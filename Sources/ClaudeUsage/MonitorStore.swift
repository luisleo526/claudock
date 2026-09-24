import AppKit
import Combine
import UsageCore

struct AccountState: Identifiable {
    var id: String { profile.id }
    let profile: Profile
    var email: String?
    var plan: SubscriptionPlan?
    var snapshot: UsageSnapshot?
    var error: MonitorError?
    var retryAt: Date?
    var loading = false
}

struct AccountReading: Sendable {
    var email: String?
    var plan: SubscriptionPlan?
    var snapshot: UsageSnapshot?
    var error: MonitorError?
}

func readAccount(_ profile: Profile) async -> AccountReading {
    if let note = profile.discoveryNote { return AccountReading(error: .unsupported(note)) }
    if profile.isVertex { return AccountReading(error: .unsupported("Vertex AI · billed through Google Cloud. Claude subscription limits do not apply.")) }
    var result = AccountReading(email: CredentialStore.email(for: profile))
    do {
        let credentials = try CredentialStore.read(profile: profile)
        result.plan = credentials.subscriptionPlan
        result.snapshot = try await UsageClient.fetch(profile: profile, credentials: credentials)
    } catch let error as MonitorError { result.error = error }
    catch { result.error = .invalidResponse }
    return result
}

@MainActor final class MonitorStore: ObservableObject {
    let isDemo = CommandLine.arguments.contains("--demo")
    /// `--demo --demo-profiles N` previews a larger synthetic collection (default 4).
    let demoProfileCount: Int = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-profiles"), arguments.indices.contains(index + 1),
              let count = Int(arguments[index + 1]) else { return DemoData.profiles.count }
        return min(max(count, 1), 200)
    }()
    @Published var accounts: [AccountState] = []
    @Published var profileError: String?
    @Published var shellIntegrationError: String?
    @Published var refreshing = false
    @Published var now = Date()
    @Published var lastRefresh: Date?
    @Published var nextRefresh = Date()
    @Published var manualRefreshAt = Date.distantPast
    @Published var analytics: AnalyticsSnapshot?
    @Published var analyticsBusy = false
    @Published var analyticsRangeDays = 7
    @Published var analyticsUpdatedAt: Date?
    @Published var analyticsDays = 7 { didSet { loadAnalytics() } }
    @Published var refreshMinutes: Int = UserDefaults.standard.object(forKey: "refreshMinutes") as? Int ?? 5 {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes")
            nextRefresh = Date().addingTimeInterval(interval)
        }
    }
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); appearanceChanged?(appearance) }
    }
    @Published var accentName = UserDefaults.standard.string(forKey: "accent") ?? "copper" {
        didSet { UserDefaults.standard.set(accentName, forKey: "accent") }
    }
    @Published var compact = UserDefaults.standard.bool(forKey: "compact") {
        didSet { UserDefaults.standard.set(compact, forKey: "compact") }
    }
    @Published var showEmails = UserDefaults.standard.bool(forKey: "showEmails") {
        didSet { UserDefaults.standard.set(showEmails, forKey: "showEmails") }
    }
    @Published var sortByUsage = UserDefaults.standard.bool(forKey: "sortByUsage") {
        didSet { UserDefaults.standard.set(sortByUsage, forKey: "sortByUsage") }
    }
    var openDashboard: (() -> Void)?
    var appearanceChanged: ((String) -> Void)?
    var statusChanged: (() -> Void)?
    private var timer: Timer?
    var interval: TimeInterval { TimeInterval([1, 5, 15].contains(refreshMinutes) ? refreshMinutes * 60 : 300) }
    private var analyticsPending = false
    private var analyticsProfiles: [Profile] = []
    private var refreshPending = false

    var sortedAccounts: [AccountState] {
        if !sortByUsage { return accounts }
        return accounts.sorted {
            let a = $0.error == nil ? ($0.snapshot?.peak ?? -1) : -1
            let b = $1.error == nil ? ($1.snapshot?.peak ?? -1) : -1
            return a == b ? $0.profile.command < $1.profile.command : a > b
        }
    }
    var availableCount: Int { profileError == nil ? accounts.filter { $0.snapshot != nil && $0.error == nil }.count : 0 }
    var subscriptionCount: Int { accounts.filter { !$0.profile.isVertex }.count }
    var attentionCount: Int { max(profileError == nil ? 0 : 1, accounts.filter { !$0.profile.isVertex && ($0.error != nil || ($0.snapshot?.peak ?? 0) >= 90) }.count) }
    var canRefresh: Bool { !refreshing && now >= manualRefreshAt }

    func start() {
        if !isDemo {
            Task {
                do {
                    _ = try await Task.detached(priority: .utility) { try ShellIntegration.upgradeIfEnabled() }.value
                    shellIntegrationError = nil
                } catch { shellIntegrationError = error.localizedDescription }
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                if self.now >= self.nextRefresh && !self.refreshing { self.refresh() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.now = Date(); if let self, !self.refreshing, self.now >= self.nextRefresh { self.refresh() } }
        }
    }
    func refresh(manual: Bool = false) {
        if isDemo {
            accounts = DemoData.profiles(count: demoProfileCount).enumerated().map { index, profile in
                AccountState(profile: profile, plan: [SubscriptionPlan.max20x, .teamPremium, .pro, .max5x][index % 4], snapshot: DemoData.usage(index: index))
            }
            now = Date(); lastRefresh = now; nextRefresh = now.addingTimeInterval(interval)
            loadAnalytics(); statusChanged?(); return
        }
        if refreshing { if !manual { refreshPending = true }; return }
        guard !manual || canRefresh else { return }
        refreshing = true; manualRefreshAt = Date().addingTimeInterval(60)
        Task {
            let profiles: [Profile]
            do {
                profiles = try await Task.detached(priority: .utility) { try ProfileStore.load() }.value
                profileError = nil
            } catch {
                profileError = error.localizedDescription
                now = Date(); nextRefresh = now.addingTimeInterval(interval); refreshing = false
                refreshPending = false; statusChanged?()
                return
            }
            accounts = profiles.map { profile in
                if let previous = accounts.first(where: { $0.profile == profile }) { return previous }
                return AccountState(profile: profile)
            }
            loadAnalytics(force: manual)
            // Stagger requests so a large collection of accounts does not burst.
            for profile in profiles {
                guard let index = accounts.firstIndex(where: { $0.id == profile.id }) else { continue }
                if let retry = accounts[index].retryAt, retry > Date() { continue }
                accounts[index].loading = true
                let reading = await Task.detached(priority: .utility) { await readAccount(profile) }.value
                accounts[index].loading = false
                accounts[index].email = reading.email
                accounts[index].plan = reading.plan ?? accounts[index].plan
                accounts[index].error = reading.error
                accounts[index].retryAt = nil
                if case .rateLimited(let retry) = reading.error { accounts[index].retryAt = retry }
                if let snapshot = reading.snapshot { accounts[index].snapshot = snapshot }
                statusChanged?()
                if !profile.isVertex { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
            now = Date(); lastRefresh = now; nextRefresh = now.addingTimeInterval(interval)
            refreshing = false; statusChanged?()
            if refreshPending { refreshPending = false; refresh() }
        }
    }
    func copyCommand(_ profile: Profile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TerminalLauncher.commandToCopy(profile), forType: .string)
    }
    func loadAnalytics(force: Bool = true) {
        if isDemo { analytics = DemoData.analytics(days: analyticsDays); return }
        let profiles = accounts.map(\.profile)
        guard !profiles.isEmpty else { return }
        if analyticsBusy { if force { analyticsPending = true }; return }
        if !force, profiles == analyticsProfiles, let updated = analyticsUpdatedAt, Date().timeIntervalSince(updated) < 300 { return }
        let days = analyticsDays
        let since = Calendar.current.date(byAdding: .day, value: -(analyticsDays - 1), to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let scanDate = Date()
        analyticsBusy = true
        Task {
            let result = await Task.detached(priority: .utility) { SessionAnalytics.scan(profiles: profiles, since: since, now: scanDate) }.value
            analytics = result; analyticsRangeDays = days; analyticsProfiles = profiles
            analyticsUpdatedAt = scanDate; analyticsBusy = false
            if analyticsPending || analyticsDays != days || accounts.map(\.profile) != profiles {
                analyticsPending = false; loadAnalytics()
            }
        }
    }
}

import AppKit
import Combine
import UsageCore

struct AccountState: Identifiable, Equatable {
    var id: String { profile.id }
    let profile: Profile
    var email: String?
    var plan: SubscriptionPlan?
    var snapshot: UsageSnapshot?
    var error: MonitorError?
    var retryAt: Date?
    var loading = false
    /// A Console profile's credit, when one is set.
    var credit: APICreditStatus?
    var creditError: String?
    /// A Console-login profile's organization from Claude Code's `.claude.json`: untrusted display text.
    var organization: String?

    /// How a Console profile is billed, for display: "Console API key" or "Console login · ORGANIZATION".
    var consoleLabel: String? {
        switch profile.authKind {
        case .apiKey: return "Console API key"
        case .consoleLogin: return organization.map { "Console login · " + $0 } ?? "Console login"
        case .subscription: return nil
        }
    }
}

struct AccountReading: Sendable {
    var email: String?
    var plan: SubscriptionPlan?
    var snapshot: UsageSnapshot?
    var error: MonitorError?
    var credit: APICreditStatus?
    var creditError: String?
    var organization: String?
}

func readAccount(_ profile: Profile) async -> AccountReading {
    if let note = profile.discoveryNote { return AccountReading(error: .unsupported(note)) }
    if profile.isVertex { return AccountReading(error: .unsupported("Vertex AI · billed through Google Cloud. Claude subscription limits do not apply.")) }
    // Billed per token: no Claude login or subscription limits to read, only the local credit ledger
    // and, for a Console sign-in, the organization Claude Code recorded.
    if profile.authKind.isConsole {
        let organization = profile.authKind == .consoleLogin ? ConsoleLogin.organizationName(profile: profile) : nil
        do { return AccountReading(credit: try APICreditStore.status(profile: profile), organization: organization) }
        catch { return AccountReading(creditError: error.localizedDescription, organization: organization) }
    }
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
    /// Shared with the CLI, which enforces it when a profile launches.
    @Published var requireInferenceToken = InferenceTokenPolicy.isRequired() {
        didSet {
            guard !isDemo, requireInferenceToken != InferenceTokenPolicy.isRequired() else { return }
            // Show the saved value if the write failed.
            if (try? InferenceTokenPolicy.setRequired(requireInferenceToken)) == nil { requireInferenceToken = InferenceTokenPolicy.isRequired() }
        }
    }
    var openDashboard: (() -> Void)?
    var appearanceChanged: ((String) -> Void)?
    var statusChanged: (() -> Void)?
    private var timer: Timer?
    var interval: TimeInterval { TimeInterval([1, 5, 15].contains(refreshMinutes) ? refreshMinutes * 60 : 300) }
    private var analyticsPending = false
    /// Earlier scans' per-file results, loaded by the first scan off the main thread; later
    /// scans (and relaunches) read only bytes appended since.
    private let analyticsCache = SessionAnalyticsCache(url: SessionAnalyticsCache.defaultURL, writeInterval: 3 * 3600)
    private var analyticsProfiles: [Profile] = []
    private var refreshPending = false
    /// Bumped when Set credit… saves, so a refresh that read the ledger before the save does not show the old credit.
    private var creditSaves: [String: Int] = [:]

    var sortedAccounts: [AccountState] {
        if !sortByUsage { return accounts }
        return accounts.sorted {
            // Console profiles have no limits, so they follow every subscription account.
            if $0.profile.authKind.isConsole != $1.profile.authKind.isConsole { return $1.profile.authKind.isConsole }
            let a = $0.error == nil ? ($0.snapshot?.peak ?? -1) : -1
            let b = $1.error == nil ? ($1.snapshot?.peak ?? -1) : -1
            return a == b ? $0.profile.command < $1.profile.command : a > b
        }
    }
    var availableCount: Int { profileError == nil ? accounts.filter { $0.snapshot != nil && $0.error == nil }.count : 0 }
    var profileCount: Int { accounts.filter { !$0.profile.isVertex }.count }
    var subscriptionCount: Int { accounts.filter { !$0.profile.isVertex && $0.profile.authKind == .subscription }.count }
    var attentionCount: Int {
        max(profileError == nil ? 0 : 1, accounts.filter {
            guard !$0.profile.isVertex else { return false }
            if $0.profile.authKind.isConsole { return $0.credit?.isLow == true }
            return $0.error != nil || ($0.snapshot?.peak ?? 0) >= 90
        }.count)
    }
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
            now = Date()
            var demo = DemoData.profiles(count: demoProfileCount).enumerated().map { index, profile in
                AccountState(profile: profile, plan: [SubscriptionPlan.max20x, .teamPremium, .pro, .max5x][index % 4],
                             snapshot: DemoData.usage(index: index, now: now), error: index == 3 ? .network : nil)
            }
            // Second and third in the list, so previews show the Console rows beside a subscription account.
            demo.insert(AccountState(profile: DemoData.apiKeyProfile, credit: DemoData.apiKeyCredit(now: now)), at: min(1, demo.count))
            demo.insert(AccountState(profile: DemoData.consoleLoginProfile, organization: DemoData.consoleOrganization), at: min(2, demo.count))
            accounts = demo
            lastRefresh = now; nextRefresh = now.addingTimeInterval(interval)
            loadAnalytics(); statusChanged?(); return
        }
        if refreshing { if !manual { refreshPending = true }; return }
        guard !manual || canRefresh else { return }
        // `claudock require-token` can change the shared setting while the app runs.
        let required = InferenceTokenPolicy.isRequired()
        if requireInferenceToken != required { requireInferenceToken = required }
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
                let creditSave = creditSaves[profile.id]
                let reading = await Task.detached(priority: .utility) { await readAccount(profile) }.value
                accounts[index].loading = false
                accounts[index].email = reading.email
                accounts[index].plan = reading.plan ?? accounts[index].plan
                accounts[index].error = reading.error
                accounts[index].retryAt = nil
                if case .rateLimited(let retry) = reading.error { accounts[index].retryAt = retry }
                if let snapshot = reading.snapshot { accounts[index].snapshot = snapshot }
                if creditSaves[profile.id] == creditSave {
                    accounts[index].credit = reading.credit
                    accounts[index].creditError = reading.creditError
                }
                accounts[index].organization = reading.organization
                statusChanged?()
                if !profile.isVertex && profile.authKind == .subscription { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
            now = Date(); lastRefresh = now; nextRefresh = now.addingTimeInterval(interval)
            refreshing = false; statusChanged?()
            if refreshPending { refreshPending = false; refresh() }
        }
    }
    /// Records a Console profile's remaining credit as of now and shows it right away.
    func setCredit(_ amount: Decimal, profile: Profile) async throws -> APICreditStatus {
        let credit = try await Task.detached(priority: .userInitiated) { try APICreditStore.setBalance(amount, profile: profile) }.value
        creditSaves[profile.id, default: 0] += 1
        if let index = accounts.firstIndex(where: { $0.profile == profile }) {
            accounts[index].credit = credit
            accounts[index].creditError = nil
        }
        statusChanged?()
        return credit
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
            let cache = analyticsCache
            let result = await Task.detached(priority: .utility) { SessionAnalytics.scan(profiles: profiles, since: since, now: scanDate, cache: cache) }.value
            analytics = result; analyticsRangeDays = days; analyticsProfiles = profiles
            analyticsUpdatedAt = scanDate; analyticsBusy = false
            if analyticsPending || analyticsDays != days || accounts.map(\.profile) != profiles {
                analyticsPending = false; loadAnalytics()
            }
        }
    }
}

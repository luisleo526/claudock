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

    /// The subscription quota part of the row, kept by `UsageRow`'s rules.
    var usage: UsageRow {
        get { UsageRow(snapshot: snapshot, plan: plan, error: error, retryAt: retryAt) }
        set { snapshot = newValue.snapshot; plan = newValue.plan; error = newValue.error; retryAt = newValue.retryAt }
    }

    /// Whether the account has room left at `now`, for the Accounts filters, groups, and sort.
    func availability(at now: Date) -> AccountAvailability {
        AccountAvailability.classify(profile: profile, snapshot: snapshot, error: error, credit: credit,
                                     creditFailed: creditError != nil, now: now)
    }

    /// The share left, 0 to 100: of the tightest subscription limit, or of the Console credit. nil without a reading,
    /// and for a third-party endpoint, which has neither.
    func percentLeft(at now: Date) -> Double? {
        if profile.authKind.isEndpoint { return nil }
        if profile.authKind.isConsole { return credit.map { (1 - $0.fraction) * 100 } }
        return snapshot?.headroom(at: now)?.percentLeft
    }

    /// How a Console profile is billed, for display: "Console API key" or "Console login · ORGANIZATION".
    var consoleLabel: String? {
        switch profile.authKind {
        case .apiKey: return "Console API key"
        case .consoleLogin: return organization.map { "Console login · " + $0 } ?? "Console login"
        case .subscription, .endpoint: return nil
        }
    }

    /// Where a third-party endpoint profile sends its requests, for display: "Third-party endpoint · HOST · MODEL".
    var endpointLabel: String? {
        profile.endpoint.map { "Third-party endpoint · \($0.host) · \($0.model)" }
    }

    /// Billed per token, by a Console organization or a third-party provider, rather than within a subscription's limits.
    var billedPerToken: Bool { profile.authKind.isConsole || profile.authKind.isEndpoint }
}

struct AccountReading: Sendable {
    var email: String?
    /// For a subscription profile without any reading, the plan its login names.
    var plan: SubscriptionPlan?
    /// A subscription profile's quota.
    var usage: UsageResult?
    /// Why the profile has no subscription quota to read.
    var error: MonitorError?
    var credit: APICreditStatus?
    var creditError: String?
    var organization: String?
}

/// The order of the Accounts list.
enum AccountSort: String, CaseIterable, Identifiable {
    /// The order of Manage profiles.
    case profile
    /// Most room left first, then near a limit, full (soonest free first), needing attention, and not tracked.
    case mostLeft
    /// Highest usage first; Console and third-party endpoint profiles follow every subscription.
    case mostUsed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: return "Profile order"
        case .mostLeft: return "Most left first"
        case .mostUsed: return "Highest usage first"
        }
    }
}

/// How the Accounts list is split into sections.
enum AccountGrouping: String, CaseIterable, Identifiable {
    case ungrouped, kind, availability
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ungrouped: return "No groups"
        case .kind: return "Account type"
        case .availability: return "Usage status"
        }
    }
}

/// Which kinds of account the Accounts list shows.
enum AccountKindFilter: String, CaseIterable, Identifiable {
    case all, subscription, console, endpoint
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All types"
        case .subscription: return "Subscriptions"
        case .console: return "Console"
        case .endpoint: return "Third-party endpoints"
        }
    }
    func includes(_ profile: Profile) -> Bool {
        switch self {
        case .all: return true
        case .subscription: return profile.authKind == .subscription
        case .console: return profile.authKind.isConsole
        case .endpoint: return profile.authKind.isEndpoint
        }
    }
}

/// One section of the Accounts list.
struct AccountGroup: Identifiable {
    let id: String
    let title: String
    let accounts: [AccountState]
}

/// Subscription quota comes through `fetcher`, which reuses a reading younger than `maxAge` from the cache shared
/// with `claudock usage` and requests nothing for a profile cooling down after HTTP 429.
func readAccount(_ profile: Profile, fetcher: UsageFetcher, maxAge: TimeInterval) async -> AccountReading {
    if let note = profile.discoveryNote { return AccountReading(error: .unsupported(note)) }
    if profile.isVertex { return AccountReading(error: .unsupported("Vertex AI · billed through Google Cloud. Claude subscription limits do not apply.")) }
    // A third-party endpoint bills per token and has nothing to read: no Claude login, limits, or Console credit.
    if profile.authKind.isEndpoint { return AccountReading() }
    // Billed per token: no Claude login or subscription limits to read, only the local credit ledger
    // and, for a Console sign-in, the organization Claude Code recorded.
    if profile.authKind.isConsole {
        let organization = profile.authKind == .consoleLogin ? ConsoleLogin.organizationName(profile: profile) : nil
        do { return AccountReading(credit: try APICreditStore.status(profile: profile), organization: organization) }
        catch { return AccountReading(creditError: error.localizedDescription, organization: organization) }
    }
    let usage = await fetcher.reading(for: profile, maxAge: maxAge, fetch: subscriptionReading)
    // Without any reading the plan still comes from the login.
    var plan: SubscriptionPlan?
    if case .failed = usage { plan = try? CredentialStore.read(profile: profile).subscriptionPlan }
    return AccountReading(email: CredentialStore.email(for: profile), plan: plan, usage: usage)
}

/// The account and plan a row names while its profile cools down and nothing is requested for it.
func accountDetails(_ profile: Profile, knownPlan: SubscriptionPlan?) -> (email: String?, plan: SubscriptionPlan?) {
    (CredentialStore.email(for: profile), knownPlan ?? (try? CredentialStore.read(profile: profile).subscriptionPlan))
}

/// One quota request, renewing an expired or rejected access token once.
@Sendable func subscriptionReading(_ profile: Profile) async throws -> UsageReading {
    let credentials = try CredentialStore.read(profile: profile)
    return UsageReading(plan: credentials.subscriptionPlan, snapshot: try await UsageClient.fetch(profile: profile, credentials: credentials))
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
    /// Replaces the earlier "Highest usage first" switch (`sortByUsage`), which it takes over when unset.
    @Published var accountSort = AccountSort(rawValue: UserDefaults.standard.string(forKey: "accountSort") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "sortByUsage") ? .mostUsed : .profile) {
        didSet { UserDefaults.standard.set(accountSort.rawValue, forKey: "accountSort") }
    }
    @Published var accountGrouping = AccountGrouping(rawValue: UserDefaults.standard.string(forKey: "accountGrouping") ?? "") ?? .ungrouped {
        didSet { UserDefaults.standard.set(accountGrouping.rawValue, forKey: "accountGrouping") }
    }
    /// Collapsed sections, as "GROUPING:ID", kept across launches.
    @Published var collapsedGroups = Set(UserDefaults.standard.stringArray(forKey: "collapsedAccountGroups") ?? []) {
        didSet { UserDefaults.standard.set(collapsedGroups.sorted(), forKey: "collapsedAccountGroups") }
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
        switch accountSort {
        case .profile: return accounts
        case .mostUsed:
            return accounts.sorted {
                // Console and endpoint profiles have no limits, so they follow every subscription account.
                if $0.billedPerToken != $1.billedPerToken { return $1.billedPerToken }
                let a = $0.error == nil ? ($0.snapshot?.peak ?? -1) : -1
                let b = $1.error == nil ? ($1.snapshot?.peak ?? -1) : -1
                return a == b ? $0.profile.command < $1.profile.command : a > b
            }
        case .mostLeft:
            let now = self.now
            let order = Dictionary(uniqueKeysWithValues: AccountAvailability.allCases.enumerated().map { ($1, $0) })
            // Computed once per account, not once per comparison.
            let keyed = accounts.map { account -> (AccountState, Int, Bool, Double, Date) in
                let status = account.availability(at: now)
                return (account, order[status] ?? 0, account.billedPerToken, account.percentLeft(at: now) ?? -1,
                        status == .full ? account.snapshot?.headroom(at: now)?.availableAgain ?? .distantFuture : .distantFuture)
            }
            return keyed.sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                // Subscriptions first: Console and endpoint profiles bill per token.
                if a.2 != b.2 { return b.2 }
                if a.3 != b.3 { return a.3 > b.3 }
                if a.4 != b.4 { return a.4 < b.4 }
                return a.0.profile.command < b.0.profile.command
            }.map { $0.0 }
        }
    }
    /// How many accounts are in each availability state.
    var availabilityCounts: [AccountAvailability: Int] {
        let now = self.now
        return accounts.reduce(into: [:]) { counts, account in counts[account.availability(at: now), default: 0] += 1 }
    }
    /// `accounts`, in their sorted order, split into the sections `accountGrouping` names; empty sections are left out.
    func groups(_ accounts: [AccountState]) -> [AccountGroup] {
        switch accountGrouping {
        case .ungrouped:
            return [AccountGroup(id: "all", title: "All profiles", accounts: accounts)]
        case .kind:
            let kinds: [(String, String, (Profile) -> Bool)] = [
                ("subscription", "Subscriptions", { !$0.isVertex && $0.discoveryNote == nil && $0.authKind == .subscription }),
                ("apiKey", "Console API keys", { $0.authKind == .apiKey }),
                ("consoleLogin", "Console sign-ins", { $0.authKind == .consoleLogin }),
                ("endpoint", "Third-party endpoints", { $0.authKind == .endpoint }),
                ("other", "Other", { ($0.isVertex || $0.discoveryNote != nil) && $0.authKind == .subscription })
            ]
            return kinds.map { id, title, matches in AccountGroup(id: id, title: title, accounts: accounts.filter { matches($0.profile) }) }
                .filter { !$0.accounts.isEmpty }
        case .availability:
            let now = self.now
            return AccountAvailability.allCases.map { status in
                AccountGroup(id: status.rawValue, title: status.title, accounts: accounts.filter { $0.availability(at: now) == status })
            }.filter { !$0.accounts.isEmpty }
        }
    }
    func isCollapsed(_ group: AccountGroup) -> Bool { collapsedGroups.contains("\(accountGrouping.rawValue):\(group.id)") }
    func toggleCollapsed(_ group: AccountGroup) {
        let key = "\(accountGrouping.rawValue):\(group.id)"
        if collapsedGroups.contains(key) { collapsedGroups.remove(key) } else { collapsedGroups.insert(key) }
    }
    var availableCount: Int { profileError == nil ? accounts.filter { $0.snapshot != nil && $0.error == nil }.count : 0 }
    var profileCount: Int { accounts.filter { !$0.profile.isVertex }.count }
    var subscriptionCount: Int { accounts.filter { !$0.profile.isVertex && $0.profile.authKind == .subscription }.count }
    var attentionCount: Int {
        max(profileError == nil ? 0 : 1, accounts.filter {
            guard !$0.profile.isVertex, !$0.profile.authKind.isEndpoint else { return false }
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
            // Before any request, show what any Claudock process read last, at launch too, and its cooldowns.
            let cached = await Task.detached(priority: .utility) { UsageCache.entries(for: profiles) }.value
            for index in accounts.indices {
                if let entry = cached[accounts[index].id] { accounts[index].usage.merge(entry) }
            }
            statusChanged?()
            loadAnalytics(force: manual)
            // An automatic refresh reuses readings younger than half its interval; a manual one asks again. The
            // fetcher spaces requests, also from `claudock usage`, so a large collection of accounts does not burst.
            let fetcher = UsageFetcher()
            let maxAge = manual ? 0 : interval / 2
            for profile in profiles {
                guard let index = accounts.firstIndex(where: { $0.id == profile.id }) else { continue }
                if accounts[index].usage.isCoolingDown(at: Date()) {
                    // Nothing is requested during a cooldown, but the row still names its account and plan.
                    let plan = accounts[index].plan
                    let details = await Task.detached(priority: .utility) { accountDetails(profile, knownPlan: plan) }.value
                    accounts[index].email = details.email
                    accounts[index].plan = details.plan
                    continue
                }
                accounts[index].loading = true
                let creditSave = creditSaves[profile.id]
                let reading = await Task.detached(priority: .utility) { await readAccount(profile, fetcher: fetcher, maxAge: maxAge) }.value
                accounts[index].loading = false
                accounts[index].email = reading.email
                if let usage = reading.usage {
                    accounts[index].usage.apply(usage)
                    accounts[index].plan = accounts[index].plan ?? reading.plan
                } else {
                    accounts[index].plan = reading.plan ?? accounts[index].plan
                    accounts[index].error = reading.error
                    accounts[index].retryAt = nil
                }
                if creditSaves[profile.id] == creditSave {
                    accounts[index].credit = reading.credit
                    accounts[index].creditError = reading.creditError
                }
                accounts[index].organization = reading.organization
                statusChanged?()
            }
            await fetcher.finish()
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

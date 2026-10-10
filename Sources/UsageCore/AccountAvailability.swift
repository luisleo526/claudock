import Foundation

/// The limit that leaves a subscription account the least room, as of a moment.
public struct UsageHeadroom: Equatable, Sendable {
    /// Percent left in `window`, from 0 to 100.
    public let percentLeft: Double
    /// The tightest limit that decides it.
    public let window: UsageWindow
    /// When every full limit has reset, if the account is full and each full limit reports a reset time.
    public let availableAgain: Date?

    public var isFull: Bool { percentLeft <= 0 }
}

extension UsageSnapshot {
    /// The limits that decide whether an account can take more work: the 5-hour, Weekly, and Fable limits the dashboard
    /// shows, or every limit when none of those is reported. Other model limits only narrow which models are left.
    public var governingWindows: [UsageWindow] {
        let display = displayWindows
        let main = [display.session, display.weekly, display.fable].compactMap { $0 }
        return main.isEmpty ? windows : main
    }

    /// The tightest governing limit at `now`. A limit whose reset time has passed counts as empty: the reading was
    /// taken before it reset. nil without any limit.
    public func headroom(at now: Date) -> UsageHeadroom? {
        let effective = governingWindows.map { window -> (UsageWindow, Double) in
            (window, window.resetsAt.map { $0 <= now } == true ? 0 : window.percent)
        }
        guard let tightest = effective.max(by: { $0.1 < $1.1 }) else { return nil }
        let full = effective.filter { $0.1 >= 100 }.map(\.0)
        let again = full.isEmpty || full.contains(where: { $0.resetsAt == nil }) ? nil : full.compactMap(\.resetsAt).max()
        return UsageHeadroom(percentLeft: max(0, 100 - tightest.1), window: tightest.0, availableAgain: again)
    }
}

/// Whether an account has room left, for the dashboard's filters and groups and `claudock available`.
public enum AccountAvailability: String, CaseIterable, Sendable {
    /// Room left in every governing limit, or Console credit that is not low.
    case available
    /// Less than 10% left in a governing limit, or low Console credit.
    case nearLimit
    /// A governing limit is used up until it resets, or no Console credit is left.
    case full
    /// The account needs a sign-in, or has no reading because the last one failed.
    case attention
    /// Nothing to measure: Vertex, a shell setup to import, a Console profile without a credit set, or not read yet.
    case untracked

    /// Below this many percent left, a limit is near.
    public static let nearLimitPercent: Double = 10

    public var title: String {
        switch self {
        case .available: return "Available"
        case .nearLimit: return "Near limit"
        case .full: return "Full"
        case .attention: return "Needs attention"
        case .untracked: return "Not tracked"
        }
    }

    /// Whether `claudock available` lists the account and the Available filter keeps it.
    public var hasRoom: Bool { self == .available || self == .nearLimit }

    /// Errors after which the reading shown no longer says what the account can do: it must sign in again.
    public static func needsSignIn(_ error: MonitorError) -> Bool {
        [.loginRequired, .unauthorized, .noCredentials, .expired, .refreshUncertain, .permissionDenied].contains(error)
    }

    /// A stale reading still classifies the account unless the error means it must sign in again.
    public static func classify(profile: Profile, snapshot: UsageSnapshot?, error: MonitorError?,
                                credit: APICreditStatus?, creditFailed: Bool = false, now: Date) -> AccountAvailability {
        if profile.isVertex || profile.discoveryNote != nil { return .untracked }
        if profile.authKind.isConsole {
            if creditFailed { return .attention }
            guard let credit else { return .untracked }
            if credit.left <= 0 { return .full }
            return credit.isLow ? .nearLimit : .available
        }
        if let error, needsSignIn(error) { return .attention }
        guard let headroom = snapshot?.headroom(at: now) else { return error == nil ? .untracked : .attention }
        if headroom.isFull { return .full }
        return headroom.percentLeft < nearLimitPercent ? .nearLimit : .available
    }
}

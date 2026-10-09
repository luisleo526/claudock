import Foundation

/// A subscription profile's quota as the dashboard keeps it between refreshes: the reading it shows, that reading's
/// plan, what made it stale, and when the next request may be made.
public struct UsageRow: Equatable, Sendable {
    public var snapshot: UsageSnapshot?
    public var plan: SubscriptionPlan?
    public var error: MonitorError?
    public var retryAt: Date?

    public init(snapshot: UsageSnapshot? = nil, plan: SubscriptionPlan? = nil, error: MonitorError? = nil, retryAt: Date? = nil) {
        self.snapshot = snapshot; self.plan = plan; self.error = error; self.retryAt = retryAt
    }

    /// Takes what the shared cache holds for the profile (`UsageCache.entries`): a reading newer than the one shown,
    /// which was read after any failure the row shows, and a cooldown that ends later than the one known.
    public mutating func merge(_ entry: UsageCacheEntry) {
        if let reading = entry.reading, reading.snapshot.fetchedAt > snapshot?.fetchedAt ?? .distantPast {
            snapshot = reading.snapshot
            plan = reading.plan
            error = nil
        }
        if let retry = entry.retryAt, retry > retryAt ?? .distantPast {
            retryAt = retry
            error = .rateLimited(retry)
        }
    }

    /// Whether a refresh at `now` must not ask for the profile.
    public func isCoolingDown(at now: Date) -> Bool {
        retryAt.map { $0 > now } ?? false
    }

    /// Takes a refresh's result. A current reading replaces the one shown, whatever that one's date; a cached one only
    /// when it is newer, so an older reading in the cache never hides a newer one the row has.
    public mutating func apply(_ result: UsageResult) {
        switch result {
        case .current(let reading):
            snapshot = reading.snapshot
            plan = reading.plan
            error = nil
        case .cached(let reading, let reason):
            if reading.snapshot.fetchedAt > snapshot?.fetchedAt ?? .distantPast {
                snapshot = reading.snapshot
                plan = reading.plan
            }
            error = reason
        case .failed(let reason):
            error = reason
        }
        if case .rateLimited(let retry)? = error { retryAt = retry } else { retryAt = nil }
    }
}

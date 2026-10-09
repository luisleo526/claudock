import Darwin
import Foundation

/// What a pass knows about one subscription profile's quota.
public enum UsageResult: Equatable, Sendable {
    /// Requested now, or cached and younger than the pass's max age.
    case current(UsageReading)
    /// An older cached reading, and why there is no newer one: a cooldown (`rateLimited`), another process holding
    /// the fetch lock too long (`usageBusy`), or the failure of this pass's request.
    case cached(UsageReading, MonitorError)
    /// No reading at all.
    case failed(MonitorError)
}

/// One pass of quota reads, a `claudock usage` run or one app refresh, through the shared `UsageCache`. A reading
/// younger than the max age is reused, and a profile cooling down after HTTP 429 is not requested. Everything else
/// is requested by one process at a time: the first profile that needs a request takes `.usage-cache-lock`, waiting
/// up to `lockWait` once per pass and meanwhile using any reading the lock holder saves, and the pass keeps the lock
/// until `finish`. Requests go one at a time, each starting at least `spacing` after the last one ended in any
/// process, and every result is saved for the other processes. Ask for one profile at a time.
public actor UsageFetcher {
    private enum Lock {
        case untried
        case waiting(Int32, deadline: TimeInterval)
        case held(Int32)
        /// No lock file could be opened: requests go ahead uncoordinated rather than never.
        case unavailable
        /// The wait ran out; nothing more is requested in this pass.
        case busy
    }

    private enum Turn {
        case request
        case settled(UsageResult)
        case busy(UsageCacheEntry?)
    }

    private let home: String
    private let lockWait: TimeInterval
    private let spacing: TimeInterval
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    /// A reading counts as current when fetched after `started` less the max age, so one that another process saves
    /// while this pass waits for the lock is used even with max age 0.
    private let started: Date
    private var lock = Lock.untried
    private var lastRequest: Date?

    public init(home: String = NSHomeDirectory(), lockWait: TimeInterval = 30) {
        self.init(home: home, lockWait: lockWait, spacing: UsageCache.spacing, now: { Date() }, random: { Double.random(in: 0..<1) })
    }

    init(home: String, lockWait: TimeInterval, spacing: TimeInterval, now: @escaping @Sendable () -> Date,
         random: @escaping @Sendable () -> Double) {
        self.home = home; self.lockWait = lockWait; self.spacing = spacing
        self.now = now; self.random = random
        started = now()
    }

    deinit {
        switch lock {
        case .held(let descriptor), .waiting(let descriptor, _): close(descriptor)
        case .untried, .unavailable, .busy: break
        }
    }

    /// `fetch` makes the request (credentials and HTTP) and is called only when one is due.
    public func reading(for profile: Profile, maxAge: TimeInterval,
                        fetch: @Sendable (Profile) async throws -> UsageReading) async -> UsageResult {
        let key = UsageCache.key(for: profile)
        let cutoff = started.addingTimeInterval(-max(0, maxAge))
        if let result = settled(UsageCache.read(home: home).profiles[key], cutoff: cutoff) { return result }
        switch await turn(key: key, cutoff: cutoff) {
        case .settled(let result): return result
        case .busy(let entry): return fallback(entry?.reading, .usageBusy)
        case .request: break
        }
        // Another process may have saved this profile while this one waited.
        var entry = UsageCache.read(home: home).profiles[key] ?? UsageCacheEntry()
        if let result = settled(entry, cutoff: cutoff) { return result }
        var previous = lastRequest
        if case .held(let descriptor) = lock, let recorded = UsageCache.lastRequest(lock: descriptor) { previous = max(previous ?? recorded, recorded) }
        let pause = UsageCache.pause(after: previous, now: now(), spacing: spacing)
        if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        let outcome: Result<UsageReading, MonitorError>
        do { outcome = .success(try await fetch(profile)) }
        catch let error as MonitorError { outcome = .failure(error) }
        catch { outcome = .failure(.invalidResponse) }
        let finished = now()
        lastRequest = finished
        if case .held(let descriptor) = lock { UsageCache.recordRequest(lock: descriptor, at: finished) }
        let result: UsageResult
        switch outcome {
        case .success(let reading):
            entry = UsageCacheEntry(reading: reading)
            result = .current(reading)
        case .failure(.rateLimited(let retryAt)):
            entry.rateLimits = min(entry.rateLimits, 1_000) + 1
            let until = retryAt ?? finished.addingTimeInterval(UsageCache.backoff(after: entry.rateLimits, random: random()))
            entry.retryAt = until
            result = fallback(entry.reading, .rateLimited(until))
        case .failure(let error):
            result = fallback(entry.reading, error)
        }
        var saved = UsageCache.read(home: home)
        saved.profiles[key] = entry
        // The reading stands even when it cannot be cached.
        try? UsageCache.write(saved, home: home, now: finished)
        return result
    }

    /// Releases the fetch lock.
    public func finish() {
        switch lock {
        case .held(let descriptor), .waiting(let descriptor, _):
            flock(descriptor, LOCK_UN)
            close(descriptor)
        case .untried, .unavailable, .busy: break
        }
        lock = .untried
    }

    /// A current reading, or a running cooldown with whatever reading there is; nil when a request is due.
    private func settled(_ entry: UsageCacheEntry?, cutoff: Date) -> UsageResult? {
        guard let entry else { return nil }
        let now = now()
        if let reading = entry.reading, UsageCache.isCurrent(reading, since: cutoff, now: now) { return .current(reading) }
        if let until = UsageCache.cooldown(entry, now: now) { return fallback(entry.reading, .rateLimited(until)) }
        return nil
    }

    private func fallback(_ reading: UsageReading?, _ error: MonitorError) -> UsageResult {
        reading.map { .cached($0, error) } ?? .failed(error)
    }

    /// Takes the fetch lock, checking meanwhile whether its holder saved what this profile needs.
    private func turn(key: String, cutoff: Date) async -> Turn {
        switch lock {
        case .held, .unavailable: return .request
        case .busy: return .busy(UsageCache.read(home: home).profiles[key])
        case .untried:
            guard let descriptor = UsageCache.openLock(home: home) else {
                lock = .unavailable
                return .request
            }
            lock = .waiting(descriptor, deadline: ProcessInfo.processInfo.systemUptime + lockWait)
        case .waiting: break
        }
        guard case .waiting(let descriptor, let deadline) = lock else { return .request }
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                lock = .held(descriptor)
                return .request
            }
            guard errno == EWOULDBLOCK || errno == EINTR else {
                close(descriptor)
                lock = .unavailable
                return .request
            }
            let entry = UsageCache.read(home: home).profiles[key]
            if let result = settled(entry, cutoff: cutoff) { return .settled(result) }
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  (try? await Task.sleep(nanoseconds: UInt64.random(in: 50_000_000...100_000_000))) != nil else {
                close(descriptor)
                lock = .busy
                return .busy(entry)
            }
        }
    }
}

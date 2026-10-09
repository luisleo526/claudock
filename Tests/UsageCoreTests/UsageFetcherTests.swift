import Darwin
import Foundation
import XCTest
@testable import UsageCore

/// One pass of quota reads through the shared cache: when it requests, what it records after HTTP 429 and
/// other failures, how it spaces requests, and how it waits for another process's fetch lock.
final class UsageFetcherTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let alpha = Profile(command: "claude-alpha", configDirectory: "/synthetic/alpha", registryID: "alpha-id", managed: true)
    private let bravo = Profile(command: "claude-bravo", configDirectory: "/synthetic/bravo", registryID: "bravo-id", managed: true)

    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-usage-fetcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ProfileStore.directory(home: home.path), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home.path
    }

    private func reading(_ percent: Double, at date: Date) -> UsageReading {
        UsageReading(plan: .max5x, snapshot: UsageSnapshot(windows: [UsageWindow(id: "five_hour", title: "5-hour session", percent: percent,
                                                                                 resetsAt: nil)], fetchedAt: date))
    }

    /// What another process saves. Pruning runs on the real clock, which keeps readings dated `instant` or today.
    private func save(_ entries: [Profile: UsageCacheEntry], home: String) throws {
        var contents = UsageCache.read(home: home)
        for (profile, entry) in entries { contents.profiles[UsageCache.key(for: profile)] = entry }
        try UsageCache.write(contents, home: home, now: Date())
    }

    private func entry(_ profile: Profile, home: String) -> UsageCacheEntry? {
        UsageCache.read(home: home).profiles[UsageCache.key(for: profile)]
    }

    /// Another process's hold on the fetch lock.
    private func holdLock(_ home: String) throws -> Int32 {
        let descriptor = open(ProfileStore.directory(home: home).appendingPathComponent(".usage-cache-lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        return descriptor
    }

    private func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// The usage endpoint: answers from a script per profile and records when each request was made.
    private final class Endpoint: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: [Result<UsageReading, Error>]]
        private var calls: [(String, Date)] = []
        init(_ answers: [String: [Result<UsageReading, Error>]] = [:]) { self.answers = answers }
        var fetch: @Sendable (Profile) async throws -> UsageReading { { try await self.answer($0) } }
        private func answer(_ profile: Profile) async throws -> UsageReading {
            let answer: Result<UsageReading, Error> = lock.withLock {
                calls.append((profile.command, Date()))
                guard var queue = answers[profile.command], !queue.isEmpty else { return .failure(MonitorError.server(599)) }
                let answer = queue.removeFirst()
                answers[profile.command] = queue
                return answer
            }
            return try answer.get()
        }
        var count: Int { lock.withLock { calls.count } }
        var times: [Date] { lock.withLock { calls.map(\.1) } }
    }

    /// A clock the test moves; the fetcher reads it for every decision.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private func fetcher(_ home: String, clock: Clock, lockWait: TimeInterval = 1, spacing: TimeInterval = 0) -> UsageFetcher {
        UsageFetcher(home: home, lockWait: lockWait, spacing: spacing, now: { clock.now }, random: { 0 })
    }

    // MARK: Reusing readings

    func testACurrentReadingIsServedWithoutARequest() async throws {
        let home = try makeHome()
        try save([alpha: UsageCacheEntry(reading: reading(10, at: instant.addingTimeInterval(-179)))], home: home)
        let endpoint = Endpoint()
        let fetcher = fetcher(home, clock: Clock(instant))
        let result = await fetcher.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        await fetcher.finish()
        XCTAssertEqual(result, .current(reading(10, at: instant.addingTimeInterval(-179))))
        XCTAssertEqual(endpoint.count, 0)
    }

    func testAnOlderReadingIsRequestedAgainAndTheResultSaved() async throws {
        let home = try makeHome()
        try save([alpha: UsageCacheEntry(reading: reading(10, at: instant.addingTimeInterval(-181)))], home: home)
        let endpoint = Endpoint(["claude-alpha": [.success(reading(20, at: instant))]])
        let fetcher = fetcher(home, clock: Clock(instant))
        let result = await fetcher.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        await fetcher.finish()
        XCTAssertEqual(result, .current(reading(20, at: instant)))
        XCTAssertEqual(endpoint.count, 1)
        XCTAssertEqual(entry(alpha, home: home), UsageCacheEntry(reading: reading(20, at: instant)))
        let lock = open(ProfileStore.directory(home: home).appendingPathComponent(".usage-cache-lock").path, O_RDONLY)
        defer { close(lock) }
        XCTAssertEqual(UsageCache.lastRequest(lock: lock), instant, "the lock file records when the request finished")
    }

    func testMaxAgeZeroUsesOnlyReadingsFetchedSinceThePassStarted() async throws {
        let home = try makeHome()
        try save([alpha: UsageCacheEntry(reading: reading(10, at: instant.addingTimeInterval(-1)))], home: home)
        let clock = Clock(instant)
        let endpoint = Endpoint(["claude-alpha": [.success(reading(11, at: instant))]])
        let fetcher = fetcher(home, clock: clock)
        let result1 = await fetcher.reading(for: alpha, maxAge: 0, fetch: endpoint.fetch)
        XCTAssertEqual(result1, .current(reading(11, at: instant)))
        // Another process saves bravo's reading while this pass runs.
        clock.advance(2)
        try save([bravo: UsageCacheEntry(reading: reading(30, at: instant.addingTimeInterval(1)))], home: home)
        let result2 = await fetcher.reading(for: bravo, maxAge: 0, fetch: endpoint.fetch)
        XCTAssertEqual(result2, .current(reading(30, at: instant.addingTimeInterval(1))))
        await fetcher.finish()
        XCTAssertEqual(endpoint.count, 1)
    }

    // MARK: Cooldowns

    func testA429WithRetryAfterKeepsTheReadingAndStartsTheCooldown() async throws {
        let home = try makeHome()
        let old = reading(10, at: instant.addingTimeInterval(-600))
        try save([alpha: UsageCacheEntry(reading: old)], home: home)
        let clock = Clock(instant)
        let endpoint = Endpoint(["claude-alpha": [.failure(MonitorError.rateLimited(instant.addingTimeInterval(600))),
                                                  .success(reading(12, at: instant.addingTimeInterval(601)))]])
        let first = fetcher(home, clock: clock)
        let result3 = await first.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result3, .cached(old, .rateLimited(instant.addingTimeInterval(600))))
        await first.finish()
        XCTAssertEqual(entry(alpha, home: home), UsageCacheEntry(reading: old, retryAt: instant.addingTimeInterval(600), rateLimits: 1))

        clock.advance(599)
        let during = fetcher(home, clock: clock)
        let result4 = await during.reading(for: alpha, maxAge: 0, fetch: endpoint.fetch)
        XCTAssertEqual(result4, .cached(old, .rateLimited(instant.addingTimeInterval(600))),
                       "max age 0 does not bypass a cooldown")
        await during.finish()
        XCTAssertEqual(endpoint.count, 1)

        clock.advance(2)
        let after = fetcher(home, clock: clock)
        let result5 = await after.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result5, .current(reading(12, at: instant.addingTimeInterval(601))))
        await after.finish()
        XCTAssertEqual(endpoint.count, 2)
        XCTAssertEqual(entry(alpha, home: home), UsageCacheEntry(reading: reading(12, at: instant.addingTimeInterval(601))), "a success clears the cooldown")
    }

    func testRepeated429sWithoutRetryAfterBackOffExponentiallyUntilASuccess() async throws {
        let home = try makeHome()
        let clock = Clock(instant)
        let limited = Result<UsageReading, Error>.failure(MonitorError.rateLimited(nil))
        let endpoint = Endpoint(["claude-alpha": [limited, limited, limited, .success(reading(5, at: instant))]])
        var started = instant
        for (count, delay) in [(1, 60.0), (2, 120.0), (3, 240.0)] {
            let pass = fetcher(home, clock: clock)
            let result6 = await pass.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
            XCTAssertEqual(result6, .failed(.rateLimited(started.addingTimeInterval(delay))))
            await pass.finish()
            XCTAssertEqual(entry(alpha, home: home), UsageCacheEntry(retryAt: started.addingTimeInterval(delay), rateLimits: count))
            clock.advance(delay + 1)
            started = clock.now
        }
        let pass = fetcher(home, clock: clock)
        let result7 = await pass.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result7, .current(reading(5, at: instant)))
        await pass.finish()
        XCTAssertEqual(entry(alpha, home: home), UsageCacheEntry(reading: reading(5, at: instant)))
        XCTAssertEqual(endpoint.count, 4)
    }

    func testOtherFailuresKeepTheReadingAndStartNoCooldown() async throws {
        let home = try makeHome()
        let old = reading(10, at: instant.addingTimeInterval(-600))
        try save([alpha: UsageCacheEntry(reading: old)], home: home)
        let endpoint = Endpoint(["claude-alpha": [.failure(MonitorError.network), .failure(MonitorError.expired)],
                                 "claude-bravo": [.failure(MonitorError.server(503)), .failure(CocoaError(.fileReadUnknown))]])
        let clock = Clock(instant)
        let first = fetcher(home, clock: clock)
        let result8 = await first.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result8, .cached(old, .network))
        let result9 = await first.reading(for: bravo, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result9, .failed(.server(503)))
        await first.finish()
        XCTAssertEqual(entry(alpha, home: home), UsageCacheEntry(reading: old))
        let second = fetcher(home, clock: clock)
        let result10 = await second.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result10, .cached(old, .expired))
        let result11 = await second.reading(for: bravo, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result11, .failed(.invalidResponse))
        await second.finish()
        XCTAssertEqual(endpoint.count, 4, "without a cooldown each pass asks again")
    }

    // MARK: Pacing and the fetch lock

    func testRequestsAreSpacedWithinAPassAndAcrossPasses() async throws {
        let home = try makeHome()
        let endpoint = Endpoint(["claude-alpha": [.success(reading(1, at: Date())), .success(reading(2, at: Date()))],
                                 "claude-bravo": [.success(reading(3, at: Date()))]])
        let first = UsageFetcher(home: home, lockWait: 1, spacing: 0.2, now: { Date() }, random: { 0 })
        _ = await first.reading(for: alpha, maxAge: 0, fetch: endpoint.fetch)
        _ = await first.reading(for: bravo, maxAge: 0, fetch: endpoint.fetch)
        await first.finish()
        let second = UsageFetcher(home: home, lockWait: 1, spacing: 0.2, now: { Date() }, random: { 0 })
        _ = await second.reading(for: alpha, maxAge: 0, fetch: endpoint.fetch)
        await second.finish()
        let times = endpoint.times
        XCTAssertEqual(times.count, 3)
        for (earlier, later) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 0.2)
        }
    }

    func testSpacingHoldsWhenTheCacheIsLostBetweenPasses() async throws {
        let home = try makeHome()
        let endpoint = Endpoint(["claude-alpha": [.success(reading(1, at: instant)), .success(reading(2, at: instant))]])
        let first = UsageFetcher(home: home, lockWait: 1, spacing: 0.3, now: { Date() }, random: { 0 })
        _ = await first.reading(for: alpha, maxAge: 0, fetch: endpoint.fetch)
        await first.finish()
        try Data("lost".utf8).write(to: ProfileStore.directory(home: home).appendingPathComponent("usage-cache.json"))
        let second = UsageFetcher(home: home, lockWait: 1, spacing: 0.3, now: { Date() }, random: { 0 })
        _ = await second.reading(for: alpha, maxAge: 0, fetch: endpoint.fetch)
        await second.finish()
        let times = endpoint.times
        XCTAssertEqual(times.count, 2)
        XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(times[0]), 0.3, "the last request's time must not depend on the cache")
    }

    func testThePassHoldsTheFetchLockUntilItFinishes() async throws {
        let home = try makeHome()
        let endpoint = Endpoint(["claude-alpha": [.success(reading(1, at: instant))]])
        let pass = fetcher(home, clock: Clock(instant))
        _ = await pass.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        let other = open(ProfileStore.directory(home: home).appendingPathComponent(".usage-cache-lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(other, 0)
        defer { close(other) }
        XCTAssertNotEqual(flock(other, LOCK_EX | LOCK_NB), 0, "another process cannot fetch while this pass may")
        await pass.finish()
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
    }

    func testABusyLockServesTheCacheAndStopsWaitingForTheRestOfThePass() async throws {
        let home = try makeHome()
        let old = reading(10, at: instant.addingTimeInterval(-600))
        try save([alpha: UsageCacheEntry(reading: old)], home: home)
        let held = try holdLock(home)
        defer { release(held) }
        let endpoint = Endpoint(["claude-alpha": [.success(reading(1, at: instant))], "claude-bravo": [.success(reading(2, at: instant))]])
        let pass = fetcher(home, clock: Clock(instant), lockWait: 0.3)
        var started = Date()
        let result12 = await pass.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result12, .cached(old, .usageBusy))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        started = Date()
        let result13 = await pass.reading(for: bravo, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result13, .failed(.usageBusy))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "the wait is spent once per pass")
        await pass.finish()
        XCTAssertEqual(endpoint.count, 0)
    }

    func testAReadingTheLockHolderSavesIsUsedWithoutWaitingForTheLock() async throws {
        let home = try makeHome()
        let held = try holdLock(home)
        defer { release(held) }
        // Whole seconds, which the cache's millisecond times keep exactly.
        let saved = reading(42, at: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        let holder = Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            try self.save([self.alpha: UsageCacheEntry(reading: saved)], home: home)
        }
        let endpoint = Endpoint()
        let pass = UsageFetcher(home: home, lockWait: 10, spacing: 0, now: { Date() }, random: { 0 })
        let started = Date()
        let result = await pass.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        await pass.finish()
        try await holder.value
        XCTAssertEqual(result, .current(saved))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(endpoint.count, 0)
    }

    func testACacheThatCannotBeWrittenStillReturnsTheReading() async throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(at: ProfileStore.directory(home: home).appendingPathComponent("usage-cache.json"),
                                                withIntermediateDirectories: false)
        let endpoint = Endpoint(["claude-alpha": [.success(reading(7, at: instant))]])
        let pass = fetcher(home, clock: Clock(instant))
        let result14 = await pass.reading(for: alpha, maxAge: 180, fetch: endpoint.fetch)
        XCTAssertEqual(result14, .current(reading(7, at: instant)))
        await pass.finish()
    }
}

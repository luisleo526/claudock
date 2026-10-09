import Darwin
import Foundation
import XCTest
@testable import UsageCore

/// The shared usage cache: its file format, pruning, and the rules for reusing a reading, cooling down after
/// HTTP 429, and spacing requests.
final class UsageCacheTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func withHome(_ action: (String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-usage-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try action(home.path)
    }

    private func file(_ home: String) -> URL {
        ProfileStore.directory(home: home).appendingPathComponent("usage-cache.json")
    }

    private func reading(_ percent: Double, at date: Date, plan: SubscriptionPlan = .max20x) -> UsageReading {
        UsageReading(plan: plan, snapshot: UsageSnapshot(windows: [
            UsageWindow(id: "five_hour", title: "5-hour session", percent: percent, resetsAt: date.addingTimeInterval(3600)),
            UsageWindow(id: "seven_day", title: "Weekly · all models", percent: percent / 2, resetsAt: nil)
        ], fetchedAt: date))
    }

    private let alpha = "Claude Code-credentials-0a1b2c3d", bravo = "Claude Code-credentials-4e5f6a7b"

    // MARK: Cooldown and pacing

    func testBackoffStartsAtOneMinuteDoublesAndStopsAtThirtyMinutes() {
        XCTAssertEqual(UsageCache.backoff(after: 1, random: 0), 60)
        XCTAssertEqual(UsageCache.backoff(after: 2, random: 0), 120)
        XCTAssertEqual(UsageCache.backoff(after: 3, random: 0), 240)
        XCTAssertEqual(UsageCache.backoff(after: 5, random: 0), 960)
        XCTAssertEqual(UsageCache.backoff(after: 6, random: 0), 1800)
        XCTAssertEqual(UsageCache.backoff(after: 7, random: 0), 1800)
        XCTAssertEqual(UsageCache.backoff(after: 0, random: 0), 60, "a count below one is the first rate limit")
        XCTAssertEqual(UsageCache.backoff(after: Int.max, random: 0.5), 1800, "a huge count must not overflow")
    }

    func testJitterAddsAtMostAQuarterAndNeverPassesThirtyMinutes() {
        XCTAssertEqual(UsageCache.backoff(after: 1, random: 0.5), 67.5)
        XCTAssertEqual(UsageCache.backoff(after: 2, random: 0.999_999), 150, accuracy: 0.001)
        XCTAssertEqual(UsageCache.backoff(after: 5, random: 0.999_999), 1200, accuracy: 0.001)
        XCTAssertEqual(UsageCache.backoff(after: 6, random: 0.999_999), 1800)
        for count in 1...12 {
            for random in [0, 0.25, 0.5, 0.75, 0.999_999] {
                let delay = UsageCache.backoff(after: count, random: random)
                let base = min(1800, 60 * pow(2, Double(count - 1)))
                XCTAssertGreaterThanOrEqual(delay, base, "count \(count), random \(random)")
                XCTAssertLessThanOrEqual(delay, min(1800, base * 1.25), "count \(count), random \(random)")
            }
        }
    }

    func testProductionJitterIsRandomWithinTheBounds() {
        let delays = (0..<200).map { _ in UsageCache.backoff(after: 1) }
        XCTAssertTrue(delays.allSatisfy { $0 >= 60 && $0 <= 75 }, "\(delays.filter { $0 < 60 || $0 > 75 })")
        XCTAssertGreaterThan(Set(delays).count, 1, "parallel cooldowns must not all end together")
    }

    func testAPauseKeepsHalfASecondAfterTheLastRequest() {
        XCTAssertEqual(UsageCache.pause(after: nil, now: instant, spacing: 0.5), 0)
        XCTAssertEqual(UsageCache.pause(after: instant.addingTimeInterval(-0.1), now: instant, spacing: 0.5), 0.4, accuracy: 0.000_001)
        XCTAssertEqual(UsageCache.pause(after: instant.addingTimeInterval(-0.5), now: instant, spacing: 0.5), 0)
        XCTAssertEqual(UsageCache.pause(after: instant.addingTimeInterval(-60), now: instant, spacing: 0.5), 0)
        XCTAssertEqual(UsageCache.pause(after: instant.addingTimeInterval(3600), now: instant, spacing: 0.5), 0.5,
                       "a last request in the future (the clock moved back) waits one spacing, not an hour")
    }

    func testAReadingIsCurrentWhenFetchedAfterTheCutoff() {
        let cutoff = instant.addingTimeInterval(-180)
        XCTAssertTrue(UsageCache.isCurrent(reading(1, at: instant.addingTimeInterval(-179)), since: cutoff, now: instant))
        XCTAssertFalse(UsageCache.isCurrent(reading(1, at: instant.addingTimeInterval(-181)), since: cutoff, now: instant))
        XCTAssertFalse(UsageCache.isCurrent(reading(1, at: cutoff), since: cutoff, now: instant), "younger than the max age, not as old")
        XCTAssertTrue(UsageCache.isCurrent(reading(1, at: instant.addingTimeInterval(30)), since: cutoff, now: instant),
                      "a clock a little behind another process's still trusts its reading")
        XCTAssertFalse(UsageCache.isCurrent(reading(1, at: instant.addingTimeInterval(3600)), since: cutoff, now: instant),
                       "a reading an hour in the future is not trusted")
    }

    func testOnlyARunningPlausibleCooldownCounts() {
        XCTAssertNil(UsageCache.cooldown(UsageCacheEntry(), now: instant))
        XCTAssertNil(UsageCache.cooldown(UsageCacheEntry(retryAt: instant.addingTimeInterval(-1), rateLimits: 1), now: instant))
        XCTAssertNil(UsageCache.cooldown(UsageCacheEntry(retryAt: instant, rateLimits: 1), now: instant))
        XCTAssertEqual(UsageCache.cooldown(UsageCacheEntry(retryAt: instant.addingTimeInterval(90), rateLimits: 1), now: instant),
                       instant.addingTimeInterval(90))
        XCTAssertEqual(UsageCache.cooldown(UsageCacheEntry(retryAt: instant.addingTimeInterval(86_400), rateLimits: 1), now: instant),
                       instant.addingTimeInterval(86_400), "Retry-After may ask for a day")
        XCTAssertNil(UsageCache.cooldown(UsageCacheEntry(retryAt: instant.addingTimeInterval(3 * 86_400), rateLimits: 1), now: instant),
                     "a cooldown longer than any Claudock sets is not trusted")
    }

    // MARK: File format

    func testContentsRoundTrip() throws {
        var contents = UsageCache.Contents()
        contents.profiles[alpha] = UsageCacheEntry(reading: reading(42.5, at: instant.addingTimeInterval(-60)))
        let extra = UsageReading(plan: .teamPremium, snapshot: UsageSnapshot(windows: [UsageWindow(id: "session-0", title: "5-hour session",
                                                                                                   percent: 100, resetsAt: nil)],
                                                                           fetchedAt: instant.addingTimeInterval(-120), extraUsageEnabled: true,
                                                                           extraUsagePercent: 12.25))
        contents.profiles[bravo] = UsageCacheEntry(reading: extra, retryAt: instant.addingTimeInterval(300), rateLimits: 2)
        contents.profiles["Claude Code-credentials"] = UsageCacheEntry(retryAt: instant.addingTimeInterval(60), rateLimits: 1)
        let data = try UsageCache.encode(contents, now: instant)
        XCTAssertEqual(UsageCache.decode(data), contents)
    }

    func testTheFileHoldsReadingsAndCooldownsOnly() throws {
        var contents = UsageCache.Contents()
        contents.profiles[alpha] = UsageCacheEntry(reading: reading(42.5, at: instant), retryAt: instant.addingTimeInterval(300), rateLimits: 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: UsageCache.encode(contents, now: instant)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let entry = try XCTUnwrap((object["profiles"] as? [String: Any])?[alpha] as? [String: Any])
        XCTAssertEqual(Set(entry.keys), ["reading", "retryAt", "rateLimits"])
        let stored = try XCTUnwrap(entry["reading"] as? [String: Any])
        XCTAssertEqual(stored["plan"] as? String, "max20x")
        XCTAssertEqual(stored["fetchedAt"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual((stored["windows"] as? [[String: Any]])?.first?["resetsAt"] as? String, "2027-01-15T09:00:00.000Z")
    }

    func testDecodingRejectsWhatItCannotTrust() throws {
        var contents = UsageCache.Contents()
        contents.profiles[alpha] = UsageCacheEntry(reading: reading(1, at: instant))
        let valid = try UsageCache.encode(contents, now: instant)
        XCTAssertNotNil(UsageCache.decode(valid))
        let text = try XCTUnwrap(String(data: valid, encoding: .utf8))
        for (label, data) in [("garbage", Data([0, 0xFF, 0xFE])), ("truncated", valid.dropLast(10)), ("empty", Data()),
                              ("another version", Data(text.replacingOccurrences(of: #""version":1"#, with: #""version":2"#).utf8)),
                              ("an array", Data("[\(text)]".utf8)),
                              ("oversized", Data(text.dropLast().utf8) + Data(repeating: 0x20, count: 1_048_576) + Data("}".utf8))] {
            XCTAssertNil(UsageCache.decode(Data(data)), label)
        }
    }

    func testDecodingDropsEntriesWithImpossibleValues() throws {
        var contents = UsageCache.Contents()
        contents.profiles[alpha] = UsageCacheEntry(reading: reading(10, at: instant))
        contents.profiles[bravo] = UsageCacheEntry(reading: reading(20, at: instant))
        let valid = try XCTUnwrap(String(data: UsageCache.encode(contents, now: instant), encoding: .utf8))
        func decoded(_ edit: (inout [String: Any]) -> Void) throws -> UsageCache.Contents? {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
            var profiles = try XCTUnwrap(root["profiles"] as? [String: Any])
            var entry = try XCTUnwrap(profiles[alpha] as? [String: Any])
            edit(&entry)
            profiles[alpha] = entry
            root["profiles"] = profiles
            return UsageCache.decode(try JSONSerialization.data(withJSONObject: root))
        }
        func windows(_ entry: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
            var stored = entry["reading"] as! [String: Any]
            var list = stored["windows"] as! [[String: Any]]
            edit(&list[0])
            stored["windows"] = list
            entry["reading"] = stored
        }
        let edits: [(String, (inout [String: Any]) -> Void)] = [
            ("a negative percentage", { windows(&$0) { $0["percent"] = -1 } }),
            ("no windows", { var stored = $0["reading"] as! [String: Any]; stored["windows"] = []; $0["reading"] = stored }),
            ("a negative rate-limit count", { $0["rateLimits"] = -1 })
        ]
        for (label, edit) in edits {
            let result = try XCTUnwrap(try decoded(edit), label)
            XCTAssertNil(result.profiles[alpha], label)
            XCTAssertEqual(result.profiles[bravo], contents.profiles[bravo], label)
        }
        var renamed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
        var profiles = try XCTUnwrap(renamed["profiles"] as? [String: Any])
        profiles["someone@example.com"] = profiles[alpha]
        renamed["profiles"] = profiles
        XCTAssertNil(UsageCache.decode(try JSONSerialization.data(withJSONObject: renamed))?.profiles["someone@example.com"],
                     "only credential-service keys are kept")
    }

    func testAnUnknownPlanReadsAsUnknown() throws {
        var contents = UsageCache.Contents()
        contents.profiles[alpha] = UsageCacheEntry(reading: reading(10, at: instant))
        let text = try XCTUnwrap(String(data: UsageCache.encode(contents, now: instant), encoding: .utf8))
        let decoded = UsageCache.decode(Data(text.replacingOccurrences(of: #""plan":"max20x""#, with: #""plan":"max40x""#).utf8))
        XCTAssertEqual(decoded?.profiles[alpha]?.reading?.plan, .unknown)
    }

    func testPruningDropsWeekOldReadingsAndEndedCooldowns() {
        var contents = UsageCache.Contents()
        contents.profiles["Claude Code-credentials-00000001"] = UsageCacheEntry(reading: reading(1, at: instant.addingTimeInterval(-6 * 86_400)))
        contents.profiles["Claude Code-credentials-00000002"] = UsageCacheEntry(reading: reading(1, at: instant.addingTimeInterval(-8 * 86_400)))
        contents.profiles["Claude Code-credentials-00000003"] = UsageCacheEntry(reading: reading(1, at: instant.addingTimeInterval(-8 * 86_400)),
                                                                                  retryAt: instant.addingTimeInterval(60), rateLimits: 1)
        contents.profiles["Claude Code-credentials-00000004"] = UsageCacheEntry(retryAt: instant.addingTimeInterval(-3600), rateLimits: 3)
        contents.profiles["Claude Code-credentials-00000005"] = UsageCacheEntry(retryAt: instant.addingTimeInterval(-2 * 86_400), rateLimits: 3)
        contents.profiles["Claude Code-credentials-00000006"] = UsageCacheEntry(reading: reading(1, at: instant.addingTimeInterval(-3600)),
                                                                                  retryAt: instant.addingTimeInterval(-2 * 86_400), rateLimits: 3)
        let pruned = UsageCache.pruned(contents, now: instant)
        XCTAssertEqual(pruned.profiles["Claude Code-credentials-00000006"], UsageCacheEntry(reading: reading(1, at: instant.addingTimeInterval(-3600))),
                       "a cooldown that ended over a day ago is forgotten, so the next 429 starts at one minute again")
        XCTAssertEqual(pruned.profiles["Claude Code-credentials-00000001"], contents.profiles["Claude Code-credentials-00000001"])
        XCTAssertNil(pruned.profiles["Claude Code-credentials-00000002"], "a week-old reading describes windows that have all reset")
        XCTAssertEqual(pruned.profiles["Claude Code-credentials-00000003"],
                       UsageCacheEntry(retryAt: instant.addingTimeInterval(60), rateLimits: 1), "the cooldown stays without the old reading")
        XCTAssertEqual(pruned.profiles["Claude Code-credentials-00000004"], contents.profiles["Claude Code-credentials-00000004"],
                       "a recently ended cooldown keeps its count for the next backoff")
        XCTAssertNil(pruned.profiles["Claude Code-credentials-00000005"])
    }

    func testPruningKeepsTheMostRecentProfiles() {
        var contents = UsageCache.Contents()
        for index in 0..<300 {
            contents.profiles[String(format: "Claude Code-credentials-%08x", index)] = UsageCacheEntry(reading: reading(1, at: instant.addingTimeInterval(Double(-index))))
        }
        let pruned = UsageCache.pruned(contents, now: instant)
        XCTAssertEqual(pruned.profiles.count, 256)
        XCTAssertNotNil(pruned.profiles["Claude Code-credentials-00000000"])
        XCTAssertNotNil(pruned.profiles[String(format: "Claude Code-credentials-%08x", 255)])
        XCTAssertNil(pruned.profiles[String(format: "Claude Code-credentials-%08x", 256)])
    }

    func testEncodingStaysUnderTheSizeLimit() throws {
        var contents = UsageCache.Contents()
        let windows = (0..<400).map { UsageWindow(id: "limit-\($0)", title: String(repeating: "W", count: 200), percent: 1, resetsAt: nil) }
        for index in 0..<40 {
            contents.profiles[String(format: "Claude Code-credentials-%08x", index)] = UsageCacheEntry(
                reading: UsageReading(plan: .pro, snapshot: UsageSnapshot(windows: windows, fetchedAt: instant.addingTimeInterval(Double(-index)))))
        }
        let data = try UsageCache.encode(contents, now: instant)
        XCTAssertLessThanOrEqual(data.count, 1_048_576)
        let decoded = try XCTUnwrap(UsageCache.decode(data))
        XCTAssertNotNil(decoded.profiles["Claude Code-credentials-00000000"], "the newest readings are kept")
        XCTAssertLessThan(decoded.profiles.count, 40)
    }

    // MARK: Files

    func testWritesAPrivateFileAtomicallyAndReadsItBack() throws {
        try withHome { home in
            var contents = UsageCache.Contents()
            contents.profiles[alpha] = UsageCacheEntry(reading: reading(5, at: instant))
            try UsageCache.write(contents, home: home, now: instant)
            var info = stat()
            XCTAssertEqual(lstat(file(home).path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
            XCTAssertEqual(UsageCache.read(home: home), contents)
            let names = try FileManager.default.contentsOfDirectory(atPath: ProfileStore.directory(home: home).path)
            XCTAssertEqual(names.filter { $0.contains("usage-cache") && $0 != "usage-cache.json" }, [], "no temporary file is left behind")
        }
    }

    func testAMissingOrBadFileReadsAsEmptyAndIsReplaced() throws {
        try withHome { home in
            XCTAssertEqual(UsageCache.read(home: home), UsageCache.Contents())
            try FileManager.default.createDirectory(at: ProfileStore.directory(home: home), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: file(home))
            XCTAssertEqual(UsageCache.read(home: home), UsageCache.Contents())
            var contents = UsageCache.Contents()
            contents.profiles[alpha] = UsageCacheEntry(reading: reading(5, at: instant))
            try UsageCache.write(contents, home: home, now: instant)
            XCTAssertEqual(UsageCache.read(home: home), contents)
        }
    }

    func testASymbolicLinkIsNeitherReadNorWrittenThrough() throws {
        try withHome { home in
            var contents = UsageCache.Contents()
            contents.profiles[alpha] = UsageCacheEntry(reading: reading(5, at: instant))
            try UsageCache.write(contents, home: home, now: instant)
            let target = URL(fileURLWithPath: home).appendingPathComponent("elsewhere.json")
            try FileManager.default.moveItem(at: file(home), to: target)
            let planted = try Data(contentsOf: target)
            try FileManager.default.createSymbolicLink(at: file(home), withDestinationURL: target)
            XCTAssertEqual(UsageCache.read(home: home), UsageCache.Contents())
            try UsageCache.write(UsageCache.Contents(), home: home, now: instant)
            XCTAssertEqual(try Data(contentsOf: target), planted)
            let attributes = try FileManager.default.attributesOfItem(atPath: file(home).path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        }
    }

    func testEntriesAreGivenByProfileWithOnlyRunningCooldowns() throws {
        try withHome { home in
            let first = Profile(command: "claude-first", configDirectory: "/synthetic/first", registryID: "first-id", managed: true)
            let second = Profile(command: "claude-second", configDirectory: "/synthetic/second", registryID: "second-id", managed: true)
            let third = Profile(command: "claude-third", configDirectory: "/synthetic/third", registryID: "third-id", managed: true)
            var contents = UsageCache.Contents()
            contents.profiles[UsageCache.key(for: first)] = UsageCacheEntry(reading: reading(5, at: instant), retryAt: instant.addingTimeInterval(60), rateLimits: 1)
            contents.profiles[UsageCache.key(for: second)] = UsageCacheEntry(reading: reading(6, at: instant), retryAt: instant.addingTimeInterval(-60), rateLimits: 1)
            try UsageCache.write(contents, home: home, now: instant)
            let entries = UsageCache.entries(for: [first, second, third], home: home, now: instant)
            XCTAssertEqual(entries["first-id"]?.reading, reading(5, at: instant))
            XCTAssertEqual(entries["first-id"]?.retryAt, instant.addingTimeInterval(60))
            XCTAssertEqual(entries["second-id"]?.reading, reading(6, at: instant))
            XCTAssertNil(entries["second-id"]?.retryAt, "an ended cooldown is not reported")
            XCTAssertNil(entries["third-id"])
        }
    }

    /// The cache is keyed by credential service, which an unresolved, Vertex, or Console profile can share with a
    /// subscription profile that once used the same folder; none of them reads subscription usage.
    func testEntriesAreOnlyForProfilesThatReadSubscriptionUsage() throws {
        try withHome { home in
            let profiles = [Profile(command: "claude", configDirectory: "", discoveryNote: "Needs import"),
                            Profile(command: "claude-vertex", configDirectory: "/synthetic/vertex", isVertex: true),
                            Profile(command: "claude-key", configDirectory: "/synthetic/key", registryID: "key-id", managed: true, authKind: .apiKey),
                            Profile(command: "claude-team", configDirectory: "/synthetic/team", registryID: "team-id", managed: true, authKind: .consoleLogin),
                            Profile(command: "claude-work", configDirectory: "/synthetic/work", registryID: "work-id", managed: true)]
            var contents = UsageCache.Contents()
            for profile in profiles {
                contents.profiles[UsageCache.key(for: profile)] = UsageCacheEntry(reading: reading(5, at: instant), retryAt: instant.addingTimeInterval(60), rateLimits: 1)
            }
            try UsageCache.write(contents, home: home, now: instant)
            XCTAssertEqual(Array(UsageCache.entries(for: profiles, home: home, now: instant).keys), ["work-id"])
        }
    }

    func testEntriesLeaveOutReadingsDatedInTheFuture() throws {
        try withHome { home in
            let ahead = Profile(command: "claude-ahead", configDirectory: "/synthetic/ahead", registryID: "ahead-id", managed: true)
            let cooling = Profile(command: "claude-cooling", configDirectory: "/synthetic/cooling", registryID: "cooling-id", managed: true)
            var contents = UsageCache.Contents()
            contents.profiles[UsageCache.key(for: ahead)] = UsageCacheEntry(reading: reading(5, at: instant.addingTimeInterval(3600)))
            contents.profiles[UsageCache.key(for: cooling)] = UsageCacheEntry(reading: reading(6, at: instant.addingTimeInterval(3600)),
                                                                                retryAt: instant.addingTimeInterval(60), rateLimits: 1)
            try UsageCache.write(contents, home: home, now: instant)
            let entries = UsageCache.entries(for: [ahead, cooling], home: home, now: instant)
            XCTAssertNil(entries["ahead-id"], "a reading an hour ahead was taken with a wrong clock and is not shown")
            XCTAssertEqual(entries["cooling-id"], UsageCacheEntry(retryAt: instant.addingTimeInterval(60), rateLimits: 1))
        }
    }
}

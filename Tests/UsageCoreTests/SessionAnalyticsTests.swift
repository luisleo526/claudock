import Foundation
import XCTest
import Darwin
@testable import UsageCore

final class SessionAnalyticsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-08T12:00:00Z")!
    private let sessionA = "11111111-1111-4111-8111-111111111111"
    private let sessionB = "22222222-2222-4222-8222-222222222222"

    private func fixture(_ body: (URL) throws -> Void) throws {
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        let temporaryPath = String(cString: resolved)
        free(resolved)
        let root = URL(fileURLWithPath: temporaryPath)
            .appendingPathComponent("claude-analytics-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func profile(_ name: String, root: URL) -> Profile {
        Profile(command: "claude-" + name, configDirectory: root.appendingPathComponent(name).path)
    }
    private func assistant(_ id: String?, usage: [String: Any], timestamp: String = "2026-09-08T12:00:00Z",
                           request: String? = nil, includeAllCounters: Bool = true) throws -> String {
        var counters: [String: Any] = includeAllCounters
            ? ["input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0] : [:]
        counters.merge(usage) { _, supplied in supplied }
        var message: [String: Any] = ["role": "assistant", "usage": counters,
                                     "content": [["type": "text", "text": "DO NOT DISPLAY PRIVATE PROMPT CONTENT"]]]
        if let id { message["id"] = id }
        var record: [String: Any] = ["type": "assistant", "message": message, "timestamp": timestamp,
                                    "sessionId": sessionA, "cwd": "/Users/tester/Project With Spaces"]
        if let request { record["requestId"] = request }
        return String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    }
    @discardableResult
    private func write(_ lines: [String], profile: Profile, session: String, project: String = "-Users-tester-project",
                       modified: Date? = nil, created: Date? = nil, trailingNewline: Bool = true) throws -> URL {
        let directory = URL(fileURLWithPath: profile.configDirectory).appendingPathComponent("projects").appendingPathComponent(project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(session + ".jsonl")
        try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified ?? now, .creationDate: created ?? now.addingTimeInterval(-3_600)], ofItemAtPath: url.path)
        return url
    }
    private func scan(_ profiles: [Profile], since: Date? = nil) -> AnalyticsSnapshot {
        SessionAnalytics.scan(profiles: profiles, since: since ?? now.addingTimeInterval(-7 * 86_400), now: now)
    }

    func testAssistantSnapshotsMergeEachComponentInsteadOfCountingContentBlocks() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([
                try assistant("same-message", usage: ["input_tokens": 100, "output_tokens": 2, "cache_read_input_tokens": 200, "cache_creation_input_tokens": 40], request: "same-request"),
                try assistant("same-message", usage: ["input_tokens": 90, "output_tokens": 20, "cache_read_input_tokens": 180, "cache_creation_input_tokens": 30], request: "same-request"),
                try assistant("another-message", usage: ["input_tokens": 5, "output_tokens": 6, "cache_read_input_tokens": 7, "cache_creation_input_tokens": 8], request: "same-request")
            ], profile: p, session: sessionA)
            let result = scan([p])
            XCTAssertFalse(result.truncated)
            XCTAssertEqual(result.totals, TokenTotals(input: 105, output: 26, cacheRead: 207, cacheWrite: 48))
            XCTAssertEqual(result.totals.total, 386)
            XCTAssertEqual(result.sessions.first?.tokens, result.totals)
            XCTAssertEqual(result.profiles.first?.tokens, result.totals)
            XCTAssertEqual(result.daily.last?.tokens, 386)
        }
    }

    func testCopiedHistoryIsDeduplicatedAcrossProfilesAndNewWorkStaysWithTarget() throws {
        try fixture { root in
            let old = profile("original", root: root), target = profile("target", root: root)
            let shared = try assistant("shared-message", usage: ["input_tokens": 10, "output_tokens": 20])
            try write([shared], profile: old, session: sessionA, created: now.addingTimeInterval(-7_200))
            try write([shared, try assistant("new-message", usage: ["input_tokens": 4, "output_tokens": 1])],
                      profile: target, session: sessionB, created: now.addingTimeInterval(-3_600))
            let result = scan([target, old])
            XCTAssertEqual(result.sessions.count, 2)
            XCTAssertEqual(Set(result.sessions.map(\.id)).count, 2)
            XCTAssertEqual(result.totals.total, 35)
            XCTAssertEqual(result.profiles.first(where: { $0.command == old.command })?.tokens.total, 30)
            XCTAssertEqual(result.profiles.first(where: { $0.command == target.command })?.tokens.total, 5)
            XCTAssertEqual(result.sessions.reduce(Int64(0)) { $0 + $1.tokens.total }, 35)
            XCTAssertTrue(result.sessions.allSatisfy(\.hasUsage))
        }
    }

    func testSharedConfigAliasIsScannedOnlyOnce() throws {
        try fixture { root in
            let first = profile("one", root: root)
            let alias = Profile(command: "claude-alias", configDirectory: first.configDirectory)
            try write([try assistant("message", usage: ["input_tokens": 7])], profile: first, session: sessionA)
            let result = scan([first, alias])
            XCTAssertEqual(result.sessions.count, 1)
            XCTAssertEqual(result.totals.total, 7)
            XCTAssertEqual(result.profiles.map(\.command), [SessionAnalytics.sharedProfileCommand])
            XCTAssertEqual(result.sessions.first?.profileCommand, SessionAnalytics.sharedProfileCommand)
            XCTAssertTrue(result.hasSharedHistory)
            XCTAssertEqual(result.profiles.reduce(Int64(0)) { $0 + $1.tokens.total }, 7)
        }
    }

    func testTimeRangeUsesMessageTimestampAndDailyBucketsUseLocalCalendar() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([
                try assistant("old", usage: ["input_tokens": 1_000], timestamp: "2026-08-01T12:00:00Z"),
                try assistant("first-day", usage: ["input_tokens": 10], timestamp: "2026-09-07T12:00:00Z"),
                try assistant("second-day", usage: ["input_tokens": 20], timestamp: "2026-09-08T20:00:00+08:00")
            ], profile: p, session: sessionA)
            let result = scan([p])
            XCTAssertEqual(result.totals.total, 30)
            XCTAssertEqual(result.daily.suffix(2).map(\.tokens), [10, 20])
            XCTAssertTrue(result.daily.dropLast(2).allSatisfy { $0.tokens == 0 })
            XCTAssertEqual(result.daily.last?.day, Calendar.current.startOfDay(for: now))
        }
    }

    func testNoUsageRemainsUnavailableAndTitlesDoNotExposeConversationContent() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([
                #"{"type":"user","cwd":"/Users/tester/Safe Project","message":{"content":"SECRET USER PROMPT"}}"#,
                #"{"type":"summary","summary":"SECRET CONVERSATION SUMMARY"}"#,
                try assistant("no-counters", usage: [:], includeAllCounters: false)
            ], profile: p, session: sessionA)
            let result = scan([p])
            let session = try XCTUnwrap(result.sessions.first)
            XCTAssertFalse(session.hasUsage)
            XCTAssertEqual(session.tokens.total, 0)
            XCTAssertEqual(session.projectPath, "/Users/tester/Safe Project")
            XCTAssertTrue(session.title.hasPrefix("Safe Project · "))
            XCTAssertFalse(session.title.contains("SECRET"))
            XCTAssertFalse(session.title.contains("PRIVATE"))
            XCTAssertFalse(result.truncated)
        }
    }

    func testOnlyImmediateProjectJSONLFilesAreIncludedAndSymlinksAreSkipped() throws {
        try fixture { root in
            let p = profile("one", root: root)
            let real = try write([try assistant("real", usage: ["input_tokens": 9])], profile: p, session: sessionA)
            try write([try assistant("nested-agent", usage: ["input_tokens": 999])], profile: p, session: sessionB,
                      project: "-Users-tester-project/subagents")
            try FileManager.default.createSymbolicLink(atPath: real.deletingLastPathComponent().appendingPathComponent("alias.jsonl").path,
                                                       withDestinationPath: real.path)
            let other = profile("outside", root: root)
            let outside = try write([try assistant("outside", usage: ["input_tokens": 1_000])], profile: other, session: sessionB)
            try FileManager.default.createSymbolicLink(atPath: URL(fileURLWithPath: p.configDirectory).appendingPathComponent("projects/linked-project").path,
                                                       withDestinationPath: outside.deletingLastPathComponent().path)
            let result = scan([p])
            XCTAssertEqual(result.sessions.count, 1)
            XCTAssertEqual(result.sessions.first?.filePath, real.path)
            XCTAssertEqual(result.totals.total, 9)
        }
    }

    func testExplicitlyImportedSymlinkRootWorksWithoutFollowingLinksBelowIt() throws {
        try fixture { root in
            let original = profile("original", root: root)
            let real = try write([try assistant("real", usage: ["input_tokens": 12])], profile: original, session: sessionA)
            let aliasPath = root.appendingPathComponent("imported-link")
            try FileManager.default.createSymbolicLink(atPath: aliasPath.path, withDestinationPath: original.configDirectory)
            let imported = Profile(command: "claude-imported", configDirectory: aliasPath.path)
            let originalServiceName = CredentialStore.serviceName(for: imported)
            try FileManager.default.createSymbolicLink(atPath: real.deletingLastPathComponent().appendingPathComponent("duplicate.jsonl").path,
                                                       withDestinationPath: real.path)
            let outside = profile("outside", root: root)
            let outsideFile = try write([try assistant("outside", usage: ["input_tokens": 999])], profile: outside, session: sessionB)
            try FileManager.default.createSymbolicLink(atPath: URL(fileURLWithPath: original.configDirectory).appendingPathComponent("projects/linked-project").path,
                                                       withDestinationPath: outsideFile.deletingLastPathComponent().path)
            let result = scan([imported])
            XCTAssertEqual(result.totals.total, 12)
            XCTAssertEqual(result.sessions.count, 1)
            XCTAssertEqual(result.sessions.first?.filePath, real.path)
            XCTAssertEqual(result.sessions.first?.profileCommand, imported.command)
            XCTAssertFalse(result.truncated)
            XCTAssertEqual(imported.configDirectory, aliasPath.path)
            XCTAssertEqual(CredentialStore.serviceName(for: imported), originalServiceName)
            XCTAssertNotEqual(CredentialStore.serviceName(for: imported), CredentialStore.serviceName(for: original))
            XCTAssertEqual(scan([imported, original]).totals.total, 12)
        }
    }

    func testSingleProfileProjectsRootSymlinkKeepsNormalAttribution() throws {
        try fixture { root in
            let source = profile("source", root: root)
            try write([try assistant("outside", usage: ["input_tokens": 999])], profile: source, session: sessionA)
            let target = profile("target", root: root)
            try FileManager.default.createDirectory(atPath: target.configDirectory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: URL(fileURLWithPath: target.configDirectory).appendingPathComponent("projects").path,
                                                       withDestinationPath: URL(fileURLWithPath: source.configDirectory).appendingPathComponent("projects").path)
            let result = scan([target])
            XCTAssertEqual(result.sessions.count, 1)
            XCTAssertEqual(result.totals.total, 999)
            XCTAssertEqual(result.profiles.map(\.command), [target.command])
            XCTAssertEqual(result.sessions.first?.profileCommand, target.command)
            XCTAssertFalse(result.hasSharedHistory)
        }
    }

    func testDefaultAndProfileProjectsLinksProduceOneSharedHistoryRow() throws {
        try fixture { root in
            let original = Profile(command: "claude", configDirectory: root.appendingPathComponent("default").path)
            try write([try assistant("shared-message", usage: ["input_tokens": 100, "output_tokens": 25])],
                      profile: original, session: sessionA)
            let personal = profile("personal", root: root)
            let work = profile("work", root: root)
            for alias in [personal, work] {
                try FileManager.default.createDirectory(atPath: alias.configDirectory, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: URL(fileURLWithPath: alias.configDirectory).appendingPathComponent("projects").path,
                                                           withDestinationPath: URL(fileURLWithPath: original.configDirectory).appendingPathComponent("projects").path)
            }
            let result = scan([original, personal, work])
            XCTAssertFalse(result.truncated)
            XCTAssertTrue(result.hasSharedHistory)
            XCTAssertEqual(result.totals.total, 125)
            XCTAssertEqual(result.sessions.count, 1)
            XCTAssertEqual(result.sessions.first?.profileCommand, SessionAnalytics.sharedProfileCommand)
            XCTAssertEqual(result.profiles.map(\.command), [SessionAnalytics.sharedProfileCommand])
            XCTAssertEqual(result.profiles.first?.tokens.total, 125)
            XCTAssertEqual(result.profiles.first?.sessions, 1)

            let independent = profile("independent", root: root)
            try write([try assistant("independent-message", usage: ["input_tokens": 10])], profile: independent, session: sessionB)
            let mixed = scan([original, work, personal, independent])
            XCTAssertEqual(mixed.totals.total, 135)
            XCTAssertEqual(Set(mixed.profiles.map(\.command)), [SessionAnalytics.sharedProfileCommand, independent.command])
            XCTAssertEqual(mixed.profiles.first(where: { $0.command == independent.command })?.tokens.total, 10)
        }
    }

    func testSevenAndThirtyDayChartsIncludeQuietCalendarDays() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([try assistant("active", usage: ["input_tokens": 7], timestamp: "2026-09-07T12:00:00Z")], profile: p, session: sessionA)
            let today = Calendar.current.startOfDay(for: now)
            for days in [7, 30] {
                let start = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -(days - 1), to: today))
                let result = scan([p], since: start)
                XCTAssertEqual(result.daily.count, days)
                XCTAssertEqual(result.daily.first?.day, start)
                XCTAssertEqual(result.daily.last?.day, today)
                XCTAssertEqual(result.daily.last?.tokens, 0)
                XCTAssertEqual(result.daily.filter { $0.tokens == 0 }.count, days - 1)
                XCTAssertEqual(result.daily.reduce(Int64(0)) { $0 + $1.tokens }, 7)
            }
        }
    }

    func testFutureLogRecordsAreFlaggedAndNeverCreateFutureBucketsOrRaiseTotals() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([
                try assistant("same-message", usage: ["input_tokens": 8]),
                try assistant("same-message", usage: ["input_tokens": 999], timestamp: "2026-09-09T12:00:00Z"),
                try assistant("future", usage: ["input_tokens": 999], timestamp: "2200-01-01T00:00:00Z")
            ], profile: p, session: sessionA)
            let result = scan([p])
            XCTAssertTrue(result.truncated)
            XCTAssertEqual(result.totals.total, 8)
            XCTAssertEqual(result.daily.last?.day, Calendar.current.startOfDay(for: now))
            XCTAssertTrue(result.daily.allSatisfy { $0.day <= now })
        }
    }

    func testMalformedOversizedAndInvalidTokenLinesAreSkippedWithIncompleteFlag() throws {
        try fixture { root in
            let p = profile("one", root: root)
            let long = String(repeating: "x", count: SessionAnalytics.maximumLineBytes + 1)
            try write([
                "{incomplete-json", long,
                try assistant("boolean", usage: ["input_tokens": false]),
                try assistant("negative", usage: ["input_tokens": -1]),
                try assistant("fraction", usage: ["output_tokens": 1.5]),
                try assistant("valid", usage: ["input_tokens": 8, "output_tokens": 2])
            ], profile: p, session: sessionA, trailingNewline: false)
            let result = scan([p])
            XCTAssertTrue(result.truncated)
            XCTAssertEqual(result.totals.total, 10)
            XCTAssertTrue(result.sessions.first?.hasUsage == true)
        }
    }

    func testMissingIdentityOrTimestampDoesNotInventUsageAttribution() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([
                try assistant(nil, usage: ["input_tokens": 999]),
                try assistant("bad-date", usage: ["input_tokens": 999], timestamp: "not-a-date"),
                try assistant(nil, usage: ["input_tokens": 2, "output_tokens": 1], request: "request-fallback"),
                try assistant(nil, usage: ["input_tokens": 2, "output_tokens": 5], request: "request-fallback")
            ], profile: p, session: sessionA)
            let result = scan([p])
            XCTAssertEqual(result.totals.total, 7)
            XCTAssertTrue(result.truncated)
        }
    }

    func testOverflowCannotCrashScannerOrWrapTotalsNegative() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([try assistant("large", usage: ["input_tokens": Int64.max, "output_tokens": Int64.max]),
                       try assistant("additional", usage: ["input_tokens": 2])], profile: p, session: sessionA)
            let result = scan([p])
            XCTAssertEqual(result.totals.input, Int64.max)
            XCTAssertEqual(result.totals.total, Int64.max)
            XCTAssertEqual(result.daily.last?.tokens, Int64.max)
        }
    }

    func testFullScanPassesOldFileLimitAndReportsCompleteByteCoverage() throws {
        try fixture { root in
            let p = profile("one", root: root)
            let progress = #"{"type":"progress","content":""# + String(repeating: "x", count: 17 * 1_048_576) + #""}"#
            let file = try write([
                try assistant("before", usage: ["input_tokens": 4]), progress,
                try assistant("after", usage: ["output_tokens": 8])
            ], profile: p, session: sessionA)
            let result = scan([p])
            XCTAssertFalse(result.truncated)
            XCTAssertEqual(result.totals.total, 12)
            XCTAssertEqual(result.scannedFiles, 1)
            XCTAssertEqual(result.eligibleFiles, 1)
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)
            XCTAssertEqual(result.scannedBytes, size.int64Value)
            XCTAssertGreaterThan(result.scannedBytes, 16 * 1_048_576)
        }
    }

    func testRecentUsageInRestoredFileWithOldMtimeIsStillCounted() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([try assistant("restored", usage: ["input_tokens": 11])], profile: p, session: sessionA,
                      modified: now.addingTimeInterval(-40 * 86_400))
            let result = scan([p])
            XCTAssertFalse(result.truncated)
            XCTAssertEqual(result.totals.total, 11)
            XCTAssertEqual(result.scannedFiles, result.eligibleFiles)
            XCTAssertEqual(result.eligibleFiles, 1)
        }
    }

    func testSubagentsAndWorkflowAgentsCountOnceAndFoldIntoParentSession() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([try assistant("parent", usage: ["input_tokens": 10]),
                       try assistant("shared", usage: ["input_tokens": 4])], profile: p, session: sessionA)
            let nested = "-Users-tester-project/\(sessionA)/subagents"
            try write([try assistant("child", usage: ["input_tokens": 20]),
                       try assistant("shared", usage: ["input_tokens": 6])], profile: p, session: "agent-fixture", project: nested)
            try write([try assistant("workflow", usage: ["input_tokens": 30])], profile: p, session: "agent-workflow",
                      project: nested + "/workflows/wf_fixture-123")
            try write([try assistant("unrelated", usage: ["input_tokens": 999])], profile: p, session: "ignored",
                      project: nested + "/arbitrary/deeper")
            let result = scan([p])
            XCTAssertFalse(result.truncated)
            XCTAssertEqual(result.totals.total, 66)
            XCTAssertEqual(result.subagentTokens.total, 56)
            XCTAssertEqual(result.sessions.count, 1)
            XCTAssertEqual(result.sessions.first?.sessionUUID, sessionA)
            XCTAssertEqual(result.sessions.first?.tokens.total, 66)
            XCTAssertEqual(result.profiles.first?.tokens.total, 66)
            XCTAssertEqual(result.scannedFiles, 3)
            XCTAssertEqual(result.eligibleFiles, 3)
        }
    }

    func testOrphanSubagentCountsInAggregateWithoutInventingAResumeRow() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([try assistant("orphan", usage: ["input_tokens": 15])], profile: p, session: "agent-orphan",
                      project: "-Users-tester-project/\(sessionA)/subagents")
            let result = scan([p])
            XCTAssertEqual(result.totals.total, 15)
            XCTAssertEqual(result.subagentTokens.total, 15)
            XCTAssertEqual(result.profiles.first?.tokens.total, 15)
            XCTAssertTrue(result.sessions.isEmpty)
            XCTAssertEqual(result.profiles.first?.sessions, 0)
        }
    }

    func testLargeUnicodeEscapedUsageKeyIsNotLostToFastPrefilter() throws {
        try fixture { root in
            let p = profile("one", root: root)
            let object: [String: Any] = ["type": "assistant", "timestamp": "2026-09-08T12:00:00Z",
                "message": ["id": "escaped", "content": String(repeating: "x", count: 5_000),
                            "usage": ["input_tokens": 9, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]]]
            let escaped = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                .replacingOccurrences(of: "\"usage\"", with: "\"\\u0075sage\"")
            try write([try assistant("initial-metadata", usage: ["input_tokens": 6]), escaped], profile: p, session: sessionA)
            let result = scan([p])
            XCTAssertFalse(result.truncated)
            XCTAssertEqual(result.totals.total, 15)
        }
    }

    func testMissingCountersMarkAvailableTotalsAsIncomplete() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([try assistant("partial-counters", usage: ["input_tokens": 3, "output_tokens": 2], includeAllCounters: false)],
                      profile: p, session: sessionA)
            let result = scan([p])
            XCTAssertTrue(result.truncated)
            XCTAssertEqual(result.totals.total, 5)
            XCTAssertEqual(result.scannedFiles, 1)
            XCTAssertEqual(result.eligibleFiles, 1)
        }
    }

    /// Each step compares a scan that reuses one persisted cache with a scan from scratch.
    func testIncrementalScanMatchesFullScanThroughAppendsRewritesReplacementsAndDeletes() throws {
        try fixture { root in
            let p = profile("one", root: root)
            let cacheURL = root.appendingPathComponent("cache/analytics-v1.bin")
            var cache = SessionAnalyticsCache(url: cacheURL)
            let since = now.addingTimeInterval(-7 * 86_400)
            func check(_ step: String, since period: Date? = nil, file: StaticString = #filePath, line: UInt = #line) {
                let full = SessionAnalytics.scan(profiles: [p], since: period ?? since, now: now)
                let incremental = SessionAnalytics.scan(profiles: [p], since: period ?? since, now: now, cache: cache)
                XCTAssertEqual(incremental, full, step, file: file, line: line)
            }
            func append(_ text: String, to url: URL) throws {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
                try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            }
            let a = try write([try assistant("shared", usage: ["input_tokens": 10], timestamp: "2026-09-08T10:00:00Z"),
                               try assistant("a1", usage: ["output_tokens": 5], timestamp: "2026-08-20T10:00:00Z")],
                              profile: p, session: sessionA, created: now.addingTimeInterval(-7_200))
            // The same message copied into a second file counts once, owned by the older copy.
            let b = try write([try assistant("shared", usage: ["input_tokens": 12], timestamp: "2026-09-08T10:00:00Z")],
                              profile: p, session: sessionB, created: now.addingTimeInterval(-3_600))
            check("initial files")
            check("unchanged files, warm cache")
            XCTAssertLessThan(cache.lastReadBytes, 1_024, "an unchanged history is not read again")
            try append(try assistant("a2", usage: ["input_tokens": 7], timestamp: "2026-09-07T10:00:00Z") + "\n", to: a)
            check("appended line")
            let partial = try assistant("b2", usage: ["output_tokens": 9], timestamp: "2026-09-08T11:00:00Z")
            try append(String(partial.prefix(40)), to: b)
            check("unfinished final line")
            try append(String(partial.dropFirst(40)), to: b)
            check("completed final line without a newline")
            try append("\n", to: b)
            check("final line terminated")
            try append("{not json}\n", to: b)
            check("invalid complete line")
            let handle = try FileHandle(forWritingTo: a)
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data((try assistant("a3", usage: ["input_tokens": 3]) + "\n").utf8)); try handle.close()
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: a.path)
            check("file rewritten in place")
            try write([try assistant("b3", usage: ["input_tokens": 4])], profile: p, session: sessionB, created: now.addingTimeInterval(-600))
            check("file replaced with a new inode")
            try FileManager.default.removeItem(at: a)
            check("file deleted")
            try write([try assistant("c1", usage: ["cache_read_input_tokens": 40], timestamp: "2026-08-01T10:00:00Z"),
                       try assistant("b3", usage: ["input_tokens": 6])],
                      profile: p, session: "33333333-3333-4333-8333-333333333333")
            check("new file")
            check("longer period", since: now.addingTimeInterval(-60 * 86_400))
            check("period that excludes older records", since: now.addingTimeInterval(-3_600))
            cache = SessionAnalyticsCache(url: cacheURL)
            check("cache reloaded from disk")
            XCTAssertLessThan(cache.lastReadBytes, 1_024)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int, 0o600)
            try Data("not a cache".utf8).write(to: cacheURL)
            cache = SessionAnalyticsCache(url: cacheURL)
            check("corrupt cache file is rebuilt")
        }
    }

    func testCachedRecordsRoundTrip() {
        let records = [SessionAnalyticsCache.Record(flags: 9, time: 12.5, tokens: TokenTotals(input: 1, output: Int64.max), identity: "message:é"),
                       SessionAnalyticsCache.Record(flags: 1, time: 0, tokens: TokenTotals(), identity: nil)]
        XCTAssertEqual(SessionAnalyticsCache.unpack(SessionAnalyticsCache.pack(records)), records)
        XCTAssertNil(SessionAnalyticsCache.unpack(Data([1, 2, 3])))
    }

    func testUnfinishedLiveTailDoesNotInvalidateCompleteUsageRecords() throws {
        try fixture { root in
            let p = profile("one", root: root)
            try write([try assistant("complete", usage: ["input_tokens": 15]), #"{"type":"assistant","message":{"#],
                      profile: p, session: sessionA, trailingNewline: false)
            let result = scan([p])
            XCTAssertFalse(result.truncated)
            XCTAssertEqual(result.totals.total, 15)
            XCTAssertEqual(result.scannedFiles, 1)
        }
    }

    func testFrozenHistoricalUpperBoundExcludesLaterValidRecordsWithoutPartialFlag() throws {
        try fixture { root in
            let p = profile("one", root: root)
            let through = Date().addingTimeInterval(-3_600)
            let formatter = ISO8601DateFormatter()
            try write([
                try assistant("included", usage: ["input_tokens": 3], timestamp: formatter.string(from: through.addingTimeInterval(-60))),
                try assistant("after-cutoff", usage: ["input_tokens": 99], timestamp: formatter.string(from: through.addingTimeInterval(60)))
            ], profile: p, session: sessionA)
            let result = SessionAnalytics.scan(profiles: [p], since: through.addingTimeInterval(-86_400), now: through)
            XCTAssertFalse(result.truncated)
            XCTAssertEqual(result.totals.total, 3)
        }
    }

    func testMissingAndUnresolvedProfilesReturnNoInventedSessions() throws {
        try fixture { root in
            let missing = profile("missing", root: root)
            let unresolved = Profile(command: "claude-unresolved", configDirectory: "")
            let result = scan([missing, unresolved])
            XCTAssertTrue(result.sessions.isEmpty)
            XCTAssertEqual(result.daily.count, 8)
            XCTAssertTrue(result.daily.allSatisfy { $0.tokens == 0 })
            XCTAssertTrue(result.profiles.isEmpty)
            XCTAssertEqual(result.totals.total, 0)
            XCTAssertFalse(result.truncated)
        }
    }
}

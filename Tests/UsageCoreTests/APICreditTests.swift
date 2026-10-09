import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import UsageCore

/// Console credit for API-key profiles: amounts, Claude Code's OTLP `api_request` events, the
/// ledger, the session-total cross-check, the launch environment, and how a balance is shown.
final class APICreditTests: XCTestCase {
    /// A sanitized OTLP/HTTP JSON export captured from Claude Code 2.1.295; shared with credit_e2e.py.
    private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("CLIIntegration/otlp_logs_fixture.json")
    private let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    private func withHome(_ action: (String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-credit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try action(home.path)
    }

    private func ledger(_ home: String) -> URL {
        ProfileStore.directory(home: home).appendingPathComponent("api-credit.json")
    }

    private func request(_ cost: Double, at offset: TimeInterval, session: String = "S", id: String = UUID().uuidString) -> APICreditRequest {
        APICreditRequest(id: id, sessionID: session, at: asOf.addingTimeInterval(offset), costUSD: cost, model: "claude-test")
    }

    private func status(_ balance: String, _ spent: String) -> APICreditStatus {
        APICreditStatus(balance: Decimal(string: balance)!, spent: Decimal(string: spent)!, asOf: asOf)
    }

    /// The fixture with its log records edited.
    private func body(_ edit: (inout [[String: Any]]) -> Void) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var resources = try XCTUnwrap(root["resourceLogs"] as? [[String: Any]])
        var scopes = try XCTUnwrap(resources[0]["scopeLogs"] as? [[String: Any]])
        var records = try XCTUnwrap(scopes[0]["logRecords"] as? [[String: Any]])
        edit(&records)
        scopes[0]["logRecords"] = records
        resources[0]["scopeLogs"] = scopes
        root["resourceLogs"] = resources
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func set(_ record: inout [String: Any], _ key: String, _ value: [String: Any]?) {
        var attributes = record["attributes"] as? [[String: Any]] ?? []
        if let index = attributes.firstIndex(where: { $0["key"] as? String == key }) {
            if let value { attributes[index]["value"] = value } else { attributes.remove(at: index) }
        } else if let value {
            attributes.append(["key": key, "value": value])
        }
        record["attributes"] = attributes
    }

    private func isAPIRequest(_ record: [String: Any]) -> Bool {
        (record["attributes"] as? [[String: Any]] ?? []).contains {
            $0["key"] as? String == "event.name" && ($0["value"] as? [String: Any])?["stringValue"] as? String == "api_request"
        }
    }

    private func claudeState(_ projects: [String: [String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["numStartups": 3, "projects": projects])
    }

    private func entry(cost: Double, start: Date, session: String) -> [String: Any] {
        ["lastCost": cost, "lastStartTime": Int((start.timeIntervalSince1970 * 1000).rounded()), "lastSessionId": session, "lastDuration": 1000]
    }

    // MARK: Amounts

    func testAmountsAcceptZeroToOneMillionWithUpToTwoDecimals() throws {
        XCTAssertEqual(try APICreditAmount.parse("200"), 200)
        XCTAssertEqual(try APICreditAmount.parse("187.42"), Decimal(string: "187.42"))
        XCTAssertEqual(try APICreditAmount.parse("0"), 0)
        XCTAssertEqual(try APICreditAmount.parse("0.5"), Decimal(string: "0.5"))
        XCTAssertEqual(try APICreditAmount.parse("007.10"), Decimal(string: "7.1"))
        XCTAssertEqual(try APICreditAmount.parse("1000000"), 1_000_000)
        XCTAssertEqual(try APICreditAmount.parse("1000000.00"), 1_000_000)
    }

    func testAmountsRejectEverythingElse() {
        for text in ["-1", "-0.01", "abc", "1.234", "1000000.01", "2000000", "1e3", "12,50", "", " 200", "200 ", "$200",
                     ".5", "5.", "0x10", "NaN", "inf", "１００", "1 000", "+5"] {
            XCTAssertThrowsError(try APICreditAmount.parse(text), text) { XCTAssertEqual($0 as? APICreditError, .invalidAmount, text) }
        }
        XCTAssertTrue(APICreditError.invalidAmount.localizedDescription.contains("at most two decimals"))
    }

    // MARK: Claude Code's OTLP events

    func testExtractsTheAPIRequestsOfAClaudeCodeExport() throws {
        let requests = APICreditEvents.requests(fromOTLPJSON: try Data(contentsOf: fixture))
        XCTAssertEqual(requests.map(\.costUSD), [0.00032136, 0.0013358250000000001])
        XCTAssertEqual(requests.map(\.sessionID), Array(repeating: "8aa2d6b7-ee16-0ecb-c67c-f917d0c20294", count: 2))
        XCTAssertEqual(requests.map(\.model), ["claude-haiku-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(requests[0].at.timeIntervalSince1970, 1_791_513_632.290, accuracy: 0.0005)
        XCTAssertEqual(requests[1].at.timeIntervalSince1970, 1_791_513_632.952, accuracy: 0.0005)
        XCTAssertEqual(requests, APICreditEvents.requests(fromOTLPJSON: try Data(contentsOf: fixture)), "identities are stable")
    }

    func testIdentityIsSessionSequenceTimestampAndRequestIDs() throws {
        let requests = APICreditEvents.requests(fromOTLPJSON: try Data(contentsOf: fixture))
        let fields = ["8aa2d6b7-ee16-0ecb-c67c-f917d0c20294", "9", "2026-10-09T02:40:32.290Z", "req_011Cfixture0ece23a490",
                      "9ccce409-5b34-a914-f845-55309feed603"]
        let expected = SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(requests.first?.id, expected)
        // Attributes outside the identity do not change it; one inside does.
        let retimed = APICreditEvents.requests(fromOTLPJSON: try body { records in
            for index in records.indices { set(&records[index], "duration_ms", ["intValue": 1]) }
        })
        XCTAssertEqual(retimed.map(\.id), requests.map(\.id))
        let other = APICreditEvents.requests(fromOTLPJSON: try body { records in
            for index in records.indices { set(&records[index], "request_id", ["stringValue": "req_other"]) }
        })
        XCTAssertEqual(other.count, 2)
        XCTAssertTrue(Set(other.map(\.id)).isDisjoint(with: requests.map(\.id)))
    }

    func testIgnoresOtherEventsAndMalformedRecords() throws {
        XCTAssertEqual(APICreditEvents.requests(fromOTLPJSON: Data("not json".utf8)), [])
        XCTAssertEqual(APICreditEvents.requests(fromOTLPJSON: Data(#"{"resourceLogs":"wrong"}"#.utf8)), [])
        XCTAssertEqual(APICreditEvents.requests(fromOTLPJSON: Data(#"[1,2,3]"#.utf8)), [])
        let onlyOthers = try body { records in records.removeAll(where: isAPIRequest) }
        XCTAssertEqual(APICreditEvents.requests(fromOTLPJSON: onlyOthers), [])
        let edits: [(String, (inout [String: Any]) -> Void)] = [
            ("no cost", { self.set(&$0, "cost_usd", nil); self.set(&$0, "cost_usd_micros", nil) }),
            ("negative cost", { self.set(&$0, "cost_usd", ["doubleValue": -0.5]) }),
            ("text cost", { self.set(&$0, "cost_usd", ["stringValue": "0.5"]) }),
            ("no session", { self.set(&$0, "session.id", nil) }),
            ("empty session", { self.set(&$0, "session.id", ["stringValue": ""]) }),
            ("no time", { self.set(&$0, "event.timestamp", nil); $0["timeUnixNano"] = nil; $0["observedTimeUnixNano"] = nil }),
            ("attributes not a list", { $0["attributes"] = ["cost_usd": 1] })]
        for (label, edit) in edits {
            let data = try body { records in
                for index in records.indices where isAPIRequest(records[index]) { edit(&records[index]) }
            }
            XCTAssertEqual(APICreditEvents.requests(fromOTLPJSON: data), [], label)
        }
    }

    func testAcceptsTheOTLPJSONVariantsOfNumbersAndTimes() throws {
        let data = try body { records in
            for index in records.indices where isAPIRequest(records[index]) {
                set(&records[index], "event.sequence", ["intValue": "9"])
                set(&records[index], "cost_usd", nil)
                set(&records[index], "cost_usd_micros", ["intValue": "1336"])
                set(&records[index], "event.timestamp", nil)
            }
        }
        let requests = APICreditEvents.requests(fromOTLPJSON: data)
        XCTAssertEqual(requests.map(\.costUSD), [0.001336, 0.001336])
        XCTAssertEqual(requests[0].at.timeIntervalSince1970, 1_791_513_632.290, accuracy: 0.0005, "falls back to timeUnixNano")
        let integer = try body { records in
            for index in records.indices where isAPIRequest(records[index]) { set(&records[index], "cost_usd", ["intValue": 2]) }
        }
        XCTAssertEqual(APICreditEvents.requests(fromOTLPJSON: integer).map(\.costUSD), [2, 2])
    }

    // MARK: Ledger

    func testSettingCreditStartsAnAccountAndRepeatedEventsCountOnce() throws {
        try withHome { home in
            XCTAssertNil(try APICreditStore.status(profileID: "P", home: home))
            try APICreditStore.setBalance(200, profileID: "P", home: home, now: asOf)
            let requests = [request(0.0123, at: 1), request(1.5, at: 2), request(0.25, at: 3)]
            XCTAssertEqual(try APICreditStore.record(requests, profileID: "P", home: home), 3)
            XCTAssertEqual(try APICreditStore.record(requests + [requests[0]], profileID: "P", home: home), 0)
            let status = try XCTUnwrap(APICreditStore.status(profileID: "P", home: home))
            XCTAssertEqual(status.spent, Decimal(string: "1.7623"))
            XCTAssertEqual(status.balance, 200)
            XCTAssertEqual(status.asOf, asOf)
            XCTAssertEqual(status.usageWindow, "Credit · $198.24 of $200.00 left")
            XCTAssertEqual(status.usedPercentText, "0.88")

            var info = stat()
            XCTAssertEqual(lstat(ledger(home).path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ledger(home))) as? [String: Any])
            XCTAssertEqual(stored["version"] as? Int, 1)
            let account = try XCTUnwrap((stored["profiles"] as? [String: Any])?["P"] as? [String: Any])
            XCTAssertEqual(account["balanceUSD"] as? Double, 200)
            XCTAssertEqual(((account["requests"] as? [[String: Any]]) ?? []).compactMap { $0["costUSD"] as? Double }, [0.0123, 1.5, 0.25])
        }
    }

    func testEventsBeforeAsOfAndForProfilesWithoutCreditAreNotCounted() throws {
        try withHome { home in
            XCTAssertEqual(try APICreditStore.record([request(1, at: 1)], profileID: "P", home: home), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledger(home).path), "no credit, no ledger")
            try APICreditStore.setBalance(150, profileID: "P", home: home, now: asOf)
            XCTAssertEqual(try APICreditStore.record([request(5, at: -120), request(2, at: 1)], profileID: "P", home: home), 1)
            XCTAssertEqual(try APICreditStore.status(profileID: "P", home: home)?.spent, 2)
            XCTAssertEqual(try APICreditStore.record([request(3, at: 1)], profileID: "Q", home: home), 0)
            XCTAssertNil(try APICreditStore.status(profileID: "Q", home: home))
        }
    }

    func testSettingAgainPrunesEverythingBeforeTheNewAsOf() throws {
        try withHome { home in
            try APICreditStore.setBalance(200, profileID: "P", home: home, now: asOf)
            try APICreditStore.setBalance(80, profileID: "Q", home: home, now: asOf)
            _ = try APICreditStore.record([request(1, at: 10, session: "S")], profileID: "P", home: home)
            _ = try APICreditStore.record([request(4, at: 10)], profileID: "Q", home: home)
            let state = try claudeState(["/w": entry(cost: 3, start: asOf.addingTimeInterval(5), session: "S")])
            _ = try APICreditStore.reconcile(profileID: "P", home: home, claudeState: state, spawn: asOf.addingTimeInterval(4),
                                             exit: asOf.addingTimeInterval(20), capturedSessions: ["S"], now: asOf.addingTimeInterval(20))
            XCTAssertEqual(try APICreditStore.status(profileID: "P", home: home)?.spent, 3)
            let later = asOf.addingTimeInterval(60)
            let reset = try APICreditStore.setBalance(Decimal(string: "187.42")!, profileID: "P", home: home, now: later)
            XCTAssertEqual(reset.spent, 0)
            XCTAssertEqual(reset.usageWindow, "Credit · $187.42 of $187.42 left")
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ledger(home))) as? [String: Any])
            let account = try XCTUnwrap((stored["profiles"] as? [String: Any])?["P"] as? [String: Any])
            XCTAssertEqual((account["requests"] as? [Any])?.count, 0)
            XCTAssertEqual((account["adjustments"] as? [Any])?.count, 0)
            XCTAssertEqual(account["balanceUSD"] as? Double, 187.42)
            XCTAssertEqual(try APICreditStore.status(profileID: "Q", home: home)?.spent, 4, "other profiles keep their spend")
        }
    }

    func testParallelWritersKeepEveryRequest() throws {
        try withHome { home in
            try APICreditStore.setBalance(100, profileID: "P", home: home, now: asOf)
            let failures = NSLock()
            var failed = 0
            DispatchQueue.concurrentPerform(iterations: 48) { index in
                do { _ = try APICreditStore.record([request(0.01, at: Double(index + 1), id: "r\(index)")], profileID: "P", home: home) }
                catch { failures.lock(); failed += 1; failures.unlock() }
            }
            XCTAssertEqual(failed, 0)
            XCTAssertEqual(try APICreditStore.status(profileID: "P", home: home)?.spent, Decimal(string: "0.48"))
        }
    }

    func testAnUnreadableLedgerIsAnErrorAndSettingCreditMovesItAside() throws {
        try withHome { home in
            try APICreditStore.setBalance(100, profileID: "P", home: home, now: asOf)
            try Data("{ not json".utf8).write(to: ledger(home))
            XCTAssertThrowsError(try APICreditStore.status(profileID: "P", home: home)) { XCTAssertEqual($0 as? APICreditError, .ledgerUnreadable) }
            XCTAssertThrowsError(try APICreditStore.record([request(1, at: 1)], profileID: "P", home: home))
            try APICreditStore.setBalance(50, profileID: "P", home: home, now: asOf.addingTimeInterval(1))
            XCTAssertEqual(try APICreditStore.status(profileID: "P", home: home)?.balance, 50)
            let directory = try FileManager.default.contentsOfDirectory(atPath: ProfileStore.directory(home: home).path)
            XCTAssertEqual(directory.filter { $0.hasPrefix("api-credit.unreadable-") }.count, 1, "the unreadable file is kept")

            try FileManager.default.removeItem(at: ledger(home))
            try FileManager.default.createSymbolicLink(atPath: ledger(home).path, withDestinationPath: "/dev/null")
            XCTAssertThrowsError(try APICreditStore.status(profileID: "P", home: home)) { XCTAssertEqual($0 as? APICreditError, .ledgerUnreadable) }
            try FileManager.default.removeItem(at: ledger(home))
            try Data(#"{"version":2,"profiles":{}}"#.utf8).write(to: ledger(home))
            XCTAssertThrowsError(try APICreditStore.status(profileID: "P", home: home)) { XCTAssertEqual($0 as? APICreditError, .ledgerUnreadable) }
        }
    }

    // MARK: Session-total cross-check

    func testALargerSessionTotalAddsTheDifferenceOnce() throws {
        try withHome { home in
            try APICreditStore.setBalance(100, profileID: "P", home: home, now: asOf)
            let spawn = asOf.addingTimeInterval(60), exit = asOf.addingTimeInterval(120)
            _ = try APICreditStore.record([request(0.1, at: 65), request(0.2, at: 66)], profileID: "P", home: home)
            let state = try claudeState(["/elsewhere": entry(cost: 9, start: asOf.addingTimeInterval(-500), session: "OLD"),
                                         "/work": entry(cost: 0.8, start: spawn.addingTimeInterval(0.01), session: "S")])
            for _ in 0..<2 {
                let adjustment = try APICreditStore.reconcile(profileID: "P", home: home, claudeState: state, spawn: spawn, exit: exit,
                                                              capturedSessions: ["S"], now: exit)
                XCTAssertEqual(adjustment?.kind, "session-total")
                XCTAssertEqual(adjustment?.sessionID, "S")
                XCTAssertEqual(adjustment?.amountUSD ?? 0, 0.5, accuracy: 1e-12)
                XCTAssertEqual(try APICreditStore.status(profileID: "P", home: home)?.spent, Decimal(string: "0.8"))
            }
        }
    }

    func testTheCrossCheckNeverSubtractsOrGuesses() throws {
        try withHome { home in
            try APICreditStore.setBalance(100, profileID: "P", home: home, now: asOf)
            let spawn = asOf.addingTimeInterval(60), exit = asOf.addingTimeInterval(120)
            _ = try APICreditStore.record([request(0.3, at: 65)], profileID: "P", home: home)
            let cases: [(String, [String: [String: Any]], Set<String>)] = [
                ("smaller lastCost", ["/w": entry(cost: 0.1, start: spawn.addingTimeInterval(0.01), session: "S")], ["S"]),
                ("equal lastCost", ["/w": entry(cost: 0.3, start: spawn.addingTimeInterval(0.01), session: "S")], ["S"]),
                ("resumed session started before the run", ["/w": entry(cost: 2, start: spawn.addingTimeInterval(-3600), session: "S")], ["S"]),
                ("started after the run", ["/w": entry(cost: 2, start: exit.addingTimeInterval(5), session: "S")], ["S"]),
                ("another process's session", ["/w": entry(cost: 2, start: spawn.addingTimeInterval(1), session: "T")], ["S"]),
                ("no cost recorded", ["/w": ["lastSessionId": "S", "lastStartTime": Int(spawn.timeIntervalSince1970 * 1000) + 10]], ["S"])]
            for (label, projects, captured) in cases {
                let adjustment = try APICreditStore.reconcile(profileID: "P", home: home, claudeState: try claudeState(projects),
                                                              spawn: spawn, exit: exit, capturedSessions: captured, now: exit)
                XCTAssertNil(adjustment, label)
                XCTAssertEqual(try APICreditStore.status(profileID: "P", home: home)?.spent, Decimal(string: "0.3"), label)
            }
            for invalid in [Data("garbage".utf8), Data(#"{"projects": []}"#.utf8)] {
                XCTAssertNil(try APICreditStore.reconcile(profileID: "P", home: home, claudeState: invalid, spawn: spawn, exit: exit,
                                                          capturedSessions: ["S"], now: exit))
            }
        }
    }

    func testASessionStartedBeforeAsOfIsNotCrossChecked() throws {
        try withHome { home in
            let spawn = asOf.addingTimeInterval(-30), exit = asOf.addingTimeInterval(30)
            try APICreditStore.setBalance(100, profileID: "P", home: home, now: asOf)
            _ = try APICreditStore.record([request(0.1, at: 10)], profileID: "P", home: home)
            let state = try claudeState(["/w": entry(cost: 5, start: spawn.addingTimeInterval(0.01), session: "S")])
            XCTAssertNil(try APICreditStore.reconcile(profileID: "P", home: home, claudeState: state, spawn: spawn, exit: exit,
                                                      capturedSessions: ["S"], now: exit))
            XCTAssertEqual(try APICreditStore.status(profileID: "P", home: home)?.spent, Decimal(string: "0.1"))
        }
    }

    func testARunThatCapturedNothingUsesTheOneEntryThatStartedWithIt() throws {
        try withHome { home in
            try APICreditStore.setBalance(100, profileID: "P", home: home, now: asOf)
            let spawn = asOf.addingTimeInterval(60), exit = asOf.addingTimeInterval(120)
            let single = try claudeState(["/w": entry(cost: 0.7, start: spawn.addingTimeInterval(0.2), session: "U")])
            let adjustment = try APICreditStore.reconcile(profileID: "P", home: home, claudeState: single, spawn: spawn, exit: exit,
                                                          capturedSessions: [], now: exit)
            XCTAssertEqual(adjustment?.amountUSD ?? 0, 0.7, accuracy: 1e-12)
            let ambiguous = try claudeState(["/a": entry(cost: 0.7, start: spawn.addingTimeInterval(0.2), session: "U"),
                                             "/b": entry(cost: 0.9, start: spawn.addingTimeInterval(0.4), session: "V")])
            XCTAssertNil(try APICreditStore.reconcile(profileID: "P", home: home, claudeState: ambiguous, spawn: spawn, exit: exit,
                                                      capturedSessions: [], now: exit))
            let late = try claudeState(["/w": entry(cost: 0.9, start: spawn.addingTimeInterval(40), session: "W")])
            XCTAssertNil(try APICreditStore.reconcile(profileID: "P", home: home, claudeState: late, spawn: spawn, exit: exit,
                                                      capturedSessions: [], now: exit), "a session that began well after the launch")
            XCTAssertEqual(try APICreditStore.status(profileID: "P", home: home)?.spent, Decimal(string: "0.7"))
        }
    }

    // MARK: Display

    func testUsageRowFormatting() {
        XCTAssertEqual(APICreditStatus.plan, "Console API")
        XCTAssertEqual(status("200", "1.7623").usageWindow, "Credit · $198.24 of $200.00 left")
        XCTAssertEqual(status("200", "1.7623").usedPercentText, "0.88")
        XCTAssertEqual(status("200", "12.58").usageWindow, "Credit · $187.42 of $200.00 left")
        XCTAssertEqual(status("200", "12.58").usedPercentText, "6.29")
        XCTAssertEqual(status("200", "0").usedPercentText, "0.00")
        XCTAssertEqual(status("200", "203").usageWindow, "Credit · $0.00 of $200.00 left")
        XCTAssertEqual(status("200", "203").usedPercentText, "101.50")
        XCTAssertEqual(status("0", "0").usedPercentText, "100.00")
        XCTAssertEqual(status("1000000", "1234.5").usageWindow, "Credit · $998,765.50 of $1,000,000.00 left")
        XCTAssertEqual(status("10", "0.005").leftText, "$10.00")
        XCTAssertEqual(status("10", "0.015").leftText, "$9.99", "what is left rounds half up to the cent")
        XCTAssertEqual(status("200", "1.7623").fraction, 0.0088115, accuracy: 1e-9)
        XCTAssertEqual(status("200", "300").fraction, 1)
        XCTAssertEqual(status("0", "0").fraction, 1)
    }

    func testLowCreditIsBelowTenPercentOrFiveDollarsLeft() {
        XCTAssertFalse(status("200", "180").isLow, "exactly 10% left")
        XCTAssertTrue(status("200", "180.01").isLow)
        XCTAssertFalse(status("40", "35").isLow, "exactly $5 left, 12.5%")
        XCTAssertTrue(status("40", "35.01").isLow)
        XCTAssertTrue(status("1000", "995").isLow, "$5 left of $1,000 is below 10%")
        XCTAssertTrue(status("3", "0").isLow)
        XCTAssertTrue(status("0", "0").isLow)
        XCTAssertTrue(status("100", "150").isLow)
        XCTAssertFalse(status("200", "12.58").isLow)
    }

    // MARK: Launch

    func testCaptureEnvironmentReplacesInheritedTelemetrySettings() {
        let inherited = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-ant-api03-synthetic", "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "grpc",
                         "OTEL_METRICS_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_ENDPOINT": "http://example.invalid", "OTEL_LOG_USER_PROMPTS": "1",
                         "CLAUDE_CODE_ENABLE_TELEMETRY": "0", "CLAUDE_CONFIG_DIR": "/tmp/account"]
        XCTAssertEqual(APICreditCapture.environment(inherited, port: 49152), [
            "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-ant-api03-synthetic", "CLAUDE_CONFIG_DIR": "/tmp/account",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_LOGS_EXPORTER": "otlp", "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://127.0.0.1:49152/v1/logs",
            "OTEL_LOGS_EXPORT_INTERVAL": "1000"])
    }

    func testSettingsThatOverrideTheTelemetrySettingsAreNamed() throws {
        try withHome { home in
            let config = URL(fileURLWithPath: home).appendingPathComponent("config"), project = URL(fileURLWithPath: home).appendingPathComponent("project")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            XCTAssertEqual(APICreditCapture.overridingSettings(configDirectory: config.path, workingDirectory: project.path, managedSettings: []), [])
            try Data(#"{"env":{"OTEL_EXPORTER_OTLP_LOGS_ENDPOINT":"http://collector:4318/v1/logs","DEBUG":"1"}}"#.utf8)
                .write(to: config.appendingPathComponent("settings.json"))
            try Data(#"{"permissions":{}}"#.utf8).write(to: config.appendingPathComponent("settings.local.json"))
            try Data(#"{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"0"}}"#.utf8).write(to: project.appendingPathComponent(".claude/settings.local.json"))
            let managed = URL(fileURLWithPath: home).appendingPathComponent("managed-settings.json")
            try Data(#"{"env":{"OTEL_LOGS_EXPORTER":"none"}}"#.utf8).write(to: managed)
            let found = APICreditCapture.overridingSettings(configDirectory: config.path, workingDirectory: project.path, managedSettings: [managed.path])
            XCTAssertEqual(found.map(\.key), ["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "CLAUDE_CODE_ENABLE_TELEMETRY", "OTEL_LOGS_EXPORTER"])
            XCTAssertEqual(found.map(\.file), [config.appendingPathComponent("settings.json").path,
                                               project.appendingPathComponent(".claude/settings.local.json").path, managed.path])
        }
    }

    func testReceiverAnswers200AndPassesOnlyBoundedBodies() throws {
        let received = NSLock()
        var bodies: [Data] = []
        let receiver = try APICreditReceiver(maximumBody: 1024) { body in received.lock(); bodies.append(body); received.unlock() }
        defer { receiver.stop() }
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = receiver.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        func exchange(_ request: Data) -> String {
            _ = request.withUnsafeBytes { send(socket, $0.baseAddress, $0.count, 0) }
            var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while !(String(data: response, encoding: .utf8) ?? "").contains("\r\n\r\n{}") {
                let count = recv(socket, &buffer, buffer.count, 0)
                if count <= 0 { break }
                response.append(contentsOf: buffer.prefix(count))
            }
            return String(data: response, encoding: .utf8) ?? ""
        }
        func post(_ body: Data, chunked: Bool = false) -> Data {
            var head = "POST /v1/logs HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            guard chunked else { return Data((head + "Content-Length: \(body.count)\r\n\r\n").utf8) + body }
            head += "Transfer-Encoding: chunked\r\n\r\n"
            let half = body.count / 2
            return Data(head.utf8) + Data(String(half, radix: 16).utf8) + Data("\r\n".utf8) + body.prefix(half) + Data("\r\n".utf8)
                + Data(String(body.count - half, radix: 16).utf8) + Data("\r\n".utf8) + body.suffix(body.count - half) + Data("\r\n0\r\n\r\n".utf8)
        }
        // One keep-alive connection, like the exporter's: a body, an oversized body, garbage, and a chunked body.
        XCTAssertTrue(exchange(post(Data(#"{"a":1}"#.utf8))).hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(exchange(post(Data(repeating: 0x20, count: 4096))).hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(exchange(post(Data("garbage".utf8))).hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(exchange(post(Data(#"{"b":2}"#.utf8), chunked: true)).hasPrefix("HTTP/1.1 200 OK"))
        receiver.stop()
        XCTAssertEqual(bodies, [Data(#"{"a":1}"#.utf8), Data("garbage".utf8), Data(#"{"b":2}"#.utf8)])
    }
}

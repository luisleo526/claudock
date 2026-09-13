import Foundation
import Darwin
import XCTest
@testable import UsageCore

final class SubscriptionConfigurationTests: XCTestCase {
    private func fixture(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-subscription-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }

    private func write(_ object: [String: Any], root: URL, name: String = "settings.json") throws {
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent(name))
    }

    private func assertUnsupported(_ root: URL, forbiddenText: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SubscriptionConfiguration.validate(configDirectory: root.path), file: file, line: line) { error in
            guard case .unsupported(let message) = error as? MonitorError else {
                XCTFail("Expected sanitized unsupported error", file: file, line: line)
                return
            }
            XCTAssertTrue(message.contains("Pro, Max, Team, or Enterprise"), file: file, line: line)
            XCTAssertFalse(message.contains(root.path), file: file, line: line)
            if let forbiddenText { XCTAssertFalse(message.contains(forbiddenText), file: file, line: line) }
        }
    }

    func testMissingSettingsAndNewConfigDirectoryAreAllowedWithoutWrites() throws {
        try fixture { root in
            try SubscriptionConfiguration.validate(configDirectory: root.path)
            let missing = root.appendingPathComponent("not-created")
            try SubscriptionConfiguration.validate(configDirectory: missing.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testOrdinarySettingsAndEmptySelectorsAreAllowed() throws {
        try fixture { root in
            try write(["model": "sonnet", "permissions": ["allow": []], "env": [:]], root: root)
            try write(["apiKeyHelper": "", "env": ["EDITOR": "vim", "ANTHROPIC_API_KEY": "", "ANTHROPIC_AUTH_TOKEN": "", "ANTHROPIC_BASE_URL": ""]], root: root, name: "settings.local.json")
            let before = try Data(contentsOf: root.appendingPathComponent("settings.local.json"))
            try SubscriptionConfiguration.validate(configDirectory: root.path)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("settings.local.json")), before)
        }
    }

    func testEveryEnabledExternalProviderFlagIsRejectedInEitherFile() throws {
        for name in ["settings.json", "settings.local.json"] {
            for flag in ["CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_FOUNDRY",
                         "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_USE_MANTLE"] {
                for value: Any in ["true", "1", "TRUE", " true ", true, 1] {
                    try fixture { root in
                        try write(["env": [flag: value]], root: root, name: name)
                        assertUnsupported(root)
                    }
                }
            }
        }
    }

    func testExplicitlyDisabledProviderFlagsAreAllowed() throws {
        for value: Any in ["false", "0", "", "FALSE", false, 0] {
            try fixture { root in
                try write(["env": ["CLAUDE_CODE_USE_VERTEX": value, "CLAUDE_CODE_USE_BEDROCK": value, "CLAUDE_CODE_USE_FOUNDRY": value]], root: root)
                try SubscriptionConfiguration.validate(configDirectory: root.path)
            }
        }
    }

    func testNonemptyCredentialOverridesAndHelperAreRejectedWithoutDisclosure() throws {
        let secret = "fixture-private-selector-value"
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
                    "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
                    "CLAUDE_CODE_OAUTH_CLIENT_ID", "CLAUDE_CODE_OAUTH_SCOPES", "ANTHROPIC_PROFILE", "ANTHROPIC_FEDERATION_RULE_ID",
                    "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_ORGANIZATION_ID",
                    "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
                    "CLAUDE_CODE_GATEWAY_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR",
                    "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_BG_AUTH_SNAPSHOT_PATH",
                    "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH", "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH", "ANTHROPIC_UNIX_SOCKET"] {
            try fixture { root in
                try write(["env": [key: secret]], root: root)
                assertUnsupported(root, forbiddenText: secret)
            }
        }
        try fixture { root in
            try write(["apiKeyHelper": secret], root: root)
            assertUnsupported(root, forbiddenText: secret)
        }
    }

    func testDirectOfficialEndpointIsAllowedButOtherDestinationsAreRejected() throws {
        for endpoint in ["https://api.anthropic.com", "https://api.anthropic.com/", "https://api.anthropic.com:443"] {
            try fixture { root in
                try write(["env": ["ANTHROPIC_BASE_URL": endpoint]], root: root)
                try SubscriptionConfiguration.validate(configDirectory: root.path)
            }
        }
        for endpoint in ["http://api.anthropic.com", "https://api.anthropic.com.other.example", "https://user@api.anthropic.com", "https://api.anthropic.com/proxy", "https://api.anthropic.com?route=other", "https://api.anthropic.com:444"] {
            try fixture { root in
                try write(["env": ["ANTHROPIC_BASE_URL": endpoint]], root: root)
                assertUnsupported(root)
            }
        }
    }

    func testBothFilesAreCheckedInsteadOfAssumingOneOverridesTheOther() throws {
        try fixture { root in
            try write(["env": ["CLAUDE_CODE_USE_VERTEX": "1"]], root: root)
            try write(["env": ["CLAUDE_CODE_USE_VERTEX": "0"]], root: root, name: "settings.local.json")
            assertUnsupported(root)
            try write([:], root: root)
            try write(["apiKeyHelper": "fixture-helper"], root: root, name: "settings.local.json")
            assertUnsupported(root)
        }
    }

    func testSharedRegularSymlinkTargetsAreValidatedWithoutChangingLinks() throws {
        try fixture { root in
            let shared = root.appendingPathComponent("shared.json")
            try Data("{}".utf8).write(to: shared)
            let settings = root.appendingPathComponent("settings.json")
            try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: shared)
            try SubscriptionConfiguration.validate(configDirectory: root.path)
            let changed = Data(#"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}"#.utf8)
            try changed.write(to: shared)
            assertUnsupported(root)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path), shared.path)
            XCTAssertEqual(try Data(contentsOf: shared), changed)
        }
    }

    func testMalformedJSONAndRelevantFieldTypesFailClosed() throws {
        for text in ["", "{", "[]", "null", #"{"env":[]}"#, #"{"env":"fixture-private-value"}"#,
                     #"{"apiKeyHelper":{}}"#, #"{"env":{"ANTHROPIC_API_KEY":true}}"#,
                     #"{"env":{"CLAUDE_CODE_USE_VERTEX":"maybe"}}"#, #"{"env":{"CLAUDE_CODE_USE_FOUNDRY":2}}"#] {
            try fixture { root in
                try Data(text.utf8).write(to: root.appendingPathComponent("settings.json"))
                assertUnsupported(root, forbiddenText: "fixture-private-value")
            }
        }
    }

    func testNonregularAndBrokenSettingsEntriesFailWithoutBlocking() throws {
        for kind in ["directory", "fifo", "fifo-link", "broken-link"] {
            try fixture { root in
                let settings = root.appendingPathComponent("settings.json")
                switch kind {
                case "directory": try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
                case "fifo": XCTAssertEqual(mkfifo(settings.path, 0o600), 0)
                case "fifo-link":
                    let fifo = root.appendingPathComponent("source-fifo")
                    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
                    try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: fifo)
                default: try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: root.appendingPathComponent("missing.json"))
                }
                let start = ContinuousClock.now
                assertUnsupported(root)
                XCTAssertLessThan(start.duration(to: .now), .seconds(1))
                var entry = stat()
                XCTAssertEqual(lstat(settings.path, &entry), 0)
            }
        }
    }

    func testOneMiBBoundaryAllowsValidJSONAndRejectsLargerFile() throws {
        try fixture { root in
            let settings = root.appendingPathComponent("settings.json")
            try (Data("{}".utf8) + Data(repeating: 32, count: 1_048_574)).write(to: settings)
            try SubscriptionConfiguration.validate(configDirectory: root.path)
            let handle = try FileHandle(forWritingTo: settings)
            try handle.seekToEnd(); try handle.write(contentsOf: Data([32])); try handle.close()
            assertUnsupported(root)
        }
    }

    func testUnreadableExistingSettingsFailClosed() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read mode-000 files") }
        try fixture { root in
            let path = root.appendingPathComponent("settings.json").path
            try write([:], root: root)
            XCTAssertEqual(chmod(path, 0), 0)
            defer { _ = chmod(path, 0o600) }
            assertUnsupported(root)
        }
    }

    func testInvalidConfigPathsAndDanglingConfigLinkAreRejected() throws {
        for path in ["", "relative", "/synthetic\npath", "/synthetic\0path"] {
            XCTAssertThrowsError(try SubscriptionConfiguration.validate(configDirectory: path))
        }
        try fixture { root in
            let target = root.appendingPathComponent("not-directory")
            try Data().write(to: target)
            assertUnsupported(target)
            let broken = root.appendingPathComponent("broken-config")
            try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("missing-config"))
            assertUnsupported(broken)
        }
    }
}

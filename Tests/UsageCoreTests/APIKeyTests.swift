import Foundation
import CryptoKit
import XCTest
@testable import UsageCore

final class APIKeyTests: XCTestCase {
    private let profile = Profile(command: "claude-console", configDirectory: "/synthetic/claudock-console",
                                  managed: true, authKind: .apiKey)
    private let key = "sk-ant-api03-" + "fixture_Key-0123456789"
    private let otherKey = "sk-ant-api03-" + "fixture_other-9876543210"
    private let usrKey = "sk-ant-usr-" + "fixture_User-Key_0123456789"

    func testRawKeyAndExactExportAssignmentsAreAccepted() throws {
        for raw in [key, " \n" + key + "\r\n", "\t" + key + " ",
                    "export ANTHROPIC_API_KEY=" + key,
                    "export \t ANTHROPIC_API_KEY='" + key + "'",
                    "export ANTHROPIC_API_KEY=\"" + key + "\"\n"] {
            XCTAssertEqual(try ConsoleAPIKey(parsing: raw).value, key)
        }
        for version in ["00", "01", "99"] {
            let other = "sk-ant-api\(version)-x"
            XCTAssertEqual(try ConsoleAPIKey(parsing: other).value, other)
        }
    }

    func testEveryKeyTypeThatIsNotAKnownNonKeyCredentialIsAccepted() throws {
        let accepted = [usrKey, "sk-ant-usr01-" + "fixture_User-Key_0123456789", key,
                        "sk-ant-svc01-" + "fixture_Service-Key_0123456789", // a type this build has never seen
                        "sk-ant-api-x", "sk-ant-api3-x", "sk-ant-api003-x", "sk-ant-api0003-x"]
        for candidate in accepted {
            for raw in [candidate, " \n" + candidate + "\r\n", "export ANTHROPIC_API_KEY=" + candidate,
                        "export ANTHROPIC_API_KEY='" + candidate + "'"] {
                XCTAssertEqual(try ConsoleAPIKey(parsing: raw).value, candidate, raw.debugDescription)
            }
        }
    }

    func testRefusedTypesMatchTheWholeTypeSegmentNotAPrefix() throws {
        for type in ["oath", "orts", "administrator", "sidecar", "sia", "ccx", "ccs", "ccsrx"] {
            let candidate = "sk-ant-\(type)01-" + "fixture_body"
            XCTAssertEqual(try ConsoleAPIKey(parsing: candidate).value, candidate, type)
        }
    }

    func testRefreshTokensAreReportedLikeOAuthAccessTokens() {
        for raw in ["sk-ant-ort01-" + "fixture_refresh", "export ANTHROPIC_API_KEY=sk-ant-ort01-fixture"] {
            XCTAssertThrowsError(try ConsoleAPIKey(parsing: raw)) { error in
                XCTAssertEqual(error as? APIKeyError, .oauthToken)
                XCTAssertTrue(error.localizedDescription.contains("subscription OAuth token, not a Console API key"))
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
            }
        }
    }

    func testSessionCredentialsAreNotConsoleAPIKeys() {
        for prefix in ["sk-ant-sid01-", "sk-ant-si-", "sk-ant-cc-", "sk-ant-ccsr-", "sk-ant-ccsr01-"] {
            for raw in [prefix + "fixture_session", "export ANTHROPIC_API_KEY='" + prefix + "fixture_session'"] {
                XCTAssertThrowsError(try ConsoleAPIKey(parsing: raw), raw.debugDescription) { error in
                    XCTAssertEqual(error as? APIKeyError, .notAnAPIKey)
                    XCTAssertTrue(error.localizedDescription.contains("Claude session credential, not a Console API key"))
                    XCTAssertFalse(error.localizedDescription.contains("fixture"))
                }
            }
        }
    }

    func testARefusedTypeKeepsItsMessageWhateverFollowsThePrefix() {
        let cases: [(String, APIKeyError)] = [
            ("sk-ant-oat01-", .oauthToken), ("sk-ant-oat01-" + String(repeating: "a", count: 600), .oauthToken),
            ("sk-ant-ort01-abc def", .oauthToken), ("sk-ant-admin01-abc.def", .adminKey),
            ("sk-ant-sid01-", .notAnAPIKey), ("sk-ant-cc-" + String(repeating: "a", count: 600), .notAnAPIKey)]
        for (raw, expected) in cases {
            XCTAssertThrowsError(try ConsoleAPIKey(parsing: raw), String(raw.prefix(24))) {
                XCTAssertEqual($0 as? APIKeyError, expected, String(raw.prefix(24)))
            }
        }
    }

    func testRefusedTypesAllowUpToFourVersionDigitsAndAreRecognisedOnlyAtTheStart() {
        let cases: [(String, APIKeyError)] = [
            ("sk-ant-oat-x", .oauthToken), ("sk-ant-oat0001-x", .oauthToken), ("sk-ant-oat00001-x", .invalidKey),
            ("sk-ant-admin0001-x", .adminKey), ("sk-ant-sid0001-x", .notAnAPIKey),
            ("Bearer sk-ant-oat01-fixture", .invalidKey), ("x sk-ant-sid01-fixture", .invalidKey)]
        for (raw, expected) in cases {
            XCTAssertThrowsError(try ConsoleAPIKey(parsing: raw), raw) { XCTAssertEqual($0 as? APIKeyError, expected, raw) }
        }
    }

    func testInvalidKeyMessageNamesTheAcceptedKeyShapes() {
        let message = APIKeyError.invalidKey.localizedDescription
        XCTAssertTrue(message.contains("sk-ant-api03-"))
        XCTAssertTrue(message.contains("sk-ant-usr-"))
        XCTAssertTrue(message.contains("export ANTHROPIC_API_KEY"))
    }

    func testOAuthTokensAndAdminKeysGetSpecificMessages() {
        for raw in ["sk-ant-oat01-" + "fixture_token", "export ANTHROPIC_API_KEY=sk-ant-oat01-fixture"] {
            XCTAssertThrowsError(try ConsoleAPIKey(parsing: raw)) { error in
                XCTAssertEqual(error as? APIKeyError, .oauthToken)
                XCTAssertTrue(error.localizedDescription.contains("subscription OAuth token, not a Console API key"))
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
            }
        }
        XCTAssertThrowsError(try ConsoleAPIKey(parsing: "sk-ant-admin01-" + "fixture_admin")) { error in
            XCTAssertEqual(error as? APIKeyError, .adminKey)
            XCTAssertTrue(error.localizedDescription.contains("Admin API keys cannot run Claude Code; create a standard key in the Console"))
            XCTAssertFalse(error.localizedDescription.contains("fixture"))
        }
    }

    func testMalformedInputIsRejectedWithoutEchoingIt() {
        let invalid = ["", "   \n", "hello", "sk-ant-api03-", "sk-ant-", "sk-ant-usr", "sk-ant-usr-", "sk-ant--abc", "sk-ant-01-abc",
                       "sk-ant-USR-abc", "sk-ant-usr_abc", "sk-ant-usr01abc", "sk-ant-usr12345-abc",
                       "sk-ant-usr-abc def", "sk-ant-usr-abc\ndef", "sk-ant-usr-abc\tdef",
                       usrKey + ";touch never-run", usrKey + "$(touch never-run)", usrKey + "漢字", usrKey + "\n" + otherKey,
                       "sk-ant-api03_abc", "sk-ant-api03-abc def", "sk-ant-api03-abc\ndef", "sk-ant-api03-abc\tdef",
                       key + ";touch never-run", key + "$(touch never-run)", key + "`whoami`", key + ".x", key + "/x",
                       key + "漢字", key + "\0", "Bearer " + key, "ANTHROPIC_API_KEY=" + key,
                       "export ANTHROPIC_API_KEY =" + key, "export ANTHROPIC_API_KEY= " + key,
                       "export OTHER_KEY=" + key, "export ANTHROPIC_API_KEY='" + key,
                       "export ANTHROPIC_API_KEY='" + key + "\"", "export ANTHROPIC_API_KEY='" + key + "'; touch never-run",
                       "export ANTHROPIC_API_KEY=\"$(touch never-run)\"", key + "\n" + otherKey]
        for raw in invalid {
            XCTAssertThrowsError(try ConsoleAPIKey(parsing: raw), raw.debugDescription) { error in
                XCTAssertEqual(error as? APIKeyError, .invalidKey)
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
                XCTAssertFalse(error.localizedDescription.contains("never-run"))
            }
        }
    }

    func testLengthLimitIncludesThePrefixAndInputIsBoundedBeforeParsing() throws {
        let longest = "sk-ant-api03-" + String(repeating: "a", count: 512 - 13)
        XCTAssertEqual(try ConsoleAPIKey(parsing: longest).value.utf8.count, 512)
        XCTAssertThrowsError(try ConsoleAPIKey(parsing: longest + "a")) { XCTAssertEqual($0 as? APIKeyError, .invalidKey) }
        let longestUsr = "sk-ant-usr-" + String(repeating: "a", count: 512 - 11)
        XCTAssertEqual(try ConsoleAPIKey(parsing: longestUsr).value.utf8.count, 512)
        XCTAssertThrowsError(try ConsoleAPIKey(parsing: longestUsr + "a")) { XCTAssertEqual($0 as? APIKeyError, .invalidKey) }
        XCTAssertThrowsError(try ConsoleAPIKey(parsing: key + String(repeating: " ", count: 4096))) {
            XCTAssertEqual($0 as? APIKeyError, .invalidKey)
        }
    }

    func testDescriptionNeverRevealsTheKey() throws {
        let parsed = try ConsoleAPIKey(parsing: key)
        XCTAssertFalse(String(describing: parsed).contains("fixture"))
        XCTAssertFalse("\(parsed)".contains("fixture"))
        XCTAssertFalse(String(reflecting: parsed).contains("fixture"))
        var dumped = ""
        dump(parsed, to: &dumped)
        XCTAssertFalse(dumped.contains("fixture"))
    }

    func testKeychainServiceIsSeparateHashedAndStableAcrossRename() {
        let service = APIKeyStore.serviceName(for: profile)
        let expected = SHA256.hash(data: Data(CredentialStore.serviceName(for: profile).utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(service, "Claudock-apikey-" + expected)
        XCTAssertNotNil(service.range(of: #"\AClaudock-apikey-[a-f0-9]{64}\z"#, options: .regularExpression))
        let renamed = Profile(command: "claude-renamed", configDirectory: profile.configDirectory, managed: true, authKind: .apiKey)
        XCTAssertEqual(APIKeyStore.serviceName(for: renamed), service)
        XCTAssertNotEqual(service, MintTokenStore.serviceName(for: profile))
        XCTAssertNotEqual(service, CredentialStore.serviceName(for: profile))
    }

    func testSecureStdinCommandIsHexEncodedAndBounded() throws {
        let service = APIKeyStore.serviceName(for: profile)
        let command = try APIKeyStore.securityWriteCommand(Data(key.utf8), account: "fixture-user", service: service)
        let text = String(decoding: command, as: UTF8.self)
        XCTAssertEqual(text, "add-generic-password -U -a \"fixture-user\" -s \"\(service)\" -X \""
                       + Data(key.utf8).map { String(format: "%02x", $0) }.joined() + "\"\n")
        XCTAssertFalse(text.contains(key))
        XCTAssertLessThanOrEqual(command.count, 4032)
        XCTAssertThrowsError(try APIKeyStore.securityWriteCommand(Data(repeating: 97, count: 2017), account: "fixture-user", service: service))
        XCTAssertThrowsError(try APIKeyStore.securityWriteCommand(Data(key.utf8), account: "bad\"account", service: service))
        for foreign in [MintTokenStore.serviceName(for: profile), CredentialStore.serviceName(for: profile), service + "\n"] {
            XCTAssertThrowsError(try APIKeyStore.securityWriteCommand(Data(key.utf8), account: "fixture-user", service: foreign))
        }
    }

    func testSaveWritesOnceThroughStdinAndVerifiesTheReadback() throws {
        var writes: [Data] = [], reads: [String] = []
        try APIKeyStore.save(ConsoleAPIKey(parsing: key), profile: profile, securityWrite: { writes.append($0) }, securityRead: { service in
            reads.append(service)
            return (Data((self.key + "\n").utf8), 0)
        })
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(reads, [APIKeyStore.serviceName(for: profile)])
        let command = String(decoding: try XCTUnwrap(writes.first), as: UTF8.self)
        XCTAssertTrue(command.hasPrefix("add-generic-password -U "))
        XCTAssertTrue(command.contains(APIKeyStore.serviceName(for: profile)))
        XCTAssertFalse(command.contains(key))
    }

    func testSaveFailsUnlessTheReadbackMatches() throws {
        let parsed = try ConsoleAPIKey(parsing: key)
        let readbacks: [(data: Data, status: Int32)] = [(Data((otherKey + "\n").utf8), 0), (Data(), 44), (Data(), 36),
                                                       (Data("not a key\n".utf8), 0)]
        for readback in readbacks {
            XCTAssertThrowsError(try APIKeyStore.save(parsed, profile: profile, securityWrite: { _ in }, securityRead: { _ in readback })) {
                XCTAssertEqual($0 as? APIKeyError, .keychainWriteFailed)
            }
        }
        XCTAssertThrowsError(try APIKeyStore.save(parsed, profile: profile, securityWrite: { _ in throw APIKeyError.keychainWriteFailed },
                                                  securityRead: { _ in XCTFail("A failed write must not be read back"); return (Data(), 44) })) {
            XCTAssertEqual($0 as? APIKeyError, .keychainWriteFailed)
        }
    }

    func testMissingKeyIsOptionalButReadErrorsNeverFallBack() throws {
        XCTAssertNil(try APIKeyStore.read(profile: profile, securityRead: { _ in (Data(), 44) }))
        XCTAssertEqual(try APIKeyStore.read(profile: profile, securityRead: { service in
            XCTAssertEqual(service, APIKeyStore.serviceName(for: self.profile))
            return (Data((self.key + "\n").utf8), 0)
        })?.value, key)
        XCTAssertThrowsError(try APIKeyStore.read(profile: profile, securityRead: { _ in (Data(), 36) })) {
            XCTAssertEqual($0 as? APIKeyError, .keychainUnavailable)
        }
        XCTAssertThrowsError(try APIKeyStore.read(profile: profile, securityRead: { _ in throw MonitorError.keychainLocked })) {
            XCTAssertEqual($0 as? APIKeyError, .keychainUnavailable)
        }
        for stored in ["", "\n", "hello\n", "export ANTHROPIC_API_KEY=" + key + "\n", " " + key + "\n", key + "\n\n"] {
            XCTAssertThrowsError(try APIKeyStore.read(profile: profile, securityRead: { _ in (Data(stored.utf8), 0) })) {
                XCTAssertEqual($0 as? APIKeyError, .invalidStoredKey)
            }
        }
    }

    func testSavedKeysOfAcceptedTypesReadBackAndRefusedTypesNever() throws {
        for stored in [usrKey, "sk-ant-usr01-" + "fixture_x", key, "sk-ant-svc01-" + "fixture_service"] {
            XCTAssertEqual(try APIKeyStore.read(profile: profile, securityRead: { _ in (Data((stored + "\n").utf8), 0) })?.value, stored)
        }
        for stored in ["sk-ant-oat01-" + "fixture_token", "sk-ant-ort01-" + "fixture_refresh", "sk-ant-admin01-" + "fixture_admin",
                       "sk-ant-sid01-" + "fixture_session", "sk-ant-cc-" + "fixture_internal", "sk-ant-usr-", "sk-ant-USR-abc"] {
            XCTAssertThrowsError(try APIKeyStore.read(profile: profile, securityRead: { _ in (Data((stored + "\n").utf8), 0) }), stored) {
                XCTAssertEqual($0 as? APIKeyError, .invalidStoredKey)
            }
        }
    }

    func testUsrKeyPassesTheSaveReadbackVerification() throws {
        var writes: [Data] = []
        try APIKeyStore.save(ConsoleAPIKey(parsing: usrKey), profile: profile, securityWrite: { writes.append($0) },
                             securityRead: { _ in (Data((self.usrKey + "\n").utf8), 0) })
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(String(decoding: try XCTUnwrap(writes.first), as: UTF8.self).contains(usrKey))
    }

    func testSavedStatusLooksUpAttributesWithoutReadingTheKey() throws {
        var commands: [[String]] = []
        XCTAssertTrue(try APIKeyStore.isSaved(profile: profile, security: { commands.append($0); return 0 }))
        XCTAssertFalse(try APIKeyStore.isSaved(profile: profile, security: { _ in 44 }))
        XCTAssertEqual(commands, [["find-generic-password", "-a", NSUserName(), "-s", APIKeyStore.serviceName(for: profile)]])
        for failure: Int32 in [1, 36, 51, 15] {
            XCTAssertThrowsError(try APIKeyStore.isSaved(profile: profile, security: { _ in failure })) {
                XCTAssertEqual($0 as? APIKeyError, .keychainUnavailable)
            }
        }
        XCTAssertThrowsError(try APIKeyStore.isSaved(profile: profile, security: { _ in throw MonitorError.keychainLocked })) {
            XCTAssertEqual($0 as? APIKeyError, .keychainUnavailable)
        }
        let subscription = Profile(command: "claude-work", configDirectory: "/synthetic/work", managed: true)
        XCTAssertThrowsError(try APIKeyStore.isSaved(profile: subscription, security: { _ in XCTFail("Unsupported profile reached Keychain"); return 0 }))
    }

    func testUndoDeletesOnlyThisProfilesItemWithoutTheKeyInArguments() {
        var commands: [[String]] = []
        APIKeyStore.delete(profile: profile, security: { commands.append($0); return 0 })
        APIKeyStore.delete(profile: Profile(command: "claude-work", configDirectory: "/synthetic/work", managed: true),
                           security: { commands.append($0); return 0 })
        XCTAssertEqual(commands, [["delete-generic-password", "-a", NSUserName(), "-s", APIKeyStore.serviceName(for: profile)]])
    }

    func testOnlyManagedAPIKeyProfilesReachTheirKeychainItem() throws {
        let parsed = try ConsoleAPIKey(parsing: key)
        let unsupported = [Profile(command: "claude-work", configDirectory: "/synthetic/work", managed: true),
                           Profile(command: "claude-imported", configDirectory: "/synthetic/imported", authKind: .apiKey),
                           Profile(command: "claude-unresolved", configDirectory: "", discoveryNote: "Unresolved", managed: true, authKind: .apiKey),
                           Profile(command: "claude-relative", configDirectory: "relative", managed: true, authKind: .apiKey)]
        for candidate in unsupported {
            XCTAssertThrowsError(try APIKeyStore.read(profile: candidate, securityRead: { _ in XCTFail("Unsupported profile reached Keychain"); return (Data(), 44) })) {
                XCTAssertEqual($0 as? APIKeyError, .unsupportedProfile)
            }
            XCTAssertThrowsError(try APIKeyStore.save(parsed, profile: candidate, securityWrite: { _ in XCTFail("Unsupported profile reached Keychain") },
                                                      securityRead: { _ in XCTFail("Unsupported profile reached Keychain"); return (Data(), 44) })) {
                XCTAssertEqual($0 as? APIKeyError, .unsupportedProfile)
            }
        }
    }

    func testAPIKeyProfilesNeverUseInferenceTokens() throws {
        let token = "sk-ant-oat01-" + "fixture_imported_token"
        XCTAssertThrowsError(try MintTokenStore.importToken(raw: token, profile: profile, identity: { _ in throw MintTokenError.loginRequired },
                                                            save: { _, _ in XCTFail("An API-key profile must not store an inference token") })) {
            XCTAssertEqual($0 as? MintTokenError, .unsupportedProfile)
        }
        XCTAssertThrowsError(try InferenceCredential.environmentToken(profile: profile, mint: { _ in
            XCTFail("An API-key profile must not read an inference token")
            return nil
        }))
    }

    func testUnsupportedSettingsMessageNamesBothSupportedAuthOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-api-key-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: ["env": ["ANTHROPIC_API_KEY": "fixture-settings-key"]])
            .write(to: root.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try SubscriptionConfiguration.validate(configDirectory: root.path)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Claude Pro, Max, Team, or Enterprise subscription"))
            XCTAssertTrue(message.contains("Console API key stored by Claudock"))
            XCTAssertFalse(message.contains("requires an official"))
            XCTAssertFalse(message.contains("fixture-settings-key"))
        }
    }
}

import Foundation
import XCTest
@testable import UsageCore

final class APIKeyProfileStoreTests: XCTestCase {
    private func withHome(_ action: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-api-key-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try action(home)
    }

    private func registry(_ home: URL) -> URL {
        ProfileStore.directory(home: home.path).appendingPathComponent("profiles.json")
    }

    private func accounts(_ home: URL) -> [String] {
        let directory = ProfileStore.directory(home: home.path).appendingPathComponent("accounts")
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func addAPIKeyProfile(_ name: String, home: URL, save: (Profile) throws -> Void = { _ in }) throws -> Profile {
        try ProfileStore.add(name: name, configDirectory: nil, authKind: .apiKey, home: home.path, beforePublishing: save)
    }

    func testProfileWithoutAuthKindDecodesAsSubscription() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"command":"claude-work","configDirectory":"/tmp/work","managed":true}"#.utf8))
        XCTAssertEqual(profile.authKind, .subscription)
        XCTAssertEqual(profile, Profile(command: "claude-work", configDirectory: "/tmp/work", managed: true))
    }

    func testAPIKeyKindRoundTripsAndSubscriptionEncodingIsUnchanged() throws {
        let apiKey = Profile(command: "claude-console", configDirectory: "/tmp/console", registryID: UUID().uuidString,
                             managed: true, authKind: .apiKey)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(apiKey)) as? [String: Any])
        XCTAssertEqual(encoded["authKind"] as? String, "apiKey")
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(apiKey)), apiKey)

        // Records without the field stay subscription profiles, so a subscription-only
        // registry keeps its existing bytes when it is written again.
        let subscription = Profile(command: "claude-work", configDirectory: "/tmp/work", registryID: UUID().uuidString, managed: true)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(subscription)) as? [String: Any])
        XCTAssertEqual(Set(plain.keys), ["command", "configDirectory", "isVertex", "registryID", "managed"])
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(subscription)), subscription)
    }

    func testUnknownAuthKindIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(Profile.self, from: Data(#"{"command":"claude-x","configDirectory":"/tmp/x","authKind":"oauth"}"#.utf8)))
    }

    func testAPIKeyProfileIsPublishedOnlyAfterItsKeyIsSaved() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            var saved: [Profile] = []
            let profile = try addAPIKeyProfile("console", home: home) { pending in
                XCTAssertFalse(try String(contentsOf: self.registry(home), encoding: .utf8).contains("claude-console"))
                saved.append(pending)
            }
            XCTAssertEqual(saved, [profile])
            XCTAssertEqual(profile.authKind, .apiKey)
            XCTAssertTrue(profile.managed)
            XCTAssertEqual(try ProfileStore.load(home: home.path).first { $0.command == "claude-console" }, profile)
            XCTAssertTrue(try ProfileStore.shellProfileNames(home: home.path).contains("claude-console"))
        }
    }

    func testFailedKeySaveRollsBackTheEntryAndItsAccountFolder() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "existing", home: home.path)
            let before = try Data(contentsOf: registry(home))
            let accountsBefore = accounts(home)
            XCTAssertThrowsError(try addAPIKeyProfile("console", home: home) { _ in throw APIKeyError.keychainWriteFailed }) {
                XCTAssertEqual($0 as? APIKeyError, .keychainWriteFailed)
            }
            XCTAssertEqual(try Data(contentsOf: registry(home)), before)
            XCTAssertEqual(accounts(home), accountsBefore)
            XCTAssertFalse(try ProfileStore.load(home: home.path).contains { $0.command == "claude-console" })
            // Nothing half-made blocks a later attempt with the same name.
            XCTAssertEqual(try addAPIKeyProfile("console", home: home).command, "claude-console")
        }
    }

    func testFailedKeySaveForAnImportedFolderLeavesTheFolderAlone() throws {
        try withHome { home in
            let folder = home.appendingPathComponent("existing-config")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent(".claude.json"))
            _ = try ProfileStore.load(home: home.path)
            let before = try Data(contentsOf: registry(home))
            XCTAssertThrowsError(try ProfileStore.add(name: "imported", configDirectory: folder.path, authKind: .apiKey, home: home.path,
                                                      beforePublishing: { _ in throw APIKeyError.keychainUnavailable })) {
                XCTAssertEqual($0 as? APIKeyError, .keychainUnavailable)
            }
            XCTAssertEqual(try Data(contentsOf: registry(home)), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [".claude.json"])
        }
    }

    func testSubscriptionAddNeverCallsAKeyHook() throws {
        try withHome { home in
            let profile = try ProfileStore.add(name: "work", home: home.path)
            XCTAssertEqual(profile.authKind, .subscription)
        }
    }

    func testRenameKeepsTheAPIKeyKindAndKeychainService() throws {
        try withHome { home in
            let original = try addAPIKeyProfile("console", home: home)
            let renamed = try ProfileStore.rename(profile: original, to: "billing", home: home.path)
            XCTAssertEqual(renamed.authKind, .apiKey)
            XCTAssertEqual(renamed.configDirectory, original.configDirectory)
            XCTAssertEqual(APIKeyStore.serviceName(for: renamed), APIKeyStore.serviceName(for: original))
            XCTAssertEqual(try ProfileStore.load(home: home.path).first { $0.command == "claude-billing" }?.authKind, .apiKey)
        }
    }

    func testRegistryRejectsAnAPIKeyKindOnAnImportedProfile() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "work", home: home.path)
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registry(home))) as? [String: Any])
            var profiles = try XCTUnwrap(state["profiles"] as? [[String: Any]])
            let index = try XCTUnwrap(profiles.firstIndex { $0["command"] as? String == "claude-work" })
            profiles[index]["managed"] = false
            profiles[index]["authKind"] = "apiKey"
            state["profiles"] = profiles
            let edited = try JSONSerialization.data(withJSONObject: state)
            try edited.write(to: registry(home))
            XCTAssertThrowsError(try ProfileStore.load(home: home.path)) { error in
                guard case ProfileManager.ManagementError.invalidManagedFiles = error else { return XCTFail("Expected invalidManagedFiles, got \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: registry(home)), edited)
        }
    }
}

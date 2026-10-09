import Foundation
import XCTest
@testable import UsageCore

/// The `consoleLogin` kind in the registry, and switching a managed Console profile between a pasted
/// API key and Claude Code's own Console sign-in.
final class ConsoleLoginProfileStoreTests: XCTestCase {
    private func withHome(_ action: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-console-login-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try action(home)
    }

    private func registry(_ home: URL) -> URL {
        ProfileStore.directory(home: home.path).appendingPathComponent("profiles.json")
    }

    private func registryVersion(_ home: URL) throws -> Int? {
        try (JSONSerialization.jsonObject(with: Data(contentsOf: registry(home))) as? [String: Any])?["version"] as? Int
    }

    private func stored(_ command: String, home: URL) throws -> Profile? {
        try ProfileStore.load(home: home.path).first { $0.command == command }
    }

    func testConsoleLoginKindRoundTrips() throws {
        let profile = Profile(command: "claude-team", configDirectory: "/tmp/team", registryID: UUID().uuidString,
                              managed: true, authKind: .consoleLogin)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        XCTAssertEqual(encoded["authKind"] as? String, "consoleLogin")
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile)), profile)
    }

    func testAddingAConsoleLoginProfileCreatesAManagedAccountFolder() throws {
        try withHome { home in
            let profile = try ProfileStore.addConsoleLoginProfile(name: "team", home: home.path)
            XCTAssertEqual(profile.authKind, .consoleLogin)
            XCTAssertTrue(profile.managed)
            XCTAssertTrue(profile.configDirectory.hasPrefix(ProfileStore.directory(home: home.path).appendingPathComponent("accounts").path))
            XCTAssertEqual(try stored("claude-team", home: home), profile)
            XCTAssertTrue(try ProfileStore.shellProfileNames(home: home.path).contains("claude-team"))
        }
    }

    func testRegistryWithAConsoleLoginProfileIsVersionTwoSoOlderBuildsRefuseIt() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "work", home: home.path)
            XCTAssertEqual(try registryVersion(home), 1)
            let team = try ProfileStore.addConsoleLoginProfile(name: "team", home: home.path)
            XCTAssertEqual(try registryVersion(home), 2)
            let written = try Data(contentsOf: registry(home))
            XCTAssertEqual(try stored("claude-team", home: home)?.authKind, .consoleLogin)
            XCTAssertEqual(try Data(contentsOf: registry(home)), written)
            let renamed = try ProfileStore.rename(profile: team, to: "org", home: home.path)
            XCTAssertEqual(renamed.authKind, .consoleLogin)
            XCTAssertEqual(renamed.configDirectory, team.configDirectory)
            XCTAssertEqual(try registryVersion(home), 2)
            try ProfileStore.remove(profile: renamed, home: home.path)
            XCTAssertEqual(try registryVersion(home), 1)
        }
    }

    func testRegistryRejectsAConsoleLoginKindOnAnImportedProfile() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "work", home: home.path)
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registry(home))) as? [String: Any])
            var profiles = try XCTUnwrap(state["profiles"] as? [[String: Any]])
            let index = try XCTUnwrap(profiles.firstIndex { $0["command"] as? String == "claude-work" })
            profiles[index]["managed"] = false
            profiles[index]["authKind"] = "consoleLogin"
            state["profiles"] = profiles
            state["version"] = 2
            let edited = try JSONSerialization.data(withJSONObject: state)
            try edited.write(to: registry(home))
            XCTAssertThrowsError(try ProfileStore.load(home: home.path)) { error in
                guard case ProfileManager.ManagementError.invalidManagedFiles = error else { return XCTFail("Expected invalidManagedFiles, got \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: registry(home)), edited)
        }
    }

    func testAnAPIKeyProfileSwitchesToItsConsoleSignInKeepingItsIdentity() throws {
        try withHome { home in
            let key = try ProfileStore.add(name: "billing", configDirectory: nil, authKind: .apiKey, home: home.path, beforePublishing: { _ in })
            let switched = try ProfileStore.setAuthKind(.consoleLogin, for: key, home: home.path)
            XCTAssertEqual(switched.authKind, .consoleLogin)
            XCTAssertEqual(switched.registryID, key.registryID)
            XCTAssertEqual(switched.command, key.command)
            XCTAssertEqual(switched.configDirectory, key.configDirectory)
            XCTAssertTrue(switched.managed)
            XCTAssertEqual(try stored("claude-billing", home: home), switched)
            XCTAssertEqual(CredentialStore.serviceName(for: switched), CredentialStore.serviceName(for: key))
            XCTAssertEqual(try registryVersion(home), 2)
        }
    }

    func testAConsoleLoginProfileSwitchesToAnAPIKeyOnlyAfterTheHookSucceeds() throws {
        try withHome { home in
            let team = try ProfileStore.addConsoleLoginProfile(name: "team", home: home.path)
            let before = try Data(contentsOf: registry(home))
            XCTAssertThrowsError(try ProfileStore.setAuthKind(.apiKey, for: team, home: home.path) { pending in
                XCTAssertEqual(pending.authKind, .apiKey)
                XCTAssertEqual(pending.registryID, team.registryID)
                throw APIKeyError.keychainWriteFailed
            }) { XCTAssertEqual($0 as? APIKeyError, .keychainWriteFailed) }
            XCTAssertEqual(try Data(contentsOf: registry(home)), before)
            XCTAssertEqual(try stored("claude-team", home: home)?.authKind, .consoleLogin)

            var saved: [Profile] = []
            let switched = try ProfileStore.setAuthKind(.apiKey, for: team, home: home.path) { pending in
                // Saved before the registry lists the new kind.
                XCTAssertEqual(try Data(contentsOf: self.registry(home)), before)
                saved.append(pending)
            }
            XCTAssertEqual(saved, [switched])
            XCTAssertEqual(switched.authKind, .apiKey)
            XCTAssertEqual(try stored("claude-team", home: home), switched)
        }
    }

    func testSwitchingToTheCurrentKindChangesNothing() throws {
        try withHome { home in
            let team = try ProfileStore.addConsoleLoginProfile(name: "team", home: home.path)
            let before = try Data(contentsOf: registry(home))
            var hooks = 0
            XCTAssertEqual(try ProfileStore.setAuthKind(.consoleLogin, for: team, home: home.path) { _ in hooks += 1 }, team)
            XCTAssertEqual(try Data(contentsOf: registry(home)), before)
            XCTAssertEqual(hooks, 1)
        }
    }

    func testSubscriptionProfilesNeverSwitchKind() throws {
        try withHome { home in
            let work = try ProfileStore.add(name: "work", home: home.path)
            let team = try ProfileStore.addConsoleLoginProfile(name: "team", home: home.path)
            let before = try Data(contentsOf: registry(home))
            for (kind, profile) in [(ProfileAuthKind.consoleLogin, work), (.apiKey, work), (.subscription, team)] {
                XCTAssertThrowsError(try ProfileStore.setAuthKind(kind, for: profile, home: home.path) { _ in XCTFail("A refused switch must not run its hook") }) { error in
                    guard case ProfileManager.ManagementError.unsupportedKindChange = error else { return XCTFail("Expected unsupportedKindChange, got \(error)") }
                }
            }
            XCTAssertEqual(try Data(contentsOf: registry(home)), before)
            XCTAssertFalse(ProfileManager.ManagementError.unsupportedKindChange.localizedDescription.isEmpty)
        }
    }

    func testAProfileThatChangedMeanwhileIsNotSwitched() throws {
        try withHome { home in
            let key = try ProfileStore.add(name: "billing", configDirectory: nil, authKind: .apiKey, home: home.path, beforePublishing: { _ in })
            _ = try ProfileStore.rename(profile: key, to: "renamed", home: home.path)
            let before = try Data(contentsOf: registry(home))
            XCTAssertThrowsError(try ProfileStore.setAuthKind(.consoleLogin, for: key, home: home.path)) { error in
                guard case ProfileManager.ManagementError.missingProfile = error else { return XCTFail("Expected missingProfile, got \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: registry(home)), before)
        }
    }
}

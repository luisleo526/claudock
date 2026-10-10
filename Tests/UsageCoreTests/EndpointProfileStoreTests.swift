import Foundation
import XCTest
@testable import UsageCore

final class EndpointProfileStoreTests: XCTestCase {
    private let deepseek = try! EndpointConfiguration(baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash")
    private let key = try! EndpointAPIKey(parsing: "sk-" + "fixture0123456789abcdef0123456789")

    private func withHome(_ action: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-endpoint-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try action(home)
    }

    private func registry(_ home: URL) -> URL { ProfileStore.directory(home: home.path).appendingPathComponent("profiles.json") }

    private func registryObject(_ home: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registry(home))) as? [String: Any])
    }

    private func accounts(_ home: URL) -> [String] {
        let directory = ProfileStore.directory(home: home.path).appendingPathComponent("accounts")
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func addEndpoint(_ name: String, home: URL, endpoint: EndpointConfiguration? = nil,
                             save: @escaping (EndpointAPIKey, Profile) throws -> Void = { _, _ in }) throws -> Profile {
        try ProfileStore.addEndpointProfile(name: name, endpoint: endpoint ?? deepseek, key: key, home: home.path,
                                            isSaved: { _ in false }, save: save, delete: { _ in })
    }

    private func editRegistry(_ home: URL, _ change: (inout [[String: Any]]) -> Void) throws -> Data {
        var state = try registryObject(home)
        var profiles = try XCTUnwrap(state["profiles"] as? [[String: Any]])
        change(&profiles)
        state["profiles"] = profiles
        let edited = try JSONSerialization.data(withJSONObject: state)
        try edited.write(to: registry(home))
        return edited
    }

    private func assertInvalid(_ home: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ProfileStore.load(home: home.path), file: file, line: line) { error in
            guard case ProfileManager.ManagementError.invalidManagedFiles = error else {
                return XCTFail("Expected invalidManagedFiles, got \(error)", file: file, line: line)
            }
        }
    }

    func testEndpointRecordsRoundTripAndOtherKindsKeepTheirBytes() throws {
        let profile = Profile(command: "claude-deepseek", configDirectory: "/tmp/deepseek", registryID: UUID().uuidString, managed: true,
                              authKind: .endpoint, endpoint: deepseek)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        XCTAssertEqual(encoded["authKind"] as? String, "endpoint")
        XCTAssertEqual(encoded["endpoint"] as? NSDictionary, ["baseURL": "https://api.deepseek.com/anthropic", "model": "deepseek-flash"] as NSDictionary)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile)), profile)
        let apiKey = Profile(command: "claude-console", configDirectory: "/tmp/console", registryID: UUID().uuidString, managed: true, authKind: .apiKey)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(apiKey)) as? [String: Any])
        XCTAssertEqual(Set(plain.keys), ["command", "configDirectory", "isVertex", "registryID", "managed", "authKind"])
    }

    func testEndpointProfileIsPublishedOnlyAfterItsKeyIsSaved() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            var saved: [Profile] = []
            let profile = try addEndpoint("deepseek", home: home) { _, pending in
                XCTAssertFalse(try String(contentsOf: self.registry(home), encoding: .utf8).contains("claude-deepseek"))
                saved.append(pending)
            }
            XCTAssertEqual(saved, [profile])
            XCTAssertEqual(profile.authKind, .endpoint)
            XCTAssertEqual(profile.endpoint, deepseek)
            XCTAssertTrue(profile.managed)
            XCTAssertEqual(try ProfileStore.load(home: home.path).first { $0.command == "claude-deepseek" }, profile)
            XCTAssertTrue(try ProfileStore.shellProfileNames(home: home.path).contains("claude-deepseek"))
            XCTAssertFalse(try String(contentsOf: registry(home), encoding: .utf8).contains("fixture"), "the key never reaches the registry")
        }
    }

    func testFailedKeySaveRollsBackAndDeletesOnlyAnItemThisAttemptCreated() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "work", home: home.path)
            let before = try Data(contentsOf: registry(home))
            let accountsBefore = accounts(home)
            for itemExisted in [false, true] {
                var deleted: [Profile] = [], attempted: [Profile] = []
                XCTAssertThrowsError(try ProfileStore.addEndpointProfile(name: "deepseek", endpoint: deepseek, key: key, home: home.path,
                                                                         isSaved: { _ in itemExisted },
                                                                         save: { _, profile in attempted.append(profile); throw EndpointKeyError.keychainWriteFailed },
                                                                         delete: { deleted.append($0) })) {
                    XCTAssertEqual($0 as? EndpointKeyError, .keychainWriteFailed)
                }
                XCTAssertEqual(deleted, itemExisted ? [] : attempted)
                XCTAssertEqual(try Data(contentsOf: registry(home)), before)
                XCTAssertEqual(accounts(home), accountsBefore)
            }
            XCTAssertEqual(try addEndpoint("deepseek", home: home).command, "claude-deepseek")
        }
    }

    func testRegistryVersionFollowsTheNewestKindItHolds() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "work", home: home.path)
            XCTAssertEqual(try registryObject(home)["version"] as? Int, 1)
            let console = try ProfileStore.add(name: "console", configDirectory: nil, authKind: .apiKey, home: home.path, beforePublishing: { _ in })
            XCTAssertEqual(try registryObject(home)["version"] as? Int, 2)
            let endpoint = try addEndpoint("deepseek", home: home)
            XCTAssertEqual(try registryObject(home)["version"] as? Int, 3)
            // Reading a current version 3 registry leaves its bytes alone.
            let written = try Data(contentsOf: registry(home))
            XCTAssertEqual(try ProfileStore.load(home: home.path).first { $0.command == "claude-deepseek" }?.endpoint, deepseek)
            XCTAssertEqual(try Data(contentsOf: registry(home)), written)
            try ProfileStore.remove(profile: endpoint, home: home.path)
            XCTAssertEqual(try registryObject(home)["version"] as? Int, 2)
            try ProfileStore.remove(profile: console, home: home.path)
            XCTAssertEqual(try registryObject(home)["version"] as? Int, 1)
        }
    }

    func testRegistryRefusesMalformedEndpointRecords() throws {
        let edits: [(String, (inout [String: Any]) -> Void)] = [
            ("an endpoint kind without its endpoint", { $0.removeValue(forKey: "endpoint") }),
            ("an endpoint on another kind", { $0["authKind"] = "apiKey" }),
            ("an imported endpoint profile", { $0["managed"] = false }),
            ("a plain-http endpoint", { $0["endpoint"] = ["baseURL": "http://api.deepseek.com/anthropic", "model": "deepseek-flash"] }),
            ("an invalid model", { $0["endpoint"] = ["baseURL": "https://api.deepseek.com/anthropic", "model": "two models"] })]
        for (label, edit) in edits {
            try withHome { home in
                _ = try addEndpoint("deepseek", home: home)
                let edited = try editRegistry(home) { profiles in
                    let index = profiles.firstIndex { $0["command"] as? String == "claude-deepseek" }!
                    edit(&profiles[index])
                }
                assertInvalid(home)
                XCTAssertEqual(try Data(contentsOf: registry(home)), edited, label)
            }
        }
        try withHome { home in
            _ = try ProfileStore.add(name: "work", home: home.path)
            _ = try editRegistry(home) { profiles in
                let index = profiles.firstIndex { $0["command"] as? String == "claude-work" }!
                profiles[index]["endpoint"] = ["baseURL": "https://api.deepseek.com/anthropic", "model": "deepseek-flash"]
            }
            assertInvalid(home)
        }
        try withHome { home in
            _ = try addEndpoint("deepseek", home: home)
            var state = try registryObject(home)
            state["version"] = 4
            try JSONSerialization.data(withJSONObject: state).write(to: registry(home))
            assertInvalid(home)
        }
    }

    func testSetEndpointChangesTheEndpointAndKeepsEverythingElse() throws {
        try withHome { home in
            let original = try addEndpoint("deepseek", home: home)
            let moved = try EndpointConfiguration(baseURL: "https://gateway.example.test/anthropic", model: "deepseek-flash[1m]")
            let changed = try ProfileStore.setEndpoint(moved, for: original, home: home.path)
            XCTAssertEqual(changed.endpoint, moved)
            XCTAssertEqual([changed.command, changed.configDirectory, changed.registryID], [original.command, original.configDirectory, original.registryID])
            XCTAssertEqual(changed.authKind, .endpoint)
            XCTAssertEqual(EndpointKeyStore.serviceName(for: changed), EndpointKeyStore.serviceName(for: original))
            XCTAssertEqual(try ProfileStore.load(home: home.path).first { $0.command == "claude-deepseek" }, changed)
            // A stale copy of the profile is refused instead of overwriting the newer endpoint.
            XCTAssertThrowsError(try ProfileStore.setEndpoint(deepseek, for: original, home: home.path)) { error in
                guard case ProfileManager.ManagementError.missingProfile = error else { return XCTFail("Expected missingProfile, got \(error)") }
            }
            let work = try ProfileStore.add(name: "work", home: home.path)
            XCTAssertThrowsError(try ProfileStore.setEndpoint(deepseek, for: work, home: home.path)) { error in
                guard case ProfileManager.ManagementError.notEndpointProfile = error else { return XCTFail("Expected notEndpointProfile, got \(error)") }
            }
        }
    }

    func testRenameKeepsTheEndpointAndKeychainService() throws {
        try withHome { home in
            let original = try addEndpoint("deepseek", home: home)
            let renamed = try ProfileStore.rename(profile: original, to: "flash", home: home.path)
            XCTAssertEqual(renamed.authKind, .endpoint)
            XCTAssertEqual(renamed.endpoint, deepseek)
            XCTAssertEqual(EndpointKeyStore.serviceName(for: renamed), EndpointKeyStore.serviceName(for: original))
            XCTAssertEqual(try ProfileStore.load(home: home.path).first { $0.command == "claude-flash" }?.endpoint, deepseek)
        }
    }

    func testEndpointProfilesNeverSwitchKind() throws {
        try withHome { home in
            let endpoint = try addEndpoint("deepseek", home: home)
            for kind in [ProfileAuthKind.apiKey, .consoleLogin, .subscription] {
                XCTAssertThrowsError(try ProfileStore.setAuthKind(kind, for: endpoint, home: home.path)) { error in
                    guard case ProfileManager.ManagementError.unsupportedKindChange = error else { return XCTFail("Expected unsupportedKindChange, got \(error)") }
                }
            }
        }
    }
}

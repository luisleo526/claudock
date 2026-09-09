import Foundation
import Darwin
import XCTest
@testable import UsageCore

final class ProfileStoreTests: XCTestCase {
    private func withHome(_ action: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try action(home)
    }

    private func write(_ text: String, _ path: String, home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func registry(_ home: URL) -> URL {
        ProfileStore.directory(home: home.path).appendingPathComponent("profiles.json")
    }

    func testProfileDecodesLegacyPayloadWithoutChangingCommandIdentity() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"command":"claude-work","configDirectory":"/tmp/work","isVertex":false}"#.utf8))
        XCTAssertEqual(profile.id, "claude-work")
        XCTAssertFalse(profile.managed)
        XCTAssertNil(profile.registryID)
        XCTAssertEqual(profile.launchCommand, "claudock run claude-work")
    }

    func testInitialImportPreservesPathsProviderUnresolvedNotesAndStableIdentityOnRestart() throws {
        try withHome { home in
            let original = #"""
            claude-work() { _claude-native "$HOME/.claude-work" "$@"; }
            claude-cloud() { export CLAUDE_CONFIG_DIR="$HOME/.cloud"; export CLAUDE_CODE_USE_VERTEX=1; claude; }
            claude-dynamic() { custom-helper "$ACCOUNT"; }
            """#
            try write(original, ".zshrc", home: home)
            let discovered = ProfileDiscovery.discover(home: home.path)
            let loaded = try ProfileStore.load(home: home.path)
            XCTAssertEqual(loaded.map(\.command), discovered.map(\.command))
            XCTAssertEqual(loaded.map(\.configDirectory), discovered.map(\.configDirectory))
            XCTAssertEqual(loaded.map(\.isVertex), discovered.map(\.isVertex))
            XCTAssertEqual(loaded.map(\.discoveryNote), discovered.map(\.discoveryNote))
            XCTAssertTrue(loaded.allSatisfy { !$0.managed && UUID(uuidString: $0.id) != nil })
            XCTAssertEqual(loaded, try ProfileStore.load(home: home.path))
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8), original)
        }
    }

    func testBootstrapRetainsExistingSharedDirectoryWrappers() throws {
        try withHome { home in
            try write(#"""
            claude-one() { _claude-native "$HOME/.same"; }
            claude-two() { _claude-native "$HOME/.same"; }
            """#, ".zshrc", home: home)
            XCTAssertEqual(try ProfileStore.load(home: home.path).map(\.command), ["claude", "claude-one", "claude-two"])
        }
    }

    func testBootstrapDeduplicatesRepeatedDeclarationsAcrossStartupAndLegacyOverlay() throws {
        try withHome { home in
            try write(#"claude-work() { _claude-native "$HOME/early"; }"#, ".zprofile", home: home)
            let shell = #"""
            claude-work() { _claude-native "$HOME/middle"; }
            source "$HOME/.config/claude-usage/profiles.zsh"
            """#
            try write(shell, ".zshrc", home: home)
            try write(#"""
            unfunction claude-work 2>/dev/null || true
            unalias claude-work 2>/dev/null || true
            function claude-work() { export CLAUDE_CONFIG_DIR="$HOME/final"; claude; }
            """#, ".config/claude-usage/profiles.zsh", home: home)
            let discovery = ProfileDiscovery.discover(home: home.path)
            XCTAssertEqual(discovery.map(\.command), ["claude", "claude-work"])
            let profiles = try ProfileStore.load(home: home.path)
            XCTAssertEqual(profiles.map(\.command), ["claude", "claude-work"])
            XCTAssertEqual(profiles.first { $0.command == "claude-work" }?.configDirectory, home.path + "/final")
            XCTAssertEqual(Set(profiles.map(\.id)).count, profiles.count)
            XCTAssertEqual(try ProfileStore.importShellProfiles(home: home.path), profiles)
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8), shell)
        }
    }

    func testLegacyUnicodeCommandsRemainImportableAndEditable() throws {
        try withHome { home in
            try write(#"claude-工作() { _claude-native "$HOME/.work"; }"#, ".zshrc", home: home)
            let profile = try XCTUnwrap(ProfileStore.load(home: home.path).first { $0.command == "claude-工作" })
            XCTAssertFalse(profile.managed)
            XCTAssertEqual(profile.launchCommand, "claudock run claude-工作")
            let renamed = try ProfileStore.rename(profile: profile, to: "work", home: home.path)
            XCTAssertEqual(renamed.id, profile.id)
            XCTAssertEqual(renamed.configDirectory, profile.configDirectory)
            XCTAssertEqual(try ProfileStore.importShellProfiles(home: home.path).map(\.command), ["claude", "claude-work"])
        }
    }

    func testDefaultNameIsReservedForNewProfilesButLegacyWrapperRemainsIntact() throws {
        try withHome { home in
            let shell = #"claude-default() { _claude-native "$HOME/.legacy-default"; }"#
            try write(shell, ".zshrc", home: home)
            let imported = try ProfileStore.load(home: home.path)
            let legacy = try XCTUnwrap(imported.first { $0.command == "claude-default" })
            XCTAssertFalse(legacy.managed)
            XCTAssertEqual(legacy.configDirectory, home.path + "/.legacy-default")
            XCTAssertEqual(legacy.launchCommand, "claudock run claude-default")
            XCTAssertEqual(imported.first { $0.command == "claude" }?.launchCommand, "claudock run claude")
            XCTAssertEqual(try ProfileStore.load(home: home.path), imported)
            let ordinary = try ProfileStore.add(name: "ordinary", home: home.path)
            for name in ["default", "DEFAULT", "Default"] {
                XCTAssertThrowsError(try ProfileStore.add(name: name, home: home.path)) { error in
                    guard case ProfileManager.ManagementError.reservedName = error else { return XCTFail("Expected reservedName, got \(error)") }
                }
                XCTAssertThrowsError(try ProfileStore.rename(profile: ordinary, to: name, home: home.path))
            }
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8), shell)
            let renamed = try ProfileStore.rename(profile: legacy, to: "legacy", home: home.path)
            XCTAssertEqual(renamed.id, legacy.id)
            XCTAssertEqual(renamed.configDirectory, legacy.configDirectory)
        }
    }

    func testCredentialServiceNamesAreIdenticalAcrossBootstrapRestartAndRename() throws {
        try withHome { home in
            try write(#"claude-work() { _claude-native "$HOME/.work"; }"#, ".zshrc", home: home)
            let discovered = ProfileDiscovery.discover(home: home.path)
            let before = Dictionary(uniqueKeysWithValues: discovered.map { ($0.command, CredentialStore.serviceName(for: $0)) })
            let imported = try ProfileStore.load(home: home.path)
            for profile in imported {
                XCTAssertEqual(CredentialStore.serviceName(for: profile), before[profile.command])
            }
            let restarted = try ProfileStore.load(home: home.path)
            let defaultProfile = try XCTUnwrap(restarted.first { $0.command == "claude" })
            XCTAssertNotEqual(defaultProfile.id, "claude")
            XCTAssertEqual(CredentialStore.serviceName(for: defaultProfile), "Claude Code-credentials")
            let work = try XCTUnwrap(restarted.first { $0.command == "claude-work" })
            let renamed = try ProfileStore.rename(profile: work, to: "office", home: home.path)
            XCTAssertEqual(CredentialStore.serviceName(for: renamed), before["claude-work"])
        }
    }

    func testDiscoveryDoesNotRunOnEveryLoadAndExplicitImportAvoidsCollisions() throws {
        try withHome { home in
            try write(#"claude-one() { _claude-native "$HOME/.one"; }"#, ".zshrc", home: home)
            let original = try ProfileStore.load(home: home.path)
            try write(#"""
            claude-one() { _claude-native "$HOME/.different"; }
            claude-two() { _claude-native "$HOME/.two"; }
            claude-three() { _claude-native "$HOME/.one"; }
            """#, ".zshrc", home: home)
            XCTAssertEqual(try ProfileStore.load(home: home.path), original)
            let imported = try ProfileStore.importShellProfiles(home: home.path)
            XCTAssertEqual(Set(imported.map(\.command)), ["claude", "claude-one", "claude-two"])
            XCTAssertEqual(imported.first { $0.command == "claude-one" }, original.first { $0.command == "claude-one" })
            XCTAssertEqual(try ProfileStore.importShellProfiles(home: home.path), imported)
        }
    }

    func testRenameAndDeleteSuppressExternalWrappersWithoutMutatingThem() throws {
        try withHome { home in
            let shell = #"claude-work() { _claude-native "$HOME/.claude-work" "$@"; }"#
            try write(shell, ".zshrc", home: home)
            try write("local credentials", ".claude-work/.credentials.json", home: home)
            let original = try XCTUnwrap(ProfileStore.load(home: home.path).first { $0.command == "claude-work" })
            let renamed = try ProfileStore.rename(profile: original, to: "office", home: home.path)
            XCTAssertEqual(renamed.registryID, original.registryID)
            XCTAssertEqual(renamed.configDirectory, original.configDirectory)
            XCTAssertTrue(renamed.managed)
            XCTAssertEqual(try ProfileStore.importShellProfiles(home: home.path).map(\.command), ["claude", "claude-office"])
            XCTAssertThrowsError(try ProfileStore.remove(profile: original, home: home.path))
            try ProfileStore.remove(profile: renamed, home: home.path)
            XCTAssertEqual(try ProfileStore.importShellProfiles(home: home.path).map(\.command), ["claude"])
            try write(shell + "\n" + #"claude-newalias() { _claude-native "$HOME/.claude-work"; }"#, ".zshrc", home: home)
            XCTAssertEqual(try ProfileStore.importShellProfiles(home: home.path).map(\.command), ["claude"])
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude-work/.credentials.json"), encoding: .utf8), "local credentials")
        }
    }

    func testExactLegacyLoginDirectoryAndOverlayBytesSurviveMigration() throws {
        try withHome { home in
            let path = home.appendingPathComponent("Account's $(literal)").path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let overlay = "# Managed by Claude Usage.\nfunction claude-legacy() { export CLAUDE_CONFIG_DIR='" + path.replacingOccurrences(of: "'", with: "'\\''") + "'; command claude \"$@\"; }\n"
            let source = #"[[ -f "$HOME/.config/claude-usage/profiles.zsh" ]] && source "$HOME/.config/claude-usage/profiles.zsh""#
            try write(source, ".zshrc", home: home)
            try write(overlay, ".config/claude-usage/profiles.zsh", home: home)
            let legacyRegistry = #"{"version":1,"profiles":[],"removed":[]}"#
            try write(legacyRegistry, ".config/claude-usage/profiles.json", home: home)
            let profile = try XCTUnwrap(ProfileStore.load(home: home.path).first { $0.command == "claude-legacy" })
            XCTAssertEqual(profile.configDirectory, path)
            XCTAssertFalse(profile.managed)
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8), source)
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".config/claude-usage/profiles.zsh"), encoding: .utf8), overlay)
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".config/claude-usage/profiles.json"), encoding: .utf8), legacyRegistry)
        }
    }

    func testExplicitImportPreservesDistinctLiteralCredentialPathsAndRejectsSameCredentialStore() throws {
        try withHome { home in
            let real = home.appendingPathComponent("Account's Folder")
            let link = home.appendingPathComponent("account-link")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let profile = try ProfileStore.add(name: "linked", configDirectory: link.path, home: home.path)
            XCTAssertEqual(profile.configDirectory, link.path)
            let physical = try ProfileStore.add(name: "physical", configDirectory: real.path, home: home.path)
            XCTAssertNotEqual(CredentialStore.serviceName(for: profile), CredentialStore.serviceName(for: physical))
            XCTAssertThrowsError(try ProfileStore.add(name: "duplicate", configDirectory: link.path, home: home.path))
            XCTAssertThrowsError(try ProfileStore.add(name: "linked", home: home.path))
            let renamed = try ProfileStore.rename(profile: profile, to: "renamed", home: home.path)
            XCTAssertEqual(renamed.configDirectory, link.path)
        }
    }

    func testPostBootstrapShellImportKeepsDistinctSymlinkKeychainsAndLiteralTombstones() throws {
        try withHome { home in
            let real = home.appendingPathComponent("physical")
            let firstLink = home.appendingPathComponent("first-link")
            let secondLink = home.appendingPathComponent("second-link")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: firstLink, withDestinationURL: real)
            try FileManager.default.createSymbolicLink(at: secondLink, withDestinationURL: real)
            try write(#"claude-original() { _claude-native "$HOME/physical"; }"#, ".zshrc", home: home)
            _ = try ProfileStore.load(home: home.path)
            try write(#"""
            claude-original() { _claude-native "$HOME/physical"; }
            claude-first() { _claude-native "$HOME/first-link"; }
            """#, ".zshrc", home: home)
            let imported = try ProfileStore.importShellProfiles(home: home.path)
            let original = try XCTUnwrap(imported.first { $0.command == "claude-original" })
            let first = try XCTUnwrap(imported.first { $0.command == "claude-first" })
            XCTAssertNotEqual(CredentialStore.serviceName(for: original), CredentialStore.serviceName(for: first))
            try ProfileStore.remove(profile: original, home: home.path)
            try write(#"""
            claude-original() { _claude-native "$HOME/physical"; }
            claude-first() { _claude-native "$HOME/first-link"; }
            claude-samecredential() { _claude-native "$HOME/physical"; }
            claude-second() { _claude-native "$HOME/second-link"; }
            """#, ".zshrc", home: home)
            let afterRemoval = try ProfileStore.importShellProfiles(home: home.path)
            XCTAssertEqual(Set(afterRemoval.map(\.command)), ["claude", "claude-first", "claude-second"])
        }
    }

    func testNFCLiteralCredentialIdentityRejectsDuplicateAddAndTombstonedImport() throws {
        try withHome { home in
            let composed = home.path + "/Café"
            let decomposed = home.path + "/Cafe\u{301}"
            try FileManager.default.createDirectory(atPath: composed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: decomposed, withIntermediateDirectories: true)
            let profile = try ProfileStore.add(name: "composed", configDirectory: composed, home: home.path)
            let alias = Profile(command: "claude-decomposed", configDirectory: decomposed)
            XCTAssertEqual(CredentialStore.serviceName(for: profile), CredentialStore.serviceName(for: alias))
            XCTAssertThrowsError(try ProfileStore.add(name: "decomposed", configDirectory: decomposed, home: home.path))
            try ProfileStore.remove(profile: profile, home: home.path)
            try write("claude-decomposed() { export CLAUDE_CONFIG_DIR='\(decomposed)'; claude; }", ".zshrc", home: home)
            XCTAssertEqual(try ProfileStore.importShellProfiles(home: home.path).map(\.command), ["claude"])
        }
    }

    func testDefaultAndExplicitConfigUseDifferentCredentialStoresDespiteSameDirectory() throws {
        try withHome { home in
            let directory = home.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = try XCTUnwrap(ProfileStore.load(home: home.path).first { $0.command == "claude" })
            let explicit = try ProfileStore.add(name: "explicit", configDirectory: directory.path, home: home.path)
            XCTAssertEqual(base.configDirectory, explicit.configDirectory)
            XCTAssertNotEqual(CredentialStore.serviceName(for: base), CredentialStore.serviceName(for: explicit))
            XCTAssertEqual(base.launchCommand, "claudock run claude")
            XCTAssertEqual(explicit.launchCommand, "claudock run claude-explicit")
            XCTAssertThrowsError(try ProfileStore.add(name: "another", configDirectory: directory.path, home: home.path))
        }
    }

    func testProviderAndUnresolvedProfilesDoNotClaimSubscriptionCredentialIdentity() throws {
        try withHome { home in
            try write(#"""
            claude-cloud() { export CLAUDE_CONFIG_DIR="$HOME/shared"; export CLAUDE_CODE_USE_VERTEX=1; claude; }
            claude-dynamic() { custom-helper "$ACCOUNT"; }
            """#, ".zshrc", home: home)
            let initial = try ProfileStore.load(home: home.path)
            XCTAssertEqual(initial.first { $0.command == "claude-cloud" }?.launchCommand, "claude-cloud")
            XCTAssertEqual(initial.first { $0.command == "claude-dynamic" }?.launchCommand, "claude-dynamic")
            try write(#"""
            claude-cloud() { export CLAUDE_CONFIG_DIR="$HOME/shared"; export CLAUDE_CODE_USE_VERTEX=1; claude; }
            claude-subscription() { _claude-native "$HOME/shared"; }
            """#, ".zshrc", home: home)
            let subscription = try XCTUnwrap(ProfileStore.importShellProfiles(home: home.path).first { $0.command == "claude-subscription" })
            try ProfileStore.remove(profile: subscription, home: home.path)
            try write(#"claude-secondcloud() { export CLAUDE_CONFIG_DIR="$HOME/shared"; export CLAUDE_CODE_USE_VERTEX=1; claude; }"#, ".zshrc", home: home)
            XCTAssertTrue(try ProfileStore.importShellProfiles(home: home.path).contains { $0.command == "claude-secondcloud" })
        }
    }

    func testCorruptOrUnsupportedRegistryIsNeverSilentlyReset() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            for corrupt in ["not json", "{}", #"{"version":99,"profiles":[],"suppressedCommands":[],"suppressedDirectories":[]}"#] {
                try Data(corrupt.utf8).write(to: registry(home))
                XCTAssertThrowsError(try ProfileStore.load(home: home.path))
                XCTAssertThrowsError(try ProfileStore.importShellProfiles(home: home.path))
                XCTAssertThrowsError(try ProfileStore.add(name: "noreset", home: home.path))
                XCTAssertEqual(try Data(contentsOf: registry(home)), Data(corrupt.utf8))
            }
        }
    }

    func testProtectedAndStaleProfileFieldsAreRejected() throws {
        try withHome { home in
            try write(#"claude-cloud() { export CLAUDE_CONFIG_DIR="$HOME/.cloud"; export CLAUDE_CODE_USE_VERTEX=1; claude; }"#, ".zshrc", home: home)
            let profiles = try ProfileStore.load(home: home.path)
            for profile in profiles {
                XCTAssertThrowsError(try ProfileStore.rename(profile: profile, to: "changed", home: home.path))
                XCTAssertThrowsError(try ProfileStore.remove(profile: profile, home: home.path))
            }
            let added = try ProfileStore.add(name: "test", home: home.path)
            for stale in [
                Profile(command: added.command, configDirectory: "/wrong", registryID: added.registryID, managed: true),
                Profile(command: added.command, configDirectory: added.configDirectory, registryID: added.registryID),
                Profile(command: added.command, configDirectory: added.configDirectory, discoveryNote: "changed", registryID: added.registryID, managed: true)
            ] {
                XCTAssertThrowsError(try ProfileStore.remove(profile: stale, home: home.path))
            }
        }
    }

    func testUnresolvedWrapperCanBeRemovedButCannotBeRenamed() throws {
        try withHome { home in
            try write(#"claude-dynamic() { custom-helper "$ACCOUNT"; }"#, ".zshrc", home: home)
            let profile = try XCTUnwrap(ProfileStore.load(home: home.path).first { $0.command == "claude-dynamic" })
            XCTAssertThrowsError(try ProfileStore.rename(profile: profile, to: "resolved", home: home.path))
            try ProfileStore.remove(profile: profile, home: home.path)
            XCTAssertEqual(try ProfileStore.importShellProfiles(home: home.path).map(\.command), ["claude"])
        }
    }

    func testPrivateRegistryAndAccountDirectoriesAndNoCredentialContents() throws {
        try withHome { home in
            let added = try ProfileStore.add(name: "private", home: home.path)
            for path in [ProfileStore.directory(home: home.path).path, URL(fileURLWithPath: added.configDirectory).deletingLastPathComponent().path, added.configDirectory] {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: registry(home).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: added.configDirectory), [])
        }
    }

    func testRejectsSymlinkRegistryAndLockWithoutWritingTargets() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            let original = try Data(contentsOf: registry(home))
            let target = home.appendingPathComponent("untouched")
            try original.write(to: target)
            try FileManager.default.removeItem(at: registry(home))
            try FileManager.default.createSymbolicLink(at: registry(home), withDestinationURL: target)
            XCTAssertThrowsError(try ProfileStore.add(name: "bad", home: home.path))
            XCTAssertEqual(try Data(contentsOf: target), original)
            try FileManager.default.removeItem(at: registry(home))
            try original.write(to: registry(home))
            let lock = ProfileStore.directory(home: home.path).appendingPathComponent(".registry-lock")
            try FileManager.default.removeItem(at: lock)
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
            XCTAssertThrowsError(try ProfileStore.load(home: home.path))
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testConcurrentMutationLockReturnsBusy() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            let path = ProfileStore.directory(home: home.path).appendingPathComponent(".registry-lock").path
            let descriptor = open(path, O_RDWR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try ProfileStore.add(name: "busy", home: home.path)) { error in
                guard case ProfileManager.ManagementError.busy = error else { return XCTFail("Expected busy, got \(error)") }
            }
        }
    }

    func testAccountCreationFailureRollsBackRegistry() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "existing", home: home.path)
            let before = try Data(contentsOf: registry(home))
            let accounts = ProfileStore.directory(home: home.path).appendingPathComponent("accounts")
            func chmod(_ arguments: [String]) throws -> Int32 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/chmod")
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                return process.terminationStatus
            }
            guard try chmod(["+a", "user:\(NSUserName()) deny add_subdirectory", accounts.path]) == 0 else { throw XCTSkip("Filesystem does not support directory ACLs") }
            defer { _ = try? chmod(["-N", accounts.path]) }
            XCTAssertThrowsError(try ProfileStore.add(name: "blocked", home: home.path))
            XCTAssertEqual(try Data(contentsOf: registry(home)), before)
            XCTAssertEqual(Set(try ProfileStore.load(home: home.path).map(\.command)), ["claude", "claude-existing"])
        }
    }
}

import Foundation
import XCTest
@testable import UsageCore

final class SharedProfileWorkspaceTests: XCTestCase {
    private func withHome(_ operation: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-shared-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        try operation(home)
    }

    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func append(_ text: String, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func config(_ profile: Profile) -> URL { URL(fileURLWithPath: profile.configDirectory) }

    func testNewProfilesImmediatelyShareSessionsHistoryAndExistingSettings() throws {
        try withHome { home in
            let canonical = home.appendingPathComponent(".claude")
            try write("{\"theme\":\"system\"}", at: canonical.appendingPathComponent("settings.json"))
            try write("shared instructions", at: canonical.appendingPathComponent("CLAUDE.md"))
            try write("existing history\n", at: canonical.appendingPathComponent("history.jsonl"))
            let first = try ProfileStore.add(name: "first", home: home.path)
            let second = try ProfileStore.add(name: "second", home: home.path)
            for profile in [first, second] {
                for name in ["projects", "history.jsonl", "settings.json", "CLAUDE.md"] {
                    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config(profile).appendingPathComponent(name).path), canonical.appendingPathComponent(name).path)
                }
            }
            try write("synthetic shared session", at: config(first).appendingPathComponent("projects/demo/session.jsonl"))
            for root in [canonical, config(first), config(second)] {
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("projects/demo/session.jsonl"), encoding: .utf8), "synthetic shared session")
            }
            try append("new shared history\n", at: config(first).appendingPathComponent("history.jsonl"))
            for root in [canonical, config(second)] {
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("history.jsonl"), encoding: .utf8), "existing history\nnew shared history\n")
            }
            // The profile is already fully shared when it becomes registry-visible.
            XCTAssertEqual(try ProfileStore.load(home: home.path).first(where: { $0.id == second.id }), second)
            let renamed = try ProfileStore.rename(profile: first, to: "renamed", home: home.path)
            XCTAssertEqual(renamed.configDirectory, first.configDirectory)
            XCTAssertEqual(renamed.registryID, first.registryID)
            XCTAssertEqual(try String(contentsOf: config(renamed).appendingPathComponent("settings.json"), encoding: .utf8), "{\"theme\":\"system\"}")
        }
    }

    func testAuthFilesAndCredentialServicesRemainIndependent() throws {
        try withHome { home in
            let canonical = home.appendingPathComponent(".claude")
            for name in [".credentials.json", ".claude.json", ".oauth_refresh.lock", ".storage-write.lock", ".claudock-refresh-fixture.json"] {
                try write("default auth sentinel", at: canonical.appendingPathComponent(name))
            }
            let first = try ProfileStore.add(name: "one", home: home.path)
            let second = try ProfileStore.add(name: "two", home: home.path)
            let defaultProfile = try XCTUnwrap(ProfileStore.load(home: home.path).first { $0.command == "claude" })
            XCTAssertEqual(Set([first, second, defaultProfile].map(CredentialStore.serviceName)).count, 3)
            for profile in [first, second] {
                for name in [".credentials.json", ".claude.json", ".oauth_refresh.lock", ".storage-write.lock", ".claudock-refresh-fixture.json"] {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: config(profile).appendingPathComponent(name).path), name)
                }
            }
            try write("first account login", at: config(first).appendingPathComponent(".credentials.json"))
            try write("first account metadata", at: config(first).appendingPathComponent(".claude.json"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: config(second).appendingPathComponent(".credentials.json").path))
            XCTAssertEqual(try String(contentsOf: canonical.appendingPathComponent(".credentials.json"), encoding: .utf8), "default auth sentinel")
            try ProfileStore.remove(profile: first, home: home.path)
            XCTAssertEqual(try String(contentsOf: config(first).appendingPathComponent(".credentials.json"), encoding: .utf8), "first account login")
        }
    }

    func testOnlyExplicitCommonResourceAllowlistIsLinked() throws {
        try withHome { home in
            let canonical = home.appendingPathComponent(".claude")
            let allowed = ["settings.json", "settings.local.json", "CLAUDE.md", "plugins", "skills", "agents", "commands", "hooks", "plans", "tasks", "teams", "sessions", "session-env", "ide", "image-cache", "paste-cache", "file-history", "cache", "security", "shell-snapshots", "backups", "debug", "downloads", "feedback-bundles", "jobs", "hud", ".omc", ".omc-config.json", ".last-cleanup", ".caveman-active", "security_warnings_state_fixture.json", "daemon"]
            let directories: Set<String> = ["plugins", "skills", "agents", "commands", "hooks"]
            func contents(_ name: String) -> String {
                ["settings.json", "settings.local.json"].contains(name) ? "{\"fixture\":\"shared \(name)\"}" : "shared \(name)"
            }
            for name in allowed {
                let target = canonical.appendingPathComponent(name)
                try write(contents(name), at: directories.contains(name) ? target.appendingPathComponent("fixture") : target)
            }
            try write("unlisted private state", at: canonical.appendingPathComponent("not-on-allowlist.json"))
            let profile = try ProfileStore.add(name: "shared", home: home.path)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: profile.configDirectory)), Set(allowed + ["projects", "history.jsonl"]))
            for name in allowed {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config(profile).appendingPathComponent(name).path), canonical.appendingPathComponent(name).path)
                let target = canonical.appendingPathComponent(name)
                XCTAssertEqual(try String(contentsOf: directories.contains(name) ? target.appendingPathComponent("fixture") : target, encoding: .utf8), contents(name))
            }
        }
    }

    func testExplicitImportDoesNotChangeItsWorkspaceOrCreateCanonicalData() throws {
        try withHome { home in
            let imported = home.appendingPathComponent("existing-account")
            try write("private session", at: imported.appendingPathComponent("projects/demo.jsonl"))
            try write("{\"fixture\":\"private settings\"}", at: imported.appendingPathComponent("settings.json"))
            try write("private login", at: imported.appendingPathComponent(".credentials.json"))
            let profile = try ProfileStore.add(name: "imported", configDirectory: imported.path, home: home.path)
            XCTAssertEqual(profile.configDirectory, imported.path)
            XCTAssertEqual(try String(contentsOf: imported.appendingPathComponent("projects/demo.jsonl"), encoding: .utf8), "private session")
            XCTAssertEqual(try String(contentsOf: imported.appendingPathComponent("settings.json"), encoding: .utf8), "{\"fixture\":\"private settings\"}")
            XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: imported.appendingPathComponent("projects").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        }
    }

    func testFreshHomeSettingsAndFuturePluginInstallsAreShared() throws {
        try withHome { home in
            let first = try ProfileStore.add(name: "first", home: home.path)
            let second = try ProfileStore.add(name: "second", home: home.path)
            let canonical = home.appendingPathComponent(".claude")
            XCTAssertEqual(try String(contentsOf: canonical.appendingPathComponent("settings.json"), encoding: .utf8), "{}\n")
            let settings = try FileHandle(forWritingTo: config(first).appendingPathComponent("settings.json"))
            try settings.truncate(atOffset: 0)
            try settings.write(contentsOf: Data("{\"theme\":\"dark\"}\n".utf8))
            try settings.close()
            try write("installed plugin", at: config(first).appendingPathComponent("plugins/new-plugin/manifest.json"))
            for root in [canonical, config(second)] {
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8), "{\"theme\":\"dark\"}\n")
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("plugins/new-plugin/manifest.json"), encoding: .utf8), "installed plugin")
            }
        }
    }

    func testInvalidCanonicalResourcePreventsRegistryPublicationAndPreservesExistingData() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            let registry = ProfileStore.directory(home: home.path).appendingPathComponent("profiles.json")
            let before = try Data(contentsOf: registry)
            let canonical = home.appendingPathComponent(".claude")
            try write("existing foreign data", at: canonical.appendingPathComponent("history.jsonl/keep"))
            XCTAssertThrowsError(try ProfileStore.add(name: "incomplete", home: home.path))
            XCTAssertEqual(try Data(contentsOf: registry), before)
            XCTAssertEqual(try String(contentsOf: canonical.appendingPathComponent("history.jsonl/keep"), encoding: .utf8), "existing foreign data")
            XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.appendingPathComponent("projects").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileStore.directory(home: home.path).appendingPathComponent("accounts").path))
        }
    }

    func testRollbackRemovesOnlyNewUntouchedResources() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            let parent = ProfileStore.directory(home: home.path).appendingPathComponent("accounts/\(UUID().uuidString)")
            let prepared = try SharedProfileWorkspace.prepare(accountParent: parent, home: home.path)
            try prepared.validate()
            prepared.rollback()
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.deletingLastPathComponent().path))
        }
    }

    func testRollbackKeepsHistoryAndAccountDataWrittenAfterPreparation() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            let parent = ProfileStore.directory(home: home.path).appendingPathComponent("accounts/\(UUID().uuidString)")
            let prepared = try SharedProfileWorkspace.prepare(accountParent: parent, home: home.path)
            let canonical = home.appendingPathComponent(".claude")
            try append("new history", at: canonical.appendingPathComponent("history.jsonl"))
            try write("new session", at: canonical.appendingPathComponent("projects/demo/session.jsonl"))
            try write("new account metadata", at: parent.appendingPathComponent("claude/.claude.json"))
            try append("new settings data", at: canonical.appendingPathComponent("settings.json"))
            prepared.rollback()
            XCTAssertEqual(try String(contentsOf: canonical.appendingPathComponent("history.jsonl"), encoding: .utf8), "new history")
            XCTAssertEqual(try String(contentsOf: canonical.appendingPathComponent("projects/demo/session.jsonl"), encoding: .utf8), "new session")
            XCTAssertEqual(try String(contentsOf: parent.appendingPathComponent("claude/.claude.json"), encoding: .utf8), "new account metadata")
            XCTAssertEqual(try String(contentsOf: canonical.appendingPathComponent("settings.json"), encoding: .utf8), "{}\nnew settings data")
        }
    }

    func testRollbackDoesNotDeleteReplacementOfAnOwnedLink() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            let parent = ProfileStore.directory(home: home.path).appendingPathComponent("accounts/\(UUID().uuidString)")
            let prepared = try SharedProfileWorkspace.prepare(accountParent: parent, home: home.path)
            let link = parent.appendingPathComponent("claude/projects")
            try FileManager.default.removeItem(at: link)
            try write("external replacement", at: link)
            XCTAssertThrowsError(try prepared.validate())
            prepared.rollback()
            XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "external replacement")
        }
    }
}

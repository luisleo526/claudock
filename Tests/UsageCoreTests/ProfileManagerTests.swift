import Foundation
import XCTest
@testable import UsageCore

final class ProfileManagerTests: XCTestCase {
    private func withHome(_ action: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-manager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try action(home)
    }

    func testGUICRUDNeverChangesShellOrCreatesShellIntegration() throws {
        try withHome { home in
            let original = Data("# user's original settings\r\nexport EDITOR=vim\n".utf8)
            let shell = home.appendingPathComponent(".zshrc")
            try original.write(to: shell)
            let added = try ProfileManager.add(name: "personal", home: home.path)
            XCTAssertTrue(added.managed)
            XCTAssertEqual(added.command, "claude-personal")
            XCTAssertEqual(added.launchCommand, "claudock run claude-personal")
            XCTAssertTrue(added.configDirectory.hasPrefix(home.path + "/Library/Application Support/Claudock/accounts/"))
            XCTAssertTrue(added.configDirectory.hasSuffix("/claude"))
            let history = URL(fileURLWithPath: added.configDirectory).appendingPathComponent("history.jsonl")
            try Data("preserved history".utf8).write(to: history)
            let renamed = try ProfileManager.rename(profile: added, to: "work", home: home.path)
            XCTAssertEqual(added.id, renamed.id)
            XCTAssertEqual(added.configDirectory, renamed.configDirectory)
            XCTAssertEqual(renamed.launchCommand, "claudock run claude-work")
            XCTAssertTrue(try ProfileStore.load(home: home.path).contains(renamed))
            try ProfileManager.remove(profile: renamed, home: home.path)
            XCTAssertEqual(try ProfileStore.load(home: home.path).map(\.command), ["claude"])
            XCTAssertEqual(try Data(contentsOf: history), Data("preserved history".utf8))
            XCTAssertEqual(try Data(contentsOf: shell), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/.config/claudock"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/.config/claude-usage"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix(".zshrc.") }, [])
        }
    }

    func testGUIOnlyBootstrapDoesNotCreateZshrc() throws {
        try withHome { home in
            _ = try ProfileManager.add(name: "new", home: home.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/.zshrc"))
        }
    }

    func testRejectsUnsafeNamesAndInvalidDirectories() throws {
        try withHome { home in
            for name in ["", "bad name", "../x", "x;touch", "x\nexit", "-dash", String(repeating: "a", count: 41)] {
                XCTAssertThrowsError(try ProfileManager.add(name: name, home: home.path), name)
            }
            XCTAssertThrowsError(try ProfileManager.add(name: "relative", configDirectory: "relative/path", home: home.path))
            XCTAssertThrowsError(try ProfileManager.add(name: "missing", configDirectory: home.path + "/missing", home: home.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/.zshrc"))
        }
    }

    func testSubscriptionProfileNamedVertexCanBeRenamedAndRemoved() throws {
        try withHome { home in
            let profile = try ProfileManager.add(name: "vertex", home: home.path)
            XCTAssertFalse(profile.isVertex)
            let renamed = try ProfileManager.rename(profile: profile, to: "personal", home: home.path)
            XCTAssertEqual(renamed.id, profile.id)
            try ProfileManager.remove(profile: renamed, home: home.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: profile.configDirectory))
        }
    }
}

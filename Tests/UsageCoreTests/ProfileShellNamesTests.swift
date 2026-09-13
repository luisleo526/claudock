import Foundation
import XCTest
@testable import UsageCore

final class ProfileShellNamesTests: XCTestCase {
    func testMissingRegistryDoesNotDiscoverShellOrCreateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "claude-external() { echo ignored; }".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ProfileStore.shellProfileNames(home: root.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileStore.directory(home: root.path).path))
    }

    func testNamesTrackManagedCRUDWithoutChangingRegistry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try ProfileStore.add(name: "work5", home: root.path)
        let registry = ProfileStore.directory(home: root.path).appendingPathComponent("profiles.json")
        let before = try Data(contentsOf: registry)
        XCTAssertEqual(try ProfileStore.shellProfileNames(home: root.path), ["claude-work5"])
        XCTAssertEqual(try Data(contentsOf: registry), before)
        let renamed = try ProfileStore.rename(profile: profile, to: "office", home: root.path)
        XCTAssertEqual(try ProfileStore.shellProfileNames(home: root.path), ["claude-office"])
        try ProfileStore.remove(profile: renamed, home: root.path)
        XCTAssertEqual(try ProfileStore.shellProfileNames(home: root.path), [])
    }

    func testCorruptRegistryFailsWithoutRepairOrRewrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProfileStore.add(name: "test", home: root.path)
        let registry = ProfileStore.directory(home: root.path).appendingPathComponent("profiles.json")
        let invalid = Data("not valid JSON".utf8)
        try invalid.write(to: registry)
        XCTAssertThrowsError(try ProfileStore.shellProfileNames(home: root.path))
        XCTAssertEqual(try Data(contentsOf: registry), invalid)
    }
}

import Foundation
import Darwin
import XCTest
@testable import UsageCore

/// Launches only read the registry: they share its lock and wait briefly for a change, which
/// takes the lock exclusively and also waits briefly before reporting it is busy.
final class RegistryLockTests: XCTestCase {
    private func withHome(_ action: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try action(home)
    }

    private func registry(_ home: URL) -> URL {
        ProfileStore.directory(home: home.path).appendingPathComponent("profiles.json")
    }

    /// Holds the registry lock through another descriptor, as another Claudock process would.
    @discardableResult
    private func hold(_ home: URL, _ operation: Int32, releaseAfter seconds: TimeInterval? = nil) -> Int32 {
        let descriptor = open(ProfileStore.directory(home: home.path).appendingPathComponent(".registry-lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, operation | LOCK_NB), 0)
        if let seconds {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
        }
        return descriptor
    }

    private func inode(_ url: URL) throws -> UInt64 {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64)
    }

    func testReadsShareTheLockAndNeverRewriteAnUnchangedRegistry() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "work", home: home.path)
            let before = try Data(contentsOf: registry(home)), file = try inode(registry(home))
            let reader = hold(home, LOCK_SH)
            defer { _ = flock(reader, LOCK_UN); _ = close(reader) }
            let started = Date()
            XCTAssertEqual(try ProfileStore.load(home: home.path).map(\.command), ["claude", "claude-work"])
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
            XCTAssertEqual(try Data(contentsOf: registry(home)), before)
            XCTAssertEqual(try inode(registry(home)), file)
        }
    }

    func testReadsWaitForABriefProfileChange() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "work", home: home.path)
            hold(home, LOCK_EX, releaseAfter: 0.5)
            let started = Date()
            XCTAssertEqual(try ProfileStore.load(home: home.path).map(\.command), ["claude", "claude-work"])
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.4)
        }
    }

    func testChangesWaitForReadersAndForOtherChanges() throws {
        try withHome { home in
            _ = try ProfileStore.load(home: home.path)
            for (operation, name) in [(LOCK_SH, "first"), (LOCK_EX, "second")] {
                hold(home, operation, releaseAfter: 0.5)
                let started = Date()
                XCTAssertEqual(try ProfileStore.add(name: name, home: home.path).command, "claude-" + name)
                XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.4)
            }
            XCTAssertEqual(try ProfileStore.load(home: home.path).map(\.command), ["claude", "claude-first", "claude-second"])
        }
    }

    func testAReadThatNeedsAMigrationWritesItOnceOtherReadersFinish() throws {
        try withHome { home in
            _ = try ProfileStore.add(name: "work", home: home.path)
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registry(home))) as? [String: Any])
            state.removeValue(forKey: "subscriptionOnlyMigration")
            try JSONSerialization.data(withJSONObject: state).write(to: registry(home))
            hold(home, LOCK_SH, releaseAfter: 0.5)
            XCTAssertEqual(try ProfileStore.load(home: home.path).map(\.command), ["claude", "claude-work"])
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registry(home))) as? [String: Any])
            XCTAssertEqual(saved["subscriptionOnlyMigration"] as? Int, 1)
        }
    }

    func testAMissingRegistryIsCreatedWhileAnotherReaderWaits() throws {
        try withHome { home in
            try FileManager.default.createDirectory(at: ProfileStore.directory(home: home.path), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: ProfileStore.directory(home: home.path).appendingPathComponent(".registry-lock").path, contents: nil)
            hold(home, LOCK_SH, releaseAfter: 0.5)
            XCTAssertEqual(try ProfileStore.load(home: home.path).map(\.command), ["claude"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: registry(home).path))
        }
    }
}

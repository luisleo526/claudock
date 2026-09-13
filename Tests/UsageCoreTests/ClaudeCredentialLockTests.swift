import Foundation
import Darwin
import XCTest
@testable import UsageCore

final class ClaudeCredentialLockTests: XCTestCase {
    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-credential-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func modificationTime(_ path: String) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
    }

    private func assertFailure(_ expected: MonitorError, operation: () async throws -> ClaudeCredentialLock,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let unexpected = try await operation()
            unexpected.release()
            XCTFail("Unexpectedly acquired credential lock", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MonitorError, expected, file: file, line: line)
        }
    }

    func testAcquiresEmptyPrivateDirectoriesAndReleasesInPlace() async throws {
        try await withDirectory { root in
            let paths = [root.appendingPathComponent(".oauth_refresh.lock").path,
                         root.appendingPathComponent("config.lock").path]
            let lease = try await ClaudeCredentialLock.acquire(paths: paths, timeout: 0)
            try lease.assertOwned()
            for path in paths {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path), [])
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber, 0o700)
            }
            lease.release()
            lease.release()
            XCTAssertThrowsError(try lease.assertOwned()) { XCTAssertEqual($0 as? MonitorError, .credentialChanged) }
            for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
        }
    }

    func testMutualExclusionAndAcquisitionAfterRelease() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent(".oauth_refresh.lock").path
            let first = try await ClaudeCredentialLock.acquire(paths: [path])
            defer { first.release() }
            await assertFailure(.refreshBusy) { try await ClaudeCredentialLock.acquire(paths: [path], timeout: 0) }
            try first.assertOwned()
            first.release()
            let next = try await ClaudeCredentialLock.acquire(paths: [path], timeout: 0)
            try next.assertOwned()
            next.release()
        }
    }

    func testPartialAcquisitionRollsBackOnSecondLockTimeout() async throws {
        try await withDirectory { root in
            let firstPath = root.appendingPathComponent(".oauth_refresh.lock").path
            let secondPath = root.appendingPathComponent("config.lock").path
            let holder = try await ClaudeCredentialLock.acquire(paths: [secondPath])
            defer { holder.release() }
            await assertFailure(.refreshBusy) {
                try await ClaudeCredentialLock.acquire(paths: [firstPath, secondPath], timeout: 0.08)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath))
            try holder.assertOwned()
        }
    }

    func testTimeoutIsBoundedAndDoesNotRemovePreexistingLock() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent(".oauth_refresh.lock").path
            XCTAssertEqual(mkdir(path, 0o700), 0)
            let start = ContinuousClock.now
            await assertFailure(.refreshBusy) { try await ClaudeCredentialLock.acquire(paths: [path], timeout: 0.1) }
            let elapsed = start.duration(to: .now)
            XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(90))
            XCTAssertLessThan(elapsed, .seconds(1))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
    }

    func testHeartbeatUpdatesMtimeAndKeepsDirectoryEmpty() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent(".oauth_refresh.lock").path
            let lease = try await ClaudeCredentialLock.acquire(paths: [path], heartbeatInterval: 0.05)
            defer { lease.release() }
            let initial = try modificationTime(path)
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertGreaterThan(try modificationTime(path), initial)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path), [])
            try lease.assertOwned()
        }
    }

    func testOwnershipReplacementIsNeitherUpdatedNorRemoved() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent(".oauth_refresh.lock").path
            let moved = root.appendingPathComponent("old-owned-directory").path
            let lease = try await ClaudeCredentialLock.acquire(paths: [path], heartbeatInterval: 0.05)
            // Keep the old inode alive so the filesystem cannot reuse its number.
            XCTAssertEqual(rename(path, moved), 0)
            XCTAssertEqual(mkdir(path, 0o700), 0)
            let replacementTime = try modificationTime(path)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertThrowsError(try lease.assertOwned()) { XCTAssertEqual($0 as? MonitorError, .credentialChanged) }
            lease.release()
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(try modificationTime(path), replacementTime)
        }
    }

    func testForeignMtimeChangeCompromisesLeaseAndPreservesDirectory() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent(".oauth_refresh.lock").path
            let lease = try await ClaudeCredentialLock.acquire(paths: [path])
            let foreignDate = Date(timeIntervalSinceNow: -120)
            try FileManager.default.setAttributes([.modificationDate: foreignDate], ofItemAtPath: path)
            XCTAssertThrowsError(try lease.assertOwned()) { XCTAssertEqual($0 as? MonitorError, .credentialChanged) }
            lease.release()
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(try modificationTime(path).timeIntervalSince1970, foreignDate.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testStaleForeignLockFailsClosedForRefreshAndStorageDeadlines() async throws {
        for threshold: TimeInterval in [60, 15] {
            try await withDirectory { root in
                let path = root.appendingPathComponent(".storage-write.lock").path
                XCTAssertEqual(mkdir(path, 0o700), 0)
                let stale = Date(timeIntervalSinceNow: -180)
                try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: path)
                await assertFailure(.refreshBusy) {
                    try await ClaudeCredentialLock.acquire(paths: [path], timeout: 0, staleAfter: threshold)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: path))
                XCTAssertEqual(try modificationTime(path).timeIntervalSince1970, stale.timeIntervalSince1970, accuracy: 0.001)
            }
        }
    }

    func testRefusesSymlinkAndRegularFileLockEntries() async throws {
        for symlink in [true, false] {
            try await withDirectory { root in
                let path = root.appendingPathComponent(".oauth_refresh.lock")
                let target = root.appendingPathComponent("target")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                if symlink { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target) }
                else { try Data("foreign sentinel".utf8).write(to: path) }
                let targetTime = try modificationTime(target.path)
                await assertFailure(.credentialChanged) {
                    try await ClaudeCredentialLock.acquire(paths: [path.path], timeout: 0)
                }
                if symlink { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), target.path) }
                else { XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "foreign sentinel") }
                XCTAssertEqual(try modificationTime(target.path), targetTime)
            }
        }
    }

    func testPartialAcquisitionRollsBackBeforeInvalidSecondEntry() async throws {
        try await withDirectory { root in
            let first = root.appendingPathComponent(".oauth_refresh.lock")
            let second = root.appendingPathComponent("config.lock")
            try Data("foreign sentinel".utf8).write(to: second)
            await assertFailure(.credentialChanged) {
                try await ClaudeCredentialLock.acquire(paths: [first.path, second.path])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
            XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "foreign sentinel")
        }
    }

    func testCancellationRollsBackPartialAcquisitionPromptly() async throws {
        try await withDirectory { root in
            let first = root.appendingPathComponent(".oauth_refresh.lock").path
            let second = root.appendingPathComponent("config.lock").path
            XCTAssertEqual(mkdir(second, 0o700), 0)
            let waiter = Task { try await ClaudeCredentialLock.acquire(paths: [first, second], timeout: 8, heartbeatInterval: 0.05) }
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: first) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: first))
            let waitingMtime = try modificationTime(first)
            // Utility-queue timers can be coalesced on CI, and filesystem mtime
            // precision varies. Await an observed heartbeat within a fixed bound
            // rather than assuming three nominal timer intervals were scheduled.
            let heartbeatDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while try modificationTime(first) <= waitingMtime, ContinuousClock.now < heartbeatDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertGreaterThan(try modificationTime(first), waitingMtime)
            let cancelledAt = ContinuousClock.now
            waiter.cancel()
            do {
                let unexpected = try await waiter.value
                unexpected.release()
                XCTFail("Cancelled acquisition succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(1))
            XCTAssertFalse(FileManager.default.fileExists(atPath: first))
            XCTAssertTrue(FileManager.default.fileExists(atPath: second))
        }
    }

    func testParentReplacementCompromisesLeaseWithoutRemovingReplacementLock() async throws {
        try await withDirectory { root in
            let parent = root.appendingPathComponent("config")
            let moved = root.appendingPathComponent("moved-config")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let path = parent.appendingPathComponent(".oauth_refresh.lock")
            let lease = try await ClaudeCredentialLock.acquire(paths: [path.path], heartbeatInterval: 0.05)
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            let replacementTime = try modificationTime(path.path)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertThrowsError(try lease.assertOwned()) { XCTAssertEqual($0 as? MonitorError, .credentialChanged) }
            lease.release()
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
            XCTAssertEqual(try modificationTime(path.path), replacementTime)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(".oauth_refresh.lock").path))
        }
    }

    func testMissingParentIsNotCreatedAndInvalidInputsFailBeforeMutation() async throws {
        try await withDirectory { root in
            let missing = root.appendingPathComponent("missing/.oauth_refresh.lock").path
            await assertFailure(.credentialChanged) { try await ClaudeCredentialLock.acquire(paths: [missing]) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
            let path = root.appendingPathComponent(".oauth_refresh.lock").path
            await assertFailure(.credentialChanged) { try await ClaudeCredentialLock.acquire(paths: [path, path]) }
            await assertFailure(.credentialChanged) { try await ClaudeCredentialLock.acquire(paths: [path], timeout: .infinity) }
            await assertFailure(.credentialChanged) { try await ClaudeCredentialLock.acquire(paths: [path], heartbeatInterval: 6) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testReleaseNeverRecursivelyRemovesUnexpectedContents() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent(".oauth_refresh.lock")
            let lease = try await ClaudeCredentialLock.acquire(paths: [path.path])
            let content = path.appendingPathComponent("foreign-file")
            try Data("keep".utf8).write(to: content)
            lease.release()
            XCTAssertEqual(try String(contentsOf: content, encoding: .utf8), "keep")
        }
    }

    func testFailedOpenRemovesUnchangedCreatedDirectory() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent(".oauth_refresh.lock").path
            let hooks = ClaudeCredentialLock.AcquisitionHooks(openCreatedDirectory: { _, _ in
                errno = EACCES
                return -1
            })
            await assertFailure(.credentialChanged) {
                try await ClaudeCredentialLock.acquire(paths: [path], hooks: hooks)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            let retry = try await ClaudeCredentialLock.acquire(paths: [path], timeout: 0)
            try retry.assertOwned()
            retry.release()
        }
    }

    func testFailedRegistrationRemovesCreatedDirectoryAndEarlierAcquisitions() async throws {
        try await withDirectory { root in
            let first = root.appendingPathComponent(".oauth_refresh.lock").path
            let second = root.appendingPathComponent("config.lock").path
            let hooks = ClaudeCredentialLock.AcquisitionHooks(beforeRegister: { name in
                if name == "config.lock" { throw MonitorError.credentialChanged }
            })
            await assertFailure(.credentialChanged) {
                try await ClaudeCredentialLock.acquire(paths: [first, second], hooks: hooks)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: first))
            XCTAssertFalse(FileManager.default.fileExists(atPath: second))
        }
    }

    func testFailedOpenPreservesReplacementDirectory() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent(".oauth_refresh.lock").path
            let hooks = ClaudeCredentialLock.AcquisitionHooks(openCreatedDirectory: { parent, name in
                // Keep the created inode alive so the replacement cannot reuse it.
                XCTAssertEqual(renameat(parent, name, parent, "original-directory"), 0)
                XCTAssertEqual(mkdirat(parent, name, 0o700), 0)
                errno = EACCES
                return -1
            })
            await assertFailure(.credentialChanged) {
                try await ClaudeCredentialLock.acquire(paths: [path], hooks: hooks)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("original-directory").path))
        }
    }

    func testFailedRegistrationPreservesChangedOpenedDirectory() async throws {
        try await withDirectory { root in
            let path = root.appendingPathComponent(".oauth_refresh.lock").path
            let changedDate = Date(timeIntervalSinceNow: -120)
            let hooks = ClaudeCredentialLock.AcquisitionHooks(beforeRegister: { _ in
                try FileManager.default.setAttributes([.modificationDate: changedDate], ofItemAtPath: path)
                throw MonitorError.credentialChanged
            })
            await assertFailure(.credentialChanged) {
                try await ClaudeCredentialLock.acquire(paths: [path], hooks: hooks)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(try modificationTime(path).timeIntervalSince1970, changedDate.timeIntervalSince1970, accuracy: 0.001)
        }
    }
}

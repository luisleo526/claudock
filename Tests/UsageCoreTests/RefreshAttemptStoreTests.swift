import Foundation
import Darwin
import XCTest
@testable import UsageCore

final class RefreshAttemptStoreTests: XCTestCase {
    private let first = String(repeating: "a", count: 64)
    private let second = String(repeating: "b", count: 64)

    private func fixture(_ action: (Profile, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-attempt-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try action(Profile(command: "claude-fixture", configDirectory: directory.path), directory)
    }

    private func target(_ directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix(".claudock-refresh-") && $0.pathExtension == "json" })
    }

    func testMissingIntentIsNilAndClearIsIdempotent() throws {
        try fixture { profile, directory in
            XCTAssertNil(try RefreshAttemptStore.read(profile: profile))
            try RefreshAttemptStore.clear(profile: profile, fingerprint: first)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testBeginPublishesOnlyPrivateVersionedFingerprintWithoutSecrets() throws {
        try fixture { profile, directory in
            try RefreshAttemptStore.begin(profile: profile, fingerprint: first)
            XCTAssertEqual(try RefreshAttemptStore.read(profile: profile), first)
            let file = try target(directory), bytes = try Data(contentsOf: file)
            var info = stat()
            XCTAssertEqual(lstat(file.path, &info), 0)
            XCTAssertEqual(info.st_uid, geteuid())
            XCTAssertEqual(info.st_mode & 0o7777, 0o600)
            XCTAssertEqual(info.st_nlink, 1)
            XCTAssertLessThanOrEqual(bytes.count, 512)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["version", "fingerprint"]))
            XCTAssertEqual(object["version"] as? Int, 1)
            XCTAssertEqual(object["fingerprint"] as? String, first)
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains("accessToken"))
            XCTAssertFalse(text.contains("refreshToken"))
            XCTAssertFalse(text.contains(profile.configDirectory))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        }
    }

    func testExistingIntentCannotBeOverwrittenEvenForSameFingerprint() throws {
        try fixture { profile, directory in
            try RefreshAttemptStore.begin(profile: profile, fingerprint: first)
            let file = try target(directory), before = try Data(contentsOf: file)
            for fingerprint in [first, second] {
                XCTAssertThrowsError(try RefreshAttemptStore.begin(profile: profile, fingerprint: fingerprint)) {
                    XCTAssertEqual($0 as? MonitorError, .refreshUncertain)
                }
            }
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        }
    }

    func testMatchingClearRemovesOnlyTheMatchedMarker() throws {
        try fixture { profile, directory in
            let unrelated = directory.appendingPathComponent("unrelated.txt")
            try Data("keep".utf8).write(to: unrelated)
            try RefreshAttemptStore.begin(profile: profile, fingerprint: first)
            try RefreshAttemptStore.clear(profile: profile, fingerprint: first)
            XCTAssertNil(try RefreshAttemptStore.read(profile: profile))
            XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["unrelated.txt"])
        }
    }

    func testMismatchedClearPreservesIntent() throws {
        try fixture { profile, directory in
            try RefreshAttemptStore.begin(profile: profile, fingerprint: second)
            let file = try target(directory), original = try Data(contentsOf: file)
            XCTAssertThrowsError(try RefreshAttemptStore.clear(profile: profile, fingerprint: first)) {
                XCTAssertEqual($0 as? MonitorError, .credentialChanged)
            }
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try RefreshAttemptStore.read(profile: profile), second)
        }
    }

    func testReplacementIntentIsNotClearedUsingOldFingerprint() throws {
        try fixture { profile, directory in
            try RefreshAttemptStore.begin(profile: profile, fingerprint: first)
            let file = try target(directory)
            let replacement = try JSONSerialization.data(withJSONObject: ["version": 1, "fingerprint": second])
            try replacement.write(to: file, options: .atomic)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
            XCTAssertThrowsError(try RefreshAttemptStore.clear(profile: profile, fingerprint: first))
            XCTAssertEqual(try Data(contentsOf: file), replacement)
        }
    }

    func testCorruptPartialAndUnknownVersionTargetsRemainBlocking() throws {
        for bytes in [Data(), Data("{\"version\":".utf8), Data("{}".utf8),
                      Data("{\"version\":2,\"fingerprint\":\"\(first)\"}".utf8),
                      Data("{\"version\":true,\"fingerprint\":\"\(first)\"}".utf8),
                      Data("{\"version\":1,\"fingerprint\":\"\(first)\",\"unexpected\":1}".utf8),
                      Data(repeating: 32, count: 513)] {
            try fixture { profile, directory in
                try RefreshAttemptStore.begin(profile: profile, fingerprint: first)
                let file = try target(directory)
                try bytes.write(to: file)
                XCTAssertThrowsError(try RefreshAttemptStore.read(profile: profile))
                XCTAssertThrowsError(try RefreshAttemptStore.begin(profile: profile, fingerprint: second))
                XCTAssertThrowsError(try RefreshAttemptStore.clear(profile: profile, fingerprint: first))
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
        }
    }

    func testUnpublishedPartialSiblingDoesNotPretendAPostOccurred() throws {
        try fixture { profile, directory in
            try RefreshAttemptStore.begin(profile: profile, fingerprint: first)
            let file = try target(directory)
            try RefreshAttemptStore.clear(profile: profile, fingerprint: first)
            let orphan = URL(fileURLWithPath: file.path + ".pending-crashed-writer")
            try Data().write(to: orphan)
            XCTAssertEqual(chmod(orphan.path, 0o600), 0)
            XCTAssertNil(try RefreshAttemptStore.read(profile: profile))
            try RefreshAttemptStore.begin(profile: profile, fingerprint: second)
            XCTAssertEqual(try RefreshAttemptStore.read(profile: profile), second)
            XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    func testSymlinkTargetIsNeverFollowedOrRemoved() throws {
        try fixture { profile, directory in
            try RefreshAttemptStore.begin(profile: profile, fingerprint: first)
            let file = try target(directory), original = try Data(contentsOf: file)
            let outside = directory.appendingPathComponent("other-state")
            try FileManager.default.moveItem(at: file, to: outside)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            XCTAssertThrowsError(try RefreshAttemptStore.read(profile: profile))
            XCTAssertThrowsError(try RefreshAttemptStore.begin(profile: profile, fingerprint: second))
            XCTAssertThrowsError(try RefreshAttemptStore.clear(profile: profile, fingerprint: first))
            XCTAssertEqual(try Data(contentsOf: outside), original)
            var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0)
            XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        }
    }

    func testNonprivateAndHardlinkedTargetsRemainBlocking() throws {
        try fixture { profile, directory in
            try RefreshAttemptStore.begin(profile: profile, fingerprint: first)
            let file = try target(directory)
            XCTAssertEqual(chmod(file.path, 0o644), 0)
            XCTAssertThrowsError(try RefreshAttemptStore.read(profile: profile))
            XCTAssertThrowsError(try RefreshAttemptStore.clear(profile: profile, fingerprint: first))
            XCTAssertEqual(chmod(file.path, 0o600), 0)
            let alias = directory.appendingPathComponent("alias")
            XCTAssertEqual(link(file.path, alias.path), 0)
            XCTAssertThrowsError(try RefreshAttemptStore.read(profile: profile))
            XCTAssertThrowsError(try RefreshAttemptStore.clear(profile: profile, fingerprint: first))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
        }
    }

    func testMarkerNamesSeparateDistinctCredentialServicesSharingADirectory() throws {
        try fixture { profile, directory in
            let standard = Profile(command: "claude", configDirectory: directory.path)
            try RefreshAttemptStore.begin(profile: profile, fingerprint: first)
            try RefreshAttemptStore.begin(profile: standard, fingerprint: second)
            XCTAssertEqual(try RefreshAttemptStore.read(profile: profile), first)
            XCTAssertEqual(try RefreshAttemptStore.read(profile: standard), second)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
            try RefreshAttemptStore.clear(profile: profile, fingerprint: first)
            XCTAssertEqual(try RefreshAttemptStore.read(profile: standard), second)
        }
    }

    func testInvalidFingerprintCannotCreateOrRemoveState() throws {
        try fixture { profile, directory in
            for invalid in ["", String(repeating: "a", count: 63), String(repeating: "g", count: 64), first + "\n"] {
                XCTAssertThrowsError(try RefreshAttemptStore.begin(profile: profile, fingerprint: invalid))
                XCTAssertThrowsError(try RefreshAttemptStore.clear(profile: profile, fingerprint: invalid))
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            try RefreshAttemptStore.begin(profile: profile, fingerprint: first.uppercased())
            XCTAssertEqual(try RefreshAttemptStore.read(profile: profile), first)
            try RefreshAttemptStore.clear(profile: profile, fingerprint: first)
        }
    }

    func testSharedWritableParentIsRefusedBeforeIntentPublication() throws {
        try fixture { profile, directory in
            XCTAssertEqual(chmod(directory.path, 0o770), 0)
            defer { chmod(directory.path, 0o700) }
            XCTAssertThrowsError(try RefreshAttemptStore.read(profile: profile))
            XCTAssertThrowsError(try RefreshAttemptStore.begin(profile: profile, fingerprint: first))
            XCTAssertThrowsError(try RefreshAttemptStore.clear(profile: profile, fingerprint: first))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testConcurrentPublicationNeverOverwritesTheWinningIntent() throws {
        try fixture { profile, directory in
            let lock = NSLock()
            var winners: [String] = []
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                let fingerprint = index == 0 ? first : second
                do {
                    try RefreshAttemptStore.begin(profile: profile, fingerprint: fingerprint)
                    lock.lock(); winners.append(fingerprint); lock.unlock()
                } catch { XCTAssertEqual(error as? MonitorError, .refreshUncertain) }
            }
            XCTAssertEqual(winners.count, 1)
            XCTAssertEqual(try RefreshAttemptStore.read(profile: profile), winners.first)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        }
    }
}

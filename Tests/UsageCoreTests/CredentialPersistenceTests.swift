import Foundation
import Darwin
import XCTest
@testable import UsageCore

final class CredentialPersistenceTests: XCTestCase {
    private let original = Data(#"{"claudeAiOauth":{"accessToken":"fixture-old-access","refreshToken":"fixture-old-refresh","expiresAt":1789000000000,"scopes":["user:profile"],"unknownOauthField":{"preserve":true}},"otherProvider":{"keep":"synthetic"},"unknownRoot":[1,2]}"#.utf8)
    private let renewed = Data(#"{"claudeAiOauth":{"accessToken":"fixture-new-access","refreshToken":"fixture-new-refresh","expiresAt":1789003600000,"scopes":["user:profile"],"unknownOauthField":{"preserve":true}},"otherProvider":{"keep":"synthetic"},"unknownRoot":[1,2]}"#.utf8)

    private func fixture(_ action: (Profile, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-credential-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".credentials.json")
        try original.write(to: file)
        XCTAssertEqual(chmod(file.path, 0o640), 0)
        try action(Profile(command: "claude-fixture", configDirectory: directory.path), file)
    }

    private func readFile(_ profile: Profile) throws -> StoredCredentials {
        try CredentialStore.readStored(profile: profile, securityRead: { _ in (Data(), 44) })
    }

    private func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return value
    }

    func testWholeKeychainDocumentAndHexArePreservedWithoutFallbackReads() throws {
        let profile = Profile(command: "claude-fixture", configDirectory: "/synthetic/nonexistent/claude")
        let plain = try CredentialStore.readStored(profile: profile, securityRead: { service in
            XCTAssertEqual(service, CredentialStore.serviceName(for: profile))
            return (original, 0)
        })
        XCTAssertEqual(plain.data, original)
        XCTAssertEqual(plain.source, .keychain(service: CredentialStore.serviceName(for: profile)))
        XCTAssertEqual(try plain.credentials.accessToken, "fixture-old-access")
        let hex = Data((original.map { String(format: "%02x", $0) }.joined() + "\n").utf8)
        let decoded = try CredentialStore.readStored(profile: profile, securityRead: { _ in (hex, 0) })
        XCTAssertEqual(decoded.data, original)
    }

    func testMalformedKeychainNeverFallsBackToExistingFile() throws {
        try fixture { profile, _ in
            for data in [Data("not-json".utf8), Data("7b0".utf8), Data("GG".utf8), Data("".utf8)] {
                XCTAssertThrowsError(try CredentialStore.readStored(profile: profile, securityRead: { _ in (data, 0) })) {
                    XCTAssertEqual($0 as? MonitorError, .noCredentials)
                }
            }
        }
    }

    func testSecurityTerminatorIsRemovedWithoutRemovingWhitespaceFromStoredValue() throws {
        XCTAssertEqual(try CredentialStore.decodeStoredJSON(original + Data([10])), original)
        let storedWithNewline = original + Data([10])
        XCTAssertEqual(try CredentialStore.decodeStoredJSON(storedWithNewline + Data([10])), storedWithNewline)
        let hex = Data((storedWithNewline.map { String(format: "%02x", $0) }.joined() + "\n").utf8)
        XCTAssertEqual(try CredentialStore.decodeStoredJSON(hex), storedWithNewline)
    }

    func testOnlyAbsentExactKeychainStatusAllowsFileFallback() throws {
        try fixture { profile, _ in
            for status: Int32 in [1, 36, 51, -25293] {
                XCTAssertThrowsError(try CredentialStore.readStored(profile: profile, securityRead: { _ in (Data(), status) })) {
                    XCTAssertEqual($0 as? MonitorError, .keychainLocked)
                }
            }
            XCTAssertEqual(try readFile(profile).data, original)
        }
    }

    func testUnresolvedOrNulPathFailsBeforeSecurityBoundary() {
        for path in ["", "relative/path", "/tmp/fixture\0other"] {
            XCTAssertThrowsError(try CredentialStore.readStored(profile: Profile(command: "claude-fixture", configDirectory: path), securityRead: { _ in
                XCTFail("Invalid profiles must not query Keychain"); return (Data(), 44)
            }))
        }
    }

    func testFileRenewalPreservesWholeDocumentAndUsesPrivateAtomicReplacement() throws {
        try fixture { profile, file in
            let record = try readFile(profile)
            let before = try info(file)
            try CredentialStore.writeStored(renewed, replacing: record)
            let after = try info(file)
            XCTAssertNotEqual(before.st_ino, after.st_ino)
            XCTAssertEqual(after.st_mode & 0o777, 0o600)
            XCTAssertEqual(after.st_uid, geteuid())
            XCTAssertEqual(after.st_nlink, 1)
            XCTAssertEqual(try Data(contentsOf: file), renewed)
            XCTAssertEqual(try readFile(profile).credentials.accessToken, "fixture-new-access")
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: renewed) as? [String: Any])
            XCTAssertEqual(fields["unknownRoot"] as? [Int], [1, 2])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), [".credentials.json"])
        }
    }

    func testPreflightDoesNotChangeContentsInodeOrPermissions() throws {
        try fixture { profile, file in
            let record = try readFile(profile), before = try info(file)
            try CredentialStore.writeStored(record.data, replacing: record)
            let after = try info(file)
            XCTAssertEqual(before.st_ino, after.st_ino)
            XCTAssertEqual(before.st_mode, after.st_mode)
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), [".credentials.json"])
        }
    }

    func testChangedRawContentsInSameInodeAreNeverOverwritten() throws {
        try fixture { profile, file in
            let record = try readFile(profile), before = try info(file)
            let changed = Data((String(decoding: original, as: UTF8.self) + "\n").utf8)
            try changed.write(to: file)
            XCTAssertEqual(try info(file).st_ino, before.st_ino)
            XCTAssertThrowsError(try CredentialStore.writeStored(renewed, replacing: record)) {
                XCTAssertEqual($0 as? MonitorError, .credentialChanged)
            }
            XCTAssertEqual(try Data(contentsOf: file), changed)
        }
    }

    func testSameContentsInReplacementInodeAreNeverOverwritten() throws {
        try fixture { profile, file in
            let record = try readFile(profile)
            try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("old"))
            try original.write(to: file)
            XCTAssertThrowsError(try CredentialStore.writeStored(renewed, replacing: record)) {
                XCTAssertEqual($0 as? MonitorError, .credentialChanged)
            }
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testDeletedCredentialFileIsNotRecreated() throws {
        try fixture { profile, file in
            let record = try readFile(profile)
            try FileManager.default.removeItem(at: file)
            XCTAssertThrowsError(try CredentialStore.writeStored(renewed, replacing: record)) {
                XCTAssertEqual($0 as? MonitorError, .credentialChanged)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).isEmpty)
        }
    }

    func testSymlinkCredentialFileIsNeitherReadNorReplaced() throws {
        try fixture { profile, file in
            let record = try readFile(profile), target = file.appendingPathExtension("actual")
            try FileManager.default.moveItem(at: file, to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            XCTAssertThrowsError(try readFile(profile))
            XCTAssertThrowsError(try CredentialStore.writeStored(renewed, replacing: record))
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(try info(file).st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        }
    }

    func testHardLinkedCredentialFileIsNeitherReadNorReplaced() throws {
        try fixture { profile, file in
            let record = try readFile(profile), alias = file.appendingPathExtension("alias")
            XCTAssertEqual(link(file.path, alias.path), 0)
            XCTAssertThrowsError(try readFile(profile))
            XCTAssertThrowsError(try CredentialStore.writeStored(renewed, replacing: record))
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try Data(contentsOf: alias), original)
        }
    }

    func testReplacedParentDirectoryDoesNotRedirectCredentialWrite() throws {
        try fixture { profile, file in
            let record = try readFile(profile), directory = file.deletingLastPathComponent()
            let moved = directory.appendingPathExtension("old")
            try FileManager.default.moveItem(at: directory, to: moved)
            defer { try? FileManager.default.removeItem(at: moved) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try original.write(to: file)
            XCTAssertThrowsError(try CredentialStore.writeStored(renewed, replacing: record))
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(".credentials.json")), original)
        }
    }

    func testSharedWritableParentIsRefused() throws {
        try fixture { profile, file in
            let record = try readFile(profile), directory = file.deletingLastPathComponent()
            XCTAssertEqual(chmod(directory.path, 0o770), 0)
            defer { chmod(directory.path, 0o700) }
            XCTAssertThrowsError(try readFile(profile))
            XCTAssertThrowsError(try CredentialStore.writeStored(renewed, replacing: record))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testMalformedOrOversizedReplacementCannotTouchExistingCredentials() throws {
        try fixture { profile, file in
            let record = try readFile(profile)
            for invalid in [Data("{}".utf8), Data(repeating: 32, count: 1_048_577)] {
                XCTAssertThrowsError(try CredentialStore.writeStored(invalid, replacing: record)) {
                    XCTAssertEqual($0 as? MonitorError, .credentialWriteFailed)
                }
            }
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testMismatchedSourceBindingFailsBeforeAnyKeychainWrite() throws {
        try fixture { profile, file in
            let record = StoredCredentials(profile: profile, data: original, source: .keychain(service: "not-the-profile-service"))
            XCTAssertThrowsError(try CredentialStore.writeStored(renewed, replacing: record)) {
                XCTAssertEqual($0 as? MonitorError, .credentialChanged)
            }
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testSecurityWriteCommandUsesFixedFlagsAndOnlyHexEncodedPayload() throws {
        let command = try CredentialStore.securityWriteCommand(original, account: "fixture-user", service: "Claude Code-credentials-1234abcd")
        let expected = "add-generic-password -U -a \"fixture-user\" -s \"Claude Code-credentials-1234abcd\" -X \""
            + original.map { String(format: "%02x", $0) }.joined() + "\"\n"
        XCTAssertEqual(String(decoding: command, as: UTF8.self), expected)
        XCTAssertFalse(String(decoding: command, as: UTF8.self).contains("fixture-old-access"))
        XCTAssertLessThanOrEqual(command.count, 4032)
    }

    func testSecurityWriteCommandEnforcesWholeCommandByteLimitWithoutArgvFallback() throws {
        let account = "fixture-user", service = "Claude Code-credentials"
        let overhead = try CredentialStore.securityWriteCommand(Data(), account: account, service: service).count
        let largest = (4032 - overhead) / 2
        XCTAssertLessThanOrEqual(try CredentialStore.securityWriteCommand(Data(repeating: 65, count: largest), account: account, service: service).count, 4032)
        XCTAssertThrowsError(try CredentialStore.securityWriteCommand(Data(repeating: 65, count: largest + 1), account: account, service: service)) {
            XCTAssertEqual($0 as? MonitorError, .credentialWriteFailed)
        }
        let unicode = Data("採樣🌿".utf8)
        XCTAssertEqual(try CredentialStore.securityWriteCommand(unicode, account: account, service: service).count, overhead + unicode.count * 2)
    }

    func testSecurityWriteCommandRejectsInjectedSelectors() {
        for account in ["", "user\" -s other", "user\n", "user\r", "user\u{2028}", "user\0", "$(command)", "`command`", "user\\escape"] {
            XCTAssertThrowsError(try CredentialStore.securityWriteCommand(original, account: account, service: "Claude Code-credentials"))
        }
        for service in ["other-service", "Claude Code-credentials-123456789", "Claude Code-credentials\n", "Claude Code-credentials\" -a other"] {
            XCTAssertThrowsError(try CredentialStore.securityWriteCommand(original, account: "fixture-user", service: service))
        }
    }
}

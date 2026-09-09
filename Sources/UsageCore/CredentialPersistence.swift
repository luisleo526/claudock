import Foundation
import Darwin
import Security

enum CredentialSource: Equatable, Sendable {
    case keychain(service: String)
    case file(path: String, device: UInt64, inode: UInt64)
}

struct StoredCredentials: @unchecked Sendable {
    let profile: Profile
    let data: Data
    let source: CredentialSource
    var credentials: Credentials { get throws { try Credentials.parse(data) } }
}

private let keychainInteractionLock = NSLock()
private let credentialSizeLimit = 1_048_576

extension CredentialStore {
    static func readStored(profile: Profile) throws -> StoredCredentials {
        try readStored(profile: profile, securityRead: runSecurity)
    }

    /// Reads one exact backend. A locked or malformed Keychain item never selects plaintext.
    /// The injectable boundary keeps tests away from the user's Keychain.
    static func readStored(profile: Profile,
                           securityRead: (String) throws -> (data: Data, status: Int32)) throws -> StoredCredentials {
        guard profile.configDirectory.hasPrefix("/"), !profile.configDirectory.utf8.contains(0) else { throw MonitorError.noCredentials }
        let service = serviceName(for: profile)
        let result = try securityRead(service)
        if result.status == 0 {
            return StoredCredentials(profile: profile, data: try decodeStoredJSON(result.data), source: .keychain(service: service))
        }
        guard result.status == 44 else { throw MonitorError.keychainLocked }
        let path = URL(fileURLWithPath: profile.configDirectory).appendingPathComponent(".credentials.json").path
        do {
            return try withCredentialParent(path) { parent, _, _ in
                let read = try readCredentialFile(parent: parent, name: ".credentials.json")
                _ = try Credentials.parse(read.data)
                return StoredCredentials(profile: profile, data: read.data,
                                         source: .file(path: path, device: fileDevice(read.info), inode: read.info.st_ino))
            }
        } catch { throw MonitorError.noCredentials }
    }

    /// The caller must hold Claude's shared storage-write lock. Passing the original data
    /// checks write access without changing credential content or replacing the file inode.
    static func writeStored(_ data: Data, replacing record: StoredCredentials) throws {
        guard data.count <= credentialSizeLimit, (try? Credentials.parse(data)) != nil else { throw MonitorError.credentialWriteFailed }
        switch record.source {
        case .keychain(let service):
            guard service == serviceName(for: record.profile) else { throw MonitorError.credentialChanged }
            try updateExistingKeychain(data, record: record, service: service)
        case .file(let path, let device, let inode):
            let expected = URL(fileURLWithPath: record.profile.configDirectory).appendingPathComponent(".credentials.json").path
            guard path == expected else { throw MonitorError.credentialChanged }
            try updateExistingFile(data, record: record, path: path, device: device, inode: inode)
        }
    }

    static func decodeStoredJSON(_ data: Data) throws -> Data {
        guard data.count <= credentialSizeLimit * 2 + 2 else { throw MonitorError.noCredentials }
        let plaintext = data.last == 0x0A ? Data(data.dropLast()) : data
        if plaintext.count <= credentialSizeLimit, (try? Credentials.parse(plaintext)) != nil {
            // security prints one terminating newline after a plaintext password value.
            // Strip that terminator only; preserve any whitespace belonging to the value.
            return plaintext
        }
        // `security -w` can return non-ASCII JSON as hex. Decode only a complete,
        // nonempty ASCII hex value; no partial decoding or lossy string conversion.
        guard let string = String(data: data, encoding: .utf8) else { throw MonitorError.noCredentials }
        let hex = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hex.isEmpty, hex.utf8.count <= credentialSizeLimit * 2, hex.utf8.count % 2 == 0,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw MonitorError.noCredentials }
        var decoded = Data(capacity: hex.utf8.count / 2)
        var offset = hex.startIndex
        while offset < hex.endIndex {
            let end = hex.index(offset, offsetBy: 2)
            guard let byte = UInt8(hex[offset..<end], radix: 16) else { throw MonitorError.noCredentials }
            decoded.append(byte); offset = end
        }
        _ = try Credentials.parse(decoded)
        return decoded
    }

    /// Commands are interpreted by security's own REPL, never by a shell. Match Claude's
    /// bounded stdin route; never place credential data in argv or fall back to that route.
    static func securityWriteCommand(_ data: Data, account: String, service: String) throws -> Data {
        let allowedAccount = #"\A[a-zA-Z0-9._-]+\z"#
        let allowedService = #"\AClaude Code-credentials(?:-[a-f0-9]{8})?\z"#
        guard account.range(of: allowedAccount, options: .regularExpression) != nil,
              service.range(of: allowedService, options: .regularExpression) != nil,
              !account.utf8.contains(10), !account.utf8.contains(13),
              !service.utf8.contains(10), !service.utf8.contains(13) else { throw MonitorError.credentialWriteFailed }
        let prefix = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \""
        let suffix = "\"\n"
        guard data.count <= 2016, prefix.utf8.count + data.count * 2 + suffix.utf8.count <= 4032 else {
            throw MonitorError.credentialWriteFailed
        }
        return Data((prefix + data.map { String(format: "%02x", $0) }.joined() + suffix).utf8)
    }

    private static func updateExistingKeychain(_ data: Data, record: StoredCredentials, service: String) throws {
        let command = try securityWriteCommand(data, account: NSUserName(), service: service)
        let identity = try existingKeychainIdentity(service: service)
        let current = try rereadKeychainForWrite(service: service)
        guard sameCredentialJSON(current, record.data),
              try existingKeychainIdentity(service: service) == identity else { throw MonitorError.credentialChanged }
        // security -U has an upsert primitive. Claude's shared storage lock plus these
        // before/after guards coordinate normal writers; this is not an unconditional
        // no-recreation guarantee against another process bypassing that lock.
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw MonitorError.credentialWriteFailed }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        do { try process.run() } catch { throw MonitorError.credentialWriteFailed }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: deadline)
        defer { deadline.cancel(); try? input.fileHandleForWriting.close() }
        do {
            try input.fileHandleForWriting.write(contentsOf: command)
            try input.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw MonitorError.credentialWriteFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MonitorError.credentialWriteFailed }
        guard try existingKeychainIdentity(service: service) == identity else { throw MonitorError.credentialChanged }
        let saved = try rereadKeychainForWrite(service: service)
        guard saved == data, try existingKeychainIdentity(service: service) == identity else { throw MonitorError.credentialChanged }
        // If identity changed, preserve the replacement. It cannot be attributed safely
        // to this command, even when it happens to contain the bytes we attempted to save.
    }

    private static func rereadKeychainForWrite(service: String) throws -> Data {
        let result = try runSecurity(service: service, timeout: 2)
        if result.status == 44 { throw MonitorError.credentialChanged }
        guard result.status == 0 else { throw MonitorError.credentialWriteFailed }
        do { return try decodeStoredJSON(result.data) }
        catch { throw MonitorError.credentialChanged }
    }

    private static func sameCredentialJSON(_ first: Data, _ second: Data) -> Bool {
        guard let firstJSON = try? JSONSerialization.jsonObject(with: first),
              let secondJSON = try? JSONSerialization.jsonObject(with: second),
              let firstCanonical = try? JSONSerialization.data(withJSONObject: firstJSON, options: [.sortedKeys]),
              let secondCanonical = try? JSONSerialization.data(withJSONObject: secondJSON, options: [.sortedKeys]) else { return false }
        return firstCanonical == secondCanonical
    }

    private static func existingKeychainIdentity(service: String) throws -> Data {
        keychainInteractionLock.lock()
        defer { keychainInteractionLock.unlock() }
        // Reference-only lookup avoids secret-read ACL prompts. Serialize and restore
        // legacy Keychain's process-wide interaction setting around the native query.
        var allowed: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw MonitorError.credentialWriteFailed }
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: NSUserName(),
                                   kSecMatchLimit as String: kSecMatchLimitOne,
                                   kSecReturnPersistentRef as String: true,
                                   kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw MonitorError.credentialChanged }
        guard status == errSecSuccess, let identity = result as? Data, !identity.isEmpty else { throw MonitorError.credentialWriteFailed }
        return identity
    }

    private static func updateExistingFile(_ data: Data, record: StoredCredentials, path: String, device: UInt64, inode: UInt64) throws {
        try withCredentialParent(path) { parent, parentPath, parentInfo in
            let name = ".credentials.json"
            func validateCurrent() throws {
                try validateCredentialParent(parentPath, expected: parentInfo)
                let current = try readCredentialFile(parent: parent, name: name)
                guard fileDevice(current.info) == device, current.info.st_ino == inode, current.data == record.data else { throw MonitorError.credentialChanged }
            }
            try validateCurrent()
            let temporary = ".claudock-credentials-\(UUID().uuidString).tmp"
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw MonitorError.credentialWriteFailed }
            var removeTemporary = true
            defer { close(fd); if removeTemporary { unlinkat(parent, temporary, 0) } }
            guard fchmod(fd, 0o600) == 0 else { throw MonitorError.credentialWriteFailed }
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw MonitorError.credentialWriteFailed }
                    written += count
                }
            }
            guard fsync(fd) == 0 else { throw MonitorError.credentialWriteFailed }
            try validateCurrent()
            if data == record.data { return }
            // SWAP requires both paths to exist. A concurrent deletion cannot be turned
            // into a newly-created credential file, as an ordinary rename could do.
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_SWAP)) == 0 else {
                throw errno == ENOENT ? MonitorError.credentialChanged : MonitorError.credentialWriteFailed
            }
            // After exchange this name contains the displaced file, not our temporary.
            // Preserve it unless its identity/content is verified or a rollback succeeds.
            removeTemporary = false
            let displaced = try readCredentialFile(parent: parent, name: temporary)
            if fileDevice(displaced.info) != device || displaced.info.st_ino != inode || displaced.data != record.data {
                // Do not delete unexpected data from a writer that bypassed Claude's lock.
                // Restore it only while the destination still names our replacement inode.
                var ownInfo = stat(), destinationInfo = stat()
                if fstat(fd, &ownInfo) == 0,
                   fstatat(parent, name, &destinationInfo, AT_SYMLINK_NOFOLLOW) == 0,
                   ownInfo.st_ino == destinationInfo.st_ino, ownInfo.st_dev == destinationInfo.st_dev,
                   renameatx_np(parent, temporary, parent, name, UInt32(RENAME_SWAP)) == 0 {
                    removeTemporary = true
                    throw MonitorError.credentialChanged
                }
                throw MonitorError.credentialChanged
            }
            removeTemporary = true
            try validateCredentialParent(parentPath, expected: parentInfo)
            guard fsync(parent) == 0 else { throw MonitorError.credentialWriteFailed }
        }
    }
}

private func fileDevice(_ info: stat) -> UInt64 { UInt64(UInt32(bitPattern: info.st_dev)) }

private func withCredentialParent<T>(_ path: String, _ action: (Int32, String, stat) throws -> T) throws -> T {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw MonitorError.credentialChanged }
    let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard let canonical = realpath(parentPath, nil) else { throw MonitorError.credentialChanged }
    defer { free(canonical) }
    let parent = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw MonitorError.credentialWriteFailed }
    defer { close(parent) }
    var info = stat()
    guard fstat(parent, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw MonitorError.credentialWriteFailed }
    try validateCredentialParent(parentPath, expected: info)
    return try action(parent, parentPath, info)
}

private func validateCredentialParent(_ path: String, expected: stat) throws {
    var current = stat()
    guard stat(path, &current) == 0, current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
          current.st_uid == geteuid(), current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          current.st_mode & 0o022 == 0 else { throw MonitorError.credentialChanged }
}

private func readCredentialFile(parent: Int32, name: String) throws -> (data: Data, info: stat) {
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw MonitorError.credentialChanged }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          before.st_uid == geteuid(), before.st_nlink == 1,
          before.st_size >= 0, before.st_size <= credentialSizeLimit else { throw MonitorError.credentialChanged }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw MonitorError.credentialWriteFailed }
        if count == 0 { break }
        guard data.count + count <= credentialSizeLimit else { throw MonitorError.credentialChanged }
        data.append(contentsOf: buffer.prefix(count))
    }
    var after = stat(), linked = stat()
    guard fstat(fd, &after) == 0, fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
          after.st_ino == before.st_ino, after.st_dev == before.st_dev, after.st_size == before.st_size,
          after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
          linked.st_ino == before.st_ino, linked.st_dev == before.st_dev, linked.st_nlink == 1,
          data.count == before.st_size else { throw MonitorError.credentialChanged }
    return (data, after)
}

import Foundation
import CryptoKit
import CoreFoundation
import Darwin

/// A durable, secret-free intent. The caller owns Claude's shared refresh locks.
/// An existing intent blocks a second POST until the coordinator can account for it.
enum RefreshAttemptStore {
    static func read(profile: Profile) throws -> String? {
        try withParent(profile) { parent, _ in
            try readMarker(parent: parent, name: markerName(profile))?.fingerprint
        }
    }

    static func begin(profile: Profile, fingerprint: String) throws {
        let fingerprint = try normalizedFingerprint(fingerprint)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "fingerprint": fingerprint], options: [.sortedKeys])
        try withParent(profile) { parent, validateParent in
            let name = markerName(profile)
            var existing = stat()
            if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw MonitorError.refreshUncertain }
            guard errno == ENOENT else { throw MonitorError.refreshUncertain }
            let temporary = name + ".pending-" + UUID().uuidString
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw MonitorError.refreshUncertain }
            var published = false
            defer {
                close(fd)
                // A sibling that never reached the canonical name cannot precede a POST.
                // Process crashes may leave this secret-free sibling for later cleanup.
                if !published { unlinkat(parent, temporary, 0) }
            }
            guard fchmod(fd, 0o600) == 0 else { throw MonitorError.refreshUncertain }
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw MonitorError.refreshUncertain }
                    written += count
                }
            }
            guard fsync(fd) == 0 else { throw MonitorError.refreshUncertain }
            try validateParent()
            // No overwrite, including corrupt files, symlinks, or another process's intent.
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw MonitorError.refreshUncertain }
            published = true
            guard fsync(parent) == 0 else { throw MonitorError.refreshUncertain }
            try validateParent()
            var own = stat()
            guard fstat(fd, &own) == 0, let installed = try readMarker(parent: parent, name: name),
                  installed.data == data, sameIdentity(installed.info, own) else { throw MonitorError.refreshUncertain }
        }
    }

    static func clear(profile: Profile, fingerprint: String) throws {
        let fingerprint = try normalizedFingerprint(fingerprint)
        try withParent(profile) { parent, validateParent in
            let name = markerName(profile)
            guard let marker = try readMarker(parent: parent, name: name) else { return }
            guard marker.fingerprint == fingerprint else { throw MonitorError.credentialChanged }
            try validateParent()
            let quarantine = name + ".clearing-" + UUID().uuidString
            // Move before deleting, then verify the actual moved file. Never unlink the
            // canonical path after a separate identity check that could become stale.
            guard renameatx_np(parent, name, parent, quarantine, UInt32(RENAME_EXCL)) == 0 else { throw MonitorError.credentialChanged }
            var verified = false
            defer {
                if !verified {
                    // Restore only into an absent canonical name. Preserve either file if
                    // a writer bypassing the shared lock installed a replacement meanwhile.
                    _ = renameatx_np(parent, quarantine, parent, name, UInt32(RENAME_EXCL))
                    _ = fsync(parent)
                }
            }
            guard let moved = try readMarker(parent: parent, name: quarantine),
                  sameIdentity(moved.info, marker.info), moved.data == marker.data else { throw MonitorError.credentialChanged }
            try validateParent()
            guard unlinkat(parent, quarantine, 0) == 0 else { throw MonitorError.refreshUncertain }
            verified = true
            guard fsync(parent) == 0 else { throw MonitorError.refreshUncertain }
        }
    }

    private static func markerName(_ profile: Profile) -> String {
        let digest = SHA256.hash(data: Data(CredentialStore.serviceName(for: profile).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ".claudock-refresh-" + digest.prefix(16) + ".json"
    }

    private static func normalizedFingerprint(_ value: String) throws -> String {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw MonitorError.refreshUncertain
        }
        return value.lowercased()
    }

    private struct Marker {
        let fingerprint: String
        let data: Data
        let info: stat
    }

    private static func readMarker(parent: Int32, name: String) throws -> Marker? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw MonitorError.refreshUncertain
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, isPrivateMarker(before), before.st_size > 0, before.st_size <= 512 else { throw MonitorError.refreshUncertain }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 513)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw MonitorError.refreshUncertain }
            if count == 0 { break }
            guard data.count + count <= 512 else { throw MonitorError.refreshUncertain }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), linked = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              isPrivateMarker(after), isPrivateMarker(linked), sameIdentity(before, after), sameIdentity(before, linked),
              before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw MonitorError.refreshUncertain }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["version", "fingerprint"]), let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let fingerprint = object["fingerprint"] as? String else { throw MonitorError.refreshUncertain }
        return Marker(fingerprint: try normalizedFingerprint(fingerprint), data: data, info: after)
    }

    private static func isPrivateMarker(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_mode & 0o7777 == 0o600
            && info.st_uid == geteuid() && info.st_nlink == 1
    }

    private static func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private static func withParent<T>(_ profile: Profile, _ action: (Int32, () throws -> Void) throws -> T) throws -> T {
        let path = profile.configDirectory
        guard path.hasPrefix("/"), !path.utf8.contains(0), let canonical = realpath(path, nil) else { throw MonitorError.refreshUncertain }
        defer { free(canonical) }
        let parent = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw MonitorError.refreshUncertain }
        defer { close(parent) }
        var original = stat()
        guard fstat(parent, &original) == 0, original.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              original.st_uid == geteuid(), original.st_mode & 0o022 == 0 else { throw MonitorError.refreshUncertain }
        func validate() throws {
            var current = stat()
            guard stat(path, &current) == 0, sameIdentity(current, original),
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), current.st_uid == geteuid(),
                  current.st_mode & 0o022 == 0 else { throw MonitorError.refreshUncertain }
        }
        try validate()
        let result = try action(parent, validate)
        try validate()
        return result
    }
}

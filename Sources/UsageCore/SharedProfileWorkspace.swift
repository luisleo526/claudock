import Foundation
import Darwin

/// Shared work files live in the default Claude folder. Each account retains a
/// separate, literal config root for its login metadata and Keychain identity.
enum SharedProfileWorkspace {
    private typealias Failure = ProfileManager.ManagementError
    private static let requiredDirectories = ["projects", "plugins", "skills", "agents", "commands", "hooks"]
    private static let requiredNames = requiredDirectories + ["history.jsonl", "settings.json"]
    private static let commonNames = [
        "settings.json", "settings.local.json", "CLAUDE.md", "plugins", "skills", "agents", "commands", "hooks",
        "plans", "tasks", "teams", "sessions", "session-env", "ide", "image-cache", "paste-cache", "file-history",
        "cache", "security", "shell-snapshots", "backups", "debug", "downloads", "feedback-bundles", "jobs", "hud",
        ".omc", ".omc-config.json", ".last-cleanup", ".caveman-active", "daemon"
    ]

    final class Prepared {
        private var entries: [OwnedEntry] = []
        private var accountDirectory: URL?
        private var accountIdentity: stat?
        private var sourceDirectory: URL?
        private var sourceIdentity: stat?

        fileprivate init() {}
        deinit { rollback() }

        fileprivate func record(parent: Int32, name: String, kind: OwnedKind) throws {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.ioFailure }
            let retained = dup(parent)
            guard retained >= 0 else { throw Failure.ioFailure }
            entries.append(OwnedEntry(parent: retained, name: name, original: info, kind: kind))
        }

        fileprivate func ready(account: URL, accountIdentity: stat, source: URL, sourceIdentity: stat) {
            accountDirectory = account; self.accountIdentity = accountIdentity
            sourceDirectory = source; self.sourceIdentity = sourceIdentity
        }

        /// Recheck publication prerequisites immediately before committing registry data.
        func validate() throws {
            guard let accountDirectory, let accountIdentity, let sourceDirectory, let sourceIdentity else { throw Failure.ioFailure }
            var current = stat()
            guard stat(sourceDirectory.path, &current) == 0, sameIdentity(current, sourceIdentity) else { throw Failure.concurrentChange }
            guard stat(accountDirectory.path, &current) == 0, sameIdentity(current, accountIdentity) else { throw Failure.concurrentChange }
            for name in requiredNames {
                let link = accountDirectory.appendingPathComponent(name)
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == sourceDirectory.appendingPathComponent(name).path else {
                    throw Failure.concurrentChange
                }
                let expectedType = requiredDirectories.contains(name) ? S_IFDIR : S_IFREG
                guard stat(sourceDirectory.appendingPathComponent(name).path, &current) == 0,
                      current.st_mode & S_IFMT == expectedType else { throw Failure.concurrentChange }
            }
            for entry in entries {
                guard entry.stillOwned() else { throw Failure.concurrentChange }
            }
        }

        func commit() {
            entries.forEach { close($0.parent) }
            entries.removeAll()
        }

        /// Never recursively delete. Newly written history, foreign replacements,
        /// or data placed in a newly created directory are retained on failure.
        func rollback() {
            for entry in entries.reversed() { entry.removeIfUnchanged(); close(entry.parent) }
            entries.removeAll()
        }
    }

    fileprivate enum OwnedKind { case directory, file(Data), link }

    private struct OwnedEntry {
        let parent: Int32
        let name: String
        let original: stat
        let kind: OwnedKind

        func stillOwned() -> Bool {
            var info = stat()
            return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && sameIdentity(info, original)
        }

        private func removable(_ info: stat, at name: String) -> Bool {
            guard sameIdentity(info, original), info.st_uid == original.st_uid,
                  info.st_mode == original.st_mode else { return false }
            if case .file(let expected) = kind {
                guard info.st_size == expected.count && info.st_nlink == 1 &&
                    info.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec &&
                    info.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else { return false }
                let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { return false }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat()
                guard fstat(fd, &opened) == 0, sameIdentity(opened, original) else { return false }
                do { return (try handle.read(upToCount: expected.count + 1) ?? Data()) == expected }
                catch { return false }
            }
            return true
        }

        func removeIfUnchanged() {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, removable(info, at: name) else { return }
            let quarantine = ".claudock-rollback-" + UUID().uuidString
            guard renameatx_np(parent, name, parent, quarantine, UInt32(RENAME_EXCL)) == 0 else { return }
            var moved = stat()
            guard fstatat(parent, quarantine, &moved, AT_SYMLINK_NOFOLLOW) == 0, removable(moved, at: quarantine) else {
                _ = renameatx_np(parent, quarantine, parent, name, UInt32(RENAME_EXCL)); return
            }
            let flags: Int32
            if case .directory = kind { flags = AT_REMOVEDIR } else { flags = 0 }
            if unlinkat(parent, quarantine, flags) != 0 {
                // Nonempty directories may contain data written after preparation.
                _ = renameatx_np(parent, quarantine, parent, name, UInt32(RENAME_EXCL))
            }
        }
    }

    static func prepare(accountParent: URL, home: String) throws -> Prepared {
        guard home.hasPrefix("/"), !home.utf8.contains(0) else { throw Failure.invalidDirectory }
        let prepared = Prepared()
        do {
            let managedBase = accountParent.deletingLastPathComponent().deletingLastPathComponent()
            let baseFD = try openDirectory(managedBase, allowLink: false)
            defer { close(baseFD) }
            let accounts = try directory(parent: baseFD, name: "accounts", prepared: prepared, allowExistingLink: false)
            defer { close(accounts) }
            let accountName = accountParent.lastPathComponent
            guard UUID(uuidString: accountName) != nil else { throw Failure.invalidDirectory }
            guard mkdirat(accounts, accountName, 0o700) == 0 else { throw Failure.directoryExists }
            try prepared.record(parent: accounts, name: accountName, kind: .directory)
            let account = openat(accounts, accountName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard account >= 0 else { throw Failure.ioFailure }
            defer { close(account) }
            let config = try directory(parent: account, name: "claude", prepared: prepared, allowExistingLink: false, allowExisting: false)
            defer { close(config) }

            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            let homeFD = try openDirectory(homeURL, allowLink: true)
            defer { close(homeFD) }
            let sourceURL = homeURL.appendingPathComponent(".claude", isDirectory: true)
            let source = try directory(parent: homeFD, name: ".claude", prepared: prepared, allowExistingLink: true)
            defer { close(source) }
            for name in requiredDirectories {
                let fd = try directory(parent: source, name: name, prepared: prepared, allowExistingLink: true)
                close(fd)
            }
            try ensureFile(parent: source, name: "history.jsonl", initial: Data(), prepared: prepared)
            try ensureFile(parent: source, name: "settings.json", initial: Data("{}\n".utf8), prepared: prepared)

            var names = requiredNames
            for name in commonNames where !requiredNames.contains(name) && exists(parent: source, name: name) { names.append(name) }
            // Directory entry names cannot contain a slash; only this explicit family
            // is added to the fixed allowlist. No auth file or lock is selected.
            for name in try FileManager.default.contentsOfDirectory(atPath: sourceURL.path).sorted()
                where name.hasPrefix("security_warnings_state_") && name.hasSuffix(".json") {
                names.append(name)
            }
            for name in names {
                let target = sourceURL.appendingPathComponent(name).path
                guard symlinkat(target, config, name) == 0 else { throw Failure.ioFailure }
                try prepared.record(parent: config, name: name, kind: .link)
            }
            // Make the prepared layout durable before its registry entry is committed.
            for fd in [config, account, accounts, source, homeFD, baseFD] {
                guard fsync(fd) == 0 else { throw Failure.ioFailure }
            }
            var sourceInfo = stat(), accountInfo = stat()
            guard fstat(source, &sourceInfo) == 0, fstat(config, &accountInfo) == 0 else { throw Failure.ioFailure }
            prepared.ready(account: accountParent.appendingPathComponent("claude"), accountIdentity: accountInfo, source: sourceURL, sourceIdentity: sourceInfo)
            try prepared.validate()
            return prepared
        } catch {
            prepared.rollback()
            throw error
        }
    }

    private static func exists(parent: Int32, name: String) -> Bool {
        var info = stat()
        return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    private static func openDirectory(_ url: URL, allowLink: Bool) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | (allowLink ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { throw Failure.invalidDirectory }
        do { try validateDirectory(fd); return fd }
        catch { close(fd); throw error }
    }

    private static func validateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw Failure.invalidDirectory }
    }

    private static func directory(parent: Int32, name: String, prepared: Prepared, allowExistingLink: Bool, allowExisting: Bool = true) throws -> Int32 {
        if mkdirat(parent, name, 0o700) == 0 {
            try prepared.record(parent: parent, name: name, kind: .directory)
        } else if errno != EEXIST || !allowExisting { throw Failure.ioFailure }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | (allowExistingLink ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { throw Failure.invalidDirectory }
        do { try validateDirectory(fd); return fd }
        catch { close(fd); throw error }
    }

    private static func ensureFile(parent: Int32, name: String, initial: Data, prepared: Prepared) throws {
        if !exists(parent: parent, name: name) {
            // Publish only fully written defaults; never truncate an existing file.
            let temporary = ".claudock-shared-init-" + UUID().uuidString
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.ioFailure }
            var published = false
            defer {
                if !published {
                    var own = stat(), current = stat()
                    if fstat(fd, &own) == 0, fstatat(parent, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0,
                       sameIdentity(own, current) { _ = unlinkat(parent, temporary, 0) }
                }
                close(fd)
            }
            try initial.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure.ioFailure }
                    written += count
                }
            }
            guard fsync(fd) == 0 else { throw Failure.ioFailure }
            if renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 {
                published = true
                try prepared.record(parent: parent, name: name, kind: .file(initial))
                return
            }
            guard errno == EEXIST else { throw Failure.ioFailure }
        }
        var info = stat()
        guard fstatat(parent, name, &info, 0) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidDirectory }
    }

    private static func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino &&
            first.st_birthtimespec.tv_sec == second.st_birthtimespec.tv_sec &&
            first.st_birthtimespec.tv_nsec == second.st_birthtimespec.tv_nsec &&
            first.st_mode & S_IFMT == second.st_mode & S_IFMT
    }
}

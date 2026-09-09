import Foundation
import Darwin

/// A proper-lockfile-compatible directory lease for Claude's credential updates.
///
/// Acquisition uses mkdir, the directory stays empty, and mtime is refreshed at
/// most every five seconds. Existing locks are never stolen, even when stale:
/// stat/rmdir cannot atomically prove that a stale lock is still the same owner.
/// Claude Code can recover its own abandoned locks. `staleAfter` is our ownership
/// freshness deadline (60 seconds for refresh, 15 seconds for storage writes),
/// not permission to remove another process's directory.
public final class ClaudeCredentialLock: @unchecked Sendable {
    /// Narrow per-acquisition fault boundary; production always uses the defaults.
    struct AcquisitionHooks: Sendable {
        var openCreatedDirectory: @Sendable (Int32, String) -> Int32 = {
            openat($0, $1, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        var beforeRegister: @Sendable (String) throws -> Void = { _ in }
    }

    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let seconds: Int
        let nanoseconds: Int

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            seconds = metadata.st_mtimespec.tv_sec
            nanoseconds = metadata.st_mtimespec.tv_nsec
        }

        var modificationTime: TimeInterval { Double(seconds) + Double(nanoseconds) / 1_000_000_000 }
        func sameIdentity(as other: Stamp) -> Bool { device == other.device && inode == other.inode }
    }

    private struct Directory {
        let parentPath: String
        let name: String
        let parentDescriptor: Int32
        let descriptor: Int32
        let parentIdentity: Stamp
        var stamp: Stamp
    }

    private let stateLock = NSLock()
    private let staleAfter: TimeInterval
    private let heartbeatInterval: TimeInterval
    private var directories: [Directory] = []
    private var timer: DispatchSourceTimer?
    private var released = false
    private var compromised = false

    private init(staleAfter: TimeInterval, heartbeatInterval: TimeInterval) {
        self.staleAfter = staleAfter
        self.heartbeatInterval = heartbeatInterval
    }

    /// Takes locks in the caller's order, rolling back earlier acquisitions on
    /// timeout, cancellation, or failure. Parent directories must already exist.
    /// Use `staleAfter: 15` for `.storage-write.lock`; refresh locks default to 60.
    public static func acquire(paths: [String], timeout: TimeInterval = 8,
                               staleAfter: TimeInterval = 60,
                               heartbeatInterval: TimeInterval = 4) async throws -> ClaudeCredentialLock {
        try await acquire(paths: paths, timeout: timeout, staleAfter: staleAfter,
                          heartbeatInterval: heartbeatInterval, hooks: AcquisitionHooks())
    }

    static func acquire(paths: [String], timeout: TimeInterval = 8,
                        staleAfter: TimeInterval = 60, heartbeatInterval: TimeInterval = 4,
                        hooks: AcquisitionHooks) async throws -> ClaudeCredentialLock {
        guard !paths.isEmpty, paths.count <= 8, Set(paths).count == paths.count,
              timeout.isFinite, timeout >= 0, timeout <= 60,
              staleAfter.isFinite, staleAfter >= 10,
              heartbeatInterval.isFinite, heartbeatInterval > 0,
              heartbeatInterval <= min(5, staleAfter / 2),
              paths.allSatisfy(validPath) else { throw MonitorError.credentialChanged }

        let lease = ClaudeCredentialLock(staleAfter: staleAfter, heartbeatInterval: heartbeatInterval)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        do {
            for path in paths {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: path)
                let parentPath = url.deletingLastPathComponent().path
                let name = url.lastPathComponent
                // Existing config-directory symlinks are allowed, as in Claude.
                // The lock entry itself is always inspected without following it.
                let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard parent >= 0 else { throw MonitorError.credentialChanged }
                var transferred = false
                defer { if !transferred { _ = close(parent) } }
                let parentIdentity = Stamp(try directoryMetadata(descriptor: parent))

                while true {
                    try Task.checkCancellation()
                    try lease.validateAcquiredDirectories()
                    try validateParent(path: parentPath, descriptor: parent, identity: parentIdentity)
                    if mkdirat(parent, name, 0o700) == 0 {
                        // Capture the entry immediately. If metadata cannot be
                        // obtained, ownership is uncertain and cleanup is skipped.
                        var createdMetadata = stat()
                        guard fstatat(parent, name, &createdMetadata, AT_SYMLINK_NOFOLLOW) == 0,
                              createdMetadata.st_mode & S_IFMT == S_IFDIR else { throw MonitorError.credentialChanged }
                        let createdStamp = Stamp(createdMetadata)
                        // Keep the inode open so a heartbeat cannot update a
                        // replacement directory that later appears at this path.
                        let descriptor = hooks.openCreatedDirectory(parent, name)
                        guard descriptor >= 0 else {
                            removeCreatedDirectory(parentPath: parentPath, name: name, parent: parent,
                                                   parentIdentity: parentIdentity, stamp: createdStamp,
                                                   staleAfter: staleAfter)
                            throw MonitorError.credentialChanged
                        }
                        do {
                            let heldStamp = Stamp(try directoryMetadata(descriptor: descriptor))
                            guard heldStamp == createdStamp else { throw MonitorError.credentialChanged }
                            let record = Directory(parentPath: parentPath, name: name, parentDescriptor: parent,
                                                   descriptor: descriptor, parentIdentity: parentIdentity,
                                                   stamp: heldStamp)
                            try hooks.beforeRegister(name)
                            try lease.register(record)
                            transferred = true
                        } catch {
                            removeCreatedDirectory(parentPath: parentPath, name: name, parent: parent,
                                                   parentIdentity: parentIdentity, stamp: createdStamp,
                                                   openedDescriptor: descriptor, staleAfter: staleAfter)
                            _ = close(descriptor)
                            throw error
                        }
                        break
                    }
                    guard errno == EEXIST else { throw MonitorError.credentialChanged }
                    var metadata = stat()
                    if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
                        guard errno == ENOENT else { throw MonitorError.credentialChanged }
                    } else {
                        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw MonitorError.credentialChanged }
                        // A stale mtime does not establish ownership. Wait for
                        // Claude's owner/recovery instead of stealing this lock.
                    }
                    guard clock.now < deadline else { throw MonitorError.refreshBusy }
                    let remaining = clock.now.duration(to: deadline)
                    try await clock.sleep(for: min(.milliseconds(50), remaining))
                }
            }
            try Task.checkCancellation()
            try lease.assertOwned()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    /// Revalidate immediately before the credential operation being protected.
    public func assertOwned() throws {
        try stateLock.withLock {
            guard !released, !compromised, !directories.isEmpty else { throw MonitorError.credentialChanged }
            do { for directory in directories { try validate(directory) } }
            catch { markCompromised(); throw MonitorError.credentialChanged }
        }
    }

    /// Idempotent. Checks unchanged, fresh ownership before nonrecursive rmdir.
    /// Unexpected contents are never removed. As with proper-lockfile, checking
    /// ownership and removing a path are separate syscalls; arbitrary external
    /// path replacement between them is outside this cooperative protocol.
    public func release() {
        stateLock.withLock {
            guard !released else { return }
            released = true
            timer?.cancel()
            timer = nil
            for directory in directories.reversed() {
                if (try? validate(directory)) != nil {
                    _ = unlinkat(directory.parentDescriptor, directory.name, AT_REMOVEDIR)
                }
                _ = close(directory.descriptor)
                _ = close(directory.parentDescriptor)
            }
            directories.removeAll()
        }
    }

    deinit { release() }

    private func register(_ directory: Directory) throws {
        try stateLock.withLock {
            guard !released, !compromised else { throw MonitorError.credentialChanged }
            try validate(directory)
            directories.append(directory)
            if timer == nil {
                let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Claudock.credential-lock", qos: .utility))
                source.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval, leeway: .milliseconds(10))
                source.setEventHandler { [weak self] in self?.heartbeat() }
                timer = source
                source.resume()
            }
        }
    }

    private func validateAcquiredDirectories() throws {
        try stateLock.withLock {
            guard !released, !compromised else { throw MonitorError.credentialChanged }
            do { for directory in directories { try validate(directory) } }
            catch { markCompromised(); throw MonitorError.credentialChanged }
        }
    }

    private func heartbeat() {
        stateLock.withLock {
            guard !released, !compromised else { return }
            do {
                for directory in directories { try validate(directory) }
                for index in directories.indices {
                    // The descriptor stays bound to our inode even if a stale
                    // recovery removes/replaces the directory concurrently.
                    guard futimes(directories[index].descriptor, nil) == 0 else { throw MonitorError.credentialChanged }
                    directories[index].stamp = Stamp(try Self.directoryMetadata(descriptor: directories[index].descriptor))
                    try validate(directories[index])
                }
            } catch { markCompromised() }
        }
    }

    private func markCompromised() {
        compromised = true
        timer?.cancel()
        timer = nil
    }

    private func validate(_ directory: Directory) throws {
        try Self.validateParent(path: directory.parentPath, descriptor: directory.parentDescriptor, identity: directory.parentIdentity)
        let held = Stamp(try Self.directoryMetadata(descriptor: directory.descriptor))
        var entry = stat()
        guard fstatat(directory.parentDescriptor, directory.name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_mode & S_IFMT == S_IFDIR,
              held == directory.stamp, Stamp(entry) == directory.stamp,
              Date().timeIntervalSince1970 - directory.stamp.modificationTime < staleAfter else {
            throw MonitorError.credentialChanged
        }
    }

    private static func validateParent(path: String, descriptor: Int32, identity: Stamp) throws {
        let held = Stamp(try directoryMetadata(descriptor: descriptor))
        var current = stat()
        guard stat(path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              identity.sameIdentity(as: held), identity.sameIdentity(as: Stamp(current)) else {
            throw MonitorError.credentialChanged
        }
    }

    /// Best-effort rollback of an entry created by this acquisition. Preserve
    /// any changed/replaced entry; never infer ownership from an old pathname.
    private static func removeCreatedDirectory(parentPath: String, name: String, parent: Int32,
                                               parentIdentity: Stamp, stamp: Stamp,
                                               openedDescriptor: Int32? = nil, staleAfter: TimeInterval) {
        guard (try? validateParent(path: parentPath, descriptor: parent, identity: parentIdentity)) != nil else { return }
        if let openedDescriptor {
            guard let held = try? directoryMetadata(descriptor: openedDescriptor), Stamp(held) == stamp else { return }
        }
        var entry = stat()
        let age = Date().timeIntervalSince1970 - stamp.modificationTime
        guard fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_mode & S_IFMT == S_IFDIR, Stamp(entry) == stamp,
              age >= -1, age < staleAfter else { return }
        _ = unlinkat(parent, name, AT_REMOVEDIR)
    }

    private static func directoryMetadata(descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw MonitorError.credentialChanged }
        return metadata
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasSuffix("/") && !path.contains("\0") && !path.contains("\n") && !path.contains("\r") &&
        !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}

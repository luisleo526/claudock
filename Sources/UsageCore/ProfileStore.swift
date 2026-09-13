import Foundation
import Darwin

/// Claudock's authoritative account registry. Shell discovery runs once at bootstrap and
/// subsequently only when explicitly requested. Config paths are never rewritten: Claude's
/// credential store derives account identity from the literal path.
public enum ProfileStore {
    private typealias Failure = ProfileManager.ManagementError
    private static let maximumBytes = 2_097_152

    public static func directory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Claudock", isDirectory: true)
    }

    public static func load(home: String = NSHomeDirectory()) throws -> [Profile] {
        try withState(home: home) { state in state.profiles }
    }

    /// Data-only input for the optional zsh adapter. Prompt hooks must not create
    /// a registry, discover shell files, read credentials, or rewrite account state.
    public static func shellProfileNames(home: String = NSHomeDirectory()) throws -> [String] {
        let snapshot = try Snapshot(directory(home: home).appendingPathComponent("profiles.json"))
        guard let data = snapshot.data else { return [] }
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { throw Failure.invalidManagedFiles }
        try validate(state)
        return sorted(state.profiles).filter {
            $0.managed && !$0.isVertex && $0.discoveryNote == nil && $0.command != "claude"
        }.map(\.command)
    }

    /// Merge newly discovered wrappers without reintroducing removed/renamed profiles.
    /// Existing registry records are authoritative; same-name or same-credential-store imports are skipped.
    public static func importShellProfiles(home: String = NSHomeDirectory()) throws -> [Profile] {
        try withState(home: home) { state in
            for candidate in ProfileDiscovery.discover(home: home) {
                guard !state.suppressedCommands.contains(candidate.command),
                      !isSuppressedDirectory(candidate, state: state),
                      !state.profiles.contains(where: { $0.command == candidate.command }),
                      !state.profiles.contains(where: { sameCredentialIdentity($0, candidate) }) else { continue }
                state.profiles.append(imported(candidate))
            }
            state.profiles = sorted(state.profiles)
            return state.profiles
        }
    }

    public static func add(name: String, configDirectory: String? = nil, home: String = NSHomeDirectory()) throws -> Profile {
        let command = try validatedCommand(name)
        let explicitDirectory = configDirectory.flatMap { $0.isEmpty ? nil : $0 }
        if let path = explicitDirectory {
            guard validPath(path) else { throw Failure.invalidDirectory }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw Failure.invalidDirectory }
        }
        let identifier = UUID().uuidString
        let accountParent = directory(home: home).appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(identifier, isDirectory: true)
        let path = explicitDirectory ?? accountParent.appendingPathComponent("claude", isDirectory: true).path
        return try withState(home: home, createAccount: explicitDirectory == nil ? accountParent : nil) { state in
            let profile = Profile(command: command, configDirectory: path, registryID: identifier, managed: true)
            guard !state.profiles.contains(where: { $0.command == command }) else { throw Failure.duplicateName }
            guard !state.profiles.contains(where: { sameCredentialIdentity($0, profile) }) else { throw Failure.duplicateDirectory }
            guard explicitDirectory != nil || !pathEntryExists(accountParent.path) else { throw Failure.directoryExists }
            state.profiles.append(profile)
            state.profiles = sorted(state.profiles)
            // Explicitly adding an account is allowed after removal. Keep tombstones so
            // the old external shell command cannot be imported as a second identity.
            return profile
        }
    }

    public static func rename(profile: Profile, to name: String, home: String = NSHomeDirectory()) throws -> Profile {
        try requireEditable(profile)
        let command = try validatedCommand(name)
        guard validPath(profile.configDirectory), profile.discoveryNote == nil else { throw Failure.unresolvedProfile }
        return try withState(home: home) { state in
            let index = try currentIndex(profile, in: state)
            if command == profile.command { return state.profiles[index] }
            guard !state.profiles.contains(where: { $0.command == command }) else { throw Failure.duplicateName }
            suppress(profile, in: &state)
            let renamed = Profile(command: command, configDirectory: profile.configDirectory,
                                  isVertex: profile.isVertex, discoveryNote: profile.discoveryNote,
                                  registryID: state.profiles[index].registryID, managed: true)
            state.profiles[index] = renamed
            state.profiles = sorted(state.profiles)
            return renamed
        }
    }

    /// Remove only the registry entry. Login credentials, history, config folders and
    /// user-authored shell functions remain untouched.
    public static func remove(profile: Profile, home: String = NSHomeDirectory()) throws {
        try requireEditable(profile)
        try withState(home: home) { state in
            let index = try currentIndex(profile, in: state)
            suppress(state.profiles[index], in: &state)
            state.profiles.remove(at: index)
        }
    }

    private struct State: Codable {
        var version = 1
        var profiles: [Profile]
        var suppressedCommands: [String] = []
        var suppressedDirectories: [String] = []
    }

    private struct Snapshot {
        let url: URL
        let data: Data?

        init(_ url: URL) throws {
            self.url = url
            guard pathEntryExists(url.path) else { data = nil; return }
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw Failure.invalidManagedFiles }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  status.st_nlink == 1, status.st_uid == geteuid(), status.st_size <= maximumBytes else { throw Failure.invalidManagedFiles }
            guard let contents = try handle.read(upToCount: maximumBytes + 1), contents.count <= maximumBytes else { throw Failure.invalidManagedFiles }
            data = contents
        }

        func unchanged() -> Bool {
            guard let current = try? Snapshot(url) else { return false }
            return current.data == data
        }
    }

    private static func withState<T>(home: String, createAccount: URL? = nil, operation: (inout State) throws -> T) throws -> T {
        let base = directory(home: home)
        do {
            try ensureBase(base)
            let lock = base.appendingPathComponent(".registry-lock")
            let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { throw Failure.invalidManagedFiles }
            defer { _ = close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  status.st_nlink == 1, status.st_uid == geteuid(), fchmod(descriptor, 0o600) == 0 else { throw Failure.invalidManagedFiles }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
            defer { _ = flock(descriptor, LOCK_UN) }
            let snapshot = try Snapshot(base.appendingPathComponent("profiles.json"))
            var state: State
            if let content = snapshot.data {
                guard let decoded = try? JSONDecoder().decode(State.self, from: content) else { throw Failure.invalidManagedFiles }
                state = decoded
                try validate(state)
            } else {
                // The legacy overlay is imported by the same non-executing parser as
                // ordinary wrappers. Its original config paths and scripts are retained.
                state = State(profiles: ProfileDiscovery.discover(home: home).map(imported))
                try validate(state)
            }
            let result = try operation(&state)
            try validate(state)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(state) + Data("\n".utf8)
            guard data.count <= maximumBytes else { throw Failure.invalidManagedFiles }
            guard snapshot.unchanged() else { throw Failure.concurrentChange }
            // Prepare shared sessions/settings before publishing the new profile.
            // Explicit folder imports pass no createAccount and remain untouched.
            let workspace = try createAccount.map { try SharedProfileWorkspace.prepare(accountParent: $0, home: home) }
            defer { workspace?.rollback() }
            try workspace?.validate()
            guard snapshot.unchanged() else { throw Failure.concurrentChange }
            if data != snapshot.data { try atomicWrite(data, to: snapshot.url) }
            workspace?.commit()
            return result
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.ioFailure
        }
    }

    private static func imported(_ profile: Profile) -> Profile {
        Profile(command: profile.command, configDirectory: profile.configDirectory, isVertex: profile.isVertex,
                discoveryNote: profile.discoveryNote, registryID: UUID().uuidString, managed: false)
    }

    private static func sorted(_ profiles: [Profile]) -> [Profile] {
        profiles.sorted {
            if $0.command == $1.command { return false }
            if $0.command == "claude" { return true }
            if $1.command == "claude" { return false }
            return $0.command.localizedStandardCompare($1.command) == .orderedAscending
        }
    }

    private static func suppress(_ profile: Profile, in state: inout State) {
        if !state.suppressedCommands.contains(profile.command) { state.suppressedCommands.append(profile.command) }
        if !profile.configDirectory.isEmpty, !state.suppressedDirectories.contains(profile.configDirectory) { state.suppressedDirectories.append(profile.configDirectory) }
        state.suppressedCommands.sort()
        state.suppressedDirectories.sort()
    }

    private static func isSuppressedDirectory(_ profile: Profile, state: State) -> Bool {
        guard !profile.isVertex, profile.discoveryNote == nil, validPath(profile.configDirectory) else { return false }
        return state.suppressedDirectories.contains {
            $0.precomposedStringWithCanonicalMapping == profile.configDirectory.precomposedStringWithCanonicalMapping
        }
    }

    private static func sameCredentialIdentity(_ first: Profile, _ second: Profile) -> Bool {
        // Claude hashes the NFC literal config path, not its physical directory.
        // Symlink/case aliases may share files while retaining separate Keychain stores.
        guard !first.isVertex, !second.isVertex, first.discoveryNote == nil, second.discoveryNote == nil,
              validPath(first.configDirectory), validPath(second.configDirectory) else { return false }
        return CredentialStore.serviceName(for: first) == CredentialStore.serviceName(for: second)
    }

    private static func currentIndex(_ profile: Profile, in state: State) throws -> Int {
        guard let index = state.profiles.firstIndex(where: { $0.id == profile.id }),
              state.profiles[index] == profile else { throw Failure.missingProfile }
        return index
    }

    private static func validate(_ state: State) throws {
        let ids = state.profiles.compactMap(\.registryID)
        let commands = state.profiles.map(\.command)
        guard state.version == 1, state.profiles.count <= 1_000,
              state.suppressedCommands.count <= 10_000, state.suppressedDirectories.count <= 10_000,
              ids.count == state.profiles.count, Set(ids).count == ids.count,
              ids.allSatisfy({ UUID(uuidString: $0) != nil }), Set(commands).count == commands.count,
              commands.filter({ $0 == "claude" }).count == 1,
              Set(state.suppressedCommands).count == state.suppressedCommands.count,
              Set(state.suppressedDirectories).count == state.suppressedDirectories.count,
              !state.suppressedCommands.contains("claude"),
              commands.allSatisfy(validImportedCommand), state.suppressedCommands.allSatisfy(validImportedCommand),
              state.suppressedDirectories.allSatisfy(validPath),
              state.profiles.allSatisfy({ profile in
                  (validPath(profile.configDirectory) || (profile.configDirectory.isEmpty && profile.discoveryNote != nil)) &&
                  (!profile.managed || (profile.command != "claude" && !profile.isVertex && profile.discoveryNote == nil && (try? validatedCommand(profile.name)) == profile.command))
              }) else { throw Failure.invalidManagedFiles }
    }

    private static func validatedCommand(_ name: String) throws -> String {
        guard name.caseInsensitiveCompare("default") != .orderedSame else { throw Failure.reservedName }
        guard name.range(of: #"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}\z"#, options: .regularExpression) != nil else { throw Failure.invalidName }
        return "claude-" + name
    }

    private static func validImportedCommand(_ command: String) -> Bool {
        if command == "claude" { return true }
        return command.hasPrefix("claude-") && command.count > 7 && command.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0)
        }
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && !path.contains("\n") && !path.contains("\r")
    }

    private static func requireEditable(_ profile: Profile) throws {
        guard profile.command != "claude", !profile.isVertex else { throw Failure.protectedProfile }
        guard validImportedCommand(profile.command) else { throw Failure.invalidName }
    }

    private static func ensureBase(_ base: URL) throws {
        // User-controlled ancestors such as Library may already exist. Only Claudock's
        // own directory is managed, and it must be a real private directory.
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ensurePrivateDirectory(base)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        if !pathEntryExists(url.path), mkdir(url.path, 0o700) != 0, errno != EEXIST { throw Failure.ioFailure }
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid() else { throw Failure.invalidManagedFiles }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.invalidManagedFiles }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, 0o700) == 0 else { throw Failure.ioFailure }
    }

    private static func pathEntryExists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.ioFailure }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlink(temporary.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw Failure.ioFailure }
        let directoryDescriptor = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if directoryDescriptor >= 0 {
            defer { _ = close(directoryDescriptor) }
            _ = fsync(directoryDescriptor)
        }
    }
}

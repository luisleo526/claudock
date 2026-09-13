import Foundation
import Darwin

/// Optional zsh integration. Profile CRUD never needs to call this type.
/// Only Claudock's marked startup block and privately owned files are changed.
public enum ShellIntegration {
    public enum IntegrationError: LocalizedError {
        case invalidExecutable, unsupportedShellFile, unsupportedConfigDirectory
        case customZdotdir, modifiedFiles, concurrentChange, busy, ioFailure

        public var errorDescription: String? {
            switch self {
            case .invalidExecutable:
                return "Choose an installed Claudock executable with an absolute path. Paths cannot contain control characters."
            case .unsupportedShellFile:
                return "Claudock cannot automatically edit a linked or nonregular .zshrc. Add the shell integration manually in your dotfiles, or use Claudock without shell integration."
            case .unsupportedConfigDirectory:
                return "Claudock's .config and .config/claudock folders must be ordinary directories to manage shell integration safely."
            case .customZdotdir:
                return "Your shell declares ZDOTDIR, which can change its startup folder. Add the Claudock command to your own shell configuration manually, or use Claudock without shell integration."
            case .modifiedFiles:
                return "Claudock's shell integration was edited or is incomplete. Restore the marked block and managed files before changing it. Your shell settings have not been replaced."
            case .concurrentChange:
                return "Your shell settings changed while saving. Refresh and try again."
            case .busy:
                return "Another Claudock shell integration update is in progress. Try again in a moment."
            case .ioFailure:
                return "Claudock could not save shell integration. Check that your home and configuration folders are writable."
            }
        }
    }

    private struct State: Codable {
        let version: Int
        let cliPath: String
    }

    private static let startMarker = "# >>> Claudock shell integration >>>"
    private static let endMarker = "# <<< Claudock shell integration <<<"
    private static let block = """
    # >>> Claudock shell integration >>>
    [[ -r "$HOME/.config/claudock/init.zsh" ]] && source "$HOME/.config/claudock/init.zsh"
    # <<< Claudock shell integration <<<

    """

    /// Returns false without creating files when integration has never been enabled.
    /// Throws if existing ownership records, init code, or startup markers disagree.
    public static func status(home: String = NSHomeDirectory()) throws -> Bool {
        let paths = try Paths(home: home)
        try paths.validateDirectories()
        return try read(paths).state != nil
    }

    /// Explicitly opts into shell changes. Calling again refreshes a moved app's CLI path.
    public static func enable(cliPath: String, home: String = NSHomeDirectory()) throws {
        guard validPath(cliPath), FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw IntegrationError.invalidExecutable
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cliPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw IntegrationError.invalidExecutable
        }
        let paths = try Paths(home: home)
        if try declaresZdotdir(in: paths.home.appendingPathComponent(".zshenv")) {
            throw IntegrationError.customZdotdir
        }
        try mutate(home: home) { paths, previous in
            let state = State(version: 3, cliPath: cliPath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let stateData = try encoder.encode(state) + Data("\n".utf8)
            var shell = previous.shellText
            if previous.state == nil {
                if !shell.isEmpty, !shell.hasSuffix("\n") { shell += "\n" }
                shell += block
            }
            // Install runnable code before connecting the startup file to it.
            return [(previous.script, Data(render(state).utf8)),
                    (previous.registry, stateData),
                    (previous.shell, Data(shell.utf8))]
        }
    }

    /// Upgrade an existing, exactly owned adapter without changing its executable
    /// path or opting an unintegrated user into shell changes.
    @discardableResult
    public static func upgradeIfEnabled(home: String = NSHomeDirectory()) throws -> Bool {
        let paths = try Paths(home: home)
        // Off means no managed files, regardless of the user's unrelated dotfiles.
        // In particular, do not inspect an unintegrated symlinked .zshrc.
        var hasManagedFiles = false
        for file in [paths.registry, paths.script] {
            var info = stat()
            if lstat(file.path, &info) == 0 { hasManagedFiles = true }
            else if errno != ENOENT && errno != ENOTDIR { throw IntegrationError.ioFailure }
        }
        guard hasManagedFiles else { return false }
        try paths.validateDirectories()
        guard let version = try read(paths).state?.version, version < 3 else { return false }
        var upgraded = false
        try mutate(home: home, checkShellLocation: false) { _, previous in
            // A concurrent disable or upgrade wins. Never recreate its removed block.
            guard let saved = previous.state, saved.version < 3 else { return [] }
            let state = State(version: 3, cliPath: saved.cliPath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(state) + Data("\n".utf8)
            upgraded = true
            return [(previous.script, Data(render(state).utf8)), (previous.registry, data)]
        }
        return upgraded
    }

    /// Removes only validated Claudock content. Original wrappers and account data remain.
    public static func disable(home: String = NSHomeDirectory()) throws {
        let paths = try Paths(home: home)
        try paths.validateDirectories()
        // Do not create .config or lock files for a no-op disable.
        guard try read(paths).state != nil else { return }
        try mutate(home: home) { _, previous in
            guard previous.state != nil, let range = previous.blockRange else { return [] }
            var shell = previous.shellText
            shell.removeSubrange(range)
            // Disconnect shell startup before removing the code it references.
            return [(previous.shell, Data(shell.utf8)),
                    (previous.script, nil), (previous.registry, nil)]
        }
    }

    private struct Paths {
        let home: URL
        let config: URL
        let base: URL
        var shell: URL { home.appendingPathComponent(".zshrc") }
        var script: URL { base.appendingPathComponent("init.zsh") }
        var registry: URL { base.appendingPathComponent("integration.json") }

        init(home: String) throws {
            guard validPath(home) else { throw IntegrationError.unsupportedConfigDirectory }
            self.home = URL(fileURLWithPath: home, isDirectory: true).resolvingSymlinksInPath()
            self.config = self.home.appendingPathComponent(".config", isDirectory: true)
            self.base = config.appendingPathComponent("claudock", isDirectory: true)
        }

        func validateDirectories() throws {
            for directory in [home, config, base] {
                var info = stat()
                if lstat(directory.path, &info) != 0 {
                    guard errno == ENOENT else { throw IntegrationError.ioFailure }
                    if directory == home { throw IntegrationError.unsupportedConfigDirectory }
                    continue
                }
                guard info.st_mode & S_IFMT == S_IFDIR else { throw IntegrationError.unsupportedConfigDirectory }
            }
        }

        func prepare() throws {
            try validateDirectories()
            for directory in [config, base] {
                if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw IntegrationError.ioFailure }
                try validateDirectories()
            }
        }
    }

    private struct Snapshot {
        let url: URL
        let data: Data?
        let permissions: mode_t

        init(_ url: URL, shell: Bool = false) throws {
            self.url = url
            let error: IntegrationError = shell ? .unsupportedShellFile : .modifiedFiles
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else {
                if errno == ENOENT {
                    // A dangling symlink is an existing entry, not a new file.
                    var info = stat()
                    guard lstat(url.path, &info) != 0, errno == ENOENT else { throw error }
                    data = nil; permissions = 0o600; return
                }
                throw error
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_size <= 2_097_152 else { throw error }
            permissions = info.st_mode & 0o777
            data = try handle.readToEnd() ?? Data()
            guard data!.count <= 2_097_152 else { throw error }
        }

        func unchanged() -> Bool {
            guard let current = try? Snapshot(url, shell: url.lastPathComponent == ".zshrc") else { return false }
            return current.data == data && current.permissions == permissions
        }
    }

    private struct Installation {
        let state: State?
        let registry: Snapshot
        let script: Snapshot
        let shell: Snapshot
        let shellText: String
        let blockRange: Range<String.Index>?
    }

    private static func read(_ paths: Paths) throws -> Installation {
        let registry = try Snapshot(paths.registry)
        let script = try Snapshot(paths.script)
        let shell = try Snapshot(paths.shell, shell: true)
        guard let shellText = String(data: shell.data ?? Data(), encoding: .utf8) else {
            throw IntegrationError.unsupportedShellFile
        }
        let range = try managedRange(in: shellText)
        let state: State?
        if registry.data == nil, script.data == nil, range == nil {
            state = nil
        } else {
            guard let registryData = registry.data,
                  let saved = try? JSONDecoder().decode(State.self, from: registryData),
                  [1, 2, 3].contains(saved.version), validPath(saved.cliPath),
                  script.data == Data(render(saved).utf8), range != nil else {
                throw IntegrationError.modifiedFiles
            }
            // A moved or removed executable does not invalidate ownership, so disabling
            // and refreshing integration still work after an app update or relocation.
            state = saved
        }
        return Installation(state: state, registry: registry, script: script,
                            shell: shell, shellText: shellText, blockRange: range)
    }

    private static func managedRange(in shell: String) throws -> Range<String.Index>? {
        let starts = shell.components(separatedBy: startMarker).count - 1
        let ends = shell.components(separatedBy: endMarker).count - 1
        if starts == 0, ends == 0 { return nil }
        guard starts == 1, ends == 1, let range = shell.range(of: block),
              range.lowerBound == shell.startIndex || shell[shell.index(before: range.lowerBound)] == "\n" else {
            throw IntegrationError.modifiedFiles
        }
        return range
    }

    private static func render(_ state: State) -> String {
        if state.version == 1 { return renderVersionOne(state) }
        if state.version == 2 { return renderVersionTwo(state) }
        return renderVersionThree(state)
    }

    private static func renderVersionThree(_ state: State) -> String {
        let invocationPrefix = quote("command " + quote(state.cliPath) + " run ")
        let autoBody = quote("command " + quote(state.cliPath) + " auto -- \"$@\"")
        return """
        # Managed by Claudock. Change shell integration in Claudock Settings.
        # Adapter v3: managed profile shortcuts and the optional claude-auto command.
        function claudock() {
          command \(quote(state.cliPath)) "$@"
        }

        function _claudock_sync_profiles() {
          emulate -L zsh
          setopt no_aliases
          local _claudock_output
          _claudock_output=$(command \(quote(state.cliPath)) shell profile-names 2>/dev/null) || return 0
          local -a _claudock_lines _claudock_names
          _claudock_lines=("${(@f)_claudock_output}")
          [[ "${_claudock_lines[1]-}" == 'claudock-profile-names-v1' ]] || return 0
          _claudock_names=("${_claudock_lines[@]:1}")
          (( ${#_claudock_names} <= 1000 )) || return 0
          local -A _claudock_seen
          local _claudock_name _claudock_suffix
          # Validate the entire data batch before changing any existing shortcut.
          for _claudock_name in "${_claudock_names[@]}"; do
            [[ "$_claudock_name" == claude-* ]] || return 0
            _claudock_suffix=${_claudock_name#claude-}
            (( ${#_claudock_suffix} >= 1 && ${#_claudock_suffix} <= 40 )) || return 0
            [[ "$_claudock_suffix" != *[^A-Za-z0-9_-]* ]] || return 0
            (( ! ${+_claudock_seen[$_claudock_name]} )) || return 0
            _claudock_seen[$_claudock_name]=1
          done
          local _claudock_auto_reserved=${+_claudock_seen[claude-auto]}
          if [[ -n "${_claudock_auto_body-}" && "${functions[claude-auto]-}" != "$_claudock_auto_body" ]]; then
            unset _claudock_auto_body
          fi
          if (( _claudock_auto_reserved )) && [[ -n "${_claudock_auto_body-}" ]]; then
            builtin unfunction claude-auto
            unset _claudock_auto_body
          fi
          # Forget user replacements; remove only exact bodies installed by us.
          for _claudock_name in "${(@k)_claudock_profile_bodies}"; do
            if [[ "${functions[$_claudock_name]-}" != "${_claudock_profile_bodies[$_claudock_name]}" ]]; then
              unset "_claudock_profile_bodies[$_claudock_name]"
            elif (( ! ${+_claudock_seen[$_claudock_name]} )); then
              builtin unfunction "$_claudock_name"
              unset "_claudock_profile_bodies[$_claudock_name]"
            fi
          done
          local _claudock_prefix=\(invocationPrefix)
          for _claudock_name in "${_claudock_names[@]}"; do
            # A registered profile reserves this name, including imported ones.
            # Keep existing v2/user wrappers; explicit claudock run still works.
            [[ "$_claudock_name" == claude-auto ]] && continue
            if (( ! ${+_claudock_profile_bodies[$_claudock_name]} )) && builtin whence -w -- "$_claudock_name" >/dev/null 2>&1; then
              continue
            fi
            functions[$_claudock_name]="${_claudock_prefix}'${_claudock_name}' -- \\\"\\$@\\\""
            _claudock_profile_bodies[$_claudock_name]="${functions[$_claudock_name]}"
          done
          if (( ! _claudock_auto_reserved )); then
            if [[ -n "${_claudock_auto_body-}" ]] || ! builtin whence -w -- claude-auto >/dev/null 2>&1; then
              functions[claude-auto]=\(autoBody)
              _claudock_auto_body="${functions[claude-auto]}"
            fi
          fi
          return 0
        }

        () {
          emulate -L zsh
          setopt no_aliases
          typeset -gA _claudock_profile_bodies
          typeset -g _claudock_auto_body
          autoload -Uz add-zsh-hook
          add-zsh-hook precmd _claudock_sync_profiles
          add-zsh-hook preexec _claudock_sync_profiles
          _claudock_sync_profiles
        }

        """
    }

    /// Frozen v2 output remains readable for ownership-safe upgrades.
    private static func renderVersionTwo(_ state: State) -> String {
        let invocationPrefix = quote("command " + quote(state.cliPath) + " run ")
        return """
        # Managed by Claudock. Change shell integration in Claudock Settings.
        # Adapter v2: profile shortcuts follow the registry without editing .zshrc.
        function claudock() {
          command \(quote(state.cliPath)) "$@"
        }

        function _claudock_sync_profiles() {
          emulate -L zsh
          setopt no_aliases
          local _claudock_output
          _claudock_output=$(command \(quote(state.cliPath)) shell profile-names 2>/dev/null) || return 0
          local -a _claudock_lines _claudock_names
          _claudock_lines=("${(@f)_claudock_output}")
          [[ "${_claudock_lines[1]-}" == 'claudock-profile-names-v1' ]] || return 0
          _claudock_names=("${_claudock_lines[@]:1}")
          (( ${#_claudock_names} <= 1000 )) || return 0
          local -A _claudock_seen
          local _claudock_name _claudock_suffix
          # Validate the entire data batch before changing any existing shortcut.
          for _claudock_name in "${_claudock_names[@]}"; do
            [[ "$_claudock_name" == claude-* ]] || return 0
            _claudock_suffix=${_claudock_name#claude-}
            (( ${#_claudock_suffix} >= 1 && ${#_claudock_suffix} <= 40 )) || return 0
            [[ "$_claudock_suffix" != *[^A-Za-z0-9_-]* ]] || return 0
            (( ! ${+_claudock_seen[$_claudock_name]} )) || return 0
            _claudock_seen[$_claudock_name]=1
          done
          # Forget user replacements; remove only exact bodies installed by us.
          for _claudock_name in "${(@k)_claudock_profile_bodies}"; do
            if [[ "${functions[$_claudock_name]-}" != "${_claudock_profile_bodies[$_claudock_name]}" ]]; then
              unset "_claudock_profile_bodies[$_claudock_name]"
            elif (( ! ${+_claudock_seen[$_claudock_name]} )); then
              builtin unfunction "$_claudock_name"
              unset "_claudock_profile_bodies[$_claudock_name]"
            fi
          done
          local _claudock_prefix=\(invocationPrefix)
          for _claudock_name in "${_claudock_names[@]}"; do
            if (( ! ${+_claudock_profile_bodies[$_claudock_name]} )) && builtin whence -w -- "$_claudock_name" >/dev/null 2>&1; then
              continue
            fi
            # The selector is validated data. The fixed body uses no eval and
            # forwards every argument literally through the CLI's -- separator.
            functions[$_claudock_name]="${_claudock_prefix}'${_claudock_name}' -- \\\"\\$@\\\""
            _claudock_profile_bodies[$_claudock_name]="${functions[$_claudock_name]}"
          done
          return 0
        }

        () {
          emulate -L zsh
          setopt no_aliases
          typeset -gA _claudock_profile_bodies
          autoload -Uz add-zsh-hook
          add-zsh-hook precmd _claudock_sync_profiles
          add-zsh-hook preexec _claudock_sync_profiles
          _claudock_sync_profiles
        }

        """
    }

    /// Byte-for-byte v1 rendering is retained to distinguish old owned adapters
    /// from edited user code during an upgrade.
    private static func renderVersionOne(_ state: State) -> String {
        """
        # Managed by Claudock. Change shell integration in Claudock Settings.
        # Profiles and credentials are managed separately from this shell entry point.
        function claudock() {
          command \(quote(state.cliPath)) "$@"
        }

        """
    }

    private static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Finder does not inherit variables assigned by shell startup. Inspect declarations
    /// conservatively instead of running arbitrary .zshenv code to discover ZDOTDIR.
    /// This is intentionally not a shell interpreter: indirect assignments may remain
    /// undetectable, and any direct declaration requires user-managed integration.
    private static func declaresZdotdir(in url: URL) throws -> Bool {
        var info = stat()
        if stat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw IntegrationError.customZdotdir }
            return false
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 2_097_152,
              let data = try? Data(contentsOf: url), data.count <= 2_097_152,
              let content = String(data: data, encoding: .utf8) else {
            throw IntegrationError.customZdotdir
        }
        // Handle ordinary comments without treating "#" within quoted values as one.
        let code = content.components(separatedBy: "\n").map { line in
            var result = ""
            var singleQuoted = false
            var doubleQuoted = false
            var escaped = false
            for character in line {
                if escaped { result.append(character); escaped = false; continue }
                if character == "\\", !singleQuoted { result.append(character); escaped = true; continue }
                if character == "'", !doubleQuoted { singleQuoted.toggle() }
                if character == "\"", !singleQuoted { doubleQuoted.toggle() }
                if character == "#", !singleQuoted, !doubleQuoted { break }
                result.append(character)
            }
            return result
        }.joined(separator: "\n")
        let assignment = #"(?:^|[;\s])ZDOTDIR\s*="#
        let declaration = #"(?:^|[;\s])(?:export|typeset|readonly)\s+(?:-[A-Za-z]+\s+)*ZDOTDIR(?=[;\s=]|$)"#
        return code.range(of: assignment, options: .regularExpression) != nil ||
            code.range(of: declaration, options: .regularExpression) != nil
    }

    private static func mutate(home: String, checkShellLocation: Bool = true,
                               operation: (Paths, Installation) throws -> [(Snapshot, Data?)]) throws {
        do {
            let paths = try Paths(home: home)
            if checkShellLocation, let zdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"], !zdotdir.isEmpty,
               URL(fileURLWithPath: zdotdir).resolvingSymlinksInPath() != paths.home {
                throw IntegrationError.customZdotdir
            }
            try paths.prepare()
            let descriptor = open(paths.base.appendingPathComponent(".shell-integration-lock").path,
                                  O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { throw IntegrationError.ioFailure }
            defer { _ = close(descriptor) }
            var lockInfo = stat()
            guard fstat(descriptor, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
                  lockInfo.st_nlink == 1 else { throw IntegrationError.modifiedFiles }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw IntegrationError.busy }
            defer { _ = flock(descriptor, LOCK_UN) }
            try paths.validateDirectories()
            let previous = try read(paths)
            let changes = try operation(paths, previous).filter { $0.0.data != $0.1 }
            guard previous.shell.unchanged(), previous.registry.unchanged(), previous.script.unchanged() else {
                throw IntegrationError.concurrentChange
            }
            if changes.contains(where: { $0.0.url == paths.shell }), let oldShell = previous.shell.data {
                let backup = paths.home.appendingPathComponent(".zshrc.claudock-backup-\(UUID().uuidString)")
                try atomicWrite(oldShell, to: backup, permissions: 0o600)
            }
            var written: [(Snapshot, Data?)] = []
            do {
                for (snapshot, content) in changes {
                    try paths.validateDirectories()
                    guard snapshot.unchanged() else { throw IntegrationError.concurrentChange }
                    if let content {
                        let permissions: mode_t = snapshot.url == paths.shell ? snapshot.permissions : 0o600
                        try atomicWrite(content, to: snapshot.url, permissions: permissions)
                    } else {
                        try FileManager.default.removeItem(at: snapshot.url)
                    }
                    written.append((snapshot, content))
                }
            } catch {
                // Roll back only bytes still matching our write. Never replace a newer
                // external edit with a stale snapshot while handling an error.
                for (snapshot, ourData) in written.reversed() {
                    guard (try? paths.validateDirectories()) != nil,
                          let current = try? Snapshot(snapshot.url), current.data == ourData else { continue }
                    if let oldData = snapshot.data {
                        try? atomicWrite(oldData, to: snapshot.url, permissions: snapshot.permissions)
                    } else {
                        try? FileManager.default.removeItem(at: snapshot.url)
                    }
                }
                throw error
            }
        } catch let error as IntegrationError {
            throw error
        } catch {
            throw IntegrationError.ioFailure
        }
    }

    private static func atomicWrite(_ data: Data, to url: URL, permissions: mode_t) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".claudock-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, permissions)
        guard descriptor >= 0 else { throw IntegrationError.ioFailure }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        guard fchmod(descriptor, permissions) == 0, fsync(descriptor) == 0,
              rename(temporary.path, url.path) == 0 else { throw IntegrationError.ioFailure }
    }
}

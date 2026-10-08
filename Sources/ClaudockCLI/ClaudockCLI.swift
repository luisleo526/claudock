import Foundation
import Darwin
import UsageCore

private enum CLIError: LocalizedError {
    case arguments(String), missingProfile(String), ambiguousProfile(String), missingExecutable, missingOwnExecutable, launchFailed(Int32), invalidEnvironment
    case input(String), missingAPIKey(String), apiKeySignIn(String), subscriptionKey(String)

    var errorDescription: String? {
        switch self {
        case .arguments(let detail): return detail + " Run 'claudock help' for usage."
        case .missingProfile(let name): return "No profile named '\(name)'. Run 'claudock profile list'."
        case .ambiguousProfile(let name): return "More than one profile is named '\(name)'. Use its exact SELECTOR from 'claudock profile list'."
        case .missingExecutable: return "Claude Code was not found. Install Claude Code or locate its executable in Claudock Settings."
        case .missingOwnExecutable: return "Could not locate this Claudock CLI executable. Enable shell integration from Claudock Settings."
        case .launchFailed(let code): return "Could not launch Claude Code: \(String(cString: strerror(code)))."
        case .invalidEnvironment: return "The launch environment contains an invalid value."
        case .input(let detail): return detail
        case .missingAPIKey(let name): return "No Console API key is saved for '\(name)'. Save one with: claudock profile set-key \(name)"
        case .apiKeySignIn(let name): return "'\(name)' uses a Console API key and has no Claude sign-in. Replace its key with: claudock profile set-key \(name)"
        case .subscriptionKey(let name): return "'\(name)' is a Claude subscription profile. Only profiles added with 'claudock profile add NAME --api-key' store a Console API key."
        }
    }
}

/// Validate the complete command before reading profiles, credentials, or shell files.
private enum Command {
    case help, version, list, importShell
    case add(String, String?), addAPIKey(String, String?), setKey(String)
    case rename(String, String), remove(String), login(String), run(String, [String])
    case usage, shellEnable, shellDisable, shellStatus, shellProfileNames
    case removedAuto
    case boundLaunch(String, String, Bool, [String])

    static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { return .help }
        if ["help", "--help", "-h"].contains(first), arguments.count == 1 { return .help }
        if ["version", "--version"].contains(first), arguments.count == 1 { return .version }
        if first == "usage", arguments.count == 1 { return .usage }
        if first == "launch-bound", arguments.count >= 5 {
            let id = try name(arguments[1]), service = arguments[2]
            guard service.range(of: #"\AClaude Code-credentials(?:-[a-f0-9]{8})?\z"#, options: .regularExpression) != nil,
                  ["run", "login"].contains(arguments[3]), arguments[4] == "--",
                  arguments[3] != "login" || arguments.count == 5 else { throw CLIError.arguments("Invalid bound profile launch.") }
            return .boundLaunch(id, service, arguments[3] == "login", Array(arguments.dropFirst(5)))
        }
        if first == "auto" { return .removedAuto }
        if first == "profile", arguments.count >= 2 {
            switch arguments[1] {
            case "list" where arguments.count == 2: return .list
            case "import-shell" where arguments.count == 2: return .importShell
            case "add" where arguments.count >= 3: return try add(name: arguments[2], options: Array(arguments.dropFirst(3)))
            case "set-key" where arguments.count == 3: return .setKey(try name(arguments[2]))
            case "set-key" where arguments.count > 3: throw CLIError.arguments("The key is read from standard input, never from arguments.")
            case "rename" where arguments.count == 4: return .rename(try name(arguments[2]), try newName(arguments[3]))
            case "remove" where arguments.count == 3: return .remove(try name(arguments[2]))
            case "login" where arguments.count == 3: return .login(try name(arguments[2]))
            default: break
            }
        }
        if first == "run", arguments.count >= 2 {
            let profile = try name(arguments[1])
            if arguments.count == 2 { return .run(profile, []) }
            guard arguments[2] == "--" else { throw CLIError.arguments("Separate Claude arguments with '--': claudock run NAME -- CLAUDE_ARGS.") }
            return .run(profile, Array(arguments.dropFirst(3)))
        }
        if first == "shell", arguments.count == 2 {
            switch arguments[1] {
            case "enable": return .shellEnable
            case "disable": return .shellDisable
            case "status": return .shellStatus
            case "profile-names": return .shellProfileNames
            default: break
            }
        }
        throw CLIError.arguments("Unknown command or unexpected arguments.")
    }

    /// `profile add NAME [--api-key] [--directory ABS_PATH]`, options in either order.
    /// A key is never taken from arguments; with --api-key it is read from standard input.
    private static func add(name value: String, options: [String]) throws -> Command {
        let name = try newName(value)
        var apiKey = false, directory: String?
        var index = 0
        while index < options.count {
            if options[index] == "--api-key", !apiKey {
                apiKey = true; index += 1
            } else if options[index] == "--directory", directory == nil, index + 1 < options.count {
                let path = options[index + 1]
                guard path.hasPrefix("/"), !path.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
                    throw CLIError.arguments("--directory requires an absolute directory path.")
                }
                directory = path; index += 2
            } else if options[index].hasPrefix("--api-key=") || (apiKey && !options[index].hasPrefix("-")) {
                throw CLIError.arguments("--api-key takes no value. The key is read from standard input, never from arguments.")
            } else {
                throw CLIError.arguments("Unknown command or unexpected arguments.")
            }
        }
        return apiKey ? .addAPIKey(name, directory) : .add(name, directory)
    }

    private static func name(_ value: String) throws -> String {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
            throw CLIError.arguments("Use a profile name or its exact claude-NAME selector.")
        }
        return value
    }

    private static func newName(_ value: String) throws -> String {
        guard !["default", "auto"].contains(value.lowercased()) else {
            throw CLIError.arguments("The profile names 'default' and 'auto' are reserved. Choose another name.")
        }
        guard value.range(of: #"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}\z"#, options: .regularExpression) != nil else {
            throw CLIError.arguments("Use 1–40 letters, numbers, underscores, or hyphens, starting with a letter or number.")
        }
        return value
    }
}

@main
private struct ClaudockCLI {
    static func main() async {
        do { try await execute(Command.parse(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            writeError(error.localizedDescription)
            exit(error is CLIError && isArgumentError(error) ? 2 : 1)
        }
    }

    private static func isArgumentError(_ error: Error) -> Bool {
        if case CLIError.arguments = error { return true }
        return false
    }

    private static func execute(_ command: Command) async throws {
        switch command {
        case .help: print(help)
        case .version: print("Claudock 1.6.0")
        case .list:
            let profiles = try ProfileStore.load()
            print("PROFILE\tSELECTOR\tKIND\tCONFIG_DIRECTORY")
            for profile in profiles {
                let kind = profile.discoveryNote != nil ? "needs-import" : profile.isVertex ? "vertex"
                    : profile.authKind == .apiKey ? "api-key" : profile.managed ? "managed" : "imported"
                print([profile.name, profile.command, kind, profile.configDirectory].map(field).joined(separator: "\t"))
            }
        case .importShell:
            let profiles = try ProfileStore.importShellProfiles()
            print("Imported shell configuration. \(profiles.count) profiles are available. Original shell files were preserved.")
        case .add(let name, let directory):
            let profile = try ProfileStore.add(name: name, configDirectory: directory)
            print("Added \(profile.name). Sign in with: claudock profile login \(profile.name)")
        case .addAPIKey(let name, let directory):
            // Validate the key before the registry is touched.
            let key = try ConsoleAPIKey(parsing: SecretInput.read(prompt: "Console API key: "))
            let profile = try ProfileStore.addAPIKeyProfile(name: name, apiKey: key, configDirectory: directory)
            print("Added \(profile.name) with its Console API key saved in Keychain. Start it with: claudock run \(profile.name)")
            print("The first interactive launch asks whether to use the API key; choose Yes.")
        case .setKey(let name):
            let profile = try resolve(name)
            guard profile.authKind == .apiKey else { throw CLIError.subscriptionKey(profile.name) }
            let key = try ConsoleAPIKey(parsing: SecretInput.read(prompt: "Console API key: "))
            try APIKeyStore.save(key, profile: profile)
            print("Saved a new Console API key for \(profile.name) in Keychain.")
        case .rename(let name, let replacement):
            let renamed = try ProfileStore.rename(profile: resolve(name), to: replacement)
            print("Renamed to \(renamed.name). Claude data and login were preserved.")
        case .remove(let name):
            let profile = try resolve(name)
            try ProfileStore.remove(profile: profile)
            if profile.authKind == .apiKey {
                let service = APIKeyStore.serviceName(for: profile)
                print("Removed \(name) from Claudock. Claude data, its Console API key, and your own shell commands were preserved.")
                print("The key stays in Keychain under service \(service). To delete it: security delete-generic-password -s \(service)")
            } else {
                print("Removed \(name) from Claudock. Claude data, credentials, and your own shell commands were preserved.")
            }
        case .login(let name):
            let profile = try resolve(name)
            guard profile.authKind == .subscription else { throw CLIError.apiKeySignIn(profile.name) }
            try launch(profile: profile, arguments: ["auth", "login", "--claudeai"])
        case .run(let name, let arguments):
            try launch(profile: resolve(name), arguments: arguments, useMint: true)
        case .removedAuto:
            FileHandle.standardError.write(Data("Claudock Auto has been removed. Use 'claudock run PROFILE' to start Claude with a specific profile.\n".utf8))
            exit(2)
        case .boundLaunch(let id, let service, let login, let arguments):
            let profiles = try ProfileStore.load()
            let matches = profiles.filter { $0.id == id }
            guard matches.count == 1, let profile = matches.first, CredentialStore.serviceName(for: profile) == service else {
                throw CLIError.arguments("The selected profile changed. Choose it again in Claudock.")
            }
            if login, profile.authKind != .subscription { throw CLIError.apiKeySignIn(profile.name) }
            try launch(profile: profile, arguments: login ? ["auth", "login", "--claudeai"] : arguments, useMint: !login)
        case .usage:
            try await usage()
        case .shellEnable:
            try ShellIntegration.enable(cliPath: currentExecutable())
            print("Claudock shell integration enabled. Open a new Terminal tab to use 'claudock' and managed 'claude-NAME' shortcuts.")
        case .shellDisable:
            try ShellIntegration.disable()
            print("Claudock shell integration disabled. Open a new Terminal tab to unload it.")
        case .shellStatus:
            print(try ShellIntegration.status() ? "enabled" : "disabled")
        case .shellProfileNames:
            let names = try ProfileStore.shellProfileNames()
            print("claudock-profile-names-v1")
            for name in names { print(name) }
        }
    }

    private static func currentExecutable() throws -> String {
        // Bundle.main inside an .app can identify its GUI CFBundleExecutable.
        // Ask dyld for this process's actual CLI executable instead.
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0, size <= 1_048_576 else { throw CLIError.missingOwnExecutable }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw CLIError.missingOwnExecutable }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func resolve(_ name: String) throws -> Profile {
        let profiles = try ProfileStore.load()
        if let exact = profiles.first(where: { $0.command == name }) { return exact }
        let matches = profiles.filter { $0.name == name }
        guard matches.count <= 1 else { throw CLIError.ambiguousProfile(name) }
        guard let profile = matches.first else {
            throw CLIError.missingProfile(name)
        }
        return profile
    }

    private static func launch(profile: Profile, arguments: [String], useMint: Bool = false) throws {
        guard let executable = ClaudeExecutable.find() else { throw CLIError.missingExecutable }
        var environment = try LaunchCommand.environment(profile: profile, inherited: ProcessInfo.processInfo.environment)
        switch profile.authKind {
        case .apiKey:
            // Inherited credentials were cleared above; the key is the only one, and no inference token is used.
            guard let key = try APIKeyStore.environmentKey(profile: profile) else { throw CLIError.missingAPIKey(profile.name) }
            environment["ANTHROPIC_API_KEY"] = key
        case .subscription:
            if useMint, let token = try InferenceCredential.environmentToken(profile: profile) { environment["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        }
        let argumentStrings = [executable] + arguments
        guard argumentStrings.allSatisfy({ !$0.contains("\0") }), environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw CLIError.invalidEnvironment
        }
        // Replace this process so the terminal, working directory, signals, and exit
        // status belong directly to Claude. User arguments never pass through a shell.
        let argv = argumentStrings.map { strdup($0) } + [nil]
        let envp = environment.keys.sorted().map { strdup($0 + "=" + environment[$0]!) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw CLIError.launchFailed(ENOMEM)
        }
        _ = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { variables in
                execve(executable, arguments.baseAddress!, variables.baseAddress!)
            }
        }
        throw CLIError.launchFailed(errno)
    }

    private static func usage() async throws {
        let profiles = try ProfileStore.load()
        let formatter = ISO8601DateFormatter()
        var failed = false
        print("PROFILE\tPLAN\tWINDOW\tUSED_PERCENT\tRESETS_UTC")
        for profile in profiles {
            guard profile.discoveryNote == nil, !profile.isVertex, !profile.configDirectory.isEmpty else {
                writeError("\(field(profile.name)): skipped; this profile does not support subscription usage.")
                continue
            }
            guard profile.authKind == .subscription else {
                writeError("\(field(profile.name)): skipped; Console API key profiles are billed per token and have no subscription limits.")
                continue
            }
            do {
                let credentials = try CredentialStore.read(profile: profile)
                let snapshot = try await UsageClient.fetch(credentials: credentials)
                for window in snapshot.windows {
                    let percent = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), window.percent)
                    print([profile.name, credentials.subscriptionPlan.displayName, window.title, percent, window.resetsAt.map(formatter.string(from:)) ?? "unknown"].map(field).joined(separator: "\t"))
                }
            } catch {
                failed = true
                writeError("\(field(profile.name)): \(error.localizedDescription)")
            }
        }
        if failed { exit(1) }
    }

    private static func field(_ string: String) -> String {
        string.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(("claudock: " + field(message) + "\n").utf8))
    }

    private static let help = """
    Claudock — Claude Code profiles, together

    Usage:
      claudock profile list
      claudock profile add NAME [--directory ABS_PATH]
      claudock profile add NAME --api-key [--directory ABS_PATH]
      claudock profile set-key NAME
      claudock profile rename NAME NEWNAME
      claudock profile remove NAME
      claudock profile login NAME
      claudock profile import-shell
      claudock run NAME [-- CLAUDE_ARGS...]
      claudock usage
      claudock shell enable|disable|status
      claudock version

    Profiles are stored by Claudock. Adding, renaming, or removing a profile
    does not edit .zshrc. Removal keeps Claude data and credentials.
    Profile names or exact SELECTOR values select a profile. An exact selector
    takes precedence; ambiguous display names require the selector from 'list'.
    Selectors are profile identifiers; they do not create shell commands.
    'run' and 'profile login' use the current terminal and working directory.
    'usage' requests subscription quota once for each supported profile; output
    is tab-separated and contains no account emails or credentials.
    Shell integration is optional. 'shell enable' adds Claudock's marked zsh
    loader; disable removes only that integration. Existing wrappers stay intact.

    Console API keys: 'profile add NAME --api-key' creates a profile that runs
    Claude Code with a Claude Console API key, billed per token rather than by
    a subscription. 'profile set-key NAME' replaces its key. Keys are read from
    standard input, never from arguments: at a terminal Claudock prompts without
    echoing, otherwise it reads the piped input. Keys are stored only in the
    macOS Keychain and reach Claude as ANTHROPIC_API_KEY. The first interactive
    launch asks whether to use the key; choose Yes. 'usage' skips these profiles.

    Examples:
      claudock profile add work
      claudock profile login work
      claudock run work
      claude-work                    After enabling shell integration
      claudock run work -- --resume
      pbpaste | claudock profile add console --api-key
      claudock run console -- --resume
    """
}

/// Reads one secret from standard input, never from arguments. At a terminal the prompt goes
/// to stderr and echo stays off until the line is read; the terminal settings come back on
/// every exit path, including signals. Piped input is read to its end, up to 4 KiB.
private enum SecretInput {
    private static let limit = 4096
    private static let terminating = [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGALRM, SIGTERM]
    private static let stopping = [SIGTSTP, SIGTTIN, SIGTTOU]
    // Plain memory, not Swift globals: the signal handler must not trigger exclusivity checks.
    nonisolated(unsafe) fileprivate static let saved = UnsafeMutablePointer<termios>.allocate(capacity: 1)
    nonisolated(unsafe) fileprivate static let stopped = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: 1)

    static func read(prompt: String) throws -> String {
        let data = isatty(STDIN_FILENO) == 1 ? try readTerminal(prompt: prompt) : try readPiped()
        guard let text = String(data: data, encoding: .utf8) else { throw CLIError.input("Standard input is not UTF-8 text.") }
        return text
    }

    private static func readPiped() throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CLIError.input("Could not read standard input.") }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw CLIError.input("Standard input is larger than 4 KiB.") }
        }
    }

    private static func readTerminal(prompt: String) throws -> Data {
        guard tcgetattr(STDIN_FILENO, saved) == 0 else { throw CLIError.input("Could not read the terminal settings.") }
        stopped.pointee = 0
        var previous: [(Int32, sigaction)] = []
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, saved)
            for (signal, action) in previous { var action = action; _ = sigaction(signal, &action, nil) }
        }
        var data = Data()
        prompting: while true {
            // Hide input before installing handlers: a background job gets SIGTTOU here and
            // waits with its default action. TCSAFLUSH drops anything typed before the prompt.
            var hidden = saved.pointee
            hidden.c_lflag &= ~tcflag_t(ECHO | ECHONL)
            while tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) != 0 {
                guard errno == EINTR else { throw CLIError.input("Could not hide terminal input.") }
            }
            for signal in terminating + stopping {
                var action = sigaction(), old = sigaction()
                action.__sigaction_u.__sa_handler = restoreTerminalAndResignal
                sigemptyset(&action.sa_mask)
                if sigaction(signal, &action, &old) == 0, !previous.contains(where: { $0.0 == signal }) { previous.append((signal, old)) }
            }
            writeStandardError(prompt)
            data = Data()
            while true {
                // A signal can be handled on another thread without interrupting this one, so wait
                // in short polls: after a stop and continue, input is hidden again before more is read.
                if stopped.pointee != 0 { stopped.pointee = 0; continue prompting }
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw CLIError.input("Could not read the terminal.") }
                var byte: UInt8 = 0
                let count = Darwin.read(STDIN_FILENO, &byte, 1)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw CLIError.input("Could not read the terminal.") }
                if count == 0 || byte == 0x0A { break prompting }
                data.append(byte)
                guard data.count <= limit else { throw CLIError.input("The input is larger than 4 KiB.") }
            }
        }
        writeStandardError("\n")
        return data
    }

    /// Writes to stderr directly; retrying EINTR keeps a stopped-and-resumed prompt intact.
    private static func writeStandardError(_ text: String) {
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBufferPointer { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            written += count
        }
    }
}

/// Async-signal-safe: restore the saved terminal, then deliver the signal again with its default
/// action. A stop is remembered so the prompt hides input again after the process continues.
private let restoreTerminalAndResignal: @convention(c) (Int32) -> Void = { signal in
    _ = tcsetattr(STDIN_FILENO, TCSANOW, SecretInput.saved)
    if signal == SIGTSTP || signal == SIGTTIN || signal == SIGTTOU { SecretInput.stopped.pointee = 1 }
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

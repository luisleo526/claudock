import Foundation
import Darwin
import UsageCore

private enum CLIError: LocalizedError {
    case arguments(String), missingProfile(String), ambiguousProfile(String), missingExecutable, missingOwnExecutable, launchFailed(Int32), invalidEnvironment

    var errorDescription: String? {
        switch self {
        case .arguments(let detail): return detail + " Run 'claudock help' for usage."
        case .missingProfile(let name): return "No profile named '\(name)'. Run 'claudock profile list'."
        case .ambiguousProfile(let name): return "More than one profile is named '\(name)'. Use its exact SELECTOR from 'claudock profile list'."
        case .missingExecutable: return "Claude Code was not found. Install Claude Code or locate its executable in Claudock Settings."
        case .missingOwnExecutable: return "Could not locate this Claudock CLI executable. Enable shell integration from Claudock Settings."
        case .launchFailed(let code): return "Could not launch Claude Code: \(String(cString: strerror(code)))."
        case .invalidEnvironment: return "The launch environment contains an invalid value."
        }
    }
}

/// Validate the complete command before reading profiles, credentials, or shell files.
private enum Command {
    case help, version, list, importShell
    case add(String, String?), rename(String, String), remove(String), login(String), run(String, [String])
    case usage, shellEnable, shellDisable, shellStatus, shellProfileNames

    static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { return .help }
        if ["help", "--help", "-h"].contains(first), arguments.count == 1 { return .help }
        if ["version", "--version"].contains(first), arguments.count == 1 { return .version }
        if first == "usage", arguments.count == 1 { return .usage }
        if first == "profile", arguments.count >= 2 {
            switch arguments[1] {
            case "list" where arguments.count == 2: return .list
            case "import-shell" where arguments.count == 2: return .importShell
            case "add" where arguments.count == 3: return .add(try newName(arguments[2]), nil)
            case "add" where arguments.count == 5 && arguments[3] == "--directory":
                guard arguments[4].hasPrefix("/"), !arguments[4].contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
                    throw CLIError.arguments("--directory requires an absolute directory path.")
                }
                return .add(try newName(arguments[2]), arguments[4])
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

    private static func name(_ value: String) throws -> String {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
            throw CLIError.arguments("Use a profile name or its exact claude-NAME selector.")
        }
        return value
    }

    private static func newName(_ value: String) throws -> String {
        guard value.caseInsensitiveCompare("default") != .orderedSame else {
            throw CLIError.arguments("The name 'default' is reserved for Claude's default account.")
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
        case .version: print("Claudock 1.4.0")
        case .list:
            let profiles = try ProfileStore.load()
            print("PROFILE\tSELECTOR\tKIND\tCONFIG_DIRECTORY")
            for profile in profiles {
                let kind = profile.discoveryNote != nil ? "needs-import" : (profile.isVertex ? "vertex" : (profile.managed ? "managed" : "imported"))
                print([profile.name, profile.command, kind, profile.configDirectory].map(field).joined(separator: "\t"))
            }
        case .importShell:
            let profiles = try ProfileStore.importShellProfiles()
            print("Imported shell configuration. \(profiles.count) profiles are available. Original shell files were preserved.")
        case .add(let name, let directory):
            let profile = try ProfileStore.add(name: name, configDirectory: directory)
            print("Added \(profile.name). Sign in with: claudock profile login \(profile.name)")
        case .rename(let name, let replacement):
            let renamed = try ProfileStore.rename(profile: resolve(name), to: replacement)
            print("Renamed to \(renamed.name). Claude data and login were preserved.")
        case .remove(let name):
            try ProfileStore.remove(profile: resolve(name))
            print("Removed \(name) from Claudock. Claude data, credentials, and your own shell commands were preserved.")
        case .login(let name):
            try launch(profile: resolve(name), arguments: ["auth", "login", "--claudeai"])
        case .run(let name, let arguments):
            try launch(profile: resolve(name), arguments: arguments)
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

    private static func launch(profile: Profile, arguments: [String]) throws {
        guard let executable = ClaudeExecutable.find() else { throw CLIError.missingExecutable }
        let environment = try LaunchCommand.environment(profile: profile, inherited: ProcessInfo.processInfo.environment)
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
        print("PROFILE\tWINDOW\tUSED_PERCENT\tRESETS_UTC")
        for profile in profiles {
            guard profile.discoveryNote == nil, !profile.isVertex, !profile.configDirectory.isEmpty else {
                writeError("\(field(profile.name)): skipped; this profile does not support subscription usage.")
                continue
            }
            do {
                let credentials = try CredentialStore.read(profile: profile)
                let snapshot = try await UsageClient.fetch(credentials: credentials)
                for window in snapshot.windows {
                    let percent = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), window.percent)
                    print([profile.name, window.title, percent, window.resetsAt.map(formatter.string(from:)) ?? "unknown"].map(field).joined(separator: "\t"))
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

    Examples:
      claudock profile add work
      claudock profile login work
      claudock run work
      claude-work                    After enabling shell integration
      claudock run work -- --resume
    """
}

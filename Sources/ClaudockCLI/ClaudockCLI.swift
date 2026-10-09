import Foundation
import Darwin
import UsageCore

private enum CLIError: LocalizedError {
    case arguments(String), missingProfile(String), ambiguousProfile(String), missingExecutable, missingOwnExecutable, launchFailed(Int32), invalidEnvironment
    case input(String), missingAPIKey(String), apiKeySignIn(String), subscriptionKey(String), apiKeyToken(String), expiredToken(String)
    case tokenAccountMismatch(String)

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
        case .apiKeyToken(let name): return "'\(name)' uses a Console API key. Inference tokens are only for Claude subscription profiles."
        case .expiredToken(let name):
            return "The inference token saved for '\(name)' has expired. Make a new one: claudock profile setup-token \(name), then pbpaste | claudock profile set-token \(name)."
        case .tokenAccountMismatch(let name):
            return "\(name)'s saved inference token belongs to a different account than its current Claude login. "
                + "Sign in with the token's account: claudock profile login \(name) — or make a new token: "
                + "claudock profile setup-token \(name), then pbpaste | claudock profile set-token \(name)."
        }
    }
}

/// Validate the complete command before reading profiles, credentials, or shell files.
private enum Command {
    case help, version, list, importShell
    case add(String, String?), addAPIKey(String, String?), setKey(String), setToken(String, Date?), setupToken(String), tokens
    case setCredit(String, Decimal)
    case rename(String, String), remove(String), login(String), run(String, [String])
    case usage, shellEnable, shellDisable, shellStatus, shellProfileNames
    /// nil prints the current setting.
    case requireToken(Bool?)
    case removedAuto
    case boundLaunch(String, String, Bool, [String])

    static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { return .help }
        if ["help", "--help", "-h"].contains(first), arguments.count == 1 { return .help }
        if ["version", "--version"].contains(first), arguments.count == 1 { return .version }
        if first == "usage", arguments.count == 1 { return .usage }
        if first == "require-token", arguments.count == 2 {
            switch arguments[1] {
            case "on": return .requireToken(true)
            case "off": return .requireToken(false)
            case "status": return .requireToken(nil)
            default: break
            }
        }
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
            case "set-token" where arguments.count == 3: return .setToken(try name(arguments[2]), nil)
            case "set-token" where arguments.count == 5 && arguments[3] == "--expires": return .setToken(try name(arguments[2]), try expiry(arguments[4]))
            case "set-token" where arguments.count > 3:
                throw CLIError.arguments("The token is read from standard input, never from arguments: claudock profile set-token NAME [--expires ISO8601_DATE].")
            case "setup-token" where arguments.count == 3: return .setupToken(try name(arguments[2]))
            case "setup-token" where arguments.count > 3:
                throw CLIError.arguments("profile setup-token takes only a profile name: claudock profile setup-token NAME.")
            case "tokens" where arguments.count == 2: return .tokens
            case "set-credit" where arguments.count == 4: return .setCredit(try name(arguments[2]), try creditAmount(arguments[3]))
            case "set-credit" where arguments.count > 2:
                throw CLIError.arguments("profile set-credit takes a profile name and an amount in US dollars: claudock profile set-credit NAME AMOUNT.")
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

    /// An ISO 8601 date and time (2026-12-31T23:59:59Z) or a full date (2026-12-31, midnight UTC).
    private static func expiry(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        throw CLIError.arguments("--expires needs an ISO 8601 date, such as 2026-12-31 or 2026-12-31T23:59:59Z.")
    }

    /// The remaining Console credit in US dollars; the input is never echoed.
    private static func creditAmount(_ value: String) throws -> Decimal {
        do { return try APICreditAmount.parse(value) }
        catch { throw CLIError.arguments(APICreditError.invalidAmount.localizedDescription) }
    }

    /// A Claude key or token typed where a profile name belongs must not be echoed in an error.
    private static func rejectCredential(_ value: String) throws {
        guard !value.lowercased().hasPrefix("sk-ant-") else {
            throw CLIError.arguments("That looks like a Claude key or token, not a profile name. Keys and tokens are read from standard input, never from arguments.")
        }
    }

    private static func name(_ value: String) throws -> String {
        try rejectCredential(value)
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
            throw CLIError.arguments("Use a profile name or its exact claude-NAME selector.")
        }
        return value
    }

    private static func newName(_ value: String) throws -> String {
        try rejectCredential(value)
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
        case .setToken(let name, let expiry):
            let profile = try resolve(name)
            guard profile.authKind == .subscription else { throw CLIError.apiKeyToken(profile.name) }
            guard profile.discoveryNote == nil, !profile.isVertex, !profile.configDirectory.isEmpty else { throw MintTokenError.unsupportedProfile }
            let token = try MintTokenStore.importToken(raw: SecretInput.read(prompt: "Inference token: "), profile: profile, expiresAt: expiry)
            print("Saved an inference token for \(profile.name) in Keychain; 'claudock run \(profile.name)' uses it. "
                  + "Expires: \(token.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"). Its account is not verified.")
        case .setupToken(let name):
            let profile = try resolve(name)
            guard profile.authKind == .subscription else { throw CLIError.apiKeyToken(profile.name) }
            // Runs like sign-in, on the profile's own login: the saved token and the token requirement play no part.
            try launch(profile: profile, arguments: ["setup-token"], signIn: true,
                       notice: "Sign the browser in to the claude.ai account for \(profile.name) first. "
                           + "When the token is shown, save it with: pbpaste | claudock profile set-token \(profile.name)")
        case .setCredit(let name, let amount):
            let profile = try resolve(name)
            guard profile.authKind == .apiKey else { throw APICreditError.subscriptionProfile(profile.name) }
            let credit = try APICreditStore.setBalance(amount, profile: profile)
            print("Set \(profile.name)'s Console credit to \(credit.balanceText) as of \(ISO8601DateFormatter().string(from: credit.asOf)). "
                  + "'claudock usage' shows what is left after the Claude Code sessions Claudock starts on this Mac; "
                  + "set it again from the Console balance any time.")
        case .tokens:
            let profiles = try ProfileStore.load()
            print("PROFILE\tTOKEN_STATUS\tEXPIRES_UTC")
            for profile in profiles {
                let status = tokenStatus(profile)
                print([profile.name, status.0, status.1].map(field).joined(separator: "\t"))
            }
            FileHandle.standardError.write(Data("require-token: \(InferenceTokenPolicy.isRequired() ? "on" : "off")\n".utf8))
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
            try launch(profile: profile, arguments: ["auth", "login", "--claudeai"], signIn: true)
        case .run(let name, let arguments):
            try launch(profile: resolve(name), arguments: arguments)
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
            try launch(profile: profile, arguments: login ? ["auth", "login", "--claudeai"] : arguments, signIn: login)
        case .usage:
            try await usage()
        case .requireToken(let required?):
            try InferenceTokenPolicy.setRequired(required)
            print(required
                  ? "Claudock now requires an inference token to launch subscription profiles; it no longer falls back to their normal login."
                  : "Claudock no longer requires an inference token; subscription profiles without one launch with their normal login.")
        case .requireToken(nil):
            print(InferenceTokenPolicy.isRequired() ? "on" : "off")
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

    /// Sign-in and token creation (`signIn`) run on the profile's own login and are never subject to the inference-token
    /// requirement. A `notice` goes to stderr just before Claude replaces this process, so a refused launch prints none.
    private static func launch(profile: Profile, arguments: [String], signIn: Bool = false, notice: String? = nil) throws {
        guard let executable = ClaudeExecutable.find() else { throw CLIError.missingExecutable }
        var environment = try LaunchCommand.environment(profile: profile, inherited: ProcessInfo.processInfo.environment)
        let credential: LaunchCredential
        do { credential = try InferenceTokenPolicy.launchCredential(profile: profile, claudeArguments: arguments, signIn: signIn) }
        catch MintTokenError.tokenExpired { throw CLIError.expiredToken(profile.name) }
        // Both mean the saved token's account is not the profile's current login: reading raises the first, saving the second.
        catch MintTokenError.accountMismatch, MintTokenError.accountChanged { throw CLIError.tokenAccountMismatch(profile.name) }
        // Inherited credentials were cleared above, so the chosen one is the only one.
        switch credential {
        case .consoleAPIKey:
            guard let key = try APIKeyStore.environmentKey(profile: profile) else { throw CLIError.missingAPIKey(profile.name) }
            environment["ANTHROPIC_API_KEY"] = key
        case .inferenceToken(let token): environment["CLAUDE_CODE_OAUTH_TOKEN"] = token
        case .profileLogin: break
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
        if let notice { FileHandle.standardError.write(Data((field(notice) + "\n").utf8)) }
        if case .consoleAPIKey = credential {
            // A child process instead of execve: Claude Code reports each request's cost to Claudock while it runs.
            do {
                exit(try APICreditLaunch.run(profile: profile, executable: executable, arguments: arguments, environment: environment,
                                             warn: writeError))
            } catch APICreditLaunchError.receiverUnavailable {
                writeError("Could not start Claudock's local usage receiver; this run's spend is not counted toward the Console credit.")
            } catch APICreditLaunchError.launchFailed(let code) {
                throw CLIError.launchFailed(code)
            }
        }
        _ = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { variables in
                execve(executable, arguments.baseAddress!, variables.baseAddress!)
            }
        }
        throw CLIError.launchFailed(errno)
    }

    /// Status and expiry for `profile tokens`; never token material.
    private static func tokenStatus(_ profile: Profile) -> (String, String) {
        guard profile.authKind == .subscription, profile.discoveryNote == nil, !profile.isVertex, !profile.configDirectory.isEmpty else {
            return ("n/a", "-")
        }
        let formatter = ISO8601DateFormatter()
        do {
            switch try MintTokenStore.status(profile: profile) {
            case .notConfigured: return ("none", "-")
            case .active(let expiry): return ("active", formatter.string(from: expiry))
            case .expired(let expiry): return ("expired", formatter.string(from: expiry))
            case .imported(let expiry): return ("pasted-unverified", expiry.map(formatter.string(from:)) ?? "unknown")
            }
        } catch { return ("unavailable", "-") }
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
                do {
                    if let credit = try APICreditStore.status(profile: profile) {
                        print([profile.name, APICreditStatus.plan, credit.usageWindow, credit.usedPercentText, "-"].map(field).joined(separator: "\t"))
                    } else {
                        writeError("\(field(profile.name)): skipped; Console API key profiles are billed per token and have no subscription limits. "
                                   + "Set its balance with: claudock profile set-credit \(profile.name) AMOUNT")
                    }
                } catch {
                    failed = true
                    writeError("\(field(profile.name)): \(error.localizedDescription)")
                }
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
      claudock profile set-credit NAME AMOUNT
      claudock profile set-token NAME [--expires ISO8601_DATE]
      claudock profile setup-token NAME
      claudock profile tokens
      claudock profile rename NAME NEWNAME
      claudock profile remove NAME
      claudock profile login NAME
      claudock profile import-shell
      claudock run NAME [-- CLAUDE_ARGS...]
      claudock usage
      claudock require-token on|off|status
      claudock shell enable|disable|status
      claudock version

    Profiles are stored by Claudock. Adding, renaming, or removing a profile
    does not edit .zshrc. Removal keeps Claude data and credentials.
    Profile names or exact SELECTOR values select a profile. An exact selector
    takes precedence; ambiguous display names require the selector from 'list'.
    Selectors are profile identifiers; they do not create shell commands.
    'run', 'profile login', and 'profile setup-token' use the current terminal and
    working directory.
    'usage' requests subscription quota once for each supported profile and
    lists the Console credit left on API-key profiles; output is tab-separated
    and contains no account emails or credentials.
    Shell integration is optional. 'shell enable' adds Claudock's marked zsh
    loader; disable removes only that integration. Existing wrappers stay intact.

    Console API keys: 'profile add NAME --api-key' creates a profile that runs
    Claude Code with a Claude Console API key, billed per token rather than by
    a subscription. 'profile set-key NAME' replaces its key. Keys are read from
    standard input, never from arguments: at a terminal Claudock prompts without
    echoing, otherwise it reads the piped input. Keys are stored only in the
    macOS Keychain and reach Claude as ANTHROPIC_API_KEY. The first interactive
    launch asks whether to use the key; choose Yes.

    Console credit: 'profile set-credit NAME AMOUNT' records the remaining
    prepaid credit shown in the Claude Console for an API-key profile, in US
    dollars (such as 200 or 187.42). 'usage' then lists what is left, less the
    cost Claude Code reports for each request in sessions Claudock starts on
    this Mac; for that, these launches run Claude as a child of claudock with
    OpenTelemetry log export to 127.0.0.1. Use of the same key elsewhere (other
    Macs, scripts, other tools) is not seen. The Console balance is
    authoritative: set it again any time. Without a credit, 'usage' skips the
    profile.

    Inference tokens: 'profile set-token NAME' saves a long-lived Claude Code
    OAuth token (sk-ant-oat01-…, or its export CLAUDE_CODE_OAUTH_TOKEN=… line)
    for a subscription profile. It is read from standard input like a key, and
    'run' passes it to Claude as CLAUDE_CODE_OAUTH_TOKEN. --expires records a
    known expiry. 'profile tokens' lists each profile's token status and expiry,
    never the token. To create a token, run Claude Code's own command for the
    profile. It signs in through your browser, so the browser must be signed in
    to the matching claude.ai account. Then copy the printed token and save it:
      claudock profile setup-token NAME
      pbpaste | claudock profile set-token NAME
    'run NAME -- setup-token' does the same when nothing comes before setup-token.
    'require-token on' makes every Claudock launch of a subscription profile
    ('run', shortcuts, Open in Terminal, Continue as…) use its inference token:
    a missing, expired, or unreadable token stops the launch instead of using
    the profile's normal login. 'profile login', 'profile setup-token', and
    'run NAME -- setup-token' always work, even when the saved token has expired
    or belongs to another account. The setting is shared with the app; it is off by default.

    Examples:
      claudock profile add work
      claudock profile login work
      claudock run work
      claude-work                    After enabling shell integration
      claudock run work -- --resume
      pbpaste | claudock profile add console --api-key
      claudock profile set-credit console 187.42
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
            // TCSAFLUSH discards anything typed or pasted after the secret, so the shell never runs it.
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, saved)
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

/// Async-signal-safe: restore the saved terminal, dropping unread input, then deliver the signal again
/// with its default action. A stop is remembered so the prompt hides input again after the process continues.
private let restoreTerminalAndResignal: @convention(c) (Int32) -> Void = { signal in
    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, SecretInput.saved)
    if signal == SIGTSTP || signal == SIGTTIN || signal == SIGTTOU { SecretInput.stopped.pointee = 1 }
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

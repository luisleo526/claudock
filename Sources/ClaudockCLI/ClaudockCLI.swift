import Foundation
import Darwin
import UsageCore

private enum CLIError: LocalizedError {
    case arguments(String), missingProfile(String), ambiguousProfile(String), missingExecutable, missingOwnExecutable, launchFailed(Int32), invalidEnvironment
    case input(String), missingAPIKey(String), apiKeySignIn(String), subscriptionKey(String), apiKeyToken(String), expiredToken(String)
    case tokenAccountMismatch(String), consoleSignIn(String), subscriptionConsoleSignIn(String), consoleLoginToken(String), noToken(String)
    /// `endpointModel(NAME, OPTION, PINNED)`: a launch argument chose a model other than the pinned one.
    case endpointModel(String, String, String), missingEndpointKey(String), endpointSignIn(String), endpointToken(String), notEndpoint(String)
    /// `endpointSettings(NAME, DETAIL)`: the user's `--settings` cannot be merged into the pinned ones.
    case endpointSettings(String, String)
    /// `endpointSession(NAME, SESSION, MODELS, HOST)`: the session to resume has replies from other models.
    case endpointSession(String, String, [String], String)
    /// `endpointSettingsOverride(NAME, FILE, VARIABLE, HOST)`: a settings file would replace the endpoint key or a pinned value.
    case endpointSettingsOverride(String, String, String, String)

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
        case .apiKeySignIn(let name):
            return "'\(name)' uses a Console API key and has no Claude sign-in. Replace its key with: claudock profile set-key \(name) "
                + "— or sign in to its Anthropic Console account instead: claudock profile login \(name) --console"
        case .subscriptionKey(let name):
            return "'\(name)' is a Claude subscription profile. Only profiles added with 'claudock profile add NAME --api-key', '--console', "
                + "or '--endpoint URL --model MODEL' use a key."
        case .apiKeyToken(let name): return "'\(name)' uses a Console API key. Inference tokens are only for Claude subscription profiles."
        case .consoleLoginToken(let name): return "'\(name)' signs in to an Anthropic Console account. Inference tokens are only for Claude subscription profiles."
        case .noToken(let name): return "No inference token is saved for '\(name)'."
        case .endpointModel(let name, let option, let pinned):
            return "\(name) is pinned to the model \(pinned); \(option) can name only that model. Leave \(option) out, "
                + "or pin another model with: claudock profile set-endpoint \(name) --model MODEL"
        case .missingEndpointKey(let name): return "No endpoint key is saved for '\(name)'. Save one with: claudock profile set-key \(name)"
        case .endpointSignIn(let name):
            return "'\(name)' uses a third-party endpoint with its own key and has no Claude sign-in. Replace its key with: claudock profile set-key \(name)"
        case .endpointToken(let name): return "'\(name)' uses a third-party endpoint with its own key. Inference tokens are only for Claude subscription profiles."
        case .notEndpoint(let name):
            return "'\(name)' is not a third-party endpoint profile. Add one with: claudock profile add NAME --endpoint URL --model MODEL"
        case .endpointSettings(let name, let detail):
            return "\(name): \(detail) Claudock passes its own --settings to pin the endpoint's model; keep other settings in yours."
        case .endpointSettingsOverride(let name, let file, let setting, let host):
            if setting == EndpointLaunch.unreadableSettings {
                return "\(name): Claudock cannot check \(file): it must be one JSON object of at most 4 MiB, without comments, trailing commas, "
                    + "or a name given twice. Fix or remove it."
            }
            return "\(name): \(file) sets \(setting), which "
                + (setting.hasSuffix("ANTHROPIC_AUTH_TOKEN") ? "Claude Code would send to \(host) instead of the endpoint key."
                   : "would override what Claudock pins for \(host).") + " Remove it from that file."
        case .endpointSession(let name, let session, let models, let host):
            return "\(name) runs on \(host), but the session \(session) has replies from \(models.joined(separator: ", ")). "
                + "A long session made with other models can fail there, for example when Claude Code compacts it. "
                + "Start a new session, or resume it anyway with: claudock run \(name) \(Command.crossProviderResume) -- CLAUDE_ARGS"
        case .consoleSignIn(let name): return "\(name) is not signed in to a Console account. Sign in with: claudock profile login \(name)"
        case .subscriptionConsoleSignIn(let name):
            return "'\(name)' is a Claude subscription profile and signs in with: claudock profile login \(name). "
                + "For an Anthropic Console account, add a profile with: claudock profile add NAME --console"
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
    case add(String, String?), addAPIKey(String, String?), addConsoleLogin(String, String?), setKey(String), setToken(String, Date?), setupToken(String), tokens
    case addEndpoint(String, EndpointConfiguration)
    /// `setEndpoint(NAME, URL, MODEL, BEHAVES_AS)`: nil keeps that part (`.some(nil)` clears the mapping); with
    /// none given, the endpoint is shown.
    case setEndpoint(String, String?, String?, String??)
    case clearToken(String)
    case setCredit(String, Decimal)
    /// `login(NAME, console)`: `--console` asks for an Anthropic Console sign-in.
    case rename(String, String), remove(String), login(String, Bool)
    /// `run(NAME, CLAUDE_ARGS, allowCrossProviderResume)`.
    case run(String, [String], Bool)
    /// `usage(maxAge)`: how old, in seconds, a cached reading may be and still be shown without a request.
    case usage(TimeInterval)
    /// `available(maxAge, namesOnly)`: the profiles with room left, most room first.
    case available(TimeInterval, Bool)
    case shellEnable, shellDisable, shellStatus, shellProfileNames
    /// nil prints the current setting.
    case requireToken(Bool?)
    case removedAuto
    case boundLaunch(String, String, Bool, [String])

    static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { return .help }
        if ["help", "--help", "-h"].contains(first), arguments.count == 1 { return .help }
        if ["version", "--version"].contains(first), arguments.count == 1 { return .version }
        if first == "usage" { return .usage(try usageMaxAge(Array(arguments.dropFirst()))) }
        if first == "available" {
            // `--names` comes first or last, so it never splits `--max-age SECONDS`.
            var options = Array(arguments.dropFirst())
            var namesOnly = false
            if let index = options.firstIndex(of: "--names"), index == 0 || index == options.count - 1 {
                namesOnly = true; options.remove(at: index)
            }
            return .available(try usageMaxAge(options, command: "available [--names]"), namesOnly)
        }
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
            case "set-endpoint" where arguments.count >= 3: return try setEndpoint(selector: arguments[2], options: Array(arguments.dropFirst(3)))
            case "set-key" where arguments.count > 3: throw CLIError.arguments("The key is read from standard input, never from arguments.")
            case "set-token" where arguments.count == 3: return .setToken(try name(arguments[2]), nil)
            case "set-token" where arguments.count == 5 && arguments[3] == "--expires": return .setToken(try name(arguments[2]), try expiry(arguments[4]))
            case "set-token" where arguments.count > 3:
                throw CLIError.arguments("The token is read from standard input, never from arguments: claudock profile set-token NAME [--expires ISO8601_DATE].")
            case "setup-token" where arguments.count == 3: return .setupToken(try name(arguments[2]))
            case "setup-token" where arguments.count > 3:
                throw CLIError.arguments("profile setup-token takes only a profile name: claudock profile setup-token NAME.")
            case "tokens" where arguments.count == 2: return .tokens
            case "clear-token" where arguments.count == 3: return .clearToken(try name(arguments[2]))
            case "clear-token" where arguments.count > 3:
                throw CLIError.arguments("profile clear-token takes only a profile name: claudock profile clear-token NAME.")
            case "set-credit" where arguments.count == 4: return .setCredit(try name(arguments[2]), try creditAmount(arguments[3]))
            case "set-credit" where arguments.count > 2:
                throw CLIError.arguments("profile set-credit takes a profile name and an amount in US dollars: claudock profile set-credit NAME AMOUNT.")
            case "rename" where arguments.count == 4: return .rename(try name(arguments[2]), try newName(arguments[3]))
            case "remove" where arguments.count == 3: return .remove(try name(arguments[2]))
            case "login" where arguments.count == 3: return .login(try name(arguments[2]), false)
            case "login" where arguments.count == 4 && arguments[3] == "--console": return .login(try name(arguments[2]), true)
            default: break
            }
        }
        if first == "run", arguments.count >= 2 {
            let profile = try name(arguments[1])
            var rest = Array(arguments.dropFirst(2))
            let allowCrossProviderResume = rest.first == crossProviderResume
            if allowCrossProviderResume { rest.removeFirst() }
            if rest.isEmpty { return .run(profile, [], allowCrossProviderResume) }
            guard rest.first == "--" else {
                throw CLIError.arguments("Separate Claude arguments with '--': claudock run NAME [\(crossProviderResume)] -- CLAUDE_ARGS.")
            }
            return .run(profile, Array(rest.dropFirst()), allowCrossProviderResume)
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

    /// The `run` option that resumes a session other models replied in on an endpoint profile.
    static let crossProviderResume = "--allow-cross-provider-resume"

    /// `profile add NAME [--api-key | --console | --endpoint URL --model MODEL] [--directory ABS_PATH]`, options in any
    /// order; an endpoint profile always gets a folder of its own. A key is never taken from arguments; with --api-key
    /// or --endpoint it is read from standard input.
    private static func add(name value: String, options: [String]) throws -> Command {
        let name = try newName(value)
        var kinds: [String] = [], directory: String?, endpoint: String?, model: String?, behavesAs: String?
        var index = 0
        while index < options.count {
            let option = options[index]
            if ["--api-key", "--console", "--endpoint"].contains(option), !kinds.isEmpty, !kinds.contains(option) {
                throw CLIError.arguments("Choose only one of --api-key, --console, or --endpoint.")
            } else if ["--api-key", "--console"].contains(option), !kinds.contains(option) {
                kinds.append(option); index += 1
            } else if ["--endpoint", "--model", "--behaves-as"].contains(option), index + 1 >= options.count {
                throw CLIError.arguments("\(option) needs a value: claudock profile add NAME --endpoint URL --model MODEL [--behaves-as CATALOG_MODEL].")
            } else if option == "--behaves-as", behavesAs == nil {
                behavesAs = try catalogModel(options[index + 1]); index += 2
            } else if option == "--endpoint", endpoint == nil {
                endpoint = try endpointURL(options[index + 1]); kinds.append(option); index += 2
            } else if option == "--model", model == nil {
                model = try modelID(options[index + 1]); index += 2
            } else if option == "--directory", directory == nil, index + 1 < options.count {
                let path = options[index + 1]
                guard path.hasPrefix("/"), !path.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
                    throw CLIError.arguments("--directory requires an absolute directory path.")
                }
                directory = path; index += 2
            } else if option.hasPrefix("--api-key=") || (kinds.contains("--api-key") && !option.hasPrefix("-")) {
                throw CLIError.arguments("--api-key takes no value. The key is read from standard input, never from arguments.")
            } else {
                throw CLIError.arguments("Unknown command or unexpected arguments.")
            }
        }
        if let endpoint {
            guard let model else { throw CLIError.arguments("--endpoint needs --model MODEL, the one model the profile is pinned to.") }
            guard directory == nil else { throw CLIError.arguments("An endpoint profile gets a config folder of its own; --directory does not combine with --endpoint.") }
            return .addEndpoint(name, try EndpointConfiguration(baseURL: endpoint, model: model, behavesAs: behavesAs))
        }
        guard model == nil, behavesAs == nil else {
            throw CLIError.arguments("--model and --behaves-as go with --endpoint URL: claudock profile add NAME --endpoint URL --model MODEL.")
        }
        return kinds == ["--api-key"] ? .addAPIKey(name, directory) : kinds == ["--console"] ? .addConsoleLogin(name, directory) : .add(name, directory)
    }

    /// `profile set-endpoint NAME [--endpoint URL] [--model MODEL] [--behaves-as CATALOG_MODEL|none]`; with none of
    /// them, the command shows the endpoint.
    private static func setEndpoint(selector value: String, options: [String]) throws -> Command {
        let selector = try name(value)
        var endpoint: String?, model: String?, behavesAs: String??
        var index = 0
        while index < options.count {
            let option = options[index]
            guard (option == "--endpoint" && endpoint == nil) || (option == "--model" && model == nil)
                    || (option == "--behaves-as" && behavesAs == nil), index + 1 < options.count else {
                throw CLIError.arguments("Use: claudock profile set-endpoint NAME [--endpoint URL] [--model MODEL] [--behaves-as CATALOG_MODEL|none].")
            }
            switch option {
            case "--endpoint": endpoint = try endpointURL(options[index + 1])
            case "--model": model = try modelID(options[index + 1])
            default: behavesAs = .some(options[index + 1] == "none" ? nil : try catalogModel(options[index + 1]))
            }
            index += 2
        }
        return .setEndpoint(selector, endpoint, model, behavesAs)
    }

    /// The input is never echoed: it may be a key typed in the wrong place.
    private static func endpointURL(_ value: String) throws -> String {
        do { return try EndpointConfiguration.validatedBaseURL(value) }
        catch { throw CLIError.arguments(EndpointError.invalidBaseURL.localizedDescription) }
    }

    private static func modelID(_ value: String) throws -> String {
        do { return try EndpointConfiguration.validatedModel(value) }
        catch { throw CLIError.arguments(EndpointError.invalidModel.localizedDescription) }
    }

    private static func catalogModel(_ value: String) throws -> String {
        do { return try EndpointConfiguration.validatedBehavesAs(value) }
        catch { throw CLIError.arguments(EndpointError.invalidBehavesAs.localizedDescription) }
    }

    /// `usage [--max-age SECONDS | --fresh]`: 180 seconds by default, 0 to 86400, and `--fresh` for 0.
    private static func usageMaxAge(_ options: [String], command: String = "usage") throws -> TimeInterval {
        switch options.count {
        case 0: return 180
        case 1 where options[0] == "--fresh": return 0
        case 2 where options[0] == "--max-age":
            guard options[1].allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Int(options[1]), seconds <= 86_400 else {
                throw CLIError.arguments("--max-age takes a whole number of seconds from 0 to 86400.")
            }
            return TimeInterval(seconds)
        default: throw CLIError.arguments("Use 'claudock \(command)', 'claudock \(command) --max-age SECONDS', or 'claudock \(command) --fresh'.")
        }
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
            exit(isArgumentError(error) ? 2 : 1)
        }
    }

    /// Usage errors and launches refused for their arguments exit 2, before anything starts.
    private static func isArgumentError(_ error: Error) -> Bool {
        switch error as? CLIError {
        case .arguments?, .endpointModel?, .endpointSettings?, .endpointSession?, .endpointSettingsOverride?: return true
        default: return false
        }
    }

    private static func execute(_ command: Command) async throws {
        switch command {
        case .help: print(help)
        case .version: print("Claudock 1.7.0")
        case .list:
            let profiles = try ProfileStore.load()
            print("PROFILE\tSELECTOR\tKIND\tCONFIG_DIRECTORY\tENDPOINT")
            for profile in profiles {
                let kind = profile.discoveryNote != nil ? "needs-import" : profile.isVertex ? "vertex"
                    : profile.authKind == .apiKey ? "api-key" : profile.authKind == .consoleLogin ? "console-login"
                    : profile.authKind == .endpoint ? "endpoint" : profile.managed ? "managed" : "imported"
                // The host and pinned model, never the key.
                let endpoint = profile.endpoint.map { "\($0.host) · \($0.model)" + ($0.behavesAs.map { " · behaves as " + $0 } ?? "") } ?? "-"
                print([profile.name, profile.command, kind, profile.configDirectory, endpoint].map(field).joined(separator: "\t"))
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
        case .addEndpoint(let name, let endpoint):
            // Validate the key before the registry is touched.
            let key = try EndpointAPIKey(parsing: SecretInput.read(prompt: "Endpoint API key: "))
            let profile = try ProfileStore.addEndpointProfile(name: name, endpoint: endpoint, key: key)
            print("Added \(profile.name) for the third-party endpoint \(endpoint.host), pinned to the model \(endpoint.model), "
                  + "with its key saved in Keychain. Start it with: claudock run \(profile.name)")
            print("Its first interactive launch asks whether you trust the folder. If Claude Code asks to make auto mode your default "
                  + "permission mode, choose No: the answer would change the settings every profile shares.")
        case .setEndpoint(let name, let url, let model, let behavesAs):
            let profile = try resolve(name)
            guard profile.authKind.isEndpoint, let current = profile.endpoint else { throw CLIError.notEndpoint(profile.name) }
            guard url != nil || model != nil || behavesAs != nil else {
                print("\(profile.name) uses the third-party endpoint \(current.baseURL) with the model \(current.model)"
                      + (current.behavesAs.map { ", which behaves as \($0)." } ?? "."))
                print("Change them with: claudock profile set-endpoint \(profile.name) [--endpoint URL] [--model MODEL] [--behaves-as CATALOG_MODEL|none]")
                return
            }
            let changed = try ProfileStore.setEndpoint(EndpointConfiguration(baseURL: url ?? current.baseURL, model: model ?? current.model,
                                                                             behavesAs: behavesAs ?? current.behavesAs), for: profile)
            guard let endpoint = changed.endpoint else { throw CLIError.notEndpoint(changed.name) }
            print("\(changed.name) now uses \(endpoint.baseURL) with the model \(endpoint.model)"
                  + (endpoint.behavesAs.map { ", which behaves as \($0)" } ?? "") + ". Its key was kept.")
        case .addConsoleLogin(let name, let directory):
            let profile = try ProfileStore.addConsoleLoginProfile(name: name, configDirectory: directory)
            print("Added \(profile.name). Sign in to its Anthropic Console account in your browser. "
                  + "If sign-in does not finish, sign in later with: claudock profile login \(profile.name)")
            try launch(profile: profile, arguments: consoleSignIn, signIn: true)
        case .setKey(let name):
            let profile = try resolve(name)
            if profile.authKind.isEndpoint {
                try EndpointKeyStore.save(EndpointAPIKey(parsing: SecretInput.read(prompt: "Endpoint API key: ")), profile: profile)
                print("Saved a new endpoint key for \(profile.name) in Keychain.")
                return
            }
            guard profile.authKind.isConsole else { throw CLIError.subscriptionKey(profile.name) }
            let key = try ConsoleAPIKey(parsing: SecretInput.read(prompt: "Console API key: "))
            if profile.authKind == .apiKey {
                try APIKeyStore.save(key, profile: profile)
                print("Saved a new Console API key for \(profile.name) in Keychain.")
            } else {
                // The key is saved before the registry lists the profile as an API-key profile.
                let switched = try ProfileStore.setAuthKind(.apiKey, for: profile) { try APIKeyStore.save(key, profile: $0) }
                let service = LaunchCommand.quote(ConsoleLogin.keychainService(for: switched))
                print("Saved a Console API key for \(switched.name) in Keychain; \(switched.name) now uses it instead of its Console account sign-in.")
                print("Claude Code's key from that sign-in stays in Keychain, unused, under service \(service). "
                      + "To delete it: security delete-generic-password -s \(service)")
                print("To switch back, sign in again with: claudock profile login \(switched.name) --console")
            }
        case .setToken(let name, let expiry):
            let profile = try tokenProfile(name)
            let token = try MintTokenStore.importToken(raw: SecretInput.read(prompt: "Inference token: "), profile: profile, expiresAt: expiry)
            print("Saved an inference token for \(profile.name) in Keychain; 'claudock run \(profile.name)' uses it. "
                  + "Expires: \(token.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"). Its account is not verified.")
        case .clearToken(let name):
            let profile = try tokenProfile(name)
            guard try MintTokenStore.delete(profile: profile) else { throw CLIError.noToken(profile.name) }
            print("Deleted the inference token saved for \(profile.name) from Keychain (service \(MintTokenStore.serviceName(for: profile))). "
                  + "Claude Code's own login was not touched.")
            print(InferenceTokenPolicy.isRequired()
                  ? "Claudock requires an inference token to launch, so 'claudock run \(profile.name)' is refused until you save one: "
                      + "claudock profile setup-token \(profile.name), then pbpaste | claudock profile set-token \(profile.name)."
                  : "'claudock run \(profile.name)' now starts Claude with the profile's normal login.")
        case .setupToken(let name):
            let profile = try resolve(name)
            try requireTokenSupport(profile)
            // Runs like sign-in, on the profile's own login: the saved token and the token requirement play no part.
            try launch(profile: profile, arguments: ["setup-token"], signIn: true,
                       notice: "Sign the browser in to the claude.ai account for \(profile.name) first. "
                           + "When the token is shown, save it with: pbpaste | claudock profile set-token \(profile.name)")
        case .setCredit(let name, let amount):
            let profile = try resolve(name)
            guard profile.authKind.isConsole else {
                throw profile.authKind.isEndpoint ? APICreditError.endpointProfile(profile.name) : APICreditError.subscriptionProfile(profile.name)
            }
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
            switch profile.authKind {
            case .apiKey: print("Removed \(name) from Claudock. Claude data, its Console API key, and your own shell commands were preserved.")
            case .consoleLogin: print("Removed \(name) from Claudock. Claude data, its Console sign-in, and your own shell commands were preserved.")
            case .subscription: print("Removed \(name) from Claudock. Claude data, credentials, and your own shell commands were preserved.")
            case .endpoint: print("Removed \(name) from Claudock. Claude data, its endpoint key, and your own shell commands were preserved.")
            }
            printLeftovers(of: profile)
        case .login(let name, let console):
            let profile = try resolve(name)
            switch profile.authKind {
            case .subscription:
                guard !console else { throw CLIError.subscriptionConsoleSignIn(profile.name) }
                try launch(profile: profile, arguments: ["auth", "login", "--claudeai"], signIn: true)
            case .consoleLogin:
                try launch(profile: profile, arguments: consoleSignIn, signIn: true)
            case .apiKey:
                guard console else { throw CLIError.apiKeySignIn(profile.name) }
                try switchToConsoleSignIn(profile)
            case .endpoint:
                throw CLIError.endpointSignIn(profile.name)
            }
        case .run(let name, let arguments, let allowCrossProviderResume):
            try launch(profile: resolve(name), arguments: arguments, allowCrossProviderResume: allowCrossProviderResume)
        case .removedAuto:
            FileHandle.standardError.write(Data("Claudock Auto has been removed. Use 'claudock run PROFILE' to start Claude with a specific profile.\n".utf8))
            exit(2)
        case .boundLaunch(let id, let service, let login, let arguments):
            let profiles = try ProfileStore.load()
            let matches = profiles.filter { $0.id == id }
            guard matches.count == 1, let profile = matches.first, CredentialStore.serviceName(for: profile) == service else {
                throw CLIError.arguments("The selected profile changed. Choose it again in Claudock.")
            }
            if login, profile.authKind == .apiKey { throw CLIError.apiKeySignIn(profile.name) }
            if login, profile.authKind == .endpoint { throw CLIError.endpointSignIn(profile.name) }
            let signIn = profile.authKind == .consoleLogin ? consoleSignIn : ["auth", "login", "--claudeai"]
            try launch(profile: profile, arguments: login ? signIn : arguments, signIn: login)
        case .usage(let maxAge):
            try await usage(maxAge: maxAge)
        case .available(let maxAge, let namesOnly):
            try await available(maxAge: maxAge, namesOnly: namesOnly)
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

    /// Claude Code's sign-in to an Anthropic Console account; it creates and keeps the profile's API key itself.
    private static let consoleSignIn = ["auth", "login", "--console"]

    /// The profile that `name` selects, for a command that saves or deletes its inference token.
    private static func tokenProfile(_ name: String) throws -> Profile {
        let profile = try resolve(name)
        try requireTokenSupport(profile)
        guard profile.discoveryNote == nil, !profile.isVertex, !profile.configDirectory.isEmpty else { throw MintTokenError.unsupportedProfile }
        return profile
    }

    /// Removal keeps every credential, and the profile list forgets where they are. So say what is still in Keychain,
    /// each item with the command that deletes it, and the config folder; deleting an item does not revoke its key.
    private static func printLeftovers(of profile: Profile) {
        let lookup = ProfileKeychainItems.lookup(for: profile)
        if !lookup.existing.isEmpty || !lookup.unchecked.isEmpty {
            print("Credentials left in Keychain. To delete one, run its command:")
            for item in lookup.existing { print("  \(item.title)\n    \(item.deleteCommand)") }
            for item in lookup.unchecked { print("  \(item.title) (Keychain could not be checked; it may not exist)\n    \(item.deleteCommand)") }
        }
        if !profile.configDirectory.isEmpty {
            // Quoted, so the line can go into `rm -r` as it is. A terminal must not receive control characters, so they
            // become spaces, and then the name shown is not exact.
            let shown = field(profile.configDirectory)
            print("Config folder: \(LaunchCommand.quote(shown))"
                  + (shown == profile.configDirectory ? "" : " (control characters in the name are shown as spaces)"))
        }
        print(profile.authKind.isEndpoint
              ? "Keys and tokens stay valid until they are revoked: an endpoint key at its provider, others in the Console or on claude.ai."
              : "Keys and tokens stay valid at Anthropic until they are revoked in the Console or on claude.ai.")
    }

    /// Inference tokens belong to subscription profiles.
    private static func requireTokenSupport(_ profile: Profile) throws {
        switch profile.authKind {
        case .subscription: return
        case .apiKey: throw CLIError.apiKeyToken(profile.name)
        case .consoleLogin: throw CLIError.consoleLoginToken(profile.name)
        case .endpoint: throw CLIError.endpointToken(profile.name)
        }
    }

    /// Runs Claude Code's Console sign-in for an API-key profile as a child, and switches the profile to that sign-in
    /// only once it finished: Claude exited 0 and its key item exists. Otherwise the profile keeps using its saved key,
    /// which stays in Keychain either way.
    private static func switchToConsoleSignIn(_ profile: Profile) throws -> Never {
        guard let executable = ClaudeExecutable.find() else { throw CLIError.missingExecutable }
        let environment = try LaunchCommand.environment(profile: profile, inherited: ProcessInfo.processInfo.environment)
        guard !executable.contains("\0"), environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw CLIError.invalidEnvironment
        }
        fflush(stdout)
        let status: Int32
        do { status = try APICreditLaunch.supervise(executable: executable, arguments: consoleSignIn, environment: environment) }
        catch APICreditLaunchError.launchFailed(let code) { throw CLIError.launchFailed(code) }
        guard status == 0 else {
            writeError("The Console sign-in did not finish; \(profile.name) still uses its Console API key.")
            exit(status)
        }
        guard try ConsoleLogin.isSignedIn(profile: profile) else {
            writeError("Claude Code finished without saving a Console sign-in; \(profile.name) still uses its Console API key.")
            exit(1)
        }
        let switched = try ProfileStore.setAuthKind(.consoleLogin, for: profile)
        let service = APIKeyStore.serviceName(for: profile)
        print("\(switched.name) now uses its Anthropic Console account sign-in; Claudock no longer passes it the saved Console API key.")
        print("The key stays in Keychain under service \(service). To delete it: security delete-generic-password -s \(service)")
        exit(0)
    }

    /// Sign-in and token creation (`signIn`) run on the profile's own login and are never subject to the inference-token
    /// requirement. A `notice` goes to stderr just before Claude replaces this process, so a refused launch prints none.
    private static func launch(profile: Profile, arguments: [String], signIn: Bool = false, notice: String? = nil,
                               allowCrossProviderResume: Bool = false) throws {
        // An endpoint launch's arguments are checked before anything else is read, so a refused one starts nothing.
        var claudeArguments = arguments
        if profile.authKind.isEndpoint, !signIn, let endpoint = profile.endpoint {
            do { try EndpointLaunch.checkModelArguments(arguments, configuration: endpoint) }
            catch EndpointLaunchError.modelNotAllowed(let option, let pinned) { throw CLIError.endpointModel(profile.name, option, pinned) }
            let directory = FileManager.default.currentDirectoryPath
            do {
                claudeArguments = try EndpointLaunch.arguments(arguments, configuration: endpoint, configDirectory: profile.configDirectory,
                                                               workingDirectory: directory)
            } catch let error as EndpointLaunchError { throw CLIError.endpointSettings(profile.name, error.localizedDescription) }
            if let override = EndpointLaunch.overridingSettings(configuration: endpoint, configDirectory: profile.configDirectory,
                                                                workingDirectory: directory).first {
                throw CLIError.endpointSettingsOverride(profile.name, override.file, override.key, endpoint.host)
            }
            if !allowCrossProviderResume {
                switch EndpointSession.check(arguments: arguments, workingDirectory: directory, configDirectory: profile.configDirectory,
                                             environment: ProcessInfo.processInfo.environment, pinned: endpoint.model) {
                case .otherModels(let session, let models): throw CLIError.endpointSession(profile.name, session, models, endpoint.host)
                case .uncheckable:
                    writeError("\(profile.name): the session picker or a remote session can load a session other models replied in, which can "
                               + "fail on \(endpoint.host); Claudock checks only --continue and --resume with a session ID, title, or .jsonl path.")
                case .clear: break
                }
            }
        }
        guard let executable = ClaudeExecutable.find() else { throw CLIError.missingExecutable }
        var environment = try LaunchCommand.environment(profile: profile, inherited: ProcessInfo.processInfo.environment)
        let credential: LaunchCredential
        do { credential = try InferenceTokenPolicy.launchCredential(profile: profile, claudeArguments: arguments, signIn: signIn) }
        catch MintTokenError.tokenExpired { throw CLIError.expiredToken(profile.name) }
        // Both mean the saved token's account is not the profile's current login: reading raises the first, saving the second.
        catch MintTokenError.accountMismatch, MintTokenError.accountChanged { throw CLIError.tokenAccountMismatch(profile.name) }
        // Inherited credentials were cleared above, so the chosen one is the only one.
        var counted = false
        switch credential {
        case .consoleAPIKey:
            guard let key = try APIKeyStore.environmentKey(profile: profile) else { throw CLIError.missingAPIKey(profile.name) }
            environment["ANTHROPIC_API_KEY"] = key
            counted = true
        case .consoleLogin:
            // Claude Code uses the key its Console sign-in keeps; without one it would start signed out.
            guard try ConsoleLogin.isSignedIn(profile: profile) else { throw CLIError.consoleSignIn(profile.name) }
            counted = true
        case .endpointKey:
            // A plain execve, like a subscription launch: no credit ledger and no OpenTelemetry capture.
            guard let endpoint = profile.endpoint, let key = try EndpointKeyStore.environmentKey(profile: profile) else {
                throw CLIError.missingEndpointKey(profile.name)
            }
            environment = EndpointLaunch.environment(environment, configuration: endpoint, key: key)
        case .inferenceToken(let token): environment["CLAUDE_CODE_OAUTH_TOKEN"] = token
        case .profileLogin: break
        }
        let argumentStrings = [executable] + claudeArguments
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
        // Claude takes over the terminal; anything printed before it must come first.
        fflush(stdout)
        if counted {
            // A child process instead of execve: Claude Code reports each request's cost to Claudock while it runs.
            do {
                exit(try APICreditLaunch.run(profile: profile, executable: executable, arguments: claudeArguments, environment: environment,
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

    /// Reads go through the cache shared with the app: a reading younger than `maxAge` is printed without a request,
    /// a profile cooling down after HTTP 429 is not requested, and a cached reading stands in, with a note on stderr,
    /// when there is no newer one. Only a profile with no reading at all fails the command.
    private static func usage(maxAge: TimeInterval) async throws {
        let profiles = try ProfileStore.load()
        let formatter = ISO8601DateFormatter()
        let fetcher = UsageFetcher()
        var failed = false
        print("PROFILE\tPLAN\tWINDOW\tUSED_PERCENT\tRESETS_UTC")
        for profile in profiles {
            guard profile.discoveryNote == nil, !profile.isVertex, !profile.configDirectory.isEmpty else {
                writeError("\(field(profile.name)): skipped; this profile does not support subscription usage.")
                continue
            }
            if let endpoint = profile.endpoint, profile.authKind.isEndpoint {
                writeError("\(field(profile.name)): " + endpointNote(endpoint))
                continue
            }
            guard profile.authKind == .subscription else {
                do {
                    if let credit = try APICreditStore.status(profile: profile) {
                        print([profile.name, APICreditStatus.plan, credit.usageWindow, credit.usedPercentText, "-"].map(field).joined(separator: "\t"))
                    } else {
                        let billing = profile.authKind == .apiKey ? "Console API key profiles are billed per token and have"
                            : ConsoleLogin.organizationName(profile: profile).map { "Console login · \($0) is billed per token and has" }
                                ?? "Console login profiles are billed per token and have"
                        writeError("\(field(profile.name)): skipped; \(billing) no subscription limits. "
                                   + "Set its balance with: claudock profile set-credit \(profile.name) AMOUNT")
                    }
                } catch {
                    failed = true
                    writeError("\(field(profile.name)): \(error.localizedDescription)")
                }
                continue
            }
            let result = await fetcher.reading(for: profile, maxAge: maxAge, fetch: subscriptionReading)
            let shown: UsageReading
            switch result {
            case .current(let reading): shown = reading
            case .cached(let reading, let reason):
                shown = reading
                writeError("\(field(profile.name)): \(staleReason(reason)); showing reading from \(age(of: reading.snapshot.fetchedAt)).")
            case .failed(let error):
                failed = true
                writeError("\(field(profile.name)): \(error.localizedDescription)")
                continue
            }
            for window in shown.snapshot.windows {
                let percent = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), window.percent)
                print([profile.name, shown.plan.displayName, window.title, percent, window.resetsAt.map(formatter.string(from:)) ?? "unknown"].map(field).joined(separator: "\t"))
            }
        }
        await fetcher.finish()
        if failed { exit(1) }
    }

    /// One request with the saved access token: renewal belongs to the resident app.
    @Sendable private static func subscriptionReading(_ profile: Profile) async throws -> UsageReading {
        let credentials = try CredentialStore.read(profile: profile)
        return UsageReading(plan: credentials.subscriptionPlan, snapshot: try await UsageClient.fetch(credentials: credentials))
    }

    /// The profiles with room left, read like `usage`: subscriptions by the room left in their tightest 5-hour,
    /// Weekly, or Fable limit, then Console profiles by the share of their credit left. A profile whose reading
    /// is cached or that cannot be read gets a note on stderr. Exits 1 when no profile has room.
    private static func available(maxAge: TimeInterval, namesOnly: Bool) async throws {
        struct Row { let profile: Profile; let kind: String; let plan: String; let left: String; let limit: String; let resets: String; let rank: Double }
        let profiles = try ProfileStore.load()
        let formatter = ISO8601DateFormatter()
        let fetcher = UsageFetcher()
        let now = Date()
        var rows: [Row] = []
        var nextFree: (profile: Profile, at: Date)?
        for profile in profiles where profile.discoveryNote == nil && !profile.isVertex && !profile.configDirectory.isEmpty {
            if profile.authKind.isEndpoint {
                writeError("\(field(profile.name)): not listed; " + (profile.endpoint.map(endpointNote) ?? "third-party endpoint."))
                continue
            }
            if profile.authKind.isConsole {
                let kind = profile.authKind == .apiKey ? "api-key" : "console-login"
                let credit: APICreditStatus?
                do { credit = try APICreditStore.status(profile: profile) }
                catch { writeError("\(field(profile.name)): \(error.localizedDescription)"); continue }
                guard let credit else {
                    writeError("\(field(profile.name)): not listed; set its Console credit to track it: claudock profile set-credit \(profile.name) AMOUNT")
                    continue
                }
                guard AccountAvailability.classify(profile: profile, snapshot: nil, error: nil, credit: credit, now: now).hasRoom else { continue }
                // Console profiles follow every subscription: they are billed per token.
                rows.append(Row(profile: profile, kind: kind, plan: APICreditStatus.plan, left: credit.leftText, limit: "Credit", resets: "-",
                                rank: -2 + (1 - credit.fraction)))
                continue
            }
            let result = await fetcher.reading(for: profile, maxAge: maxAge, fetch: subscriptionReading)
            let reading: UsageReading, error: MonitorError?
            switch result {
            case .current(let current): reading = current; error = nil
            case .cached(let cached, let reason):
                reading = cached; error = reason
                writeError("\(field(profile.name)): \(staleReason(reason)); using reading from \(age(of: cached.snapshot.fetchedAt)).")
            case .failed(let failure):
                writeError("\(field(profile.name)): not listed; \(failure.localizedDescription)")
                continue
            }
            let status = AccountAvailability.classify(profile: profile, snapshot: reading.snapshot, error: error, credit: nil, now: now)
            guard let headroom = reading.snapshot.headroom(at: now) else { continue }
            guard status.hasRoom else {
                if status == .full, let at = headroom.availableAgain, at < nextFree?.at ?? .distantFuture { nextFree = (profile, at) }
                continue
            }
            let percent = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), headroom.percentLeft)
            rows.append(Row(profile: profile, kind: "subscription", plan: reading.plan.displayName, left: percent + "%",
                            limit: headroom.window.title, resets: headroom.window.resetsAt.map(formatter.string(from:)) ?? "unknown",
                            rank: headroom.percentLeft))
        }
        await fetcher.finish()
        rows.sort { $0.rank == $1.rank ? $0.profile.name < $1.profile.name : $0.rank > $1.rank }
        if !namesOnly { print("PROFILE\tKIND\tPLAN\tLEFT\tTIGHTEST_LIMIT\tRESETS_UTC") }
        for row in rows {
            print(namesOnly ? field(row.profile.name)
                  : [row.profile.name, row.kind, row.plan, row.left, row.limit, row.resets].map(field).joined(separator: "\t"))
        }
        guard rows.isEmpty else { return }
        writeError("No profile has usage left." + (nextFree.map { " \($0.profile.name) is next free, at \(formatter.string(from: $0.at))." } ?? ""))
        exit(1)
    }

    /// What `usage` and `available` say instead of a row for a third-party endpoint profile.
    private static func endpointNote(_ endpoint: EndpointConfiguration) -> String {
        "third-party endpoint (\(endpoint.host), \(endpoint.model)), billed per token by the provider; no quota to read."
    }

    /// Why `usage` shows an older cached reading.
    private static func staleReason(_ reason: MonitorError) -> String {
        switch reason {
        case .rateLimited(let until?):
            let clock = DateFormatter()
            clock.locale = Locale(identifier: "en_US_POSIX")
            clock.dateFormat = "HH:mm"
            return "rate limited until " + clock.string(from: until)
        case .usageBusy: return "another Claudock process is reading usage"
        default:
            let text = reason.localizedDescription
            return text.hasSuffix(".") ? String(text.dropLast()) : text
        }
    }

    /// "N min ago", in whole minutes at any age, so scripts can read it.
    private static func age(of date: Date) -> String {
        "\(max(1, Int((max(0, Date().timeIntervalSince(date)) / 60).rounded()))) min ago"
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
      claudock profile add NAME --console [--directory ABS_PATH]
      claudock profile add NAME --endpoint URL --model MODEL [--behaves-as CATALOG_MODEL]
      claudock profile set-key NAME
      claudock profile set-endpoint NAME [--endpoint URL] [--model MODEL] [--behaves-as CATALOG_MODEL]
      claudock profile set-credit NAME AMOUNT
      claudock profile set-token NAME [--expires ISO8601_DATE]
      claudock profile setup-token NAME
      claudock profile tokens
      claudock profile clear-token NAME
      claudock profile rename NAME NEWNAME
      claudock profile remove NAME
      claudock profile login NAME [--console]
      claudock profile import-shell
      claudock run NAME [--allow-cross-provider-resume] [-- CLAUDE_ARGS...]
      claudock usage [--max-age SECONDS | --fresh]
      claudock available [--names] [--max-age SECONDS | --fresh]
      claudock require-token on|off|status
      claudock shell enable|disable|status
      claudock version

    Profiles are stored by Claudock. Adding, renaming, or removing a profile
    does not edit .zshrc. Removal keeps Claude data and credentials: 'profile
    remove' lists the Keychain items still holding them, each with the command
    that deletes it, and the config folder. Deleting an item does not revoke its
    key; revoke API keys in the Console, and logins and tokens on claude.ai.
    Profile names or exact SELECTOR values select a profile. An exact selector
    takes precedence; ambiguous display names require the selector from 'list'.
    Selectors are profile identifiers; they do not create shell commands.
    'run', 'profile login', and 'profile setup-token' use the current terminal and
    working directory.
    'usage' lists each subscription profile's quota and the Console credit left
    on Console profiles; output is tab-separated and contains no account
    emails or credentials. Quota readings are shared with the app in
    ~/Library/Application Support/Claudock/usage-cache.json, and a reading
    younger than 180 seconds is printed without asking Claude again.
    '--max-age SECONDS' (0 to 86400) sets that age; '--fresh' asks for new
    readings. A profile that Claude rate-limits (HTTP 429) is not asked again
    until its cooldown ends, not even with --fresh: the Retry-After time, kept
    between 5 minutes and a day, or else 1 minute doubling up to 30. While a
    profile cools down or its request fails, 'usage' prints its last reading
    and a note on stderr, and exits 0; only a profile with no reading at all
    makes it fail. One Claudock process asks Claude at a time, half a second
    between requests; other 'usage' runs wait up to 30 seconds for its
    readings, then print what is cached.
    'available' reads the same way and lists only the profiles with usage
    left, most first: subscriptions by the room left in their tightest
    5-hour, Weekly, or Fable limit (a limit past its reset time counts as
    empty), then Console profiles with credit left, by share left. Profiles
    near a limit are listed; full ones are not. '--names' prints only the
    names, one per line, for scripts:
      claudock run "$(claudock available --names | head -n 1)"
    It exits 1 when no profile has usage left, naming the next one to free up.
    Shell integration is optional. 'shell enable' adds Claudock's marked zsh
    loader; disable removes only that integration. Existing wrappers stay intact.

    Console API keys: 'profile add NAME --api-key' creates a profile that runs
    Claude Code with a Claude Console API key, billed per token rather than by
    a subscription. 'profile set-key NAME' replaces its key. Keys are read from
    standard input, never from arguments: at a terminal Claudock prompts without
    echoing, otherwise it reads the piped input. Keys are stored only in the
    macOS Keychain and reach Claude as ANTHROPIC_API_KEY. The first interactive
    launch asks whether to use the key; choose Yes.

    Console login: 'profile add NAME --console' creates a profile that signs in
    to an Anthropic Console account in the browser instead (claude auth login
    --console). Claude Code then creates and keeps the account's API key itself;
    nothing is pasted, and usage is billed per token to that Console
    organization. 'profile login NAME' signs it in again. On an API-key profile,
    'profile login NAME --console' switches it to its Console sign-in once the
    sign-in finishes, keeping the saved key unused in Keychain; 'profile set-key
    NAME' switches a Console-login profile back to a pasted key.

    Third-party endpoints: 'profile add NAME --endpoint URL --model MODEL'
    creates a profile that runs Claude Code against another service that speaks
    the Anthropic Messages protocol, such as DeepSeek, billed per token by that
    provider. The URL must be https. Its key is read from standard input like a
    Console key: the raw key, or one 'export NAME=value' line as in a shell key
    file, so a key file can be redirected in:
      claudock profile add deepseek --endpoint https://api.deepseek.com/anthropic --model deepseek-flash < KEY_FILE
    An Anthropic key (sk-ant-…) is refused. The key is stored only in the macOS
    Keychain and reaches Claude as ANTHROPIC_AUTH_TOKEN, with the URL as
    ANTHROPIC_BASE_URL and MODEL pinned in every model slot; 'run' refuses a
    --model, --fallback-model, or --advisor that names another model, and
    passes Claude Code a --settings object whose availableModels makes /model
    refuse other models too. A --settings of your own is merged into it, unless
    it sets the model, endpoint, or a credential. --behaves-as CATALOG_MODEL
    (a full id such as claude-sonnet-4-6; none removes it) lets Claude Code
    treat MODEL like that model: its prompt, limits, and context window.
    'profile set-endpoint' changes the URL, the model, or --behaves-as and keeps
    the key; 'profile set-key' replaces the key. These profiles have no Claude
    sign-in, inference token, or Console credit; 'usage' and 'available' print a
    note instead of a row.
    Sessions are shared by every profile, and a long one made with other models
    can fail on an endpoint. So 'run' refuses to resume, with --continue or
    --resume, a session in which another model replied, unless it is given
    --allow-cross-provider-resume before '--'. The session picker (--resume
    without a value) cannot be checked first, and prints a warning.

    Console credit: 'profile set-credit NAME AMOUNT' records the remaining
    prepaid credit shown in the Claude Console for an API-key or Console-login
    profile, in US dollars (such as 200 or 187.42). 'usage' then lists what is
    left, less the cost Claude Code reports for each request in sessions
    Claudock starts on this Mac; for that, these launches run Claude as a child
    of claudock with OpenTelemetry log export to 127.0.0.1. Use of the same key
    elsewhere (other Macs, scripts, other tools) is not seen. The Console
    balance is authoritative: set it again any time. Without a credit, 'usage'
    skips the profile.

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
    'profile clear-token NAME' deletes the token saved for a profile, and only
    that item: Claude Code's own login stays. The profile then starts with its
    normal login, or is refused while 'require-token' is on.
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
      claudock profile add team --console
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

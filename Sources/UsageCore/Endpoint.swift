import Foundation

public enum EndpointError: Error, LocalizedError, Equatable {
    case invalidBaseURL, invalidModel, invalidBehavesAs

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Use the endpoint's https URL, such as https://api.deepseek.com/anthropic: a host and optional path, "
                + "without a user name, password, query, or fragment."
        case .invalidModel:
            return "Use one model id of letters, digits, and . _ : / - (at most 128 characters), optionally ending in [1m], such as deepseek-flash."
        case .invalidBehavesAs:
            return "--behaves-as takes the full id of a model Claude Code knows, such as claude-sonnet-4-6, or none; an alias such as sonnet does not work."
        }
    }
}

/// A third-party service that speaks the Anthropic Messages protocol, and the one model every launch of its
/// profile is pinned to. Both are plain data: a URL is never fetched by Claudock and a model is never expanded.
public struct EndpointConfiguration: Codable, Hashable, Sendable {
    /// `https://host[:port][/path]`, with the scheme and host in lower case and no trailing slash.
    public let baseURL: String
    /// The model id the endpoint serves, sent as is. A `[1m]` suffix asks Claude Code for its one-million-token context.
    public let model: String
    /// A model in Claude Code's catalog whose handling (prompt, limits, context window) Claude Code applies to `model`,
    /// through a `modelPicker` row's `behavesAs`; nil leaves Claude Code treating the model as unknown.
    public let behavesAs: String?

    public init(baseURL: String, model: String, behavesAs: String? = nil) throws {
        self.baseURL = try Self.validatedBaseURL(baseURL)
        self.model = try Self.validatedModel(model)
        self.behavesAs = try behavesAs.map(Self.validatedBehavesAs)
    }

    /// Whether the model asks Claude Code for its one-million-token context (`[1m]`).
    public var isOneMillionTokens: Bool { model.hasSuffix("[1m]") }
    /// The model id without `[1m]`: what Claude Code sends to the endpoint.
    public var baseModel: String { isOneMillionTokens ? String(model.dropLast(4)) : model }

    /// The host, with its port when the URL names one, for display.
    public var host: String {
        guard let components = URLComponents(string: baseURL), let host = components.host else { return baseURL }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// `raw` as an https URL with a host and no user name, password, query, or fragment; trailing slashes go.
    public static func validatedBaseURL(_ raw: String) throws -> String {
        // Printable ASCII only: no white space, control characters, or look-alike letters in what goes to Claude Code.
        guard raw.utf8.count <= 2048, raw.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              raw.lowercased().hasPrefix("https://"), !raw.contains("?"), !raw.contains("#"),
              !raw.dropFirst("https://".count).prefix(while: { $0 != "/" }).contains("@"),
              var components = URLComponents(string: raw), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else { throw EndpointError.invalidBaseURL }
        components.scheme = "https"
        components.host = host.lowercased()
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        guard let normalized = components.string else { throw EndpointError.invalidBaseURL }
        return normalized
    }

    public static func validatedModel(_ raw: String) throws -> String {
        guard raw.utf8.count <= 128, raw.range(of: #"\A[A-Za-z0-9._:/-]+(\[1m\])?\z"#, options: .regularExpression) != nil else {
            throw EndpointError.invalidModel
        }
        return raw
    }

    /// Claude Code 2.1.296 maps a model only to a full catalog id (`claude-sonnet-4-6`), never an alias (`sonnet`).
    public static func validatedBehavesAs(_ raw: String) throws -> String {
        guard raw.utf8.count <= 128, raw.range(of: #"\Aclaude-[a-z0-9][a-z0-9.-]*\z"#, options: .regularExpression) != nil else {
            throw EndpointError.invalidBehavesAs
        }
        return raw
    }

    private enum CodingKeys: String, CodingKey { case baseURL, model, behavesAs }

    /// A stored endpoint must already be valid and normalised; anything else makes the registry invalid.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let baseURL = try values.decode(String.self, forKey: .baseURL)
        try self.init(baseURL: baseURL, model: values.decode(String.self, forKey: .model),
                      behavesAs: values.decodeIfPresent(String.self, forKey: .behavesAs))
        guard self.baseURL == baseURL else { throw EndpointError.invalidBaseURL }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(model, forKey: .model)
        try values.encodeIfPresent(behavesAs, forKey: .behavesAs)
    }
}

public enum EndpointKeyError: Error, LocalizedError, Equatable {
    case invalidKey, anthropicKey, unsupportedProfile, invalidStoredKey, keychainUnavailable, keychainWriteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Enter the endpoint's API key: one value of printable characters without spaces or quotes, at most 512, "
                + "or one export NAME=value line. Do not include other lines or commands."
        case .anthropicKey:
            return "This is an Anthropic key (sk-ant-…). Claudock never sends an Anthropic credential to a third-party endpoint; "
                + "use the key the endpoint's provider gave you."
        case .unsupportedProfile: return "Only third-party endpoint profiles added through Claudock keep an endpoint key."
        case .invalidStoredKey: return "The saved endpoint key is unreadable. Replace it with: claudock profile set-key NAME"
        case .keychainUnavailable: return "The endpoint key's Keychain item is unavailable. Unlock your Mac and try again."
        case .keychainWriteFailed: return "The endpoint key could not be saved and verified in Keychain."
        }
    }
}

/// A third-party endpoint's API key. Text conversions and reflection never include it.
public struct EndpointAPIKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    /// Parses pasted or piped text as data: a raw key, or exactly one `export NAME=value` or `NAME=value` line, its
    /// value optionally quoted, as in a shell key file. Nothing is executed. An Anthropic key (`sk-ant-…`) is refused:
    /// the endpoint's provider would receive it.
    public init(parsing raw: String) throws {
        guard raw.utf8.count <= 4096 else { throw EndpointKeyError.invalidKey }
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Without `export`, text whose value would start with "=" is a raw key with base64 padding, not an assignment.
        if let assignment = key.range(of: #"\A(?:export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression),
           key.range(of: #"\Aexport[ \t]"#, options: .regularExpression) != nil || !key[assignment.upperBound...].hasPrefix("=") {
            key = String(key[assignment.upperBound...])
            if let quote = key.first, quote == "'" || quote == "\"" {
                guard key.count >= 2, key.last == quote else { throw EndpointKeyError.invalidKey }
                key = String(key.dropFirst().dropLast())
            }
        }
        if let error = Self.rejection(of: key) { throw error }
        value = key
    }

    private init(validated value: String) { self.value = value }

    static func stored(_ value: String) -> EndpointAPIKey? { rejection(of: value) == nil ? EndpointAPIKey(validated: value) : nil }

    private static func rejection(of key: String) -> EndpointKeyError? {
        if key.lowercased().hasPrefix("sk-ant-") { return .anthropicKey }
        // A quote left at either end is a shell quote the paste kept, not part of a key.
        guard !key.isEmpty, key.utf8.count <= 512, key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              !"'\"".contains(key.first!), !"'\"".contains(key.last!) else { return .invalidKey }
        return nil
    }

    public var description: String { "Endpoint API key" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum EndpointLaunchError: Error, LocalizedError, Equatable {
    /// `option` named a model other than `pinned`.
    case modelNotAllowed(option: String, pinned: String)
    /// The `--settings` given to Claude Code sets this key, which the profile pins (`env.NAME` for a variable).
    case settingsConflict(String)
    /// The `--settings` given to Claude Code is neither a JSON object nor a readable file that holds one.
    case settingsUnreadable
    /// `--settings` was given more than once; Claude Code would silently keep only the last.
    case settingsRepeated
    /// An option whose effect on the settings Claudock cannot check, such as `--project-config-root`.
    case unsupportedOption(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotAllowed(let option, let pinned): return "This profile is pinned to the model \(pinned); \(option) can name only that model."
        case .settingsConflict(let key): return "--settings sets \(key), which this endpoint profile pins."
        case .settingsUnreadable: return "--settings must be a JSON object, or the path of a readable file that holds one."
        case .settingsRepeated: return "Pass --settings once; Claude Code would keep only the last one."
        case .unsupportedOption(let option):
            return "\(option) is not supported for endpoint profiles: Claudock cannot check the settings it points Claude Code to."
        }
    }
}

/// How Claude Code is started for a third-party endpoint profile.
public enum EndpointLaunch {
    /// Every model slot Claude Code has; each gets the pinned model.
    static let modelVariables = ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                                 "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
                                 "CLAUDE_CODE_SUBAGENT_MODEL"]

    /// `isolated`, which `LaunchCommand.environment` has cleared of inherited credentials, providers, and models, plus the
    /// endpoint: its URL, the key as a bearer token (`ANTHROPIC_AUTH_TOKEN`; `ANTHROPIC_API_KEY` would make an
    /// interactive Claude Code ask to approve it), the pinned model in every slot, and no nonessential traffic.
    /// Claude Code's default model is the Opus one with `[1m]`, so a model pinned without `[1m]` turns the
    /// one-million-token context off and keeps that default the pinned id; one pinned with `[1m]` keeps it on.
    /// Inherited telemetry settings go too: a third-party session is not reported to anyone.
    public static func environment(_ isolated: [String: String], configuration: EndpointConfiguration, key: String) -> [String: String] {
        var result = isolated.filter { !APICreditCapture.isTelemetryKey($0.key) }
        for (name, value) in settingsEnvironment(configuration, configDirectory: isolated["CLAUDE_CONFIG_DIR"] ?? "") {
            if value.isEmpty { result.removeValue(forKey: name) } else { result[name] = value }
        }
        result["ANTHROPIC_AUTH_TOKEN"] = key
        return result
    }

    static let oneMillionSwitch = "CLAUDE_CODE_DISABLE_1M_CONTEXT"

    /// Variables with which Claude Code 2.1.296 chooses a model for a role, offers another one in the picker, or picks a
    /// provider, beyond those `LaunchCommand` clears. Left empty, each role falls back to the pinned defaults.
    static let otherModelVariables = ["ANTHROPIC_DEFAULT_MODEL", "CLAUDE_CODE_AUTO_MODE_MODEL", "CLAUDE_CODE_BG_CLASSIFIER_MODEL",
                                      "CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL", "ANTHROPIC_CUSTOM_MODEL_OPTION", "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME",
                                      "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION", "ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES",
                                      "CLAUDE_CODE_USE_GATEWAY"]

    /// Variables a launch clears that `--settings` leaves alone: the nested-session marker is Claude Code's own, and the
    /// key cannot travel in arguments, which other processes can read.
    static let unpinnedVariables: Set<String> = ["CLAUDECODE", "ANTHROPIC_AUTH_TOKEN"]

    /// Where Claude Code 2.1.296 also reads managed settings, one JSON file each, beside `managed-settings.json`.
    public static let managedSettingsDirectory = "/Library/Application Support/ClaudeCode/managed-settings.d"

    /// The variables `--settings` repeats in its `env`. Claude Code copies each settings file's `env` over its process
    /// environment, lowest first, and `--settings` ranks above user, project, and local settings, so no settings file
    /// below managed settings can point the session elsewhere or choose another model. Every other credential, provider,
    /// and model variable a launch clears is blank, as are the other model-choosing ones: no settings file can add an
    /// Anthropic key or headers to the endpoint's requests (`ANTHROPIC_API_KEY` becomes `x-api-key` beside the bearer
    /// token), switch the provider, choose a model for another role, or move the profile's folder. The key itself is
    /// never here: a settings file that sets `ANTHROPIC_AUTH_TOKEN` is refused before launch instead (`overridingSettings`).
    static func settingsEnvironment(_ configuration: EndpointConfiguration, configDirectory: String) -> [String: String] {
        var result: [String: String] = [:]
        for name in LaunchCommand.clearedEnvironment + otherModelVariables where !unpinnedVariables.contains(name) { result[name] = "" }
        result["CLAUDE_CONFIG_DIR"] = configDirectory
        result["ANTHROPIC_BASE_URL"] = configuration.baseURL
        result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        // Claude Code 2.1.296 reads no such variable; it is set for versions that do.
        result["DISABLE_NON_ESSENTIAL_MODEL_CALLS"] = "1"
        result[oneMillionSwitch] = configuration.isOneMillionTokens ? "" : "1"
        for name in modelVariables { result[name] = configuration.model }
        return result
    }

    /// Settings files whose `env` Claude Code would apply against the pins, each with the first variable that would:
    /// the working directory's project settings when they set `ANTHROPIC_AUTH_TOKEN`, which would replace the key and
    /// which `--settings` cannot pin, and managed settings (`managed-settings.json` and the `.json` files of
    /// `managed-settings.d`), which outrank `--settings`, when they set the key or a pinned variable to another value.
    /// The profile's own settings are refused for the key already (`SubscriptionConfiguration`). A file that exists but
    /// cannot be parsed, or is too large to, is searched as text for those names instead, so it counts when it might set one.
    public static func overridingSettings(configuration: EndpointConfiguration, configDirectory: String, workingDirectory: String,
                                          managedSettings: [String] = APICreditCapture.managedSettingsFiles,
                                          managedDirectory: String = managedSettingsDirectory) -> [APICreditCapture.Override] {
        let pinned = settingsEnvironment(configuration, configDirectory: configDirectory)
        let dropIns = ((try? FileManager.default.contentsOfDirectory(atPath: managedDirectory)) ?? []).filter { $0.hasSuffix(".json") }
            .sorted().map { managedDirectory + "/" + $0 }
        let project = [workingDirectory + "/.claude/settings.json", workingDirectory + "/.claude/settings.local.json"].map { ($0, false) }
        return (project + (managedSettings + dropIns).map { ($0, true) }).compactMap { file, outranks in
            let names = ["ANTHROPIC_AUTH_TOKEN"] + (outranks ? pinned.keys.sorted() : [])
            var status = stat()
            guard stat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
            guard let data = BoundedFile.read(file, limit: 1_048_576), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return mentionedName(names, in: file).map { APICreditCapture.Override(file: file, key: $0) }
            }
            guard let environment = object["env"] as? [String: Any] else { return nil }
            return names.first { name in
                guard let value = environment[name] else { return false }
                if name == "ANTHROPIC_AUTH_TOKEN" { return (value as? String)?.isEmpty != true }
                return (value as? String) != pinned[name]
            }.map { APICreditCapture.Override(file: file, key: $0) }
        }
    }

    /// The first of `names` that appears in quotes in the first 16 MiB of `file`, or nil when it cannot be read either.
    private static func mentionedName(_ names: [String], in file: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: file), let data = try? handle.read(upToCount: 16 * 1_048_576) else { return nil }
        try? handle.close()
        return names.first { data.range(of: Data(("\"" + $0 + "\"").utf8)) != nil }
    }

    /// `arguments` with Claudock's `--settings` first: the user's own `--settings`, if Claude Code would read one, merged
    /// into it and taken out. The object pins the model for interactive choice too: `availableModels` makes `/model` and
    /// the model picker refuse other models (it matches by prefix, so the id without `[1m]` admits both forms), and with
    /// `behavesAs` a single `modelPicker` row maps the pinned id to a model Claude Code knows.
    public static func arguments(_ arguments: [String], configuration: EndpointConfiguration, configDirectory: String,
                                 workingDirectory: String) throws -> [String] {
        let options = ClaudeCommandLine.options(in: arguments)
        // It points Claude Code at project settings elsewhere, which overridingSettings does not read.
        if options.contains(where: { $0.name == "--project-config-root" }) { throw EndpointLaunchError.unsupportedOption("--project-config-root") }
        let given = options.filter { $0.name == "--settings" }
        guard given.count <= 1 else { throw EndpointLaunchError.settingsRepeated }
        var rest = arguments, user: [String: Any]?
        if let option = given.first {
            guard let value = option.value else { throw EndpointLaunchError.settingsUnreadable }
            user = try userSettings(value, workingDirectory: workingDirectory)
            for index in option.indices.sorted(by: >) { rest.remove(at: index) }
        }
        return ["--settings", try settings(configuration, configDirectory: configDirectory, merging: user)] + rest
    }

    /// As Claude Code reads `--settings`: trimmed text in braces is JSON, anything else a file path from the working directory.
    private static func userSettings(_ value: String, workingDirectory: String) throws -> [String: Any] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data?
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { data = Data(trimmed.utf8) }
        else if !trimmed.isEmpty { data = BoundedFile.read(trimmed.hasPrefix("/") ? trimmed : workingDirectory + "/" + trimmed, limit: 1_048_576) }
        else { data = nil }
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw EndpointLaunchError.settingsUnreadable
        }
        return object
    }

    static func settings(_ configuration: EndpointConfiguration, configDirectory: String, merging user: [String: Any]?) throws -> String {
        var object = user ?? [:]
        try refuseConflicts(object, configuration: configuration, configDirectory: configDirectory)
        var environment = object["env"] as? [String: Any] ?? [:]
        for (name, value) in settingsEnvironment(configuration, configDirectory: configDirectory) { environment[name] = value }
        object["env"] = environment
        // A project's key helper would otherwise send its own key to the endpoint, as x-api-key beside the bearer token.
        object["apiKeyHelper"] = ""
        object["availableModels"] = [configuration.baseModel]
        if let behavesAs = configuration.behavesAs {
            object["modelPicker"] = ["replaceBuiltInOptions": true,
                                     "options": [["model": configuration.model, "label": configuration.model,
                                                  "description": "Pinned by Claudock · \(configuration.host)", "behavesAs": behavesAs]]]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// A user's settings may not choose another model, endpoint, or credential: those keys must be absent, blank, or
    /// the pinned values.
    private static func refuseConflicts(_ object: [String: Any], configuration: EndpointConfiguration, configDirectory: String) throws {
        let pinned = configuration.model
        func models(_ value: Any) -> [String]? { (value as? String).map { [$0] } ?? value as? [String] }
        if let value = object["model"], models(value) != [pinned] { throw EndpointLaunchError.settingsConflict("model") }
        if let value = object["availableModels"],
           !(models(value).map { value is [String] && $0.allSatisfy { [pinned, configuration.baseModel].contains($0) } } ?? false) {
            throw EndpointLaunchError.settingsConflict("availableModels")
        }
        if let value = object["fallbackModel"], !(models(value)?.allSatisfy { $0 == pinned } ?? false) {
            throw EndpointLaunchError.settingsConflict("fallbackModel")
        }
        if let value = object["advisorModel"], models(value) != [pinned] { throw EndpointLaunchError.settingsConflict("advisorModel") }
        for key in ["modelOverrides", "modelPicker"] where object[key] != nil { throw EndpointLaunchError.settingsConflict(key) }
        if let helper = object["apiKeyHelper"], (helper as? String)?.isEmpty != true { throw EndpointLaunchError.settingsConflict("apiKeyHelper") }
        guard let value = object["env"] else { return }
        guard let environment = value as? [String: Any] else { throw EndpointLaunchError.settingsConflict("env") }
        let pinnedEnvironment = settingsEnvironment(configuration, configDirectory: configDirectory)
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            if let expected = pinnedEnvironment[name] {
                guard (value as? String) == expected else { throw EndpointLaunchError.settingsConflict("env." + name) }
            } else if LaunchCommand.clearedEnvironment.contains(name), (value as? String)?.isEmpty != true {
                // Every credential, provider, and model variable a launch clears.
                throw EndpointLaunchError.settingsConflict("env." + name)
            }
        }
    }

    /// Claude Code's options that name a model: the session's, its fallbacks (comma-separated), and the advisor's.
    static let modelOptions = ["--model", "--fallback-model", "--advisor"]

    /// Refuses `--model X`, `--fallback-model X[,Y…]`, `--advisor X`, and their `=` forms unless every model they name is
    /// the pinned one. Every argument is checked, after a `--` too: Claude Code takes the argument after an option that
    /// needs a value as that value, even `--`, so a `--` does not reliably end its options.
    public static func checkModelArguments(_ arguments: [String], configuration: EndpointConfiguration) throws {
        var index = 0
        while index < arguments.count {
            for option in modelOptions {
                let value: String
                if arguments[index] == option {
                    // Without a value Claude Code reports the missing argument itself and starts nothing.
                    guard index + 1 < arguments.count else { break }
                    index += 1
                    value = arguments[index]
                } else if arguments[index].hasPrefix(option + "=") {
                    value = String(arguments[index].dropFirst(option.count + 1))
                } else { continue }
                let models = option == "--fallback-model" ? value.split(separator: ",", omittingEmptySubsequences: false).map(String.init) : [value]
                guard models.allSatisfy({ $0 == configuration.model }) else {
                    throw EndpointLaunchError.modelNotAllowed(option: option, pinned: configuration.model)
                }
                break
            }
            index += 1
        }
    }
}

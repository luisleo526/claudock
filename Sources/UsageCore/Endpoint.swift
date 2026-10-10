import Foundation

public enum EndpointError: Error, LocalizedError, Equatable {
    case invalidBaseURL, invalidModel

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Use the endpoint's https URL, such as https://api.deepseek.com/anthropic: a host and optional path, "
                + "without a user name, password, query, or fragment."
        case .invalidModel:
            return "Use one model id of letters, digits, and . _ : / - (at most 128 characters), optionally ending in [1m], such as deepseek-flash."
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

    public init(baseURL: String, model: String) throws {
        self.baseURL = try Self.validatedBaseURL(baseURL)
        self.model = try Self.validatedModel(model)
    }

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

    private enum CodingKeys: String, CodingKey { case baseURL, model }

    /// A stored endpoint must already be valid and normalised; anything else makes the registry invalid.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let baseURL = try values.decode(String.self, forKey: .baseURL)
        try self.init(baseURL: baseURL, model: values.decode(String.self, forKey: .model))
        guard self.baseURL == baseURL else { throw EndpointError.invalidBaseURL }
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
        if let assignment = key.range(of: #"\A(?:export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) {
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

    public var errorDescription: String? {
        switch self {
        case .modelNotAllowed(let option, let pinned): return "This profile is pinned to the model \(pinned); \(option) can name only that model."
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
    /// Inherited telemetry settings go too: a third-party session is not reported to anyone.
    public static func environment(_ isolated: [String: String], configuration: EndpointConfiguration, key: String) -> [String: String] {
        var result = isolated.filter { !APICreditCapture.isTelemetryKey($0.key) }
        result["ANTHROPIC_BASE_URL"] = configuration.baseURL
        result["ANTHROPIC_AUTH_TOKEN"] = key
        for name in modelVariables { result[name] = configuration.model }
        result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        result["DISABLE_NON_ESSENTIAL_MODEL_CALLS"] = "1"
        return result
    }

    /// Refuses `--model X`, `--model=X`, `--fallback-model X[,Y…]`, and `--fallback-model=X[,Y…]` unless every model they
    /// name is the pinned one. Every argument is checked, after a `--` too: Claude Code takes the argument after an
    /// option that needs a value as that value, even `--`, so a `--` does not reliably end its options.
    public static func checkModelArguments(_ arguments: [String], configuration: EndpointConfiguration) throws {
        var index = 0
        while index < arguments.count {
            for option in ["--model", "--fallback-model"] {
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

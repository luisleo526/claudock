import Foundation

/// How a profile authenticates Claude Code. Only managed profiles created through Claudock can bill an
/// Anthropic Console organization or use a third-party endpoint; every other profile is a subscription.
public enum ProfileAuthKind: String, Codable, Hashable, Sendable, CaseIterable {
    case subscription
    /// A Console API key pasted into Claudock, which keeps it in Keychain and injects it at launch.
    case apiKey
    /// Claude Code's own Console sign-in (`claude auth login --console`), which keeps its API key itself.
    case consoleLogin
    /// A third-party service that speaks the Anthropic Messages protocol, with a key Claudock keeps in Keychain
    /// and one pinned model (`Profile.endpoint`).
    case endpoint

    /// Billed per token by a Console organization, through a pasted key or a Console sign-in.
    public var isConsole: Bool { self == .apiKey || self == .consoleLogin }
    /// Billed per token by a third-party provider: no Claude login, Console credit, or subscription limits.
    public var isEndpoint: Bool { self == .endpoint }

    public var title: String {
        switch self {
        case .subscription: return "Claude subscription"
        case .apiKey: return "Console API key"
        case .consoleLogin: return "Console account (sign in)"
        case .endpoint: return "Third-party endpoint"
        }
    }
}

public struct Profile: Identifiable, Codable, Hashable, Sendable {
    public var id: String { registryID ?? command }
    /// The legacy command remains the analytics and credential-identity boundary.
    public let command: String
    public let configDirectory: String
    public let isVertex: Bool
    public let discoveryNote: String?
    public let registryID: String?
    public let managed: Bool
    public let authKind: ProfileAuthKind
    /// The endpoint and pinned model of an `.endpoint` profile; nil for every other kind.
    public let endpoint: EndpointConfiguration?
    public var name: String { command == "claude" ? "default" : String(command.dropFirst(7)) }
    public var launchCommand: String {
        !isVertex && discoveryNote == nil && !configDirectory.isEmpty ? "claudock run \(command)" : command
    }

    public init(command: String, configDirectory: String, isVertex: Bool = false, discoveryNote: String? = nil,
                registryID: String? = nil, managed: Bool = false, authKind: ProfileAuthKind = .subscription,
                endpoint: EndpointConfiguration? = nil) {
        self.command = command
        self.configDirectory = configDirectory
        self.isVertex = isVertex
        self.discoveryNote = discoveryNote
        self.registryID = registryID
        self.managed = managed
        self.authKind = authKind
        self.endpoint = endpoint
    }

    private enum CodingKeys: String, CodingKey {
        case command, configDirectory, isVertex, discoveryNote, registryID, managed, authKind, endpoint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        command = try values.decode(String.self, forKey: .command)
        configDirectory = try values.decode(String.self, forKey: .configDirectory)
        isVertex = try values.decodeIfPresent(Bool.self, forKey: .isVertex) ?? false
        discoveryNote = try values.decodeIfPresent(String.self, forKey: .discoveryNote)
        registryID = try values.decodeIfPresent(String.self, forKey: .registryID)
        managed = try values.decodeIfPresent(Bool.self, forKey: .managed) ?? false
        authKind = try values.decodeIfPresent(ProfileAuthKind.self, forKey: .authKind) ?? .subscription
        endpoint = try values.decodeIfPresent(EndpointConfiguration.self, forKey: .endpoint)
    }

    /// Subscription records omit the kind, and only endpoint records hold an endpoint, so registries without
    /// those profiles keep their bytes.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(command, forKey: .command)
        try values.encode(configDirectory, forKey: .configDirectory)
        try values.encode(isVertex, forKey: .isVertex)
        try values.encodeIfPresent(discoveryNote, forKey: .discoveryNote)
        try values.encodeIfPresent(registryID, forKey: .registryID)
        try values.encode(managed, forKey: .managed)
        if authKind != .subscription { try values.encode(authKind, forKey: .authKind) }
        try values.encodeIfPresent(endpoint, forKey: .endpoint)
    }
}

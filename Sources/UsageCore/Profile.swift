import Foundation

public struct Profile: Identifiable, Codable, Hashable, Sendable {
    public var id: String { registryID ?? command }
    /// The legacy command remains the analytics and credential-identity boundary.
    public let command: String
    public let configDirectory: String
    public let isVertex: Bool
    public let discoveryNote: String?
    public let registryID: String?
    public let managed: Bool
    public var name: String { command == "claude" ? "default" : String(command.dropFirst(7)) }
    public var launchCommand: String {
        !isVertex && discoveryNote == nil && !configDirectory.isEmpty ? "claudock run \(command)" : command
    }

    public init(command: String, configDirectory: String, isVertex: Bool = false, discoveryNote: String? = nil,
                registryID: String? = nil, managed: Bool = false) {
        self.command = command
        self.configDirectory = configDirectory
        self.isVertex = isVertex
        self.discoveryNote = discoveryNote
        self.registryID = registryID
        self.managed = managed
    }

    private enum CodingKeys: String, CodingKey {
        case command, configDirectory, isVertex, discoveryNote, registryID, managed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        command = try values.decode(String.self, forKey: .command)
        configDirectory = try values.decode(String.self, forKey: .configDirectory)
        isVertex = try values.decodeIfPresent(Bool.self, forKey: .isVertex) ?? false
        discoveryNote = try values.decodeIfPresent(String.self, forKey: .discoveryNote)
        registryID = try values.decodeIfPresent(String.self, forKey: .registryID)
        managed = try values.decodeIfPresent(Bool.self, forKey: .managed) ?? false
    }
}

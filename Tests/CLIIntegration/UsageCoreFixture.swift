import Foundation

// Synthetic boundaries for the executable-level smoke checks. Profile and
// LaunchCommand are compiled from the unmodified production sources.
public enum MonitorError: Error, LocalizedError {
    case unsupported(String)
    case invalidResponse
    public var errorDescription: String? {
        if case .unsupported(let value) = self { return value }
        return nil
    }
}

public enum InferenceCredential {
    public static func environmentToken(profile: Profile) throws -> String? {
        ProcessInfo.processInfo.environment["CLAUDOCK_TEST_MINT"] == "1" ? "synthetic-mint-token" : nil
    }
}
public struct LocalHTTPRequest: Sendable {}
public actor LocalHTTPResponseWriter {}
public actor ConnectorSession {
    public static func defaultSession() async -> ConnectorSession? {
        ProcessInfo.processInfo.environment["CLAUDOCK_TEST_CONNECTORS"] == "1" ? ConnectorSession() : nil
    }
    public func authorize(_ bearer: String) async -> Bool { false }
}
public final class LoopbackHTTPServer: @unchecked Sendable {
    public init(token: String, handler: @escaping @Sendable (LocalHTTPRequest, LocalHTTPResponseWriter) async -> Void) {}
    public init(authorizeBearer: @escaping @Sendable (String) async -> Bool, handler: @escaping @Sendable (LocalHTTPRequest, LocalHTTPResponseWriter) async -> Void) {}
    public func start() async throws -> UInt16 { 12345 }
    public func stop() {}
}
public actor BalancedGateway {
    public init(selectors: Set<String>?) {
        if let path = ProcessInfo.processInfo.environment["CLAUDOCK_TEST_POOL_MARK"] {
            try? Data((selectors?.sorted().joined(separator: ",") ?? "all").utf8).write(to: URL(fileURLWithPath: path))
        }
    }
    public func prepare() async throws {}
    public func handle(_ request: LocalHTTPRequest, writer: LocalHTTPResponseWriter) async {}
}

public enum ProfileStore {
    public static func shellProfileNames() throws -> [String] { ["claude-smoke"] }
    private static func markAccess() {
        if let path = ProcessInfo.processInfo.environment["CLAUDOCK_TEST_MARK"] {
            _ = FileManager.default.createFile(atPath: path, contents: Data("store".utf8))
        }
    }

    public static func load() throws -> [Profile] {
        markAccess()
        return [
            Profile(command: "claude", configDirectory: "/synthetic/default"),
            Profile(command: "claude-smoke", configDirectory: "/synthetic/account space", registryID: "fixture-stable", managed: true),
            Profile(command: "claude-claude-smoke", configDirectory: "/synthetic/collision", managed: true),
            Profile(command: "claude-default", configDirectory: "/synthetic/legacy", managed: true),
            Profile(command: "claude-測試", configDirectory: "/synthetic/unicode"),
            Profile(command: "claude-vertex", configDirectory: "/synthetic/vertex", isVertex: true),
        ]
    }

    public static func importShellProfiles() throws -> [Profile] { try load() }
    public static func add(name: String, configDirectory: String?) throws -> Profile { try load()[1] }
    public static func rename(profile: Profile, to: String) throws -> Profile { profile }
    public static func remove(profile: Profile) throws {}
}

public enum ShellIntegration {
    public static func enable(cliPath: String) throws {
        if let path = ProcessInfo.processInfo.environment["CLAUDOCK_TEST_SHELL_MARK"] {
            try Data(cliPath.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
    public static func disable() throws {}
    public static func status() throws -> Bool { false }
}

public enum ClaudeExecutable {
    public static func find() -> String? { ProcessInfo.processInfo.environment["CLAUDOCK_TEST_EXECUTABLE"] }
}

public struct Credentials {
    public var subscriptionPlan: SubscriptionPlan { .max20x }
}
public enum CredentialStore {
    public static func serviceName(for profile: Profile) -> String { profile.registryID == "fixture-stable" ? "Claude Code-credentials-aabbccdd" : "Claude Code-credentials" }
    public static func read(profile: Profile) throws -> Credentials {
        if ProcessInfo.processInfo.environment["CLAUDOCK_TEST_FAIL_USAGE"] == "1" {
            throw MonitorError.unsupported("Synthetic quota error")
        }
        return Credentials()
    }
}

public struct UsageWindow {
    public let title: String
    public let percent: Double
    public let resetsAt: Date?
}
public struct UsageSnapshot { public let windows: [UsageWindow] }
public enum UsageClient {
    public static func fetch(credentials: Credentials) async throws -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(title: "Weekly", percent: 25.0, resetsAt: nil)])
    }
}

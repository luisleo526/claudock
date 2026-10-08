import Foundation

private func markAccess(_ boundary: String) {
    if let path = ProcessInfo.processInfo.environment["CLAUDOCK_TEST_MARK"] {
        _ = FileManager.default.createFile(atPath: path, contents: Data(boundary.utf8))
    }
}

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
        markAccess("mint credential")
        return ProcessInfo.processInfo.environment["CLAUDOCK_TEST_MINT"] == "1" ? "synthetic-mint-token" : nil
    }
}
public enum ProfileStore {
    public static func shellProfileNames() throws -> [String] { ["claude-smoke"] }
    public static func load() throws -> [Profile] {
        markAccess("profile store")
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
    public static func addAPIKeyProfile(name: String, apiKey: ConsoleAPIKey, configDirectory: String?) throws -> Profile { try load()[1] }
    public static func rename(profile: Profile, to: String) throws -> Profile { profile }
    public static func remove(profile: Profile) throws {}
}

// API-key paths are covered by api_key_e2e.py against the real Keychain; this smoke
// fixture only needs them to compile and to report any unexpected access.
public struct ConsoleAPIKey {
    public init(parsing raw: String) throws {
        markAccess("API key input")
        throw MonitorError.unsupported("The synthetic fixture stores no API keys.")
    }
}
public enum APIKeyStore {
    public static func serviceName(for profile: Profile) -> String { "Claudock-apikey-fixture" }
    public static func environmentKey(profile: Profile) throws -> String? { markAccess("API key"); return nil }
    public static func save(_ key: ConsoleAPIKey, profile: Profile) throws { markAccess("API key") }
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
        markAccess("OAuth credential")
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

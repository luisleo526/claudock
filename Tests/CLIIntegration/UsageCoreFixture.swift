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
    case rateLimited(Date?)
    case usageBusy
    public var errorDescription: String? {
        if case .unsupported(let value) = self { return value }
        return nil
    }
}

public enum LaunchCredential {
    case consoleAPIKey, consoleLogin, inferenceToken(String), profileLogin
}
/// Mirrors the real launch decision over a synthetic token (CLAUDOCK_TEST_MINT), policy
/// (CLAUDOCK_TEST_REQUIRE_TOKEN), and a saved token that belongs to another account
/// (CLAUDOCK_TEST_ACCOUNT_MISMATCH=mismatch|changed), so the smoke checks cover how the CLI passes sign-in
/// and arguments and how it words the account error. Sign-in and setup-token never read the token. As in the
/// real policy, a token that cannot be read reaches the CLI as its own error only while the requirement is off;
/// with it on, the launch is refused as having no valid token.
public enum InferenceTokenPolicy {
    public static func isRequired() -> Bool { ProcessInfo.processInfo.environment["CLAUDOCK_TEST_REQUIRE_TOKEN"] == "1" }
    public static func setRequired(_ required: Bool) throws { markAccess("preferences") }
    public static func launchCredential(profile: Profile, claudeArguments: [String], signIn: Bool) throws -> LaunchCredential {
        if signIn { return .profileLogin }
        if profile.authKind == .apiKey { return .consoleAPIKey }
        if profile.authKind == .consoleLogin { return .consoleLogin }
        if claudeArguments.first == "setup-token" { return .profileLogin }
        markAccess("mint credential")
        let unreadable: MintTokenError?
        switch ProcessInfo.processInfo.environment["CLAUDOCK_TEST_ACCOUNT_MISMATCH"] {
        case "mismatch": unreadable = .accountMismatch
        case "changed": unreadable = .accountChanged
        default: unreadable = nil
        }
        let token = ProcessInfo.processInfo.environment["CLAUDOCK_TEST_MINT"] == "1" ? "synthetic-mint-token" : nil
        guard isRequired() else {
            if let unreadable { throw unreadable }
            return token.map(LaunchCredential.inferenceToken) ?? .profileLogin
        }
        guard unreadable == nil, let token else { throw MonitorError.unsupported("Synthetic token requirement: no valid inference token.") }
        return .inferenceToken(token)
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
            Profile(command: "claude-team", configDirectory: "/synthetic/console team", registryID: "fixture-console", managed: true,
                    authKind: .consoleLogin),
        ]
    }

    public static func importShellProfiles() throws -> [Profile] { try load() }
    public static func add(name: String, configDirectory: String?) throws -> Profile { try load()[1] }
    public static func addAPIKeyProfile(name: String, apiKey: ConsoleAPIKey, configDirectory: String?) throws -> Profile { try load()[1] }
    public static func addConsoleLoginProfile(name: String, configDirectory: String?) throws -> Profile { try load()[6] }
    public static func setAuthKind(_ kind: ProfileAuthKind, for profile: Profile, beforePublishing: (Profile) throws -> Void = { _ in }) throws -> Profile {
        markAccess("kind change")
        throw MonitorError.unsupported("The synthetic fixture changes no profile kind.")
    }
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

// Console credit is covered by credit_e2e.py against the real ledger and launcher; amounts and row
// formatting come from the production APICredit.swift.
public enum APICreditStore {
    public static func status(profile: Profile) throws -> APICreditStatus? { markAccess("credit ledger"); return nil }
    public static func setBalance(_ amount: Decimal, profile: Profile) throws -> APICreditStatus {
        markAccess("credit ledger")
        throw MonitorError.unsupported("The synthetic fixture stores no credit.")
    }
}
public enum APICreditLaunchError: Error { case receiverUnavailable, launchFailed(Int32) }
public enum APICreditLaunch {
    public static func run(profile: Profile, executable: String, arguments: [String], environment: [String: String],
                           warn: (String) -> Void) throws -> Int32 {
        markAccess("credit launch")
        throw APICreditLaunchError.receiverUnavailable
    }
    public static func supervise(executable: String, arguments: [String], environment: [String: String]) throws -> Int32 {
        markAccess("supervised sign-in")
        throw APICreditLaunchError.launchFailed(ENOEXEC)
    }
}

// Console sign-in status is covered by console_login_e2e.py against the real Keychain; here it is
// CLAUDOCK_TEST_CONSOLE_SIGNED_IN=1, so the smoke checks cover how the CLI launches and words a missing sign-in.
public enum ConsoleLogin {
    public static func keychainService(for profile: Profile) -> String { "Claude Code-c0ffee00" }
    public static func isSignedIn(profile: Profile) throws -> Bool {
        markAccess("console sign-in")
        return ProcessInfo.processInfo.environment["CLAUDOCK_TEST_CONSOLE_SIGNED_IN"] == "1"
    }
    public static func organizationName(profile: Profile) -> String? { "Fixture Org" }
}

// CLI inference-token commands are covered by token_e2e.py against the real Keychain.
public enum MintTokenError: Error, LocalizedError {
    case unsupportedProfile, tokenExpired, accountMismatch, accountChanged
    public var errorDescription: String? { "Synthetic inference token error." }
}
public enum MintTokenStatus {
    case notConfigured
    case active(expiresAt: Date)
    case expired(expiresAt: Date)
    case imported(expiresAt: Date?)
}
public struct MintToken { public let expiresAt: Date? }
public enum MintTokenStore {
    public static func importToken(raw: String, profile: Profile, expiresAt: Date?) throws -> MintToken {
        markAccess("inference token")
        throw MintTokenError.unsupportedProfile
    }
    public static func status(profile: Profile) throws -> MintTokenStatus { markAccess("inference token"); return .notConfigured }
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
    public static func serviceName(for profile: Profile) -> String {
        switch profile.registryID {
        case "fixture-stable": return "Claude Code-credentials-aabbccdd"
        case "fixture-console": return "Claude Code-credentials-c0ffee00"
        default: return "Claude Code-credentials"
        }
    }
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
public struct UsageSnapshot {
    public let windows: [UsageWindow]
    public var fetchedAt = Date()
}
public enum UsageClient {
    public static func fetch(credentials: Credentials) async throws -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(title: "Weekly", percent: 25.0, resetsAt: nil)])
    }
}

// The shared cache, fetch lock, cooldowns, and pacing are covered by usage_e2e.py against a stub endpoint; here
// every reading is requested, so the smoke checks cover how the CLI prints rows and reports a failed profile.
public struct UsageReading {
    public let plan: SubscriptionPlan
    public let snapshot: UsageSnapshot
    public init(plan: SubscriptionPlan, snapshot: UsageSnapshot) { self.plan = plan; self.snapshot = snapshot }
}
public enum UsageResult {
    case current(UsageReading), cached(UsageReading, MonitorError), failed(MonitorError)
}
public actor UsageFetcher {
    public init() {}
    public func reading(for profile: Profile, maxAge: TimeInterval, fetch: @Sendable (Profile) async throws -> UsageReading) async -> UsageResult {
        markAccess("usage reading")
        do { return .current(try await fetch(profile)) }
        catch let error as MonitorError { return .failed(error) }
        catch { return .failed(.invalidResponse) }
    }
    public func finish() {}
}

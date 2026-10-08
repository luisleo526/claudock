import Foundation
import CryptoKit

public enum APIKeyError: Error, LocalizedError, Equatable {
    case invalidKey, oauthToken, adminKey
    case unsupportedProfile, invalidStoredKey, keychainUnavailable, keychainWriteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKey: return "Enter a Console API key that starts with sk-ant-api, or one complete export ANTHROPIC_API_KEY assignment. Do not include other commands."
        case .oauthToken: return "This is a subscription OAuth token, not a Console API key. Create a standard key in the Claude Console."
        case .adminKey: return "Admin API keys cannot run Claude Code; create a standard key in the Console."
        case .unsupportedProfile: return "Only profiles added with a Console API key can store one."
        case .invalidStoredKey: return "The saved Console API key is unreadable. Replace it with a new key."
        case .keychainUnavailable: return "The Console API key's Keychain item is unavailable. Unlock your Mac and try again."
        case .keychainWriteFailed: return "The Console API key could not be saved and verified in Keychain."
        }
    }
}

/// A validated Claude Console API key. Text conversions and reflection never include it.
public struct ConsoleAPIKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    /// Parses pasted or piped text as data: a raw `sk-ant-apiNN-…` key, or one complete
    /// `export ANTHROPIC_API_KEY=…` assignment, optionally quoted. Nothing is executed.
    public init(parsing raw: String) throws {
        guard raw.utf8.count <= 4096 else { throw APIKeyError.invalidKey }
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = key.range(of: #"\Aexport[ \t]+ANTHROPIC_API_KEY="#, options: .regularExpression) {
            key = String(key[prefix.upperBound...])
            if let quote = key.first, quote == "'" || quote == "\"" {
                guard key.count >= 2, key.last == quote else { throw APIKeyError.invalidKey }
                key = String(key.dropFirst().dropLast())
            }
        }
        if key.hasPrefix("sk-ant-oat") { throw APIKeyError.oauthToken }
        if key.hasPrefix("sk-ant-admin") { throw APIKeyError.adminKey }
        guard Self.isValid(key) else { throw APIKeyError.invalidKey }
        value = key
    }

    private init(validated value: String) { self.value = value }

    static func stored(_ value: String) -> ConsoleAPIKey? { isValid(value) ? ConsoleAPIKey(validated: value) : nil }

    private static func isValid(_ key: String) -> Bool {
        key.utf8.count <= 512 && key.range(of: #"\Ask-ant-api[0-9]{2}-[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil
    }

    public var description: String { "Console API key" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Console API keys live only in the login Keychain, in a namespace separate from Claude's
/// OAuth credentials and Claudock's inference tokens. A key never appears in process arguments.
public enum APIKeyStore {
    private static let writeLock = NSLock()

    public static func serviceName(for profile: Profile) -> String {
        "Claudock-apikey-" + SHA256.hash(data: Data(CredentialStore.serviceName(for: profile).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Returns nil when no key is saved. A locked or unreadable item is an error, never "missing".
    public static func read(profile: Profile) throws -> ConsoleAPIKey? {
        try read(profile: profile, securityRead: CredentialStore.runSecurity)
    }

    /// Only the launched Claude's environment receives the value. Never put it in argv.
    public static func environmentKey(profile: Profile) throws -> String? {
        try read(profile: profile)?.value
    }

    /// Saves through `security -i` on stdin, then reads the item back to verify it.
    public static func save(_ key: ConsoleAPIKey, profile: Profile) throws {
        try save(key, profile: profile, securityWrite: { command in
            guard CredentialStore.runSecurityCommand(command) else { throw APIKeyError.keychainWriteFailed }
        }, securityRead: { try CredentialStore.runSecurity(service: $0, timeout: 2) })
    }

    static func read(profile: Profile, securityRead: (String) throws -> (data: Data, status: Int32)) throws -> ConsoleAPIKey? {
        try validateProfile(profile)
        let result: (data: Data, status: Int32)
        do { result = try securityRead(serviceName(for: profile)) }
        catch { throw APIKeyError.keychainUnavailable }
        if result.status == 44 { return nil }
        guard result.status == 0 else { throw APIKeyError.keychainUnavailable }
        return try decode(result.data)
    }

    static func save(_ key: ConsoleAPIKey, profile: Profile, securityWrite: (Data) throws -> Void,
                     securityRead: (String) throws -> (data: Data, status: Int32)) throws {
        try validateProfile(profile)
        let service = serviceName(for: profile)
        let command = try securityWriteCommand(Data(key.value.utf8), account: NSUserName(), service: service)
        try writeLock.withLock {
            do { try securityWrite(command) } catch { throw APIKeyError.keychainWriteFailed }
            guard let result = try? securityRead(service), result.status == 0,
                  (try? decode(result.data)) == key else { throw APIKeyError.keychainWriteFailed }
        }
    }

    static func decode(_ data: Data) throws -> ConsoleAPIKey {
        // `security -w` prints the stored value followed by one newline.
        let stored = data.last == 0x0A ? data.dropLast() : data
        guard let text = String(data: stored, encoding: .utf8), let key = ConsoleAPIKey.stored(text) else {
            throw APIKeyError.invalidStoredKey
        }
        return key
    }

    /// Commands are interpreted by security's own REPL, never by a shell; the key is hex-encoded.
    static func securityWriteCommand(_ data: Data, account: String, service: String) throws -> Data {
        guard account.range(of: #"\A[a-zA-Z0-9._-]+\z"#, options: .regularExpression) != nil,
              service.range(of: #"\AClaudock-apikey-[a-f0-9]{64}\z"#, options: .regularExpression) != nil else { throw APIKeyError.keychainWriteFailed }
        let prefix = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \""
        let suffix = "\"\n"
        guard data.count <= 2016, prefix.utf8.count + data.count * 2 + suffix.utf8.count <= 4032 else { throw APIKeyError.keychainWriteFailed }
        return Data((prefix + data.map { String(format: "%02x", $0) }.joined() + suffix).utf8)
    }

    static func validateProfile(_ profile: Profile) throws {
        guard profile.authKind == .apiKey, profile.managed, !profile.isVertex, profile.discoveryNote == nil,
              profile.configDirectory.hasPrefix("/"), !profile.configDirectory.contains("\0") else { throw APIKeyError.unsupportedProfile }
    }
}

import Foundation
import CryptoKit

/// Third-party endpoint keys live only in the login Keychain, in a namespace of their own beside Claude's OAuth
/// credentials, Claudock's inference tokens, and Console API keys. A key never appears in process arguments.
public enum EndpointKeyStore {
    private static let writeLock = NSLock()

    public static func serviceName(for profile: Profile) -> String {
        "Claudock-endpointkey-" + SHA256.hash(data: Data(CredentialStore.serviceName(for: profile).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Returns nil when no key is saved. A locked or unreadable item is an error, never "missing".
    public static func read(profile: Profile) throws -> EndpointAPIKey? {
        try read(profile: profile, securityRead: CredentialStore.runSecurity)
    }

    /// Only the launched Claude's environment receives the value. Never put it in argv.
    public static func environmentKey(profile: Profile) throws -> String? {
        try read(profile: profile)?.value
    }

    /// Whether a key is saved, from an attribute-only lookup: status checks never read the key.
    public static func isSaved(profile: Profile) throws -> Bool {
        try isSaved(profile: profile, security: { try CredentialStore.runSecurityStatus($0) })
    }

    /// Saves through `security -i` on stdin, then reads the item back to verify it.
    public static func save(_ key: EndpointAPIKey, profile: Profile) throws {
        try save(key, profile: profile, securityWrite: { command in
            guard CredentialStore.runSecurityCommand(command) else { throw EndpointKeyError.keychainWriteFailed }
        }, securityRead: { try CredentialStore.runSecurity(service: $0, timeout: 2) })
    }

    static func read(profile: Profile, securityRead: (String) throws -> (data: Data, status: Int32)) throws -> EndpointAPIKey? {
        try validateProfile(profile)
        let result: (data: Data, status: Int32)
        do { result = try securityRead(serviceName(for: profile)) }
        catch { throw EndpointKeyError.keychainUnavailable }
        if result.status == 44 { return nil }
        guard result.status == 0 else { throw EndpointKeyError.keychainUnavailable }
        return try decode(result.data)
    }

    static func save(_ key: EndpointAPIKey, profile: Profile, securityWrite: (Data) throws -> Void,
                     securityRead: (String) throws -> (data: Data, status: Int32)) throws {
        try validateProfile(profile)
        let service = serviceName(for: profile)
        let command = try securityWriteCommand(Data(key.value.utf8), account: NSUserName(), service: service)
        try writeLock.withLock {
            do { try securityWrite(command) } catch { throw EndpointKeyError.keychainWriteFailed }
            guard let result = try? securityRead(service), result.status == 0,
                  (try? decode(result.data)) == key else { throw EndpointKeyError.keychainWriteFailed }
        }
    }

    static func isSaved(profile: Profile, security: ([String]) throws -> Int32) throws -> Bool {
        try validateProfile(profile)
        let status: Int32
        do { status = try security(["find-generic-password", "-a", NSUserName(), "-s", serviceName(for: profile)]) }
        catch { throw EndpointKeyError.keychainUnavailable }
        if status == 44 { return false }
        guard status == 0 else { throw EndpointKeyError.keychainUnavailable }
        return true
    }

    /// Best effort, to undo an item that a failed profile add created.
    static func delete(profile: Profile, security: ([String]) throws -> Int32 = { try CredentialStore.runSecurityStatus($0) }) {
        guard (try? validateProfile(profile)) != nil else { return }
        _ = try? security(["delete-generic-password", "-a", NSUserName(), "-s", serviceName(for: profile)])
    }

    static func decode(_ data: Data) throws -> EndpointAPIKey {
        // `security -w` prints the stored value followed by one newline.
        let stored = data.last == 0x0A ? data.dropLast() : data
        guard let text = String(data: stored, encoding: .utf8), let key = EndpointAPIKey.stored(text) else {
            throw EndpointKeyError.invalidStoredKey
        }
        return key
    }

    /// Commands are interpreted by security's own REPL, never by a shell; the key is hex-encoded.
    static func securityWriteCommand(_ data: Data, account: String, service: String) throws -> Data {
        guard account.range(of: #"\A[a-zA-Z0-9._-]+\z"#, options: .regularExpression) != nil,
              service.range(of: #"\AClaudock-endpointkey-[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
            throw EndpointKeyError.keychainWriteFailed
        }
        let prefix = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \""
        let suffix = "\"\n"
        guard data.count <= 2016, prefix.utf8.count + data.count * 2 + suffix.utf8.count <= 4032 else { throw EndpointKeyError.keychainWriteFailed }
        return Data((prefix + data.map { String(format: "%02x", $0) }.joined() + suffix).utf8)
    }

    static func validateProfile(_ profile: Profile) throws {
        guard profile.authKind == .endpoint, profile.endpoint != nil, profile.managed, !profile.isVertex, profile.discoveryNote == nil,
              profile.configDirectory.hasPrefix("/"), !profile.configDirectory.contains("\0") else { throw EndpointKeyError.unsupportedProfile }
    }
}

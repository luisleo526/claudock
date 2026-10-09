import Foundation

public enum ConsoleLoginError: Error, LocalizedError, Equatable {
    case unsupportedProfile, keychainUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile: return "Only Console profiles added through Claudock can sign in to an Anthropic Console account."
        case .keychainUnavailable: return "Claudock could not check the Console sign-in in Keychain. Unlock your Mac and try again."
        }
    }
}

/// Claude Code's own sign-in to an Anthropic Console account (`claude auth login --console`). Claude Code creates an
/// API key and keeps it in the login Keychain under "Claude Code" plus the config folder's hash, beside its OAuth
/// credentials, and records the account in the folder's `.claude.json` (Claude Code 2.1.295). Claudock only checks
/// that the item exists, from its attributes; it never reads the key or passes it to Claude.
public enum ConsoleLogin {
    static let organizationLimit = 80

    /// The default profile's item is plain "Claude Code"; any other folder's adds its hash, as its credentials do.
    public static func keychainService(for profile: Profile) -> String {
        "Claude Code" + CredentialStore.serviceSuffix(for: profile)
    }

    /// Whether Claude Code's key item exists. A locked or unreadable Keychain is an error, never "signed out".
    public static func isSignedIn(profile: Profile) throws -> Bool {
        try isSignedIn(profile: profile, security: { try CredentialStore.runSecurityStatus($0) })
    }

    static func isSignedIn(profile: Profile, security: ([String]) throws -> Int32) throws -> Bool {
        // An API-key profile is checked too: it switches to its Console sign-in only once the item exists.
        guard profile.authKind.isConsole, profile.managed, profile.command != "claude", !profile.isVertex, profile.discoveryNote == nil,
              profile.configDirectory.hasPrefix("/"), !profile.configDirectory.contains("\0") else { throw ConsoleLoginError.unsupportedProfile }
        let status: Int32
        do { status = try security(["find-generic-password", "-a", NSUserName(), "-s", keychainService(for: profile)]) }
        catch { throw ConsoleLoginError.keychainUnavailable }
        if status == 44 { return false }
        guard status == 0 else { throw ConsoleLoginError.keychainUnavailable }
        return true
    }

    /// The Console organization Claude Code recorded at sign-in, `oauthAccount.organizationName`, as display text.
    public static func organizationName(profile: Profile) -> String? {
        BoundedFile.read(CredentialStore.claudeState(for: profile).path, limit: 10_485_760).flatMap(organizationName(claudeState:))
    }

    /// The name is untrusted: control and format characters (bidirectional overrides among them) and line breaks
    /// become spaces, runs of white space collapse to one, and a name longer than 80 characters is cut short.
    static func organizationName(claudeState: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: claudeState) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any], let raw = account["organizationName"] as? String else { return nil }
        var visible = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars { visible.append(CharacterSet.controlCharacters.contains(scalar) ? " " : scalar) }
        let name = String(visible).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return name.count > organizationLimit ? String(name.prefix(organizationLimit - 1)) + "…" : name
    }
}

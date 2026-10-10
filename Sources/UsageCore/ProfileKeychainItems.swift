import Foundation

/// A Keychain item that can hold a credential for one profile.
public struct ProfileKeychainItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Claude Code's OAuth login for the config folder, for a subscription or a Console account.
        case login
        /// The API key Claude Code's own Console sign-in keeps for the config folder.
        case consoleKey
        /// A long-lived inference token saved by Claudock.
        case inferenceToken
        /// A Console API key saved by Claudock.
        case apiKey
    }

    public let kind: Kind
    public let service: String

    public var title: String {
        switch kind {
        case .login: return "Claude Code login (shared with anything else that uses this config folder)"
        case .consoleKey: return "Console API key from Claude Code's sign-in"
        case .inferenceToken: return "Claudock inference token"
        case .apiKey: return "Claudock Console API key"
        }
    }

    /// The command that deletes the item. Claudock only shows it; the person decides whether to run it.
    public var deleteCommand: String { ProfileKeychainItems.deleteCommand(service: service) }
}

/// What Keychain said about a profile's items.
public struct ProfileKeychainLookup: Equatable, Sendable {
    /// Items Keychain confirmed.
    public let existing: [ProfileKeychainItem]
    /// Items Keychain could not be asked about, because it is locked or `security` failed. They may exist.
    public let unchecked: [ProfileKeychainItem]
}

/// The Keychain items a profile can leave behind. Removing a profile keeps its credentials, so the person removing
/// it needs every item named: Claude Code's own and Claudock's, whatever kind of profile it was, because a profile
/// that switched between a pasted key and a Console sign-in has both.
public enum ProfileKeychainItems {
    /// Every item that could hold a credential for `profile`, in the order they are shown, without asking Keychain.
    /// A profile with no known config folder has none: its names would be those of another account's items.
    public static func items(for profile: Profile) -> [ProfileKeychainItem] {
        guard !profile.isVertex, profile.discoveryNote == nil, !profile.configDirectory.contains("\0"),
              profile.command == "claude" || profile.configDirectory.hasPrefix("/") else { return [] }
        return [ProfileKeychainItem(kind: .login, service: CredentialStore.serviceName(for: profile)),
                ProfileKeychainItem(kind: .consoleKey, service: ConsoleLogin.keychainService(for: profile)),
                ProfileKeychainItem(kind: .inferenceToken, service: MintTokenStore.serviceName(for: profile)),
                ProfileKeychainItem(kind: .apiKey, service: APIKeyStore.serviceName(for: profile))]
    }

    /// Which of the profile's items exist, from attribute-only lookups: no secret is read, so nothing prompts.
    public static func lookup(for profile: Profile) -> ProfileKeychainLookup {
        lookup(for: profile, security: { try CredentialStore.runSecurityStatus($0) })
    }

    static func lookup(for profile: Profile, security: ([String]) throws -> Int32) -> ProfileKeychainLookup {
        var existing: [ProfileKeychainItem] = [], unchecked: [ProfileKeychainItem] = []
        for item in items(for: profile) {
            switch try? security(["find-generic-password", "-a", NSUserName(), "-s", item.service]) {
            case 0?: existing.append(item)
            case 44?: break
            default: unchecked.append(item)
            }
        }
        return ProfileKeychainLookup(existing: existing, unchecked: unchecked)
    }

    /// A command to run in Terminal, so the service is quoted for the shell.
    public static func deleteCommand(service: String) -> String {
        "security delete-generic-password -s " + LaunchCommand.quote(service)
    }
}

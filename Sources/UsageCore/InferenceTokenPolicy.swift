import Foundation

/// What a `run` launch passes to Claude Code.
public enum LaunchCredential: Equatable, Sendable {
    /// A Console API-key profile's key, read from Keychain at launch.
    case consoleAPIKey
    /// A subscription profile's inference token, passed as `CLAUDE_CODE_OAUTH_TOKEN`.
    case inferenceToken(String)
    /// No token: Claude Code uses the profile's own login.
    case profileLogin
}

public enum InferenceTokenPolicyError: Error, LocalizedError, Equatable {
    case tokenRequired(String)
    case preferenceNotSaved

    public var errorDescription: String? {
        switch self {
        case .tokenRequired(let name):
            return "\(name) has no valid inference token and Claudock requires one. Create one with 'claudock run \(name) -- setup-token', then 'pbpaste | claudock profile set-token \(name)'."
        case .preferenceNotSaved: return "Claudock could not save the inference token requirement. Try again."
        }
    }
}

/// The optional rule that every Claudock launch of a subscription profile uses its inference
/// token. It is off by default and shared by the app and the CLI through their preferences domain.
public enum InferenceTokenPolicy {
    public static let preferenceKey = "requireInferenceToken"

    public static func isRequired() -> Bool {
        ClaudeExecutable.preferences?.bool(forKey: preferenceKey) ?? false
    }

    /// Turning the requirement off removes the key, returning the preference to its default.
    public static func setRequired(_ required: Bool) throws {
        guard let preferences = ClaudeExecutable.preferences else { throw InferenceTokenPolicyError.preferenceNotSaved }
        if required { preferences.set(true, forKey: preferenceKey) } else { preferences.removeObject(forKey: preferenceKey) }
        // A command-line process exits right away, so write through before checking.
        preferences.synchronize()
        guard preferences.bool(forKey: preferenceKey) == required else { throw InferenceTokenPolicyError.preferenceNotSaved }
    }

    /// Chooses the credential for a `run` launch (sign-in launches never ask). With the requirement
    /// off, a subscription profile falls back to its own login as before. With it on, a missing,
    /// expired, or unreadable token is an error, except for `setup-token`, which creates the token.
    public static func launchCredential(profile: Profile, claudeArguments: [String], requireToken: Bool) throws -> LaunchCredential {
        try launchCredential(profile: profile, claudeArguments: claudeArguments, requireToken: requireToken, mint: MintTokenStore.read)
    }

    static func launchCredential(profile: Profile, claudeArguments: [String], requireToken: Bool,
                                 mint: (Profile) throws -> MintToken?, now: Date = Date()) throws -> LaunchCredential {
        if profile.authKind == .apiKey { return .consoleAPIKey }
        guard requireToken else {
            return try InferenceCredential.environmentToken(profile: profile, mint: mint, now: now).map(LaunchCredential.inferenceToken) ?? .profileLogin
        }
        if claudeArguments.first == "setup-token" { return .profileLogin }
        let token: String?
        do { token = try InferenceCredential.environmentToken(profile: profile, mint: mint, now: now) }
        catch { throw InferenceTokenPolicyError.tokenRequired(profile.name) }
        guard let token else { throw InferenceTokenPolicyError.tokenRequired(profile.name) }
        return .inferenceToken(token)
    }
}

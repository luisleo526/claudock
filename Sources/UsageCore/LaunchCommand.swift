import Foundation

public enum LaunchCommand {
    static let clearedEnvironment = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_FOUNDRY",
        "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION", "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL", "CLAUDECODE", "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_PROFILE",
        "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_ORGANIZATION_ID",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES", "CLAUDE_CODE_OAUTH_CLIENT_ID"]
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Shared auth/provider isolation for direct exec (CLI) and Terminal scripts (GUI).
    public static func environment(profile: Profile, inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        guard profile.discoveryNote == nil, !profile.isVertex, profile.configDirectory.hasPrefix("/"),
              !profile.configDirectory.contains("\0") else {
            throw MonitorError.unsupported("This profile cannot be launched safely. Import its config folder or choose a subscription profile.")
        }
        var result = inherited
        for key in clearedEnvironment { result.removeValue(forKey: key) }
        if profile.command != "claude" { result["CLAUDE_CONFIG_DIR"] = profile.configDirectory }
        return result
    }

    public static func script(profile: Profile, executable: String, arguments: [String], workingDirectory: String) throws -> String {
        _ = try environment(profile: profile, inherited: [:])
        guard profile.discoveryNote == nil, !profile.isVertex, !profile.configDirectory.isEmpty,
              executable.hasPrefix("/"), workingDirectory.hasPrefix("/"),
              ([executable, workingDirectory, profile.configDirectory] + arguments).allSatisfy({ !$0.contains("\0") }) else {
            throw MonitorError.unsupported("This profile cannot be launched safely. Import its config folder or choose a subscription profile.")
        }
        let environment = clearedEnvironment.map { "-u " + quote($0) }.joined(separator: " ")
        let config = profile.command == "claude" ? "" : " " + quote("CLAUDE_CONFIG_DIR=" + profile.configDirectory)
        return """
        #!/bin/zsh
        # Created only after an explicit action in Claudock. Contains no credentials.
        cd -- \(quote(workingDirectory)) || exit 1
        /bin/rm -f -- "$0"
        exec /usr/bin/env \(environment)\(config) \(quote(executable)) \(arguments.map(quote).joined(separator: " "))

        """
    }
}

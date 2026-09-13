import Foundation

/// Shared CLI selection for the app and the bundled `claudock` command.
public enum ClaudeExecutable {
    // Retained across the product rename to preserve existing user preferences.
    public static let preferencesDomain = "io.github.claudeusage.ClaudeUsage"

    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment,
                            customPath: String? = nil, home: String = NSHomeDirectory()) -> String? {
        var candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home + "/.npm-global/bin/claude", home + "/.bun/bin/claude"]
        let preferences = Bundle.main.bundleIdentifier == preferencesDomain ? UserDefaults.standard : UserDefaults(suiteName: preferencesDomain)
        let configured = customPath ?? preferences?.string(forKey: "claudeExecutable")
        if let configured, !configured.isEmpty { candidates.insert(configured, at: 0) }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        return candidates.first {
            var directory: ObjCBool = false
            return $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}

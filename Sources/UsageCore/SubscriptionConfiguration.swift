import Foundation
import Darwin

/// Read-only validation of account-level provider/authentication selectors.
/// It does not classify subscription tiers or execute helpers and shell code.
public enum SubscriptionConfiguration {
    private static let maximumBytes = 1_048_576
    private static let providerFlags = ["CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_USE_MANTLE"]
    private static let credentialOverrides = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS",
        "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "CLAUDE_CODE_OAUTH_CLIENT_ID", "CLAUDE_CODE_OAUTH_SCOPES", "ANTHROPIC_PROFILE", "ANTHROPIC_FEDERATION_RULE_ID",
        "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_ORGANIZATION_ID",
        "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
        "CLAUDE_CODE_GATEWAY_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR",
        "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_BG_AUTH_SNAPSHOT_PATH",
        "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH", "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH", "ANTHROPIC_UNIX_SOCKET"]
    private static var unsupported: MonitorError {
        .unsupported("Claudock requires an official Claude Pro, Max, Team, or Enterprise subscription. Use readable JSON settings without external providers, authentication/storage overrides, or apiKeyHelper.")
    }

    public static func validate(configDirectory: String) throws {
        guard configDirectory.hasPrefix("/"), !configDirectory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw unsupported
        }
        var directory = stat()
        if stat(configDirectory, &directory) == 0 {
            guard directory.st_mode & S_IFMT == S_IFDIR else { throw unsupported }
        } else {
            // A not-yet-created config directory has no settings. An existing
            // dangling directory symlink is not an absent configuration.
            guard errno == ENOENT else { throw unsupported }
            var entry = stat()
            guard lstat(configDirectory, &entry) != 0, errno == ENOENT else { throw unsupported }
        }

        for name in ["settings.json", "settings.local.json"] {
            let path = URL(fileURLWithPath: configDirectory).appendingPathComponent(name).path
            guard let data = try readSettings(path) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unsupported }
            if let helper = object["apiKeyHelper"] {
                guard let text = helper as? String, text.isEmpty else { throw unsupported }
            }
            if let value = object["env"] {
                guard let environment = value as? [String: Any] else { throw unsupported }
                for flag in providerFlags {
                    if let value = environment[flag], try enabled(value) { throw unsupported }
                }
                for key in credentialOverrides {
                    if let value = environment[key] {
                        guard let text = value as? String, text.isEmpty else { throw unsupported }
                    }
                }
                if let value = environment["ANTHROPIC_BASE_URL"] {
                    guard let text = value as? String else { throw unsupported }
                    if !text.isEmpty {
                        guard let url = URLComponents(string: text), url.scheme?.lowercased() == "https",
                              url.host?.lowercased() == "api.anthropic.com", url.port == nil || url.port == 443,
                              url.path.isEmpty || url.path == "/", url.user == nil, url.password == nil,
                              url.query == nil, url.fragment == nil else { throw unsupported }
                    }
                }
            }
        }
    }

    private static func enabled(_ value: Any) throws -> Bool {
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true": return true
            case "", "0", "false": return false
            default: throw unsupported
            }
        }
        if let number = value as? NSNumber {
            switch number.doubleValue {
            case 1: return true
            case 0: return false
            default: throw unsupported
            }
        }
        throw unsupported
    }

    private static func readSettings(_ path: String) throws -> Data? {
        var entry = stat()
        guard lstat(path, &entry) == 0 else {
            if errno == ENOENT { return nil }
            throw unsupported
        }
        // Follow a shared settings symlink, but never block on a FIFO or accept
        // a directory/device as configuration. Failed existing links fail closed.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw unsupported }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else { throw unsupported }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else { throw unsupported }
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw unsupported }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw unsupported }
        }
        var after = stat(), current = stat()
        guard fstat(descriptor, &after) == 0, stat(path, &current) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size, data.count == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              current.st_dev == before.st_dev, current.st_ino == before.st_ino,
              current.st_size == before.st_size,
              current.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw unsupported }
        return data
    }
}

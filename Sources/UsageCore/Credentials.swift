import Foundation
import CryptoKit

public struct Credentials: Sendable {
    // Never persisted, printed, or passed to a subprocess argument.
    let accessToken: String
    public let expiresAt: Date?
    public let plan: String?
    let refreshToken: String?
    let refreshTokenExpiresAt: Date?
    let scopes: [String]
    let clientID: String?

    init(accessToken: String, expiresAt: Date?, plan: String?, refreshToken: String? = nil,
         refreshTokenExpiresAt: Date? = nil, scopes: [String] = [], clientID: String? = nil) {
        self.accessToken = accessToken; self.expiresAt = expiresAt; self.plan = plan
        self.refreshToken = refreshToken; self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes; self.clientID = clientID
    }

    func hasSameTokens(as other: Credentials) -> Bool {
        accessToken == other.accessToken && refreshToken == other.refreshToken
    }
    public static func parse(_ data: Data) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw MonitorError.noCredentials }
        func date(_ key: String) -> Date? {
            (oauth[key] as? NSNumber).flatMap { value -> Date? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
            return Date(timeIntervalSince1970: value.doubleValue / 1000)
            }
        }
        let refresh = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Credentials(accessToken: token, expiresAt: date("expiresAt"), plan: oauth["subscriptionType"] as? String,
                           refreshToken: refresh, refreshTokenExpiresAt: date("refreshTokenExpiresAt"),
                           scopes: oauth["scopes"] as? [String] ?? [],
                           clientID: (oauth["clientId"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

public enum CredentialStore {
    public static func serviceName(for profile: Profile) -> String {
        if profile.command == "claude" { return "Claude Code-credentials" }
        let path = profile.configDirectory.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash.prefix(8)
    }
    public static func read(profile: Profile) throws -> Credentials {
        try readStored(profile: profile).credentials
    }

    static func runSecurity(service: String) throws -> (data: Data, status: Int32) {
        try runSecurity(service: service, timeout: 15)
    }

    static func runSecurity(service: String, timeout: TimeInterval) throws -> (data: Data, status: Int32) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-s", service, "-w"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        do { try process.run() } catch { throw MonitorError.keychainLocked }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); deadline.cancel()
        return (data, process.terminationStatus)
    }

    public static func email(for profile: Profile) -> String? {
        let path = profile.command == "claude"
            ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
            : URL(fileURLWithPath: profile.configDirectory).appendingPathComponent(".claude.json")
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 10_485_760,
              let data = try? Data(contentsOf: path), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }
}

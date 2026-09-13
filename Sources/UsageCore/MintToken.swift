import Foundation
import CryptoKit
import Security
import Darwin

public enum MintTokenError: Error, LocalizedError, Equatable {
    case unsupportedProfile, loginRequired, invalidCode, stateMismatch, invalidResponse
    case accountMismatch, accountChanged, identityUnavailable, network, exchangeFailed
    case keychainUnavailable, keychainWriteFailed, tokenTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile: return "Choose a supported Claude subscription profile."
        case .loginRequired: return "Sign in to this profile with Claude Code first, then create its inference token."
        case .invalidCode: return "Paste the complete authorization code, including its #state suffix."
        case .stateMismatch: return "This code belongs to a different sign-in attempt. Open the browser again and use the new code."
        case .invalidResponse: return "Claude returned an incomplete inference token. Open the browser again to retry."
        case .accountMismatch: return "The browser account does not match this profile. Use the profile's existing Claude account."
        case .accountChanged: return "This profile's login changed during authorization. Start again with its current account."
        case .identityUnavailable: return "Claude did not return a verifiable account identity. Keep using the normal Claude Code login."
        case .network: return "Could not complete authorization with Claude. Open the browser again to retry."
        case .exchangeFailed: return "Claude rejected this authorization. Open the browser again and use a fresh code."
        case .keychainUnavailable: return "The inference token's Keychain item is unavailable. Unlock your Mac and try again."
        case .keychainWriteFailed: return "The inference token could not be saved and verified in Keychain. Your existing Claude login was preserved."
        case .tokenTooLarge: return "This token exceeds the supported secure storage size. Your existing Claude login was preserved."
        }
    }
}

struct MintAccountIdentity: Codable, Equatable, Sendable {
    let accountUUID: String
    let organizationUUID: String

    init(accountUUID: String, organizationUUID: String) throws {
        guard let account = UUID(uuidString: accountUUID), let organization = UUID(uuidString: organizationUUID) else {
            throw MintTokenError.identityUnavailable
        }
        self.accountUUID = account.uuidString.lowercased()
        self.organizationUUID = organization.uuidString.lowercased()
    }

    static func cached(profile: Profile) throws -> MintAccountIdentity {
        let url = profile.command == "claude"
            ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
            : URL(fileURLWithPath: profile.configDirectory).appendingPathComponent(".claude.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MintTokenError.loginRequired }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= 10_485_760,
              let data = try? handle.read(upToCount: 10_485_761), data.count <= 10_485_760,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let accountID = account["accountUuid"] as? String,
              let organizationID = account["organizationUuid"] as? String,
              let identity = try? MintAccountIdentity(accountUUID: accountID, organizationUUID: organizationID) else {
            throw MintTokenError.loginRequired
        }
        return identity
    }
}

public struct MintToken: Sendable {
    let accessToken: String
    public let expiresAt: Date
    let identity: MintAccountIdentity

    static func parseResponse(_ data: Data, now: Date, expected: MintAccountIdentity) throws -> MintToken {
        guard data.count <= 131_072,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, OAuthRefreshResult.validToken(access),
              let expiry = root["expires_in"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              expiry.doubleValue.isFinite, expiry.doubleValue > 0, expiry.doubleValue <= 315_360_000,
              let scope = root["scope"] as? String,
              Set(scope.split(whereSeparator: { $0.isWhitespace }).map(String.init)) == ["user:inference"] else {
            throw MintTokenError.invalidResponse
        }
        if let kind = root["token_type"], (kind as? String)?.lowercased() != "bearer" { throw MintTokenError.invalidResponse }
        guard let account = root["account"] as? [String: Any], let accountID = account["uuid"] as? String,
              let organization = root["organization"] as? [String: Any], let organizationID = organization["uuid"] as? String else {
            throw MintTokenError.identityUnavailable
        }
        let identity = try MintAccountIdentity(accountUUID: accountID, organizationUUID: organizationID)
        guard identity == expected else { throw MintTokenError.accountMismatch }
        return MintToken(accessToken: access, expiresAt: now.addingTimeInterval(expiry.doubleValue), identity: identity)
    }
}

/// A separate browser authorization. It never rotates or overwrites usage OAuth.
public struct MintTokenFlow: Sendable {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    private let profile: Profile
    private let expectedIdentity: MintAccountIdentity
    let verifier: String
    let state: String

    public init(profile: Profile) throws {
        try MintTokenStore.validateProfile(profile)
        self.profile = profile
        expectedIdentity = try MintAccountIdentity.cached(profile: profile)
        verifier = try Self.randomValue()
        state = try Self.randomValue()
    }

    init(profile: Profile, expectedIdentity: MintAccountIdentity, verifier: String, state: String) {
        self.profile = profile; self.expectedIdentity = expectedIdentity
        self.verifier = verifier; self.state = state
    }

    public var authorizationURL: URL {
        var url = URLComponents(string: "https://claude.com/cai/oauth/authorize")!
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        url.queryItems = [URLQueryItem(name: "code", value: "true"), URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: "user:inference"), URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state)]
        return url.url!
    }

    func request(pastedCode: String) throws -> URLRequest {
        let value = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 4096,
              parts[0].unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { throw MintTokenError.invalidCode }
        guard parts[1] == state else { throw MintTokenError.stateMismatch }
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["grant_type": "authorization_code", "code": String(parts[0]),
            "redirect_uri": Self.redirectURI, "client_id": Self.clientID, "code_verifier": verifier,
            "state": state, "expires_in": 31_536_000])
        request.timeoutInterval = 30
        return request
    }

    public func finish(pastedCode: String) async throws -> MintToken {
        try await finish(pastedCode: pastedCode, currentIdentity: MintAccountIdentity.cached,
                         transport: Self.exchange, save: MintTokenStore.save)
    }

    func finish(pastedCode: String, currentIdentity: (Profile) throws -> MintAccountIdentity,
                transport: (URLRequest) async throws -> (Data, HTTPURLResponse),
                save: (MintToken, Profile) throws -> Void, now: Date = Date()) async throws -> MintToken {
        try MintTokenStore.validateProfile(profile)
        guard try currentIdentity(profile) == expectedIdentity else { throw MintTokenError.accountChanged }
        let request = try request(pastedCode: pastedCode)
        try Task.checkCancellation()
        let data: Data; let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MintTokenError.network }
        guard response.statusCode == 200 else { throw MintTokenError.exchangeFailed }
        let token = try MintToken.parseResponse(data, now: now, expected: expectedIdentity)
        try Task.checkCancellation()
        guard try currentIdentity(profile) == expectedIdentity else { throw MintTokenError.accountChanged }
        try save(token, profile)
        return token
    }

    private static func exchange(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 35
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MintTokenError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 131_072 else { throw MintTokenError.invalidResponse }
            data.append(byte)
        }
        return (data, http)
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MintTokenError.invalidResponse }
        return base64url(Data(bytes))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum MintTokenStatus: Equatable, Sendable {
    case notConfigured
    case active(expiresAt: Date)
    case expired(expiresAt: Date)
}

public enum MintTokenStore {
    private struct Stored: Codable {
        let version: Int
        let accessToken: String
        let expiresAt: TimeInterval
        let identity: MintAccountIdentity
    }
    private static let writeLock = NSLock()

    public static func serviceName(for profile: Profile) -> String {
        "Claudock-inference-" + SHA256.hash(data: Data(CredentialStore.serviceName(for: profile).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func read(profile: Profile) throws -> MintToken? {
        try read(profile: profile, securityRead: CredentialStore.runSecurity, identity: MintAccountIdentity.cached)
    }

    public static func status(profile: Profile) throws -> MintTokenStatus {
        guard let token = try read(profile: profile) else { return .notConfigured }
        return token.expiresAt > Date() ? .active(expiresAt: token.expiresAt) : .expired(expiresAt: token.expiresAt)
    }

    static func read(profile: Profile, securityRead: (String) throws -> (data: Data, status: Int32),
                     identity: (Profile) throws -> MintAccountIdentity) throws -> MintToken? {
        try validateProfile(profile)
        let result: (data: Data, status: Int32)
        do { result = try securityRead(serviceName(for: profile)) }
        catch { throw MintTokenError.keychainUnavailable }
        if result.status == 44 { return nil }
        guard result.status == 0 else { throw MintTokenError.keychainUnavailable }
        let token = try decode(result.data)
        guard token.identity == (try identity(profile)) else { throw MintTokenError.accountMismatch }
        return token
    }

    public static func save(_ token: MintToken, profile: Profile) throws {
        try validateProfile(profile)
        guard token.identity == (try MintAccountIdentity.cached(profile: profile)) else { throw MintTokenError.accountChanged }
        let data = try encode(token)
        let service = serviceName(for: profile)
        let command = try securityWriteCommand(data, account: NSUserName(), service: service)
        try writeLock.withLock {
            try write(command)
            let result = try CredentialStore.runSecurity(service: service, timeout: 2)
            guard result.status == 0 else { throw MintTokenError.keychainWriteFailed }
            let verified = try decode(result.data)
            guard verified.accessToken == token.accessToken, verified.identity == token.identity,
                  abs(verified.expiresAt.timeIntervalSince(token.expiresAt)) < 0.001,
                  try MintAccountIdentity.cached(profile: profile) == token.identity else { throw MintTokenError.keychainWriteFailed }
        }
    }

    static func encode(_ token: MintToken) throws -> Data {
        guard OAuthRefreshResult.validToken(token.accessToken), token.expiresAt.timeIntervalSince1970.isFinite else { throw MintTokenError.invalidResponse }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Stored(version: 1, accessToken: token.accessToken,
                                         expiresAt: token.expiresAt.timeIntervalSince1970, identity: token.identity))
    }

    static func decode(_ data: Data) throws -> MintToken {
        guard data.count <= 8192 else { throw MintTokenError.invalidResponse }
        var payload = data
        if (try? JSONDecoder().decode(Stored.self, from: payload)) == nil,
           let text = String(data: data, encoding: .utf8) {
            let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hex.isEmpty, hex.count % 2 == 0, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw MintTokenError.invalidResponse
            }
            payload = Data(); var index = hex.startIndex
            while index < hex.endIndex {
                let end = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<end], radix: 16) else { throw MintTokenError.invalidResponse }
                payload.append(byte); index = end
            }
        }
        guard let saved = try? JSONDecoder().decode(Stored.self, from: payload), saved.version == 1,
              OAuthRefreshResult.validToken(saved.accessToken), saved.expiresAt.isFinite, saved.expiresAt > 0,
              let identity = try? MintAccountIdentity(accountUUID: saved.identity.accountUUID, organizationUUID: saved.identity.organizationUUID) else {
            throw MintTokenError.invalidResponse
        }
        return MintToken(accessToken: saved.accessToken, expiresAt: Date(timeIntervalSince1970: saved.expiresAt), identity: identity)
    }

    static func securityWriteCommand(_ data: Data, account: String, service: String) throws -> Data {
        guard account.range(of: #"\A[a-zA-Z0-9._-]+\z"#, options: .regularExpression) != nil,
              service.range(of: #"\AClaudock-inference-[a-f0-9]{64}\z"#, options: .regularExpression) != nil else { throw MintTokenError.keychainWriteFailed }
        let prefix = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \""
        let suffix = "\"\n"
        guard data.count <= 2016, prefix.utf8.count + data.count * 2 + suffix.utf8.count <= 4032 else { throw MintTokenError.tokenTooLarge }
        return Data((prefix + data.map { String(format: "%02x", $0) }.joined() + suffix).utf8)
    }

    private static func write(_ command: Data) throws {
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security"); process.arguments = ["-i"]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw MintTokenError.keychainWriteFailed }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        do { try process.run() } catch { throw MintTokenError.keychainWriteFailed }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: deadline)
        defer { deadline.cancel(); try? input.fileHandleForWriting.close() }
        do { try input.fileHandleForWriting.write(contentsOf: command); try input.fileHandleForWriting.close() }
        catch { if process.isRunning { process.terminate() }; process.waitUntilExit(); throw MintTokenError.keychainWriteFailed }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MintTokenError.keychainWriteFailed }
    }

    static func validateProfile(_ profile: Profile) throws {
        guard !profile.isVertex, profile.discoveryNote == nil, profile.configDirectory.hasPrefix("/"),
              !profile.configDirectory.contains("\0") else { throw MintTokenError.unsupportedProfile }
    }
}

public enum InferenceCredential {
    public static func read(profile: Profile) async throws -> Credentials {
        try await read(profile: profile, mint: MintTokenStore.read, oauth: CredentialStore.read)
    }

    static func read(profile: Profile, mint: (Profile) throws -> MintToken?,
                     oauth: (Profile) throws -> Credentials,
                     now: Date = Date()) async throws -> Credentials {
        try MintTokenStore.validateProfile(profile)
        if let mint = try mint(profile), mint.expiresAt > now {
            return Credentials(accessToken: mint.accessToken, expiresAt: mint.expiresAt, plan: nil, scopes: ["user:inference"])
        }
        let credentials = try oauth(profile)
        if let expires = credentials.expiresAt, expires <= now {
            // Auto/one-shot processes must not rotate a token pair and then
            // exit before persistence completes. The resident app owns renewal.
            throw MonitorError.expired
        }
        return credentials
    }

    /// Only the caller's environment receives the value. Never put it in argv.
    public static func environmentToken(profile: Profile) throws -> String? {
        try environmentToken(profile: profile, mint: MintTokenStore.read)
    }

    static func environmentToken(profile: Profile, mint: (Profile) throws -> MintToken?, now: Date = Date()) throws -> String? {
        try MintTokenStore.validateProfile(profile)
        guard let token = try mint(profile), token.expiresAt > now else { return nil }
        return token.accessToken
    }
}

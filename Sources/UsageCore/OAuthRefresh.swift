import Foundation
import CryptoKit

/// OAuth response material stays in memory until it is saved to the existing
/// Claude credential store. Neither tokens nor server response bodies are logged.
struct OAuthRefreshResult: Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let refreshTokenExpiresAt: Date?
    let scopes: [String]

    static func parse(_ data: Data, previous: Credentials, now: Date) throws -> OAuthRefreshResult {
        guard data.count <= 131_072,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, validToken(access),
              let duration = seconds(root["expires_in"]) else { throw MonitorError.refreshFailed }
        if let type = root["token_type"], (type as? String)?.lowercased() != "bearer" { throw MonitorError.refreshFailed }
        let refresh: String
        if let value = root["refresh_token"] {
            guard let token = value as? String, validToken(token) else { throw MonitorError.refreshFailed }
            refresh = token
        } else {
            guard let token = previous.refreshToken, validToken(token) else { throw MonitorError.refreshFailed }
            refresh = token
        }
        let scopes: [String]
        if let value = root["scope"] {
            guard let text = value as? String else { throw MonitorError.refreshFailed }
            scopes = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        } else { scopes = previous.scopes }
        let refreshExpiry: Date?
        if let value = root["refresh_token_expires_in"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= 315_360_000 else { throw MonitorError.refreshFailed }
            refreshExpiry = now.addingTimeInterval(number.doubleValue)
        } else { refreshExpiry = previous.refreshTokenExpiresAt }
        return OAuthRefreshResult(accessToken: access, refreshToken: refresh,
                                  expiresAt: now.addingTimeInterval(duration),
                                  refreshTokenExpiresAt: refreshExpiry, scopes: scopes)
    }

    private static func seconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0,
              number.doubleValue <= 315_360_000 else { return nil }
        return number.doubleValue
    }

    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16_384 && token.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }

    func merging(into data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any] else { throw MonitorError.credentialChanged }
        oauth["accessToken"] = accessToken; oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
        oauth["scopes"] = scopes
        if let refreshTokenExpiresAt { oauth["refreshTokenExpiresAt"] = refreshTokenExpiresAt.timeIntervalSince1970 * 1000 }
        root["claudeAiOauth"] = oauth
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

enum OAuthRefreshHTTP {
    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    // Public first-party OAuth client identifier, verified in Claude Code 2.1.263.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    static func request(credentials: Credentials) throws -> URLRequest {
        guard let token = credentials.refreshToken, OAuthRefreshResult.validToken(token) else { throw MonitorError.loginRequired }
        guard credentials.scopes.contains("user:profile") else { throw MonitorError.permissionDenied }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Claudock/1.5.3", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": token,
            "client_id": credentials.clientID ?? clientID, "scope": credentials.scopes.joined(separator: " ")
        ])
        return request
    }

    static func exchange(_ credentials: Credentials) async throws -> OAuthRefreshResult {
        let request = try request(credentials: credentials)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw MonitorError.network }
        guard let response = response as? HTTPURLResponse else { throw MonitorError.refreshFailed }
        return try interpret(data: data, response: response, previous: credentials, now: Date())
    }

    static func interpret(data: Data, response: HTTPURLResponse, previous: Credentials, now: Date) throws -> OAuthRefreshResult {
        if response.statusCode == 200 { return try OAuthRefreshResult.parse(data, previous: previous, now: now) }
        if response.statusCode == 429 {
            throw MonitorError.rateLimited(UsageClient.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now))
        }
        if response.statusCode == 403 { throw MonitorError.permissionDenied }
        if [400, 401].contains(response.statusCode), data.count <= 131_072,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code = root["error"] as? String ?? (root["error"] as? [String: Any])?["type"] as? String
            if code == "invalid_grant" { throw MonitorError.loginRequired }
        }
        throw MonitorError.refreshFailed
    }
}

struct RefreshDependencies: @unchecked Sendable {
    var read: (Profile) throws -> StoredCredentials = CredentialStore.readStored
    var write: (Data, StoredCredentials) throws -> Void = { try CredentialStore.writeStored($0, replacing: $1) }
    var exchange: (Credentials) async throws -> OAuthRefreshResult = OAuthRefreshHTTP.exchange
    var now: () -> Date = Date.init
}

public actor CredentialRefresher {
    public static let shared = CredentialRefresher()
    private let dependencies: RefreshDependencies
    private var flights: [String: Task<Credentials, Error>] = [:]
    private struct Failure {
        let fingerprint: String
        let until: Date
        let error: MonitorError
    }
    private struct Pending {
        let posted: Credentials
        let result: OAuthRefreshResult
    }
    private var failures: [String: Failure] = [:]
    // Preserve successful rotations in memory after a failed save. A retry saves
    // this result instead of posting the consumed refresh token a second time.
    private var pending: [String: Pending] = [:]

    init(dependencies: RefreshDependencies = RefreshDependencies()) { self.dependencies = dependencies }

    public func refresh(profile: Profile, previous: Credentials) async throws -> Credentials {
        let key = CredentialStore.serviceName(for: profile)
        if let flight = flights[key] { return try await flight.value }
        let fingerprint = Self.fingerprint(previous)
        if let failure = failures[key], failure.fingerprint == fingerprint, failure.until > dependencies.now() { throw failure.error }
        let flight = Task { try await self.perform(profile: profile, previous: previous, key: key) }
        flights[key] = flight
        do {
            let credentials = try await flight.value
            flights[key] = nil; failures[key] = nil
            return credentials
        } catch {
            flights[key] = nil
            if error is CancellationError { throw error }
            let safeError = error as? MonitorError ?? .refreshFailed
            let until: Date
            switch safeError {
            case .loginRequired: until = .distantFuture
            case .rateLimited(let date): until = date
            case .refreshBusy, .credentialChanged, .credentialWriteFailed: until = dependencies.now().addingTimeInterval(60)
            default: until = dependencies.now().addingTimeInterval(300)
            }
            failures[key] = Failure(fingerprint: fingerprint, until: until, error: safeError)
            throw safeError
        }
    }

    private static func fingerprint(_ credentials: Credentials) -> String {
        SHA256.hash(data: Data((credentials.accessToken + "\0" + (credentials.refreshToken ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func clearAttempt(profile: Profile, credentials: Credentials) throws {
        let fingerprint = Self.fingerprint(credentials)
        if try RefreshAttemptStore.read(profile: profile) == fingerprint {
            try RefreshAttemptStore.clear(profile: profile, fingerprint: fingerprint)
        }
    }

    private func perform(profile: Profile, previous: Credentials, key: String) async throws -> Credentials {
        guard profile.discoveryNote == nil, !profile.isVertex, profile.configDirectory.hasPrefix("/"),
              !profile.configDirectory.contains("\0") else { throw MonitorError.noCredentials }
        let base = profile.configDirectory.precomposedStringWithCanonicalMapping
        let canonical = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        let refreshLock = try await ClaudeCredentialLock.acquire(paths: [
            URL(fileURLWithPath: base).appendingPathComponent(".oauth_refresh.lock").path, canonical + ".lock"
        ], timeout: 6)
        defer { refreshLock.release() }
        try refreshLock.assertOwned()
        var stored = try dependencies.read(profile)
        var current = try stored.credentials
        if !current.hasSameTokens(as: previous) {
            pending[key] = nil
            try clearAttempt(profile: profile, credentials: previous)
            return current
        }
        let fingerprint = Self.fingerprint(current)
        if let recorded = try RefreshAttemptStore.read(profile: profile), recorded != fingerprint {
            try RefreshAttemptStore.clear(profile: profile, fingerprint: recorded)
        }
        let writePath = URL(fileURLWithPath: base).appendingPathComponent(".storage-write.lock").path
        if let saved = pending[key] {
            guard current.hasSameTokens(as: saved.posted) else {
                pending[key] = nil
                try clearAttempt(profile: profile, credentials: saved.posted)
                return current
            }
        } else {
            guard try RefreshAttemptStore.read(profile: profile) == nil else { throw MonitorError.refreshUncertain }
            guard current.refreshToken != nil else { throw MonitorError.loginRequired }
            if let expiry = current.refreshTokenExpiresAt, expiry <= dependencies.now() { throw MonitorError.loginRequired }
            _ = try OAuthRefreshHTTP.request(credentials: current)
            // Check write permission before rotating. This short transaction writes
            // identical content and never holds the storage lock across HTTP.
            let lock = try await ClaudeCredentialLock.acquire(paths: [writePath], timeout: 3, staleAfter: 15)
            do {
                defer { lock.release() }
                try lock.assertOwned(); try refreshLock.assertOwned()
                stored = try dependencies.read(profile)
                current = try stored.credentials
                guard current.hasSameTokens(as: previous) else { return current }
                try dependencies.write(stored.data, stored)
                stored = try dependencies.read(profile)
                current = try stored.credentials
                guard current.hasSameTokens(as: previous) else { return current }
            }
            try refreshLock.assertOwned()
            // A durable, secret-free intent prevents a restarted process from
            // reusing a refresh token whose POST may already have committed.
            try RefreshAttemptStore.begin(profile: profile, fingerprint: Self.fingerprint(current))
            let result: OAuthRefreshResult
            do { result = try await dependencies.exchange(current) }
            catch {
                if let replacement = try? dependencies.read(profile),
                   let credentials = try? replacement.credentials, !credentials.hasSameTokens(as: current) {
                    try clearAttempt(profile: profile, credentials: current)
                    return credentials
                }
                if let failure = error as? MonitorError {
                    switch failure {
                    case .loginRequired, .permissionDenied, .rateLimited:
                        try clearAttempt(profile: profile, credentials: current)
                        throw failure
                    default: break
                    }
                }
                // No blind retry after a lost/malformed response or cancellation
                // once dispatch started. Claude can refresh/re-login explicitly.
                throw MonitorError.refreshUncertain
            }
            // Set this before any fallible ownership or persistence check.
            pending[key] = Pending(posted: current, result: result)
        }
        guard let renewal = pending[key] else { throw MonitorError.refreshFailed }
        try refreshLock.assertOwned()
        let lock = try await ClaudeCredentialLock.acquire(paths: [writePath], timeout: 3, staleAfter: 15)
        defer { lock.release() }
        try lock.assertOwned(); try refreshLock.assertOwned()
        let latest = try dependencies.read(profile)
        let latestCredentials = try latest.credentials
        guard latestCredentials.hasSameTokens(as: renewal.posted) else {
            pending[key] = nil
            try clearAttempt(profile: profile, credentials: renewal.posted)
            return latestCredentials
        }
        let data = try renewal.result.merging(into: latest.data)
        try dependencies.write(data, latest)
        try lock.assertOwned()
        let readback = try dependencies.read(profile)
        let verified = try readback.credentials
        guard verified.accessToken == renewal.result.accessToken, verified.refreshToken == renewal.result.refreshToken else {
            if verified.hasSameTokens(as: renewal.posted) { throw MonitorError.credentialWriteFailed }
            pending[key] = nil
            try clearAttempt(profile: profile, credentials: renewal.posted)
            throw MonitorError.credentialChanged
        }
        pending[key] = nil
        try clearAttempt(profile: profile, credentials: renewal.posted)
        return verified
    }
}

import CoreFoundation

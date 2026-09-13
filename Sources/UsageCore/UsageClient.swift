import Foundation

final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum UsageClient {
    /// Renew at most once for an expired token or a quota HTTP 401. Other errors
    /// do not rotate credentials. CredentialRefresher also coordinates processes.
    public static func fetch(profile: Profile, credentials: Credentials) async throws -> UsageSnapshot {
        try await fetchRenewing(credentials: credentials, request: { try await fetch(credentials: $0) },
                                renew: { try await CredentialRefresher.shared.refresh(profile: profile, previous: $0) })
    }

    static func fetchRenewing(credentials: Credentials,
                              request: (Credentials) async throws -> UsageSnapshot,
                              renew: (Credentials) async throws -> Credentials) async throws -> UsageSnapshot {
        do { return try await request(credentials) }
        catch let error as MonitorError where error == .expired || error == .unauthorized {
            let renewed = try await renew(credentials)
            return try await request(renewed)
        }
    }
    public static func fetch(credentials: Credentials) async throws -> UsageSnapshot {
        if let expiry = credentials.expiresAt, expiry <= Date() { throw MonitorError.expired }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Claudock/1.5.1", forHTTPHeaderField: "User-Agent")
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw MonitorError.network }
        guard let http = response as? HTTPURLResponse else { throw MonitorError.invalidResponse }
        switch http.statusCode {
        case 200: return try UsageSnapshot.parse(data)
        case 401: throw MonitorError.unauthorized
        case 403: throw MonitorError.permissionDenied
        case 429:
            throw MonitorError.rateLimited(retryDate(http.value(forHTTPHeaderField: "Retry-After")))
        default: throw MonitorError.server(http.statusCode)
        }
    }

    static func retryDate(_ header: String?, now: Date = Date()) -> Date {
        var seconds: TimeInterval = 300
        if let header, let duration = Double(header), duration.isFinite {
            seconds = duration
        } else if let header {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: header) { seconds = date.timeIntervalSince(now) }
        }
        return now.addingTimeInterval(min(86_400, max(300, seconds)))
    }
}

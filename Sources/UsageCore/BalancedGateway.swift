import Foundation

struct GatewayUpstreamResponse: @unchecked Sendable {
    let status: Int
    let headers: [String: String]
    let forward: (@escaping @Sendable (Data) async throws -> Void) async throws -> Void
    let cancel: @Sendable () -> Void
}

struct GatewayDependencies: @unchecked Sendable {
    var profiles: () throws -> [Profile] = { try ProfileStore.load() }
    var usage: (Profile) async throws -> UsageSnapshot = { profile in
        try await UsageClient.fetch(credentials: CredentialStore.read(profile: profile))
    }
    var credential: (Profile) async throws -> Credentials = { profile in
        try await InferenceCredential.read(profile: profile)
    }
    var request: (LocalHTTPRequest, Credentials) async throws -> GatewayUpstreamResponse = GatewayUpstream.send
}

/// The gateway lives beside a single Claude child process. It never changes the
/// user's global endpoint, launches another Terminal, or replays partial answers.
public actor BalancedGateway {
    private let pool: AccountPool
    private let dependencies: GatewayDependencies
    private let selectors: Set<String>?
    private var refreshedAt = Date.distantPast
    private var refreshing: Task<Void, Error>?
    private var profiles: [Profile] = []
    private var usedProfiles: Set<String> = []
    public private(set) var requestCount = 0
    public private(set) var failoverCount = 0

    public init(selectors: Set<String>? = nil) { self.dependencies = GatewayDependencies(); self.selectors = selectors; pool = AccountPool() }
    init(dependencies: GatewayDependencies) { self.dependencies = dependencies; selectors = nil; pool = AccountPool(randomUnit: { 0 }) }

    public func prepare() async throws {
        if let refreshing { return try await refreshing.value }
        guard Date().timeIntervalSince(refreshedAt) >= 300 else { return }
        let dependencies = self.dependencies, selectors = self.selectors, pool = self.pool
        let task = Task {
            let loaded = try dependencies.profiles().filter {
                !$0.isVertex && $0.discoveryNote == nil && !$0.configDirectory.isEmpty &&
                    (selectors == nil || selectors!.contains($0.command))
            }
            guard !loaded.isEmpty else { throw MonitorError.unsupported("No subscription profiles are available for Auto. Add a profile in Claudock first.") }
            // Multiple wrappers can reference the same Keychain account. Never
            // count them twice or retry the same credential under another slug.
            var services = Set<String>()
            let unique = loaded.filter { services.insert(CredentialStore.serviceName(for: $0)).inserted }
            var usage: [String: UsageSnapshot] = [:]
            await withTaskGroup(of: (String, UsageSnapshot?).self) { group in
                var iterator = unique.makeIterator()
                for _ in 0..<3 {
                    if let profile = iterator.next() { group.addTask { (profile.id, try? await dependencies.usage(profile)) } }
                }
                for await (id, snapshot) in group {
                    usage[id] = snapshot
                    if let profile = iterator.next() { group.addTask { (profile.id, try? await dependencies.usage(profile)) } }
                }
            }
            await pool.update(profiles: unique, usage: usage)
            self.profiles = unique
            self.refreshedAt = Date()
        }
        refreshing = task
        do { try await task.value; refreshing = nil }
        catch { refreshing = nil; throw error }
    }

    public func handle(_ request: LocalHTTPRequest, writer: LocalHTTPResponseWriter) async {
        var committed = false
        do {
            try Task.checkCancellation()
            try await prepare()
            let details = try BalancedRequest.details(request)
            let supplied = request.headers["x-claude-code-session-id"] ?? "session"
            let conversation = supplied.utf8.count <= 256 ? supplied : "session"
            var excluded = Set<String>()
            let attempts = min(3, profiles.count)
            for attempt in 0..<attempts {
                try Task.checkCancellation()
                guard let profile = await pool.select(model: details.model, conversation: conversation,
                                                     excluding: excluded, hasRemoteState: details.remoteState) else { break }
                excluded.insert(profile.id)
                do {
                    let credentials = try await dependencies.credential(profile)
                    try Task.checkCancellation()
                    let response = try await dependencies.request(request, credentials)
                    // A status rejection precedes response/tool output and is
                    // safe to try elsewhere. Network errors and 5xx may follow
                    // execution upstream, so they are not blindly replayed.
                    if let until = BalancedRequest.cooldown(status: response.status, headers: response.headers) {
                        await pool.block(profile, until: until)
                        if attempt + 1 < attempts && !details.remoteState {
                            response.cancel()
                            await pool.release(profile)
                            failoverCount += 1
                            continue
                        }
                    }
                    requestCount += 1; usedProfiles.insert(profile.id)
                    let pool = self.pool
                    let gate = GatewayStreamGate(writer: writer, status: response.status, headers: response.headers) { status in
                        await pool.block(profile, until: BalancedRequest.cooldown(status: status, headers: response.headers) ?? Date().addingTimeInterval(60))
                    }
                    do {
                        try await response.forward { chunk in try await gate.write(chunk) }
                        try await gate.finish()
                        committed = await gate.committed
                    } catch let rejection as StreamRejection {
                        response.cancel()
                        await pool.block(profile, until: BalancedRequest.cooldown(status: rejection.status, headers: response.headers) ?? Date().addingTimeInterval(60))
                        if attempt + 1 < attempts { await pool.release(profile); failoverCount += 1; continue }
                        try await sendError(writer, status: 429, message: "The available profiles rejected this request before output. Check quota or renew authentication in Claudock.")
                        await pool.release(profile)
                        return
                    } catch {
                        committed = await gate.committed
                        response.cancel()
                        throw error
                    }
                    response.cancel()
                    await pool.release(profile)
                    return
                } catch {
                    await pool.release(profile)
                    if error is CancellationError || committed { throw error }
                    // Only local credential failures permit another account. A
                    // dispatched request can have side effects even if no bytes
                    // returned; the transport wraps that as .network.
                    if error is MintTokenError || (error as? MonitorError).map({ $0 != .network }) == true {
                        await pool.block(profile, until: Date().addingTimeInterval(300))
                        continue
                    }
                    throw error
                }
            }
            try await sendError(writer, status: 429, message: details.remoteState
                ? "This conversation contains account-owned files or server state. Continue it with its original profile."
                : "No eligible Claudock profile has available capacity. Check account usage or renew its token in Claudock.")
        } catch {
            if committed || Task.isCancelled { await writer.abort(); return }
            try? await sendError(writer, status: 502, message: "Claudock could not complete this request. Check connectivity and profile authentication; no partial answer was replayed.")
        }
    }

    private func sendError(_ writer: LocalHTTPResponseWriter, status: Int, message: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": status == 429 ? "rate_limit_error" : "api_error", "message": message]])
        try await writer.writeHead(status: status, headers: ["content-type": "application/json", "retry-after": "60"])
        try await writer.write(body); try await writer.finish()
    }
}

enum GatewayUpstream {
    static func makeRequest(_ incoming: LocalHTTPRequest, credentials: Credentials) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com" + incoming.target),
              url.host == "api.anthropic.com", url.scheme == "https" else { throw MonitorError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = incoming.method
        request.httpBody = incoming.method == "POST" ? incoming.body : nil
        // Keep evolving Claude capability headers; drop client credentials,
        // cookies, proxy headers, and transport-specific framing.
        for (key, value) in incoming.headers where key.hasPrefix("anthropic-") || key.hasPrefix("x-claude-code-") || ["content-type", "accept", "user-agent", "x-app"].contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        var betas = (incoming.headers["anthropic-beta"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !betas.contains("oauth-2025-04-20") { betas.append("oauth-2025-04-20") }
        request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        request.setValue(incoming.headers["anthropic-version"] ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    static func send(_ incoming: LocalHTTPRequest, credentials: Credentials) async throws -> GatewayUpstreamResponse {
        let request = try makeRequest(incoming, credentials: credentials)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300; config.timeoutIntervalForResource = 7200
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        do {
            let (bytes, raw) = try await session.bytes(for: request)
            guard let response = raw as? HTTPURLResponse else { throw MonitorError.network }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                guard let key = key as? String, let value = value as? String else { continue }
                let name = key.lowercased()
                if name == "content-type" || name == "retry-after" || name == "request-id" || name.hasPrefix("anthropic-") { headers[name] = value }
            }
            return GatewayUpstreamResponse(status: response.statusCode, headers: headers, forward: { write in
                var chunk = Data(); chunk.reserveCapacity(8192)
                // Flush newlines immediately so SSE pings and tiny token deltas
                // reach Claude without waiting for a full buffer.
                for try await byte in bytes {
                    try Task.checkCancellation()
                    chunk.append(byte)
                    if byte == 10 || chunk.count >= 8192 { try await write(chunk); chunk.removeAll(keepingCapacity: true) }
                }
                if !chunk.isEmpty { try await write(chunk) }
            }, cancel: { session.invalidateAndCancel() })
        } catch {
            session.invalidateAndCancel()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw MonitorError.network
        }
    }
}

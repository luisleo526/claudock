import Foundation

struct ConnectorCredentialSnapshot: Sendable {
    let credentials: Credentials
    let identity: MintAccountIdentity
}

enum ConnectorCredentialReadError: Error, Sendable {
    case missingCredentials, identityChanged, unavailable
}

struct ConnectorSessionDependencies: Sendable {
    private static let monotonicOrigin = ContinuousClock.now
    var read: @Sendable () async throws -> ConnectorCredentialSnapshot
    var now: @Sendable () -> Date = { Date() }
    var monotonicNow: @Sendable () -> TimeInterval = {
        // ContinuousClock includes system sleep, so sleeping the Mac cannot
        // extend a previous-bearer's five-second grace interval.
        let elapsed = monotonicOrigin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
    }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
}

/// Pins connector authorization to the normal default Claude login while model
/// traffic uses the local gateway. Credentials remain private to this actor.
/// This observes local logout/rotation/expiry; it does not probe server revocation.
public actor ConnectorSession {
    private struct Flight {
        let id: UUID
        let task: Task<ReadResult, Never>
    }
    private enum ReadResult: Sendable {
        case success(ConnectorCredentialSnapshot, started: TimeInterval, finished: TimeInterval)
        case failure(ConnectorCredentialReadError, started: TimeInterval)
    }
    private struct PreviousBearer {
        let token: String
        let originalExpiry: Date
        let deadline: TimeInterval
    }

    private let pinnedIdentity: MintAccountIdentity
    private let dependencies: ConnectorSessionDependencies
    private let readInterval: TimeInterval
    private var cached: ConnectorCredentialSnapshot?
    private var cachedAt: TimeInterval
    private var nextReadAt: TimeInterval
    private var invalidated = false
    private var flight: Flight?
    private var previous: PreviousBearer?

    private init(snapshot: ConnectorCredentialSnapshot, dependencies: ConnectorSessionDependencies,
                 readInterval: TimeInterval) {
        pinnedIdentity = snapshot.identity
        self.dependencies = dependencies
        self.readInterval = readInterval
        cached = snapshot
        cachedAt = dependencies.monotonicNow()
        // The first unknown bearer can check for a rotation immediately.
        // Subsequent reads are globally coalesced and spaced by readInterval.
        nextReadAt = cachedAt
    }

    public static func defaultSession() async -> ConnectorSession? {
        let profile = Profile(command: "claude", configDirectory: NSHomeDirectory() + "/.claude")
        let dependencies = ConnectorSessionDependencies(read: {
            try await Task.detached(priority: .utility) {
                // Still inspect the credential if cached metadata is unavailable:
                // a logout that clears both stores must be recognized as missing,
                // rather than kept indefinitely as a transient metadata failure.
                let before = try? MintAccountIdentity.cached(profile: profile)
                let credentials: Credentials
                do {
                    let stored = try CredentialStore.readStored(profile: profile, securityRead: {
                        try CredentialStore.runSecurity(service: $0, timeout: 2)
                    })
                    credentials = try stored.credentials
                } catch MonitorError.noCredentials { throw ConnectorCredentialReadError.missingCredentials }
                catch { throw ConnectorCredentialReadError.unavailable }
                guard let before else { throw ConnectorCredentialReadError.unavailable }
                let after: MintAccountIdentity
                do { after = try MintAccountIdentity.cached(profile: profile) }
                catch { throw ConnectorCredentialReadError.unavailable }
                guard before == after else { throw ConnectorCredentialReadError.identityChanged }
                return ConnectorCredentialSnapshot(credentials: credentials, identity: after)
            }.value
        })
        return await start(dependencies: dependencies)
    }

    static func start(dependencies: ConnectorSessionDependencies,
                      readInterval: TimeInterval = 1) async -> ConnectorSession? {
        guard readInterval.isFinite, readInterval > 0 else { return nil }
        do {
            let snapshot = try await dependencies.read()
            guard !Task.isCancelled, eligible(snapshot.credentials, now: dependencies.now()) else { return nil }
            return ConnectorSession(snapshot: snapshot, dependencies: dependencies, readInterval: readInterval)
        } catch { return nil }
    }

    /// The transport supplies the bearer value without the "Bearer " prefix.
    /// An unknown bearer awaits the next allowed forced read, then compares with
    /// that refreshed snapshot; a valid rotated token is not negatively cached.
    /// An authoritative same-identity rotation permits only its immediately prior
    /// eligible bearer for up to five seconds, never beyond its original expiry.
    public func authorize(_ bearer: String) async -> Bool {
        guard !Task.isCancelled, !invalidated, Self.validBearer(bearer) else { return false }
        let age = dependencies.monotonicNow() - cachedAt
        if age >= 0, age < readInterval, let cached,
           Self.eligible(cached.credentials, now: dependencies.now()),
           matchesCurrentOrPrevious(bearer, current: cached.credentials.accessToken) { return true }

        await refresh()
        let refreshedAge = dependencies.monotonicNow() - cachedAt
        guard !Task.isCancelled, !invalidated, let cached,
              refreshedAge >= 0, refreshedAge < readInterval,
              Self.eligible(cached.credentials, now: dependencies.now()) else { return false }
        return matchesCurrentOrPrevious(bearer, current: cached.credentials.accessToken)
    }

    private func refresh() async {
        guard !invalidated else { return }
        let current: Flight
        if let flight { current = flight }
        else {
            let dependencies = dependencies
            let wait = max(0, nextReadAt - dependencies.monotonicNow())
            let task = Task<ReadResult, Never> {
                do { try await dependencies.sleep(wait) }
                catch { return .failure(.unavailable, started: dependencies.monotonicNow()) }
                let started = dependencies.monotonicNow()
                do {
                    let snapshot = try await dependencies.read()
                    return .success(snapshot, started: started, finished: dependencies.monotonicNow())
                } catch let failure as ConnectorCredentialReadError {
                    return .failure(failure, started: started)
                } catch MonitorError.noCredentials {
                    return .failure(.missingCredentials, started: started)
                } catch {
                    return .failure(.unavailable, started: started)
                }
            }
            current = Flight(id: UUID(), task: task)
            flight = current
        }
        let result = await current.task.value
        // Every waiter uses actor state after the one winning completion. A late
        // waiter must not reinstall an older snapshot over a newer read or logout.
        guard flight?.id == current.id else { return }
        flight = nil
        switch result {
        case .success(let snapshot, let started, let finished):
            nextReadAt = started + readInterval
            guard snapshot.identity == pinnedIdentity else {
                invalidate()
                return
            }
            cachedAt = finished
            guard Self.eligible(snapshot.credentials, now: dependencies.now()) else {
                cached = nil
                previous = nil
                return
            }
            if let cached, !Self.constantTimeEqual(cached.credentials.accessToken, snapshot.credentials.accessToken) {
                // Only the immediately replaced, still-eligible stored token gets
                // grace. A later rotation replaces the slot; a same-token reread
                // does not extend its deadline.
                if Self.eligible(cached.credentials, now: dependencies.now()), let expiry = cached.credentials.expiresAt {
                    previous = PreviousBearer(token: cached.credentials.accessToken,
                                              originalExpiry: expiry, deadline: finished + 5)
                } else { previous = nil }
            }
            cached = snapshot
        case .failure(let error, let started):
            nextReadAt = started + readInterval
            cached = nil
            previous = nil
            switch error {
            case .missingCredentials, .identityChanged: invalidate()
            case .unavailable: break
            }
        }
    }

    private func invalidate() {
        invalidated = true
        cached = nil
        previous = nil
    }

    private func matchesCurrentOrPrevious(_ bearer: String, current: String) -> Bool {
        if let previous, dependencies.monotonicNow() >= previous.deadline || dependencies.now() >= previous.originalExpiry {
            self.previous = nil
        }
        let currentMatch = Self.constantTimeEqual(bearer, current)
        let previousMatch = previous.map { Self.constantTimeEqual(bearer, $0.token) } ?? false
        return currentMatch || previousMatch
    }

    private static func eligible(_ credentials: Credentials, now: Date) -> Bool {
        guard validBearer(credentials.accessToken), let expiry = credentials.expiresAt,
              expiry > now else { return false }
        let scopes = Set(credentials.scopes)
        return scopes.contains("user:inference") && scopes.contains("user:mcp_servers")
    }

    private static func validBearer(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }

    private static func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        let first = Array(first.utf8), second = Array(second.utf8)
        var difference = first.count ^ second.count
        for index in 0..<max(first.count, second.count) {
            let left = index < first.count ? first[index] : 0
            let right = index < second.count ? second[index] : 0
            difference |= Int(left ^ right)
        }
        return difference == 0
    }
}

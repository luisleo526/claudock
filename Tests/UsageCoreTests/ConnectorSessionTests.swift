import Foundation
import XCTest
@testable import UsageCore

private final class ConnectorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var wallOffset: TimeInterval = 0
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)
    var monotonic: TimeInterval { lock.withLock { time } }
    var now: Date { lock.withLock { origin.addingTimeInterval(time + wallOffset) } }
    func advance(_ amount: TimeInterval) { lock.withLock { time += amount } }
    func adjustWall(_ amount: TimeInterval) { lock.withLock { wallOffset += amount } }
}

private actor ConnectorTestGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() { opened = true; waiting.forEach { $0.resume() }; waiting.removeAll() }
}

private actor ConnectorTestSource {
    var result: Result<ConnectorCredentialSnapshot, ConnectorCredentialReadError>
    private(set) var calls = 0
    private(set) var starts: [TimeInterval] = []
    var gate: ConnectorTestGate?
    let clock: ConnectorTestClock
    init(_ snapshot: ConnectorCredentialSnapshot, clock: ConnectorTestClock) { result = .success(snapshot); self.clock = clock }
    func set(_ result: Result<ConnectorCredentialSnapshot, ConnectorCredentialReadError>) { self.result = result }
    func suspend(_ gate: ConnectorTestGate) { self.gate = gate }
    func read() async throws -> ConnectorCredentialSnapshot {
        calls += 1; starts.append(clock.monotonic)
        if let gate { await gate.wait() }
        return try result.get()
    }
}

final class ConnectorSessionTests: XCTestCase {
    private func identity(account: String = "11111111-1111-4111-8111-111111111111",
                          organization: String = "22222222-2222-4222-8222-222222222222") -> MintAccountIdentity {
        try! MintAccountIdentity(accountUUID: account, organizationUUID: organization)
    }

    private func snapshot(_ clock: ConnectorTestClock, token: String = "fixture-original-oauth",
                          identity: MintAccountIdentity? = nil, expiry: TimeInterval? = 3600,
                          scopes: [String] = ["user:profile", "user:inference", "user:mcp_servers"]) -> ConnectorCredentialSnapshot {
        ConnectorCredentialSnapshot(credentials: Credentials(accessToken: token, expiresAt: expiry.map { clock.now.addingTimeInterval($0) },
                                                              plan: "max", scopes: scopes),
                                    identity: identity ?? self.identity())
    }

    private func dependencies(_ source: ConnectorTestSource, _ clock: ConnectorTestClock) -> ConnectorSessionDependencies {
        ConnectorSessionDependencies(read: { try await source.read() }, now: { clock.now },
                                     monotonicNow: { clock.monotonic }, sleep: { interval in
                                         clock.advance(interval)
                                         await Task.yield()
                                     })
    }

    private func makeSession(_ source: ConnectorTestSource, _ clock: ConnectorTestClock) async throws -> ConnectorSession {
        let session = await ConnectorSession.start(dependencies: dependencies(source, clock))
        return try XCTUnwrap(session)
    }

    private func assertAuthorized(_ session: ConnectorSession, _ bearer: String, _ expected: Bool,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        let result = await session.authorize(bearer)
        XCTAssertEqual(result, expected, file: file, line: line)
    }

    func testInitialSessionRequiresKnownUnexpiredFullConnectorCapability() async throws {
        let clock = ConnectorTestClock()
        for value in [snapshot(clock, expiry: nil), snapshot(clock, expiry: 0), snapshot(clock, expiry: -1),
                      snapshot(clock, scopes: ["user:inference"]), snapshot(clock, scopes: ["user:mcp_servers"]),
                      snapshot(clock, token: ""), snapshot(clock, token: "invalid token")] {
            let source = ConnectorTestSource(value, clock: clock)
            let session = await ConnectorSession.start(dependencies: dependencies(source, clock))
            XCTAssertNil(session)
        }
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = await ConnectorSession.start(dependencies: dependencies(source, clock))
        XCTAssertNotNil(session)
    }

    func testInitialReadFailureFallsBackWithoutRenewalOrOtherReads() async {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        for failure in [ConnectorCredentialReadError.missingCredentials, .unavailable, .identityChanged] {
            await source.set(.failure(failure))
            let session = await ConnectorSession.start(dependencies: dependencies(source, clock))
            XCTAssertNil(session)
        }
        let count = await source.calls
        XCTAssertEqual(count, 3)
    }

    func testKnownTokenUsesOneSecondCacheThenRevalidates() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        for _ in 0..<20 { await assertAuthorized(session, "fixture-original-oauth", true) }
        var count = await source.calls
        XCTAssertEqual(count, 1)
        clock.advance(1.01)
        await assertAuthorized(session, "fixture-original-oauth", true)
        count = await source.calls
        XCTAssertEqual(count, 2)
    }

    func testCurrentRotationAcceptedAndPriorTokenHasBoundedGrace() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
        await assertAuthorized(session, "fixture-rotated-oauth", true)
        await assertAuthorized(session, "fixture-original-oauth", true)
        clock.advance(5)
        await assertAuthorized(session, "fixture-original-oauth", false)
        await assertAuthorized(session, "fixture-rotated-oauth", true)
    }

    func testSameTokenRereadsDoNotExtendPreviousBearerGrace() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
        await assertAuthorized(session, "fixture-rotated-oauth", true)
        for _ in 0..<4 {
            clock.advance(1)
            await assertAuthorized(session, "fixture-rotated-oauth", true)
            await assertAuthorized(session, "fixture-original-oauth", true)
        }
        clock.advance(1)
        await assertAuthorized(session, "fixture-original-oauth", false)
    }

    func testPreviousBearerNeverOutlivesItsOriginalExpiry() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock, expiry: 2), clock: clock)
        let session = try await makeSession(source, clock)
        clock.advance(0.5)
        await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
        await assertAuthorized(session, "fixture-rotated-oauth", true)
        clock.advance(1)
        await assertAuthorized(session, "fixture-original-oauth", true)
        clock.advance(0.5)
        await assertAuthorized(session, "fixture-original-oauth", false)
    }

    func testGraceUsesMonotonicDeadlineWhenWallClockMovesBackward() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
        await assertAuthorized(session, "fixture-rotated-oauth", true)
        clock.advance(5)
        clock.adjustWall(-100)
        await assertAuthorized(session, "fixture-original-oauth", false)
        await assertAuthorized(session, "fixture-rotated-oauth", true)
    }

    func testSecondRotationReplacesGraceAndRejectsGrandparentAndUnknownTokens() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        await source.set(.success(snapshot(clock, token: "fixture-second")))
        await assertAuthorized(session, "fixture-second", true)
        clock.advance(1)
        await source.set(.success(snapshot(clock, token: "fixture-third")))
        await assertAuthorized(session, "fixture-third", true)
        await assertAuthorized(session, "fixture-second", true)
        await assertAuthorized(session, "fixture-original-oauth", false)
        await assertAuthorized(session, "fixture-never-observed", false)
    }

    func testReadFailuresClearGraceAndRecoveryCannotRestoreOldSlot() async throws {
        for failure in [ConnectorCredentialReadError.unavailable, .missingCredentials, .identityChanged] {
            let clock = ConnectorTestClock()
            let source = ConnectorTestSource(snapshot(clock), clock: clock)
            let session = try await makeSession(source, clock)
            await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
            await assertAuthorized(session, "fixture-rotated-oauth", true)
            await assertAuthorized(session, "fixture-original-oauth", true)
            clock.advance(1)
            await source.set(.failure(failure))
            await assertAuthorized(session, "fixture-original-oauth", false)
            await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
            await assertAuthorized(session, "fixture-rotated-oauth", failure == .unavailable)
            await assertAuthorized(session, "fixture-original-oauth", false)
        }
    }

    func testScopeLossOrAccountChangeClearsPreviousBearerGrace() async throws {
        for accountChange in [false, true] {
            let clock = ConnectorTestClock()
            let source = ConnectorTestSource(snapshot(clock), clock: clock)
            let session = try await makeSession(source, clock)
            await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
            await assertAuthorized(session, "fixture-rotated-oauth", true)
            await assertAuthorized(session, "fixture-original-oauth", true)
            clock.advance(1)
            let changed = accountChange
                ? snapshot(clock, token: "fixture-foreign", identity: identity(account: "33333333-3333-4333-8333-333333333333"))
                : snapshot(clock, token: "fixture-rotated-oauth", scopes: ["user:inference"])
            await source.set(.success(changed))
            await assertAuthorized(session, "fixture-original-oauth", false)
            await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
            await assertAuthorized(session, "fixture-rotated-oauth", !accountChange)
            await assertAuthorized(session, "fixture-original-oauth", false)
        }
    }

    func testUnknownBearerStormStaysReadBoundedAndAcceptsRefreshedRotation() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        let gate = ConnectorTestGate()
        await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
        await source.suspend(gate)
        let requests = (0..<32).map { index in Task { await session.authorize(index == 31 ? "fixture-rotated-oauth" : "fixture-unknown-\(index)") } }
        for _ in 0..<1000 {
            if await source.calls >= 2 { break }
            await Task.yield()
        }
        let during = await source.calls
        XCTAssertEqual(during, 2)
        await gate.open()
        for (index, request) in requests.enumerated() {
            let allowed = await request.value
            XCTAssertEqual(allowed, index == 31)
        }
        let completed = await source.calls
        // Late-scheduled callers may request the next allowed refresh. The fake
        // clock advances that wait instantly, so assert the rate bound instead
        // of assuming every Swift task reached the actor before opening the gate.
        XCTAssertLessThanOrEqual(completed, Int(clock.monotonic) + 2)
        let starts = await source.starts
        for index in 2..<starts.count { XCTAssertGreaterThanOrEqual(starts[index] - starts[index - 1], 1) }
    }

    func testRepeatedUnknownTokensCannotStartReadsMoreThanOncePerSecond() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        for _ in 0..<5 { await assertAuthorized(session, "fixture-unknown", false) }
        let starts = await source.starts
        XCTAssertEqual(starts.count, 6)
        for index in 2..<starts.count { XCTAssertGreaterThanOrEqual(starts[index] - starts[index - 1], 1) }
    }

    func testObservedLogoutPermanentlyInvalidatesUntilRestart() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        await source.set(.failure(.missingCredentials))
        clock.advance(1.01)
        await assertAuthorized(session, "fixture-original-oauth", false)
        await source.set(.success(snapshot(clock, token: "fixture-new-login")))
        clock.advance(5)
        await assertAuthorized(session, "fixture-new-login", false)
        let count = await source.calls
        XCTAssertEqual(count, 2)
    }

    func testChangedAccountOrOrganizationPermanentlyInvalidates() async throws {
        for changed in [identity(account: "33333333-3333-4333-8333-333333333333"),
                        identity(organization: "44444444-4444-4444-8444-444444444444")] {
            let clock = ConnectorTestClock()
            let original = snapshot(clock)
            let source = ConnectorTestSource(original, clock: clock)
            let session = try await makeSession(source, clock)
            await source.set(.success(snapshot(clock, token: "fixture-other-account", identity: changed)))
            await assertAuthorized(session, "fixture-other-account", false)
            await source.set(.success(original))
            clock.advance(5)
            await assertAuthorized(session, "fixture-original-oauth", false)
            let count = await source.calls
            XCTAssertEqual(count, 2)
        }
    }

    func testTransientReadFailureDoesNotKeepLastGoodAndCanRecoverSameIdentity() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        await source.set(.failure(.unavailable))
        clock.advance(1.01)
        await assertAuthorized(session, "fixture-original-oauth", false)
        await source.set(.success(snapshot(clock, token: "fixture-rotated-oauth")))
        await assertAuthorized(session, "fixture-rotated-oauth", true)
        await assertAuthorized(session, "fixture-original-oauth", false)
    }

    func testExpiryAndRemovedScopeRefuseStoredToken() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock, expiry: 0.5), clock: clock)
        let session = try await makeSession(source, clock)
        clock.advance(0.6)
        await assertAuthorized(session, "fixture-original-oauth", false)
        await source.set(.success(snapshot(clock, scopes: ["user:inference"])))
        await assertAuthorized(session, "fixture-original-oauth", false)
    }

    func testMalformedBearerIsRefusedWithoutStorageRead() async throws {
        let clock = ConnectorTestClock()
        let source = ConnectorTestSource(snapshot(clock), clock: clock)
        let session = try await makeSession(source, clock)
        for value in ["", "Bearer fixture-original-oauth", "fixture\nvalue", String(repeating: "x", count: 16_385)] {
            await assertAuthorized(session, value, false)
        }
        let count = await source.calls
        XCTAssertEqual(count, 1)
    }
}

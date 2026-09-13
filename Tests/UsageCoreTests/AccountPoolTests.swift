import XCTest
@testable import UsageCore

final class AccountPoolTests: XCTestCase {
    private let a = Profile(command: "claude-a", configDirectory: "/tmp/a", registryID: "a")
    private let b = Profile(command: "claude-b", configDirectory: "/tmp/b", registryID: "b")

    func testModelLimitsAndResets() {
        let now = Date()
        let usage = UsageSnapshot(windows: [
            UsageWindow(id: "five_hour", title: "5-hour session", percent: 20, resetsAt: now.addingTimeInterval(60)),
            UsageWindow(id: "seven_day_fable", title: "Weekly · Fable", percent: 100, resetsAt: now.addingTimeInterval(60)),
            UsageWindow(id: "seven_day_sonnet", title: "Weekly · Sonnet", percent: 90, resetsAt: now.addingTimeInterval(-10))
        ], fetchedAt: now)
        XCTAssertEqual(AccountPool.headroom(usage, model: "claude-fable-5", now: now), 0)
        XCTAssertEqual(AccountPool.headroom(usage, model: "claude-sonnet-4", now: now), 80)
        XCTAssertEqual(AccountPool.headroom(usage, model: "claude-fable-5", now: now.addingTimeInterval(1000)), 50)
    }

    func testStickyThenQuotaFailoverAndPinnedState() async {
        let pool = AccountPool(randomUnit: { 0 }), now = Date()
        await pool.update(profiles: [a, b], usage: [:])
        let first = await pool.select(model: "fable", conversation: "one", excluding: [], hasRemoteState: false, now: now)
        XCTAssertEqual(first, a)
        let second = await pool.select(model: "fable", conversation: "two", excluding: [], hasRemoteState: false, now: now)
        XCTAssertEqual(second, a)
        let sticky = await pool.select(model: "fable", conversation: "one", excluding: [], hasRemoteState: false, now: now)
        XCTAssertEqual(sticky, a)
        await pool.release(a); await pool.release(a)
        await pool.block(a, until: now.addingTimeInterval(100))
        await pool.block(a, until: now.addingTimeInterval(1))
        let switched = await pool.select(model: "fable", conversation: "one", excluding: [], hasRemoteState: false, now: now)
        XCTAssertEqual(switched, b)
        let pinned = await pool.select(model: "fable", conversation: "one", excluding: [], hasRemoteState: true, now: now)
        XCTAssertNil(pinned)
        await pool.block(b, until: now.addingTimeInterval(200))
        let cannotMove = await pool.select(model: "fable", conversation: "one", excluding: [], hasRemoteState: true, now: now.addingTimeInterval(101))
        XCTAssertNil(cannotMove)
        let unknownOwner = await pool.select(model: "fable", conversation: "unknown", excluding: [], hasRemoteState: true, now: now.addingTimeInterval(101))
        XCTAssertNil(unknownOwner)
    }

    func testWeightedInitialChoiceCanUseEitherAccount() async {
        let left = AccountPool(randomUnit: { 0 }), right = AccountPool(randomUnit: { 0.99 })
        await left.update(profiles: [a, b], usage: [:]); await right.update(profiles: [a, b], usage: [:])
        let first = await left.select(model: "fable", conversation: "one", excluding: [], hasRemoteState: false)
        let last = await right.select(model: "fable", conversation: "one", excluding: [], hasRemoteState: false)
        XCTAssertEqual(first, a); XCTAssertEqual(last, b)
    }

    func testRemoteStateDetectionAndCooldown() throws {
        let body = Data(#"{"model":"fable","messages":[{"content":[{"type":"document","source":{"type":"file","file_id":"file_test"}}]}]}"#.utf8)
        let request = LocalHTTPRequest(method: "POST", target: "/v1/messages", headers: [:], body: body)
        XCTAssertTrue(try BalancedRequest.details(request).remoteState)
        let now = Date()
        XCTAssertEqual(BalancedRequest.cooldown(status: 429, headers: ["retry-after": "12"], now: now), now.addingTimeInterval(12))
        XCTAssertNil(BalancedRequest.cooldown(status: 500, headers: [:], now: now))
        XCTAssertNil(BalancedRequest.cooldown(status: 200, headers: [:], now: now))
    }

    func testUpstreamCredentialsAreReplacedAndBodyPreserved() throws {
        let body = Data(#"{"model":"fable","messages":[]}"#.utf8)
        let incoming = LocalHTTPRequest(method: "POST", target: "/v1/messages?beta=true", headers: [
            "authorization": "Bearer LOCAL", "x-api-key": "LOCAL", "cookie": "secret", "anthropic-beta": "new-feature", "anthropic-version": "2023-06-01",
            "x-claude-code-session-id": "test-session", "host": "localhost", "content-type": "application/json"
        ], body: body)
        let request = try GatewayUpstream.makeRequest(incoming, credentials: Credentials(accessToken: "UPSTREAM", expiresAt: nil, plan: "max"))
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer UPSTREAM")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "new-feature,oauth-2025-04-20")
    }
}

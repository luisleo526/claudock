import XCTest
@testable import UsageCore

final class UsageClientTests: XCTestCase {
    func testRetryAfterSupportsSecondsHTTPDatesAndMinimumCooldown() {
        let now = Date(timeIntervalSince1970: 1_784_592_000)
        XCTAssertEqual(UsageClient.retryDate("600", now: now)?.timeIntervalSince(now), 600)
        XCTAssertEqual(UsageClient.retryDate("1", now: now)?.timeIntervalSince(now), 300)
        XCTAssertEqual(UsageClient.retryDate("900000", now: now)?.timeIntervalSince(now), 86_400)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        XCTAssertEqual(UsageClient.retryDate(f.string(from: now.addingTimeInterval(900)), now: now)?.timeIntervalSince(now), 900)
    }
    /// Without a usable Retry-After the cooldown is the caller's exponential backoff, not a fixed five minutes.
    func testMissingOrUnusableRetryAfterGivesNoDate() {
        let now = Date(timeIntervalSince1970: 1_784_592_000)
        XCTAssertNil(UsageClient.retryDate(nil, now: now))
        XCTAssertNil(UsageClient.retryDate("Infinity", now: now))
        XCTAssertNil(UsageClient.retryDate("soon", now: now))
    }
    /// The variable is honoured only by a build made with -D CLAUDOCK_TEST_USAGE_ENDPOINT, never by this one.
    func testTheEnvironmentCannotMoveTheEndpointOfAnOrdinaryBuild() {
        setenv("CLAUDOCK_TEST_USAGE_ENDPOINT", "http://127.0.0.1:1/api/oauth/usage", 1)
        defer { unsetenv("CLAUDOCK_TEST_USAGE_ENDPOINT") }
        XCTAssertEqual(UsageClient.endpoint.absoluteString, "https://api.anthropic.com/api/oauth/usage")
    }
    func testUnrepresentablePercentDoesNotCrashConsumers() {
        XCTAssertThrowsError(try UsageSnapshot.parse(Data(#"{"five_hour":{"utilization":1e300}}"#.utf8)))
    }
}

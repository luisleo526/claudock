import XCTest
@testable import UsageCore

final class UsageClientTests: XCTestCase {
    func testRetryAfterSupportsSecondsHTTPDatesAndMinimumCooldown() {
        let now = Date(timeIntervalSince1970: 1_784_592_000)
        XCTAssertEqual(UsageClient.retryDate("600", now: now).timeIntervalSince(now), 600)
        XCTAssertEqual(UsageClient.retryDate("1", now: now).timeIntervalSince(now), 300)
        XCTAssertEqual(UsageClient.retryDate("Infinity", now: now).timeIntervalSince(now), 300)
        XCTAssertEqual(UsageClient.retryDate(nil, now: now).timeIntervalSince(now), 300)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        XCTAssertEqual(UsageClient.retryDate(f.string(from: now.addingTimeInterval(900)), now: now).timeIntervalSince(now), 900)
    }
    func testUnrepresentablePercentDoesNotCrashConsumers() {
        XCTAssertThrowsError(try UsageSnapshot.parse(Data(#"{"five_hour":{"utilization":1e300}}"#.utf8)))
    }
}

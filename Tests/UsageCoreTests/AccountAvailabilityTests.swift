import Foundation
import XCTest
@testable import UsageCore

final class AccountAvailabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private let subscription = Profile(command: "claude-work", configDirectory: "/tmp/work")
    private let apiKey = Profile(command: "claude-api", configDirectory: "/tmp/api", managed: true, authKind: .apiKey)

    private func snapshot(session: Double, weekly: Double, fable: Double? = nil, other: Double? = nil,
                          sessionReset: TimeInterval = 3600, weeklyReset: TimeInterval = 86_400) -> UsageSnapshot {
        var windows = [
            UsageWindow(id: "session-0", title: "5-hour session", percent: session, resetsAt: now.addingTimeInterval(sessionReset)),
            UsageWindow(id: "weekly_all-1", title: "Weekly · all models", percent: weekly, resetsAt: now.addingTimeInterval(weeklyReset))
        ]
        if let fable { windows.append(UsageWindow(id: "weekly_scoped-2", title: "Weekly · Fable", percent: fable, resetsAt: now.addingTimeInterval(weeklyReset))) }
        if let other { windows.append(UsageWindow(id: "weekly_scoped-3", title: "Weekly · Opus", percent: other, resetsAt: now.addingTimeInterval(weeklyReset))) }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    func testHeadroomIsTheTightestGoverningLimit() throws {
        let headroom = try XCTUnwrap(snapshot(session: 30, weekly: 72, fable: 55).headroom(at: now))
        XCTAssertEqual(headroom.percentLeft, 28)
        XCTAssertEqual(headroom.window.title, "Weekly · all models")
        XCTAssertFalse(headroom.isFull)
        XCTAssertNil(headroom.availableAgain)
    }

    func testOtherModelLimitsDoNotGovernWhenTheMainLimitsAreReported() throws {
        let headroom = try XCTUnwrap(snapshot(session: 10, weekly: 20, other: 100).headroom(at: now))
        XCTAssertEqual(headroom.percentLeft, 80)
        let onlyOther = UsageSnapshot(windows: [UsageWindow(id: "x", title: "Weekly · Opus", percent: 64, resetsAt: nil)])
        XCTAssertEqual(onlyOther.headroom(at: now)?.percentLeft, 36)
        XCTAssertNil(UsageSnapshot(windows: []).headroom(at: now))
    }

    func testALimitPastItsResetTimeCountsAsEmpty() throws {
        let reset = try XCTUnwrap(snapshot(session: 100, weekly: 40, sessionReset: -60).headroom(at: now))
        XCTAssertEqual(reset.percentLeft, 60)
        XCTAssertEqual(AccountAvailability.classify(profile: subscription, snapshot: snapshot(session: 100, weekly: 40, sessionReset: -60),
                                                    error: nil, credit: nil, now: now), .available)
    }

    func testFullAccountsReportWhenEveryFullLimitHasReset() throws {
        let both = try XCTUnwrap(snapshot(session: 100, weekly: 100, sessionReset: 600, weeklyReset: 7200).headroom(at: now))
        XCTAssertTrue(both.isFull)
        XCTAssertEqual(both.availableAgain, now.addingTimeInterval(7200))
        let unknown = UsageSnapshot(windows: [UsageWindow(id: "session-0", title: "5-hour session", percent: 100, resetsAt: nil)])
        XCTAssertNil(unknown.headroom(at: now)?.availableAgain)
    }

    func testSubscriptionClassification() {
        func classify(_ snapshot: UsageSnapshot?, _ error: MonitorError? = nil) -> AccountAvailability {
            AccountAvailability.classify(profile: subscription, snapshot: snapshot, error: error, credit: nil, now: now)
        }
        XCTAssertEqual(classify(snapshot(session: 20, weekly: 89)), .available)
        XCTAssertEqual(classify(snapshot(session: 20, weekly: 90.5)), .nearLimit)
        XCTAssertEqual(classify(snapshot(session: 100, weekly: 50)), .full)
        XCTAssertEqual(classify(snapshot(session: 20, weekly: 20), .network), .available, "a stale reading still counts")
        XCTAssertEqual(classify(snapshot(session: 20, weekly: 20), .loginRequired), .attention)
        XCTAssertEqual(classify(nil, .network), .attention)
        XCTAssertEqual(classify(nil), .untracked, "not read yet")
    }

    func testConsoleAndUnsupportedClassification() {
        func classify(_ profile: Profile, _ credit: APICreditStatus?, failed: Bool = false) -> AccountAvailability {
            AccountAvailability.classify(profile: profile, snapshot: nil, error: nil, credit: credit, creditFailed: failed, now: now)
        }
        XCTAssertEqual(classify(apiKey, APICreditStatus(balance: 200, spent: 12, asOf: now)), .available)
        XCTAssertEqual(classify(apiKey, APICreditStatus(balance: 200, spent: 196, asOf: now)), .nearLimit)
        XCTAssertEqual(classify(apiKey, APICreditStatus(balance: 20, spent: 25, asOf: now)), .full)
        XCTAssertEqual(classify(apiKey, nil), .untracked)
        XCTAssertEqual(classify(apiKey, nil, failed: true), .attention)
        XCTAssertEqual(classify(Profile(command: "claude-vertex", configDirectory: "", isVertex: true), nil), .untracked)
        XCTAssertTrue(AccountAvailability.nearLimit.hasRoom)
        XCTAssertFalse(AccountAvailability.full.hasRoom)
    }
}

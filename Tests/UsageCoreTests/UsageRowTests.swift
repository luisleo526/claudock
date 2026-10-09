import Foundation
import XCTest
@testable import UsageCore

/// How the dashboard's row for a subscription profile takes the shared cache and each refresh's result.
final class UsageRowTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ percent: Double, at offset: TimeInterval, plan: SubscriptionPlan = .max20x) -> UsageReading {
        UsageReading(plan: plan, snapshot: UsageSnapshot(windows: [UsageWindow(id: "five_hour", title: "5-hour session", percent: percent,
                                                                               resetsAt: nil)], fetchedAt: instant.addingTimeInterval(offset)))
    }

    func testANewerCachedReadingIsShownAndAnOlderOneIsNot() {
        var row = UsageRow(snapshot: reading(1, at: -600, plan: .pro).snapshot, plan: .pro, error: .network)
        row.merge(UsageCacheEntry(reading: reading(2, at: -60)))
        XCTAssertEqual(row, UsageRow(snapshot: reading(2, at: -60).snapshot, plan: .max20x),
                       "a reading saved after the row's failure replaces the reading and the error")
        row.merge(UsageCacheEntry(reading: reading(3, at: -900, plan: .pro)))
        XCTAssertEqual(row, UsageRow(snapshot: reading(2, at: -60).snapshot, plan: .max20x), "an older cached reading never replaces a newer one")
    }

    func testACachedCooldownHoldsTheRowUntilItEnds() {
        var row = UsageRow(snapshot: reading(1, at: -60).snapshot, plan: .max20x)
        row.merge(UsageCacheEntry(reading: reading(1, at: -60), retryAt: instant.addingTimeInterval(300), rateLimits: 1))
        XCTAssertEqual(row, UsageRow(snapshot: reading(1, at: -60).snapshot, plan: .max20x, error: .rateLimited(instant.addingTimeInterval(300)),
                                     retryAt: instant.addingTimeInterval(300)))
        XCTAssertTrue(row.isCoolingDown(at: instant.addingTimeInterval(299)))
        XCTAssertFalse(row.isCoolingDown(at: instant.addingTimeInterval(300)))
        row.merge(UsageCacheEntry(retryAt: instant.addingTimeInterval(100), rateLimits: 1))
        XCTAssertEqual(row.retryAt, instant.addingTimeInterval(300), "an earlier cooldown does not shorten the known one")
        XCTAssertFalse(UsageRow().isCoolingDown(at: instant))
    }

    func testACurrentResultReplacesTheRowWhateverTheShownReadingsDate() {
        // A reading dated a day ahead, from when the Mac's clock was wrong, must not hold back the new one.
        var row = UsageRow(snapshot: reading(9, at: 86_400).snapshot, plan: .pro, error: .rateLimited(instant.addingTimeInterval(60)),
                           retryAt: instant.addingTimeInterval(60))
        row.apply(.current(reading(4, at: 0)))
        XCTAssertEqual(row, UsageRow(snapshot: reading(4, at: 0).snapshot, plan: .max20x))
    }

    func testACachedResultKeepsANewerShownReadingAndSaysWhyItIsStale() {
        var row = UsageRow(snapshot: reading(5, at: -30, plan: .max5x).snapshot, plan: .max5x)
        row.apply(.cached(reading(4, at: -600), .rateLimited(instant.addingTimeInterval(120))))
        XCTAssertEqual(row, UsageRow(snapshot: reading(5, at: -30, plan: .max5x).snapshot, plan: .max5x,
                                     error: .rateLimited(instant.addingTimeInterval(120)), retryAt: instant.addingTimeInterval(120)))
        row.apply(.cached(reading(6, at: -10), .network))
        XCTAssertEqual(row, UsageRow(snapshot: reading(6, at: -10).snapshot, plan: .max20x, error: .network))
    }

    func testAFailedResultKeepsTheLastReading() {
        var row = UsageRow(snapshot: reading(5, at: -30).snapshot, plan: .max20x)
        row.apply(.failed(.rateLimited(instant.addingTimeInterval(60))))
        XCTAssertEqual(row, UsageRow(snapshot: reading(5, at: -30).snapshot, plan: .max20x, error: .rateLimited(instant.addingTimeInterval(60)),
                                     retryAt: instant.addingTimeInterval(60)))
        row.apply(.failed(.noCredentials))
        XCTAssertEqual(row, UsageRow(snapshot: reading(5, at: -30).snapshot, plan: .max20x, error: .noCredentials))
    }
}

import Foundation
import XCTest
@testable import UsageCore

final class UsageTests: XCTestCase {
    func testLaunchChoicePrefersFableAndRetainsTheActualWindowTitle() {
        let weekly = UsageWindow(id: "weekly_all-0", title: "Weekly · all models", percent: 45, resetsAt: nil)
        let session = UsageWindow(id: "session-1", title: "5-hour session", percent: 21, resetsAt: nil)
        let fable = UsageWindow(id: "weekly_scoped-2", title: "Weekly · Fable", percent: 88, resetsAt: nil)
        XCTAssertEqual(UsageSnapshot(windows: [weekly, session, fable]).preferredLaunchWindow, fable)
        XCTAssertEqual(UsageSnapshot(windows: [weekly, session]).preferredLaunchWindow, session)
        XCTAssertEqual(UsageSnapshot(windows: [weekly]).preferredLaunchWindow?.title, "Weekly · all models")
        XCTAssertNil(UsageSnapshot(windows: []).preferredLaunchWindow)
    }
    private let fetchedAt = Date(timeIntervalSince1970: 1_789_000_000)

    private func parse(_ json: String) throws -> UsageSnapshot {
        try UsageSnapshot.parse(Data(json.utf8), now: fetchedAt)
    }

    func testLegacyNullIsUnavailableWhileExplicitZeroIsAReading() throws {
        let snapshot = try parse(#"""
        {
          "five_hour": {"utilization": 0, "resets_at": null},
          "seven_day": {"utilization": null, "resets_at": "2026-09-09T00:00:00Z"},
          "seven_day_sonnet": null
        }
        """#)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.id, "five_hour")
        XCTAssertEqual(snapshot.windows.first?.percent, 0)
        XCTAssertNil(snapshot.windows.first?.resetsAt)
        XCTAssertEqual(snapshot.peak, 0)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)

        XCTAssertThrowsError(try parse(#"{"five_hour":{"utilization":null},"seven_day":null}"#)) {
            XCTAssertEqual($0 as? MonitorError, .invalidResponse)
        }
    }

    func testExplicitWindowsPreserveUnknownModelsAndSupersedeLegacyDuplicates() throws {
        let snapshot = try parse(#"""
        {
          "limits": [
            {"kind":"session", "percent":12.5},
            {"kind":"weekly_all", "percent":34},
            {"kind":"weekly_scoped", "percent":56, "scope":{"model":{"display_name":"Opus"}}},
            {"kind":"weekly_scoped", "percent":78, "scope":{"model":{"display_name":"Fable 5"}}}
          ],
          "five_hour":{"utilization":99},
          "seven_day":{"utilization":99},
          "seven_day_opus":{"utilization":99},
          "seven_day_sonnet":{"utilization":23}
        }
        """#)
        XCTAssertEqual(snapshot.windows.count, 5)
        XCTAssertEqual(snapshot.windows.map(\.title), [
            "5-hour session", "Weekly · all models", "Weekly · Opus", "Weekly · Fable 5", "Weekly · Sonnet"
        ])
        XCTAssertEqual(snapshot.windows.map(\.percent), [12.5, 34, 56, 78, 23])
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, snapshot.windows.count)
    }

    func testUnrecognizedExplicitKindAndSurfaceRemainVisible() throws {
        let snapshot = try parse(#"""
        {"limits":[
          {"kind":"monthly_sdk", "percent":4, "scope":{"surface":{"display_name":"Agent SDK"}}},
          {"kind":"future_window", "percent":5}
        ]}
        """#)
        XCTAssertEqual(snapshot.windows.map(\.title), ["Agent SDK", "Future Window"])
        XCTAssertEqual(snapshot.windows.map(\.percent), [4, 5])
    }

    func testFeaturedFableAndSessionWeekPairDoNotDependOnAPIOrder() throws {
        let entries = [
            #"{"kind":"weekly_scoped","percent":93,"scope":{"model":{"display_name":"Fable 5"}}}"#,
            #"{"kind":"weekly_all","percent":96}"#,
            #"{"kind":"session","percent":43}"#,
            #"{"kind":"weekly_scoped","percent":22,"scope":{"model":{"display_name":"Future Model"}}}"#
        ]
        for order in [[0, 1, 2, 3], [3, 2, 0, 1], [1, 3, 2, 0], [2, 0, 3, 1]] {
            let snapshot = try parse("{\"limits\":[\(order.map { entries[$0] }.joined(separator: ","))]}")
            let featured = try XCTUnwrap(snapshot.featuredFableWindow)
            XCTAssertEqual(featured.title, "Weekly · Fable 5")
            XCTAssertEqual(featured.percent, 93)
            XCTAssertEqual(snapshot.secondaryWindows.map(\.title), ["5-hour session", "Weekly · all models", "Weekly · Future Model"])
            XCTAssertEqual(snapshot.secondaryWindows.map(\.percent), [43, 96, 22])
            XCTAssertFalse(snapshot.secondaryWindows.contains { $0.id == featured.id })
        }
    }

    func testFableRecognitionAcceptsCaseAndNumericSuffixesWithoutMatchingOtherNames() {
        for title in ["Weekly · Fable", "Weekly · FABLE 5", "Weekly · fable5", "Fable 5.1"] {
            let window = UsageWindow(id: "model", title: title, percent: 0, resetsAt: nil)
            let snapshot = UsageSnapshot(windows: [window])
            XCTAssertEqual(snapshot.featuredFableWindow, window, title)
            XCTAssertTrue(snapshot.secondaryWindows.isEmpty)
        }
        for title in ["Weekly · NotFable", "Weekly · Fableish", "Weekly · Fable5ish", "Weekly · Fabled"] {
            let window = UsageWindow(id: "other", title: title, percent: 91, resetsAt: nil)
            let snapshot = UsageSnapshot(windows: [window])
            XCTAssertNil(snapshot.featuredFableWindow, title)
            XCTAssertEqual(snapshot.secondaryWindows, [window])
        }
    }

    func testNoFableKeepsStandardPairAndUnknownWindowsWithoutInventingAMeter() throws {
        let snapshot = try parse(#"""
        {
          "limits":[
            {"kind":"monthly_sdk","percent":19,"scope":{"surface":{"display_name":"Agent SDK"}}},
            {"kind":"weekly_scoped","percent":8,"scope":{"model":{"display_name":"Future Model"}}}
          ],
          "seven_day":{"utilization":47},
          "five_hour":{"utilization":26}
        }
        """#)
        XCTAssertNil(snapshot.featuredFableWindow)
        XCTAssertEqual(snapshot.secondaryWindows.map(\.title), ["5-hour session", "Weekly · all models", "Agent SDK", "Weekly · Future Model"])
        XCTAssertEqual(snapshot.secondaryWindows.count, snapshot.windows.count)

        let empty = UsageSnapshot(windows: [])
        XCTAssertNil(empty.featuredFableWindow)
        XCTAssertTrue(empty.secondaryWindows.isEmpty)
    }

    func testMultipleFableWindowsChooseHighestUsageAndKeepEveryOtherWindowOnce() throws {
        let fable = UsageWindow(id: "fable", title: "Weekly · Fable", percent: 62, resetsAt: nil)
        let fableFive = UsageWindow(id: "fable-five", title: "Weekly · Fable 5", percent: 91, resetsAt: fetchedAt)
        let future = UsageWindow(id: "future", title: "Weekly · Future Model", percent: 99, resetsAt: nil)
        for windows in [[fable, future, fableFive], [fableFive, future, fable]] {
            let snapshot = UsageSnapshot(windows: windows)
            let featured = try XCTUnwrap(snapshot.featuredFableWindow)
            XCTAssertEqual(featured, fableFive)
            let rendered = [featured] + snapshot.secondaryWindows
            XCTAssertEqual(rendered.count, windows.count)
            XCTAssertEqual(Set(rendered.map(\.id)), Set(windows.map(\.id)))
            XCTAssertTrue(snapshot.secondaryWindows.contains(future))
            XCTAssertTrue(snapshot.secondaryWindows.contains(fable))
        }
    }

    func testEqualFableUsageHasDeterministicTieBreaks() {
        let first = UsageWindow(id: "first", title: "Weekly · Fable", percent: 91, resetsAt: fetchedAt)
        let second = UsageWindow(id: "second", title: "Weekly · Fable", percent: 91, resetsAt: fetchedAt)
        let later = UsageWindow(id: "later", title: "Weekly · Fable", percent: 91, resetsAt: fetchedAt.addingTimeInterval(3600))
        let otherTitle = UsageWindow(id: "other", title: "Weekly · Fable 5", percent: 91, resetsAt: fetchedAt)
        XCTAssertEqual(UsageSnapshot(windows: [otherTitle, later, second, first]).featuredFableWindow, first)
        XCTAssertEqual(UsageSnapshot(windows: [first, second, later, otherTitle]).featuredFableWindow, first)
    }

    func testInvalidExplicitEntryDoesNotHideValidLegacyWindow() throws {
        let snapshot = try parse(#"""
        {
          "limits":[{"kind":"session","percent":null},{"kind":"weekly_all","percent":45}],
          "five_hour":{"utilization":11},
          "seven_day":{"utilization":90}
        }
        """#)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.first(where: { $0.title == "5-hour session" })?.percent, 11)
        XCTAssertEqual(snapshot.windows.first(where: { $0.title == "Weekly · all models" })?.percent, 45)
    }

    func testISOResetDatesAcceptOffsetsAndFractionalSeconds() throws {
        let utc = try XCTUnwrap(UsageSnapshot.parseDate("2026-09-08T12:34:56Z"))
        let positiveOffset = try XCTUnwrap(UsageSnapshot.parseDate("2026-09-08T20:34:56+08:00"))
        let negativeOffset = try XCTUnwrap(UsageSnapshot.parseDate("2026-09-08T08:34:56-04:00"))
        let fractional = try XCTUnwrap(UsageSnapshot.parseDate("2026-09-08T12:34:56.789Z"))
        XCTAssertEqual(utc, positiveOffset)
        XCTAssertEqual(utc, negativeOffset)
        XCTAssertEqual(fractional.timeIntervalSince(utc), 0.789, accuracy: 0.001)

        let snapshot = try parse(#"{"five_hour":{"utilization":3,"resets_at":"2026-09-08T20:34:56.789+08:00"}}"#)
        XCTAssertEqual(try XCTUnwrap(snapshot.windows.first?.resetsAt).timeIntervalSince(fractional), 0, accuracy: 0.001)
    }

    func testInvalidResetDateDoesNotFabricateADateOrDiscardPercentage() throws {
        for invalid: Any in ["tomorrow", "", 1_789_000_000, NSNull(), false] {
            XCTAssertNil(UsageSnapshot.parseDate(invalid))
        }
        let snapshot = try parse(#"{"five_hour":{"utilization":31,"resets_at":"not-a-date"}}"#)
        XCTAssertEqual(snapshot.windows.first?.percent, 31)
        XCTAssertNil(snapshot.windows.first?.resetsAt)
    }

    func testMalformedAndUnrecognizedPayloadsFailInsteadOfShowingZero() {
        for payload in ["{", "[]", "null", "true", "{}", #"{"error":"upstream unavailable"}"#,
                        #"{"limits":[],"five_hour":null}"#, #"{"five_hour":{"resets_at":"2026-09-09T00:00:00Z"}}"#] {
            XCTAssertThrowsError(try parse(payload), payload)
        }
    }

    func testBooleanNegativeStringAndInfinitePercentagesAreRejected() {
        for value in ["false", "true", "-0.1", "-100", #""50""#, "1e309", "-1e309"] {
            XCTAssertThrowsError(try parse("{\"five_hour\":{\"utilization\":\(value)}}"), "legacy: \(value)")
            XCTAssertThrowsError(try parse("{\"limits\":[{\"kind\":\"session\",\"percent\":\(value)}]}"), "explicit: \(value)")
        }
    }

    func testInvalidPercentagesDoNotDiscardOtherValidWindows() throws {
        let snapshot = try parse(#"""
        {
          "limits":[
            {"kind":"session","percent":false},
            {"kind":"weekly_all","percent":-1},
            {"kind":"weekly_scoped","percent":6.25,"scope":{"model":{"display_name":"Sonnet"}}}
          ]
        }
        """#)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.percent, 6.25)
    }

    func testOverLimitPercentageStaysAccurateWhileProgressFractionIsBounded() throws {
        let snapshot = try parse(#"{"five_hour":{"utilization":125.75},"seven_day":{"utilization":50}}"#)
        XCTAssertEqual(snapshot.windows.first?.percent, 125.75)
        XCTAssertEqual(snapshot.windows.first?.fraction, 1)
        XCTAssertEqual(snapshot.windows.last?.fraction, 0.5)
        XCTAssertEqual(snapshot.peak, 125.75)
    }

    func testExplicitSpendZeroAndDisabledStateSupersedeLegacyExtraUsage() throws {
        let snapshot = try parse(#"""
        {
          "five_hour":{"utilization":10},
          "spend":{"enabled":false,"percent":0},
          "extra_usage":{"is_enabled":true,"utilization":85}
        }
        """#)
        XCTAssertFalse(snapshot.extraUsageEnabled)
        XCTAssertEqual(snapshot.extraUsagePercent, 0)
    }

    func testLegacyExtraUsageAndInvalidExtraPercentage() throws {
        let snapshot = try parse(#"{"five_hour":{"utilization":10},"extra_usage":{"is_enabled":true,"utilization":102.5}}"#)
        XCTAssertTrue(snapshot.extraUsageEnabled)
        XCTAssertEqual(snapshot.extraUsagePercent, 102.5)
        for value in ["false", "-1", "null"] {
            let invalid = try parse("{\"five_hour\":{\"utilization\":10},\"extra_usage\":{\"is_enabled\":true,\"utilization\":\(value)}}")
            XCTAssertNil(invalid.extraUsagePercent)
        }
    }
}

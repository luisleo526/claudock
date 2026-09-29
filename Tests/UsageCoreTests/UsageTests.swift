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

    func testDisplayWindowsDoNotDependOnAPIOrder() throws {
        let entries = [
            #"{"kind":"weekly_scoped","percent":93,"scope":{"model":{"display_name":"Fable 5"}}}"#,
            #"{"kind":"weekly_all","percent":96}"#,
            #"{"kind":"session","percent":43}"#,
            #"{"kind":"weekly_scoped","percent":22,"scope":{"model":{"display_name":"Future Model"}}}"#
        ]
        for order in [[0, 1, 2, 3], [3, 2, 0, 1], [1, 3, 2, 0], [2, 0, 3, 1]] {
            let snapshot = try parse("{\"limits\":[\(order.map { entries[$0] }.joined(separator: ","))]}")
            let display = snapshot.displayWindows
            XCTAssertEqual(display.session?.title, "5-hour session")
            XCTAssertEqual(display.session?.percent, 43)
            XCTAssertEqual(display.weekly?.title, "Weekly · all models")
            XCTAssertEqual(display.weekly?.percent, 96)
            XCTAssertEqual(display.fable?.title, "Weekly · Fable 5")
            XCTAssertEqual(display.fable?.percent, 93)
            XCTAssertEqual(display.others.map(\.title), ["Weekly · Future Model"])
            XCTAssertEqual(display.others.map(\.percent), [22])
            let rendered = [display.session, display.weekly, display.fable].compactMap { $0 } + display.others
            XCTAssertEqual(rendered.count, snapshot.windows.count)
            XCTAssertEqual(Set(rendered.map(\.id)), Set(snapshot.windows.map(\.id)))
        }
    }

    func testFableRecognitionAcceptsCaseAndNumericSuffixesWithoutMatchingOtherNames() {
        for title in ["Weekly · Fable", "Weekly · FABLE 5", "Weekly · fable5", "Fable 5.1"] {
            let window = UsageWindow(id: "model", title: title, percent: 0, resetsAt: nil)
            let display = UsageSnapshot(windows: [window]).displayWindows
            XCTAssertEqual(display.fable, window, title)
            XCTAssertTrue(display.others.isEmpty)
        }
        for title in ["Weekly · NotFable", "Weekly · Fableish", "Weekly · Fable5ish", "Weekly · Fabled"] {
            let window = UsageWindow(id: "other", title: title, percent: 91, resetsAt: nil)
            let display = UsageSnapshot(windows: [window]).displayWindows
            XCTAssertNil(display.fable, title)
            XCTAssertEqual(display.others, [window])
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
        let display = snapshot.displayWindows
        XCTAssertNil(display.fable)
        XCTAssertEqual(display.session?.id, "five_hour")
        XCTAssertEqual(display.session?.percent, 26)
        XCTAssertEqual(display.weekly?.id, "seven_day")
        XCTAssertEqual(display.weekly?.percent, 47)
        XCTAssertEqual(display.others.map(\.title), ["Agent SDK", "Weekly · Future Model"])

        let empty = UsageSnapshot(windows: []).displayWindows
        XCTAssertNil(empty.session)
        XCTAssertNil(empty.weekly)
        XCTAssertNil(empty.fable)
        XCTAssertTrue(empty.others.isEmpty)
    }

    func testDisplayRecognizesSessionAndOverallWeekByIDOrExactTitle() {
        for id in ["five_hour", "session-7", "unknown"] {
            let window = UsageWindow(id: id, title: id == "unknown" ? "5-hour session" : "Renamed session", percent: 12, resetsAt: nil)
            let display = UsageSnapshot(windows: [window]).displayWindows
            XCTAssertEqual(display.session, window)
            XCTAssertNil(display.weekly)
            XCTAssertTrue(display.others.isEmpty)
        }
        for id in ["seven_day", "weekly_all-4", "unknown"] {
            let window = UsageWindow(id: id, title: id == "unknown" ? "Weekly · all models" : "Renamed week", percent: 34, resetsAt: nil)
            let display = UsageSnapshot(windows: [window]).displayWindows
            XCTAssertEqual(display.weekly, window)
            XCTAssertNil(display.session)
            XCTAssertTrue(display.others.isEmpty)
        }
    }

    func testMultipleFableWindowsChooseHighestUsageAndKeepEveryOtherWindowInOrder() {
        let fable = UsageWindow(id: "fable", title: "Weekly · Fable", percent: 62, resetsAt: nil)
        let fableFive = UsageWindow(id: "fable-five", title: "Weekly · Fable 5", percent: 91, resetsAt: fetchedAt)
        let future = UsageWindow(id: "future", title: "Weekly · Future Model", percent: 99, resetsAt: nil)
        for windows in [[fable, future, fableFive], [fableFive, future, fable]] {
            let display = UsageSnapshot(windows: windows).displayWindows
            XCTAssertEqual(display.fable, fableFive)
            XCTAssertNil(display.session)
            XCTAssertNil(display.weekly)
            XCTAssertEqual(display.others, windows.filter { $0 != fableFive })
        }
    }

    func testEqualFableUsageHasDeterministicTieBreaks() {
        let first = UsageWindow(id: "first", title: "Weekly · Fable", percent: 91, resetsAt: fetchedAt)
        let second = UsageWindow(id: "second", title: "Weekly · Fable", percent: 91, resetsAt: fetchedAt)
        let later = UsageWindow(id: "later", title: "Weekly · Fable", percent: 91, resetsAt: fetchedAt.addingTimeInterval(3600))
        let unknownReset = UsageWindow(id: "unknown-reset", title: "Weekly · Fable", percent: 91, resetsAt: nil)
        let otherTitle = UsageWindow(id: "other", title: "Weekly · Fable 5", percent: 91, resetsAt: fetchedAt)
        XCTAssertEqual(UsageSnapshot(windows: [otherTitle, unknownReset, later, second, first]).displayWindows.fable, first)
        XCTAssertEqual(UsageSnapshot(windows: [first, second, later, unknownReset, otherTitle]).displayWindows.fable, first)
    }

    func testDisplayPartitionsRepeatedKindsAndIDsWithoutDroppingOrRepeatingEntries() {
        let fable = UsageWindow(id: "session-0", title: "Weekly · Fable", percent: 90, resetsAt: nil)
        let session = UsageWindow(id: "session-1", title: "5-hour session", percent: 20, resetsAt: nil)
        let anotherSession = UsageWindow(id: "session-2", title: "5-hour session", percent: 30, resetsAt: nil)
        let weekly = UsageWindow(id: "weekly_all-3", title: "Weekly · all models", percent: 40, resetsAt: nil)
        let anotherWeekly = UsageWindow(id: "weekly_all-4", title: "Weekly · all models", percent: 50, resetsAt: nil)
        let duplicateID = UsageWindow(id: fable.id, title: "Future limit", percent: 60, resetsAt: nil)
        let display = UsageSnapshot(windows: [fable, session, anotherSession, weekly, duplicateID, anotherWeekly]).displayWindows
        XCTAssertEqual(display.session, session)
        XCTAssertEqual(display.weekly, weekly)
        XCTAssertEqual(display.fable, fable)
        XCTAssertEqual(display.others, [anotherSession, duplicateID, anotherWeekly])
    }

    func testElapsedFractionUsesKnownDurationsByIDOrTitle() throws {
        let sessionDuration: TimeInterval = 5 * 3600
        let weeklyDuration: TimeInterval = 7 * 24 * 3600
        let cases: [(String, String, TimeInterval)] = [
            ("five_hour", "Session", sessionDuration),
            ("session-3", "Session", sessionDuration),
            ("session", "Session", sessionDuration),
            ("unknown", "5-hour session", sessionDuration),
            ("seven_day", "All models", weeklyDuration),
            ("seven_day_opus", "Opus", weeklyDuration),
            ("weekly_all-1", "All models", weeklyDuration),
            ("weekly_scoped-2", "Fable", weeklyDuration),
            ("unknown", "Weekly · Fable 5", weeklyDuration),
            ("unknown", "Weekly · Future Model", weeklyDuration)
        ]
        for (id, title, duration) in cases {
            let window = UsageWindow(id: id, title: title, percent: 82, resetsAt: fetchedAt.addingTimeInterval(duration / 2))
            XCTAssertEqual(try XCTUnwrap(window.elapsedFraction(at: fetchedAt)), 0.5, accuracy: 0.000001, id + title)
            XCTAssertEqual(try XCTUnwrap(window.elapsedFraction(at: fetchedAt.addingTimeInterval(duration / 4))), 0.75, accuracy: 0.000001)
        }
    }

    func testElapsedFractionClampsBeforeStartAndAfterReset() {
        let window = UsageWindow(id: "session-0", title: "5-hour session", percent: 10, resetsAt: fetchedAt)
        XCTAssertEqual(window.elapsedFraction(at: fetchedAt.addingTimeInterval(-6 * 3600)), 0)
        XCTAssertEqual(window.elapsedFraction(at: fetchedAt.addingTimeInterval(-5 * 3600)), 0)
        XCTAssertEqual(window.elapsedFraction(at: fetchedAt), 1)
        XCTAssertEqual(window.elapsedFraction(at: fetchedAt.addingTimeInterval(1)), 1)
    }

    func testElapsedFractionRequiresAResetAndAKnownDuration() {
        XCTAssertNil(UsageWindow(id: "five_hour", title: "5-hour session", percent: 10, resetsAt: nil).elapsedFraction(at: fetchedAt))
        for (id, title) in [("monthly_sdk-0", "Agent SDK"), ("unknown", "Fable 5"), ("unknown", "Future window")] {
            let window = UsageWindow(id: id, title: title, percent: 10, resetsAt: fetchedAt.addingTimeInterval(3600))
            XCTAssertNil(window.elapsedFraction(at: fetchedAt), id + title)
        }
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

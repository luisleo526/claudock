import XCTest
@testable import UsageCore

final class DemoDataTests: XCTestCase {
    func testDefaultPreviewKeepsItsFourDocumentedProfiles() {
        XCTAssertEqual(DemoData.profiles.map(\.command), ["claude-personal", "claude-studio", "claude-weekend", "claude-research"])
        XCTAssertEqual(DemoData.usage(index: 1).windows.map(\.percent), [100, 81, 92])
    }

    func testPreviewCoversPaceFullAndMissingFableWithParserIDs() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let personal = DemoData.usage(index: 0, now: now)
        XCTAssertEqual(personal.displayWindows.session?.percent, 82)
        XCTAssertEqual(personal.displayWindows.weekly?.percent, 41)
        XCTAssertEqual(personal.displayWindows.fable?.percent, 67)
        XCTAssertEqual(personal.displayWindows.session?.resetsAt, now.addingTimeInterval(2 * 3600 + 10 * 60))
        XCTAssertEqual(personal.displayWindows.weekly?.resetsAt, now.addingTimeInterval(3 * 86_400 + 4 * 3600))
        XCTAssertEqual(personal.displayWindows.fable?.resetsAt, personal.displayWindows.weekly?.resetsAt)
        XCTAssertEqual(personal.fetchedAt, now)
        XCTAssertEqual(personal.windows.map(\.id), ["session-0", "weekly_all-1", "weekly_scoped-2"])
        XCTAssertNil(DemoData.usage(index: 2, now: now).displayWindows.fable)
        XCTAssertNotNil(DemoData.usage(index: 3, now: now).displayWindows.fable)
    }

    func testLargePreviewHasDistinctProfilesAndUsage() {
        let profiles = DemoData.profiles(count: 40)
        XCTAssertEqual(profiles.count, 40)
        XCTAssertEqual(Set(profiles.map(\.id)).count, 40)
        XCTAssertEqual(Array(profiles.prefix(4)), DemoData.profiles)
        XCTAssertEqual(profiles[4].command, "claude-demo-05")
        for index in profiles.indices {
            let windows = DemoData.usage(index: index).windows
            XCTAssertGreaterThanOrEqual(windows.count, index == 2 ? 2 : 3)
            XCTAssertEqual(Set(windows.map(\.id)).count, windows.count)
            XCTAssertTrue(windows.allSatisfy { (0...100).contains($0.percent) })
        }
    }

    func testPreviewInferenceTokenStatusNeedsNoKeychain() {
        XCTAssertEqual(DemoData.mintStatus(profile: DemoData.profiles[0]), .notConfigured)
    }

    func testPreviewIncludesOneSyntheticAPIKeyProfileOutsideTheSubscriptionList() {
        let profile = DemoData.apiKeyProfile
        XCTAssertEqual(profile.authKind, .apiKey)
        XCTAssertTrue(profile.managed)
        XCTAssertTrue(profile.configDirectory.hasPrefix("/Users/demo/"))
        XCTAssertFalse(DemoData.profiles(count: 200).contains { $0.command == profile.command })
        XCTAssertTrue(DemoData.apiKeySaved(profile: profile))
    }

    func testPreviewIncludesOneSyntheticConsoleLoginProfileOutsideTheSubscriptionList() {
        let profile = DemoData.consoleLoginProfile
        XCTAssertEqual(profile.authKind, .consoleLogin)
        XCTAssertTrue(profile.managed)
        XCTAssertTrue(profile.configDirectory.hasPrefix("/Users/demo/"))
        XCTAssertFalse(DemoData.profiles(count: 200).contains { $0.command == profile.command })
        XCTAssertNotEqual(profile.command, DemoData.apiKeyProfile.command)
        XCTAssertTrue(DemoData.consoleSignedIn(profile: profile))
        XCTAssertFalse(DemoData.consoleSignedIn(profile: DemoData.apiKeyProfile))
        XCTAssertEqual(DemoData.consoleOrganization, "Demo Labs LLC")
    }

    func testPreviewIncludesOneSyntheticEndpointProfileOutsideTheSubscriptionList() throws {
        let profile = DemoData.endpointProfile
        XCTAssertEqual(profile.authKind, .endpoint)
        XCTAssertTrue(profile.managed)
        XCTAssertTrue(profile.configDirectory.hasPrefix("/Users/demo/"))
        XCTAssertEqual(profile.endpoint?.host, "api.deepseek.com")
        XCTAssertEqual(profile.endpoint?.model, "deepseek-flash")
        XCTAssertFalse(DemoData.profiles(count: 200).contains { $0.command == profile.command })
        XCTAssertFalse([DemoData.apiKeyProfile.command, DemoData.consoleLoginProfile.command].contains(profile.command))
    }

    func testPreviewShowsASyntheticCreditOnTheAPIKeyProfile() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let credit = DemoData.apiKeyCredit(now: now)
        XCTAssertEqual(credit.usageWindow, "Credit · $187.42 of $200.00 left")
        XCTAssertEqual(credit.asOf, now.addingTimeInterval(-3 * 86_400))
        XCTAssertFalse(credit.isLow)
    }
}

import XCTest
@testable import UsageCore

final class DemoDataTests: XCTestCase {
    func testDefaultPreviewKeepsItsFourDocumentedProfiles() {
        XCTAssertEqual(DemoData.profiles.map(\.command), ["claude-personal", "claude-studio", "claude-weekend", "claude-research"])
        XCTAssertEqual(DemoData.usage(index: 1).windows.map(\.percent), [68, 81, 92])
    }

    func testLargePreviewHasDistinctProfilesAndUsage() {
        let profiles = DemoData.profiles(count: 40)
        XCTAssertEqual(profiles.count, 40)
        XCTAssertEqual(Set(profiles.map(\.id)).count, 40)
        XCTAssertEqual(Array(profiles.prefix(4)), DemoData.profiles)
        XCTAssertEqual(profiles[4].command, "claude-demo-05")
        for index in profiles.indices {
            let windows = DemoData.usage(index: index).windows
            XCTAssertGreaterThanOrEqual(windows.count, 3)
            XCTAssertTrue(windows.allSatisfy { (0...100).contains($0.percent) })
        }
    }

    func testPreviewInferenceTokenStatusNeedsNoKeychain() {
        XCTAssertEqual(DemoData.mintStatus(profile: DemoData.profiles[0]), .notConfigured)
    }
}

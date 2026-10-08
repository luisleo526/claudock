import Foundation
import XCTest
@testable import UsageCore

final class InferenceTokenPolicyTests: XCTestCase {
    private let profile = Profile(command: "claude-work", configDirectory: "/synthetic/work", managed: true)
    private let apiKeyProfile = Profile(command: "claude-console", configDirectory: "/synthetic/console", managed: true, authKind: .apiKey)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let pastedValue = "sk-ant-oat01-" + "fixture_pasted_token"
    private var identity: MintAccountIdentity {
        try! MintAccountIdentity(accountUUID: "11111111-1111-4111-8111-111111111111", organizationUUID: "22222222-2222-4222-8222-222222222222")
    }

    private func browser(expiresIn seconds: TimeInterval) -> MintToken {
        MintToken(accessToken: "fixture-browser-token", expiresAt: now.addingTimeInterval(seconds), identity: identity)
    }

    private func pasted(expiresIn seconds: TimeInterval?) throws -> MintToken {
        try MintToken.imported(raw: pastedValue, expiresAt: seconds.map { now.addingTimeInterval($0) }, identity: nil)
    }

    private func decide(_ read: @escaping () throws -> MintToken?, required: Bool, arguments: [String] = [],
                        profile: Profile? = nil) throws -> LaunchCredential {
        try InferenceTokenPolicy.launchCredential(profile: profile ?? self.profile, claudeArguments: arguments,
                                                  requireToken: required, mint: { _ in try read() }, now: now)
    }

    private func assertRequired(_ read: @escaping () throws -> MintToken?, arguments: [String] = [],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decide(read, required: true, arguments: arguments), file: file, line: line) { error in
            XCTAssertEqual(error as? InferenceTokenPolicyError, .tokenRequired("work"), file: file, line: line)
        }
    }

    func testPolicyOffKeepsTheExistingFallbacks() throws {
        XCTAssertEqual(try decide({ nil }, required: false), .profileLogin)
        XCTAssertEqual(try decide({ self.browser(expiresIn: 3600) }, required: false), .inferenceToken("fixture-browser-token"))
        XCTAssertEqual(try decide({ try self.pasted(expiresIn: nil) }, required: false), .inferenceToken(pastedValue))
        XCTAssertEqual(try decide({ self.browser(expiresIn: -1) }, required: false), .profileLogin)
        XCTAssertThrowsError(try decide({ try self.pasted(expiresIn: -1) }, required: false)) {
            XCTAssertEqual($0 as? MintTokenError, .tokenExpired)
        }
        XCTAssertThrowsError(try decide({ throw MintTokenError.keychainUnavailable }, required: false)) {
            XCTAssertEqual($0 as? MintTokenError, .keychainUnavailable)
        }
        XCTAssertEqual(try decide({ self.browser(expiresIn: 3600) }, required: false, arguments: ["setup-token"]),
                       .inferenceToken("fixture-browser-token"))
    }

    func testPolicyOnLaunchesWithAValidToken() throws {
        XCTAssertEqual(try decide({ self.browser(expiresIn: 3600) }, required: true), .inferenceToken("fixture-browser-token"))
        XCTAssertEqual(try decide({ try self.pasted(expiresIn: nil) }, required: true), .inferenceToken(pastedValue))
        XCTAssertEqual(try decide({ try self.pasted(expiresIn: 60) }, required: true, arguments: ["--resume", "abc"]),
                       .inferenceToken(pastedValue))
    }

    func testPolicyOnRefusesAMissingExpiredOrUnreadableToken() {
        assertRequired({ nil })
        assertRequired({ self.browser(expiresIn: 0) })
        assertRequired({ self.browser(expiresIn: -3600) })
        assertRequired({ try self.pasted(expiresIn: -1) })
        assertRequired({ throw MintTokenError.keychainUnavailable })
        assertRequired({ throw MintTokenError.accountMismatch })
        assertRequired({ throw MintTokenError.invalidResponse })
    }

    func testOnlySetupTokenAsTheFirstArgumentRunsWithoutAToken() throws {
        for arguments in [["setup-token"], ["setup-token", "--help"]] {
            XCTAssertEqual(try decide({ XCTFail("setup-token must not need a token"); return nil }, required: true, arguments: arguments),
                           .profileLogin)
        }
        XCTAssertEqual(try decide({ throw MintTokenError.keychainUnavailable }, required: true, arguments: ["setup-token"]), .profileLogin)
        for arguments in [["--print", "setup-token"], ["setup-tokens"], ["Setup-token"], [" setup-token"]] {
            assertRequired({ nil }, arguments: arguments)
        }
    }

    func testAPIKeyProfilesAreUnaffectedAndReadNoToken() throws {
        for required in [false, true] {
            XCTAssertEqual(try decide({ XCTFail("An API-key profile must not read an inference token"); return nil },
                                      required: required, profile: apiKeyProfile), .consoleAPIKey)
        }
    }

    func testRequiredMessageNamesHowToCreateAndSaveAToken() {
        XCTAssertEqual(InferenceTokenPolicyError.tokenRequired("work").localizedDescription,
                       "work has no valid inference token and Claudock requires one. Create one with 'claudock run work -- setup-token', then 'pbpaste | claudock profile set-token work'.")
    }
}

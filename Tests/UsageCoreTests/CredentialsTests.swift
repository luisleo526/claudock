import Foundation
import XCTest
@testable import UsageCore

final class CredentialsTests: XCTestCase {
    private func parse(_ json: String) throws -> Credentials {
        try Credentials.parse(Data(json.utf8))
    }

    func testCredentialExpiryUsesEpochMillisecondsAndKeepsFractionalSeconds() throws {
        let credentials = try parse(#"""
        {"claudeAiOauth":{
          "accessToken":"fixture-token-not-real",
          "expiresAt":1789000000123,
          "subscriptionType":"max"
        }}
        """#)
        XCTAssertEqual(try XCTUnwrap(credentials.expiresAt).timeIntervalSince1970, 1_789_000_000.123, accuracy: 0.001)
        XCTAssertEqual(credentials.plan, "max")
        XCTAssertEqual(credentials.accessToken, "fixture-token-not-real")
    }

    func testCredentialWithoutExpiryDoesNotInventExpiration() throws {
        for suffix in ["", #", "expiresAt":null"#] {
            let credentials = try parse("{\"claudeAiOauth\":{\"accessToken\":\"fixture-token-not-real\"\(suffix)}}")
            XCTAssertNil(credentials.expiresAt)
            XCTAssertNil(credentials.plan)
        }
    }

    func testMalformedExpiryCannotBecomeBooleanEpochOrAnInfiniteDate() throws {
        for value in ["false", "true", "-1", "0", #""1789000000123""#] {
            let credentials = try parse("{\"claudeAiOauth\":{\"accessToken\":\"fixture-token-not-real\",\"expiresAt\":\(value)}}")
            XCTAssertNil(credentials.expiresAt, value)
        }
        // JSON parsers can reject nonfinite literals before credential decoding.
        if let credentials = try? parse(#"{"claudeAiOauth":{"accessToken":"fixture-token-not-real","expiresAt":1e309}}"#) {
            XCTAssertNil(credentials.expiresAt)
        }
    }

    func testMissingOrMalformedOAuthTokenFailsWithNoCredentials() {
        for payload in ["{", "null", "[]", "{}", #"{"claudeAiOauth":null}"#,
                        #"{"claudeAiOauth":{"accessToken":""}}"#,
                        #"{"claudeAiOauth":{"accessToken":false}}"#,
                        #"{"claudeAiOauth":{"refreshToken":"fixture-refresh-only"}}"#,
                        #"{"accessToken":"fixture-at-wrong-level"}"#] {
            XCTAssertThrowsError(try parse(payload), payload) {
                XCTAssertEqual($0 as? MonitorError, .noCredentials)
            }
        }
    }

    func testServiceHashMatchesIndependentKnownFixtures() {
        let fixtures = [
            ("/Users/tester/.claude-work", "c4394a73"),
            ("/Users/tester/.claude-personal", "de0a6064"),
            ("/Users/tester/Account With Spaces", "177562ba"),
            ("/Users/tester/.claude", "ee16a9f4")
        ]
        for (path, hash) in fixtures {
            let profile = Profile(command: "claude-fixture", configDirectory: path)
            XCTAssertEqual(CredentialStore.serviceName(for: profile), "Claude Code-credentials-" + hash)
            XCTAssertNotEqual(CredentialStore.serviceName(for: profile), "Claude Code-credentials")
        }
    }

    func testServiceIsBoundToDirectoryRatherThanProfileDisplayName() {
        let first = Profile(command: "claude-first", configDirectory: "/Users/tester/.claude-work")
        let alias = Profile(command: "claude-alias", configDirectory: "/Users/tester/.claude-work")
        let other = Profile(command: "claude-other", configDirectory: "/Users/tester/.claude-personal")
        XCTAssertEqual(CredentialStore.serviceName(for: first), CredentialStore.serviceName(for: alias))
        XCTAssertNotEqual(CredentialStore.serviceName(for: first), CredentialStore.serviceName(for: other))
    }

    func testServiceHashUsesNFCAndDoesNotCanonicalizeThePath() {
        let composed = Profile(command: "claude-accent", configDirectory: "/Users/tester/.claude-caf\u{00E9}")
        let decomposed = Profile(command: "claude-accent", configDirectory: "/Users/tester/.claude-cafe\u{0301}")
        XCTAssertEqual(CredentialStore.serviceName(for: composed), "Claude Code-credentials-7c53806c")
        XCTAssertEqual(CredentialStore.serviceName(for: composed), CredentialStore.serviceName(for: decomposed))

        let plain = Profile(command: "claude-work", configDirectory: "/Users/tester/.claude-work")
        let trailingSlash = Profile(command: "claude-work", configDirectory: "/Users/tester/.claude-work/")
        XCTAssertEqual(CredentialStore.serviceName(for: trailingSlash), "Claude Code-credentials-ba2961b5")
        XCTAssertNotEqual(CredentialStore.serviceName(for: plain), CredentialStore.serviceName(for: trailingSlash))
    }

    func testDefaultProfileUsesTheUnsuffixedService() {
        let profile = Profile(command: "claude", configDirectory: "/Users/tester/.claude")
        XCTAssertEqual(CredentialStore.serviceName(for: profile), "Claude Code-credentials")
    }

    func testUnresolvedProfileFailsBeforeAnyKeychainOrFileRead() {
        let profile = Profile(command: "claude-unresolved", configDirectory: "", discoveryNote: "Cannot resolve wrapper")
        XCTAssertThrowsError(try CredentialStore.read(profile: profile)) {
            XCTAssertEqual($0 as? MonitorError, .noCredentials)
        }
    }
}

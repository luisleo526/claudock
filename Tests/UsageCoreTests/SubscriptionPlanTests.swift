import Foundation
import XCTest
@testable import UsageCore

final class SubscriptionPlanTests: XCTestCase {
    func testVerifiedMaxRateTiersProduceDistinctLabels() {
        XCTAssertEqual(SubscriptionPlan(subscriptionType: "max", rateLimitTier: "default_claude_max_5x"), .max5x)
        XCTAssertEqual(SubscriptionPlan(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"), .max20x)
        XCTAssertEqual(SubscriptionPlan.max5x.displayName, "Max 5×")
        XCTAssertEqual(SubscriptionPlan.max20x.displayName, "Max 20×")
    }

    func testTeamPremiumUsesDeclaredTeamFamilyAndVerifiedRate() {
        let plan = SubscriptionPlan(subscriptionType: "team", rateLimitTier: "default_claude_max_5x", seatTier: "team_tier_1")
        XCTAssertEqual(plan, .teamPremium)
        XCTAssertEqual(plan.displayName, "Team Premium")
        XCTAssertNotEqual(plan, .max5x)
    }

    func testUnknownSubtypeIsNotGuessedFromSeatOrRateNames() {
        for tier in [nil, "", "default_raven", "default_claude_max_20x", "custom_team_standard"] {
            for seat in [nil, "team_tier_0", "team_tier_1", "standard", "premium"] {
                XCTAssertEqual(SubscriptionPlan(subscriptionType: "team", rateLimitTier: tier, seatTier: seat), .teamUnknown)
            }
        }
        for tier in [nil, "default_claude_ai", "max_20x", "custom_20x"] {
            XCTAssertEqual(SubscriptionPlan(subscriptionType: "max", rateLimitTier: tier), .maxUnknown)
        }
        XCTAssertEqual(SubscriptionPlan.teamUnknown.displayName, "Team (tier unknown)")
        XCTAssertEqual(SubscriptionPlan.maxUnknown.displayName, "Max (tier unknown)")
    }

    func testRateTierDoesNotOverrideDeclaredSubscriptionFamily() {
        XCTAssertEqual(SubscriptionPlan(subscriptionType: "pro", rateLimitTier: "default_claude_max_20x"), .pro)
        XCTAssertEqual(SubscriptionPlan(subscriptionType: "enterprise", rateLimitTier: "default_claude_max_5x"), .enterprise)
        for family in [nil, "", "future_subscription", "fixture-unrecognized-value"] {
            let plan = SubscriptionPlan(subscriptionType: family, rateLimitTier: "default_claude_max_20x")
            XCTAssertEqual(plan, .unknown)
            XCTAssertEqual(plan.displayName, "Plan unknown")
        }
    }

    func testCredentialParserRetainsPlanAndRefreshMetadata() throws {
        let data = Data(#"""
        {"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh",
          "expiresAt":1789000000000,"refreshTokenExpiresAt":1789990000000,
          "subscriptionType":"team","rateLimitTier":"default_claude_max_5x","seatTier":"team_tier_1",
          "scopes":["user:profile","user:inference"],"clientId":"fixture-client"}}
        """#.utf8)
        let credentials = try Credentials.parse(data)
        XCTAssertEqual(credentials.plan, "team")
        XCTAssertEqual(credentials.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(credentials.seatTier, "team_tier_1")
        XCTAssertEqual(credentials.subscriptionPlan, .teamPremium)
        XCTAssertEqual(credentials.refreshToken, "fixture-refresh")
        XCTAssertNotNil(credentials.refreshTokenExpiresAt)
        XCTAssertEqual(credentials.scopes, ["user:profile", "user:inference"])
        XCTAssertEqual(credentials.clientID, "fixture-client")
    }

    func testMissingAndMalformedTierFieldsRemainUnknown() throws {
        for value in ["null", "false", "123", "[]", "{}"] {
            let data = Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-access\",\"subscriptionType\":\"max\",\"rateLimitTier\":\(value),\"seatTier\":\(value)}}".utf8)
            let credentials = try Credentials.parse(data)
            XCTAssertNil(credentials.rateLimitTier)
            XCTAssertNil(credentials.seatTier)
            XCTAssertEqual(credentials.subscriptionPlan, .maxUnknown)
        }
        let legacy = Credentials(accessToken: "fixture-access", expiresAt: nil, plan: "max")
        XCTAssertNil(legacy.rateLimitTier)
        XCTAssertNil(legacy.seatTier)
        XCTAssertEqual(legacy.subscriptionPlan, .maxUnknown)
    }

    func testMetadataDoesNotAlterCredentialTokenIdentity() {
        let first = Credentials(accessToken: "fixture-access", expiresAt: nil, plan: "max", refreshToken: "fixture-refresh",
                                rateLimitTier: "default_claude_max_5x")
        let updated = Credentials(accessToken: "fixture-access", expiresAt: nil, plan: "max", refreshToken: "fixture-refresh",
                                  rateLimitTier: "default_claude_max_20x")
        XCTAssertTrue(first.hasSameTokens(as: updated))
        XCTAssertNotEqual(first.subscriptionPlan, updated.subscriptionPlan)
    }

    func testRenewalMergePreservesPlanMetadataAndUnrelatedFields() throws {
        let original = Data(#"""
        {"claudeAiOauth":{"accessToken":"fixture-old","refreshToken":"fixture-refresh",
          "subscriptionType":"team","rateLimitTier":"default_claude_max_5x","seatTier":"team_tier_1",
          "scopes":["user:profile","user:inference"]},"unrelated":{"keep":true}}
        """#.utf8)
        let response = Data(#"{"access_token":"fixture-new","refresh_token":"fixture-rotated","expires_in":3600}"#.utf8)
        let renewal = try OAuthRefreshResult.parse(response, previous: Credentials.parse(original), now: Date(timeIntervalSince1970: 1_789_000_000))
        let merged = try renewal.merging(into: original)
        let credentials = try Credentials.parse(merged)
        XCTAssertEqual(credentials.accessToken, "fixture-new")
        XCTAssertEqual(credentials.refreshToken, "fixture-rotated")
        XCTAssertEqual(credentials.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(credentials.seatTier, "team_tier_1")
        XCTAssertEqual(credentials.subscriptionPlan, .teamPremium)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual((root["unrelated"] as? [String: Bool])?["keep"], true)
    }
}

import Foundation
import XCTest
@testable import UsageCore

/// Console-login profiles: Claude Code's own `auth login --console` keeps a managed API key in Keychain,
/// which Claudock only checks for, and records the Console organization in `.claude.json`.
final class ConsoleLoginTests: XCTestCase {
    private let profile = Profile(command: "claude-team", configDirectory: "/synthetic/console-login", registryID: UUID().uuidString,
                                  managed: true, authKind: .consoleLogin)

    // MARK: Keychain service

    func testManagedKeyServiceIsClaudeCodePlusTheConfigFolderHash() {
        // sha256("/synthetic/console-login")[:8], as Claude Code 2.1.295 derives it for a CLAUDE_CONFIG_DIR.
        XCTAssertEqual(ConsoleLogin.keychainService(for: profile), "Claude Code-e82692d0")
        let account = Profile(command: "claude-billing",
                              configDirectory: "/Users/demo/Library/Application Support/Claudock/accounts/00000000-0000-0000-0000-000000000000/claude",
                              managed: true, authKind: .consoleLogin)
        XCTAssertEqual(ConsoleLogin.keychainService(for: account), "Claude Code-0e85c2d3")
    }

    func testManagedKeyServiceSitsBesideTheOAuthCredentialsOfTheSameFolder() {
        XCTAssertEqual("Claude Code-credentials" + ConsoleLogin.keychainService(for: profile).dropFirst("Claude Code".count),
                       CredentialStore.serviceName(for: profile))
    }

    func testDefaultProfileUsesClaudeCodesPlainService() {
        // Claude Code adds no hash when CLAUDE_CONFIG_DIR is unset, which is how the default profile launches.
        XCTAssertEqual(ConsoleLogin.keychainService(for: Profile(command: "claude", configDirectory: "/Users/demo/.claude")), "Claude Code")
    }

    func testManagedKeyServiceHashesTheNFCPathAndSurvivesRename() {
        let composed = Profile(command: "claude-a", configDirectory: "/synthetic/caf\u{E9}", managed: true, authKind: .consoleLogin)
        let decomposed = Profile(command: "claude-b", configDirectory: "/synthetic/cafe\u{301}", managed: true, authKind: .consoleLogin)
        XCTAssertEqual(ConsoleLogin.keychainService(for: composed), "Claude Code-fdc632a8")
        XCTAssertEqual(ConsoleLogin.keychainService(for: decomposed), "Claude Code-fdc632a8")
        let renamed = Profile(command: "claude-renamed", configDirectory: profile.configDirectory, managed: true, authKind: .consoleLogin)
        XCTAssertEqual(ConsoleLogin.keychainService(for: renamed), ConsoleLogin.keychainService(for: profile))
    }

    // MARK: Sign-in status

    func testSignInStatusLooksUpAttributesWithoutReadingTheKey() throws {
        var commands: [[String]] = []
        XCTAssertTrue(try ConsoleLogin.isSignedIn(profile: profile, security: { commands.append($0); return 0 }))
        XCTAssertFalse(try ConsoleLogin.isSignedIn(profile: profile, security: { commands.append($0); return 44 }))
        let lookup = ["find-generic-password", "-a", NSUserName(), "-s", "Claude Code-e82692d0"]
        XCTAssertEqual(commands, [lookup, lookup])
        XCTAssertFalse(commands.joined().contains("-w"))
    }

    func testAnUnreadableKeychainIsAnErrorNeverSignedOut() {
        for failure: Int32 in [1, 36, 51, 15] {
            XCTAssertThrowsError(try ConsoleLogin.isSignedIn(profile: profile, security: { _ in failure })) {
                XCTAssertEqual($0 as? ConsoleLoginError, .keychainUnavailable)
            }
        }
        XCTAssertThrowsError(try ConsoleLogin.isSignedIn(profile: profile, security: { _ in throw MonitorError.keychainLocked })) {
            XCTAssertEqual($0 as? ConsoleLoginError, .keychainUnavailable)
        }
    }

    func testAnAPIKeyProfileCanBeCheckedBeforeItSwitchesToItsConsoleSignIn() throws {
        let apiKey = Profile(command: profile.command, configDirectory: profile.configDirectory, registryID: profile.registryID,
                             managed: true, authKind: .apiKey)
        XCTAssertTrue(try ConsoleLogin.isSignedIn(profile: apiKey, security: { _ in 0 }))
    }

    func testOnlyManagedConsoleProfilesReachClaudeCodesItem() {
        let unsupported = [Profile(command: "claude-work", configDirectory: "/synthetic/work", managed: true),
                           Profile(command: "claude", configDirectory: "/synthetic/default"),
                           Profile(command: "claude-imported", configDirectory: "/synthetic/imported", authKind: .consoleLogin),
                           Profile(command: "claude-unresolved", configDirectory: "", discoveryNote: "Unresolved", managed: true, authKind: .consoleLogin),
                           Profile(command: "claude-relative", configDirectory: "relative", managed: true, authKind: .consoleLogin)]
        for candidate in unsupported {
            XCTAssertThrowsError(try ConsoleLogin.isSignedIn(profile: candidate, security: { _ in XCTFail("Unsupported profile reached Keychain"); return 0 })) {
                XCTAssertEqual($0 as? ConsoleLoginError, .unsupportedProfile)
            }
        }
    }

    func testMessagesNameTheFix() {
        XCTAssertTrue(ConsoleLoginError.keychainUnavailable.localizedDescription.contains("Unlock"))
        XCTAssertFalse(ConsoleLoginError.unsupportedProfile.localizedDescription.isEmpty)
    }

    // MARK: Organization

    private func state(_ account: Any?) throws -> Data {
        var root: [String: Any] = ["numStartups": 2]
        if let account { root["oauthAccount"] = account }
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testOrganizationNameComesFromTheOAuthAccount() throws {
        let data = try state(["organizationName": "Demo Labs LLC", "billingType": "prepaid", "emailAddress": "demo@example.invalid"])
        XCTAssertEqual(ConsoleLogin.organizationName(claudeState: data), "Demo Labs LLC")
    }

    func testMissingOrMalformedOrganizationIsNil() throws {
        for data in [try state(nil), try state(["billingType": "prepaid"]), try state(["organizationName": 42]),
                     try state(["organizationName": "   "]), try state("not an object"), Data("not json".utf8)] {
            XCTAssertNil(ConsoleLogin.organizationName(claudeState: data))
        }
    }

    func testOrganizationNameIsUntrustedDisplayText() throws {
        let hostile = "Evil\u{202E}Corp\n\tLLC\u{0}  [link](https://example.invalid) **bold**"
        let name = try XCTUnwrap(ConsoleLogin.organizationName(claudeState: try state(["organizationName": hostile])))
        XCTAssertFalse(name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
        XCTAssertEqual(name, "Evil Corp LLC [link](https://example.invalid) **bold**")
        let long = try XCTUnwrap(ConsoleLogin.organizationName(claudeState: try state(["organizationName": String(repeating: "x", count: 500)])))
        XCTAssertEqual(long.count, 80)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testOrganizationIsReadFromTheProfilesOwnClaudeJSON() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-console-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = Profile(command: "claude-team", configDirectory: folder.path, managed: true, authKind: .consoleLogin)
        XCTAssertNil(ConsoleLogin.organizationName(profile: profile))
        try state(["organizationName": "Folder Org"]).write(to: folder.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ConsoleLogin.organizationName(profile: profile), "Folder Org")
    }

    // MARK: Launch, tokens, and credit

    func testLaunchesUseTheConsoleSignInWhateverTheTokenPolicy() throws {
        for required in [false, true] {
            for arguments in [[], ["--resume"], ["setup-token"]] {
                XCTAssertEqual(try InferenceTokenPolicy.launchCredential(
                    profile: profile, claudeArguments: arguments, signIn: false, requireToken: required,
                    mint: { _ in XCTFail("A Console-login profile must not read an inference token"); return nil }), .consoleLogin)
            }
            XCTAssertEqual(try InferenceTokenPolicy.launchCredential(
                profile: profile, claudeArguments: ["auth", "login", "--console"], signIn: true, requireToken: required,
                mint: { _ in XCTFail("Sign-in must not read an inference token"); return nil }), .profileLogin)
        }
    }

    func testConsoleLoginProfilesNeverUseInferenceTokensOrClaudockAPIKeys() throws {
        XCTAssertThrowsError(try MintTokenStore.importToken(raw: "sk-ant-oat01-" + "fixture_imported_token", profile: profile,
                                                            identity: { _ in throw MintTokenError.loginRequired },
                                                            save: { _, _ in XCTFail("A Console-login profile must not store an inference token") })) {
            XCTAssertEqual($0 as? MintTokenError, .unsupportedProfile)
        }
        XCTAssertThrowsError(try APIKeyStore.read(profile: profile, securityRead: { _ in XCTFail("A Console-login profile has no Claudock key"); return (Data(), 44) })) {
            XCTAssertEqual($0 as? APIKeyError, .unsupportedProfile)
        }
    }

    func testConsoleCreditIsAvailableToConsoleLoginProfiles() throws {
        XCTAssertTrue(ProfileAuthKind.consoleLogin.isConsole)
        XCTAssertTrue(ProfileAuthKind.apiKey.isConsole)
        XCTAssertFalse(ProfileAuthKind.subscription.isConsole)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-console-credit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credit = try APICreditStore.setBalance(25, profile: profile, home: home.path, now: now)
        XCTAssertEqual(credit.usageWindow, "Credit · $25.00 of $25.00 left")
        XCTAssertEqual(try APICreditStore.status(profileID: profile.id, home: home.path), credit)
        let subscription = Profile(command: "claude-work", configDirectory: "/synthetic/work", registryID: UUID().uuidString, managed: true)
        XCTAssertThrowsError(try APICreditStore.setBalance(10, profile: subscription, home: home.path, now: now)) {
            XCTAssertEqual($0 as? APICreditError, .subscriptionProfile("work"))
        }
        XCTAssertNil(try APICreditStore.status(profileID: subscription.id, home: home.path))
        XCTAssertTrue(APICreditError.subscriptionProfile("work").localizedDescription.contains("--console"))
    }
}

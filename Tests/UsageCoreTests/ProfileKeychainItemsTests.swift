import CryptoKit
import XCTest
@testable import UsageCore

final class ProfileKeychainItemsTests: XCTestCase {
    private let folder = "/synthetic/claudock-profile"
    private var subscription: Profile { Profile(command: "claude-fixture", configDirectory: folder, managed: true) }
    private var apiKey: Profile { Profile(command: "claude-fixture", configDirectory: folder, managed: true, authKind: .apiKey) }
    private var consoleLogin: Profile { Profile(command: "claude-fixture", configDirectory: folder, managed: true, authKind: .consoleLogin) }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func hash8(_ path: String) -> String { String(sha256(path.precomposedStringWithCanonicalMapping).prefix(8)) }

    func testItemsListEveryServiceAProfileCanLeaveInTheOrderTheyAreShown() {
        let items = ProfileKeychainItems.items(for: subscription)
        let login = "Claude Code-credentials-" + hash8(folder)
        XCTAssertEqual(items.map(\.kind), [.login, .consoleKey, .inferenceToken, .apiKey])
        XCTAssertEqual(items.map(\.service), [login, "Claude Code-" + hash8(folder),
                                              "Claudock-inference-" + sha256(login), "Claudock-apikey-" + sha256(login)])
        XCTAssertEqual(items.map(\.service), [CredentialStore.serviceName(for: subscription), ConsoleLogin.keychainService(for: subscription),
                                              MintTokenStore.serviceName(for: subscription), APIKeyStore.serviceName(for: subscription)])
        XCTAssertEqual(Set(items.map(\.service)).count, 4)
    }

    func testTheDefaultProfileKeepsClaudeCodesPlainServiceNames() {
        let items = ProfileKeychainItems.items(for: Profile(command: "claude", configDirectory: "/synthetic/default"))
        XCTAssertEqual(items.map(\.service), ["Claude Code-credentials", "Claude Code", "Claudock-inference-" + sha256("Claude Code-credentials"),
                                              "Claudock-apikey-" + sha256("Claude Code-credentials")])
    }

    func testEveryAuthKindAndANewNameListTheSameServicesBecauseTheyFollowTheConfigFolder() {
        let expected = ProfileKeychainItems.items(for: subscription).map(\.service)
        XCTAssertEqual(ProfileKeychainItems.items(for: apiKey).map(\.service), expected)
        XCTAssertEqual(ProfileKeychainItems.items(for: consoleLogin).map(\.service), expected)
        let renamed = Profile(command: "claude-renamed", configDirectory: folder, managed: true)
        XCTAssertEqual(ProfileKeychainItems.items(for: renamed).map(\.service), expected)
        let other = Profile(command: "claude-fixture", configDirectory: "/synthetic/other-profile", managed: true)
        XCTAssertTrue(Set(ProfileKeychainItems.items(for: other).map(\.service)).isDisjoint(with: expected))
    }

    func testProfilesWithoutAKnownConfigFolderHaveNoItemsAndNeverAskKeychain() {
        let unusable = [Profile(command: "claude-unresolved", configDirectory: "", discoveryNote: "Unresolved", managed: true),
                        Profile(command: "claude-relative", configDirectory: "relative/folder", managed: true),
                        Profile(command: "claude-nul", configDirectory: "/synthetic/a\0b", managed: true),
                        Profile(command: "claude-vertex", configDirectory: folder, isVertex: true)]
        for profile in unusable {
            XCTAssertEqual(ProfileKeychainItems.items(for: profile), [], profile.command)
            let lookup = ProfileKeychainItems.lookup(for: profile, security: { _ in XCTFail("Unusable profile reached Keychain"); return 44 })
            XCTAssertEqual(lookup, ProfileKeychainLookup(existing: [], unchecked: []))
        }
    }

    func testEachKindHasItsOwnTitleAndTheDeleteCommandOfItsService() {
        let items = ProfileKeychainItems.items(for: subscription)
        XCTAssertEqual(Set(items.map(\.title)).count, 4)
        XCTAssertTrue(items.allSatisfy { !$0.title.isEmpty })
        // Claude Code keeps a folder's login in one item, whoever else starts Claude with that folder.
        XCTAssertTrue(try XCTUnwrap(items.first { $0.kind == .login }).title.contains("config folder"))
        for item in items { XCTAssertEqual(item.deleteCommand, "security delete-generic-password -s '" + item.service + "'") }
    }

    func testDeleteCommandQuotesTheServiceForTheShell() {
        XCTAssertEqual(ProfileKeychainItems.deleteCommand(service: "Claude Code-credentials-1a2b3c4d"),
                       "security delete-generic-password -s 'Claude Code-credentials-1a2b3c4d'")
        XCTAssertEqual(ProfileKeychainItems.deleteCommand(service: "Claude Code"), "security delete-generic-password -s 'Claude Code'")
        XCTAssertEqual(ProfileKeychainItems.deleteCommand(service: "it's $(touch x) `y`"),
                       "security delete-generic-password -s 'it'\\''s $(touch x) `y`'")
    }

    func testLookupAsksForAttributesOnlyAndKeepsTheItemsThatExistInOrder() {
        let items = ProfileKeychainItems.items(for: subscription)
        let present: Set<String> = [items[0].service, items[2].service]
        var commands: [[String]] = []
        let lookup = ProfileKeychainItems.lookup(for: subscription, security: { arguments in
            commands.append(arguments)
            return present.contains(arguments.last ?? "") ? 0 : 44
        })
        XCTAssertEqual(commands, items.map { ["find-generic-password", "-a", NSUserName(), "-s", $0.service] })
        XCTAssertFalse(commands.joined().contains("-w") || commands.joined().contains("-g"), "A lookup must never ask for the secret")
        XCTAssertEqual(lookup.existing, [items[0], items[2]])
        XCTAssertEqual(lookup.unchecked, [])
    }

    func testLookupFindsNothingWhenNoItemExistsAfterAskingAboutEachService() {
        var asked = 0
        XCTAssertEqual(ProfileKeychainItems.lookup(for: apiKey, security: { _ in asked += 1; return 44 }),
                       ProfileKeychainLookup(existing: [], unchecked: []))
        XCTAssertEqual(asked, 4)
    }

    func testAnItemKeychainCouldNotBeAskedAboutIsNeitherListedAsExistingNorDropped() {
        let items = ProfileKeychainItems.items(for: subscription)
        var answers: [Int32?] = [0, 36, nil, 44]
        let lookup = ProfileKeychainItems.lookup(for: subscription, security: { _ in
            guard let status = answers.removeFirst() else { throw MonitorError.keychainLocked }
            return status
        })
        XCTAssertEqual(lookup.existing, [items[0]])
        XCTAssertEqual(lookup.unchecked, [items[1], items[2]])
    }
}

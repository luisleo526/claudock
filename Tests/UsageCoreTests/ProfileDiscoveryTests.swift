import Foundation
import XCTest
@testable import UsageCore

final class ProfileDiscoveryTests: XCTestCase {
    private func withHome(_ action: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try action(home)
    }

    private func write(_ text: String, _ path: String, home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func profiles(_ home: URL) -> [String: Profile] {
        Dictionary(uniqueKeysWithValues: ProfileDiscovery.discover(home: home.path).map { ($0.command, $0) })
    }

    func testDefaultAndNativeFunctionsAcrossLiteralSources() throws {
        try withHome { home in
            try write(#"source "$HOME/.config/zsh/profiles.zsh""#, ".zshrc", home: home)
            try write(#"""
            claude-personal() { _claude-native "$HOME/.claude-personal" "$@"; }
            function claude-work {
              export CLAUDE_CONFIG_DIR="${HOME}/.claude-work"
              claude "$@"
            }
            source 'nested/extra.zsh'
            """#, ".config/zsh/profiles.zsh", home: home)
            try write(#"claude-spaces() { _claude-native "$HOME/Account With Spaces" "$@"; }"#, ".config/zsh/nested/extra.zsh", home: home)
            let found = profiles(home)
            XCTAssertEqual(Set(found.keys), ["claude", "claude-personal", "claude-work", "claude-spaces"])
            XCTAssertEqual(found["claude"]?.configDirectory, home.appendingPathComponent(".claude").path)
            XCTAssertEqual(found["claude-personal"]?.configDirectory, home.appendingPathComponent(".claude-personal").path)
            XCTAssertEqual(found["claude-work"]?.configDirectory, home.appendingPathComponent(".claude-work").path)
            XCTAssertEqual(found["claude-spaces"]?.configDirectory, home.appendingPathComponent("Account With Spaces").path)
        }
    }

    func testAliasesQuotesCommentsAndUnalias() throws {
        try withHome { home in
            try write(#"""
            # alias claude-backup='CLAUDE_CONFIG_DIR="$HOME/backup" claude'
            alias claude-personal='CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude'
            alias claude-tilde='CLAUDE_CONFIG_DIR=~/.claude-tilde claude'
            alias claude-removed='CLAUDE_CONFIG_DIR="$HOME/.removed" claude'
            unalias claude-removed 2>/dev/null || true
            echo alias claude-echo='CLAUDE_CONFIG_DIR=/invalid claude'
            echo 'claude-string() { _claude-native /invalid; }'
            claude-hash() { _claude-native "$HOME/account#one" "$@"; } # inline comment
            """#, ".zshrc", home: home)
            let found = profiles(home)
            XCTAssertEqual(Set(found.keys), ["claude", "claude-personal", "claude-tilde", "claude-hash"])
            XCTAssertEqual(found["claude-personal"]?.configDirectory, home.appendingPathComponent(".claude-personal").path)
            XCTAssertEqual(found["claude-tilde"]?.configDirectory, home.appendingPathComponent(".claude-tilde").path)
            XCTAssertEqual(found["claude-hash"]?.configDirectory, home.appendingPathComponent("account#one").path)
        }
    }

    func testDynamicAndAmbiguousWrappersNeverUseDefaultCredentials() throws {
        try withHome { home in
            try write(#"""
            claude-variable() { export CLAUDE_CONFIG_DIR="$PROFILE_DIR"; claude "$@"; }
            claude-command() { _claude-native "$(touch /tmp/do-not-execute)" "$@"; }
            claude-unknown() { custom-helper personal "$@"; }
            claude-single() { _claude-native '$HOME/.not-expanded' "$@"; }
            claude-prefix() { _claude-native "$HOMESUFFIX/.not-home" "$@"; }
            claude-multiple() { export CLAUDE_CONFIG_DIR=/one; export CLAUDE_CONFIG_DIR=/two; claude; }
            alias claude-dynamic='CLAUDE_CONFIG_DIR="$UNKNOWN" claude'
            """#, ".zshrc", home: home)
            let found = profiles(home)
            XCTAssertEqual(found.count, 8)
            for (command, profile) in found where command != "claude" {
                XCTAssertEqual(profile.configDirectory, "", command)
                XCTAssertNotNil(profile.discoveryNote, command)
            }
        }
    }

    func testCyclesSensitiveSourcesAndDynamicSourcesAreSkipped() throws {
        try withHome { home in
            try write(#"""
            source "$HOME/a.zsh"
            source "$HOME/private-env.zsh"
            source "$HOME/keys.zsh"
            source "$HOME/.env"
            source "$CONFIG/hidden.zsh"
            """#, ".zshrc", home: home)
            try write(#"""
            source "$HOME/.zshrc"
            claude-valid() { _claude-native "$HOME/.valid"; }
            """#, "a.zsh", home: home)
            for path in ["private-env.zsh", "keys.zsh", ".env", "hidden.zsh", ".zshrc.backup"] {
                try write("claude-hidden() { _claude-native /hidden; }", path, home: home)
            }
            XCTAssertEqual(Set(profiles(home).keys), ["claude", "claude-valid"])
        }
    }

    func testVertexSubshellAndStartupOrderDeduplicateCommands() throws {
        try withHome { home in
            try write("claude-work() { _claude-native /old; }", ".zshenv", home: home)
            try write("claude-work() { _claude-native /middle; }", ".zprofile", home: home)
            try write(#"""
            claude-work() { _claude-native "$HOME/.work"; }
            claude-vertex() {
              (
                export CLAUDE_CONFIG_DIR="$HOME/.vertex"
                export CLAUDE_CODE_USE_VERTEX=1
                claude "$@"
              )
            }
            """#, ".zshrc", home: home)
            let found = profiles(home)
            XCTAssertEqual(found.count, 3)
            XCTAssertEqual(found["claude-work"]?.configDirectory, home.appendingPathComponent(".work").path)
            XCTAssertEqual(found["claude-vertex"]?.isVertex, true)
            XCTAssertEqual(found["claude-vertex"]?.configDirectory, home.appendingPathComponent(".vertex").path)
            XCTAssertEqual(found["claude-work"]?.isVertex, false)
        }
    }

    func testHelpersAndHeredocsDoNotCreateStartupDeclarations() throws {
        try withHome { home in
            try write(#"""
            setup() {
              alias claude-nested='CLAUDE_CONFIG_DIR=/nested claude'
              source "$HOME/hidden.zsh"
            }
            cat <<'EXAMPLE'
            claude-heredoc() { _claude-native /hidden; }
            EXAMPLE
            cat <<< 'ordinary here string'
            claude-real() { _claude-native "$HOME/.real"; }
            """#, ".zshrc", home: home)
            try write("claude-sourced() { _claude-native /hidden; }", "hidden.zsh", home: home)
            XCTAssertEqual(Set(profiles(home).keys), ["claude", "claude-real"])
        }
    }

    func testMalformedDeclarationStaysUnresolvedAndDoesNotExposeItsBody() throws {
        try withHome { home in
            try write(#"""
            claude-broken() {
              export CLAUDE_CONFIG_DIR="$HOME/.broken"
              alias claude-nested='CLAUDE_CONFIG_DIR=/nested claude'
            """#, ".zshrc", home: home)
            let found = profiles(home)
            XCTAssertEqual(Set(found.keys), ["claude", "claude-broken"])
            XCTAssertEqual(found["claude-broken"]?.configDirectory, "")
        }
    }

    func testOversizedSourcesAreSkipped() throws {
        try withHome { home in
            try write("source large.zsh\nclaude-small() { _claude-native /small; }", ".zshrc", home: home)
            try write(String(repeating: "#", count: 524_289) + "\nclaude-large() { _claude-native /large; }", "large.zsh", home: home)
            XCTAssertEqual(Set(profiles(home).keys), ["claude", "claude-small"])
        }
    }

    func testConfigDirectoryKeepsExactExpandedPathForCredentialHashing() throws {
        try withHome { home in
            try write(#"claude-exact() { export CLAUDE_CONFIG_DIR="$HOME/foo/../bar"; claude; }"#, ".zshrc", home: home)
            XCTAssertEqual(profiles(home)["claude-exact"]?.configDirectory, home.path + "/foo/../bar")
        }
    }

    func testCredentialStorageOverridesAndGlobalDefaultOverridesFailClosed() throws {
        try withHome { home in
            try write(#"""
            export CLAUDE_CONFIG_DIR="$HOME/.global"
            claude-special() {
              export CLAUDE_CONFIG_DIR="$HOME/.special"
              export CLAUDE_SECURESTORAGE_CONFIG_DIR="$HOME/.storage"
              command claude
            }
            """#, ".zshrc", home: home)
            let found = profiles(home)
            XCTAssertEqual(found["claude"]?.configDirectory, "")
            XCTAssertNotNil(found["claude"]?.discoveryNote)
            XCTAssertEqual(found["claude-special"]?.configDirectory, "")
            XCTAssertNotNil(found["claude-special"]?.discoveryNote)
        }
    }

    func testPrintedAssignmentsAndHelperNamesCannotSelectCredentials() throws {
        try withHome { home in
            try write(#"""
            claude-example() { echo CLAUDE_CONFIG_DIR=/example; custom-helper "$@"; }
            claude-docs() { echo _claude-native /example; custom-helper "$@"; }
            """#, ".zshrc", home: home)
            for profile in profiles(home).values where profile.command != "claude" {
                XCTAssertEqual(profile.configDirectory, "")
                XCTAssertNotNil(profile.discoveryNote)
            }
        }
    }
}

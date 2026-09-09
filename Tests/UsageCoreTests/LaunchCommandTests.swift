import XCTest
@testable import UsageCore

final class LaunchCommandTests: XCTestCase {
    func testShellQuoteProtectsInjectionAndSpaces() {
        XCTAssertEqual(LaunchCommand.quote("a'b; $(touch /tmp/no)"), "'a'\\''b; $(touch /tmp/no)'")
    }
    func testDefaultProfileUnsetsConfigRatherThanHashingDefaultDirectory() throws {
        let text = try LaunchCommand.script(profile: Profile(command: "claude", configDirectory: "/Users/test/.claude"), executable: "/bin/claude", arguments: ["auth", "login"], workingDirectory: "/tmp")
        XCTAssertTrue(text.contains("-u 'CLAUDE_CONFIG_DIR'"))
        XCTAssertFalse(text.contains("CLAUDE_CONFIG_DIR="))
        XCTAssertTrue(text.contains("-u 'CLAUDE_CODE_OAUTH_TOKEN'"))
    }
    func testResumeForkUsesExactSourcePathWithoutCopyingOrInterpolating() throws {
        let path = "/Users/test/project '$()/session.jsonl"
        let text = try LaunchCommand.script(profile: Profile(command: "claude-work", configDirectory: "/Users/test/.claude-work"), executable: "/bin/claude", arguments: ["--resume", path, "--fork-session"], workingDirectory: "/tmp")
        XCTAssertTrue(text.contains("'--resume' " + LaunchCommand.quote(path) + " '--fork-session'"))
        XCTAssertTrue(text.contains("'CLAUDE_CONFIG_DIR=/Users/test/.claude-work'"))
        XCTAssertFalse(text.contains("cp "))
        XCTAssertFalse(text.contains("dangerously-skip-permissions"))
    }
    func testUnresolvedAndVertexProfilesCannotLaunch() {
        for profile in [Profile(command: "claude-x", configDirectory: ""), Profile(command: "claude-v", configDirectory: "/tmp/v", isVertex: true)] {
            XCTAssertThrowsError(try LaunchCommand.script(profile: profile, executable: "/bin/claude", arguments: [], workingDirectory: "/tmp"))
        }
    }
}

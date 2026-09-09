import XCTest
@testable import UsageCore

final class ClaudeExecutableTests: XCTestCase {
    func testSelectedExecutableIsSharedAndDirectoriesAreNotExecutables() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-executable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = root.appendingPathComponent("claude-test")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        XCTAssertEqual(ClaudeExecutable.find(environment: [:], customPath: program.path, home: root.path), program.path)
        XCTAssertNotEqual(ClaudeExecutable.find(environment: [:], customPath: root.path, home: root.path), root.path)
    }

    func testDirectExecEnvironmentPreservesAccountPathAndClearsProviders() throws {
        let profile = Profile(command: "claude-work", configDirectory: "/literal/path/../account's folder")
        let env = try LaunchCommand.environment(profile: profile, inherited: ["ANTHROPIC_API_KEY":"sentinel", "CLAUDE_CODE_USE_BEDROCK":"1", "CLAUDE_SECURESTORAGE_CONFIG_DIR":"wrong", "TERM":"xterm"])
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], profile.configDirectory)
        XCTAssertNil(env["ANTHROPIC_API_KEY"]); XCTAssertNil(env["CLAUDE_CODE_USE_BEDROCK"]); XCTAssertNil(env["CLAUDE_SECURESTORAGE_CONFIG_DIR"])
        XCTAssertEqual(env["TERM"], "xterm")
        let base = try LaunchCommand.environment(profile: Profile(command: "claude", configDirectory: "/user/.claude"), inherited: ["CLAUDE_CONFIG_DIR":"wrong"])
        XCTAssertNil(base["CLAUDE_CONFIG_DIR"])
    }
}

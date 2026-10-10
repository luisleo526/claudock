import Foundation
import XCTest
@testable import UsageCore

final class EndpointSessionTests: XCTestCase {
    private func requests(_ arguments: [String]) -> [EndpointSession.Request] { EndpointSession.requests(in: arguments) }

    func testContinueAndResumeAreReadTheWayClaudeCodeParsesThem() {
        XCTAssertEqual(requests([]), [])
        XCTAssertEqual(requests(["-p", "hi"]), [])
        for arguments in [["-c"], ["--continue"], ["-p", "-c", "hi"], ["-pc", "hi"], ["-cp", "hi"], ["--debug", "-c"], ["--debug", "api", "-c"],
                          ["-w", "tree", "-c"], ["--add-dir", "a", "b", "-c"]] {
            XCTAssertEqual(requests(arguments), [.latest], "\(arguments)")
        }
        for (arguments, value) in [(["--resume", "abc"], "abc"), (["-r", "abc"], "abc"), (["--resume=abc"], "abc"), (["-rabc"], "abc"),
                                   (["-pr", "abc"], "abc"), (["-rp"], "p"), (["--fork-session", "--resume", "/abs/x.jsonl"], "/abs/x.jsonl"),
                                   (["-p", "go on", "--resume", "11111111-2222-4333-8444-555555555555"], "11111111-2222-4333-8444-555555555555")] {
            XCTAssertEqual(requests(arguments), [.session(value)], "\(arguments)")
        }
        for arguments in [["--resume"], ["-r"], ["--resume", "-p", "hi"], ["-p", "hi", "-r"]] {
            XCTAssertEqual(requests(arguments), [.picker], "\(arguments)")
        }
        XCTAssertEqual(requests(["--resume", "abc", "--continue"]), [.session("abc"), .latest])
    }

    func testValuesOfOtherOptionsAndOperandsAreNotRequests() {
        for arguments in [["--append-system-prompt", "-c"], ["--append-system-prompt", "--resume"], ["-n", "-c"], ["-nc"], ["--model", "-c"],
                          ["--", "-c"], ["-p", "--", "--resume", "x"], ["--settings", "--continue"], ["-p", "c"], ["continue"],
                          ["--append-system-prompt=-c"]] {
            XCTAssertEqual(requests(arguments), [], "\(arguments)")
        }
    }

    private func transcript(_ lines: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-endpoint-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }

    private func assistant(_ model: String, sidechain: Bool = false) -> String {
        #"{"parentUuid":null,"isSidechain":\#(sidechain),"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"\#(model)","content":[{"type":"text","text":"fixture reply"}],"usage":{"input_tokens":3,"output_tokens":5}},"uuid":"\#(UUID().uuidString.lowercased())","timestamp":"2026-10-10T10:00:00.000Z"}"#
    }

    func testOnlyAssistantModelsOtherThanThePinnedOneAreReported() throws {
        let user = #"{"type":"user","message":{"role":"user","content":"please reply as \"model\":\"claude-user-text\" with type assistant"},"uuid":"u1"}"#
        // A tool result can hold JSON of its own; only an entry's own type and model count.
        let nested = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"{\"type\":\"assistant\",\"message\":{\"model\":\"claude-nested\"}}"}]},"toolUseResult":{"type":"assistant","message":{"model":"claude-tool-result"}}}"#
        let file = try transcript([#"{"type":"summary","summary":"fixture","leafUuid":"x"}"#, user, assistant("claude-opus-5-5"), nested,
                                   assistant("deepseek-flash"), assistant("<synthetic>"), assistant("claude-haiku-5-5", sidechain: true),
                                   assistant("claude-opus-5-5"), "not json", #"{"type":"assistant","message":{"content":[]}}"#, ""])
        XCTAssertEqual(try EndpointSession.otherModels(inTranscript: file, pinned: "deepseek-flash"), ["claude-haiku-5-5", "claude-opus-5-5"])
        let own = try transcript([user, assistant("deepseek-flash"), assistant("<synthetic>"), assistant("deepseek-flash")])
        XCTAssertEqual(try EndpointSession.otherModels(inTranscript: own, pinned: "deepseek-flash"), [])
        // The endpoint answers a [1m] request as the plain model, which Claude Code records; the request keeps the suffix.
        let wide = try transcript([assistant("deepseek-flash"), assistant("deepseek-flash[1m]")])
        XCTAssertEqual(try EndpointSession.otherModels(inTranscript: wide, pinned: "deepseek-flash[1m]"), [])
        XCTAssertEqual(try EndpointSession.otherModels(inTranscript: wide, pinned: "deepseek-flash"), [])
        // What Claude Code asked for counts too, when the endpoint names its model differently in the reply.
        let renamed = try transcript([#"{"type":"assistant","requestedModel":"deepseek-flash","message":{"model":"deepseek-v4-flash-0915"}}"#,
                                      #"{"type":"assistant","requestedModel":"claude-sonnet-5-5[1m]","message":{"model":"claude-sonnet-5-5"}}"#,
                                      #"{"type":"assistant","requestedModel":"claude-opus-5-5"}"#])
        XCTAssertEqual(try EndpointSession.otherModels(inTranscript: renamed, pinned: "deepseek-flash"), ["claude-opus-5-5", "claude-sonnet-5-5"])
    }

    func testLongLinesAndAFileWithoutAFinalNewlineAreRead() throws {
        let long = #"{"type":"user","message":{"role":"user","content":""# + String(repeating: "x", count: 3_000_000) + #""}}"#
        let file = try transcript([long, assistant("claude-sonnet-5-5")])
        let handle = try FileHandle(forUpdating: file)
        try handle.truncate(atOffset: try handle.seekToEnd() - 1)
        try handle.close()
        XCTAssertEqual(try EndpointSession.otherModels(inTranscript: file, pinned: "deepseek-flash"), ["claude-sonnet-5-5"])
    }

    func testAnUnreadableTranscriptIsAnError() {
        XCTAssertThrowsError(try EndpointSession.otherModels(inTranscript: URL(fileURLWithPath: "/synthetic/missing/session.jsonl"),
                                                             pinned: "deepseek-flash"))
    }

    func testProjectFoldersAreNamedTheWayClaudeCodeNamesThem() {
        // Measured with Claude Code 2.1.296: every UTF-16 unit that is not an ASCII letter or digit becomes "-", and a
        // name longer than 200 keeps its first 200 and adds "-" and the base-36 Java string hash of the path.
        let base = "/private/tmp/claudock-endpoint-research/B/homes/e1/work/"
        XCTAssertEqual(EndpointSession.projectFolderName(base + "plain"), "-private-tmp-claudock-endpoint-research-B-homes-e1-work-plain")
        XCTAssertEqual(EndpointSession.projectFolderName(base + "sp ace.dot_under"),
                       "-private-tmp-claudock-endpoint-research-B-homes-e1-work-sp-ace-dot-under")
        XCTAssertEqual(EndpointSession.projectFolderName(base + "caf\u{E9}-nfd"), "-private-tmp-claudock-endpoint-research-B-homes-e1-work-caf--nfd")
        XCTAssertEqual(EndpointSession.projectFolderName(base + "emoji\u{1F600}"), "-private-tmp-claudock-endpoint-research-B-homes-e1-work-emoji--")
        let long = base + String(repeating: "L", count: 120) + "/" + String(repeating: "M", count: 120)
        XCTAssertEqual(EndpointSession.projectFolderName(long), "-private-tmp-claudock-endpoint-research-B-homes-e1-work-LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL-MMMMMMMMMMMMMMMMMMMMMMM-xzr0hy")
        let exactly200 = "/" + String(repeating: "a", count: 199)
        XCTAssertEqual(EndpointSession.projectFolderName(exactly200), "-" + String(repeating: "a", count: 199))
    }

    // MARK: Which session a launch would load

    private struct Workspace {
        let root: URL
        let config: URL
        let work: URL
        var projects: URL { config.appendingPathComponent("projects") }
        /// The folder Claude Code keeps the working directory's sessions in.
        var folder: URL { projects.appendingPathComponent(EndpointSession.projectFolderName(canonical)) }
        var canonical: String {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            return realpath(work.path, &buffer).map { String(cString: $0) } ?? work.path
        }
    }

    private func workspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-endpoint-resume-\(UUID().uuidString)")
        let space = Workspace(root: root, config: root.appendingPathComponent("config"), work: root.appendingPathComponent("work"))
        try FileManager.default.createDirectory(at: space.work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: space.folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return space
    }

    /// A compact transcript, as Claude Code writes it: a user line, then one assistant line per model.
    @discardableResult
    private func session(_ folder: URL, _ id: String = UUID().uuidString.lowercased(), models: [String], age: TimeInterval = 0,
                         extra: [String: Any] = [:], lines: [String] = []) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [[String: Any]] = [["parentUuid": NSNull(), "isSidechain": false, "type": "user", "uuid": "u-\(id)", "sessionId": id,
                                         "message": ["role": "user", "content": "fixture question"]].merging(extra) { $1 }]
        for (index, model) in models.enumerated() {
            entries.append(["parentUuid": "u-\(id)", "isSidechain": false, "type": "assistant", "uuid": "a\(index)-\(id)", "sessionId": id,
                            "message": ["role": "assistant", "model": model, "content": [["type": "text", "text": "fixture answer"]]]]
                .merging(extra) { $1 })
        }
        let text = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
        let file = folder.appendingPathComponent(id + ".jsonl")
        try Data(((text + lines).joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600 + age)], ofItemAtPath: file.path)
        return id
    }

    private func check(_ space: Workspace, _ arguments: [String], environment: [String: String] = [:]) -> EndpointSession.Outcome {
        EndpointSession.check(arguments: arguments, workingDirectory: space.work.path, configDirectory: space.config.path,
                              environment: environment, pinned: "deepseek-flash")
    }

    func testResumingASessionOtherModelsRepliedInIsRefused() throws {
        let space = try workspace()
        let claude = try session(space.folder, models: ["claude-opus-5-5", "<synthetic>"], age: 10)
        let own = try session(space.folder, models: ["deepseek-flash"], age: 20)
        XCTAssertEqual(check(space, ["-p", "hi"]), .clear)
        for arguments in [["--resume", claude], ["-r", claude.uppercased()], ["--resume=" + claude, "-p", "x"], ["-r" + claude]] {
            XCTAssertEqual(check(space, arguments), .otherModels(session: arguments.contains(claude.uppercased()) ? claude.uppercased() : claude,
                                                                 models: ["claude-opus-5-5"]), "\(arguments)")
        }
        XCTAssertEqual(check(space, ["--resume", own]), .clear)
        let path = space.folder.appendingPathComponent(claude + ".jsonl").path
        XCTAssertEqual(check(space, ["--resume", path, "--fork-session"]), .otherModels(session: claude, models: ["claude-opus-5-5"]))
        // A session found only in another project's folder is still the one Claude Code loads.
        let elsewhere = try session(space.projects.appendingPathComponent("-other-project"), models: ["claude-sonnet-5-5"])
        XCTAssertEqual(check(space, ["--resume", elsewhere]), .otherModels(session: elsewhere, models: ["claude-sonnet-5-5"]))
        // An unknown session loads nothing: Claude Code reports it.
        XCTAssertEqual(check(space, ["--resume", UUID().uuidString.lowercased()]), .clear)
    }

    func testContinueChecksTheNewestSessionClaudeCodeWouldPick() throws {
        let space = try workspace()
        let claude = try session(space.folder, models: ["claude-opus-5-5"], age: 10)
        try session(space.folder, models: ["deepseek-flash"], age: 20)
        XCTAssertEqual(check(space, ["-c"]), .clear)
        XCTAssertEqual(check(space, ["--continue", "-p", "x"]), .clear)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: space.folder.appendingPathComponent(claude + ".jsonl").path)
        for arguments in [["-c"], ["--continue"], ["-pc", "x"], ["--resume", "x", "-c"]] {
            XCTAssertEqual(check(space, arguments), .otherModels(session: claude, models: ["claude-opus-5-5"]), "\(arguments)")
        }
    }

    func testContinueSkipsWhatClaudeCodeSkips() throws {
        let space = try workspace()
        let own = try session(space.folder, models: ["deepseek-flash"], age: 10)
        // Newer, but each is one Claude Code passes over: metadata only, a sidechain, a team member, and a daemon worker.
        let metadata = space.folder.appendingPathComponent(UUID().uuidString.lowercased() + ".jsonl")
        try Data(#"{"type":"summary","summary":"fixture","leafUuid":"x"}"#.utf8 + Data("\n".utf8)).write(to: metadata)
        try session(space.folder, models: ["claude-opus-5-5"], age: 30, extra: ["isSidechain": true])
        try session(space.folder, models: ["claude-opus-5-5"], age: 40, extra: ["teamName": "fixture-team"])
        try session(space.folder, models: ["claude-opus-5-5"], age: 50, extra: ["sessionKind": "daemon-worker"])
        // A file whose name is not a session ID, and an agent transcript, are never candidates.
        try session(space.folder, "agent-fixture", models: ["claude-opus-5-5"], age: 60)
        XCTAssertEqual(check(space, ["-c"]), .clear, "the DeepSeek session \(own) is the one continued")
        // Sessions made with -p are passed over interactively but continued by another -p run.
        let headless = try session(space.folder, models: ["claude-haiku-5-5"], age: 70, extra: ["entrypoint": "sdk-cli"])
        XCTAssertEqual(check(space, ["-c"]), .clear)
        XCTAssertEqual(check(space, ["-c", "-p", "x"]), .otherModels(session: headless, models: ["claude-haiku-5-5"]))
        // An empty newest file is continued as an empty conversation.
        let empty = space.folder.appendingPathComponent(UUID().uuidString.lowercased() + ".jsonl")
        try Data().write(to: empty)
        XCTAssertEqual(check(space, ["-c", "-p", "x"]), .clear)
    }

    func testAPinnedProjectFolderNameIsHonoured() throws {
        let space = try workspace()
        let claude = try session(space.projects.appendingPathComponent("fixture-pin"), models: ["claude-opus-5-5"])
        XCTAssertEqual(check(space, ["-c"]), .clear)
        XCTAssertEqual(check(space, ["-c"], environment: ["CLAUDE_CODE_PROJECT_DIR_NAME": "fixture-pin"]),
                       .otherModels(session: claude, models: ["claude-opus-5-5"]))
        XCTAssertEqual(check(space, ["-c"], environment: ["CLAUDE_CODE_PROJECT_DIR_NAME": "not a name"]), .clear)
    }

    func testTitlesPathsAndPickers() throws {
        let space = try workspace()
        let titled = try session(space.folder, models: ["claude-opus-5-5"], lines: [#"{"type":"custom-title","customTitle":"Fixture Work","sessionId":"x"}"#])
        XCTAssertEqual(check(space, ["--resume", "fixture work"]), .otherModels(session: titled, models: ["claude-opus-5-5"]))
        XCTAssertEqual(check(space, ["--resume", "no such title"]), .uncheckable)
        XCTAssertEqual(check(space, ["-p", "x", "--resume", "no such title"]), .clear, "-p refuses an unknown title itself")
        let relative = "../config/projects/" + space.folder.lastPathComponent + "/" + titled + ".jsonl"
        XCTAssertEqual(check(space, ["-p", "x", "--resume", relative]), .otherModels(session: titled, models: ["claude-opus-5-5"]))
        XCTAssertEqual(check(space, ["--resume", relative]), .uncheckable, "interactively a relative path opens the picker")
        for arguments in [["--resume"], ["-r"], ["--from-pr", "12"], ["--teleport"], ["-p", "x", "--resume", "https://claude.ai/code/session"]] {
            XCTAssertEqual(check(space, arguments), .uncheckable, "\(arguments)")
        }
        XCTAssertEqual(check(space, ["-p", "x", "--resume"]), .clear, "-p refuses --resume without a value itself")
    }

    func testSubagentTranscriptsOfTheResumedSessionCountToo() throws {
        let space = try workspace()
        let own = try session(space.folder, models: ["deepseek-flash"])
        try session(space.folder.appendingPathComponent(own).appendingPathComponent("subagents"), "agent-fixture", models: ["claude-haiku-5-5"])
        XCTAssertEqual(check(space, ["--resume", own]), .otherModels(session: own, models: ["claude-haiku-5-5"]))
    }
}

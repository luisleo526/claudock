import Foundation
import XCTest
@testable import UsageCore

final class EndpointSettingsTests: XCTestCase {
    private let flash = try! EndpointConfiguration(baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash")
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-endpoint-settings-\(UUID().uuidString)")
    private let profileFolder = "/synthetic/claudock-endpoint-profile"

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func launch(_ arguments: [String], _ configuration: EndpointConfiguration? = nil) throws -> (settings: [String: Any], rest: [String]) {
        let result = try EndpointLaunch.arguments(arguments, configuration: configuration ?? flash, configDirectory: profileFolder,
                                                  workingDirectory: folder.path)
        XCTAssertEqual(result.first, "--settings")
        XCTAssertEqual(ClaudeCommandLine.options(in: result).filter { $0.name == "--settings" }.count, 1, "Claude Code reads exactly one --settings")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result[1].utf8)) as? [String: Any])
        return (object, Array(result.dropFirst(2)))
    }

    private func pinnedEnvironment(_ model: String, disable1M: String = "1") -> [String: String] {
        // Every credential, provider, and model variable a launch clears is blank here too, so no settings file sets one;
        // the profile's folder is repeated, the nested-session marker is Claude Code's own, and the key cannot be in arguments.
        var blanks: [String: String] = [:]
        for name in LaunchCommand.clearedEnvironment where !["CLAUDECODE", "ANTHROPIC_AUTH_TOKEN"].contains(name) { blanks[name] = "" }
        blanks["CLAUDE_CONFIG_DIR"] = profileFolder
        return blanks.merging(pinnedValues(model, disable1M: disable1M)) { $1 }
    }

    private func pinnedValues(_ model: String, disable1M: String) -> [String: String] {
        ["ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic", "ANTHROPIC_MODEL": model, "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
         "ANTHROPIC_DEFAULT_SONNET_MODEL": model, "ANTHROPIC_DEFAULT_HAIKU_MODEL": model, "ANTHROPIC_DEFAULT_FABLE_MODEL": model,
         "ANTHROPIC_SMALL_FAST_MODEL": model, "CLAUDE_CODE_SUBAGENT_MODEL": model, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
         "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1", "CLAUDE_CODE_DISABLE_1M_CONTEXT": disable1M,
         // The advisor tool names a model of its own; it stays off.
         "CLAUDE_CODE_DISABLE_ADVISOR_TOOL": "1", "CLAUDE_CODE_ENABLE_EXPERIMENTAL_ADVISOR_TOOL": "",
         // Blank, so a settings file's Anthropic key or headers never travel to the third party beside the endpoint key.
         "ANTHROPIC_API_KEY": "", "ANTHROPIC_CUSTOM_HEADERS": "",
         // Blank, so no settings file can choose another model for a role or the picker, or another provider.
         "ANTHROPIC_DEFAULT_MODEL": "", "CLAUDE_CODE_AUTO_MODE_MODEL": "", "CLAUDE_CODE_BG_CLASSIFIER_MODEL": "",
         "CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL": "", "ANTHROPIC_CUSTOM_MODEL_OPTION": "", "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "",
         "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION": "", "ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES": "",
         "CLAUDE_CODE_USE_GATEWAY": ""]
    }

    func testEveryLaunchCarriesOneSettingsObjectThatPinsTheModel() throws {
        let (settings, rest) = try launch(["-p", "hi"])
        XCTAssertEqual(rest, ["-p", "hi"])
        XCTAssertEqual(settings["availableModels"] as? [String], ["deepseek-flash"])
        XCTAssertEqual(settings["env"] as? [String: String], pinnedEnvironment("deepseek-flash"))
        XCTAssertNil(settings["modelPicker"], "without behavesAs the built-in rows stay; they resolve to the pinned model")
        // A project's key helper would otherwise send its key to the endpoint as x-api-key.
        XCTAssertEqual(settings["apiKeyHelper"] as? String, "")
        XCTAssertEqual(Set(settings.keys), ["availableModels", "env", "apiKeyHelper"])
    }

    func testBehavesAsAddsTheOnlyPickerRow() throws {
        let mapped = try EndpointConfiguration(baseURL: flash.baseURL, model: "deepseek-flash", behavesAs: "claude-sonnet-4-6")
        let picker = try XCTUnwrap(try launch([], mapped).settings["modelPicker"] as? [String: Any])
        XCTAssertEqual(picker["replaceBuiltInOptions"] as? Bool, true)
        let rows = try XCTUnwrap(picker["options"] as? [[String: String]])
        XCTAssertEqual(rows, [["model": "deepseek-flash", "label": "deepseek-flash", "description": "Pinned by Claudock · api.deepseek.com",
                               "behavesAs": "claude-sonnet-4-6"]])
    }

    func testAOneMillionTokenPinKeepsItsWindow() throws {
        let wide = try EndpointConfiguration(baseURL: flash.baseURL, model: "deepseek-flash[1m]", behavesAs: "claude-opus-4-8")
        let settings = try launch([], wide).settings
        // Claude Code matches the allowlist by prefix, so the plain id admits the [1m] form it sends.
        XCTAssertEqual(settings["availableModels"] as? [String], ["deepseek-flash"])
        XCTAssertEqual(settings["env"] as? [String: String], pinnedEnvironment("deepseek-flash[1m]", disable1M: ""))
        let rows = (settings["modelPicker"] as? [String: Any])?["options"] as? [[String: String]]
        XCTAssertEqual(rows?.first?["model"], "deepseek-flash[1m]")
    }

    func testTheProcessEnvironmentFollowsTheOneMillionTokenChoice() throws {
        let plain = EndpointLaunch.environment(["CLAUDE_CODE_DISABLE_1M_CONTEXT": "0", "CLAUDE_CONFIG_DIR": "/synthetic/profile"],
                                               configuration: flash, key: "k")
        XCTAssertEqual(plain["CLAUDE_CONFIG_DIR"], "/synthetic/profile", "the profile's folder stays the one LaunchCommand set")
        XCTAssertEqual(plain["CLAUDE_CODE_DISABLE_1M_CONTEXT"], "1")
        let wide = try EndpointConfiguration(baseURL: flash.baseURL, model: "deepseek-flash[1m]")
        XCTAssertNil(EndpointLaunch.environment(["CLAUDE_CODE_DISABLE_1M_CONTEXT": "1"], configuration: wide, key: "k")["CLAUDE_CODE_DISABLE_1M_CONTEXT"])
    }

    func testAUsersOwnSettingsAreMergedIntoTheOneObject() throws {
        let inline = #"{"permissions":{"allow":["Bash(ls)"]},"env":{"E2E_SETTING":"kept","ANTHROPIC_MODEL":"deepseek-flash"},"model":"deepseek-flash"}"#
        for arguments in [["--settings", inline, "-p", "x"], ["-p", "x", "--settings=" + inline]] {
            let (settings, rest) = try launch(arguments)
            XCTAssertEqual(rest, ["-p", "x"], "\(arguments)")
            XCTAssertEqual((settings["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls)"])
            XCTAssertEqual(settings["model"] as? String, "deepseek-flash")
            var expected = pinnedEnvironment("deepseek-flash")
            expected["E2E_SETTING"] = "kept"
            XCTAssertEqual(settings["env"] as? [String: String], expected)
        }
        let file = folder.appendingPathComponent("my settings.json")
        try Data(#"{"outputStyle":"Explanatory","availableModels":["deepseek-flash"]}"#.utf8).write(to: file)
        for value in [file.path, "my settings.json", "  my settings.json"] {
            let (settings, rest) = try launch(["--settings", value])
            XCTAssertEqual(rest, [])
            XCTAssertEqual(settings["outputStyle"] as? String, "Explanatory", value)
            XCTAssertEqual(settings["availableModels"] as? [String], ["deepseek-flash"])
        }
    }

    func testSettingsThatWouldChangeTheModelEndpointOrCredentialsAreRefused() throws {
        let refused: [(String, String)] = [
            (#"{"model":"deepseek-v4-pro"}"#, "model"), (#"{"availableModels":["deepseek-flash","deepseek-v4-pro"]}"#, "availableModels"),
            (#"{"availableModels":"deepseek-flash"}"#, "availableModels"),
            (#"{"fallbackModel":["deepseek-v4-pro"]}"#, "fallbackModel"), (#"{"advisorModel":"claude-opus-4-8"}"#, "advisorModel"),
            (#"{"modelOverrides":{"claude-sonnet-4-6":"deepseek-v4-pro"}}"#, "modelOverrides"), (#"{"modelPicker":{"options":[]}}"#, "modelPicker"),
            (#"{"apiKeyHelper":"/usr/local/bin/key"}"#, "apiKeyHelper"), (#"{"env":{"ANTHROPIC_MODEL":"deepseek-v4-pro"}}"#, "env.ANTHROPIC_MODEL"),
            (#"{"env":{"ANTHROPIC_DEFAULT_HAIKU_MODEL":"x"}}"#, "env.ANTHROPIC_DEFAULT_HAIKU_MODEL"),
            (#"{"env":{"ANTHROPIC_BASE_URL":"https://elsewhere.example"}}"#, "env.ANTHROPIC_BASE_URL"),
            (#"{"env":{"ANTHROPIC_API_KEY":"sk-ant-api03-fixture"}}"#, "env.ANTHROPIC_API_KEY"),
            (#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture"}}"#, "env.ANTHROPIC_AUTH_TOKEN"),
            (#"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}"#, "env.CLAUDE_CODE_USE_BEDROCK"), (#"{"env":"x"}"#, "env"),
            (#"{"env":{"ANTHROPIC_CUSTOM_MODEL_OPTION":"claude-opus-4-8"}}"#, "env.ANTHROPIC_CUSTOM_MODEL_OPTION"),
            (#"{"env":{"CLAUDE_CODE_USE_GATEWAY":"1"}}"#, "env.CLAUDE_CODE_USE_GATEWAY")]
        for (json, key) in refused {
            XCTAssertThrowsError(try EndpointLaunch.arguments(["--settings", json], configuration: flash, configDirectory: profileFolder,
                                                              workingDirectory: folder.path), json) { error in
                XCTAssertEqual(error as? EndpointLaunchError, .settingsConflict(key), json)
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
                XCTAssertFalse(error.localizedDescription.contains("v4-pro"))
            }
        }
        // The pinned values themselves, and a blank credential, are what Claudock sets anyway.
        XCTAssertNoThrow(try launch(["--settings", #"{"env":{"ANTHROPIC_API_KEY":"","ANTHROPIC_SMALL_FAST_MODEL":"deepseek-flash"},"fallbackModel":"deepseek-flash"}"#]))
    }

    private func overrides(managed: URL, dropIns: URL, preferences: [URL] = [], in directory: URL? = nil,
                           home: URL? = nil) -> [APICreditCapture.Override] {
        EndpointLaunch.overridingSettings(configuration: flash, configDirectory: profileFolder, workingDirectory: (directory ?? folder).path,
                                          managedSettings: [managed.path], managedDirectory: dropIns.path,
                                          managedPreferences: preferences.map(\.path), home: (home ?? folder.appendingPathComponent("home")).path)
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testLocalSettingsOfTheGitRootAndTheMainCheckoutAreFound() throws {
        // Claude Code reads .claude/settings.local.json at the repository's root, the main checkout's for a linked worktree,
        // and the working folder's beside it; .claude/settings.json only in the working folder.
        let main = folder.appendingPathComponent("main"), worktree = folder.appendingPathComponent("wt")
        let none = folder.appendingPathComponent("none.json"), dropIns = folder.appendingPathComponent("none.d")
        let gitDirectory = main.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try write("../..\n", to: gitDirectory.appendingPathComponent("commondir"))
        try write(worktree.path + "/.git\n", to: gitDirectory.appendingPathComponent("gitdir"))
        try write("gitdir: " + gitDirectory.path + "\n", to: worktree.appendingPathComponent(".git"))
        let mainLocal = main.appendingPathComponent(".claude/settings.local.json")
        try write(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token"}}"#, to: mainLocal)
        try write(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token"}}"#, to: main.appendingPathComponent(".claude/settings.json"))
        let subfolder = main.appendingPathComponent("src/deep"), worktreeSubfolder = worktree.appendingPathComponent("src")
        for directory in [subfolder, worktreeSubfolder] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let token = APICreditCapture.Override(file: mainLocal.path, key: "env.ANTHROPIC_AUTH_TOKEN")
        XCTAssertEqual(overrides(managed: none, dropIns: dropIns, in: subfolder), [token])
        XCTAssertEqual(overrides(managed: none, dropIns: dropIns, in: worktreeSubfolder), [token])
        let worktreeLocal = worktree.appendingPathComponent(".claude/settings.local.json")
        let ownLocal = worktreeSubfolder.appendingPathComponent(".claude/settings.local.json")
        try write(#"{"fallbackModel":"deepseek-v4-pro"}"#, to: worktreeLocal)
        try write(#"{"availableModels":["deepseek-v4-pro"]}"#, to: ownLocal)
        XCTAssertEqual(overrides(managed: none, dropIns: dropIns, in: worktreeSubfolder), [
            APICreditCapture.Override(file: ownLocal.path, key: "availableModels"),
            APICreditCapture.Override(file: worktreeLocal.path, key: "fallbackModel"), token])
        // A repository at the home folder is not where Claude Code keeps local settings.
        XCTAssertEqual(overrides(managed: none, dropIns: dropIns, in: subfolder, home: main), [])
    }

    func testManagedPreferencesAreManagedSettings() throws {
        let none = folder.appendingPathComponent("none.json"), dropIns = folder.appendingPathComponent("none.d")
        let device = folder.appendingPathComponent("com.anthropic.claudecode.plist"), user = folder.appendingPathComponent("user.plist")
        func plist(_ object: Any, to file: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: file)
        }
        try plist(["env": ["ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic"], "model": "deepseek-flash"], to: device)
        XCTAssertEqual(overrides(managed: none, dropIns: dropIns, preferences: [user, device]), [])
        try plist(["env": ["ANTHROPIC_BASE_URL": "https://elsewhere.example"]], to: user)
        XCTAssertEqual(overrides(managed: none, dropIns: dropIns, preferences: [user, device]),
                       [APICreditCapture.Override(file: user.path, key: "env.ANTHROPIC_BASE_URL")])
        // Claude Code cannot read a date or data value as JSON, nor a file that is no property list.
        for object in [["outputStyle": Date()] as [String: Any], ["blob": Data([1, 2])]] {
            try plist(object, to: user)
            XCTAssertEqual(overrides(managed: none, dropIns: dropIns, preferences: [user]),
                           [APICreditCapture.Override(file: user.path, key: EndpointLaunch.unreadableSettings)])
        }
        try write("<plist><dict><key>env</key>", to: user)
        XCTAssertEqual(overrides(managed: none, dropIns: dropIns, preferences: [user]),
                       [APICreditCapture.Override(file: user.path, key: EndpointLaunch.unreadableSettings)])
    }

    func testAnEmptySettingsFileIsAnEmptyObject() throws {
        let local = folder.appendingPathComponent(".claude/settings.local.json")
        for content in ["", " \n\t", "\u{FEFF}", "\u{FEFF}\n"] {
            try write(content, to: local)
            XCTAssertEqual(overrides(managed: folder.appendingPathComponent("none.json"), dropIns: folder.appendingPathComponent("none.d")),
                           [], content.debugDescription)
        }
    }

    func testSettingsFilesThatOutrankOrReplaceThePinsAreFound() throws {
        let project = folder.appendingPathComponent(".claude"), dropIns = folder.appendingPathComponent("managed-settings.d")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dropIns, withIntermediateDirectories: true)
        let managed = folder.appendingPathComponent("managed-settings.json")
        XCTAssertEqual(overrides(managed: managed, dropIns: dropIns), [])
        // --settings outranks a project's other variables; only the key, which it cannot carry, and the lists Claude Code
        // adds to its own matter there.
        try Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"","ANTHROPIC_BASE_URL":"https://elsewhere.example","OTHER":"x"},"availableModels":["deepseek-flash"],"model":"opus"}"#.utf8)
            .write(to: project.appendingPathComponent("settings.json"))
        // Managed settings outrank --settings: the pinned values themselves and blanks are fine there.
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic","ANTHROPIC_API_KEY":"","OTHER":"x"}}"#.utf8).write(to: managed)
        XCTAssertEqual(overrides(managed: managed, dropIns: dropIns), [])
        try Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token"}}"#.utf8).write(to: project.appendingPathComponent("settings.local.json"))
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://elsewhere.example","ANTHROPIC_MODEL":"deepseek-flash"}}"#.utf8).write(to: managed)
        try Data(#"{"env":{"CLAUDE_CONFIG_DIR":"/synthetic/other-profile"}}"#.utf8).write(to: dropIns.appendingPathComponent("10-team.json"))
        XCTAssertEqual(overrides(managed: managed, dropIns: dropIns), [
            APICreditCapture.Override(file: project.appendingPathComponent("settings.local.json").path, key: "env.ANTHROPIC_AUTH_TOKEN"),
            APICreditCapture.Override(file: managed.path, key: "env.ANTHROPIC_BASE_URL"),
            APICreditCapture.Override(file: dropIns.appendingPathComponent("10-team.json").path, key: "env.CLAUDE_CONFIG_DIR")])
    }

    func testProjectListsThatClaudeCodeJoinsAndManagedChoicesAreFound() throws {
        let project = folder.appendingPathComponent(".claude"), dropIns = folder.appendingPathComponent("managed-settings.d")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let managed = folder.appendingPathComponent("managed-settings.json"), file = project.appendingPathComponent("settings.json")
        // Claude Code joins the allowlist, fallbacks, and overrides of every source instead of letting --settings replace them.
        for (json, key) in [(#"{"availableModels":["deepseek-flash","deepseek-v4-pro"]}"#, "availableModels"),
                            (#"{"fallbackModel":"deepseek-v4-pro"}"#, "fallbackModel"),
                            (#"{"modelOverrides":{"claude-sonnet-4-6":"deepseek-v4-pro"}}"#, "modelOverrides")] {
            try Data(json.utf8).write(to: file)
            XCTAssertEqual(overrides(managed: managed, dropIns: dropIns), [APICreditCapture.Override(file: file.path, key: key)], json)
        }
        try FileManager.default.removeItem(at: file)
        // Managed settings outrank --settings for every choice it makes.
        for (json, key) in [(#"{"apiKeyHelper":"/usr/local/bin/key"}"#, "apiKeyHelper"), (#"{"availableModels":["deepseek-v4-pro"]}"#, "availableModels"),
                            (#"{"model":"deepseek-v4-pro"}"#, "model"), (#"{"modelPicker":{"options":[]}}"#, "modelPicker")] {
            try Data(json.utf8).write(to: managed)
            XCTAssertEqual(overrides(managed: managed, dropIns: dropIns), [APICreditCapture.Override(file: managed.path, key: key)], json)
        }
    }

    func testANameGivenTwiceStopsTheLaunchBecauseParsersDisagreeOnIt() throws {
        let project = folder.appendingPathComponent(".claude"), dropIns = folder.appendingPathComponent("none.d")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("settings.json")
        // Names are compared once their escapes are decoded, in every object, whatever they name.
        for content in [#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token","ANTHROPIC_AUTH_TOKEN":""}}"#,
                        #"{"env":{"ANTHROPIC_AUTH_TOKEN":"","ANTHROPIC_AUTH_TOKE\u004e":"fixture-token"}}"#,
                        #"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token"},"\u0065nv":{}}"#,
                        #"{"statusLine":{"type":"command","command":"a","command":"b"}}"#, #"{"caf\u00e9":1,"café":2}"#,
                        // Names Swift takes for one, so the object Claudock reads would hold only one of them.
                        #"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token","ANTHROPIC_AUTH_TO\u212AEN":""}}"#,
                        "{\"env\":{\"ANTHROPIC_AUTH_TOKEN\":\"fixture-token\",\"ANTHROPIC_AUTH_TO\u{212A}EN\":\"\"}}",
                        #"{"caf\u00e9":1,"cafe\u0301":2}"#] {
            try Data(content.utf8).write(to: file)
            XCTAssertEqual(overrides(managed: folder.appendingPathComponent("missing.json"), dropIns: dropIns),
                           [APICreditCapture.Override(file: file.path, key: EndpointLaunch.unreadableSettings)], content)
        }
        // The same name in two objects, escapes, and every kind of value are plain JSON.
        try Data(("\u{FEFF}" + #"{"env":{"ANTHROPIC_AUTH_TOKEN":""},"statusLine":{"type":"command","command":"printf \"\u00e9\\n\""},"#
                  + #""list":[1,-0.5e3,2E+2,true,false,null,{"type":"a"},{"type":"b"},[]],"empty":{}}"#).utf8).write(to: file)
        XCTAssertEqual(overrides(managed: folder.appendingPathComponent("missing.json"), dropIns: dropIns), [])
        // 256 levels, the object included, is as deep as Claudock follows.
        try Data(("{\"deep\":" + String(repeating: "[", count: 255) + String(repeating: "]", count: 255) + "}").utf8).write(to: file)
        XCTAssertEqual(overrides(managed: folder.appendingPathComponent("missing.json"), dropIns: dropIns), [])
    }

    func testASettingsFileThatCannotBeReadAsAnObjectStopsTheLaunch() throws {
        let project = folder.appendingPathComponent(".claude"), dropIns = folder.appendingPathComponent("none.d")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let local = project.appendingPathComponent("settings.local.json")
        // Foundation reads a trailing comma, which other parsers refuse, so it counts as well.
        for content in [#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token"} /* note */}"#, #"{"broken": "#, "[]",
                        #"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token",}}"#, #"{"list":[1,]}"#, #"{"n":01}"#, #"{"s":"\x"}"#,
                        "{\"s\":\"a\tb\"}", "{\"deep\":" + String(repeating: "[", count: 300) + String(repeating: "]", count: 300) + "}",
                        "{\"deep\":" + String(repeating: "[", count: 256) + String(repeating: "]", count: 256) + "}",
                        #"{"s":"\u+041"}"#, #"{"s":"\u-041"}"#,
                        "{\"padding\":\"" + String(repeating: "x", count: 4_200_000) + "\"}"] {
            try Data(content.utf8).write(to: local)
            XCTAssertEqual(overrides(managed: folder.appendingPathComponent("missing.json"), dropIns: dropIns),
                           [APICreditCapture.Override(file: local.path, key: EndpointLaunch.unreadableSettings)], String(content.prefix(30)))
        }
    }

    func testOptionsThatAddOrMoveSettingsAreRefused() {
        for option in ["--project-config-root", "--managed-settings", "--forward-home-settings", "--deep-link-cwd-b64", "-w", "--worktree"] {
            XCTAssertThrowsError(try EndpointLaunch.arguments([option, "x", "-p", "y"], configuration: flash, configDirectory: profileFolder,
                                                              workingDirectory: folder.path), option) {
                XCTAssertEqual($0 as? EndpointLaunchError, .unsupportedOption(option))
            }
        }
    }

    func testUnreadableOrRepeatedSettingsAreRefused() throws {
        let fifo = folder.appendingPathComponent("fifo.json").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        for value in ["{not json}", "[]", "{", "missing.json", fifo, folder.path] {
            XCTAssertThrowsError(try EndpointLaunch.arguments(["--settings", value], configuration: flash, configDirectory: profileFolder,
                                                              workingDirectory: folder.path), value) {
                XCTAssertEqual($0 as? EndpointLaunchError, .settingsUnreadable, value)
            }
        }
        XCTAssertThrowsError(try EndpointLaunch.arguments(["--settings", "{}", "--settings={}"], configuration: flash, configDirectory: profileFolder,
                                                          workingDirectory: folder.path)) {
            XCTAssertEqual($0 as? EndpointLaunchError, .settingsRepeated)
        }
    }

    func testOnlyAnArgumentClaudeCodeReadsAsTheOptionIsTaken() throws {
        for arguments in [["--append-system-prompt", "--settings", "-p"], ["-p", "--", "--settings", "{}"], ["-p", "--settings is text"]] {
            let (settings, rest) = try launch(arguments)
            XCTAssertEqual(rest, arguments)
            XCTAssertEqual(Set(settings.keys), ["availableModels", "env", "apiKeyHelper"])
        }
    }
}

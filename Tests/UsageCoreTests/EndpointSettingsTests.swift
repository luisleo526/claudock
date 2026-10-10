import Foundation
import XCTest
@testable import UsageCore

final class EndpointSettingsTests: XCTestCase {
    private let flash = try! EndpointConfiguration(baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash")
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-endpoint-settings-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func launch(_ arguments: [String], _ configuration: EndpointConfiguration? = nil) throws -> (settings: [String: Any], rest: [String]) {
        let result = try EndpointLaunch.arguments(arguments, configuration: configuration ?? flash, workingDirectory: folder.path)
        XCTAssertEqual(result.first, "--settings")
        XCTAssertEqual(ClaudeCommandLine.options(in: result).filter { $0.name == "--settings" }.count, 1, "Claude Code reads exactly one --settings")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result[1].utf8)) as? [String: Any])
        return (object, Array(result.dropFirst(2)))
    }

    private func pinnedEnvironment(_ model: String, disable1M: String = "1") -> [String: String] {
        // Every credential, provider, and model variable a launch clears is blank here too, so no settings file sets one;
        // the folder and nested-session variables are Claude Code's own and stay, and the key cannot be in arguments.
        var blanks: [String: String] = [:]
        for name in LaunchCommand.clearedEnvironment where !["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDECODE",
                                                             "ANTHROPIC_AUTH_TOKEN"].contains(name) { blanks[name] = "" }
        return blanks.merging(pinnedValues(model, disable1M: disable1M)) { $1 }
    }

    private func pinnedValues(_ model: String, disable1M: String) -> [String: String] {
        ["ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic", "ANTHROPIC_MODEL": model, "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
         "ANTHROPIC_DEFAULT_SONNET_MODEL": model, "ANTHROPIC_DEFAULT_HAIKU_MODEL": model, "ANTHROPIC_DEFAULT_FABLE_MODEL": model,
         "ANTHROPIC_SMALL_FAST_MODEL": model, "CLAUDE_CODE_SUBAGENT_MODEL": model, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
         "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1", "CLAUDE_CODE_DISABLE_1M_CONTEXT": disable1M,
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
        XCTAssertEqual(plain["CLAUDE_CONFIG_DIR"], "/synthetic/profile", "the profile's folder is LaunchCommand's to set")
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
            XCTAssertThrowsError(try EndpointLaunch.arguments(["--settings", json], configuration: flash, workingDirectory: folder.path), json) { error in
                XCTAssertEqual(error as? EndpointLaunchError, .settingsConflict(key), json)
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
                XCTAssertFalse(error.localizedDescription.contains("v4-pro"))
            }
        }
        // The pinned values themselves, and a blank credential, are what Claudock sets anyway.
        XCTAssertNoThrow(try launch(["--settings", #"{"env":{"ANTHROPIC_API_KEY":"","ANTHROPIC_SMALL_FAST_MODEL":"deepseek-flash"},"fallbackModel":"deepseek-flash"}"#]))
    }

    func testSettingsFilesThatWouldReplaceTheKeyAreFound() throws {
        let project = folder.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let managed = folder.appendingPathComponent("managed-settings.json")
        XCTAssertEqual(EndpointLaunch.overridingCredentials(workingDirectory: folder.path, managedSettings: [managed.path]), [])
        try Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"","OTHER":"x"}}"#.utf8).write(to: project.appendingPathComponent("settings.json"))
        XCTAssertEqual(EndpointLaunch.overridingCredentials(workingDirectory: folder.path, managedSettings: [managed.path]), [])
        try Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-token"}}"#.utf8).write(to: project.appendingPathComponent("settings.local.json"))
        try Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-managed"}}"#.utf8).write(to: managed)
        XCTAssertEqual(EndpointLaunch.overridingCredentials(workingDirectory: folder.path, managedSettings: [managed.path]),
                       [APICreditCapture.Override(file: project.appendingPathComponent("settings.local.json").path, key: "ANTHROPIC_AUTH_TOKEN"),
                        APICreditCapture.Override(file: managed.path, key: "ANTHROPIC_AUTH_TOKEN")])
    }

    func testUnreadableOrRepeatedSettingsAreRefused() throws {
        let fifo = folder.appendingPathComponent("fifo.json").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        for value in ["{not json}", "[]", "{", "missing.json", fifo, folder.path] {
            XCTAssertThrowsError(try EndpointLaunch.arguments(["--settings", value], configuration: flash, workingDirectory: folder.path), value) {
                XCTAssertEqual($0 as? EndpointLaunchError, .settingsUnreadable, value)
            }
        }
        XCTAssertThrowsError(try EndpointLaunch.arguments(["--settings", "{}", "--settings={}"], configuration: flash, workingDirectory: folder.path)) {
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

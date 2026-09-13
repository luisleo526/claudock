import Foundation
import Darwin
import XCTest
@testable import UsageCore

final class ShellShortcutTests: XCTestCase {
    private let header = "claudock-profile-names-v1"

    private struct Fixture {
        let home: URL
        let cli: URL
        let names: URL
        let exitCode: URL
        let capture: URL
        let bin: URL
        var script: URL { home.appendingPathComponent(".config/claudock/init.zsh") }
        var registry: URL { home.appendingPathComponent(".config/claudock/integration.json") }
        var shell: URL { home.appendingPathComponent(".zshrc") }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = home.appendingPathComponent("Claudock's $(literal) app/claudock")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fixture = Fixture(home: home, cli: cli, names: home.appendingPathComponent("names.txt"),
                              exitCode: home.appendingPathComponent("emitter-exit.txt"),
                              capture: home.appendingPathComponent("argv.bin"), bin: bin)
        let executable = #"""
        #!/bin/zsh -f
        if [[ $# == 2 && $1 == shell && $2 == profile-names ]]; then
          /bin/cat "$CLAUDOCK_TEST_NAMES"
          exit "$(< "$CLAUDOCK_TEST_EXIT")"
        fi
        builtin printf '%s\0' "$#" "$@" >> "$CLAUDOCK_TEST_CAPTURE"
        """# + "\n"
        try executable.write(to: cli, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(cli.path, 0o700), 0)
        try "0\n".write(to: fixture.exitCode, atomically: true, encoding: .utf8)
        try Data().write(to: fixture.capture)
        try setNames(["claude-work5"], fixture)
        try body(fixture)
    }

    private func setNames(_ names: [String], _ fixture: Fixture) throws {
        try ([header] + names).joined(separator: "\n").appending("\n")
            .write(to: fixture.names, atomically: true, encoding: .utf8)
    }

    private func run(_ script: String, fixture: Fixture, arguments: [String] = []) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Source the generated init directly. Never source user startup or override HOME.
        process.arguments = ["-f", "-c", script, "claudock-shortcut-test", fixture.script.path] + arguments
        process.currentDirectoryURL = fixture.home
        process.environment = ["PATH": fixture.bin.path + ":/usr/bin:/bin", "LC_ALL": "C",
                               "CLAUDOCK_TEST_NAMES": fixture.names.path,
                               "CLAUDOCK_TEST_EXIT": fixture.exitCode.path,
                               "CLAUDOCK_TEST_CAPTURE": fixture.capture.path,
                               "CLAUDOCK_TEST_ROOT": fixture.home.path]
        process.standardOutput = pipe; process.standardError = pipe
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output)
        return output
    }

    private func capturedArguments(_ fixture: Fixture) throws -> [[String]] {
        let bytes = try Data(contentsOf: fixture.capture)
        guard !bytes.isEmpty else { return [] }
        var fields = bytes.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(fields.last, "")
        fields.removeLast()
        var calls: [[String]] = [], index = 0
        while index < fields.count {
            guard let count = Int(fields[index]), count >= 0, index + count < fields.count else {
                XCTFail("Invalid synthetic argument capture"); return calls
            }
            calls.append(count == 0 ? [] : Array(fields[(index + 1)...(index + count)]))
            index += count + 1
        }
        return calls
    }

    func testShortcutRegistersAndForwardsExactLiteralRunArguments() throws {
        try withFixture { fixture in
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            let arguments = ["argument with spaces", "'$(never-run); echo nope", "", "--model", "value*?[x]"]
            _ = try run(#"""
            source "$1"
            (( ${+functions[claude-work5]} )) || exit 41
            [[ "$HOME" != "$CLAUDOCK_TEST_ROOT" ]] || exit 42
            shift
            claude-work5 "$@"
            """#, fixture: fixture, arguments: arguments)
            XCTAssertEqual(try capturedArguments(fixture), [["run", "claude-work5", "--"] + arguments])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("never-run").path))
        }
    }

    func testPromptAndPreexecHooksReflectAddedRenamedAndRemovedProfiles() throws {
        try withFixture { fixture in
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            _ = try run(#"""
            source "$1"
            (( ${+functions[claude-work5]} )) || exit 41
            printf '%s\n' claudock-profile-names-v1 claude-work5 claude-personal > "$CLAUDOCK_TEST_NAMES"
            for callback in "${precmd_functions[@]}"; do "$callback"; done
            (( ${+functions[claude-work5]} && ${+functions[claude-personal]} )) || exit 42
            printf '%s\n' claudock-profile-names-v1 claude-office claude-personal > "$CLAUDOCK_TEST_NAMES"
            for callback in "${preexec_functions[@]}"; do "$callback" 'claude-office' 'claude-office' 'claude-office'; done
            (( ! ${+functions[claude-work5]} && ${+functions[claude-office]} && ${+functions[claude-personal]} )) || exit 43
            claude-office 'from renamed profile'
            printf '%s\n' claudock-profile-names-v1 claude-office > "$CLAUDOCK_TEST_NAMES"
            for callback in "${precmd_functions[@]}"; do "$callback"; done
            (( ${+functions[claude-office]} && ! ${+functions[claude-personal]} )) || exit 44
            printf '%s\n' claudock-profile-names-v1 > "$CLAUDOCK_TEST_NAMES"
            for callback in "${preexec_functions[@]}"; do "$callback" ':' ':' ':'; done
            (( ! ${+functions[claude-office]} && ${+functions[claudock]} )) || exit 45
            """#, fixture: fixture)
            XCTAssertEqual(try capturedArguments(fixture), [["run", "claude-office", "--", "from renamed profile"]])
        }
    }

    func testUserFunctionsAliasesAndExecutableCommandsTakePriority() throws {
        try withFixture { fixture in
            try setNames(["claude-function", "claude-alias", "claude-executable", "claude-free"], fixture)
            let executable = fixture.bin.appendingPathComponent("claude-executable")
            try "#!/bin/sh\nprintf 'external-command\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
            XCTAssertEqual(chmod(executable.path, 0o700), 0)
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            let output = try run(#"""
            function claude-function() { print -r -- user-function; }
            alias claude-alias='print -r -- user-alias'
            before_function=$functions[claude-function]
            before_alias=$aliases[claude-alias]
            source "$1"
            [[ $functions[claude-function] == "$before_function" && $aliases[claude-alias] == "$before_alias" ]] || exit 41
            (( ! ${+functions[claude-alias]} && ! ${+functions[claude-executable]} && ${+functions[claude-free]} )) || exit 42
            claude-function
            eval 'claude-alias'
            claude-executable
            """#, fixture: fixture)
            XCTAssertEqual(output, "user-function\nuser-alias\nexternal-command\n")
            XCTAssertEqual(try capturedArguments(fixture), [])
        }
    }

    func testResourceDoesNotStackHooksAndKeepsExistingHookOrder() throws {
        try withFixture { fixture in
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            _ = try run(#"""
            function existing_precmd() { :; }
            function existing_preexec() { :; }
            typeset -ga precmd_functions=(existing_precmd)
            typeset -ga preexec_functions=(existing_preexec)
            source "$1"
            first_precmd="${(j:,:)precmd_functions}"
            first_preexec="${(j:,:)preexec_functions}"
            original_body=$functions[claude-work5]
            source "$1"
            source "$1"
            [[ "${(j:,:)precmd_functions}" == "$first_precmd" ]] || exit 41
            [[ "${(j:,:)preexec_functions}" == "$first_preexec" ]] || exit 42
            [[ ${precmd_functions[1]} == existing_precmd && ${preexec_functions[1]} == existing_preexec ]] || exit 43
            [[ ${#precmd_functions} == 2 && ${#preexec_functions} == 2 ]] || exit 44
            [[ $functions[claude-work5] == "$original_body" ]] || exit 45
            """#, fixture: fixture)
        }
    }

    func testUserReplacementOfManagedFunctionSurvivesProfileRemoval() throws {
        try withFixture { fixture in
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            let output = try run(#"""
            source "$1"
            function claude-work5() { print -r -- user-replacement; }
            replacement=$functions[claude-work5]
            printf '%s\n' claudock-profile-names-v1 > "$CLAUDOCK_TEST_NAMES"
            for callback in "${precmd_functions[@]}"; do "$callback"; done
            [[ $functions[claude-work5] == "$replacement" ]] || exit 41
            source "$1"
            [[ $functions[claude-work5] == "$replacement" ]] || exit 42
            claude-work5
            """#, fixture: fixture)
            XCTAssertEqual(output, "user-replacement\n")
        }
    }

    func testFailedAndMalformedEmitterPreservesWholePreviousBatch() throws {
        let malformed = [
            "wrong-header\nclaude-new\n",
            header + "\nclaude-new\nclaude-invalid.name\n",
            header + "\nclaude-new\nclaude-new\n",
            header + "\nclaude-new\nclaude-with-space \n",
            header + "\nclaude-new\nclaude-" + String(repeating: "x", count: 41) + "\n",
            header + "\nclaude-new\nclaude-$(touch \"$CLAUDOCK_TEST_ROOT/injected\")\n",
            header + "\nclaude-new\nclaude-x;touch \"$CLAUDOCK_TEST_ROOT/injected\"\n"
        ]
        try withFixture { fixture in
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            var files: [String] = []
            for (index, value) in malformed.enumerated() {
                let path = fixture.home.appendingPathComponent("invalid-\(index).txt")
                try value.write(to: path, atomically: true, encoding: .utf8)
                files.append(path.path)
            }
            _ = try run(#"""
            source "$1"
            original=$functions[claude-work5]
            printf '%s\n' claudock-profile-names-v1 claude-new > "$CLAUDOCK_TEST_NAMES"
            printf '7\n' > "$CLAUDOCK_TEST_EXIT"
            for callback in "${precmd_functions[@]}"; do "$callback"; done
            [[ $functions[claude-work5] == "$original" ]] || exit 41
            (( ! ${+functions[claude-new]} )) || exit 42
            printf '0\n' > "$CLAUDOCK_TEST_EXIT"
            shift
            for invalid in "$@"; do
              /bin/cat "$invalid" > "$CLAUDOCK_TEST_NAMES"
              for callback in "${preexec_functions[@]}"; do "$callback" ':' ':' ':'; done
              [[ $functions[claude-work5] == "$original" ]] || exit 43
              (( ! ${+functions[claude-new]} )) || exit 44
              [[ ! -e "$CLAUDOCK_TEST_ROOT/injected" ]] || exit 45
            done
            """#, fixture: fixture, arguments: files)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("injected").path))
        }
    }

    private func installExactLegacyV1(_ fixture: Fixture, edit: Bool = false) throws {
        try FileManager.default.createDirectory(at: fixture.script.deletingLastPathComponent(), withIntermediateDirectories: true)
        let quotedCLI = "'" + fixture.cli.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Frozen v1 output from the original implementation, not the v2 renderer.
        let legacy = [
            "# Managed by Claudock. Change shell integration in Claudock Settings.",
            "# Profiles and credentials are managed separately from this shell entry point.",
            "function claudock() {", "  command \(quotedCLI) \"$@\"", "}", ""
        ].joined(separator: "\n")
        try (legacy + (edit ? "# User edit\n" : "")).write(to: fixture.script, atomically: true, encoding: .utf8)
        let state = try JSONSerialization.data(withJSONObject: ["version": 1, "cliPath": fixture.cli.path], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) + Data([10])
        try state.write(to: fixture.registry)
        let shell = #"""
        # Existing user settings
        alias ll='ls -l'
        # >>> Claudock shell integration >>>
        [[ -r "$HOME/.config/claudock/init.zsh" ]] && source "$HOME/.config/claudock/init.zsh"
        # <<< Claudock shell integration <<<
        """# + "\n"
        try shell.write(to: fixture.shell, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(fixture.script.path, 0o600), 0)
        XCTAssertEqual(chmod(fixture.registry.path, 0o600), 0)
        XCTAssertEqual(chmod(fixture.shell.path, 0o640), 0)
    }

    func testExactOwnedV1MigratesToV3WithoutChangingStartupBytes() throws {
        try withFixture { fixture in
            try installExactLegacyV1(fixture)
            let startup = try Data(contentsOf: fixture.shell)
            XCTAssertTrue(try ShellIntegration.status(home: fixture.home.path))
            XCTAssertTrue(try ShellIntegration.upgradeIfEnabled(home: fixture.home.path))
            XCTAssertTrue(try ShellIntegration.status(home: fixture.home.path))
            XCTAssertEqual(try Data(contentsOf: fixture.shell), startup)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.shell.path)[.posixPermissions] as? NSNumber, 0o640)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.registry)) as? [String: Any])
            XCTAssertEqual(state["version"] as? Int, 3)
            XCTAssertEqual(state["cliPath"] as? String, fixture.cli.path)
            let script = try Data(contentsOf: fixture.script), registry = try Data(contentsOf: fixture.registry)
            XCTAssertFalse(try ShellIntegration.upgradeIfEnabled(home: fixture.home.path))
            XCTAssertEqual(try Data(contentsOf: fixture.script), script)
            XCTAssertEqual(try Data(contentsOf: fixture.registry), registry)
            XCTAssertEqual(try Data(contentsOf: fixture.shell), startup)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).contains { $0.hasPrefix(".zshrc.claudock-backup-") })
            _ = try run("source \"$1\"; (( ${+functions[claude-work5]} )) || exit 41", fixture: fixture)
        }
    }

    func testEditedV1IsRefusedWithoutReplacingManagedOrStartupContent() throws {
        try withFixture { fixture in
            try installExactLegacyV1(fixture, edit: true)
            let before = try [fixture.script, fixture.registry, fixture.shell].map { try Data(contentsOf: $0) }
            XCTAssertThrowsError(try ShellIntegration.upgradeIfEnabled(home: fixture.home.path)) { error in
                guard case ShellIntegration.IntegrationError.modifiedFiles = error else { return XCTFail("Expected modifiedFiles") }
            }
            XCTAssertEqual(try [fixture.script, fixture.registry, fixture.shell].map { try Data(contentsOf: $0) }, before)
        }
    }

    func testUpgradeWhileOffCreatesNoFilesAndDoesNotReadUserManagedStartup() throws {
        try withFixture { fixture in
            let target = fixture.home.appendingPathComponent("custom-zshrc")
            try Data("unmanaged startup\n".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: fixture.shell, withDestinationURL: target)
            let before = try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).sorted()
            XCTAssertFalse(try ShellIntegration.upgradeIfEnabled(home: fixture.home.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).sorted(), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".config").path))
            XCTAssertEqual(try Data(contentsOf: target), Data("unmanaged startup\n".utf8))
        }
    }

    func testAutoShortcutForwardsClaudeArgumentsWithoutChangingManualAutoSyntax() throws {
        try withFixture { fixture in
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            let arguments = ["--resume", "session with spaces", "'$(never-run)", "", "--model", "claude-fable-5"]
            _ = try run(#"""
            source "$1"
            (( ${+functions[claude-auto]} && ${+functions[claude-work5]} )) || exit 41
            shift
            claude-auto "$@"
            claude-auto
            claudock auto --profiles work5
            """#, fixture: fixture, arguments: arguments)
            XCTAssertEqual(try capturedArguments(fixture), [["auto", "--"] + arguments, ["auto", "--"], ["auto", "--profiles", "work5"]])
        }
    }

    func testAutoShortcutPreservesExistingFunctionAliasAndExecutable() throws {
        for existing in ["function", "alias", "executable"] {
            try withFixture { fixture in
                if existing == "executable" {
                    let executable = fixture.bin.appendingPathComponent("claude-auto")
                    try "#!/bin/sh\nprintf 'external-auto\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
                    XCTAssertEqual(chmod(executable.path, 0o700), 0)
                }
                try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
                let definition: String
                switch existing {
                case "function": definition = "function claude-auto() { print -r -- external-auto; }\n"
                case "alias": definition = "alias claude-auto='print -r -- external-auto'\n"
                default: definition = ""
                }
                let output = try run(definition + #"""
                source "$1"
                source "$1"
                eval 'claude-auto'
                """#, fixture: fixture)
                XCTAssertEqual(output, "external-auto\n")
                XCTAssertEqual(try capturedArguments(fixture), [])
            }
        }
    }

    func testUserReplacementOfAutoShortcutRemainsOwnedByUser() throws {
        try withFixture { fixture in
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            let output = try run(#"""
            source "$1"
            function claude-auto() { print -r -- user-auto; }
            before=$functions[claude-auto]
            _claudock_sync_profiles
            source "$1"
            [[ $functions[claude-auto] == "$before" ]] || exit 41
            printf '%s\n' claudock-profile-names-v1 claude-auto > "$CLAUDOCK_TEST_NAMES"
            _claudock_sync_profiles
            [[ $functions[claude-auto] == "$before" ]] || exit 42
            claude-auto
            """#, fixture: fixture)
            XCTAssertEqual(output, "user-auto\n")
        }
    }

    func testRegisteredAutoProfileSuppressesAutoAliasWithoutInventingProfileWrapper() throws {
        try withFixture { fixture in
            try setNames(["claude-auto", "claude-work5"], fixture)
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            _ = try run(#"""
            source "$1"
            (( ! ${+functions[claude-auto]} && ${+functions[claude-work5]} )) || exit 41
            claudock run claude-auto
            """#, fixture: fixture)
            XCTAssertEqual(try capturedArguments(fixture), [["run", "claude-auto"]])
        }
    }

    func testNewRegistryCollisionRemovesOnlyOurUnchangedAutoAlias() throws {
        try withFixture { fixture in
            try ShellIntegration.enable(cliPath: fixture.cli.path, home: fixture.home.path)
            _ = try run(#"""
            source "$1"
            (( ${+functions[claude-auto]} )) || exit 41
            printf '%s\n' claudock-profile-names-v1 claude-auto claude-work5 > "$CLAUDOCK_TEST_NAMES"
            _claudock_sync_profiles
            (( ! ${+functions[claude-auto]} && ${+functions[claude-work5]} )) || exit 42
            printf '%s\n' claudock-profile-names-v1 claude-work5 > "$CLAUDOCK_TEST_NAMES"
            _claudock_sync_profiles
            (( ${+functions[claude-auto]} )) || exit 43
            """#, fixture: fixture)
        }
    }

    private func installExactLegacyV2(_ fixture: Fixture) throws {
        try installExactLegacyV1(fixture)
        let quotedCLI = LaunchCommand.quote(fixture.cli.path)
        let prefix = LaunchCommand.quote("command " + quotedCLI + " run ")
        // Frozen v2 bytes, independent of the current v3 renderer.
        let legacy = #"""
        # Managed by Claudock. Change shell integration in Claudock Settings.
        # Adapter v2: profile shortcuts follow the registry without editing .zshrc.
        function claudock() {
          command \#(quotedCLI) "$@"
        }

        function _claudock_sync_profiles() {
          emulate -L zsh
          setopt no_aliases
          local _claudock_output
          _claudock_output=$(command \#(quotedCLI) shell profile-names 2>/dev/null) || return 0
          local -a _claudock_lines _claudock_names
          _claudock_lines=("${(@f)_claudock_output}")
          [[ "${_claudock_lines[1]-}" == 'claudock-profile-names-v1' ]] || return 0
          _claudock_names=("${_claudock_lines[@]:1}")
          (( ${#_claudock_names} <= 1000 )) || return 0
          local -A _claudock_seen
          local _claudock_name _claudock_suffix
          # Validate the entire data batch before changing any existing shortcut.
          for _claudock_name in "${_claudock_names[@]}"; do
            [[ "$_claudock_name" == claude-* ]] || return 0
            _claudock_suffix=${_claudock_name#claude-}
            (( ${#_claudock_suffix} >= 1 && ${#_claudock_suffix} <= 40 )) || return 0
            [[ "$_claudock_suffix" != *[^A-Za-z0-9_-]* ]] || return 0
            (( ! ${+_claudock_seen[$_claudock_name]} )) || return 0
            _claudock_seen[$_claudock_name]=1
          done
          # Forget user replacements; remove only exact bodies installed by us.
          for _claudock_name in "${(@k)_claudock_profile_bodies}"; do
            if [[ "${functions[$_claudock_name]-}" != "${_claudock_profile_bodies[$_claudock_name]}" ]]; then
              unset "_claudock_profile_bodies[$_claudock_name]"
            elif (( ! ${+_claudock_seen[$_claudock_name]} )); then
              builtin unfunction "$_claudock_name"
              unset "_claudock_profile_bodies[$_claudock_name]"
            fi
          done
          local _claudock_prefix=\#(prefix)
          for _claudock_name in "${_claudock_names[@]}"; do
            if (( ! ${+_claudock_profile_bodies[$_claudock_name]} )) && builtin whence -w -- "$_claudock_name" >/dev/null 2>&1; then
              continue
            fi
            # The selector is validated data. The fixed body uses no eval and
            # forwards every argument literally through the CLI's -- separator.
            functions[$_claudock_name]="${_claudock_prefix}'${_claudock_name}' -- \"\$@\""
            _claudock_profile_bodies[$_claudock_name]="${functions[$_claudock_name]}"
          done
          return 0
        }

        () {
          emulate -L zsh
          setopt no_aliases
          typeset -gA _claudock_profile_bodies
          autoload -Uz add-zsh-hook
          add-zsh-hook precmd _claudock_sync_profiles
          add-zsh-hook preexec _claudock_sync_profiles
          _claudock_sync_profiles
        }
        """# + "\n"
        try legacy.write(to: fixture.script, atomically: true, encoding: .utf8)
        let state = try JSONSerialization.data(withJSONObject: ["version": 2, "cliPath": fixture.cli.path], options: [.sortedKeys])
        try state.write(to: fixture.registry)
    }

    func testExactOwnedV2UpgradesWithoutStartupChangesAndRetainsCollidingProfileFunction() throws {
        try withFixture { fixture in
            try setNames(["claude-auto", "claude-work5"], fixture)
            try installExactLegacyV2(fixture)
            XCTAssertTrue(try ShellIntegration.status(home: fixture.home.path))
            let oldScript = fixture.home.appendingPathComponent("owned-v2.zsh")
            try Data(contentsOf: fixture.script).write(to: oldScript)
            let startup = try Data(contentsOf: fixture.shell)
            XCTAssertTrue(try ShellIntegration.upgradeIfEnabled(home: fixture.home.path))
            XCTAssertEqual(try Data(contentsOf: fixture.shell), startup)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.registry)) as? [String: Any])
            XCTAssertEqual(state["version"] as? Int, 3)
            XCTAssertEqual(state["cliPath"] as? String, fixture.cli.path)
            XCTAssertFalse(try ShellIntegration.upgradeIfEnabled(home: fixture.home.path))
            _ = try run(#"""
            source "$2"
            before=$functions[claude-auto]
            (( ${+_claudock_profile_bodies[claude-auto]} )) || exit 41
            source "$1"
            [[ $functions[claude-auto] == "$before" ]] || exit 42
            claude-auto --resume
            """#, fixture: fixture, arguments: [oldScript.path])
            XCTAssertEqual(try capturedArguments(fixture), [["run", "claude-auto", "--", "--resume"]])
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path).contains { $0.hasPrefix(".zshrc.claudock-backup-") })
        }
    }

    func testEditedV2IsNotOverwrittenByUpgrade() throws {
        try withFixture { fixture in
            try installExactLegacyV2(fixture)
            let file = try FileHandle(forWritingTo: fixture.script)
            try file.seekToEnd(); try file.write(contentsOf: Data("# User edit\n".utf8)); try file.close()
            let before = try [fixture.script, fixture.registry, fixture.shell].map { try Data(contentsOf: $0) }
            XCTAssertThrowsError(try ShellIntegration.upgradeIfEnabled(home: fixture.home.path))
            XCTAssertEqual(try [fixture.script, fixture.registry, fixture.shell].map { try Data(contentsOf: $0) }, before)
        }
    }
}

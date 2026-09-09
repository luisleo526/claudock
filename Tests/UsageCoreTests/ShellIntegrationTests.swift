import Foundation
import Darwin
import XCTest
@testable import UsageCore

final class ShellIntegrationTests: XCTestCase {
    private let begin = "# >>> Claudock shell integration >>>"
    private let end = "# <<< Claudock shell integration <<<"

    private func withHome(_ body: (URL, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent("Claudock's $(literal) app/claudock")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/zsh\nprintf '%s\\n' \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try body(home, executable)
    }

    private func write(_ text: String, path: String, home: URL) throws {
        let target = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
    }

    private func text(_ path: String, home: URL) throws -> String {
        try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    private func backups(_ home: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".zshrc.claudock-backup-") }
    }

    func testReadOnlyStatusAndDisabledNoOpDoNotCreateConfigOrStartup() throws {
        try withHome { home, _ in
            XCTAssertFalse(try ShellIntegration.status(home: home.path))
            try ShellIntegration.disable(home: home.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
        }
    }

    func testEnableAndDisablePreserveUserShellAndAccountData() throws {
        try withHome { home, executable in
            let original = "# Personal settings\nfunction claude-work() { echo unchanged; }\n"
            try write(original, path: ".zshrc", home: home)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: home.appendingPathComponent(".zshrc").path)
            try write("credential sentinel", path: ".claude-work/.credentials.json", home: home)
            try write("registry sentinel", path: ".config/claudock/profiles.json", home: home)
            try ShellIntegration.enable(cliPath: executable.path, home: home.path)
            XCTAssertTrue(try ShellIntegration.status(home: home.path))
            let enabled = try text(".zshrc", home: home)
            XCTAssertTrue(enabled.hasPrefix(original))
            XCTAssertEqual(enabled.components(separatedBy: begin).count, 2)
            XCTAssertEqual(try backups(home).count, 1)
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups(home).first), encoding: .utf8), original)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".zshrc").path)[.posixPermissions] as? NSNumber, 0o640)
            for path in [".config/claudock/init.zsh", ".config/claudock/integration.json"] {
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber, 0o600)
            }
            // No duplicate blocks, extra backup, or account mutations on repeated enable.
            try ShellIntegration.enable(cliPath: executable.path, home: home.path)
            XCTAssertEqual(try text(".zshrc", home: home), enabled)
            XCTAssertEqual(try backups(home).count, 1)
            try ShellIntegration.disable(home: home.path)
            XCTAssertFalse(try ShellIntegration.status(home: home.path))
            XCTAssertEqual(try text(".zshrc", home: home), original)
            XCTAssertEqual(try backups(home).count, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/claudock/init.zsh").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/claudock/integration.json").path))
            XCTAssertEqual(try text(".claude-work/.credentials.json", home: home), "credential sentinel")
            XCTAssertEqual(try text(".config/claudock/profiles.json", home: home), "registry sentinel")
        }
    }

    func testGeneratedZshRunsLiteralExecutableAndForwardsArguments() throws {
        try withHome { home, executable in
            try ShellIntegration.enable(cliPath: executable.path, home: home.path)
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", "source \"$1\"; claudock \"$2\" \"$3\" \"$4\"", "test",
                                 home.appendingPathComponent(".zshrc").path, "profile", "argument with spaces", "'$(never-run);echo nope"]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "profile\nargument with spaces\n'$(never-run);echo nope\n")
        }
    }

    func testUpdatingExecutableAndDisablingAfterAppMoveWork() throws {
        try withHome { home, executable in
            try ShellIntegration.enable(cliPath: executable.path, home: home.path)
            let originalShell = try text(".zshrc", home: home)
            let moved = home.appendingPathComponent("moved-cli")
            try FileManager.default.moveItem(at: executable, to: moved)
            XCTAssertTrue(try ShellIntegration.status(home: home.path))
            try ShellIntegration.enable(cliPath: moved.path, home: home.path)
            XCTAssertTrue(try text(".config/claudock/init.zsh", home: home).contains(moved.path))
            XCTAssertEqual(try text(".zshrc", home: home), originalShell)
            XCTAssertEqual(try backups(home).count, 0)
            try FileManager.default.removeItem(at: moved)
            try ShellIntegration.disable(home: home.path)
            XCTAssertFalse(try ShellIntegration.status(home: home.path))
        }
    }

    func testUnterminatedOriginalLineAndLaterUserCodeRemainValid() throws {
        try withHome { home, executable in
            try write("export EDITOR=vim", path: ".zshrc", home: home)
            try ShellIntegration.enable(cliPath: executable.path, home: home.path)
            let enabled = try text(".zshrc", home: home)
            XCTAssertTrue(enabled.hasPrefix("export EDITOR=vim\n" + begin))
            try write(enabled + "export PAGER=less\n", path: ".zshrc", home: home)
            try ShellIntegration.disable(home: home.path)
            XCTAssertEqual(try text(".zshrc", home: home), "export EDITOR=vim\nexport PAGER=less\n")
        }
    }

    func testRefusesModifiedOrDuplicateMarkersWithoutReplacingAnything() throws {
        for modification in ["edit", "duplicate", "remove-end", "remove-block"] {
            try withHome { home, executable in
                try ShellIntegration.enable(cliPath: executable.path, home: home.path)
                let original = try text(".zshrc", home: home)
                let changed: String
                switch modification {
                case "edit": changed = original.replacingOccurrences(of: "[[ -r", with: "[[ -f")
                case "duplicate": changed = original + original
                case "remove-end": changed = original.replacingOccurrences(of: end, with: "")
                default: changed = "# User removed integration\n"
                }
                try write(changed, path: ".zshrc", home: home)
                let script = try text(".config/claudock/init.zsh", home: home)
                XCTAssertThrowsError(try ShellIntegration.status(home: home.path), modification)
                XCTAssertThrowsError(try ShellIntegration.enable(cliPath: executable.path, home: home.path), modification)
                XCTAssertThrowsError(try ShellIntegration.disable(home: home.path), modification)
                XCTAssertEqual(try text(".zshrc", home: home), changed)
                XCTAssertEqual(try text(".config/claudock/init.zsh", home: home), script)
                XCTAssertEqual(try backups(home).count, 0)
            }
        }
    }

    func testRefusesEditedManagedScriptAndForeignUnregisteredScript() throws {
        for install in [true, false] {
            try withHome { home, executable in
                if install { try ShellIntegration.enable(cliPath: executable.path, home: home.path) }
                try write("echo user-owned code\n", path: ".config/claudock/init.zsh", home: home)
                XCTAssertThrowsError(try ShellIntegration.enable(cliPath: executable.path, home: home.path))
                XCTAssertThrowsError(try ShellIntegration.disable(home: home.path))
                XCTAssertEqual(try text(".config/claudock/init.zsh", home: home), "echo user-owned code\n")
            }
        }
    }

    func testRefusesSymlinkStartupWithoutChangingLinkOrTarget() throws {
        try withHome { home, executable in
            try write("# Dotfiles are external\n", path: "dotfiles/zshrc", home: home)
            let shell = home.appendingPathComponent(".zshrc")
            let target = home.appendingPathComponent("dotfiles/zshrc")
            try FileManager.default.createSymbolicLink(at: shell, withDestinationURL: target)
            XCTAssertThrowsError(try ShellIntegration.enable(cliPath: executable.path, home: home.path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: shell.path), target.path)
            XCTAssertEqual(try text("dotfiles/zshrc", home: home), "# Dotfiles are external\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/claudock/init.zsh").path))
        }
    }

    func testRefusesSymlinkConfigAndManagedFiles() throws {
        for linkedPath in [".config", ".config/claudock", ".config/claudock/init.zsh", ".config/claudock/integration.json"] {
            try withHome { home, executable in
                let target = home.appendingPathComponent("external")
                if linkedPath.hasSuffix(".zsh") || linkedPath.hasSuffix(".json") {
                    try write("external sentinel", path: "external", home: home)
                } else {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                }
                let link = home.appendingPathComponent(linkedPath)
                try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                XCTAssertThrowsError(try ShellIntegration.enable(cliPath: executable.path, home: home.path), linkedPath)
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
                XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
            }
        }
    }

    func testRejectsInvalidExecutableBeforeWritingFiles() throws {
        try withHome { home, executable in
            for invalid in ["relative/claudock", executable.path + "\n", executable.path + "\t", home.path, home.appendingPathComponent("missing").path] {
                XCTAssertThrowsError(try ShellIntegration.enable(cliPath: invalid, home: home.path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
        }
    }

    func testExistingExclusiveLockRejectsConcurrentUpdate() throws {
        try withHome { home, executable in
            try ShellIntegration.enable(cliPath: executable.path, home: home.path)
            let shell = try text(".zshrc", home: home)
            let descriptor = open(home.appendingPathComponent(".config/claudock/.shell-integration-lock").path, O_RDWR)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try ShellIntegration.disable(home: home.path)) { error in
                guard case ShellIntegration.IntegrationError.busy = error else {
                    return XCTFail("Expected a busy error, got \(error)")
                }
            }
            XCTAssertEqual(try text(".zshrc", home: home), shell)
            XCTAssertTrue(try ShellIntegration.status(home: home.path))
        }
    }

    func testZshenvZdotdirDeclarationsRefuseEnableBeforeAnyConfigurationWrite() throws {
        for declaration in [
            "ZDOTDIR=\"$HOME/.config/zsh\"\n",
            "export ZDOTDIR=$HOME/dotfiles\n",
            "typeset -gx ZDOTDIR\n",
            "if true; then ZDOTDIR=/tmp/custom-zsh; fi\n",
            "export FOO=bar ZDOTDIR=/tmp/custom-zsh\n"
        ] {
            try withHome { home, executable in
                try write("# User startup\n", path: ".zshrc", home: home)
                try write(declaration, path: ".zshenv", home: home)
                XCTAssertThrowsError(try ShellIntegration.enable(cliPath: executable.path, home: home.path)) { error in
                    guard case ShellIntegration.IntegrationError.customZdotdir = error else {
                        return XCTFail("Expected a ZDOTDIR error, got \(error)")
                    }
                }
                XCTAssertEqual(try text(".zshrc", home: home), "# User startup\n")
                XCTAssertEqual(try text(".zshenv", home: home), declaration)
                XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config").path))
                XCTAssertFalse(try ShellIntegration.status(home: home.path))
            }
        }
    }

    func testZshenvCommentsDoNotDisableOrdinaryHomeStartupIntegration() throws {
        try withHome { home, executable in
            let environment = "# export ZDOTDIR=$HOME/example\n  # ZDOTDIR=/example\nexport EDITOR=vim # ZDOTDIR=/example\nexport LABEL='a # b' # export ZDOTDIR=/example\n"
            try write(environment, path: ".zshenv", home: home)
            try ShellIntegration.enable(cliPath: executable.path, home: home.path)
            XCTAssertTrue(try ShellIntegration.status(home: home.path))
            // If the user subsequently adopts a different startup folder, disabling
            // can still clean up the Claudock block previously added to home/.zshrc.
            try write("export ZDOTDIR=$HOME/dotfiles\n", path: ".zshenv", home: home)
            try ShellIntegration.disable(home: home.path)
            XCTAssertFalse(try ShellIntegration.status(home: home.path))
            XCTAssertEqual(try text(".zshenv", home: home), "export ZDOTDIR=$HOME/dotfiles\n")
        }
    }
}

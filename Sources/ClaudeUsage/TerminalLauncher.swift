import AppKit
import UsageCore

enum TerminalLauncher {
    static var executable: String? {
        ClaudeExecutable.find()
    }

    static var bundledCLI: String? {
        let directory = Bundle.main.executableURL?.deletingLastPathComponent()
        guard let path = directory?.appendingPathComponent("claudock").path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static func commandToCopy(_ profile: Profile) -> String {
        guard profile.discoveryNote == nil, !profile.isVertex else { return profile.command }
        if (try? ShellIntegration.status()) == true { return profile.launchCommand }
        guard let cli = bundledCLI else { return profile.launchCommand }
        return LaunchCommand.quote(cli) + " run " + LaunchCommand.quote(profile.command)
    }

    @MainActor static func login(profile: Profile) async throws {
        try await launch(profile: profile, arguments: ["auth", "login", "--claudeai"], directory: NSHomeDirectory())
    }
    @MainActor static func launch(profile: Profile, arguments: [String] = [], directory: String = NSHomeDirectory()) async throws {
        guard let executable else { throw MonitorError.unsupported("Claude Code was not found. Install it or select its executable in Settings.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MonitorError.unsupported("The project folder no longer exists. Choose an existing project.")
        }
        let script = try LaunchCommand.script(profile: profile, executable: executable, arguments: arguments, workingDirectory: directory)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Claudock-\(NSUserName())", isDirectory: true)
        // Refuse a pre-existing link/non-directory at this predictable parent.
        if let values = try? folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]), values.isSymbolicLink == true || values.isDirectory != true {
            throw MonitorError.unsupported("The temporary launch folder is unavailable.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(UUID().uuidString + ".command")
        try Data(script.utf8).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            try? FileManager.default.removeItem(at: file)
            throw MonitorError.unsupported("Terminal.app was not found on this Mac.")
        }
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw MonitorError.unsupported("Terminal could not open the launch script. \(error.localizedDescription)")
        }
    }
    @MainActor static func chooseExecutable() {
        let picker = NSOpenPanel()
        picker.message = "Select the Claude Code executable"
        picker.canChooseDirectories = false; picker.canChooseFiles = true
        if picker.runModal() == .OK, let url = picker.url, FileManager.default.isExecutableFile(atPath: url.path) {
            UserDefaults.standard.set(url.path, forKey: "claudeExecutable")
        }
    }
}

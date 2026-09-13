import SwiftUI
import UsageCore

struct ProfileManagerView: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var configPath = ""
    @State private var editing: Profile?
    @State private var deleting: Profile?
    @State private var busy = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var loginAfterAdd = true
    @State private var shellEnabled = false
    @State private var shellStatusKnown = false
    @State private var shellFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your profiles").font(.system(size: 22, weight: .semibold))
                    Text("Managed by Claudock. No shell changes required.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing == nil ? "Add an account" : "Rename \(editing!.name)").font(.headline)
                    HStack {
                        Text("Name").foregroundStyle(.secondary)
                        TextField("profile-name", text: $name).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("profileNameField")
                    }
                    if editing == nil {
                        HStack {
                            Text(configPath.isEmpty ? "Shared sessions and settings, with a separate account login" : configPath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(configPath.isEmpty ? "Import folder…" : "Change…") { chooseFolder() }
                            if !configPath.isEmpty { Button { configPath = "" } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain) }
                        }
                        Toggle("Open Claude sign-in after adding", isOn: $loginAfterAdd).font(.caption)
                    } else {
                        Text("The config folder and login stay the same.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Letters, numbers, hyphens, underscores · up to 40 characters").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        if editing != nil { Button("Cancel") { editing = nil; name = "" } }
                        Button(editing == nil ? "Add profile" : "Save name") { save() }
                            .buttonStyle(.borderedProminent).tint(controlAccent).foregroundStyle(.white).disabled(name.isEmpty || busy || store.refreshing)
                            .accessibilityIdentifier("saveProfileButton")
                    }
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Enable claudock in zsh", isOn: Binding(get: { shellEnabled }, set: { updateShell(enabled: $0) }))
                            .disabled(busy || !shellStatusKnown)
                        Spacer()
                        Button("Import zsh profiles") { importProfiles() }.disabled(busy || store.refreshing)
                    }
                    Text(shellEnabled ? "The Claudock block is enabled in .zshrc. Open a new Terminal, or source ~/.config/claudock/init.zsh in an existing one." : "Optional. Enabling adds a labeled Claudock block to .zshrc and keeps your existing commands intact. The app works without it.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let message = shellFailure ?? store.shellIntegrationError { Text(message).font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = store.profileError { Text(error).font(.caption).foregroundStyle(.red) }
            if TerminalLauncher.executable == nil {
                HStack {
                    Text("Install Claude Code before signing in.").font(.caption)
                    Link("Installation guide", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                    Button("Locate Claude…") { TerminalLauncher.chooseExecutable() }
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.accounts) { account in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(account.profile.name).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                                Text(account.profile.managed ? "MANAGED" : "IMPORTED").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                Spacer()
                                if !account.profile.isVertex && account.profile.discoveryNote == nil {
                                    Button("Re-login") { login(account.profile) }.disabled(busy)
                                        .help("Opens this profile’s Claude sign-in in Terminal")
                                }
                                Menu {
                                    Button("Copy command") { store.copyCommand(account.profile) }
                                    if !account.profile.configDirectory.isEmpty {
                                        Button("Show config folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: account.profile.configDirectory) }
                                    }
                                    if account.profile.command != "claude" && !account.profile.isVertex {
                                        if account.profile.discoveryNote == nil {
                                            Button("Rename…") { editing = account.profile; name = account.profile.name; configPath = "" }
                                        }
                                        Button("Remove from Claudock…", role: .destructive) { deleting = account.profile }
                                    }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            }
                            Text(account.profile.discoveryNote ?? account.profile.configDirectory).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 13)
                        Divider()
                    }
                }
            }
            Text("Profiles are stored by Claudock. Refresh to see changes made from another terminal. Original wrappers, conversations, and saved logins are preserved.")
                .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(24).frame(width: 650, height: 730)
            .task { await readShellStatus() }
            .disabled(store.isDemo)
            .overlay(alignment: .bottom) { if store.isDemo { Button("Preview only · close") { dismiss() }.padding(8) } }
            .alert("Profile change failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") { failure = nil }
            } message: { Text(failure ?? "") }
            .alert("Remove \(deleting?.name ?? "profile") from Claudock?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Remove profile", role: .destructive) { remove() }
            } message: { Text("This removes the profile from Claudock's list. Claude conversations, config folder, saved login, and your own shell commands will be kept.") }
    }
    private func chooseFolder() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.message = "Choose an existing Claude config folder (the folder containing .claude.json or projects)."
        if picker.runModal() == .OK, let url = picker.url { configPath = url.path }
    }
    private func save() {
        busy = true; failure = nil
        let existing = editing; let requestedName = name; let directory = configPath
        Task {
            do {
                let profile = try await Task.detached {
                    if let existing { return try ProfileManager.rename(profile: existing, to: requestedName) }
                    return try ProfileManager.add(name: requestedName, configDirectory: directory.isEmpty ? nil : directory)
                }.value
                notice = "\(profile.name) is ready in Claudock."
                name = ""; configPath = ""; editing = nil
                store.refresh()
                if existing == nil && loginAfterAdd { try await TerminalLauncher.login(profile: profile) }
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
    private func remove() {
        guard let profile = deleting else { return }; deleting = nil; busy = true
        Task {
            do {
                try await Task.detached { try ProfileManager.remove(profile: profile) }.value
                notice = "Removed \(profile.name) from Claudock. Its Claude data is still on this Mac."
                store.refresh()
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
    private func login(_ profile: Profile) {
        busy = true
        Task {
            do {
                try await TerminalLauncher.login(profile: profile)
                notice = "Finish signing in to \(profile.name) in Terminal, then refresh the monitor."
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
    private func readShellStatus() async {
        do {
            shellEnabled = try await Task.detached { try ShellIntegration.status() }.value
            shellStatusKnown = true; shellFailure = nil
        } catch {
            shellStatusKnown = false; shellFailure = error.localizedDescription
        }
    }
    private func updateShell(enabled: Bool) {
        guard !busy, !store.isDemo else { return }
        let cli = TerminalLauncher.bundledCLI
        if enabled && cli == nil {
            shellFailure = "The bundled claudock CLI is missing. Reinstall the complete Claudock app."
            return
        }
        busy = true; shellFailure = nil
        Task {
            do {
                try await Task.detached {
                    if enabled, let cli { try ShellIntegration.enable(cliPath: cli) }
                    else { try ShellIntegration.disable() }
                }.value
                await readShellStatus()
                store.shellIntegrationError = nil
            } catch { shellFailure = error.localizedDescription }
            busy = false
        }
    }
    private func importProfiles() {
        guard !busy, !store.isDemo else { return }
        busy = true; failure = nil
        Task {
            do {
                let profiles = try await Task.detached { try ProfileStore.importShellProfiles() }.value
                notice = "Claudock now has \(profiles.count) profiles. Your shell files were only read."
                store.refresh()
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
}

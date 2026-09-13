import SwiftUI
import UsageCore

struct ProfileManagerView: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var configPath = ""
    @State private var editing: Profile?
    @State private var deleting: Profile?
    @State private var minting: Profile?
    @State private var lastMintedProfile: Profile?
    @State private var mintStatuses: [String: MintTokenStatus] = [:]
    @State private var mintStatusRequests: [String: UUID] = [:]
    @State private var unavailableMintStatuses: Set<String> = []
    @State private var busy = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var loginAfterAdd = true
    @State private var shellEnabled = false
    @State private var shellStatusKnown = false
    @State private var shellFailure: String?

    private var actionsUnavailable: Bool { busy || store.refreshing || store.isDemo }

    private var shellExplanation: String {
        guard shellStatusKnown else { return "Shell integration status is unavailable. Profile management still works in Claudock." }
        if shellEnabled {
            return "Managed shortcuts update automatically in zsh tabs running the current integration. Open a new Terminal tab, or run source ~/.config/claudock/init.zsh once in an existing tab. Your own commands keep their behavior."
        }
        return "Optional. Enable this to add claudock and profile shortcuts in new Terminal tabs. You can always use Copy launch command. Already-open tabs keep their loaded functions until closed."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your profiles").font(.system(size: 22, weight: .semibold))
                    Text("Managed by Claudock. No shell changes required.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Updating profile") }
                Button(store.isDemo ? "Close preview" : "Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing == nil ? "Add an account" : "Rename \(editing!.name)").font(.headline)
                    HStack {
                        Text("Name").foregroundStyle(.secondary)
                        TextField("profile-name", text: $name).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("profileNameField")
                            .onSubmit { save() }
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
                        if editing != nil { Button("Cancel rename") { resetEditor() } }
                        Button(editing == nil ? "Add profile" : "Save name") { save() }
                            .buttonStyle(.borderedProminent).tint(controlAccent).foregroundStyle(.white).disabled(name.isEmpty)
                            .accessibilityIdentifier("saveProfileButton")
                    }
                }.padding(8)
            }.disabled(actionsUnavailable)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Enable claudock in zsh", isOn: Binding(get: { shellEnabled }, set: { updateShell(enabled: $0) }))
                            .disabled(actionsUnavailable || !shellStatusKnown)
                        Spacer()
                        Button("Import zsh profiles") { importProfiles() }.disabled(actionsUnavailable)
                    }
                    Text(shellExplanation)
                        .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let message = shellFailure ?? store.shellIntegrationError { Text(message).font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = store.profileError { Text(error).font(.caption).foregroundStyle(.red) }
            if !store.isDemo && TerminalLauncher.executable == nil {
                HStack {
                    Text("Install Claude Code before signing in.").font(.caption)
                    Link("Installation guide", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                    Button("Locate Claude…") { TerminalLauncher.chooseExecutable() }.disabled(actionsUnavailable)
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.accounts) { account in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(account.profile.name).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                                    .lineLimit(1).truncationMode(.middle).help(account.profile.command)
                                Text(account.profile.managed ? "MANAGED" : "IMPORTED").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                Spacer()
                                if !account.profile.isVertex && account.profile.discoveryNote == nil {
                                    Button("Re-login") { login(account.profile) }.disabled(actionsUnavailable)
                                        .accessibilityLabel("Re-login to \(account.profile.name)")
                                        .help("Opens this profile’s Claude sign-in in Terminal")
                                }
                                if account.profile.command != "claude" && !account.profile.isVertex {
                                    Button("Rename…") { beginRename(account.profile) }
                                        .disabled(actionsUnavailable || account.profile.discoveryNote != nil)
                                        .accessibilityLabel("Rename \(account.profile.name)")
                                        .accessibilityIdentifier("renameProfile-\(account.id)")
                                        .help("Change the profile name while keeping its login and shared workspace")
                                    Button("Remove…", role: .destructive) { requestRemoval(account.profile) }
                                        .disabled(actionsUnavailable)
                                        .accessibilityLabel("Remove \(account.profile.name) from Claudock")
                                        .accessibilityIdentifier("removeProfile-\(account.id)")
                                        .help("Remove this registration. Shared history, settings, and the saved login are kept.")
                                }
                                Menu {
                                    Button("Copy launch command") { copyCommand(account.profile) }
                                    if !account.profile.configDirectory.isEmpty {
                                        Button("Show config folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: account.profile.configDirectory) }
                                    }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                                    .disabled(actionsUnavailable).help("More actions for \(account.profile.name)")
                            }.buttonStyle(.bordered).controlSize(.small)
                            Text(account.profile.discoveryNote ?? account.profile.configDirectory).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                            HStack(spacing: 12) {
                                Text(mintStatusDescription(account.profile)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .accessibilityLabel(mintStatusDescription(account.profile))
                                Spacer(minLength: 8)
                                Button(mintButtonTitle(account.profile)) { beginMint(account.profile) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .disabled(actionsUnavailable || account.profile.isVertex || account.profile.discoveryNote != nil)
                                    .accessibilityIdentifier("mintToken-\(account.id)")
                                    .accessibilityLabel("Set or replace inference token for \(account.profile.name)")
                                    .help("Paste an existing inference token or create one in your browser")
                            }
                        }.padding(.vertical, 13)
                            .task(id: account.profile) { await readMintStatus(account.profile) }
                        Divider()
                    }
                }
            }
            Text("Rename keeps the same login and workspace. Remove only deletes the Claudock registration and its managed shortcuts; shared conversations, settings, saved logins, and your own shell commands are kept.")
                .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(24).frame(width: 650, height: 730)
            .task { await readShellStatus() }
            .interactiveDismissDisabled(busy)
            .sheet(item: $minting, onDismiss: {
                if let profile = lastMintedProfile { Task { await readMintStatus(profile) } }
            }) { profile in MintTokenView(profile: profile) }
            .alert("Profile action needs attention", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") { failure = nil }
            } message: { Text(failure ?? "") }
            .alert("Remove profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { profile in
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Remove profile", role: .destructive) { remove(profile) }.disabled(actionsUnavailable)
            } message: { profile in
                Text("Remove \(profile.name) from Claudock? Shared conversations and settings, this account's config folder and saved login, and your own shell commands will be kept. Only shortcuts still owned by Claudock are removed when a loaded integration next synchronizes.")
            }
    }
    private func resetEditor() { editing = nil; name = ""; configPath = "" }
    private func mintButtonTitle(_ profile: Profile) -> String {
        switch mintStatuses[profile.id] {
        case .active?, .expired?, .imported?: return "Manage token…"
        default: return "Set token…"
        }
    }
    private func beginMint(_ profile: Profile) {
        guard !actionsUnavailable, !profile.isVertex, profile.discoveryNote == nil else { return }
        lastMintedProfile = profile; minting = profile
    }
    private func mintStatusDescription(_ profile: Profile) -> String {
        if store.isDemo { return "Inference token: demo preview" }
        if profile.isVertex || profile.discoveryNote != nil { return "Inference token unavailable for this profile" }
        if unavailableMintStatuses.contains(profile.id) { return "Inference token status unavailable" }
        guard let status = mintStatuses[profile.id] else { return "Checking inference token…" }
        switch status {
        case .notConfigured: return "No inference token"
        case .active(let expiry):
            return "Inference token \(expiry > store.now ? "expires" : "expired") \(expiry.formatted(date: .abbreviated, time: .shortened))"
        case .expired(let expiry): return "Inference token expired \(expiry.formatted(date: .abbreviated, time: .shortened))"
        case .imported(let expiry):
            if let expiry {
                return "Pasted token · account unverified · \(expiry > store.now ? "expires" : "expired") \(expiry.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Pasted token · expiry unknown · account unverified"
        }
    }
    private func readMintStatus(_ profile: Profile) async {
        guard !store.isDemo, !profile.isVertex, profile.discoveryNote == nil else { return }
        let request = UUID()
        mintStatusRequests[profile.id] = request
        do {
            let status = try await Task.detached(priority: .utility) { try MintTokenStore.status(profile: profile) }.value
            guard !Task.isCancelled, mintStatusRequests[profile.id] == request,
                  store.accounts.contains(where: { $0.profile == profile }) else { return }
            mintStatuses[profile.id] = status; unavailableMintStatuses.remove(profile.id)
        } catch {
            guard !Task.isCancelled, mintStatusRequests[profile.id] == request,
                  store.accounts.contains(where: { $0.profile == profile }) else { return }
            unavailableMintStatuses.insert(profile.id)
        }
    }
    private func beginRename(_ profile: Profile) {
        guard !actionsUnavailable, profile.command != "claude", !profile.isVertex, profile.discoveryNote == nil else { return }
        editing = profile; name = profile.name; configPath = ""; notice = nil; failure = nil
    }
    private func requestRemoval(_ profile: Profile) {
        guard !actionsUnavailable, profile.command != "claude", !profile.isVertex else { return }
        deleting = profile; failure = nil
    }
    private func shortcutNotice(_ profile: Profile) -> String {
        guard shellStatusKnown else { return "Use Copy launch command; shell integration status could not be verified." }
        if shellEnabled { return "\(profile.command) is available in zsh tabs running the current integration, unless your own command already uses that name." }
        return "Use Copy launch command, or enable zsh integration to add a \(profile.command) shortcut."
    }
    private func copyCommand(_ profile: Profile) {
        guard !actionsUnavailable else { return }
        store.copyCommand(profile)
        notice = profile.isVertex || profile.discoveryNote != nil
            ? "Copied your existing \(profile.command) command."
            : "Copied an explicit Claudock launch command for \(profile.name). It works without a profile shortcut."
    }
    private func chooseFolder() {
        guard !actionsUnavailable else { return }
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.message = "Choose an existing Claude config folder (the folder containing .claude.json or projects)."
        if picker.runModal() == .OK, let url = picker.url { configPath = url.path }
    }
    private func save() {
        guard !actionsUnavailable, !name.isEmpty else { return }
        busy = true; failure = nil; notice = nil
        let existing = editing; let requestedName = name; let directory = configPath
        let shouldLogin = loginAfterAdd
        Task {
            defer { busy = false }
            do {
                let profile = try await Task.detached {
                    if let existing { return try ProfileManager.rename(profile: existing, to: requestedName) }
                    return try ProfileManager.add(name: requestedName, configDirectory: directory.isEmpty ? nil : directory)
                }.value
                await readShellStatus()
                notice = (existing == nil ? "Added \(profile.name). " : "Renamed to \(profile.name). ") + shortcutNotice(profile)
                resetEditor()
                store.refresh()
                if existing == nil && shouldLogin {
                    do { try await TerminalLauncher.login(profile: profile) }
                    catch { failure = "The profile was saved, but Claude sign-in could not open. \(error.localizedDescription)" }
                }
            } catch { failure = error.localizedDescription }
        }
    }
    private func remove(_ profile: Profile) {
        guard !actionsUnavailable else { return }
        deleting = nil; busy = true; failure = nil; notice = nil
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try ProfileManager.remove(profile: profile) }.value
                if editing?.id == profile.id { resetEditor() }
                notice = "Removed \(profile.name). Shared history, settings, and the saved login were kept. Your own shell commands are unchanged."
                store.refresh()
            } catch { failure = error.localizedDescription }
        }
    }
    private func login(_ profile: Profile) {
        guard !actionsUnavailable else { return }
        busy = true; failure = nil; notice = nil
        Task {
            defer { busy = false }
            do {
                try await TerminalLauncher.login(profile: profile)
                notice = "Finish signing in to \(profile.name) in Terminal, then refresh the monitor."
            } catch { failure = error.localizedDescription }
        }
    }
    private func readShellStatus() async {
        if store.isDemo { shellEnabled = false; shellStatusKnown = true; shellFailure = nil; return }
        do {
            shellEnabled = try await Task.detached { try ShellIntegration.status() }.value
            shellStatusKnown = true; shellFailure = nil
        } catch {
            shellStatusKnown = false; shellFailure = error.localizedDescription
        }
    }
    private func updateShell(enabled: Bool) {
        guard !actionsUnavailable else { return }
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
        guard !actionsUnavailable else { return }
        busy = true; failure = nil; notice = nil
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

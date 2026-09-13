import SwiftUI
import UsageCore

struct SessionsView: View {
    @ObservedObject var store: MonitorStore
    @State private var search = ""
    @State private var selection: SessionRecord?

    private var sessions: [SessionRecord] {
        guard store.analyticsRangeDays == store.analyticsDays || store.isDemo else { return [] }
        return (store.analytics?.sessions ?? [])
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.profileCommand.localizedCaseInsensitiveContains(search) }
            .sorted { $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : $0.modifiedAt > $1.modifiedAt }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                TextField("Find a project or profile", text: $search).textFieldStyle(.plain)
                Picker("Period", selection: $store.analyticsDays) { Text("7 days").tag(7); Text("30 days").tag(30) }.labelsHidden().frame(width: 105)
            }.padding(.horizontal, 24)
            Text("Continue a conversation with another account in a new Terminal. Your original session keeps running.")
                .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(3).padding(.horizontal, 24)
            if store.analyticsBusy { ProgressView().controlSize(.small).padding(.horizontal, 24) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sessions.prefix(100)) { session in
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text("\(profileDisplayName(session.profileCommand)) · \(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 10)).foregroundStyle(muted)
                                Text(session.hasUsage ? "\(tokenLabel(session.tokens.total)) recorded tokens" : "Token usage unavailable")
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                            }
                            Spacer(minLength: 0)
                            Button { selection = session } label: { Label("Continue as…", systemImage: "arrow.triangle.branch") }
                                .font(.system(size: 11)).disabled(session.projectPath == nil)
                        }.padding(.horizontal, 24).padding(.vertical, 16)
                        Divider().padding(.horizontal, 24)
                    }
                    if sessions.isEmpty && !store.analyticsBusy {
                        Text("No matching sessions in this period.").font(.subheadline).foregroundStyle(muted).padding(40)
                    }
                    if sessions.count > 100 { Text("Showing the 100 most recent matches. Search to narrow the list.").font(.caption).foregroundStyle(muted).padding(20) }
                    if store.analytics?.truncated == true { Text("Partial local history · some logs were skipped by the scan limits.").font(.caption).foregroundStyle(accent).padding(20) }
                }
            }
        }.padding(.top, 12)
            .sheet(item: $selection) { session in ContinueSessionView(store: store, session: session) }
    }
}

struct ContinueSessionView: View {
    @ObservedObject var store: MonitorStore
    let session: SessionRecord
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var launching = false
    @State private var error: String?
    private var candidates: [AccountState] { store.accounts.filter { !$0.profile.isVertex && $0.profile.discoveryNote == nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Continue with another profile").font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 7) {
                Text(session.title).font(.headline)
                Text(session.projectPath ?? "Project unavailable").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted).textSelection(.enabled)
                Text("From \(profileDisplayName(session.profileCommand))").font(.caption).foregroundStyle(muted)
            }
            Picker("Continue using", selection: $target) {
                Text("Choose a profile").tag("")
                Text("Auto · switch on quota limits").tag("__claudock_auto__")
                ForEach(candidates) { account in
                    Text(account.profile.command + (account.error == nil ? account.snapshot?.preferredLaunchWindow.map { " · \($0.title) \(Int($0.percent))% used" } ?? "" : " · check sign-in")).tag(account.id)
                }
            }
            Text("Claude opens the selected project in a new Terminal and forks the saved conversation under this profile’s login. The existing conversation file stays in place. Claude’s normal project trust and permission prompts still apply.")
                .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
            Text("Requires Claude Code with JSONL resume support (verified with 2.1.263). The new session uses the target profile’s settings.")
                .font(.system(size: 10)).foregroundStyle(muted)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if launching { ProgressView().controlSize(.small) }
                Button("Continue in Terminal") { launch() }.buttonStyle(.borderedProminent).tint(controlAccent).foregroundStyle(.white).disabled(target.isEmpty || launching || store.isDemo)
            }
        }.padding(28).frame(width: 510)
    }
    private func launch() {
        guard let directory = session.projectPath else { return }
        let account = candidates.first(where: { $0.id == target })
        guard target == "__claudock_auto__" || account != nil else { return }
        launching = true
        Task {
            do {
                let url = URL(fileURLWithPath: session.filePath)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, url.pathExtension == "jsonl" else {
                    throw MonitorError.unsupported("The saved conversation file is no longer available.")
                }
                let arguments = ["--resume", session.filePath, "--fork-session"]
                if target == "__claudock_auto__" { try await TerminalLauncher.auto(arguments: arguments, directory: directory) }
                else if let account { try await TerminalLauncher.launch(profile: account.profile, arguments: arguments, directory: directory) }
                dismiss()
            } catch { self.error = error.localizedDescription }
            launching = false
        }
    }
}

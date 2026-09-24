import SwiftUI
import ServiceManagement
import UsageCore

let canvas = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.105, green: 0.10, blue: 0.095, alpha: 1) : NSColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)
})
let ink = Color.primary
let muted = adaptiveColor(light: 0x686761, dark: 0xA9A7A2)
private func rgb(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
}
private func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
    })
}
private var accentPair: (light: UInt32, dark: UInt32) {
    switch UserDefaults.standard.string(forKey: "accent") {
    case "sage": return (0x52745A, 0x7AAD87)
    case "iris": return (0x736596, 0xA691D9)
    case "blue": return (0x477092, 0x66A1D1)
    default: return (0x975E41, 0xD18259)
    }
}
var accent: Color {
    adaptiveColor(light: accentPair.light, dark: accentPair.dark)
}
// Deeper fills keep white native control labels legible in both appearances.
var controlAccent: Color { Color(nsColor: rgb(accentPair.light)) }

private func usageColor(_ percent: Double) -> Color {
    percent >= 90 ? adaptiveColor(light: 0xAF4E3F, dark: 0xF06B57)
        : percent >= 70 ? adaptiveColor(light: 0x876735, dark: 0xE8B05C) : accent
}

struct MonitorView: View {
    @ObservedObject var store: MonitorStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var copied: String?
    @State private var openingProfile: String?
    @State private var openedProfile: String?
    @State private var profileActionError: (id: String, message: String)?
    @State private var tab = "Accounts"
    @State private var search = ""
    @State private var showManager = false
    @State private var autoOpening = false
    @State private var autoFailure: String?
    @State private var showWelcome = !CommandLine.arguments.contains("--demo") && !UserDefaults.standard.bool(forKey: "onboardingComplete")

    var body: some View {
        let _ = PerfProbe.count("monitor.body")
        VStack(spacing: 0) {
            header
            Picker("View", selection: $tab) {
                Text("Accounts").tag("Accounts")
                Text("Overview").tag("Overview")
                Text("Sessions").tag("Sessions")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)
            if tab == "Accounts" {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep working across accounts").font(.system(size: 12, weight: .medium))
                        Text("Auto switches on quota limits in the same session.").font(.system(size: 10)).foregroundStyle(muted)
                    }
                    Spacer()
                    Button("Start Auto") {
                        autoOpening = true
                        Task {
                            do { try await TerminalLauncher.auto() }
                            catch { autoFailure = error.localizedDescription }
                            autoOpening = false
                        }
                    }.disabled(autoOpening || store.isDemo || store.subscriptionCount == 0)
                        .help("Open Claude with the shared workspace and automatic quota failover. Already streamed answers are never replayed.")
                }.padding(.horizontal, 24).padding(.bottom, 16)
            }
            if tab == "Accounts" {
            if let error = store.profileError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(accent).padding(.horizontal, 24).padding(.bottom, 12)
            }
            HStack(spacing: 6) {
                Circle().fill(store.refreshing ? accent : Color(red: 0.57, green: 0.70, blue: 0.51)).frame(width: 6, height: 6)
                Text(store.refreshing ? "Checking accounts…" : "\(store.availableCount) of \(store.subscriptionCount) profiles updated")
                Spacer()
                Text("Allowance used").font(.system(size: 11, weight: .medium))
            }
            .font(.system(size: 11)).foregroundStyle(muted).padding(.horizontal, 24).padding(.bottom, 16)
            Rectangle().fill(ink.opacity(0.1)).frame(height: 1)
            if store.accounts.isEmpty {
                VStack(spacing: 12) {
                    if store.profileError == nil { ProgressView().controlSize(.small) }
                    Text(store.profileError == nil ? "Loading your profiles…" : "Profile settings need attention. Open Manage profiles for details.").foregroundStyle(muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Sort once per update; each row used to re-sort to find the last one.
                let accounts = store.sortedAccounts
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(accounts) { account in
                            accountRow(account)
                            if account.id != accounts.last?.id { Rectangle().fill(ink.opacity(0.075)).frame(height: 1).padding(.horizontal, 24) }
                        }
                    }
                }
            }
            } else if tab == "Overview" {
                OverviewView(store: store)
            } else {
                SessionsView(store: store)
            }
            footer
        }
        .background(canvas).foregroundStyle(ink).tint(controlAccent)
        .preferredColorScheme(store.appearance == "system" ? nil : store.appearance == "light" ? .light : .dark)
        .frame(minWidth: 460, idealWidth: 510, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .alert("Login item", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
            Button("OK") { loginError = nil }
        } message: { Text(loginError ?? "") }
        .sheet(isPresented: $showManager) { ProfileManagerView(store: store) }
        .alert("Could not start Auto", isPresented: Binding(get: { autoFailure != nil }, set: { if !$0 { autoFailure = nil } })) {
            Button("OK") { autoFailure = nil }
        } message: { Text(autoFailure ?? "") }
        .sheet(isPresented: $showWelcome) { WelcomeView(store: store) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showManager = true } } }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("CLAUDOCK").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2.5).foregroundStyle(accent)
                Text(tab == "Accounts" ? "Account usage" : tab == "Overview" ? "Usage overview" : "Saved sessions").font(.system(size: 20, weight: .semibold))
            }
            Spacer()
            HStack(spacing: 12) {
                Button { store.openDashboard?() } label: { Image(systemName: "macwindow") }
                    .help("Open dashboard in a window")
                    .foregroundStyle(muted)
                Button { store.refresh(manual: true) } label: {
                    if store.refreshing { ProgressView().controlSize(.small).frame(width: 15, height: 15) }
                    else { Image(systemName: "arrow.clockwise") }
                }.disabled(!store.canRefresh).help("Refresh all profiles (one-minute cooldown)")
                Menu {
                    Button("Manage profiles…") { showManager = true }
                    Divider()
                    Toggle("Show account emails", isOn: $store.showEmails)
                    Toggle("Highest usage first", isOn: $store.sortByUsage)
                    Toggle("Compact account rows", isOn: $store.compact)
                    Button("Open dashboard window") { store.openDashboard?() }
                    Picker("Refresh interval", selection: $store.refreshMinutes) {
                        Text("1 minute").tag(1); Text("5 minutes").tag(5); Text("15 minutes").tag(15)
                    }
                    Picker("Appearance", selection: $store.appearance) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }
                    Picker("Accent", selection: $store.accentName) {
                        Text("Copper").tag("copper"); Text("Sage").tag("sage"); Text("Iris").tag("iris"); Text("Blue").tag("blue")
                    }
                    Divider()
                    Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { value in
                        do {
                            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            if value && !launchAtLogin { SMAppService.openSystemSettingsLoginItems() }
                        } catch { loginError = "Could not change launch at login: \(error.localizedDescription)" }
                    }))
                    Button("About this monitor") {
                        let alert = NSAlert()
                        alert.messageText = "Claudock"
                        alert.informativeText = "Your Claude accounts, together. Checks your profiles every \(store.refreshMinutes) minutes. Profiles are managed locally; zsh integration is optional. Claudock uses Claude’s existing credentials to read usage and automatically renew eligible logins through Anthropic. Re-login is needed when renewal is no longer available. Claudock is unaffiliated with Anthropic."
                        alert.runModal()
                    }
                    Button("Locate Claude executable…") { TerminalLauncher.chooseExecutable() }
                    Button("Show setup guide…") { showWelcome = true }
                    Divider()
                    Button("Quit Claudock") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("Settings")
            }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(muted).padding(.top, 9)
        }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)
    }
    private func accountRow(_ account: AccountState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let _ = PerfProbe.count("monitor.row")
            HStack(alignment: .center) {
                Text(account.profile.name).font(.system(size: 15, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(account.profile.command)
                if let plan = account.plan {
                    Text(plan.displayName.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.6)
                        .foregroundStyle(muted).padding(.horizontal, 6).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ink.opacity(0.15), lineWidth: 1))
                        .fixedSize().help(plan.explanation)
                        .accessibilityLabel("Subscription: \(plan.displayName)")
                }
                Spacer()
                if account.loading { ProgressView().controlSize(.mini) }
                else if account.error != nil && !account.profile.isVertex {
                    Text(account.snapshot == nil ? "NEEDS ATTENTION" : "STALE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.7).foregroundStyle(accent)
                }
                HStack(spacing: 8) {
                    Button { openProfile(account.profile) } label: {
                        HStack(spacing: 5) {
                            if openingProfile == account.id { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "terminal") }
                            Text(openingProfile == account.id ? "Opening…" : openedProfile == account.id ? "Opened Terminal" : "Open in Terminal")
                        }
                        .font(.system(size: 11)).padding(.horizontal, 6).frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(store.isDemo || openingProfile != nil || account.profile.isVertex || account.profile.discoveryNote != nil)
                    .help(store.isDemo ? "Preview mode does not open real sessions" : account.profile.isVertex || account.profile.discoveryNote != nil ? "Copy this command and run it in zsh to preserve its custom setup" : "Open \(account.profile.command) in a new Terminal")
                    .accessibilityLabel("Open \(account.profile.command) in Terminal")
                    .accessibilityIdentifier("openProfile-\(account.id)")
                    Button {
                        store.copyCommand(account.profile); copied = account.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if copied == account.id { copied = nil } }
                    } label: {
                        Label(copied == account.id ? "Copied" : "Copy", systemImage: copied == account.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11)).padding(.horizontal, 6).frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered).controlSize(.small).foregroundStyle(copied == account.id ? accent : muted)
                    .help(account.profile.discoveryNote == nil && !account.profile.isVertex ? "Copy a Claudock command for \(account.profile.name)" : "Copy \(account.profile.command) to clipboard")
                    .accessibilityLabel(copied == account.id ? "Copied launch command for \(account.profile.name)" : "Copy launch command for \(account.profile.name)")
                    .accessibilityIdentifier("copyProfile-\(account.id)")
                }
            }
            if profileActionError?.id == account.id {
                Label(profileActionError?.message ?? "", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(accent).textSelection(.enabled)
            }
            if store.showEmails, let email = account.email {
                Text(email).font(.system(size: 11)).foregroundStyle(muted).textSelection(.enabled).padding(.top, -9)
            }
            if let snapshot = account.snapshot {
                let secondary = snapshot.secondaryWindows
                let primary = Array(secondary.prefix(2))
                if let featured = snapshot.featuredFableWindow {
                    meter(featured, stale: account.error != nil, featured: true)
                }
                if !primary.isEmpty {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(primary) { window in meter(window, stale: account.error != nil) }
                        if primary.count == 1 { Spacer().frame(maxWidth: .infinity) }
                    }
                }
                ForEach(Array(secondary.dropFirst(2))) { window in
                    compactMeter(window, stale: account.error != nil)
                }
                if snapshot.extraUsageEnabled {
                    Text("Extra usage enabled\(snapshot.extraUsagePercent.map { " · \(Int($0.rounded()))% of budget used" } ?? "")")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
                if account.error != nil {
                    Text("Last success \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
            }
            if let error = account.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.localizedDescription)
                    if let retry = account.retryAt { Text("Retry after \(retry.formatted(date: .omitted, time: .shortened))") }
                    if [.loginRequired, .unauthorized, .noCredentials, .expired, .refreshUncertain].contains(error) {
                        Text("This affects usage monitoring. Choose Re-login in Manage profiles, then refresh. Inference tokens are managed separately.")
                    }
                }.font(.system(size: 11)).foregroundStyle(account.profile.isVertex ? muted : accent).lineSpacing(3)
            }
        }.padding(.horizontal, 24).padding(.vertical, store.compact ? 12 : 16)
    }
    private func openProfile(_ profile: Profile) {
        guard !store.isDemo, openingProfile == nil else { return }
        openingProfile = profile.id
        openedProfile = nil
        profileActionError = nil
        Task {
            do {
                try await TerminalLauncher.launch(profile: profile)
                openedProfile = profile.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if openedProfile == profile.id { openedProfile = nil } }
            } catch {
                profileActionError = (profile.id, error.localizedDescription)
            }
            openingProfile = nil
        }
    }
    private func meter(_ window: UsageWindow, stale: Bool, featured: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: featured ? 12 : 11, weight: featured ? .semibold : .regular))
                    .foregroundStyle(featured && !stale ? ink : muted)
                Spacer(minLength: 4)
                (Text("\(Int(window.percent.rounded()))").font(.system(size: featured ? 32 : 18, weight: .medium, design: .rounded)).monospacedDigit()
                    + Text("%").font(.system(size: featured ? 13 : 10)).foregroundColor(muted))
                    .foregroundStyle(stale ? muted : featured ? usageColor(window.percent) : ink)
            }
            progressBar(window, stale: stale, height: featured ? 6 : 4)
            Text(resetLabel(window.resetsAt)).font(.system(size: 10)).foregroundStyle(muted)
                .help(window.resetsAt?.formatted(date: .complete, time: .standard) ?? "No reset time reported")
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.title), \(Int(window.percent.rounded())) percent used. \(resetLabel(window.resetsAt)). \(stale ? "Stale reading." : "")")
    }
    private func compactMeter(_ window: UsageWindow, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text(window.title).lineLimit(1).help(window.title)
                Spacer(minLength: 4)
                Text(resetLabel(window.resetsAt)).foregroundStyle(muted)
                    .help(window.resetsAt?.formatted(date: .complete, time: .standard) ?? "No reset time reported")
                Text("\(Int(window.percent.rounded()))%").monospacedDigit()
                    .foregroundStyle(stale ? muted : usageColor(window.percent))
            }.font(.system(size: 10))
            progressBar(window, stale: stale, height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title), \(Int(window.percent.rounded())) percent used. \(resetLabel(window.resetsAt)). \(stale ? "Stale reading." : "")")
    }
    private func progressBar(_ window: UsageWindow, stale: Bool, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.09))
                Capsule().fill(stale ? muted : usageColor(window.percent)).frame(width: max(0, proxy.size.width * window.fraction))
            }
        }.frame(height: height)
    }
    private func resetLabel(_ date: Date?) -> String {
        guard let date else { return "Reset time unavailable" }
        let remaining = Int(date.timeIntervalSince(store.now))
        if remaining <= 0 { return "Reset due · awaiting update" }
        let days = remaining / 86_400; let hours = (remaining % 86_400) / 3600; let minutes = (remaining % 3600) / 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(max(1, minutes))m"
    }
    private var footer: some View {
        HStack(spacing: 5) {
            Button { showManager = true } label: { Label("Manage profiles", systemImage: "person.2") }
                .buttonStyle(.plain).foregroundStyle(accent).accessibilityIdentifier("manageProfilesButton")
            Spacer()
            if store.isDemo { Text("DEMO").font(.system(size: 9, design: .monospaced)).foregroundStyle(accent) }
            if store.refreshing { Text("Refreshing…") }
            else if store.lastRefresh != nil {
                Text("Next check in \(max(1, Int(ceil(store.nextRefresh.timeIntervalSince(store.now) / 60))))m")
            } else { Text("Every \(store.refreshMinutes) minutes") }
        }.font(.system(size: 10)).foregroundStyle(muted)
            .padding(.horizontal, 24).padding(.vertical, 13)
            .background(canvas)
            .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.08)).frame(height: 1) }
    }
}

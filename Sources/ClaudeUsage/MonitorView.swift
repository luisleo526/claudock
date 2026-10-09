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
    @State private var creditProfile: Profile?
    @State private var tab = "Accounts"
    @State private var search = ""
    @State private var showManager = false
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
                            AccountRow(account: account, resetLabels: resetLabels(for: account), accentName: store.accentName,
                                       isDemo: store.isDemo, compact: store.compact, showEmails: store.showEmails,
                                       opening: openingProfile == account.id, openingAny: openingProfile != nil,
                                       opened: openedProfile == account.id, copied: copied == account.id,
                                       actionError: profileActionError?.id == account.id ? profileActionError?.message ?? "" : nil,
                                       open: { openProfile(account.profile) }, copy: { copyCommand(account) },
                                       setCredit: { creditProfile = account.profile })
                                .equatable()
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
        .sheet(item: $creditProfile) { profile in CreditView(store: store, profile: profile) }
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
                    Toggle("Require inference token to launch", isOn: $store.requireInferenceToken).disabled(store.isDemo)
                    Text("Subscription launches stop instead of using the normal login")
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
    private func copyCommand(_ account: AccountState) {
        store.copyCommand(account.profile); copied = account.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if copied == account.id { copied = nil } }
    }
    /// Time inputs are computed here, against `store.now`, so rows can skip clock updates
    /// until a countdown or the spoken whole-percent elapsed label changes.
    private func resetLabels(for account: AccountState) -> [String: WindowLabels] {
        Dictionary(account.snapshot?.windows.map { window in
            let reset = resetLabel(window.resetsAt)
            let shortReset = reset.hasPrefix("Resets in ") ? String(reset.dropFirst("Resets in ".count))
                : window.resetsAt == nil ? "Unavailable" : "Reset due"
            return (window.id, WindowLabels(reset: reset, shortReset: shortReset,
                                            elapsedFraction: window.elapsedFraction(at: store.now)))
        } ?? [], uniquingKeysWith: { first, _ in first })
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

private struct WindowLabels: Equatable {
    let reset: String
    let shortReset: String
    let elapsedFraction: Double?
    var elapsedPercent: Int? { elapsedFraction.map { Int(($0 * 100).rounded()) } }

    // Coalesce subpercent tick movement with label changes instead of invalidating every
    // account on each ten-second clock update. The tick uses the exact fraction on render.
    static func == (lhs: WindowLabels, rhs: WindowLabels) -> Bool {
        lhs.reset == rhs.reset && lhs.shortReset == rhs.shortReset && lhs.elapsedPercent == rhs.elapsedPercent
    }
}

/// One account in the Accounts list. Inputs are plain values, compared by `==`, so a
/// parent update (a clock tick, another account's refresh) skips rows that did not
/// change. The action closures are not compared; they only reach state and the store,
/// which stay the same objects.
private struct AccountRow: View, Equatable {
    let account: AccountState
    let resetLabels: [String: WindowLabels]
    /// Accent colors are read from preferences; the name makes a change re-render rows.
    let accentName: String
    let isDemo: Bool
    let compact: Bool
    let showEmails: Bool
    let opening: Bool
    let openingAny: Bool
    let opened: Bool
    let copied: Bool
    let actionError: String?
    let open: () -> Void
    let copy: () -> Void
    let setCredit: () -> Void

    static func == (lhs: AccountRow, rhs: AccountRow) -> Bool {
        lhs.account == rhs.account && lhs.resetLabels == rhs.resetLabels && lhs.accentName == rhs.accentName
            && lhs.isDemo == rhs.isDemo && lhs.compact == rhs.compact && lhs.showEmails == rhs.showEmails
            && lhs.opening == rhs.opening && lhs.openingAny == rhs.openingAny && lhs.opened == rhs.opened
            && lhs.copied == rhs.copied && lhs.actionError == rhs.actionError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let _ = PerfProbe.count("monitor.row")
            HStack(alignment: .center) {
                Text(account.profile.name).font(.system(size: 15, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(account.profile.command)
                if account.profile.authKind == .apiKey {
                    badge("API", help: "Claude Console API key, billed per token", accessibilityLabel: "Console API key")
                } else if let plan = account.plan {
                    badge(plan.displayName, help: plan.explanation, accessibilityLabel: "Subscription: \(plan.displayName)")
                }
                Spacer()
                if account.loading { ProgressView().controlSize(.mini) }
                else if account.error != nil && !account.profile.isVertex {
                    Text(account.snapshot == nil ? "NEEDS ATTENTION" : "STALE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.7).foregroundStyle(accent)
                } else if account.credit?.isLow == true {
                    Text("LOW CREDIT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.7).foregroundStyle(usageColor(100))
                }
                HStack(spacing: 8) {
                    Button(action: open) {
                        HStack(spacing: 5) {
                            if opening { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "terminal") }
                            Text(opening ? "Opening…" : opened ? "Opened Terminal" : "Open in Terminal")
                        }
                        .font(.system(size: 11)).padding(.horizontal, 6).frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(isDemo || openingAny || account.profile.isVertex || account.profile.discoveryNote != nil)
                    .help(isDemo ? "Preview mode does not open real sessions" : account.profile.isVertex || account.profile.discoveryNote != nil ? "Copy this command and run it in zsh to preserve its custom setup" : "Open \(account.profile.command) in a new Terminal")
                    .accessibilityLabel("Open \(account.profile.command) in Terminal")
                    .accessibilityIdentifier("openProfile-\(account.id)")
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11)).padding(.horizontal, 6).frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered).controlSize(.small).foregroundStyle(copied ? accent : muted)
                    .help(account.profile.discoveryNote == nil && !account.profile.isVertex ? "Copy a Claudock command for \(account.profile.name)" : "Copy \(account.profile.command) to clipboard")
                    .accessibilityLabel(copied ? "Copied launch command for \(account.profile.name)" : "Copy launch command for \(account.profile.name)")
                    .accessibilityIdentifier("copyProfile-\(account.id)")
                }
            }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(accent).textSelection(.enabled)
            }
            if showEmails, let email = account.email {
                Text(email).font(.system(size: 11)).foregroundStyle(muted).textSelection(.enabled).padding(.top, -9)
            }
            if account.profile.authKind == .apiKey {
                credit.help(CreditView.estimateNote)
            }
            if let snapshot = account.snapshot {
                let display = snapshot.displayWindows
                if let session = display.session {
                    meter(session, label: "5-hour", stale: account.error != nil)
                }
                if let weekly = display.weekly {
                    meter(weekly, label: "Weekly", stale: account.error != nil)
                }
                meter(display.fable, label: "Fable", stale: account.error != nil)
                ForEach(display.others) { window in
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
        }.padding(.horizontal, 24).padding(.vertical, compact ? 12 : 16)
    }
    /// What is left of the Console credit, as a meter like the limit rows: spent of the balance set.
    @ViewBuilder private var credit: some View {
        if let credit = account.credit {
            // Red only when the credit is low, so the color agrees with the attention count.
            let tint = usageColor(credit.isLow ? 100 : min(89, NSDecimalNumber(decimal: credit.usedPercent).doubleValue))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Credit").font(.system(size: 11)).frame(width: 48, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ink.opacity(0.09)).frame(height: 6)
                            Capsule().fill(tint).frame(width: max(0, proxy.size.width * credit.fraction), height: 6)
                        }.frame(height: 10)
                    }.frame(height: 10)
                    Text("\(credit.leftText) left of \(credit.balanceText)")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(credit.isLow ? tint : ink).fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Console credit, \(credit.leftText) left of \(credit.balanceText), \(credit.usedPercentText) percent spent, "
                                    + "since \(credit.asOf.formatted(date: .long, time: .omitted)).\(credit.isLow ? " Low credit." : "") Estimate.")
                HStack(spacing: 6) {
                    Text("since \(credit.asOf.formatted(date: .abbreviated, time: .omitted)) · billed per token")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    setCreditButton
                }.font(.system(size: 10)).foregroundStyle(muted)
            }
        } else {
            HStack(spacing: 6) {
                Text(account.creditError ?? "Console API key · billed per token · set its credit to see what is left")
                    .foregroundStyle(account.creditError == nil ? muted : accent).lineLimit(2)
                Spacer(minLength: 4)
                setCreditButton
            }.font(.system(size: 11))
        }
    }
    private var setCreditButton: some View {
        Button("Set credit…", action: setCredit)
            .buttonStyle(.bordered).controlSize(.small).font(.system(size: 10))
            .accessibilityLabel("Set Console credit for \(account.profile.name)")
            .accessibilityIdentifier("setCredit-\(account.id)")
    }
    private func badge(_ title: String, help: String, accessibilityLabel: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.6)
            .foregroundStyle(muted).padding(.horizontal, 6).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ink.opacity(0.15), lineWidth: 1))
            .fixedSize().help(help)
            .accessibilityLabel(accessibilityLabel)
    }
    private func meter(_ window: UsageWindow?, label: String, stale: Bool) -> some View {
        let timing = window.flatMap { resetLabels[$0.id] }
        let full = (window?.percent ?? 0) >= 100
        return HStack(spacing: 10) {
            Text(label).font(.system(size: 11))
                .foregroundStyle(stale || window == nil ? muted : ink)
                .frame(width: 48, alignment: .leading)
                .help(window?.title ?? "Weekly · Fable")
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.09)).frame(height: 6)
                    if let window {
                        Capsule().fill(stale ? muted : usageColor(window.percent))
                            .frame(width: max(0, proxy.size.width * window.fraction), height: 6)
                    }
                    if let elapsed = timing?.elapsedFraction {
                        Rectangle().fill(ink.opacity(0.55)).frame(width: 2, height: 10)
                            .offset(x: proxy.size.width * elapsed - 1)
                    }
                }.frame(height: 10)
            }.frame(height: 10)
            HStack(spacing: 4) {
                Text(window.map { "\(Int($0.percent.rounded()))%" } ?? "—")
                    .font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
                    .fixedSize().frame(width: 46, alignment: .trailing)
                Label("Full", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 9, weight: .medium)).fixedSize()
                    .frame(width: 38, alignment: .leading).opacity(full ? 1 : 0)
            }
            .foregroundStyle(stale || window == nil ? muted : usageColor(window?.percent ?? 0))
            Text(window == nil ? "Not reported" : timing?.shortReset ?? "Unavailable")
                .font(.system(size: 10)).foregroundStyle(muted)
                .fixedSize().frame(width: 64, alignment: .trailing)
                .help(window?.resetsAt?.formatted(date: .complete, time: .standard) ?? "No reset time reported")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meterAccessibilityLabel(window, stale: stale))
    }
    private func meterAccessibilityLabel(_ window: UsageWindow?, stale: Bool) -> String {
        guard let window else { return "Weekly · Fable, Not reported." }
        let elapsed = resetLabels[window.id]?.elapsedPercent.map { " \($0) percent of the window elapsed." } ?? ""
        return "\(window.title), \(Int(window.percent.rounded())) percent used. \(window.percent >= 100 ? "Full. " : "")\(resetLabel(window)).\(elapsed)\(stale ? " Stale reading." : "")"
    }
    private func compactMeter(_ window: UsageWindow, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text(window.title).lineLimit(1).help(window.title)
                Spacer(minLength: 4)
                Text(resetLabel(window)).foregroundStyle(muted)
                    .help(window.resetsAt?.formatted(date: .complete, time: .standard) ?? "No reset time reported")
                Text("\(Int(window.percent.rounded()))%").monospacedDigit()
                    .foregroundStyle(stale ? muted : usageColor(window.percent))
            }.font(.system(size: 10))
            progressBar(window, stale: stale, height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title), \(Int(window.percent.rounded())) percent used. \(resetLabel(window)). \(stale ? "Stale reading." : "")")
    }
    private func progressBar(_ window: UsageWindow, stale: Bool, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.09))
                Capsule().fill(stale ? muted : usageColor(window.percent)).frame(width: max(0, proxy.size.width * window.fraction))
            }
        }.frame(height: height)
    }
    private func resetLabel(_ window: UsageWindow) -> String {
        resetLabels[window.id]?.reset ?? "Reset time unavailable"
    }
}

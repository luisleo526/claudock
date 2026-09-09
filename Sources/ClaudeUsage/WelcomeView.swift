import SwiftUI

struct WelcomeView: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    var manage: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 36, weight: .light)).foregroundStyle(Color.orange.opacity(0.75))
                Spacer()
                Text("\(step + 1) / 3").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(["Welcome to Claudock", "Connect your profiles", "Ready in your menu bar"][step])
                .font(.system(size: 24, weight: .semibold)).lineSpacing(2)
            if step == 0 {
                Text("Check account limits, review local activity, and open the profile you need.")
                    .foregroundStyle(.secondary).lineSpacing(4)
                Label("Works with your existing claude-{profile} commands", systemImage: "terminal")
                Label("No separate account or cloud sync", systemImage: "lock")
            } else if step == 1 {
                Text("Found \(store.subscriptionCount) profile\(store.subscriptionCount == 1 ? "" : "s"). You can add accounts or import config folders at any time.").foregroundStyle(.secondary)
                Label(TerminalLauncher.executable == nil ? "Claude Code not found" : "Claude Code detected", systemImage: TerminalLauncher.executable == nil ? "exclamationmark.circle" : "checkmark.circle")
                if TerminalLauncher.executable == nil {
                    HStack {
                        Link("Install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                        Button("Locate executable…") { TerminalLauncher.chooseExecutable() }
                    }
                }
                Text("The app reads existing Claude logins to check quota. Token charts come from local session logs; they do not measure your subscription allowance.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Click the menu-bar icon to check usage. Click elsewhere to close it. Open a regular dashboard window only when you need more room.")
                    .font(.subheadline).foregroundStyle(.secondary).lineSpacing(3)
                Toggle("Show account emails", isOn: $store.showEmails)
                Text("Add accounts in Manage profiles. Claudock works without changing your shell; enable optional Terminal integration there if you want a claudock command in zsh.")
                    .font(.subheadline).foregroundStyle(.secondary).lineSpacing(3)
            }
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step == 2 {
                    Button("Add an account") { finish(); manage() }
                    Button("Open my dashboard") { finish() }.buttonStyle(.borderedProminent).tint(controlAccent).foregroundStyle(.white)
                } else { Button("Continue") { step += 1 }.buttonStyle(.borderedProminent).tint(controlAccent).foregroundStyle(.white) }
            }
        }.padding(32).frame(width: 510, height: 460)
    }
    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        dismiss()
    }
}

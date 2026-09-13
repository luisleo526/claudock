import SwiftUI
import AppKit
import UsageCore

struct MintTokenView: View {
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var flow: MintTokenFlow?
    @State private var code = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var expiry: Date?
    @State private var operation: Task<Void, Never>?

    private var isDemo: Bool { CommandLine.arguments.contains("--demo") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inference token for \(profile.name)").font(.title2.weight(.semibold))
            Text("Create a separate token for Claude sessions and account balancing. Your existing login continues to monitor usage and renew itself.")
                .foregroundStyle(.secondary)
            Text("This token supports inference only. Features requiring a full Claude login may be unavailable.")
                .font(.caption).foregroundStyle(.secondary)
            if let expiry {
                Label("Saved in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            } else {
                Text("In the browser, choose the same Claude account used by this profile. Claudock verifies the account and organization before saving.").font(.callout)
                Button(flow == nil ? "Open browser" : "Start again in browser", action: openBrowser)
                    .disabled(busy || isDemo)
                SecureField("Paste authorization code#state", text: $code)
                    .textFieldStyle(.roundedBorder).disabled(flow == nil || busy || isDemo)
                    .accessibilityLabel("Complete authorization code and state")
                if busy { ProgressView("Creating and saving token…").controlSize(.small) }
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            if isDemo { Text("Demo mode does not open sign-in or access Keychain.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(expiry == nil ? "Cancel" : "Done") { operation?.cancel(); code = ""; dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(busy)
                if expiry == nil {
                    Button("Create token", action: finish)
                        .keyboardShortcut(.defaultAction)
                        .disabled(flow == nil || code.isEmpty || busy || isDemo)
                }
            }
        }
        .padding(24).frame(width: 500)
        .interactiveDismissDisabled(busy)
        .onDisappear { operation?.cancel(); code = ""; flow = nil }
    }

    private func openBrowser() {
        guard !isDemo, !busy else { return }
        failure = nil; code = ""
        do {
            let next = try MintTokenFlow(profile: profile)
            guard NSWorkspace.shared.open(next.authorizationURL) else { throw MintTokenError.network }
            flow = next
        } catch { flow = nil; failure = error.localizedDescription }
    }

    private func finish() {
        guard !isDemo, !busy, let flow else { return }
        let pasted = code
        code = ""; busy = true; failure = nil
        self.flow = nil
        operation = Task {
            do {
                let token = try await flow.finish(pastedCode: pasted)
                expiry = token.expiresAt
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
            busy = false
        }
    }
}

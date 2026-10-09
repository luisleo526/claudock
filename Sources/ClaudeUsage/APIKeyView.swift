import SwiftUI
import UsageCore

/// Replaces the Console API key of an API-key profile. The key is never displayed.
struct APIKeyView: View {
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var saved = false
    @State private var operation: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var isDemo: Bool { CommandLine.arguments.contains("--demo") }
    private var canSave: Bool { !busy && !isDemo && !keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Console API key for \(profile.name)").font(.title2.weight(.semibold))
            Text("Claude Code uses this key for the profile. API usage is billed per token by the Claude Console.")
                .foregroundStyle(.secondary)
            if saved {
                Label("Saved in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New API key").font(.callout.weight(.medium))
                    SecureField("sk-ant-…", text: $keyText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy || isDemo)
                        .accessibilityLabel("New Console API key")
                        .accessibilityIdentifier("apiKeyField")
                        .focused($focused)
                        .onSubmit { save() }
                    Text("Paste the key or its export ANTHROPIC_API_KEY=… line. It replaces the saved key and is stored only in Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if busy { ProgressView("Saving API key…").controlSize(.small) }
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            if isDemo { Text("Demo mode does not access Keychain.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(saved ? "Done" : "Cancel") { operation?.cancel(); keyText = ""; dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(busy)
                if !saved {
                    Button("Save to Keychain", action: save)
                        .keyboardShortcut(.defaultAction).disabled(!canSave)
                        .accessibilityIdentifier("saveAPIKeyButton")
                }
            }
        }
        .padding(24).frame(width: 500)
        .interactiveDismissDisabled(busy)
        .onAppear { if !isDemo { focused = true } }
        .onDisappear { operation?.cancel(); keyText = "" }
    }

    private func save() {
        guard canSave else { return }
        let raw = keyText, selected = profile
        keyText = ""; focused = false; busy = true; failure = nil
        operation = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try APIKeyStore.save(ConsoleAPIKey(parsing: raw), profile: selected)
                }.value
                saved = true
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
            busy = false
        }
    }
}

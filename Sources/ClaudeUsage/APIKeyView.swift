import SwiftUI
import UsageCore

/// Replaces the Console API key of an API-key profile, or the key of a third-party endpoint profile. The key is never displayed.
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
    /// The endpoint of a third-party endpoint profile; nil for a Console API-key profile.
    private var endpoint: EndpointConfiguration? { profile.authKind == .endpoint ? profile.endpoint : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(endpoint == nil ? "Console API key for \(profile.name)" : "Endpoint key for \(profile.name)").font(.title2.weight(.semibold))
            Text(endpoint.map { "Claude Code sends this key to \($0.host) for the profile. Usage is billed per token by that provider." }
                 ?? "Claude Code uses this key for the profile. API usage is billed per token by the Claude Console.")
                .foregroundStyle(.secondary)
            if saved {
                Label("Saved in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(endpoint == nil ? "New API key" : "New endpoint key").font(.callout.weight(.medium))
                    SecureField(endpoint == nil ? "sk-ant-…" : "Key", text: $keyText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy || isDemo)
                        .accessibilityLabel(endpoint == nil ? "New Console API key" : "New third-party endpoint key")
                        .accessibilityIdentifier("apiKeyField")
                        .focused($focused)
                        .onSubmit { save() }
                    Text(endpoint == nil
                         ? "Paste the key or its export ANTHROPIC_API_KEY=… line. It replaces the saved key and is stored only in Keychain."
                         : "Paste the key or its export NAME=… line. It replaces the saved key and is stored only in Keychain. "
                            + "Anthropic keys (sk-ant-…) are refused, so they never reach a third party.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if busy { ProgressView("Saving key…").controlSize(.small) }
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
        let raw = keyText, selected = profile, isEndpoint = endpoint != nil
        keyText = ""; focused = false; busy = true; failure = nil
        operation = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if isEndpoint { try EndpointKeyStore.save(EndpointAPIKey(parsing: raw), profile: selected) }
                    else { try APIKeyStore.save(ConsoleAPIKey(parsing: raw), profile: selected) }
                }.value
                saved = true
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
            busy = false
        }
    }
}

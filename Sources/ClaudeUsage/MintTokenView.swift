import SwiftUI
import AppKit
import UsageCore

struct MintTokenView: View {
    private enum Mode: Hashable { case paste, browser }
    private enum Field: Hashable { case token, authorizationCode }

    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .paste
    @State private var tokenText = ""
    @State private var flow: MintTokenFlow?
    @State private var code = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var saved = false
    @State private var savedFromPaste = false
    @State private var expiry: Date?
    @State private var operation: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private var isDemo: Bool { CommandLine.arguments.contains("--demo") }
    private var canSave: Bool {
        guard !busy, !isDemo else { return false }
        switch mode {
        case .paste: return !tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .browser: return flow != nil && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inference token for \(profile.name)").font(.title2.weight(.semibold))
            Text("Use an existing token for Claude sessions and Auto, or create one in your browser.")
                .foregroundStyle(.secondary)
            if saved {
                Label("Saved in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let expiry {
                    Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                } else {
                    Text("Expiry unknown").font(.caption).foregroundStyle(.secondary)
                }
                if savedFromPaste {
                    Text("Assigned to \(profile.name). The token's account was not verified remotely.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Picker("Token setup", selection: $mode) {
                    Text("Paste token").tag(Mode.paste)
                    Text("Create in browser").tag(Mode.browser)
                }
                .pickerStyle(.segmented).labelsHidden().disabled(busy)
                .accessibilityIdentifier("inferenceTokenModePicker")

                if mode == .paste {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Inference token").font(.callout.weight(.medium))
                        HStack {
                            SecureField("Paste your existing token", text: $tokenText)
                                .textFieldStyle(.roundedBorder)
                                .disabled(busy || isDemo)
                                .accessibilityLabel("Inference token")
                                .accessibilityIdentifier("inferenceTokenField")
                                .focused($focusedField, equals: .token)
                                .onSubmit { saveToken() }
                            Button("Paste", action: pasteToken)
                                .disabled(busy || isDemo)
                                .accessibilityLabel("Paste inference token from clipboard")
                                .accessibilityIdentifier("pasteInferenceTokenButton")
                        }
                        Text("Imported token: account unverified, expiry unknown.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Choose the same Claude account used by this profile. Claudock verifies its account and organization before saving.")
                        .font(.callout)
                    Button(flow == nil ? "Open browser" : "Start again in browser", action: openBrowser)
                        .disabled(busy || isDemo)
                    SecureField("Paste authorization code#state", text: $code)
                        .textFieldStyle(.roundedBorder).disabled(flow == nil || busy || isDemo)
                        .accessibilityLabel("Complete authorization code and state")
                        .accessibilityIdentifier("inferenceAuthorizationCodeField")
                        .focused($focusedField, equals: .authorizationCode)
                        .onSubmit { saveToken() }
                }
                if busy { ProgressView("Saving inference token…").controlSize(.small) }
            }
            Text("Inference only. Quota monitoring uses a separate Claude Code login.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            if isDemo { Text("Demo mode does not read the clipboard, open sign-in, or access Keychain.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(saved ? "Done" : "Cancel") { operation?.cancel(); clearInputs(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(busy)
                if !saved {
                    Button(mode == .paste ? "Save to Keychain" : "Create token", action: saveToken)
                        .keyboardShortcut(.defaultAction).disabled(!canSave)
                        .accessibilityIdentifier("saveInferenceTokenButton")
                }
            }
        }
        .padding(24).frame(width: 500)
        .interactiveDismissDisabled(busy)
        .onAppear { if !isDemo { focusedField = .token } }
        .onChange(of: mode) { _, mode in
            clearInputs(); failure = nil
            focusedField = !isDemo && mode == .paste ? .token : nil
        }
        .onDisappear { operation?.cancel(); clearInputs() }
    }

    private func clearInputs() { tokenText = ""; code = ""; flow = nil }

    private func pasteToken() {
        guard mode == .paste, !isDemo, !busy else { return }
        // Read the clipboard only for this explicit user action.
        guard let value = NSPasteboard.general.string(forType: .string),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failure = "The clipboard does not contain a token."
            return
        }
        guard value.utf8.count <= 16_384 else { failure = MintTokenError.tokenTooLarge.localizedDescription; return }
        tokenText = value
        failure = nil
        focusedField = .token
    }

    private func openBrowser() {
        guard mode == .browser, !isDemo, !busy else { return }
        failure = nil; code = ""
        do {
            let next = try MintTokenFlow(profile: profile)
            guard NSWorkspace.shared.open(next.authorizationURL) else { throw MintTokenError.network }
            flow = next
            focusedField = .authorizationCode
        } catch { flow = nil; failure = error.localizedDescription }
    }

    private func saveToken() {
        guard canSave else { return }
        let selectedMode = mode
        let pasted = selectedMode == .paste ? tokenText : code
        let browserFlow = flow
        let selectedProfile = profile
        clearInputs(); focusedField = nil; busy = true; failure = nil
        operation = Task {
            do {
                let token: MintToken
                if selectedMode == .paste {
                    token = try await Task.detached(priority: .userInitiated) {
                        try MintTokenStore.importToken(raw: pasted, profile: selectedProfile, expiresAt: nil)
                    }.value
                } else {
                    guard let browserFlow else { throw MintTokenError.invalidCode }
                    token = try await browserFlow.finish(pastedCode: pasted)
                }
                expiry = token.expiresAt
                savedFromPaste = selectedMode == .paste
                saved = true
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
            busy = false
        }
    }
}

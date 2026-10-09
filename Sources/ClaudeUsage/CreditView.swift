import SwiftUI
import UsageCore

/// Records an API-key profile's remaining Console credit, as `claudock profile set-credit` does.
struct CreditView: View {
    /// How far the estimate reaches; also the help text of the dashboard's credit rows.
    static let estimateNote = "An estimate from the Claude Code sessions Claudock starts on this Mac, using the cost Claude Code reports "
        + "for each request. Use of this key elsewhere (other Macs, scripts, other tools) is not seen. The Console balance "
        + "is authoritative; set the credit again any time."

    @ObservedObject var store: MonitorStore
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var saved: APICreditStatus?
    @FocusState private var focused: Bool

    private var current: APICreditStatus? { store.accounts.first { $0.profile == profile }?.credit }
    private var canSave: Bool { !busy && !store.isDemo && !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Console credit for \(profile.name)").font(.title2.weight(.semibold))
            Text("Enter the credit remaining in the Claude Console. Claudock subtracts what each request costs from now on.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let saved {
                Label("Saved: \(saved.balanceText) as of \(saved.asOf.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                if let current {
                    Text("Now \(current.leftText) left of \(current.balanceText), since \(current.asOf.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Remaining credit").font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        Text("$").foregroundStyle(.secondary)
                        TextField("200.00", text: $amountText)
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                            .disabled(busy || store.isDemo)
                            .focused($focused)
                            .onSubmit { save() }
                            .accessibilityLabel("Remaining Console credit in US dollars")
                            .accessibilityIdentifier("creditAmountField")
                        Text("USD").foregroundStyle(.secondary)
                    }
                    Text("From 0 to 1,000,000, with at most two decimals. Spend before now no longer counts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if busy { ProgressView("Saving credit…").controlSize(.small) }
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text(Self.estimateNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.isDemo { Text("Demo mode does not save credit.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(saved == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(busy)
                if saved == nil {
                    Button("Save credit", action: save)
                        .keyboardShortcut(.defaultAction).disabled(!canSave)
                        .accessibilityIdentifier("saveCreditButton")
                }
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(busy)
        .onAppear { if !store.isDemo { focused = true } }
    }

    private func save() {
        guard canSave else { return }
        let amount: Decimal
        do { amount = try APICreditAmount.parse(amountText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { failure = error.localizedDescription; return }
        busy = true; failure = nil
        Task {
            do { saved = try await store.setCredit(amount, profile: profile) }
            catch { failure = error.localizedDescription }
            busy = false
        }
    }
}

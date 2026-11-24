import AppKit
import RadarixKit
import SwiftUI

/// Runs the OAuth device flow. Closes once `completeDeviceFlow` returns, that is once the account
/// is added and has synced; closing it before GitHub accepted the sign-in cancels the flow.
struct DeviceFlowSheet: View {
    let controller: RadarixController
    /// Called when the account is added, right before the sheet closes.
    var onSignedIn: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: DeviceCode?
    @State private var errorMessage: String?
    /// Not owned by the sheet's lifetime, so the initial sync after sign-in outlives the sheet.
    @State private var flow: Task<Void, Never>?
    /// The sessions when the flow started. A session not among them is the one this flow added,
    /// also when it replaced the session of the same account.
    @State private var sessionsAtStart: [AccountSession]?
    @State private var completed = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in with GitHub").font(.headline)
            if let code {
                Text("Enter this code on GitHub:")
                Text(verbatim: code.userCode)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Copy") { copy(code.userCode) }
                    Button("Open GitHub") { openURL(code.verificationURI) }
                        .keyboardShortcut(.defaultAction)
                }
                if errorMessage == nil {
                    if accepted {
                        progress("Syncing…")
                    } else {
                        progress("Waiting for you to confirm on GitHub…")
                    }
                }
            } else if errorMessage == nil {
                progress("Requesting a code…")
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            guard flow == nil else { return }
            sessionsAtStart = controller.sessions
            flow = Task { await run() }
        }
        .onDisappear {
            // Closed before GitHub accepted the sign-in: stop polling GitHub. Once it did, the
            // account is added and its first sync must not be cut short.
            if !completed, !accepted { flow?.cancel() }
        }
    }

    /// GitHub accepted the sign-in and the account is added; `completeDeviceFlow` goes on with
    /// its first sync.
    private var accepted: Bool {
        guard let sessionsAtStart else { return false }
        return controller.sessions.contains { session in !sessionsAtStart.contains { $0 === session } }
    }

    private func progress(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func run() async {
        do {
            let code = try await controller.startDeviceFlow()
            self.code = code
            try await controller.completeDeviceFlow(code)
            completed = true
            onSignedIn()
            dismiss()
        } catch {
            // Closing the sheet is not an error, whatever form the cancellation takes.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = AppModel.message(for: error)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

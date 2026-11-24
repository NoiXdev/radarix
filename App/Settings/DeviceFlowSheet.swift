import AppKit
import RadarixKit
import SwiftUI

/// Runs the OAuth device flow. Closes once signed in; closing it earlier cancels the flow.
struct DeviceFlowSheet: View {
    let controller: RadarixController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: DeviceCode?
    @State private var errorMessage: String?
    /// Not owned by the sheet's lifetime, so the initial sync after sign-in outlives the sheet.
    @State private var flow: Task<Void, Never>?

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
                    progress("Waiting for you to confirm on GitHub…")
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
            flow = Task { await run() }
        }
        // `completeDeviceFlow` goes on with the first sync after signing in; that is not a wait for the user.
        .onChange(of: isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
        .onDisappear {
            // Closed before sign-in finished: stop polling GitHub.
            if !isSignedIn { flow?.cancel() }
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = controller.auth { true } else { false }
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

import AppKit
import RadarixKit
import SwiftUI

/// Runs the OAuth device flow while shown. Closing the sheet cancels the wait.
struct DeviceFlowSheet: View {
    let controller: RadarixController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: DeviceCode?
    @State private var errorMessage: String?

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
        // `.task` is cancelled when the sheet closes, which stops the polling.
        .task { await run() }
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

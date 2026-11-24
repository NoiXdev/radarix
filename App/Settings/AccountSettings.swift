import RadarixKit
import SwiftUI

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showingDeviceFlow = false
    @State private var confirmingReset = false
    @State private var errorMessage: String?

    private var controller: RadarixController { model.controller }

    var body: some View {
        Form {
            switch controller.auth {
            case .signedOut:
                SignInSection(title: "Sign in with GitHub", showingDeviceFlow: $showingDeviceFlow)
            case .needsReauth(let login):
                Section {
                    Label(
                        "GitHub no longer accepts the sign-in for \(login). Sign in again to continue syncing.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                SignInSection(title: "Sign in again", showingDeviceFlow: $showingDeviceFlow)
                AccountInfoSection()
                accountActions
            case .signedIn:
                AccountInfoSection()
                accountActions
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingDeviceFlow) {
            DeviceFlowSheet(controller: controller)
        }
        .confirmationDialog("Reset all data?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset all data", role: .destructive) {
                perform { try controller.resetAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your sign-in, your watched repositories and what you have seen from this Mac.")
        }
    }

    private var accountActions: some View {
        Section {
            HStack {
                Button("Sign out") {
                    perform { try controller.signOut() }
                }
                Spacer()
                Button("Reset all data…", role: .destructive) {
                    confirmingReset = true
                }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = AppModel.message(for: error)
        }
    }
}

/// "Sign in with GitHub" plus the personal access token under "Advanced".
private struct SignInSection: View {
    let title: LocalizedStringKey
    @Binding var showingDeviceFlow: Bool

    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Button(title) { showingDeviceFlow = true }
                .disabled(!model.isDeviceFlowAvailable || isSigningIn)
            if !model.isDeviceFlowAvailable {
                Text("Sign-in with GitHub is not set up in this build. Use a personal access token under Advanced.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            DisclosureGroup("Advanced") {
                SecureField("Personal access token", text: $token)
                HStack {
                    Button("Use token", action: signIn)
                        .disabled(trimmedToken.isEmpty || isSigningIn)
                    if isSigningIn {
                        ProgressView().controlSize(.small)
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Text("Classic token: repo and read:org. Fine-grained token: read access to metadata, issues and pull requests.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func signIn() {
        let value = trimmedToken
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await model.controller.signIn(token: value, kind: .personalToken)
                token = ""
            } catch {
                errorMessage = AppModel.message(for: error)
            }
            isSigningIn = false
        }
    }
}

private struct AccountInfoSection: View {
    @Environment(AppModel.self) private var model

    private var controller: RadarixController { model.controller }

    var body: some View {
        Section {
            if let account = controller.account {
                LabeledContent("Account") { Text(verbatim: account.login) }
            }
            LabeledContent("Signed in with") { Text(credentialKind) }
            LabeledContent("Rate limit") { Text(rateLimit) }
            LabeledContent("Last sync") {
                HStack(spacing: 6) {
                    if controller.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                    Text(lastSync)
                }
            }
        }
    }

    private var credentialKind: String {
        switch controller.credentialKind {
        case .oauth: String(localized: "GitHub sign-in")
        case .personalToken: String(localized: "Personal access token")
        case nil: "–"
        }
    }

    private var rateLimit: String {
        guard let limit = controller.lastReport?.rateLimit else { return "–" }
        let reset = limit.resetAt.formatted(date: .omitted, time: .shortened)
        return String(localized: "\(limit.remaining) / \(limit.limit), resets at \(reset)")
    }

    private var lastSync: String {
        guard let date = controller.lastSyncAt else { return String(localized: "Not yet") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

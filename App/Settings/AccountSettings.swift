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
            // Shows the first account only until this tab lists every account.
            if let session = controller.sessions.first {
                if session.auth == .needsReauth {
                    Section {
                        Label(
                            "GitHub no longer accepts the sign-in for \(session.login). Sign in again to continue syncing.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                    SignInSection(title: "Sign in again", showingDeviceFlow: $showingDeviceFlow)
                }
                AccountInfoSection(session: session)
                accountActions
            } else {
                SignInSection(title: "Sign in with GitHub", showingDeviceFlow: $showingDeviceFlow)
                resetSection
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
                perform { try model.resetAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your sign-in, your watched repositories and what you have seen from this Mac.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset all data…", role: .destructive) {
                confirmingReset = true
            }
        }
    }

    private var accountActions: some View {
        Section {
            HStack {
                Button("Sign out") {
                    perform { try model.signOut() }
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Personal access token")
                    // The bare form-row field has no visible edge; a bordered box reads as an input.
                    SecureField("Personal access token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit { if !trimmedToken.isEmpty && !isSigningIn { signIn() } }
                }
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
                try await model.controller.addAccount(token: value, kind: .personalToken)
                token = ""
            } catch {
                errorMessage = AppModel.message(for: error)
            }
            isSigningIn = false
        }
    }
}

private struct AccountInfoSection: View {
    let session: AccountSession

    var body: some View {
        Section {
            LabeledContent("Account") { Text(verbatim: session.login) }
            LabeledContent("Signed in with") { Text(credentialKind) }
            LabeledContent("Rate limit") { Text(rateLimit) }
            LabeledContent("Last sync") {
                HStack(spacing: 6) {
                    if session.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                    Text(lastSync)
                }
            }
            if let problem = syncProblem {
                Text(problem)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var syncProblem: String? {
        switch session.syncProblem {
        case .offline:
            String(localized: "Can't reach GitHub. Showing saved data.")
        case .rateLimited(let until) where until > .now:
            String(localized: "GitHub's rate limit is reached. Radarix syncs again after \(until.formatted(date: .omitted, time: .shortened)).")
        case .rateLimited, nil:
            nil
        }
    }

    private var credentialKind: String {
        switch session.credentialKind {
        case .oauth: String(localized: "GitHub sign-in")
        case .personalToken: String(localized: "Personal access token")
        }
    }

    private var rateLimit: String {
        guard let limit = session.lastReport?.rateLimit else { return "–" }
        let reset = limit.resetAt.formatted(date: .omitted, time: .shortened)
        return String(localized: "\(limit.remaining) / \(limit.limit), resets at \(reset)")
    }

    private var lastSync: String {
        guard let date = session.lastSyncAt else { return String(localized: "Not yet") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

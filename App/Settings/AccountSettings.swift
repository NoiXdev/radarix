import RadarixKit
import SwiftUI

/// The Accounts tab: every signed-in account with its state, adding and removing accounts, and
/// the reset. Signed out, it is the sign-in itself.
struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showingDeviceFlow = false
    @State private var showingAddAccount = false
    /// The add sheet was opened by "Sign in again", so landing on a listed account is the point.
    @State private var signingInAgain = false
    @State private var confirmingReset = false
    @State private var errorMessage: String?

    private var controller: RadarixController { model.controller }

    var body: some View {
        Form {
            if controller.sessions.isEmpty {
                SignInSection(title: "Sign in with GitHub", showingDeviceFlow: $showingDeviceFlow)
            } else {
                ForEach(controller.sessions, id: \.accountID) { session in
                    AccountDetailsSection(
                        session: session,
                        signInAgain: {
                        signingInAgain = true
                        showingAddAccount = true
                    },
                        remove: { perform { try model.removeAccount(session.accountID) } }
                    )
                }
                Section {
                    Button("Add account…") {
                        signingInAgain = false
                        showingAddAccount = true
                    }
                }
            }
            Section {
                Button("Reset all data…", role: .destructive) {
                    confirmingReset = true
                }
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
        .sheet(isPresented: $showingAddAccount) {
            AddAccountSheet(isSigningInAgain: signingInAgain)
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

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = AppModel.message(for: error)
        }
    }
}

/// Today's sign-in in a sheet, for another account or a new sign-in of one in the list.
/// Closes once the account is added, which includes its first sync. When adding lands on an
/// account already in the list (github.com was signed in to it), it stays open and says so.
private struct AddAccountSheet: View {
    let isSigningInAgain: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeviceFlow = false
    /// What the device flow signed in as; handled once its sheet has closed.
    @State private var deviceFlowResult: AddedAccount?
    /// The login of an account that was already in the list.
    @State private var alreadyAdded: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                SignInSection(
                    title: "Sign in with GitHub",
                    showingDeviceFlow: $showingDeviceFlow,
                    note: "Make sure the right account is signed in on github.com.",
                    onSignedIn: handle
                )
                if let alreadyAdded {
                    Section {
                        Label {
                            Text("\(alreadyAdded) is already added. To add another account, sign in to it on github.com first, or use a token of that account.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460, height: 470)
        .sheet(isPresented: $showingDeviceFlow, onDismiss: {
            if let deviceFlowResult { handle(deviceFlowResult) }
            deviceFlowResult = nil
        }) {
            DeviceFlowSheet(controller: model.controller, onSignedIn: { deviceFlowResult = $0 })
        }
    }

    private func handle(_ added: AddedAccount) {
        if added.isNew || isSigningInAgain {
            dismiss()
        } else {
            alreadyAdded = added.login
        }
    }
}

/// "Sign in with GitHub" plus the personal access token under "Advanced".
private struct SignInSection: View {
    let title: LocalizedStringKey
    @Binding var showingDeviceFlow: Bool
    /// A line under the sign-in button.
    var note: LocalizedStringKey?
    /// Called with the account the token belongs to, once it is added.
    var onSignedIn: (AddedAccount) -> Void = { _ in }

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
            if let note {
                Text(note)
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
                Text("Classic token: repo and read:org. Fine-grained token: read access to metadata, and read and write access to issues and pull requests, which assigning needs.")
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
                let added = try await model.controller.addAccount(token: value, kind: .personalToken)
                token = ""
                isSigningIn = false
                onSignedIn(added)
            } catch {
                errorMessage = AppModel.message(for: error)
                isSigningIn = false
            }
        }
    }
}

/// One account: who it is, how it signed in, whether it syncs, and its actions.
private struct AccountDetailsSection: View {
    let session: AccountSession
    let signInAgain: () -> Void
    let remove: () -> Void

    var body: some View {
        Section {
            LabeledContent("Account") { Text(verbatim: session.login) }
            // A session restored without a credential does not know how it signed in.
            if let credentialKind {
                LabeledContent("Signed in with") { Text(credentialKind) }
            }
            LabeledContent("Rate limit") { Text(rateLimit) }
            LabeledContent("Last sync") {
                HStack(spacing: 6) {
                    if session.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                    Text(lastSync)
                }
            }
            if session.auth == .needsReauth {
                Label(
                    "GitHub no longer accepts the sign-in for \(session.login). Sign in again to continue syncing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else if let problem = syncProblem {
                Text(problem)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if session.auth == .needsReauth {
                    Button("Sign in again", action: signInAgain)
                }
                Spacer()
                // No confirmation: the account's data stays, so adding it again resumes it.
                Button("Remove", action: remove)
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

    private var credentialKind: String? {
        switch session.credentialKind {
        case .oauth: String(localized: "GitHub sign-in")
        case .personalToken: String(localized: "Personal access token")
        case nil: nil
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

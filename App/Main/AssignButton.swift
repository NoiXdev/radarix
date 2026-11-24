import OSLog
import RadarixKit
import SwiftUI

/// "Assign to me" or "Unassign me" for one item, for the account that owns its repository.
/// Hidden when no account owns it. Disabled with a progress indicator while a request for the
/// item runs, wherever it started, so the menu, the inspector and the window agree.
struct AssignButton: View {
    let key: ItemKey

    @Environment(AppModel.self) private var model
    @State private var errorMessage: String?
    /// False once the view is gone; a late failure then goes to the app-wide alert.
    @State private var isPresent = false

    private var controller: RadarixController { model.controller }

    var body: some View {
        content
            .onAppear { isPresent = true }
            .onDisappear { isPresent = false }
    }

    @ViewBuilder private var content: some View {
        if let assigned = controller.isAssignedToOwner(key) {
            let isBusy = controller.assigningKeys.contains(key)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button(assigned ? "Unassign me" : "Assign to me") {
                        errorMessage = nil
                        Task {
                            do {
                                try await controller.setAssigned(!assigned, key: key)
                            } catch {
                                if isPresent {
                                    errorMessage = AppModel.message(for: error)
                                } else {
                                    model.reportAssignFailure(error, key: key)
                                }
                            }
                        }
                    }
                    .disabled(isBusy)
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The context menu's entry. A menu has no room for a progress indicator, so it only disables.
/// A failure is logged and shown in the main window's alert.
struct AssignMenuButton: View {
    let key: ItemKey
    let setAssigned: @MainActor (ItemKey, Bool) async throws -> Void

    @Environment(AppModel.self) private var model

    private static let log = Logger(subsystem: "dev.noix.radarix", category: "assign")

    var body: some View {
        if let assigned = model.controller.isAssignedToOwner(key) {
            Button(assigned ? "Unassign me" : "Assign to me") {
                Task {
                    do {
                        try await setAssigned(key, !assigned)
                    } catch {
                        Self.log.error("Assigning failed: \(String(describing: error), privacy: .public)")
                        model.reportAssignFailure(error, key: key)
                    }
                }
            }
            .disabled(model.controller.assigningKeys.contains(key))
        }
    }
}

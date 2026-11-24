import RadarixKit
import SwiftUI

/// The menu bar glyph with the count of new and updated items, or `!` when the sign-in was rejected.
/// Showing the count never marks anything seen.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var controller: RadarixController { model.controller }

    var body: some View {
        let total = controller.counts(in: nil).total
        HStack(spacing: 3) {
            Image("MenuBarGlyph")
            if needsReauth {
                Text(verbatim: "!")
            } else if total > 0 {
                Text(total, format: .number).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(needsReauth ? Text("Radarix, sign in again") : Text("Radarix, \(total) new or updated"))
        // The label exists from launch, unlike the main window, which the window group suppresses.
        .task {
            if model.claimLaunchWindow() { openWindow(id: "main") }
        }
    }

    private var needsReauth: Bool {
        if case .needsReauth = controller.auth { true } else { false }
    }
}

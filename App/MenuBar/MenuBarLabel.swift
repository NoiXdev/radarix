import RadarixKit
import SwiftUI

/// The menu bar glyph with the count of new and updated items of every account. A `!` follows the
/// count when the sign-in of an account was rejected, and stands alone when that is every account.
/// Showing the count never marks anything seen.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var controller: RadarixController { model.controller }

    var body: some View {
        let total = controller.counts(in: nil).total
        HStack(spacing: 3) {
            Image("MenuBarGlyph")
            if allNeedReauth {
                Text(verbatim: "!")
            } else if anyNeedsReauth {
                // The healthy accounts still sync: their count stays visible.
                Text(verbatim: total > 0 ? total.formatted() + "!" : "!").monospacedDigit()
            } else if total > 0 {
                Text(total, format: .number).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(total: total))
        // The label exists from launch, unlike the main window, which the window group suppresses.
        // A window opened for a launch link appears first; the yield leaves it one more turn.
        .task {
            await Task.yield()
            if await model.claimLaunchWindow() { openWindow(id: "main") }
        }
    }

    private var anyNeedsReauth: Bool { !controller.needsReauth.isEmpty }

    private var allNeedReauth: Bool { anyNeedsReauth && controller.needsReauth.count == controller.sessions.count }

    private func accessibilityLabel(total: Int) -> Text {
        if allNeedReauth { return Text("Radarix, sign in again") }
        if anyNeedsReauth { return Text("Radarix, \(total) new or updated, sign in again") }
        return Text("Radarix, \(total) new or updated")
    }
}

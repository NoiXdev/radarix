import RadarixKit
import SwiftUI

@main
struct RadarixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }
    /// Each window's content reports its window, so only these count for the Dock icon.
    private var windows: WindowTracker { appDelegate.windows }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .background(WindowMarker(kind: .main, tracker: windows))
        }
        .defaultSize(width: 1040, height: 640)
        // Opened by the menu bar label instead, so a launch at login shows no window.
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [DeepLink.scheme])
        .environment(model)
        .commands { MainCommands(controller: model.controller) }
        // One window per item; opening an item that has one brings it to the front.
        WindowGroup(id: "description", for: ItemKey.self) { $key in
            if let key {
                DescriptionWindow(key: key)
                    .background(WindowMarker(kind: .description, tracker: windows))
            }
        }
        .defaultSize(width: 720, height: 640)
        // File > New would open a window with a nil key.
        .commandsRemoved()
        .defaultLaunchBehavior(.suppressed)
        // A launch at login shows no window, so none comes back from the last session either.
        .restorationBehavior(.disabled)
        // Deep links belong to the main window.
        .handlesExternalEvents(matching: [])
        .environment(model)
        Settings {
            SettingsView()
                .background(WindowMarker(kind: .settings, tracker: windows))
        }
        .environment(model)
        // A copy handing over to another instance shows no item, so it cannot change settings.
        MenuBarExtra(isInserted: Binding(get: { !model.isYielding }, set: { _ in })) {
            MenuBarPopover()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Refresh (⌘R) and Mark all as seen (⇧⌘K) in the View menu.
private struct MainCommands: Commands {
    let controller: RadarixController

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Refresh") {
                Task { await controller.refresh() }
            }
            .keyboardShortcut("r")
            Button("Mark all as seen") {
                controller.markAllSeen()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}

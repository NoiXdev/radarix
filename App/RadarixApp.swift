import RadarixKit
import SwiftUI

@main
struct RadarixApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .onAppear { model.start() }
        }
        .defaultSize(width: 1040, height: 640)
        .environment(model)
        .commands { MainCommands(controller: model.controller) }
        Settings {
            SettingsView()
                .onAppear { model.start() }
        }
        .environment(model)
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

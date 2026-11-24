import SwiftUI
import RadarixKit

@main
struct RadarixApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Text("Radarix")
                .onAppear { model.start() }
        }
        .environment(model)
        Settings {
            SettingsView()
                .onAppear { model.start() }
        }
        .environment(model)
    }
}

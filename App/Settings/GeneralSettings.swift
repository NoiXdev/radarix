import RadarixKit
import SwiftUI

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Layout", selection: setting(\.layout)) {
                    Text("Sidebar").tag(MainLayout.sidebar)
                    Text("Single list").tag(MainLayout.grouped)
                }
                Picker("Refresh every", selection: setting(\.refreshInterval)) {
                    ForEach(AppSettings.refreshIntervals, id: \.self) { interval in
                        Text("\(Int(interval / 60)) minutes").tag(interval)
                    }
                }
            }
            Section {
                Picker("Bot items", selection: setting(\.botDisplay)) {
                    Text("Badge").tag(BotDisplayMode.badge)
                    Text("Own group").tag(BotDisplayMode.grouped)
                    Text("Hidden").tag(BotDisplayMode.hidden)
                }
                Toggle("Notify about bot items", isOn: setting(\.notifyBots))
                Toggle("Notify about updated items", isOn: setting(\.notifyUpdated))
            }
        }
        .formStyle(.grouped)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        let controller = model.controller
        return Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { value in controller.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }
}

import AppKit
import RadarixKit
import SwiftUI

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    /// The system's login item status, read on appear and whenever Radarix becomes active.
    @State private var opensAtLogin = false
    @State private var loginItemNeedsApproval = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                // A closure, not `set: setOpenAtLogin`: Swift 6.3 (Xcode 26) crashes in IRGen on
                // the method reference converted to an @isolated(any) setter.
                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: { setOpenAtLogin($0) }))
                if let loginItemError {
                    Text(loginItemError)
                        .foregroundStyle(.red)
                } else if loginItemNeedsApproval {
                    HStack {
                        Text("Allow Radarix in System Settings → Login Items.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                }
                Toggle("Start in the background", isOn: setting(\.startInBackground))
                Toggle(
                    "Hide from the Dock when the window is closed",
                    isOn: Binding(
                        get: { model.controller.settings.menuBarOnlyWhenClosed },
                        set: { model.setMenuBarOnlyWhenClosed($0) })
                )
            }
            Section {
                Picker("Layout", selection: setting(\.layout)) {
                    Text("Sidebar").tag(MainLayout.sidebar)
                    Text("Single list").tag(MainLayout.grouped)
                }
                Picker("Show description", selection: setting(\.descriptionPlacement)) {
                    Text("In a window").tag(DescriptionPlacement.window)
                    Text("In the sidebar").tag(DescriptionPlacement.sidebar)
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
                if model.notifications.authorizationDenied {
                    HStack {
                        Text("Notifications are turned off for Radarix in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Notifications") { NSWorkspace.shared.open(Self.notificationSettingsURL) }
                    }
                }
            }
            if let updates = model.updates {
                Section {
                    Toggle(
                        "Check for updates",
                        isOn: Binding(
                            get: { model.controller.settings.checkForUpdates }, set: { model.setCheckForUpdates($0) })
                    )
                    if let release = updates.available {
                        Text("Version \(release.version.description) is available.")
                        Link("View release", destination: release.url)
                        Text("Update with: brew upgrade --cask radarix")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: readLoginItem)
        .task { await model.notifications.refreshAuthorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLoginItem()
            Task { await model.notifications.refreshAuthorizationStatus() }
        }
    }

    private static let notificationSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = AppModel.message(for: error)
        }
        readLoginItem()
    }

    /// Shows the real status and mirrors it into the settings. A registration that still
    /// waits for approval shows as on, so it can be turned off again.
    private func readLoginItem() {
        loginItemNeedsApproval = LoginItem.needsApproval
        opensAtLogin = LoginItem.isEnabled || loginItemNeedsApproval
        let enabled = LoginItem.isEnabled
        if model.controller.settings.openAtLogin != enabled {
            model.controller.updateSettings { $0.openAtLogin = enabled }
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        let controller = model.controller
        return Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { value in controller.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }
}

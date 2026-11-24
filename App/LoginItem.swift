import ServiceManagement

/// Opening Radarix at login, as the system records it.
enum LoginItem {
    private static var service: SMAppService { .mainApp }

    static var isEnabled: Bool { service.status == .enabled }

    /// Registered, but the user still has to allow it in System Settings.
    static var needsApproval: Bool { service.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

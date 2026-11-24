import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountSettings()
            }
            Tab("Repositories", systemImage: "folder") {
                RepositorySettings()
            }
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
        }
        .frame(width: 560, height: 480)
    }
}

import SwiftUI

@main
struct OpenVaultApp: App {
    @State private var model = AppModel(environment: .live())

    var body: some Scene {
        WindowGroup {
            RootScene(model: model)
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
        }
    }
}

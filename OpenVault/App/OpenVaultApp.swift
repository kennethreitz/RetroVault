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

        WindowGroup("OpenVault Player", for: LibretroRunRequest.self) { $request in
            if let request {
                LibretroGameView(request: request)
            } else {
                ContentUnavailableView(
                    "No Game Selected",
                    systemImage: "gamecontroller"
                )
            }
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)

        WindowGroup("OpenVault Logs", id: "diagnostics") {
            LogViewerView()
        }
        .defaultSize(width: 980, height: 580)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
        }
    }
}

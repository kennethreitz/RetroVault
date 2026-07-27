import AppKit
import SwiftUI

@MainActor
private final class OpenVaultApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard
            let iconURL = Bundle.main.url(
                forResource: "AppIcon",
                withExtension: "icns"
            ),
            let icon = NSImage(contentsOf: iconURL)
        else {
            OpenVaultLog.application.error(
                "Could not load the bundled application icon."
            )
            return
        }

        NSApplication.shared.applicationIconImage = icon
        OpenVaultLog.application.debug(
            "Applied the bundled application icon."
        )
    }
}

@main
struct OpenVaultApp: App {
    @NSApplicationDelegateAdaptor(OpenVaultApplicationDelegate.self)
    private var applicationDelegate
    @State private var model = AppModel(environment: .live())

    var body: some Scene {
        WindowGroup {
            RootScene(model: model)
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            DiagnosticsCommands()
        }

        Window("OpenVault Big Picture", id: BigPictureScene.id) {
            if let libraryModel = model.libraryModel {
                BigPictureView(model: libraryModel)
            } else {
                ContentUnavailableView(
                    "Connect to RomM First",
                    systemImage: "tv"
                )
            }
        }
        .defaultSize(width: 1_280, height: 720)
        .commands {
            DiagnosticsCommands()
        }

        WindowGroup("OpenVault Player", for: LibretroRunRequest.self) { $request in
            if let request {
                LibretroGameView(
                    request: request,
                    service: model.libraryService
                )
            } else {
                ContentUnavailableView(
                    "No Game Selected",
                    systemImage: "gamecontroller"
                )
            }
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            DiagnosticsCommands()
        }

        WindowGroup("OpenVault Logs", id: "diagnostics") {
            LogViewerView()
        }
        .defaultSize(width: 980, height: 580)
        .windowResizability(.contentMinSize)
        .commands {
            DiagnosticsCommands()
        }

        Settings {
            SettingsView(model: model)
        }
        .commands {
            DiagnosticsCommands()
        }
    }
}

private struct DiagnosticsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Show Logs") {
                openWindow(id: "diagnostics")
            }
            .keyboardShortcut("l", modifiers: .command)
        }
    }
}

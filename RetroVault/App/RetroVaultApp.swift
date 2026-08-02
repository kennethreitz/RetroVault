import AppKit
@preconcurrency import GameController
import SwiftUI

@MainActor
private final class RetroVaultApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted emulators become the foreground application while RetroVault
        // continues publishing native controllers through its DSU relay.
        // macOS otherwise stops delivering GameController input as soon as
        // Cemu takes focus, which leaves relay-backed player slots connected
        // but frozen.
        GCController.shouldMonitorBackgroundEvents = true
        RetroVaultLog.application.debug(
            "Enabled background controller monitoring for hosted emulators."
        )

        DSUConnection.shared.apply(layout: DSUPreferences.layout())
        DSUConnection.shared.apply(DSUPreferences.activeConfiguration())

        guard
            let iconURL = Bundle.main.url(
                forResource: "AppIcon",
                withExtension: "icns"
            ),
            let icon = NSImage(contentsOf: iconURL)
        else {
            RetroVaultLog.application.error(
                "Could not load the bundled application icon."
            )
            return
        }

        NSApplication.shared.applicationIconImage = icon
        RetroVaultLog.application.debug(
            "Applied the bundled application icon."
        )
    }
}

@main
struct RetroVaultApp: App {
    @NSApplicationDelegateAdaptor(RetroVaultApplicationDelegate.self)
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
            GameInfoCommands()
            FullScreenCommands()
        }

        WindowGroup("RetroVault Player", for: LibretroRunRequest.self) { $request in
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
            GameInfoCommands()
            FullScreenCommands()
        }

        WindowGroup("Game Information", for: GameInfoRequest.self) { $request in
            if
                let request,
                let libraryModel = model.libraryModel
            {
                GameInfoView(
                    request: request,
                    session: libraryModel.session,
                    service: model.libraryService
                )
            } else {
                ContentUnavailableView(
                    "Game Information Unavailable",
                    systemImage: "info.circle"
                )
            }
        }
        .defaultSize(width: 780, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            DiagnosticsCommands()
            GameInfoCommands()
            FullScreenCommands()
        }

        WindowGroup("RetroVault Logs", id: "diagnostics") {
            LogViewerView()
        }
        .defaultSize(width: 980, height: 580)
        .windowResizability(.contentMinSize)
        .commands {
            DiagnosticsCommands()
            GameInfoCommands()
            FullScreenCommands()
        }

        Settings {
            SettingsView(model: model)
        }
        .commands {
            DiagnosticsCommands()
            GameInfoCommands()
            FullScreenCommands()
        }
    }
}

private struct FullScreenCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Toggle Full Screen") {
                NSApplication.shared.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: .command)
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

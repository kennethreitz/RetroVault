import AppKit
@preconcurrency import GameController
import SwiftUI

@MainActor
private final class RetroVaultApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationIsPending = false
    private var terminationReplyWasSent = false
    private var terminationFallback: Task<Void, Never>?

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

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard
            !terminationIsPending,
            LibretroApplicationTerminationCoordinator.shared.hasActiveSession
        else {
            return terminationIsPending ? .terminateLater : .terminateNow
        }

        terminationIsPending = true
        terminationReplyWasSent = false
        RetroVaultLog.application.notice(
            "Application termination requested during gameplay; preserving the active session first."
        )

        LibretroApplicationTerminationCoordinator.shared.checkpointAndStop {
            self.finishDeferredTermination(in: sender)
        }

        // A faulty third-party core must not make RetroVault impossible to
        // quit. Healthy cores normally complete this handshake in well under
        // a second.
        terminationFallback = Task { @MainActor [weak self, weak sender] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, let sender else {
                return
            }
            RetroVaultLog.application.error(
                "Timed out while preserving the active session during application termination."
            )
            finishDeferredTermination(in: sender)
        }
        return .terminateLater
    }

    private func finishDeferredTermination(in application: NSApplication) {
        guard !terminationReplyWasSent else {
            return
        }
        terminationReplyWasSent = true
        terminationFallback?.cancel()
        terminationFallback = nil
        RetroVaultLog.application.notice(
            "Active gameplay session was preserved; completing application termination."
        )
        application.reply(toApplicationShouldTerminate: true)
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
            AcknowledgementsCommands()
            DiagnosticsCommands()
            GameInfoCommands()
            LibraryCommands()
            GameplayCommands()
            FullScreenCommands()
            RetroVaultHelpCommands()
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

        WindowGroup("RetroVault Logs", id: "diagnostics") {
            LogViewerView()
        }
        .defaultSize(width: 980, height: 580)
        .windowResizability(.contentMinSize)

        WindowGroup("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The common menu-bar surface for hosted emulators that do not expose
/// Libretro's pause, reset, rewind, or quick-state controls.
struct HostedGameplayControl {
    let title: String
    let canStop: Bool
    private let stopAction: @MainActor () -> Void

    init(
        title: String,
        canStop: Bool,
        stop: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.canStop = canStop
        stopAction = stop
    }

    @MainActor
    func stop() {
        stopAction()
    }
}

private struct HostedGameplayControlFocusedValueKey: FocusedValueKey {
    typealias Value = HostedGameplayControl
}

extension FocusedValues {
    var hostedGameplayControl: HostedGameplayControl? {
        get { self[HostedGameplayControlFocusedValueKey.self] }
        set { self[HostedGameplayControlFocusedValueKey.self] = newValue }
    }
}

private struct GameplayCommands: Commands {
    @FocusedValue(\.libretroGameplayControl) private var gameplayControl
    @FocusedValue(\.hostedGameplayControl) private var hostedGameplayControl
    @FocusedValue(\.retroVaultLibraryControl) private var libraryControl

    var body: some Commands {
        CommandMenu("Game") {
            if let gameplayControl {
                Button(gameplayControl.isPaused ? "Resume" : "Pause") {
                    gameplayControl.togglePause()
                }
                .keyboardShortcut("p", modifiers: .command)

                Button(gameplayControl.isMuted ? "Unmute" : "Mute") {
                    gameplayControl.toggleMute()
                }
                .keyboardShortcut("m", modifiers: .command)

                Divider()

                Button("Rewind One Step") {
                    gameplayControl.rewind()
                }
                .disabled(!gameplayControl.canRewind)

                Divider()

                Button("Save Quick State") {
                    gameplayControl.saveQuickState()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!gameplayControl.canSaveQuickState)

                Button("Load Quick State") {
                    gameplayControl.loadQuickState()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!gameplayControl.canLoadQuickState)

                Divider()

                Button("Reset Game") {
                    gameplayControl.reset()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Stop Game", role: .destructive) {
                    gameplayControl.stop()
                }
            } else if let hostedGameplayControl {
                Button("Stop \(hostedGameplayControl.title)", role: .destructive) {
                    hostedGameplayControl.stop()
                }
                .disabled(!hostedGameplayControl.canStop)
            } else if let libraryControl {
                libraryGameCommands(libraryControl)
            } else {
                unavailableGameCommands
            }
        }
    }

    @ViewBuilder
    private func libraryGameCommands(
        _ libraryControl: RetroVaultLibraryControl
    ) -> some View {
        Button(
            libraryControl.hasResumeState
                ? "Resume \(libraryControl.selectedGameTitle ?? "Game")"
                : "Play \(libraryControl.selectedGameTitle ?? "Game")"
        ) {
            libraryControl.play()
        }
        .disabled(libraryControl.selectedGameTitle == nil)

        Button("Play from Beginning") {
            libraryControl.playFromBeginning()
        }
        .disabled(
            libraryControl.selectedGameTitle == nil
                || !libraryControl.hasResumeState
        )

        Button("Game Options…") {
            libraryControl.showOptions()
        }
        .disabled(
            libraryControl.selectedGameTitle == nil
                && libraryControl.selectedSystemTitle == nil
        )

        Divider()

        Button(
            libraryControl.isFavorite
                ? "Remove from Favorite Games"
                : "Add to Favorite Games"
        ) {
            libraryControl.toggleFavorite()
        }
        .disabled(!libraryControl.canChangeFavorite)

        Button(
            libraryControl.isDownloaded
                ? "Remove Download"
                : "Download Game"
        ) {
            libraryControl.toggleDownload()
        }
        .disabled(!libraryControl.canChangeDownload)

        Button("Manage Saves…") {
            libraryControl.manageSaves()
        }
        .disabled(!libraryControl.canManageSaves)
    }

    @ViewBuilder
    private var unavailableGameCommands: some View {
        Button("Pause") {}
            .disabled(true)
        Button("Mute") {}
            .disabled(true)
        Divider()
        Button("Rewind One Step") {}
            .disabled(true)
        Divider()
        Button("Save Quick State") {}
            .disabled(true)
        Button("Load Quick State") {}
            .disabled(true)
        Divider()
        Button("Reset Game") {}
            .disabled(true)
        Divider()
        Button("Stop Game") {}
            .disabled(true)
    }
}

private struct LibraryCommands: Commands {
    @FocusedValue(\.retroVaultLibraryControl) private var libraryControl

    var body: some Commands {
        CommandMenu("Library") {
            Button("Home") {
                libraryControl?.showHome()
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(libraryControl == nil)

            Divider()

            Button("Downloaded Games") {
                libraryControl?.showDownloaded()
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(libraryControl == nil)

            Button("Recently Played") {
                libraryControl?.showRecentlyPlayed()
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(libraryControl == nil)

            Button("Favorite Games") {
                libraryControl?.showFavorites()
            }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(libraryControl == nil)

            Button("Recently Added") {
                libraryControl?.showRecentlyAdded()
            }
            .keyboardShortcut("5", modifiers: .command)
            .disabled(libraryControl == nil)

            Button("All Games") {
                libraryControl?.showAllGames()
            }
            .keyboardShortcut("6", modifiers: .command)
            .disabled(libraryControl == nil)

            Divider()

            Button("Save Center") {
                libraryControl?.showSaveCenter()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(libraryControl == nil)

            Button("Sync Status…") {
                libraryControl?.showSyncStatus()
            }
            .disabled(libraryControl == nil)

            Button("Sync Now") {
                libraryControl?.synchronize()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(
                libraryControl == nil
                    || libraryControl?.isSynchronizing == true
                    || libraryControl?.isServerReachable != true
            )

            Divider()

            Button("Open RomM in Browser") {
                libraryControl?.openRomM()
            }
            .disabled(libraryControl == nil)
        }
    }
}

private struct AcknowledgementsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Acknowledgements…") {
                openWindow(id: "acknowledgements")
            }
        }
    }
}

private struct AcknowledgementsView: View {
    private let cores = BundledCoreAcknowledgement.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Acknowledgements")
                        .font(.largeTitle.bold())
                    Text(
                        "RetroVault is built on open-source software. Each component remains subject to its own license."
                    )
                    .foregroundStyle(.secondary)
                }

                acknowledgementSection("RetroVault") {
                    acknowledgementRow(
                        name: "RetroVault",
                        detail: "GNU General Public License, version 2 or later, with the RetroVault Core Linking Exception",
                        sourceURL: URL(string: "https://github.com/kennethreitz/RetroVault"),
                        licenseURL: URL(string: "https://github.com/kennethreitz/RetroVault/blob/main/LICENSE")
                    )
                }

                acknowledgementSection("Swift Packages") {
                    acknowledgementRow(
                        name: "Nuke 13.0.6",
                        detail: "MIT License · Alexander Grebenyuk",
                        sourceURL: URL(string: "https://github.com/kean/Nuke"),
                        licenseURL: URL(string: "https://github.com/kean/Nuke/blob/13.0.6/LICENSE")
                    )
                    Divider()
                    acknowledgementRow(
                        name: "ZIPFoundation 0.9.20",
                        detail: "MIT License · Thomas Zoechling",
                        sourceURL: URL(string: "https://github.com/weichsel/ZIPFoundation"),
                        licenseURL: URL(string: "https://github.com/weichsel/ZIPFoundation/blob/0.9.20/LICENSE")
                    )
                }

                acknowledgementSection("Hosted Emulators") {
                    acknowledgementRow(
                        name: "Cemu",
                        detail: "Mozilla Public License 2.0",
                        sourceURL: URL(string: "https://github.com/cemu-project/Cemu"),
                        licenseURL: URL(string: "https://github.com/cemu-project/Cemu/blob/main/LICENSE.txt")
                    )
                    Divider()
                    acknowledgementRow(
                        name: "Vita3K",
                        detail: "GNU General Public License, version 2",
                        sourceURL: URL(string: "https://github.com/Vita3K/Vita3K"),
                        licenseURL: URL(string: "https://github.com/Vita3K/Vita3K/blob/master/COPYING.txt")
                    )
                }

                acknowledgementSection("Bundled Libretro Cores") {
                    if cores.isEmpty {
                        Text(
                            "Core notices are unavailable in this development build. Release builds include the reviewed core manifest and complete license texts."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(cores.enumerated()), id: \.element.id) { index, core in
                            if index > 0 {
                                Divider()
                            }
                            acknowledgementRow(
                                name: core.displayName,
                                detail: "\(core.licenseName) · revision \(core.shortRevision)",
                                sourceURL: core.sourceURL,
                                licenseURL: core.licenseURL
                            )
                        }
                    }
                }

                Text(
                    "Complete bundled-core license texts and the reviewed manifest ship inside RetroVault. See THIRD_PARTY_NOTICES.md in the source repository for distribution details."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    private func acknowledgementSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private func acknowledgementRow(
        name: String,
        detail: String,
        sourceURL: URL?,
        licenseURL: URL?
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 18)
            HStack(spacing: 12) {
                if let sourceURL {
                    Link("Source", destination: sourceURL)
                }
                if let licenseURL {
                    Link("License", destination: licenseURL)
                }
            }
            .font(.subheadline)
        }
    }
}

private struct BundledCoreAcknowledgement: Decodable, Identifiable {
    struct Manifest: Decodable {
        let cores: [BundledCoreAcknowledgement]
    }

    struct Source: Decodable {
        let repository: URL
        let revision: String
    }

    struct License: Decodable {
        let spdx: String
        let noticeURL: URL
    }

    let id: String
    let displayName: String
    let source: Source
    let licenseInfo: License

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case source
        case licenseInfo = "license"
    }

    var shortRevision: String {
        String(source.revision.prefix(8))
    }

    var sourceURL: URL {
        source.repository
    }

    var licenseURL: URL {
        licenseInfo.noticeURL
    }

    var licenseName: String {
        licenseInfo.spdx
    }

    static func load(bundle: Bundle = .main) -> [Self] {
        guard
            let resourcesURL = bundle.resourceURL,
            let data = try? Data(
                contentsOf: resourcesURL
                    .appending(path: "Libretro", directoryHint: .isDirectory)
                    .appending(path: "CoreManifest.json")
            ),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            return []
        }
        return manifest.cores.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}

private struct FullScreenCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
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

private struct RetroVaultHelpCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .help) {
            Link(
                "RetroVault on GitHub",
                destination: URL(
                    string: "https://github.com/kennethreitz/RetroVault"
                )!
            )

            Link(
                "RomM Project Website",
                destination: URL(string: "https://romm.app")!
            )

            Divider()

            Link(
                "Report an Issue…",
                destination: URL(
                    string: "https://github.com/kennethreitz/RetroVault/issues/new/choose"
                )!
            )
        }
    }
}

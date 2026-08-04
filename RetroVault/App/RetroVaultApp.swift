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
            AcknowledgementsCommands()
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

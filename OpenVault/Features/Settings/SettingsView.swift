import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BigPictureScene.launchesAutomaticallyPreferenceKey)
    private var launchesBigPictureAutomatically = false
    @AppStorage(BigPictureScene.opensInFullScreenPreferenceKey)
    private var opensBigPictureInFullScreen =
        BigPictureScene.opensInFullScreenByDefault
    @State private var showsPurgeConfirmation = false

    var body: some View {
        Form {
            Section("Server") {
                switch model.destination {
                case let .library(session):
                    LabeledContent("Address", value: session.serverURL.value.absoluteString)
                    LabeledContent("User", value: session.username)

                    Button("Disconnect", role: .destructive) {
                        Task {
                            await model.disconnect()
                        }
                    }
                case .preparing, .connection:
                    Text("No RomM server is connected.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Library") {
                if let libraryModel = model.libraryModel {
                    Button {
                        Task {
                            await libraryModel.refresh()
                        }
                    } label: {
                        Label("Resync Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(libraryModel.isSynchronizing)

                    Button(role: .destructive) {
                        showsPurgeConfirmation = true
                    } label: {
                        Label(
                            "Purge Local Cache & Resync",
                            systemImage: "trash"
                        )
                    }
                    .disabled(libraryModel.isSynchronizing)

                    if libraryModel.isSynchronizing {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text(
                                libraryModel.isPurgingLocalCache
                                    ? "Purging local cache…"
                                    : "Synchronizing with RomM…"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage = libraryModel.refreshErrorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }

                    Text(
                        """
                        Resync replaces OpenVault's local metadata after a complete \
                        successful refresh. Purge also clears cached game details and \
                        artwork first. Neither action modifies or scans the RomM server.
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Connect to RomM to manage the local library cache.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Emulation") {
                LabeledContent("Runtime", value: "Bundled Libretro")

                Button("Open 2048 Runtime Test") {
                    openWindow(value: LibretroRunRequest.pipelineTest)
                }

                #if DEBUG
                if let testROMURL {
                    Button("Open \(testROMURL.lastPathComponent) with Gambatte") {
                        openWindow(
                            value: LibretroRunRequest(
                                title: testROMURL.deletingPathExtension().lastPathComponent,
                                coreID: "libretro-gambatte",
                                contentURL: testROMURL
                            )
                        )
                    }
                }
                #endif

                Text(
                    """
                    This content-free core verifies native video, input, local save memory, \
                    save states, and the separate player window before OpenVault enables \
                    reviewed console cores for RomM games.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Big Picture") {
                Toggle(
                    "Launch OpenVault in Big Picture",
                    isOn: $launchesBigPictureAutomatically
                )

                Toggle(
                    "Open Big Picture in Full Screen",
                    isOn: $opensBigPictureInFullScreen
                )

                Text(
                    """
                    OpenVault can launch the controller-first library automatically \
                    after restoring its RomM connection. Big Picture opens in full \
                    screen by default and can still switch between full screen and \
                    a regular window with the green window control.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Logging", value: "macOS Unified Log")

                Button {
                    openWindow(id: "diagnostics")
                } label: {
                    Label("Open Log Viewer", systemImage: "text.alignleft")
                }

                Text(
                    """
                    Shows recent and live OpenVault activity. Credentials and \
                    client tokens are never included in diagnostic messages.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .alert(
            "Purge OpenVault's Local Cache?",
            isPresented: $showsPurgeConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Purge & Resync", role: .destructive) {
                guard let libraryModel = model.libraryModel else {
                    return
                }
                Task {
                    await libraryModel.purgeLocalCacheAndResync()
                }
            }
        } message: {
            Text(
                """
                OpenVault will remove its cached library metadata, game details, and \
                artwork, then rebuild them from RomM. Exported ROMs, saves, and local \
                playback data are not removed.
                """
            )
        }
    }

    #if DEBUG
    private var testROMURL: URL? {
        guard
            let path = ProcessInfo.processInfo.environment["OPENVAULT_LIBRETRO_TEST_ROM"],
            !path.isEmpty
        else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    #endif
}

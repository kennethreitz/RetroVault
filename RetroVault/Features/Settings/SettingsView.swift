import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BigPictureScene.opensInFullScreenPreferenceKey)
    private var opensBigPictureInFullScreen =
        BigPictureScene.opensInFullScreenByDefault
    @AppStorage(LibretroTransportPreferences.enablesFastForwardKey)
    private var enablesR3FastForward =
        LibretroTransportPreferences.enabledByDefault
    @AppStorage(LibretroTransportPreferences.enablesRewindKey)
    private var enablesL3Rewind =
        LibretroTransportPreferences.enabledByDefault
    @AppStorage(LibretroVideoPreferences.filterKey)
    private var videoFilter = LibretroVideoPreferences.defaultFilter
    @AppStorage(LibretroInternalResolutionPreferences.scaleKey)
    private var internalResolution =
        LibretroInternalResolutionPreferences.defaultResolution
    @AppStorage(LibretroCorePreferences.enablesExperimentalCoresKey)
    private var enablesExperimentalCores =
        LibretroCorePreferences.enabledByDefault
    @AppStorage(LibretroPlayerPreferences.opensInFullScreenKey)
    private var opensGamesInFullScreen =
        LibretroPlayerPreferences.opensInFullScreenByDefault
    @AppStorage(LibretroWiiControllerPreferences.profileKey)
    private var wiiControllerProfile =
        LibretroWiiControllerPreferences.defaultProfile
    @AppStorage(LibretroDigitalInputPreferences.mapsLeftAnalogToDPadKey)
    private var mapsLeftAnalogToDPad =
        LibretroDigitalInputPreferences.mapsLeftAnalogToDPadByDefault
    @AppStorage(DSUPreferences.isEnabledKey)
    private var usesDSUController = DSUPreferences.enabledByDefault
    @AppStorage(DSUPreferences.hostKey)
    private var dsuHost = DSUProtocol.defaultHost
    @AppStorage(DSUPreferences.portKey)
    private var dsuPort = Int(DSUProtocol.defaultPort)
    @AppStorage(DSUPreferences.slotKey)
    private var dsuSlot = 0
    @AppStorage(DSUPreferences.layoutKey)
    private var dsuLayout = DSUPreferences.defaultLayout.rawValue
    @State private var showsPurgeConfirmation = false
    @State private var dsuStatus = DSUConnection.shared.status
    @State private var dsuReconnectTask: Task<Void, Never>?

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
                        Resync replaces RetroVault's local metadata after a complete \
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

            Section("Video") {
                Picker("Upscaling", selection: $videoFilter) {
                    ForEach(LibretroVideoFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }

                Text(videoFilter.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Internal Resolution", selection: $internalResolution) {
                    ForEach(LibretroInternalResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }

                Text(
                    """
                    Internal resolution redraws 3D games at a higher \
                    resolution instead of enlarging the picture afterwards. \
                    It applies to the PlayStation, Dreamcast, PSP, GameCube, \
                    and Wii cores, costs GPU time, and takes effect the next \
                    time a game starts. 2D cores render at a fixed resolution \
                    and ignore it.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Emulation") {
                LabeledContent("Runtime", value: "Bundled Libretro")

                Picker("Wii Controller", selection: $wiiControllerProfile) {
                    ForEach(LibretroWiiControllerProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }

                Text(
                    """
                    Presented to Wii games when they start. Sideways Wii Remote \
                    suits games designed around holding the remote like a \
                    traditional controller. This does not affect GameCube games.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle(
                    "Map Left Stick to D-Pad for Digital Systems",
                    isOn: $mapsLeftAnalogToDPad
                )

                Text(
                    """
                    Lets the left stick control digital-only games such as NES, \
                    Game Boy Advance, and Wii games using the sideways Wii Remote. \
                    Analog-capable controller configurations are not changed.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle(
                    "Enable Fast Forward with R3",
                    isOn: $enablesR3FastForward
                )

                Toggle(
                    "Open Games in Full Screen",
                    isOn: $opensGamesInFullScreen
                )

                Toggle(
                    "Enable Rewind with L3",
                    isOn: $enablesL3Rewind
                )

                Toggle(
                    "Enable Experimental Cores",
                    isOn: $enablesExperimentalCores
                )

                Text(
                    """
                    Experimental cores ship with RetroVault but have not met the \
                    bar the reviewed cores are held to. Their systems stay \
                    hidden until this is on, and their video, audio, input, \
                    firmware, and save behaviour may be incomplete.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

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
                    save states, and the separate player window before RetroVault enables \
                    reviewed console cores for RomM games.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Network Controller (DSU)") {
                Toggle(
                    "Read a DSU Controller Server",
                    isOn: $usesDSUController
                )

                TextField("Server", text: $dsuHost, prompt: Text(DSUProtocol.defaultHost))
                    .disabled(!usesDSUController)

                TextField(
                    "Port",
                    value: $dsuPort,
                    format: .number.grouping(.never),
                    prompt: Text(String(DSUProtocol.defaultPort))
                )
                .disabled(!usesDSUController)

                Picker("Controller", selection: $dsuSlot) {
                    ForEach(0..<Int(DSUProtocol.slotCount), id: \.self) { slot in
                        Text("Slot \(slot + 1)").tag(slot)
                    }
                }
                .disabled(!usesDSUController)

                Picker("Button Layout", selection: $dsuLayout) {
                    Text("Standard").tag(ControllerFaceButtonLayout.standard.rawValue)
                    Text("Nintendo").tag(ControllerFaceButtonLayout.nintendo.rawValue)
                }
                .disabled(!usesDSUController)

                LabeledContent("Status", value: dsuStatus.summary)

                Text(
                    """
                    DSU, also called the cemuhook protocol, carries a pad's \
                    buttons, sticks, touchpad, and motion over the local \
                    network. RetroVault reads one slot and merges it with any \
                    controller attached to this Mac, in Big Picture and in the \
                    player. Cores that ask for motion receive the pad's \
                    gyroscope and accelerometer. A DSU packet carries no \
                    controller identity, so choose Nintendo if the server is \
                    publishing a Switch pad and its face buttons read swapped.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Presentation") {
                Toggle(
                    "Open RetroVault in Full Screen",
                    isOn: $opensBigPictureInFullScreen
                )

                Text(
                    """
                    RetroVault opens its controller-first library in full screen by \
                    default. Use the green window control to switch between full \
                    screen and a regular window.
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
                    Shows recent and live RetroVault activity. Credentials and \
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
        .task {
            // The connection lives for the whole app, so Settings polls it for
            // display rather than owning it.
            while !Task.isCancelled {
                dsuStatus = DSUConnection.shared.status
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onChange(of: usesDSUController) { applyDSUConfiguration() }
        .onChange(of: dsuHost) { applyDSUConfiguration() }
        .onChange(of: dsuPort) { applyDSUConfiguration() }
        .onChange(of: dsuSlot) { applyDSUConfiguration() }
        .onChange(of: dsuLayout) {
            // Reading the same packets differently needs no new socket.
            DSUConnection.shared.apply(
                layout: ControllerFaceButtonLayout(rawValue: dsuLayout)
                    ?? DSUPreferences.defaultLayout
            )
        }
        .alert(
            "Purge RetroVault's Local Cache?",
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
                RetroVault will remove its cached library metadata, game details, and \
                artwork, then rebuild them from RomM. Exported ROMs, saves, and local \
                playback data are not removed.
                """
            )
        }
    }

    private func applyDSUConfiguration() {
        // The address and port fields change on every keystroke, so settle
        // before rebuilding the socket.
        dsuReconnectTask?.cancel()
        dsuReconnectTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else {
                return
            }

            guard usesDSUController else {
                DSUConnection.shared.apply(nil)
                return
            }

            DSUConnection.shared.apply(
                DSUConfiguration(
                    host: dsuHost,
                    port: UInt16(clamping: dsuPort),
                    slot: UInt8(clamping: dsuSlot)
                ).normalized
            )
        }
    }

    #if DEBUG
    private var testROMURL: URL? {
        guard
            let path = ProcessInfo.processInfo.environment["RETROVAULT_LIBRETRO_TEST_ROM"],
            !path.isEmpty
        else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    #endif
}

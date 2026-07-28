import Foundation
import Metal
import Testing
@testable import OpenVault

@Suite("Bundled Libretro cores")
struct LibretroCoreManifestTests {
    @Test("Uses interpreter mode for DOSBox Pure")
    func usesSafeDOSBoxPureCPUCore() {
        #expect(
            LibretroCoreOptionPreferences.value(
                for: "dosbox_pure_cpu_core",
                default: "auto"
            ) == "normal"
        )
        #expect(
            LibretroCoreOptionPreferences.value(
                for: "unconfigured_core_option",
                default: "core default"
            ) == "core default"
        )
    }

    @Test("Attaches a Memory Pak to the first N64 controller")
    func attachesNintendo64MemoryPak() {
        #expect(
            LibretroCoreOptionPreferences.value(
                for: "parallel-n64-pak1",
                default: "none",
                availableValues: ["none", "memory", "rumble"]
            ) == "memory"
        )
        #expect(
            LibretroCoreOptionPreferences.value(
                for: "parallel-n64-pak2",
                default: "none",
                availableValues: ["none", "memory", "rumble"]
            ) == "none"
        )
    }

    @Test("Maps Xbox and Nintendo face buttons to matching positions")
    func mapsControllerFaceButtonPositions() {
        let xboxBottom = LibretroInputState.faceButtonMask(
            buttonAPressed: true,
            buttonBPressed: false,
            buttonXPressed: false,
            buttonYPressed: false,
            layout: .standard
        )
        let switchBottom = LibretroInputState.faceButtonMask(
            buttonAPressed: false,
            buttonBPressed: true,
            buttonXPressed: false,
            buttonYPressed: false,
            layout: .nintendo
        )
        let xboxRight = LibretroInputState.faceButtonMask(
            buttonAPressed: false,
            buttonBPressed: true,
            buttonXPressed: false,
            buttonYPressed: false,
            layout: .standard
        )
        let switchRight = LibretroInputState.faceButtonMask(
            buttonAPressed: true,
            buttonBPressed: false,
            buttonXPressed: false,
            buttonYPressed: false,
            layout: .nintendo
        )
        let xboxLeft = LibretroInputState.faceButtonMask(
            buttonAPressed: false,
            buttonBPressed: false,
            buttonXPressed: true,
            buttonYPressed: false,
            layout: .standard
        )
        let switchLeft = LibretroInputState.faceButtonMask(
            buttonAPressed: false,
            buttonBPressed: false,
            buttonXPressed: false,
            buttonYPressed: true,
            layout: .nintendo
        )
        let xboxTop = LibretroInputState.faceButtonMask(
            buttonAPressed: false,
            buttonBPressed: false,
            buttonXPressed: false,
            buttonYPressed: true,
            layout: .standard
        )
        let switchTop = LibretroInputState.faceButtonMask(
            buttonAPressed: false,
            buttonBPressed: false,
            buttonXPressed: true,
            buttonYPressed: false,
            layout: .nintendo
        )

        #expect(xboxBottom == LibretroButton.b.mask)
        #expect(switchBottom == xboxBottom)
        #expect(xboxRight == LibretroButton.a.mask)
        #expect(switchRight == xboxRight)
        #expect(xboxLeft == LibretroButton.y.mask)
        #expect(switchLeft == xboxLeft)
        #expect(xboxTop == LibretroButton.x.mask)
        #expect(switchTop == xboxTop)
    }

    @Test("Maps held stick buttons to transport controls")
    func mapsHeldStickButtonsToTransportControls() {
        #expect(
            LibretroTransportControls.controller(
                leftThumbstickButtonPressed: true,
                rightThumbstickButtonPressed: false
            )
                == LibretroTransportControls(
                    isRewinding: true,
                    isFastForwarding: false
                )
        )
        #expect(
            LibretroTransportControls.controller(
                leftThumbstickButtonPressed: false,
                rightThumbstickButtonPressed: true
            )
                == LibretroTransportControls(
                    isRewinding: false,
                    isFastForwarding: true
                )
        )
        #expect(
            LibretroTransportControls.controller(
                leftThumbstickButtonPressed: true,
                rightThumbstickButtonPressed: true
            )
                == LibretroTransportControls(
                    isRewinding: true,
                    isFastForwarding: false
                )
        )
        #expect(
            LibretroTransportControls.controller(
                leftThumbstickButtonPressed: true,
                rightThumbstickButtonPressed: true,
                enablesRewind: false,
                enablesFastForward: false
            ) == LibretroTransportControls()
        )
    }

    @Test("Selects only reviewed cores for compatible RomM games")
    func selectsReviewedCore() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Libretro/CoreManifest.json")
        let manifest = try JSONDecoder().decode(
            LibretroCoreManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        #expect(manifest.schemaVersion == 1)
        #expect(
            manifest.compatibleCore(
                systemName: "Game Boy Color",
                fileExtension: ".GBC"
            )?.id == "libretro-gambatte"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Nintendo Entertainment System",
                fileExtension: "nes"
            )?.id == "libretro-nestopia"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Famicom",
                fileExtension: ".UNIF"
            )?.id == "libretro-nestopia"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Super Nintendo Entertainment System",
                fileExtension: "sfc"
            )?.id == "libretro-bsnes-mercury-balanced"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Super Famicom",
                fileExtension: "zip",
                archiveMemberNames: ["Manual.txt", "Chrono Trigger.smc"]
            )?.id == "libretro-bsnes-mercury-balanced"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Game Boy",
                fileExtension: "zip",
                archiveMemberNames: ["README.txt", "Tetris.gb"]
            )?.id == "libretro-gambatte"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Game Boy",
                fileExtension: "zip",
                archiveMemberNames: ["README.txt", "Tetris.nes"]
            ) == nil
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Game Boy",
                fileExtension: ""
            )?.id == "libretro-gambatte"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Nintendo Entertainment System",
                fileExtension: "fds"
            ) == nil
        )
        #expect(manifest.core(id: "libretro-2048")?.status == .pipelineTest)
    }

    @Test("Distinguishes systems with bundled core support")
    func identifiesSupportedSystems() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Libretro/CoreManifest.json")
        let manifest = try JSONDecoder().decode(
            LibretroCoreManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        // Reviewed cores only. `supportsSystem` otherwise defaults this from
        // UserDefaults, which would let a developer's own experimental-cores
        // setting decide whether this test passes.
        func supports(_ system: String) -> Bool {
            manifest.supportsSystem(
                named: system,
                includingExperimental: false
            )
        }

        #expect(supports("Game Boy"))
        #expect(supports("Sega Master System/Mark III"))
        #expect(supports("ColecoVision"))
        #expect(supports("Nintendo GameCube"))
        #expect(supports("PlayStation Portable"))
        #expect(supports("Virtual Boy"))
        // Offered only by flycast, which is experimental.
        #expect(!supports("Dreamcast"))
        #expect(!manifest.supportsSystem(named: "PlayStation 2"))

        // With experimental cores switched on, Dreamcast becomes playable.
        #expect(
            manifest.supportsSystem(
                named: "Dreamcast",
                includingExperimental: true
            )
        )
    }

    // 3DS support was removed: Azahar only offers Vulkan and Software
    // renderers, and its Vulkan path needs a hardware context this runtime
    // does not provide. Nothing may quietly claim to play these files again.
    @Test("3DS files match no bundled core")
    func rejects3DSGames() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Libretro/CoreManifest.json")
        let manifest = try JSONDecoder().decode(
            LibretroCoreManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        for fileExtension in ["3ds", "cci", "cxi", "3dsx"] {
            #expect(
                manifest.compatibleCore(
                    systemName: "Nintendo 3DS",
                    fileExtension: fileExtension,
                    includingExperimental: true
                ) == nil,
                "expected no core for .\(fileExtension)"
            )
        }

        #expect(
            !manifest.supportsSystem(
                named: "Nintendo 3DS",
                includingExperimental: true
            )
        )
        #expect(!manifest.cores.contains { $0.id == "libretro-azahar" })
    }

    // Exact values taken from a real RomM library: the system name RomM
    // reports for the Master System, and a downloaded game's extension.
    @Test("Matches a Master System game to Gearsystem")
    func matchesMasterSystemGames() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Libretro/CoreManifest.json")
        let manifest = try JSONDecoder().decode(
            LibretroCoreManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        for includingExperimental in [true, false] {
            #expect(
                manifest.compatibleCore(
                    systemName: "Sega Master System/Mark III",
                    fileExtension: "sms",
                    contentFileNames: ["Hang-On (UE) [!].sms"],
                    includingExperimental: includingExperimental
                )?.id == "libretro-gearsystem",
                "experimental=\(includingExperimental)"
            )
        }
    }

    @Test("Selects the expanded ARM64 core set")
    func selectsExpandedCoreSet() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Libretro/CoreManifest.json")
        let manifest = try JSONDecoder().decode(
            LibretroCoreManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        #expect(
            manifest.compatibleCore(
                systemName: "Game Boy Advance",
                fileExtension: "gba"
            )?.id == "libretro-mgba"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Sega Master System",
                fileExtension: "sms"
            )?.id == "libretro-gearsystem"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "ColecoVision",
                fileExtension: "col"
            )?.id == "libretro-gearcoleco"
        )
        #expect(
            manifest.core(id: "libretro-gearcoleco")?
                .firmware.map(\.fileName)
                == ["colecovision.rom"]
        )
        #expect(
            manifest.core(id: "libretro-gearcoleco")?
                .firmware.allSatisfy(\.required) == true
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Atari 2600",
                fileExtension: "a26"
            )?.id == "libretro-stella2014"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Atari 7800",
                fileExtension: "a78"
            )?.id == "libretro-prosystem"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Atari 5200",
                fileExtension: "a52"
            )?.id == "libretro-a5200"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Virtual Boy",
                fileExtension: "vb"
            )?.id == "libretro-beetle-vb"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Neo Geo Pocket Color",
                fileExtension: "ngc"
            )?.id == "libretro-beetle-ngp"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "WonderSwan Color",
                fileExtension: "wsc"
            )?.id == "libretro-beetle-wswan"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Pokémon Mini",
                fileExtension: "min"
            )?.id == "libretro-pokemini"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "PlayStation",
                fileExtension: "chd"
            )?.id == "libretro-pcsx-rearmed"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "PlayStation",
                fileExtension: "",
                contentFileNames: [
                    "Castlevania - Symphony of the Night (U).bin",
                    "Castlevania - Symphony of the Night (U).cue",
                ]
            )?.id == "libretro-pcsx-rearmed"
        )
        #expect(
            manifest.core(id: "libretro-pcsx-rearmed")?
                .fileExtensions.first == "m3u"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "PlayStation Portable",
                fileExtension: "cso"
            )?.id == "libretro-ppsspp"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "TurboGrafx-16/PC Engine",
                fileExtension: "pce"
            )?.id == "libretro-geargrafx"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "PC Engine SuperGrafx",
                fileExtension: "sgx"
            )?.id == "libretro-geargrafx"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "PC Engine CD",
                fileExtension: "chd"
            )?.id == "libretro-geargrafx"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Nintendo GameCube",
                fileExtension: "rvz"
            )?.id == "libretro-dolphin"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Nintendo DS",
                fileExtension: "nds"
            )?.id == "libretro-melonds"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Sega Mega Drive/Genesis",
                fileExtension: "md"
            )?.id == "libretro-genesis-plus-gx"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Sega CD",
                fileExtension: "chd"
            )?.id == "libretro-genesis-plus-gx"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Sega 32X",
                fileExtension: "32x"
            )?.id == "libretro-picodrive"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "DOS",
                fileExtension: "zip"
            )?.id == "libretro-dosbox-pure"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Arduboy",
                fileExtension: "hex"
            )?.id == "libretro-arduous"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Pico-8",
                fileExtension: "p8"
            )?.id == "libretro-fake08"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Nintendo Wii",
                fileExtension: "wbfs"
            )?.id == "libretro-dolphin"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Nintendo 64",
                fileExtension: "z64"
            )?.id == "libretro-parallel-n64"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Arcade",
                fileExtension: "zip",
                archiveMemberNames: ["1942.01", "1942.02"]
            )?.id == "libretro-fbneo"
        )
        #expect(
            manifest.core(id: "libretro-fbneo")?.loadsArchivesDirectly == true
        )
        #expect(
            manifest.core(id: "libretro-dosbox-pure")?
                .loadsArchivesDirectly == true
        )
        #expect(
            manifest.core(id: "libretro-genesis-plus-gx")?
                .firmware.map(\.fileName)
                == ["bios_CD_E.bin", "bios_CD_J.bin", "bios_CD_U.bin"]
        )
    }

    @Test("Uses the largest centered integer scale that fits")
    func usesIntegerVideoScale() {
        let viewport = LibretroVideoLayout.viewport(
            sourceSize: CGSize(width: 256, height: 224),
            targetSize: CGSize(width: 1_800, height: 1_330)
        )

        #expect(
            viewport
                == CGRect(
                    x: 260,
                    y: 105,
                    width: 1_280,
                    height: 1_120
                )
        )
    }

    @Test("Allows proportional downscaling when the source is larger")
    func downscalesOversizedVideo() {
        let viewport = LibretroVideoLayout.viewport(
            sourceSize: CGSize(width: 320, height: 240),
            targetSize: CGSize(width: 160, height: 120)
        )

        #expect(viewport == CGRect(x: 0, y: 0, width: 160, height: 120))
    }

    @Test("Corrects a frame whose buffer is not the shape the core asked for")
    func honorsCoreAspectRatio() {
        // An N64 core hands over a 640x480 buffer but asks for 16:9, which
        // scaling the buffer alone would render as 4:3.
        let viewport = LibretroVideoLayout.viewport(
            sourceSize: CGSize(width: 640, height: 480),
            targetSize: CGSize(width: 1_920, height: 1_080),
            aspectRatio: 16.0 / 9.0
        )

        #expect(viewport == CGRect(x: 0, y: 0, width: 1_920, height: 1_080))

        // The same buffer letterboxes inside a taller window.
        let letterboxed = LibretroVideoLayout.viewport(
            sourceSize: CGSize(width: 640, height: 480),
            targetSize: CGSize(width: 1_600, height: 1_200),
            aspectRatio: 16.0 / 9.0
        )
        #expect(letterboxed.width == 1_600)
        #expect(letterboxed.height == 900)
        #expect(letterboxed.origin.y == 150)
    }

    @Test("Keeps whole-pixel scaling when the core's shape matches its buffer")
    func keepsIntegerScaleForSquarePixels() {
        // 4:3 reported against a 4:3 buffer must not lose the crisp integer
        // scale that square-pixel cores rely on.
        let viewport = LibretroVideoLayout.viewport(
            sourceSize: CGSize(width: 320, height: 240),
            targetSize: CGSize(width: 1_000, height: 1_000),
            aspectRatio: 4.0 / 3.0
        )

        #expect(viewport == CGRect(x: 20, y: 140, width: 960, height: 720))
    }

    @Test("Falls back to the buffer when a core reports no aspect ratio")
    func fallsBackToBufferShape() {
        let reported = LibretroVideoLayout.viewport(
            sourceSize: CGSize(width: 256, height: 224),
            targetSize: CGSize(width: 1_800, height: 1_330),
            aspectRatio: 0
        )
        let derived = LibretroVideoLayout.viewport(
            sourceSize: CGSize(width: 256, height: 224),
            targetSize: CGSize(width: 1_800, height: 1_330)
        )

        #expect(reported == derived)
    }

    @Test("Offers reviewed cores always and experimental ones only on request")
    func gatesExperimentalCores() {
        typealias Status = LibretroCoreManifest.Core.Status

        // Reviewed cores are unaffected by the preference.
        #expect(Status.bundled.isOffered(includingExperimental: false))
        #expect(Status.bundled.isOffered(includingExperimental: true))

        // Experimental cores ship, but stay hidden until asked for.
        #expect(!Status.experimental.isOffered(includingExperimental: false))
        #expect(Status.experimental.isOffered(includingExperimental: true))

        // Nothing turns these three into a playable core.
        for status in [Status.pipelineTest, .planned, .excluded] {
            #expect(!status.isOffered(includingExperimental: false))
            #expect(!status.isOffered(includingExperimental: true))
        }
    }

    @Test("Keeps experimental cores out of the catalog by default")
    func defaultsToReviewedCoresOnly() {
        let defaults = UserDefaults(suiteName: "LibretroCoreTests.experimental")
        defaults?.removePersistentDomain(
            forName: "LibretroCoreTests.experimental"
        )

        #expect(
            !LibretroCorePreferences.enablesExperimentalCores(
                from: defaults ?? .standard
            )
        )

        defaults?.set(
            true,
            forKey: LibretroCorePreferences.enablesExperimentalCoresKey
        )
        #expect(
            LibretroCorePreferences.enablesExperimentalCores(
                from: defaults ?? .standard
            )
        )
        defaults?.removePersistentDomain(
            forName: "LibretroCoreTests.experimental"
        )
    }

    // The shader is compiled from source at runtime, so a mistake in it is a
    // crash when a game starts rather than a build failure. Compiling every
    // filter here moves that back to the test suite.
    @Test("Compiles a render pipeline for every video filter")
    func compilesPixelShader() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(
            source: LibretroMetalShader.source,
            options: nil
        )

        let vertexFunction = try #require(
            library.makeFunction(name: "openVaultPixelVertex")
        )

        for filter in LibretroVideoFilter.allCases {
            let fragmentFunction = library.makeFunction(
                name: filter.fragmentFunctionName
            )
            #expect(
                fragmentFunction != nil,
                "missing fragment function for \(filter.rawValue)"
            )

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            #expect(
                throws: Never.self,
                "pipeline failed for \(filter.rawValue)"
            ) {
                try device.makeRenderPipelineState(descriptor: descriptor)
            }
        }
    }

    @Test("Defaults to unfiltered video")
    func videoFilterDefaultsToOff() {
        let defaults = UserDefaults(
            suiteName: "LibretroVideoTests.filter"
        )
        defaults?.removePersistentDomain(forName: "LibretroVideoTests.filter")

        #expect(
            LibretroVideoPreferences.filter(from: defaults ?? .standard)
                == .nearest
        )
        #expect(LibretroVideoFilter.nearest.displayName == "Off")
        #expect(
            LibretroInternalResolutionPreferences.resolution(
                from: defaults ?? .standard
            ) == .native
        )
    }

    @Test("Runs a PSP smoke-test image when one is provided")
    @MainActor
    func runsPSPSmokeTestImage() async throws {
        guard
            let path = ProcessInfo.processInfo.environment[
                "OPENVAULT_PSP_TEST_ROM"
            ],
            FileManager.default.fileExists(atPath: path)
        else {
            return
        }

        let session = LibretroSession(
            request: LibretroRunRequest(
                title: "PPSSPP Integration Test",
                coreID: "libretro-ppsspp",
                contentURL: URL(fileURLWithPath: path)
            )
        )
        session.start()
        defer {
            session.stop()
        }

        var didStart = false
        for _ in 0..<300 {
            switch session.phase {
            case .running:
                didStart = true
                if let frame = session.videoBuffer.snapshot() {
                    #expect(frame.width > 0)
                    #expect(frame.height > 0)
                    #expect(!frame.pixels.isEmpty)
                    return
                }
            case let .failed(message):
                Issue.record("PPSSPP failed to start: \(message)")
                return
            case .idle, .starting, .stopped:
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        Issue.record(
            didStart
                ? "PPSSPP started but did not render a frame within 30 seconds."
                : "PPSSPP did not start within 30 seconds."
        )
    }

    @Test("Runs a PlayStation smoke-test image when one is provided")
    @MainActor
    func runsPlayStationSmokeTestImage() async throws {
        guard
            let path = ProcessInfo.processInfo.environment[
                "OPENVAULT_PLAYSTATION_TEST_ROM"
            ],
            FileManager.default.fileExists(atPath: path)
        else {
            return
        }

        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coresDirectory = ProcessInfo.processInfo.environment[
            "OPENVAULT_TEST_CORES_DIRECTORY"
        ].map(URL.init(fileURLWithPath:))
            ?? repositoryURL.appending(
                path: "Build/LibretroCores/Cores",
                directoryHint: .isDirectory
            )
        let installation = try LibretroInstallation(
            manifestURL: repositoryURL.appending(
                path: "Libretro/CoreManifest.json"
            ),
            coresDirectory: coresDirectory
        )
        let session = LibretroSession(
            request: LibretroRunRequest(
                title: "PlayStation Integration Test",
                coreID: "libretro-pcsx-rearmed",
                contentURL: URL(fileURLWithPath: path)
            ),
            installation: installation
        )
        session.start()
        defer {
            session.stop()
        }

        var didStart = false
        for _ in 0..<300 {
            switch session.phase {
            case .running:
                didStart = true
                if let frame = session.videoBuffer.snapshot(),
                   containsVisiblePixels(frame) {
                    return
                }
            case let .failed(message):
                Issue.record("PCSX-ReARMed failed to start: \(message)")
                return
            case .idle, .starting, .stopped:
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        Issue.record(
            didStart
                ? "PCSX-ReARMed returned no visible frame within 30 seconds."
                : "PCSX-ReARMed did not start within 30 seconds."
        )
    }

    @Test("Stages long full-path content with adjacent disc files")
    func stagesLongFullPathContent() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sourceDirectory = root
            .appending(
                path: String(repeating: "long-directory-", count: 8),
                directoryHint: .isDirectory
            )
            .appending(
                path: String(repeating: "nested-", count: 8),
                directoryHint: .isDirectory
            )
        defer {
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )

        let cueURL = sourceDirectory.appending(path: "game.cue")
        let binURL = sourceDirectory.appending(path: "game.bin")
        try Data("FILE \"game.bin\" BINARY\n".utf8).write(to: cueURL)
        try Data([0x00, 0x01, 0x02]).write(to: binURL)
        #expect(cueURL.path.utf8.count >= 192)

        let staged = try LibretroStagedContent.prepare(
            contentURL: cueURL,
            needsFullPath: true
        )
        let stagedURL = try #require(staged.contentURL)

        #expect(stagedURL != cueURL)
        #expect(stagedURL.path.utf8.count < 192)
        #expect(try Data(contentsOf: stagedURL) == Data(contentsOf: cueURL))
        #expect(
            try Data(
                contentsOf: stagedURL
                    .deletingLastPathComponent()
                    .appending(path: "game.bin")
            ) == Data(contentsOf: binURL)
        )
    }

    @Test("Preserves arcade archive names when shortening their launch path")
    func preservesArcadeArchiveNameWhenStaging() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sourceDirectory = root
            .appending(
                path: String(repeating: "sandbox-container-", count: 10),
                directoryHint: .isDirectory
            )
        defer {
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )

        let archiveURL = sourceDirectory.appending(path: "digdug.zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archiveURL)
        #expect(archiveURL.path.utf8.count >= 192)

        let staged = try LibretroStagedContent.prepare(
            contentURL: archiveURL,
            needsFullPath: true
        )
        let stagedURL = try #require(staged.contentURL)

        #expect(stagedURL != archiveURL)
        #expect(stagedURL.lastPathComponent == "digdug.zip")
        #expect(stagedURL.path.utf8.count < 192)
        #expect(try Data(contentsOf: stagedURL) == Data(contentsOf: archiveURL))
    }

    @Test("Renders visible N64 pixels when a smoke-test ROM is provided")
    @MainActor
    func rendersN64SmokeTestROM() async throws {
        guard
            let path = ProcessInfo.processInfo.environment[
                "OPENVAULT_N64_TEST_ROM"
            ],
            FileManager.default.fileExists(atPath: path)
        else {
            return
        }

        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let installation = try LibretroInstallation(
            manifestURL: repositoryURL.appending(
                path: "Libretro/CoreManifest.json"
            ),
            coresDirectory: repositoryURL.appending(
                path: "Build/LibretroCores/Cores",
                directoryHint: .isDirectory
            )
        )
        let session = LibretroSession(
            request: LibretroRunRequest(
                title: "Nintendo 64 Integration Test",
                coreID: "libretro-parallel-n64",
                contentURL: URL(fileURLWithPath: path)
            ),
            installation: installation
        )
        session.start()
        defer {
            session.stop()
        }

        var didStart = false
        var didReceiveFrame = false
        for _ in 0..<300 {
            switch session.phase {
            case .running:
                didStart = true
                if let frame = session.videoBuffer.snapshot() {
                    didReceiveFrame = true
                    if containsVisiblePixels(frame) {
                        return
                    }
                }
            case let .failed(message):
                Issue.record("ParaLLEl-N64 failed to start: \(message)")
                return
            case .idle, .starting, .stopped:
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        if !didStart {
            Issue.record("ParaLLEl-N64 did not start within 30 seconds.")
        } else if !didReceiveFrame {
            Issue.record("ParaLLEl-N64 did not return a frame within 30 seconds.")
        } else {
            Issue.record("ParaLLEl-N64 returned only black frames for 30 seconds.")
        }
    }

    @Test("Bounds rewind history by memory and entry count")
    func boundsRewindHistory() {
        var rewind = LibretroRewindBuffer(byteLimit: 10, entryLimit: 3)

        let appendedFirst = rewind.append(Data(repeating: 1, count: 4))
        let appendedSecond = rewind.append(Data(repeating: 2, count: 4))
        let appendedThird = rewind.append(Data(repeating: 3, count: 4))
        #expect(appendedFirst)
        #expect(appendedSecond)
        #expect(appendedThird)
        #expect(rewind.count == 2)
        #expect(rewind.byteCount == 8)
        let newest = rewind.popLast()
        let oldest = rewind.popLast()
        #expect(newest == Data(repeating: 3, count: 4))
        #expect(oldest == Data(repeating: 2, count: 4))
        #expect(rewind.isEmpty)

        let appendedOversized = rewind.append(Data(repeating: 4, count: 11))
        #expect(!appendedOversized)
        #expect(rewind.isEmpty)
        #expect(rewind.byteCount == 0)
    }

    @Test("Can consume multiple rewind frames per rendered step")
    func consumesMultipleRewindFrames() {
        var rewind = LibretroRewindBuffer(byteLimit: 100, entryLimit: 10)
        rewind.append(Data([1]))
        rewind.append(Data([2]))
        rewind.append(Data([3]))
        rewind.append(Data([4]))

        #expect(rewind.popLast(steps: 2) == Data([3]))
        #expect(rewind.count == 2)
        #expect(rewind.byteCount == 2)
    }

    @Test("Captures small rewind states at frame cadence")
    func capturesSmallRewindStatesAtFrameCadence() {
        let cadence = LibretroRewindCadence(
            framesPerSecond: 60,
            byteLimit: 128 * 1_024 * 1_024
        )

        #expect(
            cadence.snapshotInterval(forStateByteCount: 128 * 1_024)
                == 1.0 / 60.0
        )
    }

    @Test("Adapts rewind cadence for larger states")
    func adaptsRewindCadenceForLargerStates() {
        let cadence = LibretroRewindCadence(
            framesPerSecond: 60,
            byteLimit: 128 * 1_024 * 1_024
        )
        let interval =
            cadence.snapshotInterval(forStateByteCount: 1 * 1_024 * 1_024)

        #expect(interval > 1.0 / 60.0)
        #expect(interval < 1.0 / 12.0)
        #expect(
            abs(
                (1 / interval) * LibretroRewindCadence.targetHistoryDuration
                    * Double(1 * 1_024 * 1_024)
                    - Double(128 * 1_024 * 1_024)
            ) < 1
        )
    }

    @Test("Sustains rewind for states within the history budget")
    func sustainsRewindForModestStates() {
        let cadence = LibretroRewindCadence(
            framesPerSecond: 60,
            byteLimit: 128 * 1_024 * 1_024
        )

        #expect(cadence.canSustainRewind(forStateByteCount: 128 * 1_024))
        #expect(cadence.canSustainRewind(forStateByteCount: 1 * 1_024 * 1_024))
    }

    @Test("Refuses rewind for states too large to keep a useful history")
    func refusesRewindForOversizedStates() {
        let cadence = LibretroRewindCadence(
            framesPerSecond: 60,
            byteLimit: 128 * 1_024 * 1_024
        )

        // Serialization runs inside the frame budget, so a GameCube-sized state
        // would cost most of every captured frame and still retain well under a
        // second of history.
        #expect(
            !cadence.canSustainRewind(forStateByteCount: 24 * 1_024 * 1_024)
        )
    }

    // A core too large for the full eight seconds keeps rewind on a shorter
    // history rather than losing it, which is what puts the PlayStation back
    // in range.
    @Test("Shortens rewind history rather than dropping it")
    func shortensHistoryForLargerStates() {
        let cadence = LibretroRewindCadence(
            framesPerSecond: 60,
            byteLimit: 128 * 1_024 * 1_024
        )
        let playStationState = 3_500 * 1_024

        #expect(cadence.canSustainRewind(forStateByteCount: playStationState))

        let history = cadence.sustainableHistoryDuration(
            forStateByteCount: playStationState
        )
        #expect(history >= LibretroRewindCadence.minimumHistoryDuration)
        #expect(history < LibretroRewindCadence.targetHistoryDuration)

        // The rate never drops below the floor, because that is the part that
        // costs frame time.
        let rate = 1 / cadence.snapshotInterval(
            forStateByteCount: playStationState
        )
        #expect(rate >= LibretroRewindCadence.minimumSnapshotsPerSecond)
    }

    // A core small enough for the full history must be completely unaffected
    // by the shortening path.
    @Test("Leaves small states on the full history and rate")
    func smallStatesKeepFullHistory() {
        let byteLimit = 128 * 1_024 * 1_024
        let cadence = LibretroRewindCadence(
            framesPerSecond: 60,
            byteLimit: byteLimit
        )
        let stateByteCount = 256 * 1_024

        #expect(
            cadence.sustainableHistoryDuration(
                forStateByteCount: stateByteCount
            ) == LibretroRewindCadence.targetHistoryDuration
        )
        let rate = 1 / cadence.snapshotInterval(
            forStateByteCount: stateByteCount
        )
        let expected = min(
            60,
            Double(byteLimit)
                / Double(stateByteCount)
                / LibretroRewindCadence.targetHistoryDuration
        )
        #expect(abs(rate - expected) < 0.001)
    }

    @Test("Bounds sustainable rewind by the history budget, not the minimum rate")
    func boundsSustainableRewindByHistoryBudget() {
        let byteLimit = 128 * 1_024 * 1_024
        let cadence = LibretroRewindCadence(
            framesPerSecond: 60,
            byteLimit: byteLimit
        )
        // The cutoff is where the affordable history falls below the shortest
        // window worth keeping, not where the full history stops fitting.
        let largestSustainableState = Int(
            Double(byteLimit)
                / LibretroRewindCadence.minimumSnapshotsPerSecond
                / LibretroRewindCadence.minimumHistoryDuration
        )

        #expect(
            cadence.canSustainRewind(
                forStateByteCount: largestSustainableState
            )
        )
        #expect(
            !cadence.canSustainRewind(
                forStateByteCount: largestSustainableState + 1
            )
        )
        // The history budget still bounds memory: the largest state that keeps
        // rewind holds no more than the byte limit.
        let held =
            Double(largestSustainableState)
            * LibretroRewindCadence.minimumSnapshotsPerSecond
            * cadence.sustainableHistoryDuration(
                forStateByteCount: largestSustainableState
            )
        #expect(held <= Double(byteLimit) + 1)
    }

    @Test("Captures every frame at a 60 Hz rewind cadence")
    func capturesEveryFrameAtFullCadence() {
        var schedule = LibretroRewindCaptureSchedule(
            framesPerSecond: 60
        )

        for _ in 0..<10 {
            let shouldCapture = schedule.shouldCapture()
            #expect(shouldCapture)
            schedule.didCapture(snapshotInterval: 1.0 / 60.0)
        }
    }

    @Test("Spaces lower-rate rewind captures by emulated frames")
    func spacesLowerRateCapturesByFrame() {
        var schedule = LibretroRewindCaptureSchedule(
            framesPerSecond: 60
        )

        let first = schedule.shouldCapture()
        #expect(first)
        schedule.didCapture(snapshotInterval: 1.0 / 30.0)
        let second = schedule.shouldCapture()
        let third = schedule.shouldCapture()
        #expect(!second)
        #expect(third)
        schedule.didCapture(snapshotInterval: 1.0 / 30.0)
        let fourth = schedule.shouldCapture()
        let fifth = schedule.shouldCapture()
        #expect(!fourth)
        #expect(fifth)
    }

    @Test("Disables rewind for Nintendo 64 cores")
    func disablesNintendo64Rewind() {
        #expect(
            !LibretroRewindPolicy.isEnabled(
                forCoreID: "libretro-parallel-n64"
            )
        )
        #expect(
            !LibretroRewindPolicy.isEnabled(
                forCoreID: "libretro-mupen64plus-next"
            )
        )
        #expect(
            LibretroRewindPolicy.isEnabled(
                forCoreID: "libretro-bsnes-mercury-balanced"
            )
        )
    }

    @Test("Start and Select request one clean exit per button chord")
    func detectsControllerExitChord() {
        var chord = LibretroControllerExitChord()

        let idle = chord.update(startPressed: false, selectPressed: false)
        let startOnly = chord.update(startPressed: true, selectPressed: false)
        let firstChord = chord.update(startPressed: true, selectPressed: true)
        let heldChord = chord.update(startPressed: true, selectPressed: true)
        let selectOnly = chord.update(startPressed: false, selectPressed: true)
        let secondChord = chord.update(startPressed: true, selectPressed: true)

        #expect(!idle)
        #expect(!startOnly)
        #expect(firstChord)
        #expect(!heldChord)
        #expect(!selectOnly)
        #expect(secondChord)
    }

    @Test("Marks Big Picture launches without breaking restored requests")
    func preservesPlayerOrigin() throws {
        let legacyRequest = try JSONDecoder().decode(
            LibretroRunRequest.self,
            from: Data(
                #"{"title":"2048","coreID":"libretro-2048","contentURL":null}"#
                    .utf8
            )
        )
        let bigPictureRequest = legacyRequest.launched(from: .bigPicture)

        #expect(legacyRequest.playerOrigin == nil)
        #expect(legacyRequest.restoresQuickStateOnLaunch)
        #expect(bigPictureRequest.playerOrigin == .bigPicture)
        #expect(bigPictureRequest.restoresQuickStateOnLaunch)
        #expect(bigPictureRequest.title == legacyRequest.title)
        #expect(bigPictureRequest.coreID == legacyRequest.coreID)

        let freshRequest = bigPictureRequest.startingFresh()
        #expect(!freshRequest.restoresQuickStateOnLaunch)
        #expect(freshRequest.playerOrigin == .bigPicture)
    }

    @MainActor
    @Test("A clean exit can immediately dismiss an inactive player")
    func exitsInactivePlayer() {
        let session = LibretroSession(request: .pipelineTest)

        session.exitPlayer()

        #expect(session.shouldClosePlayer)
        #expect(session.isReadyToClosePlayer)
        #expect(LibretroExitMode.automatic.createsResumeState)
        #expect(!LibretroExitMode.explicitStop.createsResumeState)
    }

    private func containsVisiblePixels(_ frame: LibretroVideoFrame) -> Bool {
        frame.pixels.withUnsafeBytes { bytes in
            guard let pixels = bytes.baseAddress?.assumingMemoryBound(
                to: UInt8.self
            ) else {
                return false
            }

            for offset in stride(from: 0, to: bytes.count - 3, by: 4) {
                if pixels[offset] != 0
                    || pixels[offset + 1] != 0
                    || pixels[offset + 2] != 0
                {
                    return true
                }
            }
            return false
        }
    }
}

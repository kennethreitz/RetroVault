import Foundation
import Metal
import Testing
@testable import RetroVault

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

    @Test("Fast-forward releases after a short R3 hold")
    func fastForwardReleasesAfterShortHold() {
        var latch = LibretroFastForwardLatch()

        let started = latch.update(isPressed: true, at: 10)
        let stillHeld = latch.update(isPressed: true, at: 13.9)
        let released = latch.update(isPressed: false, at: 13.9)

        #expect(started)
        #expect(stillHeld)
        #expect(!released)
        #expect(!latch.isLatched)
    }

    @Test("Fast-forward latches after four seconds and toggles off")
    func fastForwardLatchesAndTogglesOff() {
        var latch = LibretroFastForwardLatch()

        let started = latch.update(isPressed: true, at: 10)
        let latched = latch.update(isPressed: true, at: 14)
        #expect(started)
        #expect(latched)
        #expect(latch.isLatched)
        let releasedWhileLatched =
            latch.update(isPressed: false, at: 14.1)
        #expect(releasedWhileLatched)

        let toggledOff = latch.update(isPressed: true, at: 15)
        #expect(!toggledOff)
        #expect(!latch.isLatched)
        let suppressedHold = latch.update(isPressed: true, at: 20)
        let released = latch.update(isPressed: false, at: 20.1)
        #expect(!suppressedHold)
        #expect(!released)
    }

    @Test("Reset clears latched fast-forward")
    func resetClearsLatchedFastForward() {
        var latch = LibretroFastForwardLatch()

        _ = latch.update(isPressed: true, at: 0)
        _ = latch.update(isPressed: true, at: 4)
        latch.reset()

        #expect(!latch.isLatched)
        let released = latch.update(isPressed: false, at: 5)
        #expect(!released)
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
        // Offered only by experimental cores.
        #expect(!supports("Dreamcast"))
        #expect(!supports("Pico-8"))
        #expect(!manifest.supportsSystem(named: "PlayStation 2"))

        // With experimental cores switched on, both systems become playable.
        #expect(
            manifest.supportsSystem(
                named: "Dreamcast",
                includingExperimental: true
            )
        )
        #expect(
            manifest.supportsSystem(
                named: "Pico-8",
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
            manifest.compatibleCore(
                systemName: "PlayStation",
                fileExtension: ""
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
            )?.id == "libretro-beetle-pce"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "PC Engine SuperGrafx",
                fileExtension: "sgx"
            )?.id == "libretro-beetle-pce"
        )
        #expect(
            manifest.compatibleCore(
                systemName: "PC Engine CD",
                fileExtension: "chd"
            )?.id == "libretro-beetle-pce"
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
                fileExtension: "p8",
                includingExperimental: false
            ) == nil
        )
        #expect(
            manifest.compatibleCore(
                systemName: "Pico-8",
                fileExtension: "p8",
                includingExperimental: true
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

    @Test("Keeps Pico-8 experimental with an older artifact manifest")
    func overridesStalePico8Availability() throws {
        let core = try JSONDecoder().decode(
            LibretroCoreManifest.Core.self,
            from: Data(
                """
                {
                  "id": "libretro-fake08",
                  "displayName": "FAKE-08",
                  "status": "bundled",
                  "binaryName": "fake08_libretro.dylib",
                  "systems": ["pico-8"],
                  "fileExtensions": ["p8", "png"],
                  "capabilities": ["softwareVideo"],
                  "firmware": []
                }
                """.utf8
            )
        )

        #expect(core.availabilityStatus == .experimental)
        #expect(!core.isOffered(includingExperimental: false))
        #expect(core.isOffered(includingExperimental: true))
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

    @Test("Defaults to Smart CRT video")
    func videoFilterDefaultsToSmartCRT() {
        let defaults = UserDefaults(
            suiteName: "LibretroVideoTests.filter"
        )
        defaults?.removePersistentDomain(forName: "LibretroVideoTests.filter")

        #expect(
            LibretroVideoPreferences.filter(from: defaults ?? .standard)
                == .crtSmart
        )
        #expect(LibretroVideoFilter.nearest.displayName == "Off")
        #expect(!LibretroVideoFilter.nearest.usesFrameHistory)
        #expect(!LibretroVideoFilter.sharpBilinear.usesFrameHistory)
        #expect(!LibretroVideoFilter.xbr.usesFrameHistory)
        #expect(LibretroVideoFilter.crt.usesFrameHistory)
        #expect(LibretroVideoFilter.crtSmart.usesFrameHistory)
        #expect(LibretroVideoFilter.crtCurved.usesFrameHistory)
    }

    @Test("Escape leaves gameplay fullscreen before closing the player")
    func resolvesGameplayEscapeAction() {
        #expect(
            LibretroEscapeAction.resolve(
                isFullScreen: true,
                playerOrigin: .bigPicture
            ) == .leaveFullScreen
        )
        #expect(
            LibretroEscapeAction.resolve(
                isFullScreen: true,
                playerOrigin: nil
            ) == .leaveFullScreen
        )
        #expect(
            LibretroEscapeAction.resolve(
                isFullScreen: false,
                playerOrigin: .bigPicture
            ) == .exitPlayer
        )
        #expect(
            LibretroEscapeAction.resolve(
                isFullScreen: false,
                playerOrigin: nil
            ) == .stopSession
        )
        #expect(
            GameplayEscapeAction.resolve(isFullScreen: true)
                == .leaveFullScreen
        )
        #expect(
            GameplayEscapeAction.resolve(isFullScreen: false)
                == .closeGame
        )
    }

    @Test("Smart CRT curves television systems and keeps newer systems flat")
    func resolvesSmartCRTGeometryForSystem() {
        #expect(
            LibretroVideoFilter.crtSmart.resolved(
                forSystemName: "Nintendo Entertainment System"
            ) == .crtCurved
        )
        #expect(
            LibretroVideoFilter.crtSmart.resolved(
                forSystemName: "Nintendo GameCube"
            ) == .crtCurved
        )
        #expect(
            LibretroVideoFilter.crtSmart.resolved(
                forSystemName: "Arcade"
            ) == .crtCurved
        )
        #expect(
            LibretroVideoFilter.crtSmart.resolved(
                forSystemName: "DOS"
            ) == .crtCurved
        )
        #expect(
            LibretroVideoFilter.crtSmart.resolved(
                forSystemName: "Game Boy Advance"
            ) == .crt
        )
        #expect(
            LibretroVideoFilter.crtSmart.resolved(
                forSystemName: "Nintendo Wii"
            ) == .crt
        )
        #expect(
            LibretroVideoFilter.crtSmart.resolved(
                forSystemName: "PlayStation Portable"
            ) == .crt
        )
        #expect(
            LibretroVideoFilter.crtSmart.resolved(
                forSystemName: nil
            ) == .crt
        )
        #expect(
            LibretroVideoFilter.nearest.resolved(
                forSystemName: "Nintendo Entertainment System"
            ) == .nearest
        )
    }

    @Test("Runs a PSP smoke-test image when one is provided")
    @MainActor
    func runsPSPSmokeTestImage() async throws {
        guard
            let path = ProcessInfo.processInfo.environment[
                "RETROVAULT_PSP_TEST_ROM"
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

    @Test("Runs a Pico-8 cartridge when one is provided")
    @MainActor
    func runsPico8SmokeTestCartridge() async throws {
        guard
            let path = ProcessInfo.processInfo.environment[
                "RETROVAULT_PICO8_TEST_ROM"
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
                title: "Pico-8 Integration Test",
                coreID: "libretro-fake08",
                contentURL: URL(fileURLWithPath: path),
                systemName: "Pico-8"
            ),
            installation: installation
        )
        session.start()
        defer {
            session.stop()
        }

        var didStart = false
        var didReceiveFrame = false
        for _ in 0..<100 {
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
                Issue.record("FAKE-08 failed to start: \(message)")
                return
            case .idle, .starting, .stopped:
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        if !didStart {
            Issue.record("FAKE-08 did not start within 10 seconds.")
        } else if !didReceiveFrame {
            Issue.record("FAKE-08 did not return a frame within 10 seconds.")
        } else {
            Issue.record("FAKE-08 returned only black frames for 10 seconds.")
        }
    }

    @Test("Runs a PlayStation smoke-test image when one is provided")
    @MainActor
    func runsPlayStationSmokeTestImage() async throws {
        guard
            let path = ProcessInfo.processInfo.environment[
                "RETROVAULT_PLAYSTATION_TEST_ROM"
            ],
            FileManager.default.fileExists(atPath: path)
        else {
            return
        }

        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coresDirectory = ProcessInfo.processInfo.environment[
            "RETROVAULT_TEST_CORES_DIRECTORY"
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
                "RETROVAULT_N64_TEST_ROM"
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
            byteLimit: LibretroRewindCadence.defaultByteLimit
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
            byteLimit: LibretroRewindCadence.defaultByteLimit
        )
        let interval =
            cadence.snapshotInterval(forStateByteCount: 1 * 1_024 * 1_024)

        #expect(interval > 1.0 / 60.0)
        #expect(interval < 1.0 / 12.0)
        #expect(
            abs(
                (1 / interval) * LibretroRewindCadence.targetHistoryDuration
                    * Double(1 * 1_024 * 1_024)
                    - Double(LibretroRewindCadence.defaultByteLimit)
            ) < 1
        )
    }

    @Test("Sustains rewind for states within the history budget")
    func sustainsRewindForModestStates() {
        let cadence = LibretroRewindCadence(
            framesPerSecond: 60,
            byteLimit: LibretroRewindCadence.defaultByteLimit
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

    // A core too large for the full sixteen seconds keeps rewind on a shorter
    // history rather than losing it, which is what puts the PlayStation back
    // in range.
    @Test("Shortens rewind history rather than dropping it")
    func shortensHistoryForLargerStates() {
        let cadence = LibretroRewindCadence(
            framesPerSecond: 60,
            byteLimit: LibretroRewindCadence.defaultByteLimit
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

    @Test("Disables rewind for cores with unsafe state restoration")
    func disablesUnsafeRewind() {
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
            !LibretroRewindPolicy.isEnabled(
                forCoreID: "libretro-dolphin"
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

    @Test("Presents a Classic Controller Pro to Wii games in Dolphin")
    func selectsWiiClassicControllerPro() throws {
        let wiiRequest = LibretroRunRequest(
            title: "Wii Test",
            coreID: "libretro-dolphin",
            contentURL: nil,
            systemName: "Nintendo Wii"
        )
        let gameCubeRequest = LibretroRunRequest(
            title: "GameCube Test",
            coreID: "libretro-dolphin",
            contentURL: nil,
            systemName: "Nintendo GameCube"
        )

        #expect(
            LibretroControllerDevice.primaryDevice(
                coreID: wiiRequest.coreID,
                systemName: wiiRequest.systemName,
                wiiProfile: .classicControllerPro
            ) == LibretroControllerDevice.wiiClassicControllerPro
        )
        #expect(
            LibretroControllerDevice.primaryDevice(
                coreID: gameCubeRequest.coreID,
                systemName: gameCubeRequest.systemName
            ) == LibretroControllerDevice.joypad
        )

        let restoredRequest = wiiRequest.launched(from: .bigPicture)
            .startingFresh()
        #expect(restoredRequest.systemName == "Nintendo Wii")
    }

    @Test("Can present a sideways Wii Remote to Wii games in Dolphin")
    func selectsSidewaysWiiRemote() {
        #expect(
            LibretroControllerDevice.primaryDevice(
                coreID: "libretro-dolphin",
                systemName: "Wii",
                wiiProfile: .sidewaysWiiRemote
            ) == LibretroControllerDevice.sidewaysWiiRemote
        )

        let defaults = UserDefaults(
            suiteName: "LibretroCoreTests.wii-controller"
        )
        defaults?.removePersistentDomain(
            forName: "LibretroCoreTests.wii-controller"
        )
        #expect(
            LibretroWiiControllerPreferences.profile(
                from: defaults ?? .standard
            ) == .classicControllerPro
        )
        defaults?.set(
            LibretroWiiControllerProfile.sidewaysWiiRemote.rawValue,
            forKey: LibretroWiiControllerPreferences.profileKey
        )
        #expect(
            LibretroWiiControllerPreferences.profile(
                from: defaults ?? .standard
            ) == .sidewaysWiiRemote
        )
        defaults?.removePersistentDomain(
            forName: "LibretroCoreTests.wii-controller"
        )
    }

    @Test("Routes DSU and a local controller to separate players")
    func routesTwoControllerSources() {
        #expect(
            LibretroInputPortRouting.localPorts(
                hasDSU: true,
                controllerCount: 1
            ) == [1]
        )
        #expect(
            LibretroInputPortRouting.localPorts(
                hasDSU: false,
                controllerCount: 2
            ) == [0, 1]
        )
        #expect(
            LibretroInputPortRouting.localPorts(
                hasDSU: true,
                controllerCount: 2
            ) == [1]
        )
    }

    @Test("Maps the left stick to a D-pad with a dead zone")
    func mapsLeftAnalogToDPad() {
        let threshold = Int16.max / 2
        let unrelated = LibretroButton.a.mask | LibretroButton.start.mask

        #expect(
            LibretroInputState.buttonsMappingLeftAnalogToDPad(
                buttons: unrelated,
                x: -threshold,
                y: -threshold
            )
                == unrelated
                    | LibretroButton.left.mask
                    | LibretroButton.up.mask
        )
        #expect(
            LibretroInputState.buttonsMappingLeftAnalogToDPad(
                buttons: unrelated,
                x: threshold - 1,
                y: -(threshold - 1)
            ) == unrelated
        )
        #expect(
            LibretroInputState.buttonsMappingLeftAnalogToDPad(
                buttons: LibretroButton.down.mask,
                x: 0,
                y: -Int16.max
            ) == LibretroButton.down.mask
        )
    }

    @Test("Enables analog-to-D-pad only for digital configurations")
    func selectsAnalogToDPadConfigurations() {
        #expect(
            LibretroAnalogToDPadPolicy.applies(
                coreID: "libretro-nestopia",
                controllerDevice: LibretroControllerDevice.joypad,
                preferenceEnabled: true
            )
        )
        #expect(
            LibretroAnalogToDPadPolicy.applies(
                coreID: "libretro-mgba",
                controllerDevice: LibretroControllerDevice.joypad,
                preferenceEnabled: true
            )
        )
        #expect(
            LibretroAnalogToDPadPolicy.applies(
                coreID: "libretro-dolphin",
                controllerDevice:
                    LibretroControllerDevice.sidewaysWiiRemote,
                preferenceEnabled: true
            )
        )
        #expect(
            !LibretroAnalogToDPadPolicy.applies(
                coreID: "libretro-dolphin",
                controllerDevice:
                    LibretroControllerDevice.wiiClassicControllerPro,
                preferenceEnabled: true
            )
        )
        #expect(
            !LibretroAnalogToDPadPolicy.applies(
                coreID: "libretro-parallel-n64",
                controllerDevice: LibretroControllerDevice.joypad,
                preferenceEnabled: true
            )
        )
        #expect(
            !LibretroAnalogToDPadPolicy.applies(
                coreID: "libretro-nestopia",
                controllerDevice: LibretroControllerDevice.joypad,
                preferenceEnabled: false
            )
        )
    }

    @Test("Analog-to-D-pad defaults on and can be disabled")
    func persistsAnalogToDPadPreference() throws {
        let suiteName = "LibretroCoreTests.analog-to-dpad"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        #expect(
            LibretroDigitalInputPreferences.mapsLeftAnalogToDPad(
                from: defaults
            )
        )
        defaults.set(
            false,
            forKey: LibretroDigitalInputPreferences.mapsLeftAnalogToDPadKey
        )
        #expect(
            !LibretroDigitalInputPreferences.mapsLeftAnalogToDPad(
                from: defaults
            )
        )
        defaults.removePersistentDomain(forName: suiteName)
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

@Suite("Cemu companion")
struct CemuInstallationTests {
    @Test("Matches Cemu presentation to the RetroVault window")
    func matchesHostWindowPresentation() {
        #expect(CemuLaunchPresentation.matching(
            hostWindowIsFullScreen: true
        ) == .fullScreen)
        #expect(CemuLaunchPresentation.matching(
            hostWindowIsFullScreen: false
        ) == .windowed)
    }

    @Test("Maps a Cannoli Cemu save bundle into desktop Cemu's MLC layout")
    func mapsPortableSaveBundleIntoMLC() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let portableSaveURL = directory.appending(
            path: "save/user/80000001",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: portableSaveURL,
            withIntermediateDirectories: true
        )
        let restoredData = Data("romm-wind-waker-save".utf8)
        try restoredData.write(
            to: portableSaveURL.appending(path: "cking.sav")
        )
        let marker = """
            format=1
            emulator=CEMU
            title_id=0005000010143500
            """
        try marker.write(
                to: directory.appending(path: "cannoli-standalone-save.txt"),
                atomically: true,
                encoding: .utf8
            )
        let origin = try #require(
            try CemuInstallation.portableSaveOrigin(in: directory)
        )

        let staleSaveURL = directory.appending(
            path: "usr/save/00050000/10143500/user/80000001",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: staleSaveURL,
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(
            to: staleSaveURL.appending(path: "cking.sav")
        )

        #expect(try CemuInstallation.prepareRestoredSaveData(in: directory))
        let desktopSaveURL = directory.appending(
            path: "usr/save/00050000/10143500/user/80000001/cking.sav"
        )
        #expect(try Data(contentsOf: desktopSaveURL) == restoredData)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "save").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(
                    path: "cannoli-standalone-save.txt"
                ).path
            )
        )
        #expect(try !CemuInstallation.prepareRestoredSaveData(in: directory))

        let changedData = Data("changed-on-desktop".utf8)
        try changedData.write(to: desktopSaveURL, options: .atomic)
        try CemuInstallation.withPreservedSaveBundle(
            in: directory,
            origin: origin
        ) { portableDirectory in
            let preservedMarker = try Data(
                contentsOf: portableDirectory.appending(
                    path: "cannoli-standalone-save.txt"
                )
            )
            let preservedSave = try Data(
                contentsOf: portableDirectory.appending(
                    path: "save/user/80000001/cking.sav"
                )
            )
            #expect(preservedMarker == Data(marker.utf8))
            #expect(preservedSave == changedData)
            #expect(
                !FileManager.default.fileExists(
                    atPath: portableDirectory.appending(path: "usr").path
                )
            )
        }
    }

    @Test("Prepares private Cemu data and direct quick-launch arguments")
    func preparesPrivateRuntime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceApplication = directory.appending(
            path: "Source/Cemu.app",
            directoryHint: .isDirectory
        )
        let executable = sourceApplication.appending(
            path: "Contents/MacOS/Cemu"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let realExecutable = executable.deletingLastPathComponent()
            .appending(path: "Cemu.real")
        try Data("direct executable\n".utf8).write(to: realExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: realExecutable.path
        )

        let homeURL = directory.appending(
            path: "Home",
            directoryHint: .isDirectory
        )
        let userDataURL = homeURL
            .appending(path: "Library/Application Support/Cemu")
        let installation = CemuInstallation(
            sourceApplicationURL: sourceApplication,
            applicationSupportURL: directory.appending(
                path: "Support",
                directoryHint: .isDirectory
            ),
            cemuUserDataURL: userDataURL,
            processHomeURL: homeURL
        )
        let gameURL = directory.appending(path: "Games & More/Wind Waker.wua")
        let mlcURL = directory.appending(
            path: "Saves & Data/Wind Waker",
            directoryHint: .isDirectory
        )
        let runtime = try installation.prepareRuntime(
            dsuConfiguration: CemuDSUConfiguration(
                host: "127.0.0.1",
                port: 26_760,
                playerCount: 4
            ),
            contentURL: gameURL,
            mlcURL: mlcURL,
            launchPresentation: .fullScreen
        )

        #expect(FileManager.default.isExecutableFile(atPath: runtime.executableURL.path))
        #expect(runtime.executableURL == realExecutable)
        let settings = try String(
            contentsOf: runtime.userDataDirectory.appending(path: "settings.xml"),
            encoding: .utf8
        )
        #expect(settings.contains("<macos_disclaimer>true</macos_disclaimer>"))
        #expect(settings.contains("<fullscreen>true</fullscreen>"))
        #expect(settings.contains("<api>1</api>"))
        #expect(settings.contains("<mlc_path>\(directory.path)/Saves &amp; Data/Wind Waker</mlc_path>"))
        #expect(settings.contains("<Entry>\(directory.path)/Games &amp; More</Entry>"))
        #expect(settings.contains("<DSUC host=\"127.0.0.1\" port=\"26760\"/>"))
        #expect(settings.contains("<Audio>"))
        #expect(settings.contains("<api>3</api>"))
        #expect(settings.contains("<TVDevice>default</TVDevice>"))
        #expect(settings.contains("<TVVolume>50</TVVolume>"))

        let profile = try String(
            contentsOf: runtime.userDataDirectory
                .appending(path: "controllerProfiles/controller0.xml"),
            encoding: .utf8
        )
        #expect(profile.contains("RetroVault DSU Controller"))
        #expect(profile.contains("<rumble>1</rumble>"))
        #expect(profile.contains("<type>Wii U Pro Controller</type>"))
        #expect(!profile.contains("Wii U GamePad"))
        #expect(profile.contains("<ip>127.0.0.1</ip>"))
        #expect(profile.contains("<port>26760</port>"))
        #expect(profile.contains("<entry><mapping>12</mapping><button>4</button></entry>"))
        #expect(profile.contains("<entry><mapping>25</mapping><button>40</button></entry>"))
        for playerIndex in 0..<4 {
            let playerProfile = try String(
                contentsOf: runtime.userDataDirectory.appending(
                    path: "controllerProfiles/controller\(playerIndex).xml"
                ),
                encoding: .utf8
            )
            #expect(playerProfile.contains("RetroVault DSU Controller \(playerIndex + 1)"))
            #expect(playerProfile.contains("<uuid>\(playerIndex)</uuid>"))
            #expect(playerProfile.contains("<type>Wii U Pro Controller</type>"))
        }

        let launchArguments = runtime.launchArguments(
            contentURL: gameURL,
            mlcURL: mlcURL,
            presentation: .fullScreen
        )
        #expect(launchArguments == [
            "-g", gameURL.path,
            "-m", mlcURL.path,
            "-f",
        ])
        #expect(runtime.launchArguments(
            contentURL: gameURL,
            mlcURL: mlcURL,
            presentation: .windowed
        ) == [
            "-g", gameURL.path,
            "-m", mlcURL.path,
        ])

        _ = try installation.prepareRuntime(
            dsuConfiguration: nil,
            contentURL: gameURL,
            mlcURL: mlcURL,
            launchPresentation: .windowed
        )
        let windowedSettings = try String(
            contentsOf: runtime.userDataDirectory.appending(path: "settings.xml"),
            encoding: .utf8
        )
        #expect(windowedSettings.contains("<fullscreen>false</fullscreen>"))
        #expect(runtime.processEnvironment(merging: [:])["HOME"] == homeURL.path)

        let resourcesURL = sourceApplication.appending(
            path: "Contents/Resources",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        try Data().write(
            to: resourcesURL.appending(path: "RetroVaultMetalRenderer")
        )
        _ = try installation.prepareRuntime(
            dsuConfiguration: nil,
            contentURL: gameURL,
            mlcURL: mlcURL,
            launchPresentation: .windowed
        )
        let metalSettings = try String(
            contentsOf: runtime.userDataDirectory.appending(path: "settings.xml"),
            encoding: .utf8
        )
        #expect(installation.rendererName == "Metal")
        #expect(metalSettings.contains("<api>2</api>"))
    }

    @Test("Falls back to Vulkan only for known Metal compatibility issues")
    func selectsPerTitleRendererCompatibilityFallback() {
        let metalApplication = URL(fileURLWithPath: "/CemuMetal.app")
        let vulkanApplication = URL(fileURLWithPath: "/CemuVulkan.app")

        #expect(CemuCompatibilityOverrides.requiresVulkan(
            forGameTitle: "Super Mario 3D World"
        ))
        #expect(!CemuCompatibilityOverrides.requiresVulkan(
            forGameTitle: "Mario Kart 8"
        ))
        #expect(CemuInstallation.preferredApplicationURL(
            forGameTitle: "Super Mario 3D World",
            primaryApplicationURL: metalApplication,
            vulkanFallbackApplicationURL: vulkanApplication
        ) == vulkanApplication)
        #expect(CemuInstallation.preferredApplicationURL(
            forGameTitle: "The Legend of Zelda: The Wind Waker HD",
            primaryApplicationURL: metalApplication,
            vulkanFallbackApplicationURL: vulkanApplication
        ) == metalApplication)
        #expect(CemuInstallation.preferredApplicationURL(
            forGameTitle: "Super Mario 3D World",
            primaryApplicationURL: metalApplication,
            vulkanFallbackApplicationURL: nil
        ) == metalApplication)
    }

    @Test("Maps the shared internal-resolution setting to Cemu graphics packs")
    func mapsInternalResolutionToGraphicPacks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let modernPackURL = directory.appending(
            path: "graphicPacks/downloadedGraphicPacks/MarioKart8/Graphics/rules.txt"
        )
        try FileManager.default.createDirectory(
            at: modernPackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
            [Definition]
            name = Graphic Options
            path = "Mario Kart 8/Graphics"

            [Default]
            $width = 1280
            $height = 720
            $gameWidth = 1280
            $gameHeight = 720

            [Preset]
            category = TV Resolution
            name = 2560x1440
            $width = 2560
            $height = 1440

            [Preset]
            category = TV Resolution
            name = 5120x2880
            $width = 5120
            $height = 2880

            [Preset]
            category = Gamepad Resolution
            name = 2560x1440 Gamepad
            $width = 2560
            $height = 1440
            """.write(to: modernPackURL, atomically: true, encoding: .utf8)

        let legacyPackURL = directory.appending(
            path: "graphicPacks/downloadedGraphicPacks/WindWakerHD_Resolution/rules.txt"
        )
        try FileManager.default.createDirectory(
            at: legacyPackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
            [Definition]
            name = Resolution
            path = "The Legend of Zelda: The Wind Waker HD/Graphics/Resolution"

            [Preset]
            name = 2560x1440
            $width = 2560
            $height = 1440
            $gameWidth = 1280
            $gameHeight = 720

            [Preset]
            name = 5120x2880
            $width = 5120
            $height = 2880
            $gameWidth = 1280
            $gameHeight = 720
            """.write(to: legacyPackURL, atomically: true, encoding: .utf8)

        let twoX = try CemuGraphicPackCatalog.settingsXML(
            in: directory,
            resolution: .double,
            xmlEscaped: { $0 }
        )
        #expect(twoX.contains("category=\"TV Resolution\" preset=\"2560x1440\""))
        #expect(twoX.contains("WindWakerHD_Resolution/rules.txt"))
        #expect(twoX.contains("<Preset preset=\"2560x1440\"/>"))
        #expect(!twoX.contains("Gamepad Resolution"))

        let fourX = try CemuGraphicPackCatalog.settingsXML(
            in: directory,
            resolution: .quadruple,
            xmlEscaped: { $0 }
        )
        #expect(fourX.contains("category=\"TV Resolution\" preset=\"5120x2880\""))
        #expect(fourX.contains("<Preset preset=\"5120x2880\"/>"))

        let native = try CemuGraphicPackCatalog.settingsXML(
            in: directory,
            resolution: .native,
            xmlEscaped: { $0 }
        )
        #expect(native == "  <GraphicPack/>")
    }
}

import Foundation
import Metal
import SwiftUI
import Testing
@testable import OpenVault

@Suite("Bundled Libretro cores")
struct LibretroCoreManifestTests {
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

        #expect(manifest.supportsSystem(named: "Game Boy"))
        #expect(manifest.supportsSystem(named: "Sega Master System/Mark III"))
        #expect(manifest.supportsSystem(named: "Nintendo GameCube"))
        #expect(manifest.supportsSystem(named: "PlayStation Portable"))
        #expect(manifest.supportsSystem(named: "Virtual Boy"))
        #expect(!manifest.supportsSystem(named: "Dreamcast"))
        #expect(!manifest.supportsSystem(named: "PlayStation 2"))
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

    @Test("Compiles the explicit nearest-neighbor Metal shader")
    func compilesPixelShader() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(
            source: LibretroMetalShader.source,
            options: nil
        )

        #expect(library.makeFunction(name: "openVaultPixelVertex") != nil)
        #expect(library.makeFunction(name: "openVaultPixelFragment") != nil)
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

@Suite("Game details layout")
struct GameDetailsLayoutTests {
    @Test("Keeps foreground content inside the split-view safe area")
    func respectsSidebarSafeArea() {
        let viewport = GameDetailsViewport(
            containerFrame: CGRect(x: 0, y: 0, width: 1_500, height: 900),
            safeAreaInsets: SwiftUI.EdgeInsets(
                top: 18,
                leading: 300,
                bottom: 12,
                trailing: 20
            )
        )

        #expect(viewport.origin == CGPoint(x: 300, y: 18))
        #expect(viewport.size == CGSize(width: 1_180, height: 870))
    }

    @Test("Does not apply an already consumed split-view offset twice")
    func doesNotDuplicateConsumedInsets() {
        let viewport = GameDetailsViewport(
            containerFrame: CGRect(x: 300, y: 18, width: 1_180, height: 870),
            safeAreaInsets: SwiftUI.EdgeInsets(
                top: 18,
                leading: 300,
                bottom: 12,
                trailing: 20
            )
        )

        #expect(viewport.origin == .zero)
        #expect(viewport.size == CGSize(width: 1_160, height: 858))
    }

    @Test("Clamps a fully occluded viewport to zero")
    func clampsFullyOccludedViewport() {
        let viewport = GameDetailsViewport(
            containerFrame: CGRect(x: 0, y: 0, width: 250, height: 100),
            safeAreaInsets: SwiftUI.EdgeInsets(
                top: 60,
                leading: 180,
                bottom: 60,
                trailing: 180
            )
        )

        #expect(viewport.size == .zero)
    }
}

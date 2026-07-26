import Foundation
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
            ) == nil
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
        #expect(manifest.core(id: "libretro-2048")?.status == .pipelineTest)
    }
}

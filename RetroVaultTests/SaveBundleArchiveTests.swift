import Foundation
import Testing
import ZIPFoundation

@testable import RetroVault

@Suite("Save bundle archives")
struct SaveBundleArchiveTests {
    @Test("Hashes directory contents independently from modification dates")
    func hashesContents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let dataURL = directory.appending(
            path: "PSP/SAVEDATA/GAME/DATA.BIN"
        )
        try FileManager.default.createDirectory(
            at: dataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("save-one".utf8).write(to: dataURL)

        let archiver = SaveBundleArchive()
        let firstHash = try #require(
            try archiver.contentHash(of: directory)
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 42)],
            ofItemAtPath: dataURL.path
        )
        #expect(try archiver.contentHash(of: directory) == firstHash)

        try Data("save-two".utf8).write(to: dataURL, options: .atomic)
        #expect(try archiver.contentHash(of: directory) != firstHash)
    }

    @Test("Restores a bundle by replacing the existing save directory")
    func replacesExistingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appending(
            path: "Source",
            directoryHint: .isDirectory
        )
        let sourceData = source.appending(
            path: "PSP/SAVEDATA/GAME/DATA.BIN"
        )
        try FileManager.default.createDirectory(
            at: sourceData.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new-save".utf8).write(to: sourceData)

        let archiveData = try #require(
            try SaveBundleArchive().data(from: source)
        )
        let archiveURL = root.appending(path: "Save.zip")
        try archiveData.write(to: archiveURL)

        let destination = root.appending(
            path: "Destination",
            directoryHint: .isDirectory
        )
        let staleData = destination.appending(path: "Stale.bin")
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: staleData)

        try SaveBundleArchive().restore(
            from: archiveURL,
            to: destination
        )

        #expect(
            try Data(
                contentsOf: destination.appending(
                    path: "PSP/SAVEDATA/GAME/DATA.BIN"
                )
            ) == Data("new-save".utf8)
        )
        #expect(!FileManager.default.fileExists(atPath: staleData.path))
    }

    @Test("Rejects ZIP entries that escape the save directory")
    func rejectsPathTraversal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let archiveURL = directory.appending(path: "Unsafe.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let content = Data("unsafe".utf8)
        try archive.addEntry(
            with: "../Escaped.bin",
            type: .file,
            uncompressedSize: Int64(content.count),
            compressionMethod: .deflate,
            provider: { position, size in
                content.subdata(
                    in: Int(position)..<min(
                        Int(position) + size,
                        content.count
                    )
                )
            }
        )

        let destination = directory.appending(
            path: "Destination",
            directoryHint: .isDirectory
        )
        #expect(throws: SaveBundleArchiveError.self) {
            try SaveBundleArchive().restore(
                from: archiveURL,
                to: destination
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "Escaped.bin").path
            )
        )
    }
}

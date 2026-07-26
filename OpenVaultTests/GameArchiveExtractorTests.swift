import Foundation
import Testing
@testable import OpenVault

@Suite("Game archive extraction")
struct GameArchiveExtractorTests {
    private static let fixture = Data(
        base64Encoded: """
        UEsDBAoAAAAAAIWy+VwAAAAAAAAAAAAAAAAHAAAAbmVzdGVkL1BLAwQKAAAAAACFsvlc\
        asJpzQcAAAAHAAAADgAAAG5lc3RlZC9HYW1lLmdiUk9NREFUQVBLAwQKAAAAAACFsvlc\
        Gp3FJwUAAAAFAAAACQAAAE90aGVyLm5lc3dyb25nUEsDBAoAAAAAAIWy+VwAAAAAAAA\
        AAAAAAAAJAAAAX19NQUNPU1gvUEsDBAoAAAAAAIWy+VwUNBRPCAAAAAgAAAASAAAAX19\
        NQUNPU1gvLl9HYW1lLmdibWV0YWRhdGFQSwECHgMKAAAAAACFsvlcAAAAAAAAAAAAAA\
        AABwAAAAAAAAAAABAA7UEAAAAAbmVzdGVkL1BLAQIeAwoAAAAAAIWy+VxqwmnNBwAAA\
        AcAAAAOAAAAAAAAAAEAAACkgSUAAABuZXN0ZWQvR2FtZS5nYlBLAQIeAwoAAAAAAIWy\
        +VwancUnBQAAAAUAAAAJAAAAAAAAAAEAAACkgVgAAABPdGhlci5uZXNQSwECHgMKAAAA\
        AACFsvlcAAAAAAAAAAAAAAAACQAAAAAAAAAAABAA7UGEAAAAX19NQUNPU1gvUEsBAh4D\
        CgAAAAAAhbL5XBQ0FE8IAAAACAAAABIAAAAAAAAAAQAAAKSBqwAAAF9fTUFDT1NYLy5\
        fR2FtZS5nYlBLBQYAAAAABQAFAB8BAADjAAAAAAA=
        """.replacingOccurrences(of: "\\", with: "")
    )!

    @Test("Extracts one compatible regular file and reuses it")
    func extractsCompatibleContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let archiveURL = directory.appending(path: "Game.zip")
        try Self.fixture.write(to: archiveURL)

        let extractor = ZIPFoundationGameArchiveExtractor()
        let firstURL = try extractor.playableContent(
            from: archiveURL,
            supportedFileExtensions: ["gb", "gbc"]
        )
        let secondURL = try extractor.playableContent(
            from: archiveURL,
            supportedFileExtensions: ["gb", "gbc"]
        )

        #expect(firstURL == secondURL)
        #expect(firstURL.lastPathComponent == "Game.gb")
        #expect(try Data(contentsOf: firstURL) == Data("ROMDATA".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "Extracted/nested").path
            )
        )
    }

    @Test("Rejects archives without content supported by the selected core")
    func rejectsUnsupportedContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let archiveURL = directory.appending(path: "Game.zip")
        try Self.fixture.write(to: archiveURL)

        #expect(throws: GameArchiveError.self) {
            try ZIPFoundationGameArchiveExtractor().playableContent(
                from: archiveURL,
                supportedFileExtensions: ["gbc"]
            )
        }
    }
}

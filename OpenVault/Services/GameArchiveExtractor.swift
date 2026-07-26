import Foundation
import ZIPFoundation

/// Extracts one core-compatible game file from a cached archive.
protocol GameArchiveExtracting: Sendable {
    func playableContent(
        from sourceURL: URL,
        supportedFileExtensions: [String]
    ) throws -> URL
}

/// ZIP extraction backed by ZIPFoundation.
///
/// OpenVault extracts only a regular file whose extension is declared by the
/// selected core. Directory paths and symbolic links from the archive are
/// never materialized.
struct ZIPFoundationGameArchiveExtractor: GameArchiveExtracting {
    private static let maximumExtractedBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024

    func playableContent(
        from sourceURL: URL,
        supportedFileExtensions: [String]
    ) throws -> URL {
        let supportedExtensions = Set(
            supportedFileExtensions.map(Self.normalizedFileExtension)
                .filter { !$0.isEmpty }
        )
        let sourceExtension = Self.normalizedFileExtension(sourceURL.pathExtension)

        guard !supportedExtensions.isEmpty else {
            throw GameArchiveError.noSupportedContent(supportedFileExtensions)
        }
        guard sourceExtension == "zip" else {
            guard supportedExtensions.contains(sourceExtension) else {
                throw GameArchiveError.noSupportedContent(supportedFileExtensions)
            }
            return sourceURL
        }

        let archive: Archive
        do {
            archive = try Archive(url: sourceURL, accessMode: .read)
        } catch {
            throw GameArchiveError.invalidArchive(reason: error.localizedDescription)
        }

        let archiveStem = sourceURL.deletingPathExtension()
            .lastPathComponent
            .lowercased()
        let candidates = archive
            .filter { entry in
                guard entry.type == .file else {
                    return false
                }
                let path = Self.normalizedArchivePath(entry.path)
                let components = path.split(separator: "/", omittingEmptySubsequences: true)
                guard !components.isEmpty,
                      !components.contains(where: {
                          $0 == "__MACOSX" || $0.hasPrefix(".")
                      })
                else {
                    return false
                }
                return supportedExtensions.contains(
                    Self.normalizedFileExtension(
                        URL(fileURLWithPath: path).pathExtension
                    )
                )
            }
            .sorted { lhs, rhs in
                let lhsMatchesArchive = Self.stem(of: lhs.path) == archiveStem
                let rhsMatchesArchive = Self.stem(of: rhs.path) == archiveStem
                if lhsMatchesArchive != rhsMatchesArchive {
                    return lhsMatchesArchive
                }
                if lhs.uncompressedSize != rhs.uncompressedSize {
                    return lhs.uncompressedSize > rhs.uncompressedSize
                }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

        guard let entry = candidates.first else {
            throw GameArchiveError.noSupportedContent(
                supportedExtensions.sorted()
            )
        }
        guard entry.uncompressedSize <= Self.maximumExtractedBytes else {
            throw GameArchiveError.contentTooLarge(
                name: URL(fileURLWithPath: entry.path).lastPathComponent
            )
        }

        return try extract(
            entry,
            from: archive,
            nextTo: sourceURL
        )
    }

    private func extract(
        _ entry: Entry,
        from archive: Archive,
        nextTo sourceURL: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let extractionDirectory = sourceURL.deletingLastPathComponent()
            .appending(path: "Extracted", directoryHint: .isDirectory)
        let entryPath = Self.normalizedArchivePath(entry.path)
        let fileName = URL(fileURLWithPath: entryPath).lastPathComponent
        let destination = extractionDirectory.appending(path: fileName)

        if fileManager.fileExists(atPath: destination.path) {
            let values = try? destination.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values?.fileSize,
               fileSize >= 0,
               UInt64(fileSize) == entry.uncompressedSize {
                try? fileManager.setAttributes(
                    [.modificationDate: Date.now],
                    ofItemAtPath: destination.path
                )
                return destination
            }
            try fileManager.removeItem(at: destination)
        }

        try fileManager.createDirectory(
            at: extractionDirectory,
            withIntermediateDirectories: true
        )
        let temporaryURL = extractionDirectory
            .appending(path: ".\(UUID().uuidString).partial")
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        do {
            _ = try archive.extract(entry, to: temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: destination)
            return destination
        } catch {
            throw GameArchiveError.extractionFailed(
                name: fileName,
                reason: error.localizedDescription
            )
        }
    }

    private static func normalizedFileExtension(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private static func normalizedArchivePath(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "/")
    }

    private static func stem(of path: String) -> String {
        URL(fileURLWithPath: normalizedArchivePath(path))
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
    }
}

enum GameArchiveError: LocalizedError {
    case invalidArchive(reason: String)
    case noSupportedContent([String])
    case contentTooLarge(name: String)
    case extractionFailed(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalidArchive(reason):
            return "OpenVault could not read this ZIP archive: \(reason)"
        case let .noSupportedContent(fileExtensions):
            let formats = fileExtensions
                .map { ".\($0.trimmingCharacters(in: CharacterSet(charactersIn: ".")))" }
                .joined(separator: ", ")
            return "This ZIP archive does not contain a supported game file (\(formats))."
        case let .contentTooLarge(name):
            return "The archived game \(name) is larger than OpenVault's 20 GB playback cache limit."
        case let .extractionFailed(name, reason):
            return "OpenVault could not extract \(name) from the ZIP archive: \(reason)"
        }
    }
}

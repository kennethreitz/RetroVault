import CryptoKit
import Foundation
import ZIPFoundation

/// Archives directory-based emulator saves without letting ZIP metadata
/// participate in change detection.
struct SaveBundleArchive: Sendable {
  private static let maximumEntryCount = 10_000
  private static let maximumUncompressedBytes: UInt64 =
    512 * 1_024 * 1_024
  private static let hashReadSize = 1_024 * 1_024

  /// Returns a stable hash of every regular file's relative path and contents.
  ///
  /// Modification dates and ZIP container bytes are intentionally excluded so
  /// an unchanged save directory is not uploaded again.
  func contentHash(of directoryURL: URL) throws -> String? {
    let files = try regularFiles(in: directoryURL)
    guard !files.isEmpty else {
      return nil
    }

    var hasher = SHA256()
    for file in files {
      hasher.update(data: Data(file.relativePath.utf8))
      hasher.update(data: Data([0]))

      let handle = try FileHandle(forReadingFrom: file.url)
      defer {
        try? handle.close()
      }
      while let chunk = try handle.read(upToCount: Self.hashReadSize),
        !chunk.isEmpty
      {
        hasher.update(data: chunk)
      }
      hasher.update(data: Data([0xFF]))
    }

    return hasher.finalize()
      .map { String(format: "%02x", $0) }
      .joined()
  }

  /// Creates a ZIP containing the directory's regular files.
  func data(from directoryURL: URL) throws -> Data? {
    let files = try regularFiles(in: directoryURL)
    guard !files.isEmpty else {
      return nil
    }

    let archiveURL = FileManager.default.temporaryDirectory
      .appending(path: "OpenVault-\(UUID().uuidString).zip")
    defer {
      try? FileManager.default.removeItem(at: archiveURL)
    }

    let archive = try Archive(url: archiveURL, accessMode: .create)
    for file in files {
      try archive.addEntry(
        with: file.relativePath,
        fileURL: file.url,
        compressionMethod: .deflate
      )
    }
    return try Data(contentsOf: archiveURL)
  }

  /// Replaces a local save directory with the contents of a validated ZIP.
  func restore(from archiveURL: URL, to directoryURL: URL) throws {
    let archive: Archive
    do {
      archive = try Archive(url: archiveURL, accessMode: .read)
    } catch {
      throw SaveBundleArchiveError.invalidArchive(
        reason: error.localizedDescription
      )
    }

    let entries = Array(archive)
    guard !entries.isEmpty else {
      throw SaveBundleArchiveError.emptyArchive
    }
    guard entries.count <= Self.maximumEntryCount else {
      throw SaveBundleArchiveError.archiveTooLarge
    }

    var uncompressedBytes: UInt64 = 0
    for entry in entries {
      guard entry.type != .symlink, Self.isSafePath(entry.path) else {
        throw SaveBundleArchiveError.unsafeEntry(entry.path)
      }
      let (total, overflow) = uncompressedBytes.addingReportingOverflow(
        entry.uncompressedSize
      )
      guard !overflow, total <= Self.maximumUncompressedBytes else {
        throw SaveBundleArchiveError.archiveTooLarge
      }
      uncompressedBytes = total
    }

    let fileManager = FileManager.default
    let parentURL = directoryURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parentURL,
      withIntermediateDirectories: true
    )
    let stagingURL = parentURL.appending(
      path: ".OpenVaultSaveRestore-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: true
    )
    defer {
      try? fileManager.removeItem(at: stagingURL)
    }

    for entry in entries {
      let destinationURL = stagingURL.appending(path: entry.path)
      _ = try archive.extract(entry, to: destinationURL)
    }

    if fileManager.fileExists(atPath: directoryURL.path) {
      let backupName = ".OpenVaultSaveBackup-\(UUID().uuidString)"
      _ = try fileManager.replaceItemAt(
        directoryURL,
        withItemAt: stagingURL,
        backupItemName: backupName,
        options: [.usingNewMetadataOnly]
      )
      try? fileManager.removeItem(
        at: parentURL.appending(path: backupName)
      )
    } else {
      try fileManager.moveItem(at: stagingURL, to: directoryURL)
    }
  }

  private func regularFiles(
    in directoryURL: URL
  ) throws -> [(url: URL, relativePath: String)] {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: directoryURL.path,
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue
    else {
      return []
    }

    let resourceKeys: [URLResourceKey] = [
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: resourceKeys,
        options: [.skipsPackageDescendants]
      )
    else {
      return []
    }

    let rootPath = directoryURL.standardizedFileURL.path
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var files: [(url: URL, relativePath: String)] = []
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        continue
      }

      let standardizedPath = fileURL.standardizedFileURL.path
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard standardizedPath.hasPrefix(rootPath + "/") else {
        throw SaveBundleArchiveError.unsafeEntry(fileURL.path)
      }
      let relativePath = String(
        standardizedPath.dropFirst(rootPath.count + 1)
      )
      guard Self.isSafePath(relativePath) else {
        throw SaveBundleArchiveError.unsafeEntry(relativePath)
      }
      files.append((fileURL, relativePath))
    }

    guard files.count <= Self.maximumEntryCount else {
      throw SaveBundleArchiveError.archiveTooLarge
    }
    return files.sorted {
      $0.relativePath.localizedStandardCompare($1.relativePath)
        == .orderedAscending
    }
  }

  private static func isSafePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/") else {
      return false
    }
    let components = path.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
  }
}

enum SaveBundleArchiveError: LocalizedError {
  case invalidArchive(reason: String)
  case emptyArchive
  case archiveTooLarge
  case unsafeEntry(String)

  var errorDescription: String? {
    switch self {
    case .invalidArchive(let reason):
      "The save bundle is not a valid ZIP archive: \(reason)"
    case .emptyArchive:
      "The save bundle is empty."
    case .archiveTooLarge:
      "The save bundle is too large to restore safely."
    case .unsafeEntry(let path):
      "The save bundle contains an unsafe entry: \(path)"
    }
  }
}

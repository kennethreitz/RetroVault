import Foundation

enum GameSaveDataKind: Sendable {
  case save
  case state
}

/// A server notification indicating that cached library metadata may be stale.
struct RomMLibraryChangeEvent: Equatable, Sendable {
  let name: String
}

protocol RomMClient: Sendable {
  func verifyServer(at serverURL: ServerURL) async throws
  func exchange(pairingCode: PairingCode, at serverURL: ServerURL) async throws -> ClientToken
  func currentUser(at serverURL: ServerURL, token: ClientToken) async throws -> RomMUser
  func systems(at serverURL: ServerURL, token: ClientToken) async throws -> [LibrarySystem]
  func collections(at serverURL: ServerURL, token: ClientToken) async throws -> [LibraryCollection]
  func games(
    at serverURL: ServerURL,
    token: ClientToken,
    matching filter: LibraryFilter,
    searchTerm: String?,
    ordering: GamePageOrdering,
    offset: Int,
    limit: Int
  ) async throws -> GamePage
  func games(
    at serverURL: ServerURL,
    token: ClientToken,
    matching filter: LibraryFilter,
    searchTerm: String?,
    ordering: GamePageOrdering,
    updatedAfter: Date?,
    offset: Int,
    limit: Int
  ) async throws -> GamePage
  func libraryChangeEvents(
    at serverURL: ServerURL,
    token: ClientToken
  ) -> AsyncStream<RomMLibraryChangeEvent>
  func gameIDsWithSaveData(
    _ kind: GameSaveDataKind,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> Set<Int>
  func gameDetails(
    for gameID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameDetails
  func updateGameUserMetadata(
    _ metadata: GameUserMetadata,
    for gameID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameUserMetadata
  func updateCollectionMembership(
    collectionID: Int,
    gameIDs: [Int],
    adding: Bool,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> LibraryCollection
  func downloadGame(
    for gameID: Int,
    fileName: String,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload
  func downloadGame(
    for gameID: Int,
    fileName: String,
    at serverURL: ServerURL,
    token: ClientToken,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> RomMDownload
  func firmware(
    for platformID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> [RomMFirmware]
  func downloadFirmware(
    _ firmware: RomMFirmware,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload
  func downloadSave(
    _ save: GameSaveDataItem,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload
  func uploadSave(
    _ data: Data,
    fileName: String,
    for gameID: Int,
    emulator: String,
    slot: String,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameSaveDataItem
  func deleteGames(
    withIDs gameIDs: [Int],
    deletingFiles: Bool,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameDeletionResult
}

extension RomMClient {
  func games(
    at serverURL: ServerURL,
    token: ClientToken,
    matching filter: LibraryFilter,
    searchTerm: String?,
    ordering: GamePageOrdering,
    updatedAfter: Date?,
    offset: Int,
    limit: Int
  ) async throws -> GamePage {
    try await games(
      at: serverURL,
      token: token,
      matching: filter,
      searchTerm: searchTerm,
      ordering: ordering,
      offset: offset,
      limit: limit
    )
  }

  func libraryChangeEvents(
    at serverURL: ServerURL,
    token: ClientToken
  ) -> AsyncStream<RomMLibraryChangeEvent> {
    AsyncStream { $0.finish() }
  }

  func updateCollectionMembership(
    collectionID: Int,
    gameIDs: [Int],
    adding: Bool,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> LibraryCollection {
    throw RomMAPIError.invalidResponse
  }

  func downloadGame(
    for gameID: Int,
    fileName: String,
    at serverURL: ServerURL,
    token: ClientToken,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> RomMDownload {
    try await downloadGame(
      for: gameID,
      fileName: fileName,
      at: serverURL,
      token: token
    )
  }

  func firmware(
    for platformID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> [RomMFirmware] {
    []
  }

  func downloadFirmware(
    _ firmware: RomMFirmware,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload {
    throw RomMAPIError.invalidResponse
  }

  func gameIDsWithSaveData(
    _ kind: GameSaveDataKind,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> Set<Int> {
    []
  }

  func deleteGames(
    withIDs gameIDs: [Int],
    deletingFiles: Bool,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameDeletionResult {
    throw RomMAPIError.invalidResponse
  }

  func downloadSave(
    _ save: GameSaveDataItem,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload {
    throw RomMAPIError.invalidResponse
  }

  func uploadSave(
    _ data: Data,
    fileName: String,
    for gameID: Int,
    emulator: String,
    slot: String,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameSaveDataItem {
    throw RomMAPIError.invalidResponse
  }
}

/// A ROM streamed by URLSession into a temporary file.
///
/// Callers must move or remove `temporaryFileURL` before releasing this value.
struct RomMDownload: Sendable {
  let temporaryFileURL: URL
  let suggestedFileName: String
}

/// Byte progress for a ROM streamed from RomM.
struct RomMDownloadProgress: Equatable, Sendable {
  let bytesReceived: Int64
  let totalBytesExpected: Int64?

  var fractionCompleted: Double? {
    guard let totalBytesExpected, totalBytesExpected > 0 else {
      return nil
    }
    return min(
      max(Double(bytesReceived) / Double(totalBytesExpected), 0),
      1
    )
  }
}

/// A system-level firmware file managed by RomM.
struct RomMFirmware: Codable, Hashable, Identifiable, Sendable {
  let id: Int
  let fileName: String
  let fileSizeBytes: Int64
  let sha1Hash: String?
  let isVerified: Bool
  let isMissingFromFileSystem: Bool
}

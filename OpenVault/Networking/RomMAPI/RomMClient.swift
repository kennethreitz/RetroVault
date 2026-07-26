import Foundation

enum GameSaveDataKind: Sendable {
  case save
  case state
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
    offset: Int,
    limit: Int
  ) async throws -> GamePage
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
  func downloadGame(
    for gameID: Int,
    fileName: String,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload
}

extension RomMClient {
  func gameIDsWithSaveData(
    _ kind: GameSaveDataKind,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> Set<Int> {
    []
  }
}

/// A ROM streamed by URLSession into a temporary file.
///
/// Callers must move or remove `temporaryFileURL` before releasing this value.
struct RomMDownload: Sendable {
  let temporaryFileURL: URL
  let suggestedFileName: String
}

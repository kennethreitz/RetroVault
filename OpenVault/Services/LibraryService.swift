import CryptoKit
import Foundation
import OSLog

protocol LibraryServing: Sendable {
  func cachedSnapshot(in session: ServerSession) async throws -> LibrarySnapshot?
  func purgeLocalCache() async throws
  func synchronizeLibrary(
    in session: ServerSession,
    onProgress: @escaping @Sendable (LibrarySyncProgress) async -> Void
  ) async throws -> LibrarySnapshot
  func systems(in session: ServerSession) async throws -> [LibrarySystem]
  func collections(in session: ServerSession) async throws -> [LibraryCollection]
  func games(
    in session: ServerSession,
    matching filter: LibraryFilter,
    searchTerm: String?,
    offset: Int,
    limit: Int
  ) async throws -> GamePage
  func systemHasArtwork(_ systemID: Int, in session: ServerSession) async throws -> Bool
  func gameDetails(for gameID: Int, in session: ServerSession) async throws -> GameDetails
  func updateUserMetadata(
    _ metadata: GameUserMetadata,
    for game: GameDetails,
    in session: ServerSession
  ) async throws -> GameDetails
  func downloadGame(_ game: GameDetails, in session: ServerSession) async throws -> URL
  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String]
  ) async throws -> URL
  func artworkRequest(for game: GameSummary, in session: ServerSession) async throws -> URLRequest?
  func resourceRequest(for url: URL?, in session: ServerSession) async throws -> URLRequest?
}

extension LibraryServing {
  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String]
  ) async throws -> URL {
    throw LibraryServiceError.playbackCacheUnavailable
  }
}

actor RomMLibraryService: LibraryServing {
  private static let artworkInspectionPageSize = 500
  private static let synchronizationPageSize = 500
  private static let maximumRuntimeCacheBytes: Int64 = 20 * 1_024 * 1_024 * 1_024

  private let api: any RomMClient
  private let credentialStore: any CredentialStoring
  private let cache: any LibraryCaching
  private let downloadsDirectory: URL
  private let runtimeCacheDirectory: URL
  private let archiveExtractor: any GameArchiveExtracting
  private let purgeArtworkCache: @Sendable () -> Void
  private let now: @Sendable () -> Date

  init(
    api: any RomMClient,
    credentialStore: any CredentialStoring,
    cache: any LibraryCaching = InMemoryLibraryCache(),
    downloadsDirectory: URL? = nil,
    runtimeCacheDirectory: URL? = nil,
    archiveExtractor: any GameArchiveExtracting = ZIPFoundationGameArchiveExtractor(),
    purgeArtworkCache: @escaping @Sendable () -> Void = {},
    now: @escaping @Sendable () -> Date = { .now }
  ) {
    self.api = api
    self.credentialStore = credentialStore
    self.cache = cache
    self.downloadsDirectory =
      downloadsDirectory
      ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? URL.homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    self.runtimeCacheDirectory =
      runtimeCacheDirectory
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "ROMs", directoryHint: .isDirectory)
      ?? URL.temporaryDirectory
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "ROMs", directoryHint: .isDirectory)
    self.archiveExtractor = archiveExtractor
    self.purgeArtworkCache = purgeArtworkCache
    self.now = now
  }

  func cachedSnapshot(in session: ServerSession) async throws -> LibrarySnapshot? {
    try await cache.snapshot(for: session.serverURL)
  }

  func purgeLocalCache() async throws {
    try await cache.removeAll()
    purgeArtworkCache()
  }

  func synchronizeLibrary(
    in session: ServerSession,
    onProgress: @escaping @Sendable (LibrarySyncProgress) async -> Void
  ) async throws -> LibrarySnapshot {
    OpenVaultLog.library.notice("Starting RomM library synchronization")
    let token = try await authenticationToken()
    async let saveGameIDsRequest = api.gameIDsWithSaveData(
      .save,
      at: session.serverURL,
      token: token
    )
    async let stateGameIDsRequest = api.gameIDsWithSaveData(
      .state,
      at: session.serverURL,
      token: token
    )
    async let systemsRequest = api.systems(
      at: session.serverURL,
      token: token
    )
    async let collectionsRequest = api.collections(
      at: session.serverURL,
      token: token
    )
    let (remoteSystems, remoteCollections) = try await (
      systemsRequest,
      collectionsRequest
    )

    var allGames: [GameSummary] = []
    var seenGameIDs: Set<Int> = []
    var offset = 0

    while true {
      let page = try await api.games(
        at: session.serverURL,
        token: token,
        matching: .allGames,
        searchTerm: nil,
        offset: offset,
        limit: Self.synchronizationPageSize
      )
      let newGames = page.games.filter {
        !$0.isBIOS && seenGameIDs.insert($0.id).inserted
      }
      allGames.append(contentsOf: newGames)

      await onProgress(
        LibrarySyncProgress(
          systems: remoteSystems,
          collections: remoteCollections,
          games: newGames,
          completedGameCount: min(
            page.offset + page.games.count,
            page.total
          ),
          totalGameCount: page.total
        )
      )

      guard page.hasMore else {
        break
      }
      guard !page.games.isEmpty else {
        throw LibraryServiceError.incompleteSynchronization
      }
      offset = page.offset + page.games.count
    }

    let (saveGameIDs, stateGameIDs) = try await (
      saveGameIDsRequest,
      stateGameIDsRequest
    )
    allGames = allGames.map { game in
      game.withSaveDataAvailability(
        hasSave: saveGameIDs.contains(game.id),
        hasState: stateGameIDs.contains(game.id)
      )
    }

    let memberships = try await collectionMemberships(
      for: remoteCollections,
      session: session,
      token: token
    )
    let systemCounts = Dictionary(grouping: allGames, by: \.systemID)
      .mapValues(\.count)
    let systems = remoteSystems.map {
      LibrarySystem(
        id: $0.id,
        name: $0.name,
        gameCount: systemCounts[$0.id, default: 0]
      )
    }
    let membershipCounts = Dictionary(
      uniqueKeysWithValues: memberships.map {
        ($0.collectionID, $0.gameIDs.count)
      }
    )
    let collections = remoteCollections.map {
      LibraryCollection(
        id: $0.id,
        name: $0.name,
        gameCount: membershipCounts[$0.id, default: 0]
      )
    }
    let snapshot = LibrarySnapshot(
      synchronizedAt: now(),
      systems: systems,
      collections: collections,
      games: allGames,
      collectionMemberships: memberships
    )

    try await cache.replaceSnapshot(snapshot, for: session.serverURL)
    OpenVaultLog.library.notice(
      "Synchronized \(snapshot.games.count, privacy: .public) games across \(snapshot.systems.count, privacy: .public) systems"
    )
    return snapshot
  }

  func systems(in session: ServerSession) async throws -> [LibrarySystem] {
    if let snapshot = try await cache.snapshot(for: session.serverURL) {
      return snapshot.systems
    }

    return try await api.systems(
      at: session.serverURL,
      token: authenticationToken()
    )
  }

  func collections(in session: ServerSession) async throws -> [LibraryCollection] {
    if let snapshot = try await cache.snapshot(for: session.serverURL) {
      return snapshot.collections
    }

    return try await api.collections(
      at: session.serverURL,
      token: authenticationToken()
    )
  }

  func games(
    in session: ServerSession,
    matching filter: LibraryFilter,
    searchTerm: String?,
    offset: Int,
    limit: Int
  ) async throws -> GamePage {
    if let snapshot = try await cache.snapshot(for: session.serverURL) {
      return snapshot.page(
        matching: filter,
        searchTerm: searchTerm,
        offset: offset,
        limit: limit
      )
    }

    return try await api.games(
      at: session.serverURL,
      token: authenticationToken(),
      matching: filter,
      searchTerm: searchTerm,
      offset: offset,
      limit: limit
    )
  }

  func systemHasArtwork(_ systemID: Int, in session: ServerSession) async throws -> Bool {
    if let snapshot = try await cache.snapshot(for: session.serverURL) {
      return snapshot.games.contains {
        $0.systemID == systemID && !$0.isBIOS && $0.coverURL != nil
      }
    }

    let token = try await authenticationToken()
    var offset = 0

    while true {
      let page = try await api.games(
        at: session.serverURL,
        token: token,
        matching: .system(systemID),
        searchTerm: nil,
        offset: offset,
        limit: Self.artworkInspectionPageSize
      )

      if page.games.contains(where: { !$0.isBIOS && $0.coverURL != nil }) {
        return true
      }

      guard page.hasMore, !page.games.isEmpty else {
        return false
      }
      offset += page.games.count
    }
  }

  func gameDetails(for gameID: Int, in session: ServerSession) async throws -> GameDetails {
    do {
      let details = try await api.gameDetails(
        for: gameID,
        at: session.serverURL,
        token: authenticationToken()
      )
      try? await cache.saveGameDetails(details, for: session.serverURL)
      return details
    } catch RomMAPIError.notFound {
      throw LibraryServiceError.gameNotFound
    } catch {
      if let cachedDetails = try? await cache.gameDetails(
        for: gameID,
        serverURL: session.serverURL
      ) {
        OpenVaultLog.library.notice(
          "Using cached details for game \(gameID, privacy: .public)"
        )
        return cachedDetails
      }
      throw error
    }
  }

  func updateUserMetadata(
    _ metadata: GameUserMetadata,
    for game: GameDetails,
    in session: ServerSession
  ) async throws -> GameDetails {
    let updatedMetadata: GameUserMetadata

    OpenVaultLog.library.debug(
      "Updating user metadata for game \(game.id, privacy: .public)"
    )
    do {
      updatedMetadata = try await api.updateGameUserMetadata(
        metadata,
        for: game.id,
        at: session.serverURL,
        token: authenticationToken()
      )
    } catch RomMAPIError.forbidden {
      OpenVaultLog.library.error(
        "Token lacks user-metadata permission for game \(game.id, privacy: .public)"
      )
      throw LibraryServiceError.userMetadataWritePermissionRequired
    } catch RomMAPIError.notFound {
      OpenVaultLog.library.error(
        "RomM no longer contains game \(game.id, privacy: .public)"
      )
      throw LibraryServiceError.gameNotFound
    } catch {
      OpenVaultLog.library.error(
        "Could not update game \(game.id, privacy: .public): \(error.localizedDescription)"
      )
      throw error
    }

    var updatedGame = game
    updatedGame.userMetadata = updatedMetadata
    try? await cache.saveGameDetails(updatedGame, for: session.serverURL)
    OpenVaultLog.library.notice(
      "Updated user metadata for game \(game.id, privacy: .public)"
    )
    return updatedGame
  }

  func downloadGame(_ game: GameDetails, in session: ServerSession) async throws -> URL {
    let download: RomMDownload

    do {
      download = try await api.downloadGame(
        for: game.id,
        fileName: game.fileName,
        at: session.serverURL,
        token: authenticationToken()
      )
    } catch RomMAPIError.notFound {
      throw LibraryServiceError.gameNotFound
    }

    defer {
      try? FileManager.default.removeItem(at: download.temporaryFileURL)
    }

    do {
      try FileManager.default.createDirectory(
        at: downloadsDirectory,
        withIntermediateDirectories: true
      )

      let fileName = safeFileName(
        download.suggestedFileName,
        fallback: game.fileName,
        gameID: game.id
      )
      let destination = availableDownloadURL(for: fileName)
      try FileManager.default.moveItem(
        at: download.temporaryFileURL,
        to: destination
      )
      return destination
    } catch {
      throw LibraryServiceError.couldNotSaveDownload(reason: error.localizedDescription)
    }
  }

  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String]
  ) async throws -> URL {
    let destination = runtimeCacheURL(for: game, in: session)
    let fileManager = FileManager.default

    if fileManager.fileExists(atPath: destination.path) {
      let values = try? destination.resourceValues(forKeys: [.fileSizeKey])
      if game.fileSizeBytes <= 0 || Int64(values?.fileSize ?? -1) == game.fileSizeBytes {
        try? fileManager.setAttributes(
          [.modificationDate: now()],
          ofItemAtPath: destination.path
        )
        let contentURL = try archiveExtractor.playableContent(
          from: destination,
          supportedFileExtensions: supportedFileExtensions
        )
        try pruneRuntimeCache(preserving: [destination, contentURL])
        return contentURL
      }
      try? fileManager.removeItem(at: destination)
    }

    let download: RomMDownload
    do {
      download = try await api.downloadGame(
        for: game.id,
        fileName: game.fileName,
        at: session.serverURL,
        token: authenticationToken()
      )
    } catch RomMAPIError.notFound {
      throw LibraryServiceError.gameNotFound
    }

    defer {
      try? fileManager.removeItem(at: download.temporaryFileURL)
    }

    do {
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.moveItem(
        at: download.temporaryFileURL,
        to: destination
      )
      let contentURL = try archiveExtractor.playableContent(
        from: destination,
        supportedFileExtensions: supportedFileExtensions
      )
      try pruneRuntimeCache(preserving: [destination, contentURL])
      return contentURL
    } catch let error as GameArchiveError {
      throw error
    } catch {
      throw LibraryServiceError.couldNotCacheGame(reason: error.localizedDescription)
    }
  }

  func artworkRequest(for game: GameSummary, in session: ServerSession) async throws -> URLRequest?
  {
    try await resourceRequest(for: game.coverURL, in: session)
  }

  func resourceRequest(for url: URL?, in session: ServerSession) async throws -> URLRequest? {
    guard let url else {
      return nil
    }

    var request = URLRequest(url: url)
    request.setValue("image/*", forHTTPHeaderField: "Accept")

    if session.serverURL.hasSameOrigin(as: url) {
      let token = try await authenticationToken()
      request.setValue("Bearer \(token.rawValue)", forHTTPHeaderField: "Authorization")
    }

    return request
  }

  private func authenticationToken() async throws -> ClientToken {
    guard let token = try await credentialStore.loadToken() else {
      throw LibraryServiceError.notAuthenticated
    }
    return token
  }

  private func collectionMemberships(
    for collections: [LibraryCollection],
    session: ServerSession,
    token: ClientToken
  ) async throws -> [LibrarySnapshot.CollectionMembership] {
    var memberships: [LibrarySnapshot.CollectionMembership] = []

    for collection in collections {
      var gameIDs: [Int] = []
      var seenGameIDs: Set<Int> = []
      var offset = 0

      while true {
        let page = try await api.games(
          at: session.serverURL,
          token: token,
          matching: .collection(collection.id),
          searchTerm: nil,
          offset: offset,
          limit: Self.synchronizationPageSize
        )
        gameIDs.append(
          contentsOf: page.games.compactMap {
            guard !$0.isBIOS, seenGameIDs.insert($0.id).inserted else {
              return nil
            }
            return $0.id
          }
        )

        guard page.hasMore else {
          break
        }
        guard !page.games.isEmpty else {
          throw LibraryServiceError.incompleteSynchronization
        }
        offset = page.offset + page.games.count
      }

      memberships.append(
        LibrarySnapshot.CollectionMembership(
          collectionID: collection.id,
          gameIDs: gameIDs
        )
      )
    }

    return memberships
  }

  private func safeFileName(_ suggested: String, fallback: String, gameID: Int) -> String {
    for value in [suggested, fallback] {
      let name = URL(fileURLWithPath: value)
        .lastPathComponent
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ":", with: "-")
        .components(separatedBy: .controlCharacters)
        .joined()

      if !name.isEmpty, name != ".", name != ".." {
        return name
      }
    }

    return "RomM Game \(gameID).zip"
  }

  private func availableDownloadURL(for fileName: String) -> URL {
    let initialURL = downloadsDirectory.appending(path: fileName)
    guard FileManager.default.fileExists(atPath: initialURL.path) else {
      return initialURL
    }

    let fileExtension = initialURL.pathExtension
    let stem = initialURL.deletingPathExtension().lastPathComponent
    var suffix = 2

    while true {
      let candidateName =
        fileExtension.isEmpty
        ? "\(stem) \(suffix)"
        : "\(stem) \(suffix).\(fileExtension)"
      let candidateURL = downloadsDirectory.appending(path: candidateName)

      if !FileManager.default.fileExists(atPath: candidateURL.path) {
        return candidateURL
      }
      suffix += 1
    }
  }

  private func runtimeCacheURL(
    for game: GameDetails,
    in session: ServerSession
  ) -> URL {
    let serverDigest = SHA256.hash(
      data: Data(session.serverURL.value.absoluteString.utf8)
    )
    .map { String(format: "%02x", $0) }
    .joined()
    let version =
      nonEmpty(game.sha1Hash)
      ?? nonEmpty(game.md5Hash)
      ?? nonEmpty(game.crcHash)
      ?? "\(game.fileSizeBytes)-\(game.updatedAt)"
    let versionDigest = SHA256.hash(data: Data(version.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    let fileName = safeFileName(
      game.fileName,
      fallback: game.fileName,
      gameID: game.id
    )

    return
      runtimeCacheDirectory
      .appending(path: serverDigest, directoryHint: .isDirectory)
      .appending(path: String(game.id), directoryHint: .isDirectory)
      .appending(path: versionDigest, directoryHint: .isDirectory)
      .appending(path: fileName)
  }

  private func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func pruneRuntimeCache(preserving preservedURLs: Set<URL>) throws {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .fileSizeKey,
      .contentModificationDateKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: runtimeCacheDirectory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return
    }

    var files: [(url: URL, size: Int64, date: Date)] = []
    var totalBytes: Int64 = 0

    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: keys)
      guard values.isRegularFile == true else {
        continue
      }
      let size = Int64(values.fileSize ?? 0)
      files.append(
        (
          url: url,
          size: size,
          date: values.contentModificationDate ?? .distantPast
        )
      )
      totalBytes += size
    }

    for file in files.sorted(by: { $0.date < $1.date })
    where totalBytes > Self.maximumRuntimeCacheBytes && !preservedURLs.contains(file.url) {
      try FileManager.default.removeItem(at: file.url)
      totalBytes -= file.size
    }
  }
}

enum LibraryServiceError: LocalizedError {
  case notAuthenticated
  case gameNotFound
  case incompleteSynchronization
  case couldNotSaveDownload(reason: String)
  case userMetadataWritePermissionRequired
  case playbackCacheUnavailable
  case couldNotCacheGame(reason: String)

  var errorDescription: String? {
    switch self {
    case .notAuthenticated:
      "OpenVault could not find the RomM client token. Reconnect the server and try again."
    case .gameNotFound:
      "This game is no longer available on the connected RomM server."
    case .incompleteSynchronization:
      "RomM returned an incomplete library page. OpenVault kept the previous offline library."
    case .couldNotSaveDownload(let reason):
      "OpenVault downloaded the ROM but could not save it in Downloads: \(reason)"
    case .userMetadataWritePermissionRequired:
      "This client token cannot edit game progress. Reconnect with a token that includes roms.user.write."
    case .playbackCacheUnavailable:
      "This library service cannot prepare games for playback."
    case .couldNotCacheGame(let reason):
      "OpenVault downloaded the ROM but could not add it to the playback cache: \(reason)"
    }
  }
}

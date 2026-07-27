import CryptoKit
import Foundation
import OSLog

protocol LibraryServing: Sendable {
  func cachedSnapshot(in session: ServerSession) async throws -> LibrarySnapshot?
  func cachedGameDetails(
    for gameID: Int,
    in session: ServerSession
  ) async throws -> GameDetails?
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
  func updateFavoriteMembershipLocally(
    collectionID: Int,
    gameIDs: [Int],
    adding: Bool,
    in session: ServerSession
  ) async throws -> LibrarySnapshot
  func synchronizePendingFavorites(
    in session: ServerSession
  ) async throws -> LibrarySnapshot?
  func downloadGame(_ game: GameDetails, in session: ServerSession) async throws -> URL
  func downloadGame(
    _ game: GameDetails,
    in session: ServerSession,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> URL
  func removeDownloadedGame(withID gameID: Int, in session: ServerSession) async throws
  func exportGame(_ game: GameDetails, in session: ServerSession) async throws -> URL
  func deleteGames(
    withIDs gameIDs: [Int],
    deletingFilesFromServer: Bool,
    in session: ServerSession
  ) async throws -> GameDeletionResult
  func downloadedGameIDs(in session: ServerSession) async -> Set<Int>
  func managedDownloadedGameIDs(in session: ServerSession) async -> Set<Int>
  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool
  ) async throws -> URL
  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> URL
  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool,
    allowsRemoteAccess: Bool,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> URL
  func prepareFirmwareForPlay(
    for platformID: Int,
    requirements: [LibretroCoreManifest.Core.Firmware],
    in session: ServerSession
  ) async throws -> URL?
  func prepareFirmwareForPlay(
    for platformID: Int,
    requirements: [LibretroCoreManifest.Core.Firmware],
    in session: ServerSession,
    allowsRemoteAccess: Bool
  ) async throws -> URL?
  func prepareCartridgeSaveForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    emulator: String,
    coreID: String
  ) async throws -> CartridgeSaveSyncConfiguration?
  func prepareCartridgeSaveForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    emulator: String,
    coreID: String,
    allowsRemoteAccess: Bool
  ) async throws -> CartridgeSaveSyncConfiguration?
  func syncCartridgeSaveAfterPlay(
    _ configuration: CartridgeSaveSyncConfiguration
  ) async throws -> CartridgeSaveSyncOutcome
  func resourceRequest(for url: URL?, in session: ServerSession) async throws -> URLRequest?
}

extension LibraryServing {
  func updateFavoriteMembershipLocally(
    collectionID: Int,
    gameIDs: [Int],
    adding: Bool,
    in session: ServerSession
  ) async throws -> LibrarySnapshot {
    throw LibraryServiceError.favoriteUpdateUnavailable
  }

  func synchronizePendingFavorites(
    in session: ServerSession
  ) async throws -> LibrarySnapshot? {
    nil
  }

  func downloadGame(
    _ game: GameDetails,
    in session: ServerSession,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> URL {
    try await downloadGame(game, in: session)
  }

  func cachedGameDetails(
    for gameID: Int,
    in session: ServerSession
  ) async throws -> GameDetails? {
    nil
  }

  func downloadedGameIDs(in session: ServerSession) async -> Set<Int> {
    []
  }

  func managedDownloadedGameIDs(in session: ServerSession) async -> Set<Int> {
    await downloadedGameIDs(in: session)
  }

  func exportGame(_ game: GameDetails, in session: ServerSession) async throws -> URL {
    throw LibraryServiceError.gameExportUnavailable
  }

  func removeDownloadedGame(
    withID gameID: Int,
    in session: ServerSession
  ) async throws {
    throw LibraryServiceError.downloadRemovalUnavailable
  }

  func deleteGames(
    withIDs gameIDs: [Int],
    deletingFilesFromServer: Bool,
    in session: ServerSession
  ) async throws -> GameDeletionResult {
    throw LibraryServiceError.gameDeletionUnavailable
  }

  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool = false
  ) async throws -> URL {
    throw LibraryServiceError.playbackCacheUnavailable
  }

  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool = false,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> URL {
    try await prepareGameForPlay(
      game,
      in: session,
      supportedFileExtensions: supportedFileExtensions,
      loadsArchivesDirectly: loadsArchivesDirectly
    )
  }

  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool = false,
    allowsRemoteAccess: Bool,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> URL {
    try await prepareGameForPlay(
      game,
      in: session,
      supportedFileExtensions: supportedFileExtensions,
      loadsArchivesDirectly: loadsArchivesDirectly,
      onProgress: onProgress
    )
  }

  func prepareCartridgeSaveForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    emulator: String,
    coreID: String
  ) async throws -> CartridgeSaveSyncConfiguration? {
    nil
  }

  func prepareCartridgeSaveForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    emulator: String,
    coreID: String,
    allowsRemoteAccess: Bool
  ) async throws -> CartridgeSaveSyncConfiguration? {
    try await prepareCartridgeSaveForPlay(
      game,
      in: session,
      emulator: emulator,
      coreID: coreID
    )
  }

  func prepareFirmwareForPlay(
    for platformID: Int,
    requirements: [LibretroCoreManifest.Core.Firmware],
    in session: ServerSession
  ) async throws -> URL? {
    guard requirements.isEmpty else {
      throw LibraryServiceError.firmwareCacheUnavailable
    }
    return nil
  }

  func prepareFirmwareForPlay(
    for platformID: Int,
    requirements: [LibretroCoreManifest.Core.Firmware],
    in session: ServerSession,
    allowsRemoteAccess: Bool
  ) async throws -> URL? {
    try await prepareFirmwareForPlay(
      for: platformID,
      requirements: requirements,
      in: session
    )
  }

  func syncCartridgeSaveAfterPlay(
    _ configuration: CartridgeSaveSyncConfiguration
  ) async throws -> CartridgeSaveSyncOutcome {
    .unchanged
  }

}

actor RomMLibraryService: LibraryServing {
  private static let artworkInspectionPageSize = 500
  private static let synchronizationPageSize = 500
  private let api: any RomMClient
  private let credentialStore: any CredentialStoring
  private let cache: any LibraryCaching
  private let downloadsDirectory: URL
  private let managedROMDirectory: URL
  private let runtimeCacheDirectory: URL
  private let firmwareDirectory: URL
  private let saveDirectory: URL
  private let archiveExtractor: any GameArchiveExtracting
  private let purgeArtworkCache: @Sendable () -> Void
  private let now: @Sendable () -> Date

  init(
    api: any RomMClient,
    credentialStore: any CredentialStoring,
    cache: any LibraryCaching = InMemoryLibraryCache(),
    downloadsDirectory: URL? = nil,
    managedROMDirectory: URL? = nil,
    runtimeCacheDirectory: URL? = nil,
    firmwareDirectory: URL? = nil,
    saveDirectory: URL? = nil,
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
    self.managedROMDirectory =
      managedROMDirectory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first?
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "ROMs", directoryHint: .isDirectory)
      ?? URL.temporaryDirectory
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "ROMs", directoryHint: .isDirectory)
    self.runtimeCacheDirectory =
      runtimeCacheDirectory
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "ROMs", directoryHint: .isDirectory)
      ?? URL.temporaryDirectory
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "ROMs", directoryHint: .isDirectory)
    self.firmwareDirectory =
      firmwareDirectory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first?
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "Firmware", directoryHint: .isDirectory)
      ?? URL.temporaryDirectory
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "Firmware", directoryHint: .isDirectory)
    self.saveDirectory =
      saveDirectory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first?
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "Saves", directoryHint: .isDirectory)
      ?? URL.temporaryDirectory
      .appending(path: "OpenVault", directoryHint: .isDirectory)
      .appending(path: "Saves", directoryHint: .isDirectory)
    self.archiveExtractor = archiveExtractor
    self.purgeArtworkCache = purgeArtworkCache
    self.now = now
  }

  func cachedSnapshot(in session: ServerSession) async throws -> LibrarySnapshot? {
    guard let snapshot = try await cache.snapshot(for: session.serverURL) else {
      return nil
    }
    let serverFavoriteGameIDs = RomMFavorites.gameIDs(
      collections: snapshot.collections,
      memberships: snapshot.collectionMemberships
    )
    let localState: LocalFavoriteState
    if let persistedState = try await cache.localFavorites(
      for: session.serverURL
    ) {
      localState = persistedState
    } else {
      localState = LocalFavoriteState(gameIDs: serverFavoriteGameIDs)
      try await cache.replaceLocalFavorites(
        localState,
        for: session.serverURL
      )
    }
    return snapshot.applyingFavoriteGameIDs(localState.gameIDs)
  }

  func cachedGameDetails(
    for gameID: Int,
    in session: ServerSession
  ) async throws -> GameDetails? {
    try await cache.gameDetails(
      for: gameID,
      serverURL: session.serverURL
    )
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
    do {
      _ = try await synchronizePendingFavorites(
        in: session,
        token: token
      )
    } catch {
      OpenVaultLog.library.error(
        "Could not flush pending Favorites before library synchronization: \(error.localizedDescription)"
      )
    }
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
        seenGameIDs.insert($0.id).inserted
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
        gameCount: membershipCounts[$0.id, default: 0],
        isFavorite: $0.isFavorite,
        virtualType: $0.virtualType
      )
    }
    let remoteSnapshot = LibrarySnapshot(
      synchronizedAt: now(),
      systems: systems,
      collections: collections,
      games: allGames,
      collectionMemberships: memberships
    )
    let remoteFavoriteGameIDs = RomMFavorites.gameIDs(
      collections: remoteSnapshot.collections,
      memberships: remoteSnapshot.collectionMemberships
    )
    let localFavoriteState = try await cache.localFavorites(
      for: session.serverURL
    ) ?? LocalFavoriteState(gameIDs: remoteFavoriteGameIDs)
    let reconciledFavoriteState = localFavoriteState.reconciling(
      serverGameIDs: remoteFavoriteGameIDs
    )
    try await cache.replaceLocalFavorites(
      reconciledFavoriteState,
      for: session.serverURL
    )
    let snapshot = remoteSnapshot.applyingFavoriteGameIDs(
      reconciledFavoriteState.gameIDs
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

  func updateFavoriteMembershipLocally(
    collectionID: Int,
    gameIDs: [Int],
    adding: Bool,
    in session: ServerSession
  ) async throws -> LibrarySnapshot {
    let uniqueGameIDs = Array(Set(gameIDs)).sorted()
    guard !uniqueGameIDs.isEmpty else {
      throw LibraryServiceError.favoriteUpdateUnavailable
    }
    guard let snapshot = try await cache.snapshot(for: session.serverURL) else {
      throw LibraryServiceError.favoriteUpdateUnavailable
    }
    guard
      RomMFavorites.regularCollectionID(in: snapshot.collections)
        == collectionID
    else {
      throw LibraryServiceError.favoriteCollectionUnavailable
    }

    let serverFavoriteGameIDs = RomMFavorites.gameIDs(
      collections: snapshot.collections,
      memberships: snapshot.collectionMemberships
    )
    let currentState = try await cache.localFavorites(
      for: session.serverURL
    ) ?? LocalFavoriteState(gameIDs: serverFavoriteGameIDs)
    let updatedState = currentState.setting(
      adding,
      for: Set(uniqueGameIDs)
    )
    try await cache.replaceLocalFavorites(
      updatedState,
      for: session.serverURL
    )
    let updatedSnapshot = snapshot.applyingFavoriteGameIDs(
      updatedState.gameIDs
    )
    try await cache.replaceSnapshot(updatedSnapshot, for: session.serverURL)
    OpenVaultLog.library.notice(
      "Updated local Favorites to \(updatedState.gameIDs.count, privacy: .public) games; \(updatedState.pendingChanges.count, privacy: .public) changes await RomM"
    )
    return updatedSnapshot
  }

  func synchronizePendingFavorites(
    in session: ServerSession
  ) async throws -> LibrarySnapshot? {
    let token = try await authenticationToken()
    return try await synchronizePendingFavorites(
      in: session,
      token: token
    )
  }

  func downloadGame(_ game: GameDetails, in session: ServerSession) async throws -> URL {
    try await downloadGame(
      game,
      in: session,
      onProgress: { _ in }
    )
  }

  func downloadGame(
    _ game: GameDetails,
    in session: ServerSession,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> URL {
    let destination = managedROMURL(for: game, in: session)
    let fileManager = FileManager.default

    if let localURL = try locallyAvailableGameURL(for: game, in: session) {
      return localURL
    }

    if fileManager.fileExists(atPath: destination.path) {
      try? fileManager.removeItem(at: destination)
    }

    let download: RomMDownload

    do {
      download = try await api.downloadGame(
        for: game.id,
        fileName: game.fileName,
        at: session.serverURL,
        token: authenticationToken(),
        onProgress: onProgress
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
      notifyDownloadedGamesDidChange()
      return destination
    } catch {
      throw LibraryServiceError.couldNotCacheGame(reason: error.localizedDescription)
    }
  }

  func removeDownloadedGame(
    withID gameID: Int,
    in session: ServerSession
  ) async throws {
    guard gameID > 0 else {
      throw LibraryServiceError.couldNotRemoveDownload(
        reason: "The game identifier is invalid."
      )
    }

    let fileManager = FileManager.default
    let directories = [
      managedROMServerDirectory(in: session)
        .appending(path: String(gameID), directoryHint: .isDirectory),
      runtimeCacheServerDirectory(in: session)
        .appending(path: String(gameID), directoryHint: .isDirectory),
    ]
    var errors: [String] = []

    for directory in directories where fileManager.fileExists(atPath: directory.path) {
      do {
        try fileManager.removeItem(at: directory)
      } catch {
        errors.append(error.localizedDescription)
      }
    }

    notifyDownloadedGamesDidChange()

    guard errors.isEmpty else {
      throw LibraryServiceError.couldNotRemoveDownload(
        reason: errors.joined(separator: " ")
      )
    }
  }

  func exportGame(_ game: GameDetails, in session: ServerSession) async throws -> URL {
    let localURL =
      cachedGameURL(
        for: game,
        in: managedROMServerDirectory(in: session)
      )
      ?? cachedGameURL(
        for: game,
        in: runtimeCacheServerDirectory(in: session)
      )
    if let localURL {
      return try saveExport(
        from: localURL,
        suggestedFileName: game.fileName,
        fallbackFileName: game.fileName,
        gameID: game.id,
        moveSource: false
      )
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
      try? FileManager.default.removeItem(at: download.temporaryFileURL)
    }

    return try saveExport(
      from: download.temporaryFileURL,
      suggestedFileName: download.suggestedFileName,
      fallbackFileName: game.fileName,
      gameID: game.id,
      moveSource: true
    )
  }

  private func saveExport(
    from source: URL,
    suggestedFileName: String,
    fallbackFileName: String,
    gameID: Int,
    moveSource: Bool
  ) throws -> URL {
    do {
      try FileManager.default.createDirectory(
        at: downloadsDirectory,
        withIntermediateDirectories: true
      )

      let fileName = safeFileName(
        suggestedFileName,
        fallback: fallbackFileName,
        gameID: gameID
      )
      let destination = availableDownloadURL(for: fileName)
      if moveSource {
        try FileManager.default.moveItem(at: source, to: destination)
      } else {
        try FileManager.default.copyItem(at: source, to: destination)
      }
      return destination
    } catch {
      throw LibraryServiceError.couldNotExportGame(reason: error.localizedDescription)
    }
  }

  func downloadedGameIDs(in session: ServerSession) async -> Set<Int> {
    storedGameIDs(in: managedROMServerDirectory(in: session))
      .union(storedGameIDs(in: runtimeCacheServerDirectory(in: session)))
  }

  func managedDownloadedGameIDs(in session: ServerSession) async -> Set<Int> {
    storedGameIDs(in: managedROMServerDirectory(in: session))
  }

  func deleteGames(
    withIDs gameIDs: [Int],
    deletingFilesFromServer: Bool,
    in session: ServerSession
  ) async throws -> GameDeletionResult {
    let uniqueGameIDs = Array(Set(gameIDs)).sorted()
    guard !uniqueGameIDs.isEmpty else {
      return GameDeletionResult(
        successfulItemCount: 0,
        failedItemCount: 0,
        errors: []
      )
    }

    OpenVaultLog.library.notice(
      "Requesting deletion of \(uniqueGameIDs.count, privacy: .public) RomM games"
    )

    do {
      let result = try await api.deleteGames(
        withIDs: uniqueGameIDs,
        deletingFiles: deletingFilesFromServer,
        at: session.serverURL,
        token: authenticationToken()
      )

      if result.completedWithoutErrors,
        result.successfulItemCount == uniqueGameIDs.count
      {
        do {
          try await cache.removeGames(
            withIDs: Set(uniqueGameIDs),
            for: session.serverURL
          )
        } catch {
          OpenVaultLog.library.error(
            "RomM deleted games, but the local cache could not be updated: \(error.localizedDescription)"
          )
        }
      }

      return result
    } catch RomMAPIError.forbidden {
      throw LibraryServiceError.gameDeletionPermissionRequired
    } catch RomMAPIError.notFound {
      throw LibraryServiceError.gameDeletionUnavailable
    }
  }

  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool = false
  ) async throws -> URL {
    try await prepareGameForPlay(
      game,
      in: session,
      supportedFileExtensions: supportedFileExtensions,
      loadsArchivesDirectly: loadsArchivesDirectly,
      onProgress: { _ in }
    )
  }

  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool = false,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> URL {
    try await prepareGameForPlay(
      game,
      in: session,
      supportedFileExtensions: supportedFileExtensions,
      loadsArchivesDirectly: loadsArchivesDirectly,
      allowsRemoteAccess: true,
      onProgress: onProgress
    )
  }

  func prepareGameForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool = false,
    allowsRemoteAccess: Bool,
    onProgress: @escaping @Sendable (RomMDownloadProgress) -> Void
  ) async throws -> URL {
    let managedURL: URL
    if allowsRemoteAccess {
      managedURL = try await downloadGame(
        game,
        in: session,
        onProgress: onProgress
      )
    } else if let localURL = try locallyAvailableGameURL(
      for: game,
      in: session
    ) {
      managedURL = localURL
    } else {
      throw LibraryServiceError.gameNotDownloaded
    }

    do {
      return try playableContent(
        from: managedURL,
        supportedFileExtensions: supportedFileExtensions,
        loadsArchivesDirectly: loadsArchivesDirectly
      )
    } catch let error as GameArchiveError {
      throw error
    } catch {
      throw LibraryServiceError.couldNotCacheGame(reason: error.localizedDescription)
    }
  }

  private func playableContent(
    from sourceURL: URL,
    supportedFileExtensions: [String],
    loadsArchivesDirectly: Bool
  ) throws -> URL {
    if loadsArchivesDirectly,
       supportedFileExtensions.contains(sourceURL.pathExtension.lowercased())
    {
      return sourceURL
    }
    return try archiveExtractor.playableContent(
      from: sourceURL,
      supportedFileExtensions: supportedFileExtensions
    )
  }

  func prepareFirmwareForPlay(
    for platformID: Int,
    requirements: [LibretroCoreManifest.Core.Firmware],
    in session: ServerSession
  ) async throws -> URL? {
    try await prepareFirmwareForPlay(
      for: platformID,
      requirements: requirements,
      in: session,
      allowsRemoteAccess: true
    )
  }

  func prepareFirmwareForPlay(
    for platformID: Int,
    requirements: [LibretroCoreManifest.Core.Firmware],
    in session: ServerSession,
    allowsRemoteAccess: Bool
  ) async throws -> URL? {
    guard !requirements.isEmpty else {
      return nil
    }

    let directory = firmwareDirectory
      .appending(path: serverKey(for: session), directoryHint: .isDirectory)
      .appending(path: String(platformID), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    let missingRequirements = requirements.filter {
      !isValidFirmware(
        at: directory.appending(path: $0.fileName),
        requirement: $0
      )
    }
    guard !missingRequirements.isEmpty else {
      return directory
    }

    guard allowsRemoteAccess else {
      if let required = missingRequirements.first(where: \.required) {
        throw LibraryServiceError.offlineFirmwareUnavailable(
          fileName: required.fileName,
          description: required.description
        )
      }
      return directory
    }

    let token: ClientToken
    let remoteFirmware: [RomMFirmware]
    do {
      token = try await authenticationToken()
      remoteFirmware = try await api.firmware(
        for: platformID,
        at: session.serverURL,
        token: token
      )
    } catch RomMAPIError.forbidden {
      if missingRequirements.contains(where: \.required) {
        throw LibraryServiceError.firmwareReadPermissionRequired
      }
      OpenVaultLog.libretro.info(
        "Firmware access is unavailable; optional firmware will use core fallback"
      )
      return directory
    } catch {
      if let required = missingRequirements.first(where: \.required) {
        throw LibraryServiceError.couldNotPrepareFirmware(
          fileName: required.fileName,
          reason: error.localizedDescription
        )
      }
      OpenVaultLog.libretro.info(
        "RomM is unavailable; using cached firmware or core fallback"
      )
      return directory
    }

    for requirement in missingRequirements {
      guard
        let remote = remoteFirmware.first(where: {
          !$0.isMissingFromFileSystem
            && $0.fileName.caseInsensitiveCompare(requirement.fileName) == .orderedSame
        })
      else {
        if requirement.required {
          throw LibraryServiceError.missingFirmware(
            fileName: requirement.fileName,
            description: requirement.description
          )
        }
        continue
      }

      if let remoteHash = nonEmpty(remote.sha1Hash),
        let acceptedHashes = requirement.sha1,
        !acceptedHashes.isEmpty,
        !acceptedHashes.contains(where: {
          $0.caseInsensitiveCompare(remoteHash) == .orderedSame
        })
      {
        if requirement.required {
          throw LibraryServiceError.invalidFirmware(fileName: requirement.fileName)
        }
        OpenVaultLog.libretro.error(
          "RomM firmware \(requirement.fileName, privacy: .public) has an unexpected hash"
        )
        continue
      }

      let download: RomMDownload
      do {
        download = try await api.downloadFirmware(
          remote,
          at: session.serverURL,
          token: token
        )
      } catch {
        if requirement.required {
          throw LibraryServiceError.couldNotPrepareFirmware(
            fileName: requirement.fileName,
            reason: error.localizedDescription
          )
        }
        OpenVaultLog.libretro.error(
          "Could not cache optional firmware \(requirement.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        continue
      }

      defer {
        try? FileManager.default.removeItem(at: download.temporaryFileURL)
      }

      guard
        isValidFirmware(
          at: download.temporaryFileURL,
          requirement: requirement,
          expectedSize: remote.fileSizeBytes,
          expectedSHA1: remote.sha1Hash
        )
      else {
        if requirement.required {
          throw LibraryServiceError.invalidFirmware(fileName: requirement.fileName)
        }
        OpenVaultLog.libretro.error(
          "Downloaded optional firmware \(requirement.fileName, privacy: .public) failed validation"
        )
        continue
      }

      let destination = directory.appending(path: requirement.fileName)
      do {
        if FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(
          at: download.temporaryFileURL,
          to: destination
        )
      } catch {
        if requirement.required {
          throw LibraryServiceError.couldNotPrepareFirmware(
            fileName: requirement.fileName,
            reason: error.localizedDescription
          )
        }
      }
    }

    if let missing = requirements.first(where: {
      $0.required
        && !isValidFirmware(
          at: directory.appending(path: $0.fileName),
          requirement: $0
        )
    }) {
      throw LibraryServiceError.missingFirmware(
        fileName: missing.fileName,
        description: missing.description
      )
    }

    return directory
  }

  func prepareCartridgeSaveForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    emulator: String,
    coreID: String
  ) async throws -> CartridgeSaveSyncConfiguration? {
    try await prepareCartridgeSaveForPlay(
      game,
      in: session,
      emulator: emulator,
      coreID: coreID,
      allowsRemoteAccess: true
    )
  }

  func prepareCartridgeSaveForPlay(
    _ game: GameDetails,
    in session: ServerSession,
    emulator: String,
    coreID: String,
    allowsRemoteAccess: Bool
  ) async throws -> CartridgeSaveSyncConfiguration? {
    let storage = saveStorage(forCoreID: coreID)
    let localSaveURL = saveURL(
      for: game.id,
      in: session,
      storage: storage
    )
    try FileManager.default.createDirectory(
      at: localSaveURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let configuration = CartridgeSaveSyncConfiguration(
      serverURL: session.serverURL,
      gameID: game.id,
      localSaveURL: localSaveURL,
      uploadFileName: saveFileName(for: game, storage: storage),
      emulator: emulator,
      slot: "autosave",
      storage: storage
    )
    let localHash = saveContentHash(for: configuration)
    let metadata = loadSaveSyncMetadata(for: localSaveURL)

    guard allowsRemoteAccess else {
      OpenVaultLog.libretro.info(
        "Launching game \(game.id, privacy: .public) with its local save while RomM is offline"
      )
      return configuration
    }

    let token: ClientToken
    do {
      token = try await authenticationToken()
    } catch {
      OpenVaultLog.libretro.info(
        "RomM is unavailable; using local cartridge save for game \(game.id, privacy: .public)"
      )
      return configuration
    }

    let launchGame: GameDetails
    do {
      let refreshedGame = try await api.gameDetails(
        for: game.id,
        at: session.serverURL,
        token: token
      )
      launchGame = refreshedGame
      try? await cache.saveGameDetails(
        refreshedGame,
        for: session.serverURL
      )
      OpenVaultLog.libretro.debug(
        "Checked RomM for cartridge saves before launching game \(game.id, privacy: .public)"
      )
    } catch {
      launchGame = game
      OpenVaultLog.libretro.info(
        "Could not refresh cartridge saves for game \(game.id, privacy: .public); using local or cached save information"
      )
    }

    if localHash != nil,
      metadata == nil || metadata?.localContentHash != localHash
    {
      OpenVaultLog.libretro.notice(
        "Preserving unsynchronized local cartridge save for game \(game.id, privacy: .public)"
      )
      return configuration
    }

    let candidates = remoteSaves(
      in: launchGame,
      storage: configuration.effectiveStorage
    )
    guard !candidates.isEmpty else {
      return configuration
    }

    for save in candidates {
      if localHash != nil, let metadata {
        if save.id == metadata.remoteSaveID
          || (
            save.contentHash != nil
              && save.contentHash == metadata.remoteContentHash
          )
        {
          return configuration
        }

        if let remoteUpdatedAt = save.updatedAt,
          let synchronizedUpdatedAt = metadata.remoteUpdatedAt,
          remoteUpdatedAt <= synchronizedUpdatedAt
        {
          return configuration
        }
      }

      do {
        let download = try await api.downloadSave(
          save,
          at: session.serverURL,
          token: token
        )
        defer {
          try? FileManager.default.removeItem(at: download.temporaryFileURL)
        }

        let data = try Data(contentsOf: download.temporaryFileURL)
        guard
          !data.isEmpty,
          save.fileSizeBytes <= 0 || Int64(data.count) == save.fileSizeBytes
        else {
          OpenVaultLog.libretro.error(
            "RomM save \(save.id, privacy: .public) has an unexpected file size"
          )
          continue
        }

        let importedHash: String
        switch configuration.effectiveStorage {
        case .saveRAM:
          try data.write(to: localSaveURL, options: .atomic)
          importedHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        case .directoryBundle:
          try SaveBundleArchive().restore(
            from: download.temporaryFileURL,
            to: localSaveURL
          )
          guard
            let directoryHash = try SaveBundleArchive().contentHash(
              of: localSaveURL
            )
          else {
            throw SaveBundleArchiveError.emptyArchive
          }
          importedHash = directoryHash
        }
        try? writeSaveSyncMetadata(
          CartridgeSaveSyncMetadata(
            localContentHash: importedHash,
            remoteSaveID: save.id,
            remoteContentHash: save.contentHash,
            remoteUpdatedAt: save.updatedAt
          ),
          for: localSaveURL
        )
        OpenVaultLog.libretro.notice(
          "Imported RomM cartridge save \(save.id, privacy: .public) for game \(game.id, privacy: .public)"
        )
        return configuration
      } catch RomMAPIError.notFound {
        OpenVaultLog.libretro.info(
          "RomM save \(save.id, privacy: .public) is missing; trying the previous revision"
        )
      } catch {
        OpenVaultLog.libretro.error(
          "Could not import cartridge save for game \(game.id, privacy: .public): \(error.localizedDescription)"
        )
        return configuration
      }
    }

    return configuration
  }

  func syncCartridgeSaveAfterPlay(
    _ configuration: CartridgeSaveSyncConfiguration
  ) async throws -> CartridgeSaveSyncOutcome {
    guard
      FileManager.default.fileExists(atPath: configuration.localSaveURL.path)
    else {
      return .unchanged
    }

    let localHash: String
    let data: Data
    do {
      switch configuration.effectiveStorage {
      case .saveRAM:
        data = try Data(contentsOf: configuration.localSaveURL)
        guard !data.isEmpty else {
          return .unchanged
        }
        localHash = SHA256.hash(data: data)
          .map { String(format: "%02x", $0) }
          .joined()
      case .directoryBundle:
        let archive = SaveBundleArchive()
        guard
          let hash = try archive.contentHash(
            of: configuration.localSaveURL
          ),
          let bundleData = try archive.data(
            from: configuration.localSaveURL
          )
        else {
          return .unchanged
        }
        localHash = hash
        data = bundleData
      }
    } catch {
      throw LibraryServiceError.couldNotSyncSave(reason: error.localizedDescription)
    }
    let previousMetadata = loadSaveSyncMetadata(
      for: configuration.localSaveURL
    )
    guard previousMetadata?.localContentHash != localHash else {
      return .unchanged
    }

    let token = try await authenticationToken()
    let uploadedSave: GameSaveDataItem
    do {
      uploadedSave = try await api.uploadSave(
        data,
        fileName: configuration.uploadFileName,
        for: configuration.gameID,
        emulator: configuration.emulator,
        slot: configuration.slot,
        at: configuration.serverURL,
        token: token
      )
    } catch RomMAPIError.forbidden {
      throw LibraryServiceError.saveSyncWritePermissionRequired
    } catch {
      throw LibraryServiceError.couldNotSyncSave(reason: error.localizedDescription)
    }

    do {
      try writeSaveSyncMetadata(
        CartridgeSaveSyncMetadata(
          localContentHash: localHash,
          remoteSaveID: uploadedSave.id,
          remoteContentHash: uploadedSave.contentHash,
          remoteUpdatedAt: uploadedSave.updatedAt
        ),
        for: configuration.localSaveURL
      )
    } catch {
      OpenVaultLog.libretro.error(
        "Uploaded game \(configuration.gameID, privacy: .public) save but could not record its local sync baseline: \(error.localizedDescription)"
      )
    }

    if let refreshedDetails = try? await api.gameDetails(
      for: configuration.gameID,
      at: configuration.serverURL,
      token: token
    ) {
      try? await cache.saveGameDetails(
        refreshedDetails,
        for: configuration.serverURL
      )
    }
    OpenVaultLog.libretro.notice(
      "Uploaded cartridge save \(uploadedSave.id, privacy: .public) for game \(configuration.gameID, privacy: .public)"
    )
    return .uploaded
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

  private func synchronizePendingFavorites(
    in session: ServerSession,
    token: ClientToken
  ) async throws -> LibrarySnapshot? {
    guard var snapshot = try await cache.snapshot(
      for: session.serverURL
    ) else {
      return nil
    }
    let serverFavoriteGameIDs = RomMFavorites.gameIDs(
      collections: snapshot.collections,
      memberships: snapshot.collectionMemberships
    )
    var state = try await cache.localFavorites(
      for: session.serverURL
    ) ?? LocalFavoriteState(gameIDs: serverFavoriteGameIDs)
    guard !state.pendingChanges.isEmpty else {
      return snapshot.applyingFavoriteGameIDs(state.gameIDs)
    }
    guard
      let collectionID = RomMFavorites.regularCollectionID(
        in: snapshot.collections
      )
    else {
      throw LibraryServiceError.favoriteCollectionUnavailable
    }

    let batches = [
      (adding: true, changes: state.additions),
      (adding: false, changes: state.removals),
    ]
    for batch in batches where !batch.changes.isEmpty {
      OpenVaultLog.library.debug(
        "\(batch.adding ? "Adding" : "Removing") \(batch.changes.count, privacy: .public) pending Favorites members"
      )

      let updatedCollection: LibraryCollection
      do {
        updatedCollection = try await api.updateCollectionMembership(
          collectionID: collectionID,
          gameIDs: batch.changes.map(\.gameID),
          adding: batch.adding,
          at: session.serverURL,
          token: token
        )
      } catch RomMAPIError.forbidden {
        throw LibraryServiceError.favoriteWritePermissionRequired
      } catch RomMAPIError.notFound {
        throw LibraryServiceError.favoriteCollectionUnavailable
      } catch {
        throw error
      }

      guard let memberGameIDs = updatedCollection.memberGameIDs else {
        throw LibraryServiceError.favoriteUpdateUnavailable
      }
      let latestState = try await cache.localFavorites(
        for: session.serverURL
      ) ?? state
      state = latestState.resolving(
        batch.changes,
        serverGameIDs: Set(memberGameIDs)
      )
      try await cache.replaceLocalFavorites(
        state,
        for: session.serverURL
      )
      snapshot = snapshot.replacingCollectionMembership(
        with: updatedCollection,
        gameIDs: Array(state.gameIDs)
      )
      try await cache.replaceSnapshot(snapshot, for: session.serverURL)
    }

    OpenVaultLog.library.notice(
      "Synchronized local Favorites with RomM; \(state.pendingChanges.count, privacy: .public) changes remain pending"
    )
    return snapshot.applyingFavoriteGameIDs(state.gameIDs)
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
      if let memberGameIDs = collection.memberGameIDs {
        memberships.append(
          LibrarySnapshot.CollectionMembership(
            collectionID: collection.id,
            gameIDs: Array(Set(memberGameIDs)).sorted()
          )
        )
        continue
      }

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
            guard seenGameIDs.insert($0.id).inserted else {
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

  private func managedROMURL(
    for game: GameDetails,
    in session: ServerSession
  ) -> URL {
    storedGameURL(
      for: game,
      in: managedROMServerDirectory(in: session)
    )
  }

  private func locallyAvailableGameURL(
    for game: GameDetails,
    in session: ServerSession
  ) throws -> URL? {
    let fileManager = FileManager.default
    if let cachedURL = cachedGameURL(
      for: game,
      in: managedROMServerDirectory(in: session)
    ) {
      try? fileManager.setAttributes(
        [.modificationDate: now()],
        ofItemAtPath: cachedURL.path
      )
      notifyDownloadedGamesDidChange()
      return cachedURL
    }

    guard let runtimeURL = cachedGameURL(
      for: game,
      in: runtimeCacheServerDirectory(in: session)
    ) else {
      return nil
    }

    let destination = managedROMURL(for: game, in: session)
    do {
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.copyItem(at: runtimeURL, to: destination)
      notifyDownloadedGamesDidChange()
      return destination
    } catch {
      throw LibraryServiceError.couldNotCacheGame(
        reason: error.localizedDescription
      )
    }
  }

  private func saveURL(
    for gameID: Int,
    in session: ServerSession,
    storage: CartridgeSaveSyncConfiguration.Storage
  ) -> URL {
    let gameDirectory = saveDirectory
      .appending(path: serverKey(for: session), directoryHint: .isDirectory)
      .appending(path: String(gameID), directoryHint: .isDirectory)
    switch storage {
    case .saveRAM:
      return gameDirectory.appending(path: "SaveRAM.srm")
    case .directoryBundle:
      return gameDirectory.appending(
        path: "PPSSPP",
        directoryHint: .isDirectory
      )
    }
  }

  private func saveFileName(
    for game: GameDetails,
    storage: CartridgeSaveSyncConfiguration.Storage
  ) -> String {
    let stem = URL(fileURLWithPath: game.fileName)
      .deletingPathExtension()
      .lastPathComponent
    let suffix = switch storage {
    case .saveRAM:
      ".srm"
    case .directoryBundle:
      ".ppsspp.zip"
    }
    return safeFileName(
      "\(stem)\(suffix)",
      fallback: "RomM Game \(game.id)\(suffix)",
      gameID: game.id
    )
  }

  private func saveStorage(
    forCoreID coreID: String
  ) -> CartridgeSaveSyncConfiguration.Storage {
    coreID.lowercased().contains("ppsspp")
      ? .directoryBundle
      : .saveRAM
  }

  private func remoteSaves(
    in game: GameDetails,
    storage: CartridgeSaveSyncConfiguration.Storage
  ) -> [GameSaveDataItem] {
    game.saves
      .filter {
        $0.kind == .save
          && !$0.isMissingFromFileSystem
          && $0.downloadURL != nil
          && (
            storage != .directoryBundle
              || $0.fileExtension.lowercased() == "zip"
          )
      }
      .sorted {
        let leftDate = $0.updatedAt ?? $0.createdAt ?? .distantPast
        let rightDate = $1.updatedAt ?? $1.createdAt ?? .distantPast
        if leftDate == rightDate {
          return $0.id > $1.id
        }
        return leftDate > rightDate
      }
  }

  private func saveContentHash(
    for configuration: CartridgeSaveSyncConfiguration
  ) -> String? {
    switch configuration.effectiveStorage {
    case .saveRAM:
      guard
        let data = try? Data(contentsOf: configuration.localSaveURL),
        !data.isEmpty
      else {
        return nil
      }
      return SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    case .directoryBundle:
      return try? SaveBundleArchive().contentHash(
        of: configuration.localSaveURL
      )
    }
  }

  private func loadSaveSyncMetadata(
    for localSaveURL: URL
  ) -> CartridgeSaveSyncMetadata? {
    guard
      let data = try? Data(contentsOf: saveSyncMetadataURL(for: localSaveURL))
    else {
      return nil
    }
    return try? JSONDecoder().decode(CartridgeSaveSyncMetadata.self, from: data)
  }

  private func writeSaveSyncMetadata(
    _ metadata: CartridgeSaveSyncMetadata,
    for localSaveURL: URL
  ) throws {
    let data = try JSONEncoder().encode(metadata)
    try data.write(
      to: saveSyncMetadataURL(for: localSaveURL),
      options: .atomic
    )
  }

  private func saveSyncMetadataURL(for localSaveURL: URL) -> URL {
    localSaveURL.deletingLastPathComponent().appending(path: "Sync.json")
  }

  private func storedGameURL(
    for game: GameDetails,
    in serverDirectory: URL
  ) -> URL {
    let version = gameContentVersion(for: game)
    let versionDigest = SHA256.hash(data: Data(version.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    let storedFileName =
      game.fileExtension.isEmpty
        && URL(fileURLWithPath: game.fileName).pathExtension.isEmpty
        && !game.files.isEmpty
      ? "\(game.fileName).zip"
      : game.fileName
    let fileName = safeFileName(
      storedFileName,
      fallback: storedFileName,
      gameID: game.id
    )

    return serverDirectory
      .appending(path: String(game.id), directoryHint: .isDirectory)
      .appending(path: versionDigest, directoryHint: .isDirectory)
      .appending(path: fileName)
  }

  private func gameContentVersion(for game: GameDetails) -> String {
    if let sha1Hash = nonEmpty(game.sha1Hash) {
      return "sha1:\(sha1Hash.lowercased())"
    }
    if let md5Hash = nonEmpty(game.md5Hash) {
      return "md5:\(md5Hash.lowercased())"
    }
    if let crcHash = nonEmpty(game.crcHash) {
      return "crc:\(crcHash.lowercased())"
    }

    let files = game.files
      .filter(\.isTopLevel)
      .sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    if !files.isEmpty {
      let fileVersions = files.map { file in
        "\(file.name):\(fileContentVersion(for: file))"
      }
      return "files:\(fileVersions.joined(separator: "|"))"
    }

    // A RomM game record's updatedAt changes for metadata and save activity.
    // Those changes must not invalidate an otherwise identical local ROM.
    return "file:\(game.fileName):size:\(game.fileSizeBytes)"
  }

  private func fileContentVersion(for file: GameFile) -> String {
    if let sha1Hash = nonEmpty(file.sha1Hash) {
      return "sha1:\(sha1Hash.lowercased())"
    }
    if let md5Hash = nonEmpty(file.md5Hash) {
      return "md5:\(md5Hash.lowercased())"
    }
    if let crcHash = nonEmpty(file.crcHash) {
      return "crc:\(crcHash.lowercased())"
    }
    if let chdSHA1Hash = nonEmpty(file.chdSHA1Hash) {
      return "chd-sha1:\(chdSHA1Hash.lowercased())"
    }
    return "size:\(file.sizeBytes):modified:\(file.lastModified)"
  }

  private func hasStrongContentIdentity(_ game: GameDetails) -> Bool {
    if nonEmpty(game.sha1Hash) != nil
      || nonEmpty(game.md5Hash) != nil
      || nonEmpty(game.crcHash) != nil
    {
      return true
    }

    return game.files.contains { file in
      nonEmpty(file.sha1Hash) != nil
        || nonEmpty(file.md5Hash) != nil
        || nonEmpty(file.crcHash) != nil
        || nonEmpty(file.chdSHA1Hash) != nil
    }
  }

  private func cachedGameURL(
    for game: GameDetails,
    in serverDirectory: URL
  ) -> URL? {
    let expectedURL = storedGameURL(for: game, in: serverDirectory)
    if isValidCachedGame(at: expectedURL, expectedSize: game.fileSizeBytes) {
      return expectedURL
    }

    // Before stable content identities were introduced, OpenVault included
    // the volatile RomM record timestamp in this directory name. Recover that
    // complete download instead of fetching hundreds of megabytes again.
    guard !hasStrongContentIdentity(game) else {
      return nil
    }

    let gameDirectory = serverDirectory
      .appending(path: String(game.id), directoryHint: .isDirectory)
    let fileManager = FileManager.default
    guard
      let versionDirectories = try? fileManager.contentsOfDirectory(
        at: gameDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }

    let expectedExtension = expectedURL.pathExtension.lowercased()
    let candidates = versionDirectories.flatMap { versionDirectory -> [URL] in
      guard
        (try? versionDirectory.resourceValues(forKeys: [.isDirectoryKey])
          .isDirectory) == true
      else {
        return []
      }
      return (try? fileManager.contentsOfDirectory(
        at: versionDirectory,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    }
    .filter { candidate in
      guard
        (try? candidate.resourceValues(forKeys: [.isRegularFileKey])
          .isRegularFile) == true
      else {
        return false
      }
      return expectedExtension.isEmpty
        || candidate.pathExtension.lowercased() == expectedExtension
    }
    .filter {
      isValidCachedGame(at: $0, expectedSize: game.fileSizeBytes)
    }
    .sorted {
      let lhsDate = (try? $0.resourceValues(
        forKeys: [.contentModificationDateKey]
      ))?.contentModificationDate ?? .distantPast
      let rhsDate = (try? $1.resourceValues(
        forKeys: [.contentModificationDateKey]
      ))?.contentModificationDate ?? .distantPast
      return lhsDate > rhsDate
    }

    guard let recoveredURL = candidates.first else {
      return nil
    }
    OpenVaultLog.library.notice(
      "Reusing legacy cached ROM for game \(game.id, privacy: .public)"
    )
    return recoveredURL
  }

  private func runtimeCacheServerDirectory(in session: ServerSession) -> URL {
    runtimeCacheDirectory.appending(
      path: serverKey(for: session),
      directoryHint: .isDirectory
    )
  }

  private func managedROMServerDirectory(in session: ServerSession) -> URL {
    managedROMDirectory.appending(
      path: serverKey(for: session),
      directoryHint: .isDirectory
    )
  }

  private func serverKey(for session: ServerSession) -> String {
    SHA256.hash(
      data: Data(session.serverURL.value.absoluteString.utf8)
    )
    .map { String(format: "%02x", $0) }
    .joined()
  }

  private func storedGameIDs(in directory: URL) -> Set<Int> {
    let fileManager = FileManager.default
    guard
      let gameDirectories = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return Set(
      gameDirectories.compactMap { gameDirectory in
        guard
          let gameID = Int(gameDirectory.lastPathComponent),
          containsRegularFile(in: gameDirectory)
        else {
          return nil
        }
        return gameID
      }
    )
  }

  private func isValidCachedGame(
    at url: URL,
    expectedSize: Int64
  ) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return false
    }
    if url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame {
      guard let uncompressedSize = archiveExtractor.uncompressedContentSize(of: url) else {
        return false
      }
      guard expectedSize > 0 else {
        return true
      }

      let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
      if Int64(fileSize ?? -1) == expectedSize {
        return true
      }

      // RomM can add a tiny generated playlist (for example an M3U that points
      // at a downloaded CUE) when it packages a directory-backed game. The
      // archive must still contain every byte RomM reported, but this generated
      // descriptor should not make an otherwise complete cache miss forever.
      let reportedSize = UInt64(expectedSize)
      let maximumGeneratedDescriptorBytes: UInt64 = 1 * 1_024 * 1_024
      return uncompressedSize >= reportedSize
        && uncompressedSize - reportedSize <= maximumGeneratedDescriptorBytes
    }
    guard expectedSize > 0 else {
      return true
    }
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values?.fileSize ?? -1) == expectedSize
  }

  private func isValidFirmware(
    at url: URL,
    requirement: LibretroCoreManifest.Core.Firmware,
    expectedSize: Int64? = nil,
    expectedSHA1: String? = nil
  ) -> Bool {
    guard
      FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url),
      !data.isEmpty
    else {
      return false
    }

    if let expectedSize, expectedSize > 0, Int64(data.count) != expectedSize {
      return false
    }

    if !requirement.sha256.isEmpty {
      let digest = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
      guard requirement.sha256.contains(where: {
        $0.caseInsensitiveCompare(digest) == .orderedSame
      }) else {
        return false
      }
    }

    let acceptedSHA1Hashes = requirement.sha1 ?? []
    if !acceptedSHA1Hashes.isEmpty || nonEmpty(expectedSHA1) != nil {
      let digest = Insecure.SHA1.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()

      if let expectedSHA1 = nonEmpty(expectedSHA1),
        expectedSHA1.caseInsensitiveCompare(digest) != .orderedSame
      {
        return false
      }

      if !acceptedSHA1Hashes.isEmpty {
        guard acceptedSHA1Hashes.contains(where: {
          $0.caseInsensitiveCompare(digest) == .orderedSame
        }) else {
          return false
        }
      }
    }

    return true
  }

  private func containsRegularFile(in directory: URL) -> Bool {
    let fileManager = FileManager.default
    let resourceKeys: Set<URLResourceKey> = [
      .isDirectoryKey,
      .isRegularFileKey,
    ]
    var pendingDirectories = [directory]

    while let currentDirectory = pendingDirectories.popLast() {
      guard
        let children = try? fileManager.contentsOfDirectory(
          at: currentDirectory,
          includingPropertiesForKeys: Array(resourceKeys),
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }

      for child in children {
        guard
          let values = try? child.resourceValues(forKeys: resourceKeys)
        else {
          continue
        }
        if values.isRegularFile == true {
          return true
        }
        if values.isDirectory == true {
          pendingDirectories.append(child)
        }
      }
    }
    return false
  }

  private func notifyDownloadedGamesDidChange() {
    if Thread.isMainThread {
      NotificationCenter.default.post(
        name: .openVaultDownloadedGamesDidChange,
        object: nil
      )
    } else {
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: .openVaultDownloadedGamesDidChange,
          object: nil
        )
      }
    }
  }

  private func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

}

private struct CartridgeSaveSyncMetadata: Codable {
  let localContentHash: String
  let remoteSaveID: Int
  let remoteContentHash: String?
  let remoteUpdatedAt: Date?
}

extension Notification.Name {
  static let openVaultDownloadedGamesDidChange = Notification.Name(
    "org.kennethreitz.OpenVault.downloaded-games-did-change"
  )
}

enum LibraryServiceError: LocalizedError {
  case notAuthenticated
  case gameNotFound
  case gameNotDownloaded
  case incompleteSynchronization
  case couldNotExportGame(reason: String)
  case userMetadataWritePermissionRequired
  case favoriteCollectionUnavailable
  case favoriteWritePermissionRequired
  case favoriteUpdateUnavailable
  case playbackCacheUnavailable
  case firmwareCacheUnavailable
  case firmwareReadPermissionRequired
  case offlineFirmwareUnavailable(fileName: String, description: String)
  case missingFirmware(fileName: String, description: String)
  case invalidFirmware(fileName: String)
  case couldNotPrepareFirmware(fileName: String, reason: String)
  case couldNotCacheGame(reason: String)
  case couldNotRemoveDownload(reason: String)
  case saveSyncWritePermissionRequired
  case couldNotSyncSave(reason: String)
  case gameExportUnavailable
  case downloadRemovalUnavailable
  case gameDeletionPermissionRequired
  case gameDeletionUnavailable

  var errorDescription: String? {
    switch self {
    case .notAuthenticated:
      "OpenVault could not find the RomM client token. Reconnect the server and try again."
    case .gameNotFound:
      "This game is no longer available on the connected RomM server."
    case .gameNotDownloaded:
      "This game is not downloaded on this Mac. Connect to RomM and download it before playing offline."
    case .incompleteSynchronization:
      "RomM returned an incomplete library page. OpenVault kept the previous offline library."
    case .couldNotExportGame(let reason):
      "OpenVault could not export the ROM to Downloads: \(reason)"
    case .userMetadataWritePermissionRequired:
      "This client token cannot edit game progress. Reconnect with a token that includes roms.user.write."
    case .favoriteCollectionUnavailable:
      "RomM did not expose an editable Favorites collection for this account."
    case .favoriteWritePermissionRequired:
      "This client token cannot edit Favorites. Reconnect with a token that includes collections.write."
    case .favoriteUpdateUnavailable:
      "This library service cannot edit RomM collection membership."
    case .playbackCacheUnavailable:
      "This library service cannot prepare games for playback."
    case .firmwareCacheUnavailable:
      "This library service cannot prepare system firmware for playback."
    case .firmwareReadPermissionRequired:
      "This client token cannot download system firmware. Reconnect with a token that includes firmware.read."
    case .offlineFirmwareUnavailable(let fileName, let description):
      "Required firmware \(fileName) (\(description)) is not cached on this Mac. Connect to RomM once to download it."
    case .missingFirmware(let fileName, let description):
      "RomM does not have the required system firmware \(fileName) (\(description)). Upload it to this system in RomM and try again."
    case .invalidFirmware(let fileName):
      "RomM's \(fileName) firmware does not match a version supported by this core."
    case .couldNotPrepareFirmware(let fileName, let reason):
      "OpenVault could not prepare \(fileName) from RomM: \(reason)"
    case .couldNotCacheGame(let reason):
      "OpenVault downloaded the ROM but could not add it to the local library: \(reason)"
    case .couldNotRemoveDownload(let reason):
      "OpenVault could not remove the local ROM: \(reason)"
    case .saveSyncWritePermissionRequired:
      "This client token cannot upload cartridge saves. Reconnect with a token that includes assets.write."
    case .couldNotSyncSave(let reason):
      "OpenVault preserved the local cartridge save but could not sync it to RomM: \(reason)"
    case .gameExportUnavailable:
      "This library service cannot export games."
    case .downloadRemovalUnavailable:
      "This library service cannot remove downloaded games."
    case .gameDeletionPermissionRequired:
      "This client token cannot delete games. Reconnect with a token that includes roms.write."
    case .gameDeletionUnavailable:
      "This RomM server does not expose the supported bulk game-deletion endpoint."
    }
  }
}

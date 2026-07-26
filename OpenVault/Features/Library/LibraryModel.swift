import Foundation
import OSLog
import Observation

enum LibrarySelection: Hashable {
  case allGames
  case downloaded
  case virtualCollections
  case system(Int)
  case collection(LibraryCollection.ID)

  var filter: LibraryFilter {
    switch self {
    case .allGames:
      .allGames
    case .downloaded:
      .allGames
    case .virtualCollections:
      .allGames
    case .system(let id):
      .system(id)
    case .collection(let id):
      .collection(id)
    }
  }
}

@MainActor
@Observable
final class LibraryModel {
  private static let pageSize = 60

  let session: ServerSession
  let service: any LibraryServing

  var selection: LibrarySelection = .allGames
  private(set) var systems: [LibrarySystem] = []
  private(set) var collections: [LibraryCollection] = []
  private(set) var collectionPreviewGames: [LibraryCollection.ID: [GameSummary]] = [:]
  private(set) var downloadedGameIDs: Set<Int> = []
  private(set) var managedDownloadedGameIDs: Set<Int> = []
  private(set) var games: [GameSummary] = []
  private(set) var searchTerm = ""
  private(set) var searchesAllSystems = false
  private(set) var hidesBIOSGames = true
  private(set) var hidesGamesWithoutArtwork = false
  private(set) var systemIDsWithArtwork: Set<Int> = []
  private(set) var systemIDsWithoutArtwork: Set<Int> = []
  private(set) var allGameCount = 0
  private(set) var totalGameCount = 0
  private(set) var isLoading = false
  private(set) var isLoadingMore = false
  private(set) var isCheckingSystemArtwork = false
  private(set) var isSynchronizing = false
  private(set) var isPurgingLocalCache = false
  private(set) var isCachingArtwork = false
  private(set) var isDownloadingGames = false
  private(set) var isRemovingDownloads = false
  private(set) var isExportingGames = false
  private(set) var isDeletingGames = false
  private(set) var synchronizedGameCount = 0
  private(set) var synchronizationTotalGameCount = 0
  private(set) var cachedArtworkCount = 0
  private(set) var artworkCacheTotalCount = 0
  private(set) var artworkCacheFailureCount = 0
  private(set) var lastSuccessfulSync: Date?
  private(set) var isShowingStaleData = false
  private(set) var refreshErrorMessage: String?
  private(set) var errorMessage: String?

  private var hasLoaded = false
  private var requestID = UUID()
  private var synchronizationID = UUID()
  private var artworkInspectionID = UUID()
  private var artworkCachingTask: Task<Void, Never>?
  private var snapshot: LibrarySnapshot?
  private let artworkCache: any ArtworkCaching

  init(
    session: ServerSession,
    service: any LibraryServing,
    artworkCache: any ArtworkCaching = DisabledArtworkCache()
  ) {
    self.session = session
    self.service = service
    self.artworkCache = artworkCache
  }

  var title: String {
    switch selection {
    case .allGames:
      "All Games"
    case .downloaded:
      "Downloaded"
    case .virtualCollections:
      "Virtual Collections"
    case .system(let id):
      systems.first(where: { $0.id == id })?.name ?? "System"
    case .collection(let id):
      collections.first(where: { $0.id == id })?.name ?? "Collection"
    }
  }

  var displayedGames: [GameSummary] {
    let libraryGames =
      hidesBIOSGames
      ? games.filter { !$0.isBIOS }
      : games
    guard hidesGamesWithoutArtwork else {
      return libraryGames
    }
    return libraryGames.filter { $0.coverURL != nil }
  }

  var downloadedGameCount: Int {
    guard let snapshot else {
      return downloadedGameIDs.count
    }
    return snapshot.games.lazy.filter {
      self.downloadedGameIDs.contains($0.id)
        && (!self.hidesBIOSGames || !$0.isBIOS)
    }.count
  }

  /// A complete, read-only source for controller-first library presentations.
  ///
  /// Big Picture mode consumes the persisted RomM snapshot directly so opening
  /// it never changes the sidebar selection, search, or table pagination.
  var bigPictureSource: BigPictureLibrarySource {
    let sourceGames = snapshot?.games ?? games
    let visibleGames =
      hidesBIOSGames
      ? sourceGames.filter { !$0.isBIOS }
      : sourceGames

    return BigPictureLibrarySource(
      synchronizedAt: snapshot?.synchronizedAt ?? lastSuccessfulSync,
      systems: systems,
      collections: collections,
      games: visibleGames,
      collectionMemberships: snapshot?.collectionMemberships ?? [],
      downloadedGameIDs: downloadedGameIDs
    )
  }

  var hasMoreGames: Bool {
    games.count < totalGameCount
  }

  func load() async {
    guard !hasLoaded else {
      return
    }

    do {
      if let cachedSnapshot = try await service.cachedSnapshot(in: session) {
        apply(cachedSnapshot)
        hasLoaded = true
        isShowingStaleData = true
        OpenVaultLog.library.info(
          "Loaded \(cachedSnapshot.games.count, privacy: .public) games from the offline cache"
        )
      }
    } catch is CancellationError {
      return
    } catch {
      refreshErrorMessage = error.localizedDescription
      OpenVaultLog.library.error(
        "Could not load the offline library: \(error.localizedDescription)"
      )
    }

    await reloadDownloadedGames()
    await refresh()
  }

  func refresh() async {
    guard !isSynchronizing else {
      return
    }

    cancelArtworkCaching()
    await reloadDownloadedGames()

    let currentSynchronizationID = UUID()
    synchronizationID = currentSynchronizationID
    requestID = UUID()
    artworkInspectionID = UUID()
    isLoading = games.isEmpty
    isLoadingMore = false
    isCheckingSystemArtwork = false
    isSynchronizing = true
    synchronizedGameCount = 0
    synchronizationTotalGameCount = 0
    refreshErrorMessage = nil
    errorMessage = nil

    do {
      let refreshedSnapshot = try await service.synchronizeLibrary(
        in: session
      ) { [weak self] progress in
        await self?.apply(
          progress,
          synchronizationID: currentSynchronizationID
        )
      }

      guard synchronizationID == currentSynchronizationID else {
        return
      }

      apply(refreshedSnapshot)
      hasLoaded = true
      isLoading = false
      isSynchronizing = false
      isShowingStaleData = false
      refreshErrorMessage = nil
      startArtworkCaching(for: refreshedSnapshot.games)

      if hidesGamesWithoutArtwork {
        await inspectSystemArtwork()
      }
    } catch is CancellationError {
      guard synchronizationID == currentSynchronizationID else {
        return
      }
      isLoading = false
      isSynchronizing = false
      OpenVaultLog.library.debug("Library synchronization was cancelled")
    } catch {
      guard synchronizationID == currentSynchronizationID else {
        return
      }

      isLoading = false
      isSynchronizing = false
      refreshErrorMessage = error.localizedDescription
      OpenVaultLog.library.error(
        "Library synchronization failed: \(error.localizedDescription)"
      )

      if snapshot != nil || !games.isEmpty {
        isShowingStaleData = true
      } else {
        games = []
        totalGameCount = 0
        errorMessage = error.localizedDescription
      }
    }
  }

  func purgeLocalCacheAndResync() async {
    guard !isSynchronizing else {
      return
    }

    cancelArtworkCaching()
    isSynchronizing = true
    isPurgingLocalCache = true
    refreshErrorMessage = nil
    errorMessage = nil
    OpenVaultLog.library.notice("Purging the local library cache")

    do {
      try await service.purgeLocalCache()
    } catch is CancellationError {
      isSynchronizing = false
      isPurgingLocalCache = false
      return
    } catch {
      isSynchronizing = false
      isPurgingLocalCache = false
      refreshErrorMessage = error.localizedDescription
      OpenVaultLog.library.error(
        "Could not purge the local library cache: \(error.localizedDescription)"
      )
      return
    }

    snapshot = nil
    hasLoaded = false
    systems = []
    collections = []
    collectionPreviewGames = [:]
    games = []
    systemIDsWithArtwork = []
    systemIDsWithoutArtwork = []
    allGameCount = 0
    totalGameCount = 0
    lastSuccessfulSync = nil
    isShowingStaleData = false
    isSynchronizing = false
    isPurgingLocalCache = false

    OpenVaultLog.library.notice("Purged the local library cache")
    await refresh()
  }

  private func startArtworkCaching(for games: [GameSummary]) {
    artworkCachingTask?.cancel()

    let totalCount = Set(games.compactMap(\.coverURL)).count
    cachedArtworkCount = 0
    artworkCacheTotalCount = totalCount
    artworkCacheFailureCount = 0
    isCachingArtwork = totalCount > 0

    guard totalCount > 0 else {
      artworkCachingTask = nil
      return
    }

    let artworkCache = self.artworkCache
    let session = self.session
    let service = self.service
    artworkCachingTask = Task { [weak self] in
      await artworkCache.cacheArtwork(
        for: games,
        in: session,
        using: service
      ) { [weak self] progress in
        await self?.apply(progress)
      }

      guard !Task.isCancelled else {
        return
      }
      self?.isCachingArtwork = false
      self?.artworkCachingTask = nil

      if let failureCount = self?.artworkCacheFailureCount,
        failureCount > 0
      {
        OpenVaultLog.library.notice(
          "Artwork caching completed with \(failureCount, privacy: .public) failed requests"
        )
      } else {
        OpenVaultLog.library.notice("Artwork caching completed")
      }
    }
  }

  private func apply(_ progress: ArtworkCacheProgress) {
    cachedArtworkCount = progress.completedCount
    artworkCacheTotalCount = progress.totalCount
    artworkCacheFailureCount = progress.failedCount
  }

  private func cancelArtworkCaching() {
    artworkCachingTask?.cancel()
    artworkCachingTask = nil
    isCachingArtwork = false
    cachedArtworkCount = 0
    artworkCacheTotalCount = 0
    artworkCacheFailureCount = 0
  }

  func reloadGames() async {
    let currentRequestID = UUID()
    requestID = currentRequestID
    isLoading = true
    isLoadingMore = false
    errorMessage = nil

    if selection == .virtualCollections {
      games = []
      totalGameCount = 0
      isLoading = false
      return
    }

    if let snapshot {
      let page = pageFromSnapshot(
        from: snapshot,
        offset: 0,
        limit: snapshot.games.count
      )
      games = page.games
      totalGameCount = page.total
      isLoading = false

      if displayedGames.isEmpty, hasMoreGames {
        await loadMore()
      }
      return
    }

    guard selection != .downloaded else {
      games = []
      totalGameCount = 0
      isLoading = false
      return
    }

    do {
      let page = try await service.games(
        in: session,
        matching: requestFilter,
        searchTerm: normalizedSearchTerm,
        offset: 0,
        limit: Self.pageSize
      )

      guard requestID == currentRequestID else {
        return
      }

      games = page.games
      totalGameCount = page.total
      if selection == .allGames {
        allGameCount = page.total
      }
      isLoading = false

      if displayedGames.isEmpty, hasMoreGames {
        await loadMore()
      }
    } catch {
      guard requestID == currentRequestID else {
        return
      }
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }

  func loadMoreIfNeeded(near game: GameSummary) async {
    let visibleGames = displayedGames
    guard
      !isLoading,
      !isLoadingMore,
      hasMoreGames,
      let index = visibleGames.firstIndex(where: { $0.id == game.id }),
      index
        >= visibleGames.index(
          visibleGames.endIndex,
          offsetBy: -min(8, visibleGames.count)
        )
    else {
      return
    }

    await loadMore()
  }

  func loadMore() async {
    guard !isLoading, !isLoadingMore, hasMoreGames else {
      return
    }

    let currentRequestID = requestID
    isLoadingMore = true
    errorMessage = nil
    let initialVisibleCount = displayedGames.count
    var fetchedPageCount = 0

    do {
      repeat {
        let page: GamePage
        if let snapshot {
          page = pageFromSnapshot(
            from: snapshot,
            offset: games.count,
            limit: Self.pageSize
          )
        } else {
          page = try await service.games(
            in: session,
            matching: requestFilter,
            searchTerm: normalizedSearchTerm,
            offset: games.count,
            limit: Self.pageSize
          )
        }

        guard requestID == currentRequestID else {
          return
        }

        let existingIDs = Set(games.map(\.id))
        games.append(contentsOf: page.games.filter { !existingIDs.contains($0.id) })
        totalGameCount = page.total
        fetchedPageCount += 1
      } while displayedGames.count == initialVisibleCount
        && hasMoreGames
        && fetchedPageCount < 4

      isLoadingMore = false
    } catch {
      guard requestID == currentRequestID else {
        return
      }
      errorMessage = error.localizedDescription
      isLoadingMore = false
    }
  }

  func retry() async {
    if refreshErrorMessage != nil || snapshot == nil {
      await refresh()
    } else if games.isEmpty {
      await reloadGames()
    } else if let lastGame = games.last {
      await loadMoreIfNeeded(near: lastGame)
    }
  }

  func search(for term: String) async {
    let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard searchTerm != normalized else {
      return
    }

    searchTerm = normalized
    if normalized.isEmpty {
      searchesAllSystems = false
    }
    await reloadGames()
  }

  func setSearchesAllSystems(_ enabled: Bool) async {
    let newValue = enabled && !searchTerm.isEmpty
    guard searchesAllSystems != newValue else {
      return
    }

    searchesAllSystems = newValue
    await reloadGames()
  }

  func setHidesGamesWithoutArtwork(_ enabled: Bool) async {
    hidesGamesWithoutArtwork = enabled

    if enabled {
      await inspectSystemArtwork()
    }
  }

  func setHidesBIOSGames(_ enabled: Bool) async {
    guard hidesBIOSGames != enabled else {
      return
    }

    hidesBIOSGames = enabled
    systemIDsWithArtwork = []
    systemIDsWithoutArtwork = []

    if let snapshot {
      apply(snapshot)
    } else if hasLoaded {
      await reloadGames()
    }

    if hidesGamesWithoutArtwork {
      await inspectSystemArtwork()
    }
  }

  func reloadDownloadedGames() async {
    async let downloadedGameIDsRequest = service.downloadedGameIDs(in: session)
    async let managedDownloadedGameIDsRequest = service.managedDownloadedGameIDs(
      in: session
    )
    let (gameIDs, managedGameIDs) = await (
      downloadedGameIDsRequest,
      managedDownloadedGameIDsRequest
    )
    guard
      gameIDs != downloadedGameIDs
        || managedGameIDs != managedDownloadedGameIDs
    else {
      return
    }

    downloadedGameIDs = gameIDs
    managedDownloadedGameIDs = managedGameIDs
    if selection == .downloaded {
      await reloadGames()
    }
  }

  func downloadGames(
    _ gamesToDownload: [GameSummary]
  ) async -> GameDownloadResult {
    var seenGameIDs: Set<Int> = []
    let uniqueGames = gamesToDownload.filter {
      seenGameIDs.insert($0.id).inserted
        && !managedDownloadedGameIDs.contains($0.id)
    }
    guard !uniqueGames.isEmpty, !isDownloadingGames else {
      return GameDownloadResult(
        downloadedGameIDs: [],
        failedItemCount: 0,
        errors: []
      )
    }

    isDownloadingGames = true
    defer { isDownloadingGames = false }

    var downloadedGameIDs: [Int] = []
    var errors: [String] = []

    for game in uniqueGames {
      guard !Task.isCancelled else {
        break
      }

      if game.isMissingFromFileSystem == true {
        errors.append("\(game.name): RomM reports that its ROM file is missing.")
        continue
      }

      do {
        let details = try await transferableDetails(for: game)
        _ = try await service.downloadGame(
          details,
          in: session
        )
        downloadedGameIDs.append(game.id)
      } catch is CancellationError {
        break
      } catch {
        errors.append("\(game.name): \(error.localizedDescription)")
      }
    }

    await reloadDownloadedGames()
    return GameDownloadResult(
      downloadedGameIDs: downloadedGameIDs,
      failedItemCount: errors.count,
      errors: errors
    )
  }

  func removeDownloads(
    _ gamesToRemove: [GameSummary]
  ) async -> GameDownloadRemovalResult {
    var seenGameIDs: Set<Int> = []
    let uniqueGames = gamesToRemove.filter {
      seenGameIDs.insert($0.id).inserted
        && downloadedGameIDs.contains($0.id)
    }
    guard !uniqueGames.isEmpty, !isRemovingDownloads else {
      return GameDownloadRemovalResult(
        removedGameIDs: [],
        failedItemCount: 0,
        errors: []
      )
    }

    isRemovingDownloads = true
    defer { isRemovingDownloads = false }

    var removedGameIDs: [Int] = []
    var errors: [String] = []

    for game in uniqueGames {
      guard !Task.isCancelled else {
        break
      }

      do {
        try await service.removeDownloadedGame(
          withID: game.id,
          in: session
        )
        removedGameIDs.append(game.id)
      } catch is CancellationError {
        break
      } catch {
        errors.append("\(game.name): \(error.localizedDescription)")
      }
    }

    await reloadDownloadedGames()
    return GameDownloadRemovalResult(
      removedGameIDs: removedGameIDs,
      failedItemCount: errors.count,
      errors: errors
    )
  }

  func exportGames(
    _ gamesToExport: [GameSummary]
  ) async -> GameExportResult {
    var seenGameIDs: Set<Int> = []
    let uniqueGames = gamesToExport.filter {
      seenGameIDs.insert($0.id).inserted
    }
    guard !uniqueGames.isEmpty, !isExportingGames else {
      return GameExportResult(
        exportedFileURLs: [],
        failedItemCount: 0,
        errors: []
      )
    }

    isExportingGames = true
    defer { isExportingGames = false }

    var exportedFileURLs: [URL] = []
    var errors: [String] = []

    for game in uniqueGames {
      guard !Task.isCancelled else {
        break
      }

      if game.isMissingFromFileSystem == true,
        !downloadedGameIDs.contains(game.id)
      {
        errors.append("\(game.name): RomM reports that its ROM file is missing.")
        continue
      }

      do {
        let details = try await transferableDetails(for: game)
        let destination = try await service.exportGame(
          details,
          in: session
        )
        exportedFileURLs.append(destination)
      } catch is CancellationError {
        break
      } catch {
        errors.append("\(game.name): \(error.localizedDescription)")
      }
    }

    return GameExportResult(
      exportedFileURLs: exportedFileURLs,
      failedItemCount: errors.count,
      errors: errors
    )
  }

  func deleteGames(
    _ gamesToDelete: [GameSummary],
    deletingFilesFromServer: Bool
  ) async throws -> GameDeletionResult {
    let gameIDs = Set(gamesToDelete.map(\.id))
    guard !gameIDs.isEmpty else {
      return GameDeletionResult(
        successfulItemCount: 0,
        failedItemCount: 0,
        errors: []
      )
    }
    guard !isDeletingGames else {
      throw CancellationError()
    }

    isDeletingGames = true
    defer { isDeletingGames = false }

    let result = try await service.deleteGames(
      withIDs: Array(gameIDs),
      deletingFilesFromServer: deletingFilesFromServer,
      in: session
    )

    if result.completedWithoutErrors,
      result.successfulItemCount == gameIDs.count
    {
      if let snapshot {
        apply(snapshot.removingGames(withIDs: gameIDs))
      } else {
        games.removeAll { gameIDs.contains($0.id) }
        totalGameCount = max(0, totalGameCount - gameIDs.count)
        allGameCount = max(0, allGameCount - gameIDs.count)
      }
    } else if result.successfulItemCount > 0 {
      await refresh()
    }

    return result
  }

  private func inspectSystemArtwork() async {
    guard !isCheckingSystemArtwork else {
      return
    }

    if let snapshot {
      systemIDsWithArtwork = Set(
        snapshot.games.lazy
          .filter {
            (!self.hidesBIOSGames || !$0.isBIOS) && $0.coverURL != nil
          }
          .map(\.systemID)
      )
      systemIDsWithoutArtwork = Set(
        systems.lazy
          .filter { $0.gameCount > 0 }
          .map(\.id)
      ).subtracting(systemIDsWithArtwork)
      return
    }

    systemIDsWithArtwork.formUnion(
      games.lazy
        .filter {
          (!self.hidesBIOSGames || !$0.isBIOS) && $0.coverURL != nil
        }
        .map(\.systemID)
    )

    let systemsToInspect = systems.filter {
      $0.gameCount > 0
        && !systemIDsWithArtwork.contains($0.id)
        && !systemIDsWithoutArtwork.contains($0.id)
    }
    guard !systemsToInspect.isEmpty else {
      return
    }

    let inspectionID = UUID()
    artworkInspectionID = inspectionID
    isCheckingSystemArtwork = true
    let service = service
    let session = session
    var batchStart = 0

    while batchStart < systemsToInspect.count {
      let batchEnd = min(batchStart + 4, systemsToInspect.count)
      let batch = Array(systemsToInspect[batchStart..<batchEnd])

      await withTaskGroup(of: (Int, Bool?).self) { group in
        for system in batch {
          group.addTask {
            let hasArtwork = try? await service.systemHasArtwork(
              system.id,
              in: session
            )
            return (system.id, hasArtwork)
          }
        }

        for await (systemID, hasArtwork) in group {
          guard artworkInspectionID == inspectionID else {
            continue
          }

          switch hasArtwork {
          case true:
            systemIDsWithArtwork.insert(systemID)
          case false:
            systemIDsWithoutArtwork.insert(systemID)
          case nil:
            break
          }
        }
      }

      guard artworkInspectionID == inspectionID else {
        return
      }
      batchStart = batchEnd
    }

    guard artworkInspectionID == inspectionID else {
      return
    }
    isCheckingSystemArtwork = false
  }

  private func transferableDetails(for game: GameSummary) async throws -> GameDetails {
    if let cachedDetails = try await service.cachedGameDetails(
      for: game.id,
      in: session
    ) {
      return cachedDetails
    }
    return try await service.gameDetails(
      for: game.id,
      in: session
    )
  }

  private var requestFilter: LibraryFilter {
    if !searchTerm.isEmpty, searchesAllSystems {
      return .allGames
    }
    return selection.filter
  }

  private var normalizedSearchTerm: String? {
    searchTerm.isEmpty ? nil : searchTerm
  }

  private func pageFromSnapshot(
    from librarySnapshot: LibrarySnapshot,
    offset: Int,
    limit: Int
  ) -> GamePage {
    let visibleGames = gamesVisibleUnderBIOSFilter(
      in: librarySnapshot
    )
    let scopedSnapshot = LibrarySnapshot(
      synchronizedAt: librarySnapshot.synchronizedAt,
      systems: librarySnapshot.systems,
      collections: librarySnapshot.collections,
      games:
        selection == .downloaded
        ? visibleGames.filter { downloadedGameIDs.contains($0.id) }
        : visibleGames,
      collectionMemberships: librarySnapshot.collectionMemberships
    )
    return scopedSnapshot.page(
      matching: selection == .downloaded ? .allGames : requestFilter,
      searchTerm: normalizedSearchTerm,
      offset: offset,
      limit: limit
    )
  }

  private func apply(_ librarySnapshot: LibrarySnapshot) {
    snapshot = librarySnapshot
    let visibleGames = gamesVisibleUnderBIOSFilter(
      in: librarySnapshot
    )
    let visibleGameIDs = Set(visibleGames.map(\.id))
    let systemCounts = Dictionary(
      grouping: visibleGames,
      by: \.systemID
    ).mapValues(\.count)
    let collectionCounts = Dictionary(
      uniqueKeysWithValues: librarySnapshot.collectionMemberships.map {
        membership in
        (
          membership.collectionID,
          membership.gameIDs.count { visibleGameIDs.contains($0) }
        )
      }
    )

    systems = librarySnapshot.systems.map {
      LibrarySystem(
        id: $0.id,
        name: $0.name,
        gameCount: systemCounts[$0.id, default: 0]
      )
    }
    collections = librarySnapshot.collections.map {
      LibraryCollection(
        id: $0.id,
        name: $0.name,
        gameCount: collectionCounts[$0.id, default: 0],
        virtualType: $0.virtualType
      )
    }
    collectionPreviewGames = Self.makeCollectionPreviews(
      from: librarySnapshot,
      visibleGameIDs: visibleGameIDs
    )
    allGameCount = visibleGames.count
    lastSuccessfulSync = librarySnapshot.synchronizedAt
    systemIDsWithArtwork = []
    systemIDsWithoutArtwork = []
    validateSelection()

    if selection == .virtualCollections {
      games = []
      totalGameCount = 0
    } else {
      let page = pageFromSnapshot(
        from: librarySnapshot,
        offset: 0,
        limit: librarySnapshot.games.count
      )
      games = page.games
      totalGameCount = page.total
    }
  }

  private func apply(
    _ progress: LibrarySyncProgress,
    synchronizationID currentSynchronizationID: UUID
  ) {
    guard synchronizationID == currentSynchronizationID else {
      return
    }

    synchronizedGameCount = progress.completedGameCount
    synchronizationTotalGameCount = progress.totalGameCount

    guard snapshot == nil, games.isEmpty else {
      return
    }

    systems = progress.systems
    collections = progress.collections
    allGameCount = progress.totalGameCount
    validateSelection()

    let visibleGames = progress.games.filter {
      !hidesBIOSGames || !$0.isBIOS
    }
    if !visibleGames.isEmpty {
      games = Array(visibleGames.prefix(Self.pageSize))
      totalGameCount = progress.totalGameCount
      isLoading = false
    } else if progress.completedGameCount >= progress.totalGameCount {
      totalGameCount = 0
      isLoading = false
    }
  }

  private func gamesVisibleUnderBIOSFilter(
    in librarySnapshot: LibrarySnapshot
  ) -> [GameSummary] {
    guard hidesBIOSGames else {
      return librarySnapshot.games
    }
    return librarySnapshot.games.filter { !$0.isBIOS }
  }

  private func validateSelection() {
    switch selection {
    case .allGames, .downloaded:
      break
    case .virtualCollections
      where collections.contains(where: {
        if case .virtual = $0.id {
          true
        } else {
          false
        }
      }):
      break
    case .system(let id) where systems.contains(where: { $0.id == id }):
      break
    case .collection(let id) where collections.contains(where: { $0.id == id }):
      break
    case .virtualCollections, .system, .collection:
      selection = .allGames
    }
  }

  private static func makeCollectionPreviews(
    from snapshot: LibrarySnapshot,
    visibleGameIDs: Set<Int>
  ) -> [LibraryCollection.ID: [GameSummary]] {
    let gamesByID = Dictionary(
      uniqueKeysWithValues: snapshot.games.map { ($0.id, $0) }
    )

    return Dictionary(
      uniqueKeysWithValues: snapshot.collectionMemberships.map { membership in
        var gamesWithArtwork: [GameSummary] = []
        var gamesWithoutArtwork: [GameSummary] = []

        for gameID in membership.gameIDs {
          guard
            visibleGameIDs.contains(gameID),
            let game = gamesByID[gameID]
          else {
            continue
          }

          if game.coverURL != nil {
            if gamesWithArtwork.count < 4 {
              gamesWithArtwork.append(game)
            }
          } else if gamesWithoutArtwork.count < 4 {
            gamesWithoutArtwork.append(game)
          }

          if gamesWithArtwork.count == 4 {
            break
          }
        }

        return (
          membership.collectionID,
          Array((gamesWithArtwork + gamesWithoutArtwork).prefix(4))
        )
      }
    )
  }
}

import Foundation
import OSLog
import Observation

enum LibrarySelection: Hashable {
  case allGames
  case system(Int)
  case collection(LibraryCollection.ID)

  var filter: LibraryFilter {
    switch self {
    case .allGames:
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
  private(set) var games: [GameSummary] = []
  private(set) var searchTerm = ""
  private(set) var searchesAllSystems = false
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
  private(set) var synchronizedGameCount = 0
  private(set) var synchronizationTotalGameCount = 0
  private(set) var lastSuccessfulSync: Date?
  private(set) var isShowingStaleData = false
  private(set) var refreshErrorMessage: String?
  private(set) var errorMessage: String?

  private var hasLoaded = false
  private var requestID = UUID()
  private var synchronizationID = UUID()
  private var artworkInspectionID = UUID()
  private var snapshot: LibrarySnapshot?

  init(session: ServerSession, service: any LibraryServing) {
    self.session = session
    self.service = service
  }

  var title: String {
    switch selection {
    case .allGames:
      "All Games"
    case .system(let id):
      systems.first(where: { $0.id == id })?.name ?? "System"
    case .collection(let id):
      collections.first(where: { $0.id == id })?.name ?? "Collection"
    }
  }

  var displayedGames: [GameSummary] {
    let libraryGames = games.filter { !$0.isBIOS }
    guard hidesGamesWithoutArtwork else {
      return libraryGames
    }
    return libraryGames.filter { $0.coverURL != nil }
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

    await refresh()
  }

  func refresh() async {
    guard !isSynchronizing else {
      return
    }

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

  func reloadGames() async {
    let currentRequestID = UUID()
    requestID = currentRequestID
    isLoading = true
    isLoadingMore = false
    errorMessage = nil

    if let snapshot {
      let page = snapshot.page(
        matching: requestFilter,
        searchTerm: normalizedSearchTerm,
        offset: 0,
        limit: Self.pageSize
      )
      games = page.games
      totalGameCount = page.total
      isLoading = false

      if displayedGames.isEmpty, hasMoreGames {
        await loadMore()
      }
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
          page = snapshot.page(
            matching: requestFilter,
            searchTerm: normalizedSearchTerm,
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

  func loadAllGamesForTable() async {
    guard !isLoading, !isLoadingMore, hasMoreGames else {
      return
    }

    if let snapshot {
      let currentRequestID = requestID
      isLoadingMore = true
      await Task.yield()

      let page = snapshot.page(
        matching: requestFilter,
        searchTerm: normalizedSearchTerm,
        offset: 0,
        limit: snapshot.games.count
      )
      guard requestID == currentRequestID, !Task.isCancelled else {
        return
      }

      games = page.games
      totalGameCount = page.total
      isLoadingMore = false
      return
    }

    while hasMoreGames, !Task.isCancelled {
      let previousCount = games.count
      await loadMore()
      guard games.count > previousCount else {
        return
      }
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

  private func inspectSystemArtwork() async {
    guard !isCheckingSystemArtwork else {
      return
    }

    if let snapshot {
      systemIDsWithArtwork = Set(
        snapshot.games.lazy
          .filter { !$0.isBIOS && $0.coverURL != nil }
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
        .filter { !$0.isBIOS && $0.coverURL != nil }
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

  private var requestFilter: LibraryFilter {
    if !searchTerm.isEmpty, searchesAllSystems {
      return .allGames
    }
    return selection.filter
  }

  private var normalizedSearchTerm: String? {
    searchTerm.isEmpty ? nil : searchTerm
  }

  private func apply(_ librarySnapshot: LibrarySnapshot) {
    snapshot = librarySnapshot
    systems = librarySnapshot.systems
    collections = librarySnapshot.collections
    allGameCount = librarySnapshot.games.count
    lastSuccessfulSync = librarySnapshot.synchronizedAt
    systemIDsWithArtwork = []
    systemIDsWithoutArtwork = []
    validateSelection()

    let page = librarySnapshot.page(
      matching: requestFilter,
      searchTerm: normalizedSearchTerm,
      offset: 0,
      limit: Self.pageSize
    )
    games = page.games
    totalGameCount = page.total
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

    let visibleGames = progress.games.filter { !$0.isBIOS }
    if !visibleGames.isEmpty {
      games = Array(visibleGames.prefix(Self.pageSize))
      totalGameCount = progress.totalGameCount
      isLoading = false
    } else if progress.completedGameCount >= progress.totalGameCount {
      totalGameCount = 0
      isLoading = false
    }
  }

  private func validateSelection() {
    switch selection {
    case .allGames:
      break
    case .system(let id) where systems.contains(where: { $0.id == id }):
      break
    case .collection(let id) where collections.contains(where: { $0.id == id }):
      break
    case .system, .collection:
      selection = .allGames
    }
  }
}

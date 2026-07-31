import Foundation

/// A game system exposed by the connected RomM library.
struct LibrarySystem: Codable, Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
  let gameCount: Int
}

/// A regular or smart collection exposed by RomM.
struct LibraryCollection: Codable, Identifiable, Hashable, Sendable {
  enum ID: Codable, Hashable, Sendable {
    case regular(Int)
    case smart(Int)
    /// Retained only so caches written before virtual-collection support was
    /// removed can be decoded and migrated.
    case virtual(String)
  }

  let id: ID
  let name: String
  let gameCount: Int
  /// Whether RomM marks this regular collection as the account's Favorites.
  let isFavorite: Bool?
  /// Legacy virtual collection category retained for cache compatibility.
  let virtualType: String?
  /// Membership supplied inline by RomM, used only while constructing a snapshot.
  let memberGameIDs: [Int]?

  init(
    id: ID,
    name: String,
    gameCount: Int,
    isFavorite: Bool? = nil,
    virtualType: String? = nil,
    memberGameIDs: [Int]? = nil
  ) {
    self.id = id
    self.name = name
    self.gameCount = gameCount
    self.isFavorite = isFavorite
    self.virtualType = virtualType
    self.memberGameIDs = memberGameIDs
  }
}

/// RomM's Favorites collection projected into game-level presentation state.
enum RomMFavorites {
  enum MembershipChange: Equatable, Sendable {
    case add
    case remove
  }

  static func collectionID(
    in collections: [LibraryCollection]
  ) -> LibraryCollection.ID? {
    favoriteCollections(in: collections).first?.id
  }

  static func regularCollectionID(
    in collections: [LibraryCollection]
  ) -> Int? {
    guard
      let collectionID = collectionID(in: collections),
      case .regular(let id) = collectionID
    else {
      return nil
    }
    return id
  }

  /// Removes only when every selected game is already a favorite.
  ///
  /// Adding an already-favorite game is harmless, which makes mixed selections
  /// predictable and lets RomM's collection endpoint perform one atomic edit.
  static func membershipChange(
    for gameIDs: Set<Int>,
    favoriteGameIDs: Set<Int>
  ) -> MembershipChange {
    guard !gameIDs.isEmpty, gameIDs.isSubset(of: favoriteGameIDs) else {
      return .add
    }
    return .remove
  }

  static func gameIDs(
    collections: [LibraryCollection],
    memberships: [LibrarySnapshot.CollectionMembership]
  ) -> Set<Int> {
    let favoriteCollections = favoriteCollections(in: collections)
    let favoriteCollectionIDs = Set(favoriteCollections.map(\.id))
    guard !favoriteCollectionIDs.isEmpty else {
      return []
    }

    var gameIDs = Set(
      favoriteCollections.flatMap { $0.memberGameIDs ?? [] }
    )
    for membership in memberships
    where favoriteCollectionIDs.contains(membership.collectionID) {
      gameIDs.formUnion(membership.gameIDs)
    }
    return gameIDs
  }

  /// Stable-partitions an already sorted list without changing its secondary order.
  static func prioritizing(
    _ games: [GameSummary],
    gameIDs: Set<Int>
  ) -> [GameSummary] {
    guard !gameIDs.isEmpty else {
      return games
    }

    var favorites: [GameSummary] = []
    var remainingGames: [GameSummary] = []
    favorites.reserveCapacity(min(gameIDs.count, games.count))
    remainingGames.reserveCapacity(games.count)

    for game in games {
      if gameIDs.contains(game.id) {
        favorites.append(game)
      } else {
        remainingGames.append(game)
      }
    }
    favorites.append(contentsOf: remainingGames)
    return favorites
  }

  private static func favoriteCollections(
    in collections: [LibraryCollection]
  ) -> [LibraryCollection] {
    let explicitlyFavorite = collections.filter { $0.isFavorite == true }
    guard explicitlyFavorite.isEmpty else {
      return explicitlyFavorite
    }

    // Older cached snapshots predate RomM's explicit `is_favorite` metadata.
    return collections.filter {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        .localizedCaseInsensitiveCompare("Favorites") == .orderedSame
    }
  }
}

/// When games were last played on this Mac.
///
/// RomM records a `last_played` of its own, but only for games played through
/// its web player — RetroVault never reports a play back to the server. Local
/// history is therefore the only record of playing a game here, and it has to
/// survive being offline, so it is kept alongside the cached library rather
/// than derived from RomM.
struct LocalPlayHistory: Codable, Equatable, Sendable {
  /// The most recent play per game. Only the latest matters, so repeated plays
  /// overwrite rather than accumulate.
  private(set) var playedAtByGameID: [Int: Date]

  init(playedAtByGameID: [Int: Date] = [:]) {
    self.playedAtByGameID = playedAtByGameID
  }

  /// Game identifiers ordered most recently played first.
  var gameIDsByRecency: [Int] {
    playedAtByGameID
      .sorted {
        $0.value == $1.value
          ? $0.key < $1.key
          : $0.value > $1.value
      }
      .map(\.key)
  }

  func lastPlayed(gameID: Int) -> Date? {
    playedAtByGameID[gameID]
  }

  mutating func recordPlay(gameID: Int, at date: Date) {
    playedAtByGameID[gameID] = date
  }

  func removingGames(withIDs gameIDs: Set<Int>) -> LocalPlayHistory {
    LocalPlayHistory(
      playedAtByGameID: playedAtByGameID.filter {
        !gameIDs.contains($0.key)
      }
    )
  }

  /// Applies RomM's `last_played` for each game where it is newer than anything
  /// recorded here, so history from the web player is not lost.
  func merging(games: [GameSummary]) -> LocalPlayHistory {
    let standardFormatter = ISO8601DateFormatter()
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [
      .withInternetDateTime,
      .withFractionalSeconds,
    ]

    let serverDates = games.reduce(into: [Int: Date]()) { dates, game in
      guard
        let raw = game.serverLastPlayed,
        let date = fractionalFormatter.date(from: raw)
          ?? standardFormatter.date(from: raw)
      else {
        return
      }
      dates[game.id] = date
    }
    return merging(serverLastPlayedByGameID: serverDates)
  }

  func merging(serverLastPlayedByGameID: [Int: Date]) -> LocalPlayHistory {
    var merged = playedAtByGameID
    for (gameID, serverDate) in serverLastPlayedByGameID {
      if let localDate = merged[gameID], localDate >= serverDate {
        continue
      }
      merged[gameID] = serverDate
    }
    return LocalPlayHistory(playedAtByGameID: merged)
  }
}

/// RetroVault's durable, local-first Favorites state.
///
/// The effective set is immediately available offline. Pending changes form a
/// compact last-write-wins outbox that is reconciled with RomM whenever the
/// server is reachable.
struct LocalFavoriteState: Codable, Equatable, Sendable {
  struct Change: Codable, Equatable, Sendable {
    let gameID: Int
    let isFavorite: Bool
  }

  let gameIDs: Set<Int>
  let pendingChanges: [Change]

  init(
    gameIDs: Set<Int> = [],
    pendingChanges: [Change] = []
  ) {
    self.gameIDs = gameIDs
    self.pendingChanges = Self.normalized(pendingChanges)
  }

  var additions: [Change] {
    pendingChanges.filter(\.isFavorite)
  }

  var removals: [Change] {
    pendingChanges.filter { !$0.isFavorite }
  }

  func setting(
    _ isFavorite: Bool,
    for changedGameIDs: Set<Int>
  ) -> LocalFavoriteState {
    guard !changedGameIDs.isEmpty else {
      return self
    }

    var effectiveGameIDs = gameIDs
    var pendingByGameID = Dictionary(
      uniqueKeysWithValues: pendingChanges.map {
        ($0.gameID, $0.isFavorite)
      }
    )
    for gameID in changedGameIDs {
      if isFavorite {
        effectiveGameIDs.insert(gameID)
      } else {
        effectiveGameIDs.remove(gameID)
      }
      pendingByGameID[gameID] = isFavorite
    }

    return LocalFavoriteState(
      gameIDs: effectiveGameIDs,
      pendingChanges: pendingByGameID.map {
        Change(gameID: $0.key, isFavorite: $0.value)
      }
    )
  }

  func reconciling(serverGameIDs: Set<Int>) -> LocalFavoriteState {
    var effectiveGameIDs = serverGameIDs
    for change in pendingChanges {
      if change.isFavorite {
        effectiveGameIDs.insert(change.gameID)
      } else {
        effectiveGameIDs.remove(change.gameID)
      }
    }
    return LocalFavoriteState(
      gameIDs: effectiveGameIDs,
      pendingChanges: pendingChanges
    )
  }

  func resolving(
    _ attemptedChanges: [Change],
    serverGameIDs: Set<Int>
  ) -> LocalFavoriteState {
    let attemptedByGameID = Dictionary(
      uniqueKeysWithValues: attemptedChanges.map {
        ($0.gameID, $0.isFavorite)
      }
    )
    let remainingChanges = pendingChanges.filter { current in
      attemptedByGameID[current.gameID] != current.isFavorite
    }
    return LocalFavoriteState(
      gameIDs: serverGameIDs,
      pendingChanges: remainingChanges
    ).reconciling(serverGameIDs: serverGameIDs)
  }

  private static func normalized(_ changes: [Change]) -> [Change] {
    let pendingByGameID = changes.reduce(into: [Int: Bool]()) {
      $0[$1.gameID] = $1.isFavorite
    }
    return pendingByGameID
      .map { Change(gameID: $0.key, isFavorite: $0.value) }
      .sorted { $0.gameID < $1.gameID }
  }
}

/// The subset of RomM game metadata needed to render the library grid.
struct GameSummary: Codable, Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
  let systemID: Int
  let systemName: String
  let coverURL: URL?
  let isBIOS: Bool
  let hasSave: Bool?
  let hasState: Bool?
  let userStatus: String?
  let completion: Int?
  let rating: Int?
  let difficulty: Int?
  let genres: [String]?
  let releaseYear: Int?
  let regions: [String]?
  let fileSizeBytes: Int64?
  let isIdentified: Bool?
  let isMissingFromFileSystem: Bool?
  let createdAt: String?
  let updatedAt: String?
  /// RomM's own record of when this game was last played, which only reflects
  /// plays made through its web player.
  let serverLastPlayed: String?
  /// The newest known play on this Mac or in RomM.
  ///
  /// This presentation value is projected from `LocalPlayHistory` when the
  /// library is loaded so list columns can sort without consulting global
  /// mutable state.
  let lastPlayedAt: Date?

  init(
    id: Int,
    name: String,
    systemID: Int,
    systemName: String,
    coverURL: URL?,
    isBIOS: Bool = false,
    hasSave: Bool? = nil,
    hasState: Bool? = nil,
    userStatus: String? = nil,
    completion: Int? = nil,
    rating: Int? = nil,
    difficulty: Int? = nil,
    genres: [String]? = nil,
    releaseYear: Int? = nil,
    regions: [String]? = nil,
    fileSizeBytes: Int64? = nil,
    isIdentified: Bool? = nil,
    isMissingFromFileSystem: Bool? = nil,
    createdAt: String? = nil,
    updatedAt: String? = nil,
    serverLastPlayed: String? = nil,
    lastPlayedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.systemID = systemID
    self.systemName = systemName
    self.coverURL = coverURL
    self.isBIOS = isBIOS
    self.hasSave = hasSave
    self.hasState = hasState
    self.userStatus = userStatus
    self.completion = completion
    self.rating = rating
    self.difficulty = difficulty
    self.genres = genres
    self.releaseYear = releaseYear
    self.regions = regions
    self.fileSizeBytes = fileSizeBytes
    self.isIdentified = isIdentified
    self.isMissingFromFileSystem = isMissingFromFileSystem
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.serverLastPlayed = serverLastPlayed
    self.lastPlayedAt = lastPlayedAt
  }

  func withSaveDataAvailability(
    hasSave: Bool,
    hasState: Bool
  ) -> GameSummary {
    GameSummary(
      id: id,
      name: name,
      systemID: systemID,
      systemName: systemName,
      coverURL: coverURL,
      isBIOS: isBIOS,
      hasSave: hasSave,
      hasState: hasState,
      userStatus: userStatus,
      completion: completion,
      rating: rating,
      difficulty: difficulty,
      genres: genres,
      releaseYear: releaseYear,
      regions: regions,
      fileSizeBytes: fileSizeBytes,
      isIdentified: isIdentified,
      isMissingFromFileSystem: isMissingFromFileSystem,
      createdAt: createdAt,
      updatedAt: updatedAt,
      serverLastPlayed: serverLastPlayed,
      lastPlayedAt: lastPlayedAt
    )
  }

  func withLastPlayedAt(_ date: Date?) -> GameSummary {
    GameSummary(
      id: id,
      name: name,
      systemID: systemID,
      systemName: systemName,
      coverURL: coverURL,
      isBIOS: isBIOS,
      hasSave: hasSave,
      hasState: hasState,
      userStatus: userStatus,
      completion: completion,
      rating: rating,
      difficulty: difficulty,
      genres: genres,
      releaseYear: releaseYear,
      regions: regions,
      fileSizeBytes: fileSizeBytes,
      isIdentified: isIdentified,
      isMissingFromFileSystem: isMissingFromFileSystem,
      createdAt: createdAt,
      updatedAt: updatedAt,
      serverLastPlayed: serverLastPlayed,
      lastPlayedAt: date
    )
  }
}

/// A page of games returned by RomM.
struct GamePage: Equatable, Sendable {
  let games: [GameSummary]
  let total: Int
  let limit: Int
  let offset: Int

  var hasMore: Bool {
    offset + games.count < total
  }
}

/// The order RomM applies before paginating a game query.
enum GamePageOrdering: Sendable {
  /// Alphabetical by name, which is the order a person expects when browsing.
  case name
  /// Ascending by identifier.
  ///
  /// Names repeat constantly across regions and revisions, so ordering by name
  /// leaves tied rows free to land in a different position for every query.
  /// Paginating across concurrent requests needs a unique key, or one page can
  /// repeat a row another page skipped.
  case identifier
}

/// Outcome of a bulk RomM game-deletion request.
struct GameDeletionResult: Equatable, Sendable {
  let successfulItemCount: Int
  let failedItemCount: Int
  let errors: [String]

  var completedWithoutErrors: Bool {
    failedItemCount == 0 && errors.isEmpty
  }
}

/// Outcome of adding one or more RomM games to RetroVault's managed local library.
struct GameDownloadResult: Equatable, Sendable {
  let downloadedGameIDs: [Int]
  let failedItemCount: Int
  let errors: [String]

  var successfulItemCount: Int {
    downloadedGameIDs.count
  }

  var completedWithoutErrors: Bool {
    failedItemCount == 0 && errors.isEmpty
  }
}

/// Result of moving a game to the front of an active managed-download queue.
enum PrioritizedGameDownloadResult: Equatable, Sendable {
  /// No bulk download was active, so normal playback preparation should proceed.
  case noActiveQueue
  /// The game was already local or finished downloading from the active queue.
  case downloaded
  /// The queued download failed before playback could begin.
  case failed(String)
  /// Playback preparation was cancelled while waiting for the queued download.
  case cancelled
}

/// Aggregate progress for an explicit multi-game download operation.
struct LibraryDownloadProgress: Equatable, Sendable {
  var processedGameCount: Int
  var totalGameCount: Int
  var currentGameID: Int?
  var currentGameName: String?
  var currentTransferProgress: RomMDownloadProgress?
  var failedGameCount: Int
  var activeGameCount: Int = 0
  var activeTransferProgress: [Int: RomMDownloadProgress] = [:]

  var currentGameNumber: Int {
    guard currentGameID != nil else {
      return min(processedGameCount, totalGameCount)
    }
    return min(processedGameCount + 1, totalGameCount)
  }

  var fractionCompleted: Double {
    guard totalGameCount > 0 else {
      return 0
    }
    let activeFraction: Double
    if activeTransferProgress.isEmpty {
      activeFraction =
        currentGameID == nil
        ? 0
        : currentTransferProgress?.fractionCompleted ?? 0
    } else {
      activeFraction = activeTransferProgress.values.reduce(0) {
        $0 + ($1.fractionCompleted ?? 0)
      }
    }
    return min(
      max(
        (Double(processedGameCount) + activeFraction)
          / Double(totalGameCount),
        0
      ),
      1
    )
  }
}

/// Outcome of removing one or more locally cached games from RetroVault.
struct GameDownloadRemovalResult: Equatable, Sendable {
  let removedGameIDs: [Int]
  let failedItemCount: Int
  let errors: [String]

  var successfulItemCount: Int {
    removedGameIDs.count
  }

  var completedWithoutErrors: Bool {
    failedItemCount == 0 && errors.isEmpty
  }
}

/// Outcome of exporting one or more games from RetroVault to the user's Downloads folder.
struct GameExportResult: Equatable, Sendable {
  let exportedFileURLs: [URL]
  let failedItemCount: Int
  let errors: [String]

  var successfulItemCount: Int {
    exportedFileURLs.count
  }

  var completedWithoutErrors: Bool {
    failedItemCount == 0 && errors.isEmpty
  }
}

/// A server-side filter for the shared game grid.
enum LibraryFilter: Equatable, Sendable {
  case allGames
  case system(Int)
  case systems(Set<Int>)
  case collection(LibraryCollection.ID)
}

/// A complete, server-authoritative library snapshot persisted for offline use.
struct LibrarySnapshot: Codable, Equatable, Sendable {
  struct CollectionMembership: Codable, Equatable, Sendable {
    let collectionID: LibraryCollection.ID
    let gameIDs: [Int]
  }

  let synchronizedAt: Date
  let systems: [LibrarySystem]
  let collections: [LibraryCollection]
  let games: [GameSummary]
  let collectionMemberships: [CollectionMembership]

  /// Projects the durable local/RomM play history onto rows used by sortable
  /// library presentations.
  func applying(_ playHistory: LocalPlayHistory) -> LibrarySnapshot {
    LibrarySnapshot(
      synchronizedAt: synchronizedAt,
      systems: systems,
      collections: collections,
      games: games.map {
        $0.withLastPlayedAt(playHistory.lastPlayed(gameID: $0.id))
      },
      collectionMemberships: collectionMemberships
    )
  }

  /// Removes legacy virtual collections retained by an older cache.
  ///
  /// RomM can expose thousands of automatic collections with large inline
  /// membership lists. RetroVault no longer synchronizes them, but preserving
  /// this migration keeps an existing offline cache readable while promptly
  /// releasing that data.
  func withoutVirtualCollections() -> LibrarySnapshot {
    let retainedCollections = collections.filter {
      if case .virtual = $0.id {
        return false
      }
      return true
    }
    guard retainedCollections.count != collections.count else {
      return self
    }

    let retainedIDs = Set(retainedCollections.map(\.id))
    return LibrarySnapshot(
      synchronizedAt: synchronizedAt,
      systems: systems,
      collections: retainedCollections,
      games: games,
      collectionMemberships: collectionMemberships.filter {
        retainedIDs.contains($0.collectionID)
      }
    )
  }

  func page(
    matching filter: LibraryFilter,
    searchTerm: String?,
    offset: Int,
    limit: Int
  ) -> GamePage {
    let scopedGames: [GameSummary]

    switch filter {
    case .allGames:
      scopedGames = games
    case .system(let systemID):
      scopedGames = games.filter { $0.systemID == systemID }
    case .systems(let systemIDs):
      scopedGames = games.filter { systemIDs.contains($0.systemID) }
    case .collection(let collectionID):
      let memberIDs = Set(
        collectionMemberships
          .first(where: { $0.collectionID == collectionID })?
          .gameIDs ?? []
      )
      scopedGames = games.filter { memberIDs.contains($0.id) }
    }

    let matchingGames: [GameSummary]
    if let searchTerm {
      let normalized = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
      matchingGames =
        normalized.isEmpty
        ? scopedGames
        : scopedGames.filter {
          $0.name.localizedCaseInsensitiveContains(normalized)
            || $0.systemName.localizedCaseInsensitiveContains(normalized)
        }
    } else {
      matchingGames = scopedGames
    }

    let safeOffset = min(max(offset, 0), matchingGames.count)
    let safeLimit = max(limit, 0)
    let endIndex = min(safeOffset + safeLimit, matchingGames.count)

    return GamePage(
      games: Array(matchingGames[safeOffset..<endIndex]),
      total: matchingGames.count,
      limit: safeLimit,
      offset: safeOffset
    )
  }

  func removingGames(withIDs removedGameIDs: Set<Int>) -> LibrarySnapshot {
    guard !removedGameIDs.isEmpty else {
      return self
    }

    let remainingGames = games.filter {
      !removedGameIDs.contains($0.id)
    }
    let systemCounts = Dictionary(
      grouping: remainingGames,
      by: \.systemID
    ).mapValues(\.count)
    let memberships = collectionMemberships.map { membership in
      CollectionMembership(
        collectionID: membership.collectionID,
        gameIDs: membership.gameIDs.filter {
          !removedGameIDs.contains($0)
        }
      )
    }
    let collectionCounts = Dictionary(
      uniqueKeysWithValues: memberships.map {
        ($0.collectionID, $0.gameIDs.count)
      }
    )

    return LibrarySnapshot(
      synchronizedAt: synchronizedAt,
      systems: systems.map {
        LibrarySystem(
          id: $0.id,
          name: $0.name,
          gameCount: systemCounts[$0.id, default: 0]
        )
      },
      collections: collections.map {
        LibraryCollection(
          id: $0.id,
          name: $0.name,
          gameCount: collectionCounts[$0.id, default: 0],
          isFavorite: $0.isFavorite,
          virtualType: $0.virtualType
        )
      },
      games: remainingGames,
      collectionMemberships: memberships
    )
  }

  func replacingCollectionMembership(
    with updatedCollection: LibraryCollection,
    gameIDs: [Int]
  ) -> LibrarySnapshot {
    let uniqueGameIDs = Array(Set(gameIDs)).sorted()
    let collection = LibraryCollection(
      id: updatedCollection.id,
      name: updatedCollection.name,
      gameCount: uniqueGameIDs.count,
      isFavorite: updatedCollection.isFavorite,
      virtualType: updatedCollection.virtualType
    )

    var updatedCollections = collections
    if let index = updatedCollections.firstIndex(where: {
      $0.id == collection.id
    }) {
      updatedCollections[index] = collection
    } else {
      updatedCollections.append(collection)
    }

    let membership = CollectionMembership(
      collectionID: collection.id,
      gameIDs: uniqueGameIDs
    )
    var updatedMemberships = collectionMemberships
    if let index = updatedMemberships.firstIndex(where: {
      $0.collectionID == collection.id
    }) {
      updatedMemberships[index] = membership
    } else {
      updatedMemberships.append(membership)
    }

    return LibrarySnapshot(
      synchronizedAt: synchronizedAt,
      systems: systems,
      collections: updatedCollections,
      games: games,
      collectionMemberships: updatedMemberships
    )
  }

  func applyingFavoriteGameIDs(
    _ favoriteGameIDs: Set<Int>
  ) -> LibrarySnapshot {
    guard
      let favoriteCollectionID = RomMFavorites.collectionID(
        in: collections
      ),
      let favoriteCollection = collections.first(where: {
        $0.id == favoriteCollectionID
      })
    else {
      return self
    }

    return replacingCollectionMembership(
      with: LibraryCollection(
        id: favoriteCollection.id,
        name: favoriteCollection.name,
        gameCount: favoriteGameIDs.count,
        isFavorite: true,
        virtualType: favoriteCollection.virtualType,
        memberGameIDs: Array(favoriteGameIDs).sorted()
      ),
      gameIDs: Array(favoriteGameIDs)
    )
  }
}

/// Progress emitted while RetroVault downloads a complete RomM metadata snapshot.
struct LibrarySyncProgress: Sendable {
  let systems: [LibrarySystem]
  let collections: [LibraryCollection]
  let games: [GameSummary]
  let completedGameCount: Int
  let totalGameCount: Int
}

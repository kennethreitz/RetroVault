import Foundation

struct BigPictureLibrarySource: Sendable {
  let synchronizedAt: Date?
  let systems: [LibrarySystem]
  let collections: [LibraryCollection]
  let games: [GameSummary]
  let collectionMemberships: [LibrarySnapshot.CollectionMembership]
  let downloadedGameIDs: Set<Int>
  let playHistory: LocalPlayHistory
}

enum BigPictureScope: Hashable, Sendable {
  case all
  case recentlyAdded
  case recentlyPlayed
  case favorites
  case downloaded
  case system(Int)
  /// Downloaded games belonging to one system.
  case downloadedSystem(Int)
  case collection(LibraryCollection.ID)
}

enum BigPictureCatalogPreparation: Equatable, Sendable {
  /// Enough indexing to make the home screen and every destination usable.
  /// Individual destinations sort on demand until the fully prepared catalog
  /// replaces this one.
  case startup
  /// Prepares every system and collection list for immediate navigation.
  case full
}

enum BigPictureHomeLibrarySection: String, CaseIterable, Sendable {
  case downloadedGames
  case recentlyPlayed
  case favoriteGames
  case recentlyAdded
  case allGames

  static let displayOrder: [Self] = [
    .downloadedGames,
    .recentlyPlayed,
    .favoriteGames,
    .recentlyAdded,
    .allGames,
  ]

  var title: String {
    switch self {
    case .downloadedGames:
      "Downloaded Games"
    case .recentlyPlayed:
      "Recently Played"
    case .favoriteGames:
      "Favorite Games"
    case .recentlyAdded:
      "Recently Added"
    case .allGames:
      "All Games"
    }
  }
}

struct BigPictureCatalog: Sendable {
  static let empty = BigPictureCatalog(
    source: BigPictureLibrarySource(
      synchronizedAt: nil,
      systems: [],
      collections: [],
      games: [],
      collectionMemberships: [],
      downloadedGameIDs: [],
      playHistory: LocalPlayHistory()
    ),
    manifest: nil
  )

  let synchronizedAt: Date?
  let systems: [LibrarySystem]
  let collections: [LibraryCollection]
  let allGames: [GameSummary]
  let recentlyAddedGames: [GameSummary]
  let recentlyPlayedGames: [GameSummary]
  let favoriteGames: [GameSummary]
  let downloadedGames: [GameSummary]
  let favoriteGameIDs: Set<Int>
  /// Only the systems with something downloaded, so Downloaded can be browsed
  /// the same way the library itself is.
  let downloadedSystems: [LibrarySystem]

  private let gamesBySystem: [Int: [GameSummary]]
  private let gamesByCollection: [LibraryCollection.ID: [GameSummary]]
  private let downloadedGamesBySystem: [Int: [GameSummary]]
  private let gamesByID: [Int: GameSummary]
  private let gameIDsByCollection: [LibraryCollection.ID: [Int]]
  private let isFullyPrepared: Bool

  init(
    source: BigPictureLibrarySource,
    manifest: LibretroCoreManifest?,
    // Read once here rather than per system inside the filter, and taken as a
    // parameter so a test can state which core set it means instead of
    // inheriting whatever the running machine has switched on.
    includingExperimental: Bool =
      LibretroCorePreferences.enablesExperimentalCores(),
    preparation: BigPictureCatalogPreparation = .full
  ) {
    synchronizedAt = source.synchronizedAt
    isFullyPrepared = preparation == .full

    let supportedSystems = source.systems.filter {
      $0.gameCount > 0
        && (
          (manifest?.supportsSystem(
            named: $0.name,
            includingExperimental: includingExperimental
          ) ?? true)
          || Vita3KInstallation.supports(
            systemName: $0.name,
            includingExperimental: includingExperimental
          )
          || CemuInstallation.supports(systemName: $0.name)
        )
    }
    let supportedSystemIDs = Set(supportedSystems.map(\.id))
    let playableGames =
      manifest == nil
      ? source.games
      : source.games.filter { supportedSystemIDs.contains($0.systemID) }
    let visibleGameIDs = Set(playableGames.map(\.id))
    let supportedCollections = source.collections.filter {
      if case .virtual = $0.id {
        return false
      }
      return true
    }
    let supportedCollectionIDs = Set(supportedCollections.map(\.id))
    let supportedMemberships = source.collectionMemberships.filter {
      supportedCollectionIDs.contains($0.collectionID)
    }
    let favoriteIDs = RomMFavorites.gameIDs(
      collections: supportedCollections,
      memberships: supportedMemberships
    )
    favoriteGameIDs = favoriteIDs

    systems =
      supportedSystems
      .sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    let membershipByCollectionID = Dictionary(
      uniqueKeysWithValues: supportedMemberships.map {
        ($0.collectionID, $0.gameIDs)
      }
    )
    gameIDsByCollection = membershipByCollectionID
    collections = supportedCollections
      .filter { collection in
        membershipByCollectionID[collection.id]?.contains {
          visibleGameIDs.contains($0)
        } == true
      }
      .sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }

    let preparedGamesByID = Dictionary(
      uniqueKeysWithValues: playableGames.map { ($0.id, $0) }
    )
    gamesByID = preparedGamesByID

    let alphabeticalGames: [GameSummary]
    if preparation == .full {
      alphabeticalGames = Self.alphabeticallySorted(playableGames)
      gamesBySystem = Dictionary(
        grouping: alphabeticalGames,
        by: \.systemID
      ).mapValues {
        RomMFavorites.prioritizing($0, gameIDs: favoriteIDs)
      }
      gamesByCollection = Dictionary(
        uniqueKeysWithValues: supportedMemberships.map { membership in
          (
            membership.collectionID,
            membership.gameIDs.compactMap {
              preparedGamesByID[$0]
            }
            .sorted(by: Self.isAlphabeticallyOrdered)
          )
        }
      )
    } else {
      // Grouping is linear and makes every system immediately navigable. The
      // much more expensive global and per-collection sorts happen in the
      // fully prepared catalog that replaces this one in the background.
      alphabeticalGames = playableGames
      gamesBySystem = Dictionary(
        grouping: playableGames,
        by: \.systemID
      )
      gamesByCollection = [:]
    }
    allGames = alphabeticalGames

    let downloaded = alphabeticalGames.filter {
      source.downloadedGameIDs.contains($0.id)
    }
    downloadedGames =
      preparation == .full
      ? downloaded
      : Self.alphabeticallySorted(downloaded)
    downloadedGamesBySystem = Dictionary(
      grouping: downloadedGames,
      by: \.systemID
    ).mapValues {
      RomMFavorites.prioritizing($0, gameIDs: favoriteIDs)
    }
    let downloadedSystemIDs = Set(downloaded.map(\.systemID))
    // Reuse the alphabetical system order rather than sorting again.
    downloadedSystems = systems.filter {
      downloadedSystemIDs.contains($0.id)
    }
    let favorites = alphabeticalGames.filter { favoriteIDs.contains($0.id) }
    favoriteGames =
      preparation == .full
      ? favorites
      : Self.alphabeticallySorted(favorites)
    recentlyAddedGames =
      preparation == .full
      ? Array(Self.sortByDateAdded(alphabeticalGames).prefix(50))
      : Array(Self.sortByCreatedAtString(playableGames).prefix(50))
    recentlyPlayedGames = Array(
      source.playHistory.gameIDsByRecency
        .compactMap { preparedGamesByID[$0] }
        .prefix(50)
    )
  }

  func games(in scope: BigPictureScope) -> [GameSummary] {
    switch scope {
    case .all:
      isFullyPrepared ? allGames : Self.alphabeticallySorted(allGames)
    case .recentlyAdded:
      recentlyAddedGames
    case .recentlyPlayed:
      recentlyPlayedGames
    case .favorites:
      favoriteGames
    case .downloaded:
      downloadedGames
    case .system(let systemID):
      preparedSystemGames(systemID)
    case .downloadedSystem(let systemID):
      preparedDownloadedSystemGames(systemID)
    case .collection(let collectionID):
      preparedCollectionGames(collectionID)
    }
  }

  func downloadedGameCount(inSystem systemID: Int) -> Int {
    downloadedGamesBySystem[systemID]?.count ?? 0
  }

  func title(for scope: BigPictureScope) -> String {
    switch scope {
    case .all:
      BigPictureHomeLibrarySection.allGames.title
    case .recentlyAdded:
      BigPictureHomeLibrarySection.recentlyAdded.title
    case .recentlyPlayed:
      BigPictureHomeLibrarySection.recentlyPlayed.title
    case .favorites:
      BigPictureHomeLibrarySection.favoriteGames.title
    case .downloaded:
      BigPictureHomeLibrarySection.downloadedGames.title
    case .system(let systemID), .downloadedSystem(let systemID):
      systems.first(where: { $0.id == systemID })?.name ?? "Games"
    case .collection(let collectionID):
      collections.first(where: { $0.id == collectionID })?.name ?? "Collection"
    }
  }

  private static func sortByDateAdded(
    _ games: [GameSummary]
  ) -> [GameSummary] {
    let standardFormatter = ISO8601DateFormatter()
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [
      .withInternetDateTime,
      .withFractionalSeconds,
    ]

    let preparedGames = games.map { game in
      (
        game: game,
        date:
          game.createdAt.flatMap {
            fractionalFormatter.date(from: $0)
              ?? standardFormatter.date(from: $0)
          }
      )
    }

    return preparedGames.sorted { lhs, rhs in
      switch (lhs.date, rhs.date) {
      case (let left?, let right?) where left != right:
        return left > right
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        let comparison = lhs.game.name.localizedStandardCompare(rhs.game.name)
        return comparison == .orderedSame
          ? lhs.game.id < rhs.game.id
          : comparison == .orderedAscending
      }
    }
    .map(\.game)
  }

  private func preparedSystemGames(_ systemID: Int) -> [GameSummary] {
    let games = gamesBySystem[systemID] ?? []
    guard !isFullyPrepared else {
      return games
    }
    return RomMFavorites.prioritizing(
      Self.alphabeticallySorted(games),
      gameIDs: favoriteGameIDs
    )
  }

  private func preparedDownloadedSystemGames(
    _ systemID: Int
  ) -> [GameSummary] {
    let games = downloadedGamesBySystem[systemID] ?? []
    guard !isFullyPrepared else {
      return games
    }
    return RomMFavorites.prioritizing(
      Self.alphabeticallySorted(games),
      gameIDs: favoriteGameIDs
    )
  }

  private func preparedCollectionGames(
    _ collectionID: LibraryCollection.ID
  ) -> [GameSummary] {
    if isFullyPrepared {
      return gamesByCollection[collectionID] ?? []
    }
    return Self.alphabeticallySorted(
      gameIDsByCollection[collectionID, default: []].compactMap {
        gamesByID[$0]
      }
    )
  }

  private static func alphabeticallySorted(
    _ games: [GameSummary]
  ) -> [GameSummary] {
    games.sorted(by: isAlphabeticallyOrdered)
  }

  private static func isAlphabeticallyOrdered(
    _ lhs: GameSummary,
    _ rhs: GameSummary
  ) -> Bool {
    let comparison = lhs.name.localizedStandardCompare(rhs.name)
    return comparison == .orderedSame
      ? lhs.id < rhs.id
      : comparison == .orderedAscending
  }

  /// RomM emits UTC ISO-8601 creation timestamps. Their lexical order is
  /// chronological, so the startup catalog can identify the newest games
  /// without parsing thousands of dates. The fully prepared catalog replaces
  /// this result with the tolerant date-parser path.
  private static func sortByCreatedAtString(
    _ games: [GameSummary]
  ) -> [GameSummary] {
    games.sorted { lhs, rhs in
      switch (lhs.createdAt, rhs.createdAt) {
      case (let left?, let right?) where left != right:
        return left > right
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return isAlphabeticallyOrdered(lhs, rhs)
      }
    }
  }
}

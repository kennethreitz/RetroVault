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
  case recentlyAdded
  case recentlyPlayed
  case favorites
  case downloaded
  case system(Int)
  /// Downloaded games belonging to one system.
  case downloadedSystem(Int)
  case collection(LibraryCollection.ID)
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

  init(
    source: BigPictureLibrarySource,
    manifest: LibretroCoreManifest?,
    // Read once here rather than per system inside the filter, and taken as a
    // parameter so a test can state which core set it means instead of
    // inheriting whatever the running machine has switched on.
    includingExperimental: Bool =
      LibretroCorePreferences.enablesExperimentalCores()
  ) {
    synchronizedAt = source.synchronizedAt

    let supportedSystems = source.systems.filter {
      $0.gameCount > 0
        && (
          manifest?.supportsSystem(
            named: $0.name,
            includingExperimental: includingExperimental
          ) ?? true
        )
    }
    let supportedSystemIDs = Set(supportedSystems.map(\.id))
    let playableGames =
      manifest == nil
      ? source.games
      : source.games.filter { supportedSystemIDs.contains($0.systemID) }
    let alphabeticalGames = playableGames.sorted {
      let comparison = $0.name.localizedStandardCompare($1.name)
      return comparison == .orderedSame
        ? $0.id < $1.id
        : comparison == .orderedAscending
    }
    let visibleGameIDs = Set(alphabeticalGames.map(\.id))
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
    collections = supportedCollections
      .filter { collection in
        membershipByCollectionID[collection.id]?.contains {
          visibleGameIDs.contains($0)
        } == true
      }
      .sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    gamesBySystem = Dictionary(
      grouping: alphabeticalGames,
      by: \.systemID
    ).mapValues {
      RomMFavorites.prioritizing($0, gameIDs: favoriteIDs)
    }

    let gamesByID = Dictionary(
      uniqueKeysWithValues: alphabeticalGames.map { ($0.id, $0) }
    )
    gamesByCollection = Dictionary(
      uniqueKeysWithValues: supportedMemberships.map { membership in
        (
          membership.collectionID,
          membership.gameIDs.compactMap { gameID in
            guard visibleGameIDs.contains(gameID) else {
              return nil
            }
            return gamesByID[gameID]
          }
          .sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame
              ? $0.id < $1.id
              : comparison == .orderedAscending
          }
        )
      }
    )
    let downloaded = alphabeticalGames.filter {
      source.downloadedGameIDs.contains($0.id)
    }
    downloadedGames = downloaded
    downloadedGamesBySystem = Dictionary(
      grouping: downloaded,
      by: \.systemID
    ).mapValues {
      RomMFavorites.prioritizing($0, gameIDs: favoriteIDs)
    }
    let downloadedSystemIDs = Set(downloaded.map(\.systemID))
    // Reuse the alphabetical system order rather than sorting again.
    downloadedSystems = systems.filter {
      downloadedSystemIDs.contains($0.id)
    }
    favoriteGames = alphabeticalGames.filter {
      favoriteIDs.contains($0.id)
    }
    recentlyAddedGames = Array(
      Self.sortByDateAdded(alphabeticalGames).prefix(50)
    )
    let playableGamesByID = Dictionary(
      uniqueKeysWithValues: alphabeticalGames.map { ($0.id, $0) }
    )
    recentlyPlayedGames = Array(
      source.playHistory.gameIDsByRecency
        .compactMap { playableGamesByID[$0] }
        .prefix(50)
    )
  }

  func games(in scope: BigPictureScope) -> [GameSummary] {
    switch scope {
    case .recentlyAdded:
      recentlyAddedGames
    case .recentlyPlayed:
      recentlyPlayedGames
    case .favorites:
      favoriteGames
    case .downloaded:
      downloadedGames
    case .system(let systemID):
      gamesBySystem[systemID] ?? []
    case .downloadedSystem(let systemID):
      downloadedGamesBySystem[systemID] ?? []
    case .collection(let collectionID):
      gamesByCollection[collectionID] ?? []
    }
  }

  func downloadedGameCount(inSystem systemID: Int) -> Int {
    downloadedGamesBySystem[systemID]?.count ?? 0
  }

  func title(for scope: BigPictureScope) -> String {
    switch scope {
    case .recentlyAdded:
      "Recently Added"
    case .recentlyPlayed:
      "Recently Played"
    case .favorites:
      "Favorites"
    case .downloaded:
      "Downloaded"
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
}

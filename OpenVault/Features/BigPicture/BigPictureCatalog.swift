import Foundation

struct BigPictureLibrarySource: Sendable {
  let synchronizedAt: Date?
  let systems: [LibrarySystem]
  let collections: [LibraryCollection]
  let games: [GameSummary]
  let collectionMemberships: [LibrarySnapshot.CollectionMembership]
  let downloadedGameIDs: Set<Int>
}

enum BigPictureScope: Hashable, Sendable {
  case recentlyAdded
  case downloaded
  case system(Int)
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
      downloadedGameIDs: []
    ),
    manifest: nil
  )

  let synchronizedAt: Date?
  let systems: [LibrarySystem]
  let collections: [LibraryCollection]
  let recentlyAddedGames: [GameSummary]
  let downloadedGames: [GameSummary]

  private let gamesBySystem: [Int: [GameSummary]]
  private let gamesByCollection: [LibraryCollection.ID: [GameSummary]]

  init(
    source: BigPictureLibrarySource,
    manifest: LibretroCoreManifest?
  ) {
    synchronizedAt = source.synchronizedAt

    let supportedSystems = source.systems.filter {
      $0.gameCount > 0
        && (manifest?.supportsSystem(named: $0.name) ?? true)
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

    systems =
      supportedSystems
      .sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    let membershipByCollectionID = Dictionary(
      uniqueKeysWithValues: source.collectionMemberships.map {
        ($0.collectionID, $0.gameIDs)
      }
    )
    collections = source.collections
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
    )

    let gamesByID = Dictionary(
      uniqueKeysWithValues: alphabeticalGames.map { ($0.id, $0) }
    )
    gamesByCollection = Dictionary(
      uniqueKeysWithValues: source.collectionMemberships.map { membership in
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
    downloadedGames = alphabeticalGames.filter {
      source.downloadedGameIDs.contains($0.id)
    }
    recentlyAddedGames = Array(
      Self.sortByDateAdded(alphabeticalGames).prefix(50)
    )
  }

  func games(in scope: BigPictureScope) -> [GameSummary] {
    switch scope {
    case .recentlyAdded:
      recentlyAddedGames
    case .downloaded:
      downloadedGames
    case .system(let systemID):
      gamesBySystem[systemID] ?? []
    case .collection(let collectionID):
      gamesByCollection[collectionID] ?? []
    }
  }

  func title(for scope: BigPictureScope) -> String {
    switch scope {
    case .recentlyAdded:
      "Recently Added"
    case .downloaded:
      "Downloaded"
    case .system(let systemID):
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

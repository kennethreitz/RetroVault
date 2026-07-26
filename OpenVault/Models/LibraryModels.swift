import Foundation

/// A game system exposed by the connected RomM library.
struct LibrarySystem: Codable, Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
  let gameCount: Int
}

/// A regular, smart, or automatically generated virtual collection exposed by RomM.
struct LibraryCollection: Codable, Identifiable, Hashable, Sendable {
  enum ID: Codable, Hashable, Sendable {
    case regular(Int)
    case smart(Int)
    case virtual(String)
  }

  let id: ID
  let name: String
  let gameCount: Int
  /// Whether RomM marks this regular collection as the account's Favorites.
  let isFavorite: Bool?
  /// RomM's virtual collection category, such as `collection` or `genre`.
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
///
/// Favorites remain server-owned collection metadata. OpenVault derives this set
/// from the synchronized collection membership so it also works from the offline
/// library snapshot.
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
    updatedAt: String? = nil
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
      updatedAt: updatedAt
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

/// Outcome of a bulk RomM game-deletion request.
struct GameDeletionResult: Equatable, Sendable {
  let successfulItemCount: Int
  let failedItemCount: Int
  let errors: [String]

  var completedWithoutErrors: Bool {
    failedItemCount == 0 && errors.isEmpty
  }
}

/// Outcome of adding one or more RomM games to OpenVault's managed local library.
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

/// Aggregate progress for an explicit multi-game download operation.
struct LibraryDownloadProgress: Equatable, Sendable {
  var processedGameCount: Int
  let totalGameCount: Int
  var currentGameID: Int?
  var currentGameName: String?
  var currentTransferProgress: RomMDownloadProgress?
  var failedGameCount: Int

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
    let currentFraction =
      currentGameID == nil
      ? 0
      : currentTransferProgress?.fractionCompleted ?? 0
    return min(
      max(
        (Double(processedGameCount) + currentFraction)
          / Double(totalGameCount),
        0
      ),
      1
    )
  }
}

/// Outcome of removing one or more locally cached games from OpenVault.
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

/// Outcome of exporting one or more games from OpenVault to the user's Downloads folder.
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
}

/// Progress emitted while OpenVault downloads a complete RomM metadata snapshot.
struct LibrarySyncProgress: Sendable {
  let systems: [LibrarySystem]
  let collections: [LibraryCollection]
  let games: [GameSummary]
  let completedGameCount: Int
  let totalGameCount: Int
}

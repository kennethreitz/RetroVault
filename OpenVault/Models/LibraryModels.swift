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
  /// RomM's virtual collection category, such as `collection` or `genre`.
  let virtualType: String?
  /// Membership supplied inline by RomM, used only while constructing a snapshot.
  let memberGameIDs: [Int]?

  init(
    id: ID,
    name: String,
    gameCount: Int,
    virtualType: String? = nil,
    memberGameIDs: [Int]? = nil
  ) {
    self.id = id
    self.name = name
    self.gameCount = gameCount
    self.virtualType = virtualType
    self.memberGameIDs = memberGameIDs
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
          virtualType: $0.virtualType
        )
      },
      games: remainingGames,
      collectionMemberships: memberships
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

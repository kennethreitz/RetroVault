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
  }

  let id: ID
  let name: String
  let gameCount: Int
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
}

/// Progress emitted while OpenVault downloads a complete RomM metadata snapshot.
struct LibrarySyncProgress: Sendable {
  let systems: [LibrarySystem]
  let collections: [LibraryCollection]
  let games: [GameSummary]
  let completedGameCount: Int
  let totalGameCount: Int
}

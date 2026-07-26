import Foundation

/// Complete metadata for a game returned by RomM.
struct GameDetails: Codable, Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
  let systemID: Int
  let systemName: String
  let summary: String?
  let coverURL: URL?
  let screenshotURLs: [URL]
  let alternativeNames: [String]
  let metadata: GameMetadata
  let regions: [String]
  let languages: [String]
  let tags: [String]
  let files: [GameFile]
  let fileName: String
  let fileExtension: String
  let filePath: String
  let fullPath: String
  let fileSizeBytes: Int64
  let revision: String?
  let crcHash: String?
  let md5Hash: String?
  let sha1Hash: String?
  let retroAchievementsHash: String?
  let isIdentified: Bool
  let isMissingFromFileSystem: Bool
  let hasManual: Bool
  let hasSoundtrack: Bool
  let manualURL: URL?
  let videoURL: URL?
  let createdAt: String
  let updatedAt: String
  var userMetadata: GameUserMetadata
  let saves: [GameSaveDataItem]
  let states: [GameSaveDataItem]
  let contentCounts: GameContentCounts
  let providerIdentifiers: [GameProviderIdentifier]

  var gameSummary: GameSummary {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone

    return GameSummary(
      id: id,
      name: name,
      systemID: systemID,
      systemName: systemName,
      coverURL: coverURL,
      hasSave: !saves.isEmpty,
      hasState: !states.isEmpty,
      userStatus: userMetadata.status,
      completion: userMetadata.completion,
      rating: userMetadata.rating,
      difficulty: userMetadata.difficulty,
      genres: metadata.genres,
      releaseYear: metadata.firstReleaseDate.map {
        calendar.component(.year, from: $0)
      },
      regions: regions,
      fileSizeBytes: fileSizeBytes,
      isIdentified: isIdentified,
      isMissingFromFileSystem: isMissingFromFileSystem,
      updatedAt: updatedAt
    )
  }
}

/// Normalized metadata aggregated by RomM from its metadata providers.
struct GameMetadata: Codable, Hashable, Sendable {
  let genres: [String]
  let franchises: [String]
  let collections: [String]
  let companies: [String]
  let gameModes: [String]
  let ageRatings: [String]
  let playerCount: String?
  let firstReleaseDate: Date?
  let averageRating: Double?
}

/// A file belonging to a RomM game.
struct GameFile: Codable, Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
  let path: String
  let fullPath: String
  let sizeBytes: Int64
  let category: String?
  let isTopLevel: Bool
  let createdAt: String
  let updatedAt: String
  let lastModified: String
  let crcHash: String?
  let md5Hash: String?
  let sha1Hash: String?
  let retroAchievementsHash: String?
  let chdSHA1Hash: String?
  let archiveMembers: [GameArchiveMember]
  let trackMetadata: GameTrackMetadata?
}

/// A member contained inside an archived game file.
struct GameArchiveMember: Codable, Identifiable, Hashable, Sendable {
  var id: String {
    "\(name)-\(sizeBytes)-\(crcHash)"
  }

  let name: String
  let sizeBytes: Int64
  let crcHash: String
  let md5Hash: String
  let sha1Hash: String
}

/// Audio metadata attached to a soundtrack file.
struct GameTrackMetadata: Codable, Hashable, Sendable {
  let title: String?
  let artist: String?
  let album: String?
  let year: Int?
  let genre: String?
  let track: Int?
  let disc: Int?
  let durationSeconds: Double?
}

/// Per-user state returned alongside a RomM game.
struct GameUserMetadata: Codable, Hashable, Sendable {
  var status: String?
  let lastPlayed: String?
  var rating: Int
  var difficulty: Int
  var completion: Int
  var isBacklogged: Bool
  var isNowPlaying: Bool
  var isHidden: Bool
}

/// A save file or save state attached to a game for the connected RomM user.
struct GameSaveDataItem: Codable, Identifiable, Hashable, Sendable {
  enum Kind: Codable, Hashable, Sendable {
    case save
    case state
  }

  let id: Int
  let kind: Kind
  let fileName: String
  let fileExtension: String
  let filePath: String
  let fullPath: String
  let downloadURL: URL?
  let fileSizeBytes: Int64
  let isMissingFromFileSystem: Bool
  let createdAt: Date?
  let updatedAt: Date?
  let emulator: String?
  let slot: String?
  let contentHash: String?
  let isPublic: Bool
  let screenshotURL: URL?
}

/// Counts for related content whose full presentation belongs to later features.
struct GameContentCounts: Codable, Hashable, Sendable {
  let siblingGames: Int
  let saves: Int
  let states: Int
  let screenshots: Int
  let collections: Int
  let notes: Int
}

/// An identifier assigned by an external metadata provider.
struct GameProviderIdentifier: Codable, Identifiable, Hashable, Sendable {
  var id: String {
    name
  }

  let name: String
  let value: String
}

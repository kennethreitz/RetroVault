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
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  /// Builds the best offline detail representation available from a synchronized
  /// library row. A later RomM refresh replaces this summary with full metadata.
  static func cachedSummary(_ game: GameSummary) -> GameDetails {
    let releaseDate = game.releaseYear.flatMap { year in
      var components = DateComponents()
      components.calendar = Calendar(identifier: .gregorian)
      components.timeZone = TimeZone(secondsFromGMT: 0)
      components.year = year
      components.month = 1
      components.day = 1
      return components.date
    }

    return GameDetails(
      id: game.id,
      name: game.name,
      systemID: game.systemID,
      systemName: game.systemName,
      summary: nil,
      coverURL: game.coverURL,
      screenshotURLs: [],
      alternativeNames: [],
      metadata: GameMetadata(
        genres: game.genres ?? [],
        franchises: [],
        collections: [],
        companies: [],
        gameModes: [],
        ageRatings: [],
        playerCount: nil,
        firstReleaseDate: releaseDate,
        averageRating: nil
      ),
      regions: game.regions ?? [],
      languages: [],
      tags: [],
      files: [],
      fileName: "",
      fileExtension: "",
      filePath: "",
      fullPath: "",
      fileSizeBytes: game.fileSizeBytes ?? 0,
      revision: nil,
      crcHash: nil,
      md5Hash: nil,
      sha1Hash: nil,
      retroAchievementsHash: nil,
      isIdentified: game.isIdentified ?? false,
      isMissingFromFileSystem: game.isMissingFromFileSystem ?? false,
      hasManual: false,
      hasSoundtrack: false,
      manualURL: nil,
      videoURL: nil,
      createdAt: game.createdAt ?? "",
      updatedAt: game.updatedAt ?? "",
      userMetadata: GameUserMetadata(
        status: game.userStatus,
        lastPlayed: nil,
        rating: game.rating ?? 0,
        difficulty: game.difficulty ?? 0,
        completion: game.completion ?? 0,
        isBacklogged: false,
        isNowPlaying: false,
        isHidden: false
      ),
      saves: [],
      states: [],
      contentCounts: GameContentCounts(
        siblingGames: 0,
        saves: game.hasSave == true ? 1 : 0,
        states: game.hasState == true ? 1 : 0,
        screenshots: 0,
        collections: 0,
        notes: 0
      ),
      providerIdentifiers: []
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

/// Non-secret information carried into a Libretro session so battery-backed
/// save memory can use RetroVault's stable, server-scoped local save file.
struct CartridgeSaveSyncConfiguration: Codable, Hashable, Sendable {
  enum Storage: String, Codable, Hashable, Sendable {
    case saveRAM
    case directoryBundle
  }

  let serverURL: ServerURL
  let gameID: Int
  let localSaveURL: URL
  let uploadFileName: String
  let emulator: String
  let slot: String
  let storage: Storage?
  let remoteSaveUpdatedAt: Date?
  let cemuPortableSaveOrigin: CemuPortableSaveOrigin?

  init(
    serverURL: ServerURL,
    gameID: Int,
    localSaveURL: URL,
    uploadFileName: String,
    emulator: String,
    slot: String,
    storage: Storage?,
    remoteSaveUpdatedAt: Date? = nil,
    cemuPortableSaveOrigin: CemuPortableSaveOrigin? = nil
  ) {
    self.serverURL = serverURL
    self.gameID = gameID
    self.localSaveURL = localSaveURL
    self.uploadFileName = uploadFileName
    self.emulator = emulator
    self.slot = slot
    self.storage = storage
    self.remoteSaveUpdatedAt = remoteSaveUpdatedAt
    self.cemuPortableSaveOrigin = cemuPortableSaveOrigin
  }

  var effectiveStorage: Storage {
    storage ?? .saveRAM
  }

  func withRemoteSaveUpdatedAt(_ updatedAt: Date?) -> Self {
    Self(
      serverURL: serverURL,
      gameID: gameID,
      localSaveURL: localSaveURL,
      uploadFileName: uploadFileName,
      emulator: emulator,
      slot: slot,
      storage: storage,
      remoteSaveUpdatedAt: updatedAt,
      cemuPortableSaveOrigin: cemuPortableSaveOrigin
    )
  }

  func withCemuPortableSaveOrigin(
    _ origin: CemuPortableSaveOrigin?
  ) -> Self {
    Self(
      serverURL: serverURL,
      gameID: gameID,
      localSaveURL: localSaveURL,
      uploadFileName: uploadFileName,
      emulator: emulator,
      slot: slot,
      storage: storage,
      remoteSaveUpdatedAt: remoteSaveUpdatedAt,
      cemuPortableSaveOrigin: origin
    )
  }
}

/// The exact portable Cemu layout imported from a Cannoli-managed RomM save.
///
/// Desktop Cemu edits this title inside its MLC tree. Retaining the original
/// marker lets RetroVault upload the changed save in the representation its
/// originating client already understands.
struct CemuPortableSaveOrigin: Codable, Hashable, Sendable {
  let titleID: String
  let markerData: Data
}

/// Result of reconciling a locally persisted cartridge save with RomM.
enum CartridgeSaveSyncOutcome: Equatable, Sendable {
  case unchanged
  case uploaded
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

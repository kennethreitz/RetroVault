import Foundation

/// A save persisted by RetroVault for one game on the connected server.
///
/// This is a local inventory record. RomM remains the source of truth for
/// remote revisions, while the content hash tells the UI whether the local
/// save has changed since the last successful reconciliation.
struct LocalSaveRecord: Identifiable, Hashable, Sendable {
  var id: Int { gameID }

  let gameID: Int
  let storage: CartridgeSaveSyncConfiguration.Storage
  let sizeBytes: Int64
  let modifiedAt: Date?
  let lastSynchronizedAt: Date?
  let needsUpload: Bool
  let failureMessage: String?
}

enum SaveCenterStatus: Hashable, Sendable {
  case synchronized
  case uploadPending
  case remoteOnly
  case failed(String)

  var title: String {
    switch self {
    case .synchronized:
      "SYNCED"
    case .uploadPending:
      "UPLOAD NEEDED"
    case .remoteOnly:
      "ON ROMM"
    case .failed:
      "RETRY"
    }
  }

  var systemImage: String {
    switch self {
    case .synchronized:
      "checkmark.circle.fill"
    case .uploadPending:
      "arrow.up.circle.fill"
    case .remoteOnly:
      "icloud.and.arrow.down"
    case .failed:
      "exclamationmark.triangle.fill"
    }
  }
}

/// Controller-facing projection of local and RomM save availability.
struct SaveCenterItem: Identifiable, Hashable, Sendable {
  var id: Int { game.id }

  let game: GameSummary
  let localRecord: LocalSaveRecord?
  let status: SaveCenterStatus

  var detail: String {
    var components = [status.title]
    if let localRecord, localRecord.sizeBytes > 0 {
      components.append(
        ByteCountFormatter.string(
          fromByteCount: localRecord.sizeBytes,
          countStyle: .file
        )
      )
    }
    return components.joined(separator: " · ")
  }
}

enum SaveCenterCatalog {
  static func items(
    games: [GameSummary],
    localRecords: [LocalSaveRecord],
    failures: [Int: String] = [:]
  ) -> [SaveCenterItem] {
    let gamesByID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
    let localRecordsByGameID = Dictionary(
      uniqueKeysWithValues: localRecords.map { ($0.gameID, $0) }
    )
    let gameIDs = Set(localRecordsByGameID.keys).union(
      games.lazy.filter { $0.hasSave == true }.map(\.id)
    )

    return gameIDs.compactMap { gameID in
      guard let game = gamesByID[gameID] else {
        return nil
      }
      let localRecord = localRecordsByGameID[gameID]
      let status: SaveCenterStatus
      if let failure = failures[gameID] ?? localRecord?.failureMessage {
        status = .failed(failure)
      } else if let localRecord {
        status = localRecord.needsUpload ? .uploadPending : .synchronized
      } else {
        status = .remoteOnly
      }
      return SaveCenterItem(
        game: game,
        localRecord: localRecord,
        status: status
      )
    }
    .sorted(by: isOrderedBefore)
  }

  private static func isOrderedBefore(
    _ lhs: SaveCenterItem,
    _ rhs: SaveCenterItem
  ) -> Bool {
    let leftPriority = priority(of: lhs.status)
    let rightPriority = priority(of: rhs.status)
    if leftPriority != rightPriority {
      return leftPriority < rightPriority
    }
    let comparison = lhs.game.name.localizedStandardCompare(rhs.game.name)
    return comparison == .orderedSame
      ? lhs.game.id < rhs.game.id
      : comparison == .orderedAscending
  }

  private static func priority(of status: SaveCenterStatus) -> Int {
    switch status {
    case .synchronized:
      0
    case .failed:
      1
    case .uploadPending:
      2
    case .remoteOnly:
      3
    }
  }
}

enum SaveCenterSyncResult: Equatable, Sendable {
  case synchronized
  case unchanged
  case failed(String)
}

enum SaveCenterError: LocalizedError {
  case gameUnavailable
  case unsupportedSystem(String)
  case saveUnavailable

  var errorDescription: String? {
    switch self {
    case .gameUnavailable:
      "This game is no longer available in the local library."
    case .unsupportedSystem(let systemName):
      "RetroVault does not have a bundled core for \(systemName)."
    case .saveUnavailable:
      "RetroVault could not determine how this game's save should be synchronized."
    }
  }
}

import Foundation
import Testing

@testable import RetroVault

@Suite("Save Center")
struct SaveCenterTests {
  @Test("Combines RomM availability with local synchronization state")
  func buildsSaveInventory() throws {
    let games = [
      game(id: 1, name: "Synced", hasSave: true),
      game(id: 2, name: "Pending", hasSave: true),
      game(id: 3, name: "Remote", hasSave: true),
      game(id: 4, name: "No Save", hasSave: false),
    ]
    let records = [
      LocalSaveRecord(
        gameID: 1,
        storage: .saveRAM,
        sizeBytes: 32_768,
        modifiedAt: Date(timeIntervalSince1970: 100),
        lastSynchronizedAt: Date(timeIntervalSince1970: 100),
        needsUpload: false,
        failureMessage: nil
      ),
      LocalSaveRecord(
        gameID: 2,
        storage: .saveRAM,
        sizeBytes: 8_192,
        modifiedAt: Date(timeIntervalSince1970: 200),
        lastSynchronizedAt: Date(timeIntervalSince1970: 100),
        needsUpload: true,
        failureMessage: nil
      ),
    ]

    let items = SaveCenterCatalog.items(games: games, localRecords: records)

    #expect(items.map(\.id) == [1, 2, 3])
    #expect(items[0].status == .synchronized)
    #expect(items[1].status == .uploadPending)
    #expect(items[2].status == .remoteOnly)
  }

  @Test("Prioritizes retryable failures")
  func prioritizesFailures() throws {
    let games = [
      game(id: 1, name: "Alpha", hasSave: true),
      game(id: 2, name: "Beta", hasSave: true),
    ]
    let records = games.map {
      LocalSaveRecord(
        gameID: $0.id,
        storage: .saveRAM,
        sizeBytes: 1_024,
        modifiedAt: nil,
        lastSynchronizedAt: nil,
        needsUpload: true,
        failureMessage: $0.id == 2 ? "RomM is offline" : nil
      )
    }

    let items = SaveCenterCatalog.items(games: games, localRecords: records)

    #expect(items.map(\.id) == [2, 1])
    #expect(items[0].status == .failed("RomM is offline"))
  }

  private func game(
    id: Int,
    name: String,
    hasSave: Bool
  ) -> GameSummary {
    GameSummary(
      id: id,
      name: name,
      systemID: 1,
      systemName: "Game Boy",
      coverURL: nil,
      hasSave: hasSave
    )
  }
}

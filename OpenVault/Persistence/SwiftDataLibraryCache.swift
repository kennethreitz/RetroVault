import Foundation
import SwiftData

@Model
private final class CachedLibrarySnapshotRecord {
    @Attribute(.unique) var serverKey: String
    var synchronizedAt: Date
    @Attribute(.externalStorage) var payload: Data

    init(serverKey: String, synchronizedAt: Date, payload: Data) {
        self.serverKey = serverKey
        self.synchronizedAt = synchronizedAt
        self.payload = payload
    }
}

@Model
private final class CachedGameDetailsRecord {
    @Attribute(.unique) var cacheKey: String
    var serverKey: String
    var gameID: Int
    var updatedAt: Date
    @Attribute(.externalStorage) var payload: Data

    init(
        cacheKey: String,
        serverKey: String,
        gameID: Int,
        updatedAt: Date,
        payload: Data
    ) {
        self.cacheKey = cacheKey
        self.serverKey = serverKey
        self.gameID = gameID
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

@Model
private final class LocalFavoriteStateRecord {
    @Attribute(.unique) var serverKey: String
    var updatedAt: Date
    @Attribute(.externalStorage) var payload: Data

    init(serverKey: String, updatedAt: Date, payload: Data) {
        self.serverKey = serverKey
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

/// SwiftData implementation of the offline RomM metadata cache.
actor SwiftDataLibraryCache: LibraryCaching {
    private let isStoredInMemoryOnly: Bool
    private var container: ModelContainer?

    init(isStoredInMemoryOnly: Bool = false) {
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
    }

    func snapshot(for serverURL: ServerURL) throws -> LibrarySnapshot? {
        let context = try modelContext()
        let serverKey = key(for: serverURL)
        var descriptor = FetchDescriptor<CachedLibrarySnapshotRecord>(
            predicate: #Predicate { $0.serverKey == serverKey }
        )
        descriptor.fetchLimit = 1

        guard let record = try context.fetch(descriptor).first else {
            return nil
        }

        do {
            return try JSONDecoder().decode(LibrarySnapshot.self, from: record.payload)
        } catch {
            context.delete(record)
            try context.save()
            return nil
        }
    }

    func replaceSnapshot(_ snapshot: LibrarySnapshot, for serverURL: ServerURL) throws {
        let context = try modelContext()
        let serverKey = key(for: serverURL)
        let payload = try JSONEncoder().encode(snapshot)
        var descriptor = FetchDescriptor<CachedLibrarySnapshotRecord>(
            predicate: #Predicate { $0.serverKey == serverKey }
        )
        descriptor.fetchLimit = 1

        if let record = try context.fetch(descriptor).first {
            record.synchronizedAt = snapshot.synchronizedAt
            record.payload = payload
        } else {
            context.insert(
                CachedLibrarySnapshotRecord(
                    serverKey: serverKey,
                    synchronizedAt: snapshot.synchronizedAt,
                    payload: payload
                )
            )
        }

        let validGameIDs = Set(snapshot.games.map(\.id))
        let detailsDescriptor = FetchDescriptor<CachedGameDetailsRecord>(
            predicate: #Predicate { $0.serverKey == serverKey }
        )
        for record in try context.fetch(detailsDescriptor)
        where !validGameIDs.contains(record.gameID) {
            context.delete(record)
        }

        try context.save()
    }

    func gameDetails(for gameID: Int, serverURL: ServerURL) throws -> GameDetails? {
        let context = try modelContext()
        let cacheKey = detailsKey(for: gameID, serverURL: serverURL)
        var descriptor = FetchDescriptor<CachedGameDetailsRecord>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        descriptor.fetchLimit = 1

        guard let record = try context.fetch(descriptor).first else {
            return nil
        }

        do {
            return try JSONDecoder().decode(GameDetails.self, from: record.payload)
        } catch {
            context.delete(record)
            try context.save()
            return nil
        }
    }

    func saveGameDetails(_ details: GameDetails, for serverURL: ServerURL) throws {
        let context = try modelContext()
        let serverKey = key(for: serverURL)
        let cacheKey = detailsKey(for: details.id, serverURL: serverURL)
        let payload = try JSONEncoder().encode(details)
        var descriptor = FetchDescriptor<CachedGameDetailsRecord>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        descriptor.fetchLimit = 1

        if let record = try context.fetch(descriptor).first {
            record.updatedAt = .now
            record.payload = payload
        } else {
            context.insert(
                CachedGameDetailsRecord(
                    cacheKey: cacheKey,
                    serverKey: serverKey,
                    gameID: details.id,
                    updatedAt: .now,
                    payload: payload
                )
            )
        }

        try context.save()
    }

    func removeGames(withIDs gameIDs: Set<Int>, for serverURL: ServerURL) throws {
        guard !gameIDs.isEmpty else {
            return
        }

        let context = try modelContext()
        let serverKey = key(for: serverURL)
        var snapshotDescriptor = FetchDescriptor<CachedLibrarySnapshotRecord>(
            predicate: #Predicate { $0.serverKey == serverKey }
        )
        snapshotDescriptor.fetchLimit = 1

        if let snapshotRecord = try context.fetch(snapshotDescriptor).first,
           let snapshot = try? JSONDecoder().decode(
               LibrarySnapshot.self,
               from: snapshotRecord.payload
           ) {
            let updatedSnapshot = snapshot.removingGames(withIDs: gameIDs)
            snapshotRecord.payload = try JSONEncoder().encode(updatedSnapshot)
        }

        let detailsDescriptor = FetchDescriptor<CachedGameDetailsRecord>(
            predicate: #Predicate { $0.serverKey == serverKey }
        )
        for record in try context.fetch(detailsDescriptor)
        where gameIDs.contains(record.gameID) {
            context.delete(record)
        }

        if let state = try localFavorites(for: serverURL) {
            try replaceLocalFavorites(
                LocalFavoriteState(
                    gameIDs: state.gameIDs.subtracting(gameIDs),
                    pendingChanges: state.pendingChanges.filter {
                        !gameIDs.contains($0.gameID)
                    }
                ),
                for: serverURL
            )
        }

        try context.save()
    }

    func localFavorites(
        for serverURL: ServerURL
    ) throws -> LocalFavoriteState? {
        let context = try modelContext()
        let serverKey = key(for: serverURL)
        var descriptor = FetchDescriptor<LocalFavoriteStateRecord>(
            predicate: #Predicate { $0.serverKey == serverKey }
        )
        descriptor.fetchLimit = 1

        guard let record = try context.fetch(descriptor).first else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                LocalFavoriteState.self,
                from: record.payload
            )
        } catch {
            context.delete(record)
            try context.save()
            return nil
        }
    }

    func replaceLocalFavorites(
        _ state: LocalFavoriteState,
        for serverURL: ServerURL
    ) throws {
        let context = try modelContext()
        let serverKey = key(for: serverURL)
        let payload = try JSONEncoder().encode(state)
        var descriptor = FetchDescriptor<LocalFavoriteStateRecord>(
            predicate: #Predicate { $0.serverKey == serverKey }
        )
        descriptor.fetchLimit = 1

        if let record = try context.fetch(descriptor).first {
            record.updatedAt = .now
            record.payload = payload
        } else {
            context.insert(
                LocalFavoriteStateRecord(
                    serverKey: serverKey,
                    updatedAt: .now,
                    payload: payload
                )
            )
        }
        try context.save()
    }

    func removeAll() throws {
        let context = try modelContext()
        try context.delete(model: CachedLibrarySnapshotRecord.self)
        try context.delete(model: CachedGameDetailsRecord.self)
        try context.delete(model: LocalFavoriteStateRecord.self)
        try context.save()
    }

    private func modelContext() throws -> ModelContext {
        if let container {
            return ModelContext(container)
        }

        let schema = Schema([
            CachedLibrarySnapshotRecord.self,
            CachedGameDetailsRecord.self,
            LocalFavoriteStateRecord.self,
        ])
        let configuration = ModelConfiguration(
            "OpenVaultLibrary",
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        self.container = container
        return ModelContext(container)
    }

    private func key(for serverURL: ServerURL) -> String {
        serverURL.value.absoluteString
    }

    private func detailsKey(for gameID: Int, serverURL: ServerURL) -> String {
        "\(key(for: serverURL))#\(gameID)"
    }
}

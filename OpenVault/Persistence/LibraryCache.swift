import Foundation

/// Persistence boundary for disposable, server-scoped RomM metadata.
protocol LibraryCaching: Sendable {
    func snapshot(for serverURL: ServerURL) async throws -> LibrarySnapshot?
    func replaceSnapshot(_ snapshot: LibrarySnapshot, for serverURL: ServerURL) async throws
    func gameDetails(for gameID: Int, serverURL: ServerURL) async throws -> GameDetails?
    func saveGameDetails(_ details: GameDetails, for serverURL: ServerURL) async throws
    func removeGames(withIDs gameIDs: Set<Int>, for serverURL: ServerURL) async throws
    func localFavorites(for serverURL: ServerURL) async throws -> LocalFavoriteState?
    func replaceLocalFavorites(
        _ state: LocalFavoriteState,
        for serverURL: ServerURL
    ) async throws
    func localPlayHistory(for serverURL: ServerURL) async throws -> LocalPlayHistory?
    func replaceLocalPlayHistory(
        _ history: LocalPlayHistory,
        for serverURL: ServerURL
    ) async throws
    func removeAll() async throws
}

/// Lightweight cache used by tests and as a non-persistent fallback.
actor InMemoryLibraryCache: LibraryCaching {
    private var snapshots: [ServerURL: LibrarySnapshot] = [:]
    private var details: [ServerURL: [Int: GameDetails]] = [:]
    private var favorites: [ServerURL: LocalFavoriteState] = [:]
    private var playHistories: [ServerURL: LocalPlayHistory] = [:]

    func snapshot(for serverURL: ServerURL) -> LibrarySnapshot? {
        snapshots[serverURL]
    }

    func replaceSnapshot(_ snapshot: LibrarySnapshot, for serverURL: ServerURL) {
        snapshots[serverURL] = snapshot

        let validGameIDs = Set(snapshot.games.map(\.id))
        details[serverURL] = details[serverURL]?.filter {
            validGameIDs.contains($0.key)
        }
    }

    func gameDetails(for gameID: Int, serverURL: ServerURL) -> GameDetails? {
        details[serverURL]?[gameID]
    }

    func saveGameDetails(_ gameDetails: GameDetails, for serverURL: ServerURL) {
        details[serverURL, default: [:]][gameDetails.id] = gameDetails
    }

    func removeGames(withIDs gameIDs: Set<Int>, for serverURL: ServerURL) {
        if let snapshot = snapshots[serverURL] {
            snapshots[serverURL] = snapshot.removingGames(withIDs: gameIDs)
        }
        details[serverURL] = details[serverURL]?.filter {
            !gameIDs.contains($0.key)
        }
        if let state = favorites[serverURL] {
            favorites[serverURL] = LocalFavoriteState(
                gameIDs: state.gameIDs.subtracting(gameIDs),
                pendingChanges: state.pendingChanges.filter {
                    !gameIDs.contains($0.gameID)
                }
            )
        }
        playHistories[serverURL] = playHistories[serverURL]?
            .removingGames(withIDs: gameIDs)
    }

    func localFavorites(for serverURL: ServerURL) -> LocalFavoriteState? {
        favorites[serverURL]
    }

    func replaceLocalFavorites(
        _ state: LocalFavoriteState,
        for serverURL: ServerURL
    ) {
        favorites[serverURL] = state
    }

    func localPlayHistory(for serverURL: ServerURL) -> LocalPlayHistory? {
        playHistories[serverURL]
    }

    func replaceLocalPlayHistory(
        _ history: LocalPlayHistory,
        for serverURL: ServerURL
    ) {
        playHistories[serverURL] = history
    }

    func removeAll() {
        snapshots.removeAll()
        details.removeAll()
        favorites.removeAll()
        playHistories.removeAll()
    }
}

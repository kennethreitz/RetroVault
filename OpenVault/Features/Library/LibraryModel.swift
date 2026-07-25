import Foundation
import Observation

enum LibrarySelection: Hashable {
    case allGames
    case system(Int)
    case collection(LibraryCollection.ID)

    var filter: LibraryFilter {
        switch self {
        case .allGames:
            .allGames
        case let .system(id):
            .system(id)
        case let .collection(id):
            .collection(id)
        }
    }
}

@MainActor
@Observable
final class LibraryModel {
    private static let pageSize = 60

    let session: ServerSession
    let service: any LibraryServing

    var selection: LibrarySelection = .allGames
    private(set) var systems: [LibrarySystem] = []
    private(set) var collections: [LibraryCollection] = []
    private(set) var games: [GameSummary] = []
    private(set) var searchTerm = ""
    private(set) var searchesAllSystems = false
    private(set) var hidesGamesWithoutArtwork = false
    private(set) var allGameCount = 0
    private(set) var totalGameCount = 0
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?

    private var hasLoaded = false
    private var requestID = UUID()

    init(session: ServerSession, service: any LibraryServing) {
        self.session = session
        self.service = service
    }

    var title: String {
        switch selection {
        case .allGames:
            "All Games"
        case let .system(id):
            systems.first(where: { $0.id == id })?.name ?? "System"
        case let .collection(id):
            collections.first(where: { $0.id == id })?.name ?? "Collection"
        }
    }

    var displayedGames: [GameSummary] {
        guard hidesGamesWithoutArtwork else {
            return games
        }
        return games.filter { $0.coverURL != nil }
    }

    var hasMoreGames: Bool {
        games.count < totalGameCount
    }

    func load() async {
        guard !hasLoaded else {
            return
        }
        await refresh()
    }

    func refresh() async {
        let currentRequestID = UUID()
        requestID = currentRequestID
        isLoading = true
        isLoadingMore = false
        errorMessage = nil

        do {
            async let systems = service.systems(in: session)
            async let collections = service.collections(in: session)
            let (loadedSystems, loadedCollections) = try await (systems, collections)

            guard requestID == currentRequestID else {
                return
            }

            self.systems = loadedSystems
            self.collections = loadedCollections
            allGameCount = loadedSystems.reduce(0) { $0 + $1.gameCount }
            validateSelection()

            let page = try await service.games(
                in: session,
                matching: requestFilter,
                searchTerm: normalizedSearchTerm,
                offset: 0,
                limit: Self.pageSize
            )

            guard requestID == currentRequestID else {
                return
            }

            games = page.games
            totalGameCount = page.total
            if selection == .allGames {
                allGameCount = page.total
            }
            hasLoaded = true
            isLoading = false
        } catch {
            guard requestID == currentRequestID else {
                return
            }
            games = []
            totalGameCount = 0
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func reloadGames() async {
        let currentRequestID = UUID()
        requestID = currentRequestID
        games = []
        totalGameCount = 0
        isLoading = true
        isLoadingMore = false
        errorMessage = nil

        do {
            let page = try await service.games(
                in: session,
                matching: requestFilter,
                searchTerm: normalizedSearchTerm,
                offset: 0,
                limit: Self.pageSize
            )

            guard requestID == currentRequestID else {
                return
            }

            games = page.games
            totalGameCount = page.total
            if selection == .allGames {
                allGameCount = page.total
            }
            isLoading = false
        } catch {
            guard requestID == currentRequestID else {
                return
            }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func loadMoreIfNeeded(near game: GameSummary) async {
        let visibleGames = displayedGames
        guard
            !isLoading,
            !isLoadingMore,
            hasMoreGames,
            let index = visibleGames.firstIndex(where: { $0.id == game.id }),
            index >= visibleGames.index(
                visibleGames.endIndex,
                offsetBy: -min(8, visibleGames.count)
            )
        else {
            return
        }

        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMoreGames else {
            return
        }

        let currentRequestID = requestID
        isLoadingMore = true
        errorMessage = nil
        let initialVisibleCount = displayedGames.count
        var fetchedPageCount = 0

        do {
            repeat {
                let page = try await service.games(
                    in: session,
                    matching: requestFilter,
                    searchTerm: normalizedSearchTerm,
                    offset: games.count,
                    limit: Self.pageSize
                )

                guard requestID == currentRequestID else {
                    return
                }

                let existingIDs = Set(games.map(\.id))
                games.append(contentsOf: page.games.filter { !existingIDs.contains($0.id) })
                totalGameCount = page.total
                fetchedPageCount += 1
            } while hidesGamesWithoutArtwork
                && displayedGames.count == initialVisibleCount
                && hasMoreGames
                && fetchedPageCount < 4

            isLoadingMore = false
        } catch {
            guard requestID == currentRequestID else {
                return
            }
            errorMessage = error.localizedDescription
            isLoadingMore = false
        }
    }

    func retry() async {
        if games.isEmpty {
            await reloadGames()
        } else if let lastGame = games.last {
            await loadMoreIfNeeded(near: lastGame)
        }
    }

    func search(for term: String) async {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchTerm != normalized else {
            return
        }

        searchTerm = normalized
        if normalized.isEmpty {
            searchesAllSystems = false
        }
        await reloadGames()
    }

    func setSearchesAllSystems(_ enabled: Bool) async {
        let newValue = enabled && !searchTerm.isEmpty
        guard searchesAllSystems != newValue else {
            return
        }

        searchesAllSystems = newValue
        await reloadGames()
    }

    func setHidesGamesWithoutArtwork(_ enabled: Bool) {
        hidesGamesWithoutArtwork = enabled
    }

    private var requestFilter: LibraryFilter {
        if !searchTerm.isEmpty, searchesAllSystems {
            return .allGames
        }
        return selection.filter
    }

    private var normalizedSearchTerm: String? {
        searchTerm.isEmpty ? nil : searchTerm
    }

    private func validateSelection() {
        switch selection {
        case .allGames:
            break
        case let .system(id) where systems.contains(where: { $0.id == id }):
            break
        case let .collection(id) where collections.contains(where: { $0.id == id }):
            break
        case .system, .collection:
            selection = .allGames
        }
    }
}

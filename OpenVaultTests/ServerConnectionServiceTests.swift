import Foundation
import Testing

@testable import OpenVault

@Suite("Server connection")
struct ServerConnectionServiceTests {
    @Test("Pairs, validates scopes, and persists the session")
    func pairsAndPersists() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "b", count: 64))
        let api = MockRomMClient(
            token: token,
            user: RomMUser(
                id: 1,
                username: "kenneth",
                scopes: ["collections.read", "me.read", "platforms.read", "roms.read"]
            )
        )
        let credentials = MemoryCredentialStore()
        let configurations = MemoryConfigurationStore()
        let service = ServerConnectionService(
            api: api,
            credentialStore: credentials,
            configurationStore: configurations
        )

        let session = try await service.pair(
            serverURL: "https://romm.example.com",
            pairingCode: "12345678"
        )

        #expect(session.username == "kenneth")
        #expect(await credentials.token == token)
        #expect(await configurations.configuration?.serverURL == session.serverURL)
    }

    @Test("Reports missing scopes while preserving the exchanged token")
    func reportsMissingScopes() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "c", count: 64))
        let api = MockRomMClient(
            token: token,
            user: RomMUser(id: 1, username: "kenneth", scopes: ["me.read"])
        )
        let credentials = MemoryCredentialStore()
        let configurations = MemoryConfigurationStore()
        let service = ServerConnectionService(
            api: api,
            credentialStore: credentials,
            configurationStore: configurations
        )

        await #expect(throws: ServerConnectionError.self) {
            try await service.pair(
                serverURL: "https://romm.example.com",
                pairingCode: "12345678"
            )
        }

        #expect(await credentials.token == token)
        #expect(await configurations.configuration == nil)
    }
}

@Suite("Library")
struct LibraryTests {
    @MainActor
    @Test("Loads sidebar data and paginates the shared game grid")
    func loadsAndPaginates() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let service = MockLibraryService()
        let model = LibraryModel(session: session, service: service)

        await model.load()

        #expect(model.systems.map(\.name) == ["Game Boy", "Super Nintendo"])
        #expect(model.collections.map(\.name) == ["Favorites"])
        #expect(model.games.count == 60)
        #expect(model.allGameCount == 61)
        #expect(model.totalGameCount == 61)

        await model.loadMoreIfNeeded(near: try #require(model.games.last))
        #expect(model.games.count == 61)

        model.selection = .system(2)
        await model.reloadGames()
        #expect(model.games.allSatisfy { $0.systemID == 2 })

        await model.search(for: "Game 2")
        #expect(model.searchTerm == "Game 2")
        #expect(model.games.allSatisfy { game in
            game.systemID == 2 && game.name.localizedCaseInsensitiveContains("Game 2")
        })

        await model.setSearchesAllSystems(true)
        #expect(model.searchesAllSystems)
        #expect(model.games.contains { $0.systemID == 1 })

        model.setHidesGamesWithoutArtwork(true)
        #expect(model.displayedGames.allSatisfy { $0.coverURL != nil })
    }

    @Test("Adds bearer authentication only to same-origin artwork")
    func authenticatesOnlyRomMArtwork() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "e", count: 64))
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let api = MockRomMClient(
            token: token,
            user: RomMUser(
                id: 1,
                username: "kenneth",
                scopes: ["collections.read", "me.read", "platforms.read", "roms.read"]
            )
        )
        let service = RomMLibraryService(api: api, credentialStore: credentials)
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let localGame = GameSummary(
            id: 1,
            name: "Local",
            systemID: 1,
            systemName: "Test",
            coverURL: URL(string: "https://romm.example.com/assets/local.webp")
        )
        let remoteGame = GameSummary(
            id: 2,
            name: "Remote",
            systemID: 1,
            systemName: "Test",
            coverURL: URL(string: "https://images.example.net/remote.webp")
        )

        let localRequest = try #require(
            try await service.artworkRequest(for: localGame, in: session)
        )
        let remoteRequest = try #require(
            try await service.artworkRequest(for: remoteGame, in: session)
        )

        #expect(localRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(token.rawValue)")
        #expect(remoteRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

private struct MockRomMClient: RomMClient {
    let token: ClientToken
    let user: RomMUser

    func verifyServer(at serverURL: ServerURL) async throws {}

    func exchange(pairingCode: PairingCode, at serverURL: ServerURL) async throws -> ClientToken {
        token
    }

    func currentUser(at serverURL: ServerURL, token: ClientToken) async throws -> RomMUser {
        user
    }

    func systems(at serverURL: ServerURL, token: ClientToken) async throws -> [LibrarySystem] {
        []
    }

    func collections(at serverURL: ServerURL, token: ClientToken) async throws -> [LibraryCollection] {
        []
    }

    func games(
        at serverURL: ServerURL,
        token: ClientToken,
        matching filter: LibraryFilter,
        searchTerm: String?,
        offset: Int,
        limit: Int
    ) async throws -> GamePage {
        GamePage(games: [], total: 0, limit: limit, offset: offset)
    }
}

private actor MockLibraryService: LibraryServing {
    private let allGames: [GameSummary] = (1 ... 61).map { id in
        let systemID = id.isMultiple(of: 2) ? 2 : 1
        return GameSummary(
            id: id,
            name: "Game \(id)",
            systemID: systemID,
            systemName: systemID == 1 ? "Game Boy" : "Super Nintendo",
            coverURL: id.isMultiple(of: 2)
                ? URL(string: "https://romm.example.com/assets/\(id).webp")
                : nil
        )
    }

    func systems(in session: ServerSession) -> [LibrarySystem] {
        [
            LibrarySystem(id: 1, name: "Game Boy", gameCount: 31),
            LibrarySystem(id: 2, name: "Super Nintendo", gameCount: 30),
        ]
    }

    func collections(in session: ServerSession) -> [LibraryCollection] {
        [
            LibraryCollection(id: .regular(1), name: "Favorites", gameCount: 5),
        ]
    }

    func games(
        in session: ServerSession,
        matching filter: LibraryFilter,
        searchTerm: String?,
        offset: Int,
        limit: Int
    ) -> GamePage {
        let filteredGames: [GameSummary]
        switch filter {
        case .allGames:
            filteredGames = allGames
        case let .system(id):
            filteredGames = allGames.filter { $0.systemID == id }
        case .collection:
            filteredGames = Array(allGames.prefix(5))
        }

        let matchingGames: [GameSummary]
        if let searchTerm, !searchTerm.isEmpty {
            matchingGames = filteredGames.filter {
                $0.name.localizedCaseInsensitiveContains(searchTerm)
            }
        } else {
            matchingGames = filteredGames
        }

        return GamePage(
            games: Array(matchingGames.dropFirst(offset).prefix(limit)),
            total: matchingGames.count,
            limit: limit,
            offset: offset
        )
    }

    func artworkRequest(for game: GameSummary, in session: ServerSession) -> URLRequest? {
        nil
    }
}

private actor MemoryCredentialStore: CredentialStoring {
    var token: ClientToken?

    func loadToken() -> ClientToken? {
        token
    }

    func save(_ token: ClientToken) {
        self.token = token
    }

    func removeToken() {
        token = nil
    }
}

private actor MemoryConfigurationStore: ServerConfigurationStoring {
    var configuration: RemoteServerConfiguration?

    func load() -> RemoteServerConfiguration? {
        configuration
    }

    func save(_ configuration: RemoteServerConfiguration) {
        self.configuration = configuration
    }

    func remove() {
        configuration = nil
    }
}

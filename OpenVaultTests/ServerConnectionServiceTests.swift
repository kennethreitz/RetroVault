import Foundation
import Testing

@testable import OpenVault

@Suite("Application Support credential storage")
struct ApplicationSupportCredentialStoreTests {
    @Test("Stores the token with owner-only permissions and removes it")
    func roundTrip() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directoryURL.appending(path: "romm-client-token")
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let store = ApplicationSupportCredentialStore(fileURL: fileURL)
        let token = try ClientToken(
            rawValue: "rmm_" + String(repeating: "a", count: 64)
        )

        #expect(try await store.loadToken() == nil)

        try await store.save(token)

        #expect(try await store.loadToken() == token)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: directoryURL.path
        )
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        try await store.removeToken()

        #expect(try await store.loadToken() == nil)
    }
}

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
                scopes: [
                    "collections.read",
                    "me.read",
                    "platforms.read",
                    "roms.read",
                    "roms.user.write",
                ]
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

    @Test("Disconnects and clears the offline library cache")
    func disconnectsAndClearsCache() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "d", count: 64))
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let configurations = MemoryConfigurationStore()
        let serverURL = try ServerURL("https://romm.example.com")
        await configurations.save(
            RemoteServerConfiguration(
                serverURL: serverURL,
                username: "kenneth"
            )
        )
        let cache = InMemoryLibraryCache()
        await cache.replaceSnapshot(testLibrarySnapshot(), for: serverURL)
        let service = ServerConnectionService(
            api: MockRomMClient(
                token: token,
                user: RomMUser(id: 1, username: "kenneth", scopes: [])
            ),
            credentialStore: credentials,
            configurationStore: configurations,
            libraryCache: cache
        )

        try await service.disconnect()

        #expect(await credentials.token == nil)
        #expect(await configurations.configuration == nil)
        #expect(await cache.snapshot(for: serverURL) == nil)
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

        await model.setHidesGamesWithoutArtwork(true)
        #expect(model.displayedGames.allSatisfy { $0.coverURL != nil })
        #expect(model.systemIDsWithArtwork == [2])
        #expect(model.systemIDsWithoutArtwork == [1])
    }

    @MainActor
    @Test("Purges the local cache before rebuilding the library")
    func purgesAndResynchronizes() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let service = MockLibraryService()
        let model = LibraryModel(session: session, service: service)

        await model.load()
        await model.purgeLocalCacheAndResync()

        #expect(await service.purgeCount() == 1)
        #expect(model.games.count == 60)
        #expect(model.allGameCount == 61)
        #expect(model.totalGameCount == 61)
        #expect(!model.isSynchronizing)
        #expect(!model.isPurgingLocalCache)
        #expect(model.refreshErrorMessage == nil)
    }

    @MainActor
    @Test("Drops BIOS entries and advances past BIOS-only pages")
    func dropsBIOSGames() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let biosGames = (1 ... 60).map { id in
            GameSummary(
                id: id,
                name: "[BIOS] Firmware \(id)",
                systemID: 1,
                systemName: "Game Boy",
                coverURL: nil,
                isBIOS: true
            )
        }
        let playableGame = GameSummary(
            id: 61,
            name: "Tetris",
            systemID: 1,
            systemName: "Game Boy",
            coverURL: nil
        )
        let service = MockLibraryService(allGames: biosGames + [playableGame])
        let model = LibraryModel(session: session, service: service)

        await model.load()

        #expect(model.displayedGames == [playableGame])
        #expect(model.games.count == 1)
        #expect(model.displayedGames.allSatisfy { !$0.isBIOS })
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

    @MainActor
    @Test("Loads full game details")
    func loadsFullGameDetails() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let game = GameSummary(
            id: 42,
            name: "Game 42",
            systemID: 1,
            systemName: "Game Boy",
            coverURL: nil
        )
        let model = GameDetailsModel(
            game: game,
            session: session,
            service: MockLibraryService()
        )

        await model.load()

        #expect(model.details?.id == 42)
        #expect(model.details?.files.isEmpty == true)
        #expect(model.errorMessage == nil)

        var metadata = try #require(model.details?.userMetadata)
        metadata.completion = 65
        metadata.rating = 8
        metadata.status = "incomplete"
        await model.updateUserMetadata(metadata)

        #expect(model.details?.userMetadata.completion == 65)
        #expect(model.details?.userMetadata.rating == 8)
        #expect(model.details?.userMetadata.status == "incomplete")
        #expect(model.userMetadataErrorMessage == nil)
    }

    @MainActor
    @Test("Rolls back optimistic user metadata when RomM rejects an update")
    func rollsBackRejectedUserMetadata() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let model = GameDetailsModel(
            game: GameSummary(
                id: 42,
                name: "Game 42",
                systemID: 1,
                systemName: "Game Boy",
                coverURL: nil
            ),
            session: session,
            service: MockLibraryService(rejectsMetadataUpdates: true)
        )
        await model.load()

        var metadata = try #require(model.details?.userMetadata)
        metadata.completion = 65
        await model.updateUserMetadata(metadata)

        #expect(model.details?.userMetadata.completion == 0)
        #expect(model.userMetadataErrorMessage != nil)
    }

    @Test("Persists updated user metadata in the offline details cache")
    func cachesUpdatedUserMetadata() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "f", count: 64))
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let cache = InMemoryLibraryCache()
        let api = MockRomMClient(
            token: token,
            user: RomMUser(id: 1, username: "kenneth", scopes: ["roms.user.write"])
        )
        let service = RomMLibraryService(
            api: api,
            credentialStore: credentials,
            cache: cache
        )
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let game = mockGameDetails(id: 42)
        var metadata = game.userMetadata
        metadata.completion = 100
        metadata.status = "completed_100"

        let updated = try await service.updateUserMetadata(
            metadata,
            for: game,
            in: session
        )
        let cached = await cache.gameDetails(
            for: game.id,
            serverURL: session.serverURL
        )

        #expect(updated.userMetadata.completion == 100)
        #expect(updated.userMetadata.status == "completed_100")
        #expect(cached?.userMetadata == updated.userMetadata)
    }

    @Test("Saves downloads without overwriting an existing ROM")
    func savesDownloadWithoutOverwriting() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "f", count: 64))
        let credentials = MemoryCredentialStore()
        await credentials.save(token)

        let downloadsDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: downloadsDirectory)
        }

        let existingURL = downloadsDirectory.appending(path: "Game 42.gb")
        try Data("existing".utf8).write(to: existingURL)

        let api = MockRomMClient(
            token: token,
            user: RomMUser(id: 1, username: "kenneth", scopes: ["roms.read"])
        )
        let service = RomMLibraryService(
            api: api,
            credentialStore: credentials,
            downloadsDirectory: downloadsDirectory
        )
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )

        let savedURL = try await service.downloadGame(
            mockGameDetails(id: 42),
            in: session
        )

        #expect(savedURL.lastPathComponent == "Game 42 2.gb")
        #expect(try Data(contentsOf: existingURL) == Data("existing".utf8))
        #expect(try Data(contentsOf: savedURL) == Data("downloaded".utf8))
    }

    @Test("Reuses a cached game when RomM credentials are unavailable")
    func reusesPlaybackCacheOffline() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "a", count: 64))
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let runtimeCacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: runtimeCacheDirectory)
        }

        let expectedData = Data(repeating: 0x42, count: 1_024)
        let service = RomMLibraryService(
            api: MockRomMClient(
                token: token,
                user: RomMUser(id: 1, username: "kenneth", scopes: ["roms.read"]),
                downloadData: expectedData
            ),
            credentialStore: credentials,
            runtimeCacheDirectory: runtimeCacheDirectory
        )
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let game = mockGameDetails(id: 42)

        let firstURL = try await service.prepareGameForPlay(
            game,
            in: session,
            supportedFileExtensions: ["gb"]
        )
        await credentials.removeToken()
        let offlineURL = try await service.prepareGameForPlay(
            game,
            in: session,
            supportedFileExtensions: ["gb"]
        )

        #expect(firstURL == offlineURL)
        #expect(try Data(contentsOf: offlineURL) == expectedData)
        #expect(offlineURL.path.hasPrefix(runtimeCacheDirectory.path))
    }
}

private struct MockRomMClient: RomMClient {
    let token: ClientToken
    let user: RomMUser
    var downloadData = Data("downloaded".utf8)

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

    func gameDetails(
        for gameID: Int,
        at serverURL: ServerURL,
        token: ClientToken
    ) async throws -> GameDetails {
        throw RomMAPIError.notFound
    }

    func updateGameUserMetadata(
        _ metadata: GameUserMetadata,
        for gameID: Int,
        at serverURL: ServerURL,
        token: ClientToken
    ) async throws -> GameUserMetadata {
        metadata
    }

    func downloadGame(
        for gameID: Int,
        fileName: String,
        at serverURL: ServerURL,
        token: ClientToken
    ) async throws -> RomMDownload {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try downloadData.write(to: temporaryURL)
        return RomMDownload(
            temporaryFileURL: temporaryURL,
            suggestedFileName: fileName
        )
    }
}

private actor MockLibraryService: LibraryServing {
    private static let defaultGames: [GameSummary] = (1 ... 61).map { id in
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

    private let allGames: [GameSummary]
    private let rejectsMetadataUpdates: Bool
    private var localCachePurgeCount = 0

    init(
        allGames: [GameSummary]? = nil,
        rejectsMetadataUpdates: Bool = false
    ) {
        self.allGames = allGames ?? Self.defaultGames
        self.rejectsMetadataUpdates = rejectsMetadataUpdates
    }

    func cachedSnapshot(in session: ServerSession) -> LibrarySnapshot? {
        nil
    }

    func purgeLocalCache() {
        localCachePurgeCount += 1
    }

    func purgeCount() -> Int {
        localCachePurgeCount
    }

    func synchronizeLibrary(
        in session: ServerSession,
        onProgress: @escaping @Sendable (LibrarySyncProgress) async -> Void
    ) async -> LibrarySnapshot {
        let synchronizedGames = allGames.filter { !$0.isBIOS }
        let synchronizedSystems = systems(in: session).map { system in
            LibrarySystem(
                id: system.id,
                name: system.name,
                gameCount: synchronizedGames.count { $0.systemID == system.id }
            )
        }
        let synchronizedCollections = collections(in: session).map { collection in
            LibraryCollection(
                id: collection.id,
                name: collection.name,
                gameCount: min(5, synchronizedGames.count)
            )
        }

        await onProgress(
            LibrarySyncProgress(
                systems: synchronizedSystems,
                collections: synchronizedCollections,
                games: synchronizedGames,
                completedGameCount: synchronizedGames.count,
                totalGameCount: synchronizedGames.count
            )
        )

        return LibrarySnapshot(
            synchronizedAt: Date(timeIntervalSince1970: 1_000),
            systems: synchronizedSystems,
            collections: synchronizedCollections,
            games: synchronizedGames,
            collectionMemberships: synchronizedCollections.map {
                LibrarySnapshot.CollectionMembership(
                    collectionID: $0.id,
                    gameIDs: Array(synchronizedGames.prefix(5).map(\.id))
                )
            }
        )
    }

    func systems(in session: ServerSession) -> [LibrarySystem] {
        Dictionary(grouping: allGames, by: \.systemID)
            .compactMap { id, games in
                guard let name = games.first?.systemName else {
                    return nil
                }
                return LibrarySystem(id: id, name: name, gameCount: games.count)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    func systemHasArtwork(_ systemID: Int, in session: ServerSession) -> Bool {
        allGames.contains { $0.systemID == systemID && !$0.isBIOS && $0.coverURL != nil }
    }

    func gameDetails(for gameID: Int, in session: ServerSession) -> GameDetails {
        mockGameDetails(id: gameID)
    }

    func updateUserMetadata(
        _ metadata: GameUserMetadata,
        for game: GameDetails,
        in session: ServerSession
    ) throws -> GameDetails {
        if rejectsMetadataUpdates {
            throw RomMAPIError.server(statusCode: 503)
        }

        var updated = game
        updated.userMetadata = metadata
        return updated
    }

    func downloadGame(_ game: GameDetails, in session: ServerSession) -> URL {
        FileManager.default.temporaryDirectory.appending(path: game.fileName)
    }

    func artworkRequest(for game: GameSummary, in session: ServerSession) -> URLRequest? {
        nil
    }

    func resourceRequest(for url: URL?, in session: ServerSession) -> URLRequest? {
        nil
    }
}

func mockGameDetails(id: Int) -> GameDetails {
    GameDetails(
        id: id,
        name: "Game \(id)",
        systemID: 1,
        systemName: "Game Boy",
        summary: "Test game",
        coverURL: nil,
        screenshotURLs: [],
        alternativeNames: [],
        metadata: GameMetadata(
            genres: ["Action"],
            franchises: [],
            collections: [],
            companies: [],
            gameModes: ["Single player"],
            ageRatings: [],
            playerCount: "1",
            firstReleaseDate: nil,
            averageRating: nil
        ),
        regions: [],
        languages: [],
        tags: [],
        files: [],
        fileName: "Game \(id).gb",
        fileExtension: "gb",
        filePath: "roms/GB",
        fullPath: "roms/GB/Game \(id).gb",
        fileSizeBytes: 1_024,
        revision: nil,
        crcHash: nil,
        md5Hash: nil,
        sha1Hash: nil,
        retroAchievementsHash: nil,
        isIdentified: true,
        isMissingFromFileSystem: false,
        hasManual: false,
        hasSoundtrack: false,
        manualURL: nil,
        videoURL: nil,
        createdAt: "",
        updatedAt: "",
        userMetadata: GameUserMetadata(
            status: nil,
            lastPlayed: nil,
            rating: 0,
            difficulty: 0,
            completion: 0,
            isBacklogged: false,
            isNowPlaying: false,
            isHidden: false
        ),
        saves: [],
        states: [],
        contentCounts: GameContentCounts(
            siblingGames: 0,
            saves: 0,
            states: 0,
            screenshots: 0,
            collections: 0,
            notes: 0
        ),
        providerIdentifiers: []
    )
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

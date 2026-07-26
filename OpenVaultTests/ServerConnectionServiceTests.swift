import CryptoKit
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
                    "assets.read",
                    "assets.write",
                    "collections.read",
                    "collections.write",
                    "firmware.read",
                    "me.read",
                    "platforms.read",
                    "roms.read",
                    "roms.write",
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
    @Test("Persists RomM Favorites membership in the offline snapshot")
    func persistsFavoriteMembership() async throws {
        let token = try ClientToken(
            rawValue: "rmm_" + String(repeating: "a", count: 64)
        )
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let serverURL = try ServerURL("https://romm.example.com")
        let session = ServerSession(serverURL: serverURL, username: "kenneth")
        let cache = InMemoryLibraryCache()
        await cache.replaceSnapshot(testLibrarySnapshot(), for: serverURL)
        let updatedCollection = LibraryCollection(
            id: .regular(10),
            name: "Favorites",
            gameCount: 2,
            isFavorite: true,
            memberGameIDs: [1, 2]
        )
        let api = MockRomMClient(
            token: token,
            user: RomMUser(
                id: 1,
                username: "kenneth",
                scopes: ["collections.write"]
            ),
            updatedCollection: updatedCollection
        )
        let service = RomMLibraryService(
            api: api,
            credentialStore: credentials,
            cache: cache
        )

        let result = try await service.updateCollectionMembership(
            collectionID: 10,
            gameIDs: [2],
            adding: true,
            in: session
        )

        #expect(
            result.collectionMemberships.first {
                $0.collectionID == .regular(10)
            }?.gameIDs == [1, 2]
        )
        #expect(
            await cache.snapshot(for: serverURL)?
                .collections.first { $0.id == .regular(10) }?
                .isFavorite == true
        )
    }

    @MainActor
    @Test("Loads sidebar data and exposes the complete synchronized library")
    func loadsCompleteLibrary() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let service = MockLibraryService()
        let model = LibraryModel(session: session, service: service)

        await model.load()

        #expect(model.systems.map(\.name) == ["Game Boy", "Super Nintendo"])
        #expect(model.collections.map(\.name) == ["Favorites"])
        #expect(model.games.count == 61)
        #expect(model.allGameCount == 61)
        #expect(model.totalGameCount == 61)

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
    @Test("Starts a complete artwork pass after synchronization")
    func startsArtworkCachingAfterSynchronization() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let service = MockLibraryService()
        let artworkCache = RecordingArtworkCache()
        let model = LibraryModel(
            session: session,
            service: service,
            artworkCache: artworkCache
        )

        await model.load()
        let cachedGameIDs = await artworkCache.waitForRequest()

        #expect(cachedGameIDs.count == 61)
        #expect(model.artworkCacheTotalCount == 30)
        #expect(model.cachedArtworkCount == 30)
        #expect(model.artworkCacheFailureCount == 0)
        #expect(!model.isCachingArtwork)
    }

    @MainActor
    @Test("Removes games after RomM confirms deletion")
    func deletesGamesFromLibrary() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let service = MockLibraryService()
        let model = LibraryModel(session: session, service: service)
        await model.load()
        let game = try #require(model.games.first)

        let result = try await model.deleteGames(
            [game],
            deletingFilesFromServer: false
        )

        #expect(result.successfulItemCount == 1)
        #expect(!model.games.contains { $0.id == game.id })
        #expect(model.allGameCount == 60)
    }

    @MainActor
    @Test("Downloads a unique game selection and refreshes local membership")
    func downloadsSelectedGames() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let service = MockLibraryService()
        let model = LibraryModel(session: session, service: service)
        await model.load()
        let firstGame = try #require(model.games.first)
        let secondGame = try #require(model.games.dropFirst().first)

        let result = await model.downloadGames([
            firstGame,
            secondGame,
            firstGame,
        ])

        #expect(result.successfulItemCount == 2)
        #expect(result.failedItemCount == 0)
        #expect(result.completedWithoutErrors)
        #expect(model.downloadedGameIDs == [firstGame.id, secondGame.id])
        let serviceDownloadedGameIDs = await service.downloadedGameIDs(
            in: session
        )
        #expect(serviceDownloadedGameIDs == [firstGame.id, secondGame.id])

        let removalResult = await model.removeDownloads([firstGame, secondGame])
        #expect(removalResult.successfulItemCount == 2)
        #expect(removalResult.completedWithoutErrors)
        #expect(model.downloadedGameIDs.isEmpty)
    }

    @MainActor
    @Test("Promotes a launched game to the front of an active download queue")
    func prioritizesLaunchedGameDownload() async throws {
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let service = MockLibraryService(blockedDownloadID: 1)
        let model = LibraryModel(session: session, service: service)
        await model.load()
        let firstGame = try #require(model.games.first { $0.id == 1 })
        let secondGame = try #require(model.games.first { $0.id == 2 })
        let launchedGame = try #require(model.games.first { $0.id == 3 })

        let bulkDownload = Task { @MainActor in
            await model.downloadGames([
                firstGame,
                secondGame,
            ])
        }
        await service.waitUntilDownloadStarts(gameID: firstGame.id)

        let prioritizedDownload = Task { @MainActor in
            await model.prioritizeDownloadForPlayback(launchedGame)
        }
        await Task.yield()
        await Task.yield()
        #expect(model.downloadProgress?.totalGameCount == 3)
        await service.resumeBlockedDownload()

        #expect(await prioritizedDownload.value == .downloaded)
        #expect((await bulkDownload.value).completedWithoutErrors)
        #expect(
            await service.recordedDownloadOrder()
                == [firstGame.id, launchedGame.id, secondGame.id]
        )
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
        #expect(model.games.count == 61)
        #expect(model.allGameCount == 61)
        #expect(model.totalGameCount == 61)
        #expect(!model.isSynchronizing)
        #expect(!model.isPurgingLocalCache)
        #expect(model.refreshErrorMessage == nil)
    }

    @MainActor
    @Test("Hides BIOS entries by default and can reveal them")
    func filtersBIOSGames() async throws {
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
        #expect(model.allGameCount == 1)
        #expect(model.displayedGames.allSatisfy { !$0.isBIOS })

        await model.setHidesBIOSGames(false)

        #expect(model.displayedGames.count == 61)
        #expect(model.games.count == 61)
        #expect(model.allGameCount == 61)
        #expect(model.displayedGames.contains { $0.isBIOS })
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
            try await service.resourceRequest(for: localGame.coverURL, in: session)
        )
        let remoteRequest = try #require(
            try await service.resourceRequest(for: remoteGame.coverURL, in: session)
        )
        let batchRequests = try await service.artworkRequests(
            for: [localGame, remoteGame, localGame],
            in: session
        )

        #expect(localRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(token.rawValue)")
        #expect(remoteRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(batchRequests.count == 2)
        #expect(
            batchRequests[0].value(forHTTPHeaderField: "Authorization")
                == "Bearer \(token.rawValue)"
        )
        #expect(batchRequests[1].value(forHTTPHeaderField: "Authorization") == nil)
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

    @Test("Exports without overwriting an existing ROM or changing local membership")
    func exportsWithoutOverwriting() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "f", count: 64))
        let credentials = MemoryCredentialStore()
        await credentials.save(token)

        let downloadsDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let localStorageDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: downloadsDirectory)
            try? FileManager.default.removeItem(at: localStorageDirectory)
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
            downloadsDirectory: downloadsDirectory,
            managedROMDirectory: localStorageDirectory.appending(path: "Managed"),
            runtimeCacheDirectory: localStorageDirectory.appending(path: "Runtime")
        )
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )

        let savedURL = try await service.exportGame(
            mockGameDetails(id: 42),
            in: session
        )

        #expect(savedURL.lastPathComponent == "Game 42 2.gb")
        #expect(try Data(contentsOf: existingURL) == Data("existing".utf8))
        #expect(try Data(contentsOf: savedURL) == Data("downloaded".utf8))
        #expect(await service.downloadedGameIDs(in: session).isEmpty)
        #expect(await service.managedDownloadedGameIDs(in: session).isEmpty)
    }

    @Test("Downloads a game into OpenVault's managed local library")
    func downloadsIntoManagedLibrary() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "e", count: 64))
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let managedROMDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let exportsDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: managedROMDirectory)
            try? FileManager.default.removeItem(at: exportsDirectory)
        }

        let expectedData = Data(repeating: 0x42, count: 1_024)
        let service = RomMLibraryService(
            api: MockRomMClient(
                token: token,
                user: RomMUser(id: 1, username: "kenneth", scopes: ["roms.read"]),
                downloadData: expectedData
            ),
            credentialStore: credentials,
            downloadsDirectory: exportsDirectory,
            managedROMDirectory: managedROMDirectory
        )
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )

        let localURL = try await service.downloadGame(
            mockGameDetails(id: 42),
            in: session
        )

        #expect(localURL.path.hasPrefix(managedROMDirectory.path))
        #expect(try Data(contentsOf: localURL) == expectedData)
        #expect(await service.downloadedGameIDs(in: session) == [42])
        #expect(await service.managedDownloadedGameIDs(in: session) == [42])

        await credentials.removeToken()
        let exportedURL = try await service.exportGame(
            mockGameDetails(id: 42),
            in: session
        )
        #expect(exportedURL.path.hasPrefix(exportsDirectory.path))
        #expect(try Data(contentsOf: exportedURL) == expectedData)
        #expect(await service.downloadedGameIDs(in: session) == [42])

        try await service.removeDownloadedGame(withID: 42, in: session)
        #expect(await service.downloadedGameIDs(in: session).isEmpty)
        #expect(await service.managedDownloadedGameIDs(in: session).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: localURL.path))
        #expect(try Data(contentsOf: exportedURL) == expectedData)
    }

    @Test("Reuses and promotes a cached game when RomM is unavailable")
    func reusesPlaybackCacheOffline() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "a", count: 64))
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let runtimeCacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedROMDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: runtimeCacheDirectory)
            try? FileManager.default.removeItem(at: managedROMDirectory)
        }

        let expectedData = Data(repeating: 0x42, count: 1_024)
        let service = RomMLibraryService(
            api: MockRomMClient(
                token: token,
                user: RomMUser(id: 1, username: "kenneth", scopes: ["roms.read"]),
                downloadData: expectedData
            ),
            credentialStore: credentials,
            managedROMDirectory: managedROMDirectory,
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
        #expect(await service.downloadedGameIDs(in: session) == [42])
        #expect(await service.managedDownloadedGameIDs(in: session).isEmpty)
        await credentials.removeToken()
        let relaunchedService = RomMLibraryService(
            api: MockRomMClient(
                token: token,
                user: RomMUser(id: 1, username: "kenneth", scopes: ["roms.read"])
            ),
            credentialStore: credentials,
            managedROMDirectory: managedROMDirectory,
            runtimeCacheDirectory: runtimeCacheDirectory
        )
        #expect(await relaunchedService.downloadedGameIDs(in: session) == [42])
        #expect(await relaunchedService.managedDownloadedGameIDs(in: session).isEmpty)
        let promotedURL = try await relaunchedService.downloadGame(
            game,
            in: session
        )
        #expect(promotedURL.path.hasPrefix(managedROMDirectory.path))
        #expect(await relaunchedService.managedDownloadedGameIDs(in: session) == [42])
        let offlineURL = try await relaunchedService.prepareGameForPlay(
            game,
            in: session,
            supportedFileExtensions: ["gb"]
        )

        #expect(firstURL.path.hasPrefix(runtimeCacheDirectory.path))
        #expect(offlineURL == promotedURL)
        #expect(try Data(contentsOf: offlineURL) == expectedData)
        #expect(offlineURL.path.hasPrefix(managedROMDirectory.path))

        try await relaunchedService.removeDownloadedGame(withID: 42, in: session)
        #expect(await relaunchedService.downloadedGameIDs(in: session).isEmpty)
        #expect(await relaunchedService.managedDownloadedGameIDs(in: session).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(!FileManager.default.fileExists(atPath: offlineURL.path))
    }

    @Test("Reuses a managed download after RomM metadata changes")
    func reusesManagedDownloadAfterMetadataChange() async throws {
        let token = try ClientToken(
            rawValue: "rmm_" + String(repeating: "a", count: 64)
        )
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let managedROMDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: managedROMDirectory)
        }

        let expectedData = Data(repeating: 0x42, count: 1_024)
        let service = RomMLibraryService(
            api: MockRomMClient(
                token: token,
                user: RomMUser(
                    id: 1,
                    username: "kenneth",
                    scopes: ["roms.read"]
                ),
                downloadData: expectedData
            ),
            credentialStore: credentials,
            managedROMDirectory: managedROMDirectory
        )
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let downloadedGame = mockGameDetails(
            id: 1_134,
            updatedAt: "2026-07-26T09:02:35+00:00"
        )
        let downloadedURL = try await service.downloadGame(
            downloadedGame,
            in: session
        )

        // Recreate the directory layout used before cache identities stopped
        // depending on the volatile RomM record timestamp.
        let legacyVersion = "\(downloadedGame.fileSizeBytes)-\(downloadedGame.updatedAt)"
        let legacyDigest = SHA256.hash(data: Data(legacyVersion.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let legacyDirectory = downloadedURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: legacyDigest, directoryHint: .isDirectory)
        try FileManager.default.moveItem(
            at: downloadedURL.deletingLastPathComponent(),
            to: legacyDirectory
        )

        await credentials.removeToken()
        let refreshedGame = mockGameDetails(
            id: downloadedGame.id,
            updatedAt: "2026-07-26T15:09:24+00:00"
        )
        let preparedURL = try await service.prepareGameForPlay(
            refreshedGame,
            in: session,
            supportedFileExtensions: ["gb"]
        )

        #expect(preparedURL.path.hasPrefix(legacyDirectory.path))
        #expect(try Data(contentsOf: preparedURL) == expectedData)
        #expect(await service.managedDownloadedGameIDs(in: session) == [1_134])
    }

    @Test("Preserves archives for cores that load them as game content")
    func preservesCoreNativeArchive() async throws {
        let token = try ClientToken(
            rawValue: "rmm_" + String(repeating: "a", count: 64)
        )
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let runtimeCacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedROMDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: runtimeCacheDirectory)
            try? FileManager.default.removeItem(at: managedROMDirectory)
        }

        let archiveData = Data(repeating: 0x5A, count: 1_024)
        let service = RomMLibraryService(
            api: MockRomMClient(
                token: token,
                user: RomMUser(
                    id: 1,
                    username: "kenneth",
                    scopes: ["roms.read"]
                ),
                downloadData: archiveData
            ),
            credentialStore: credentials,
            managedROMDirectory: managedROMDirectory,
            runtimeCacheDirectory: runtimeCacheDirectory
        )
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let game = mockGameDetails(
            id: 1_942,
            fileName: "1942.zip",
            systemName: "Arcade"
        )

        let contentURL = try await service.prepareGameForPlay(
            game,
            in: session,
            supportedFileExtensions: ["zip", "7z"],
            loadsArchivesDirectly: true
        )

        #expect(contentURL.pathExtension == "zip")
        #expect(try Data(contentsOf: contentURL) == archiveData)
        #expect(
            !FileManager.default.fileExists(
                atPath: contentURL
                    .deletingLastPathComponent()
                    .appending(path: "Extracted", directoryHint: .isDirectory)
                    .path
            )
        )
    }

    @Test("Caches verified RomM system firmware for offline playback")
    func cachesSystemFirmware() async throws {
        let token = try ClientToken(
            rawValue: "rmm_" + String(repeating: "f", count: 64)
        )
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let data = Data("verified firmware".utf8)
        let sha1 = Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let firmware = RomMFirmware(
            id: 9,
            fileName: "bios.test",
            fileSizeBytes: Int64(data.count),
            sha1Hash: sha1,
            isVerified: true,
            isMissingFromFileSystem: false
        )
        let requirement = LibretroCoreManifest.Core.Firmware(
            id: "test-bios",
            fileName: "bios.test",
            description: "Test BIOS",
            required: true,
            sha256: [],
            sha1: [sha1]
        )
        let api = MockRomMClient(
            token: token,
            user: RomMUser(
                id: 1,
                username: "kenneth",
                scopes: ["firmware.read"]
            ),
            firmwareFiles: [firmware: data]
        )
        let session = ServerSession(
            serverURL: try ServerURL("https://romm.example.com"),
            username: "kenneth"
        )
        let service = RomMLibraryService(
            api: api,
            credentialStore: credentials,
            firmwareDirectory: directory
        )

        let systemDirectory = try #require(
            try await service.prepareFirmwareForPlay(
                for: 12,
                requirements: [requirement],
                in: session
            )
        )
        let cachedURL = systemDirectory.appending(path: "bios.test")
        #expect(try Data(contentsOf: cachedURL) == data)

        let mismatchedCredentials = MemoryCredentialStore()
        await mismatchedCredentials.save(token)
        let mismatchedFirmware = RomMFirmware(
            id: 10,
            fileName: "bios.test",
            fileSizeBytes: Int64(data.count),
            sha1Hash: String(repeating: "0", count: 40),
            isVerified: true,
            isMissingFromFileSystem: false
        )
        let mismatchedService = RomMLibraryService(
            api: MockRomMClient(
                token: token,
                user: RomMUser(
                    id: 1,
                    username: "kenneth",
                    scopes: ["firmware.read"]
                ),
                firmwareFiles: [mismatchedFirmware: data]
            ),
            credentialStore: mismatchedCredentials,
            firmwareDirectory: directory.appending(
                path: "Mismatched",
                directoryHint: .isDirectory
            )
        )
        await #expect(throws: LibraryServiceError.self) {
            try await mismatchedService.prepareFirmwareForPlay(
                for: 12,
                requirements: [
                    .init(
                        id: "remote-hash-test",
                        fileName: "bios.test",
                        description: "Test BIOS",
                        required: true,
                        sha256: [],
                        sha1: nil
                    )
                ],
                in: session
            )
        }

        await credentials.removeToken()
        let relaunchedService = RomMLibraryService(
            api: MockRomMClient(
                token: token,
                user: RomMUser(id: 1, username: "kenneth", scopes: [])
            ),
            credentialStore: credentials,
            firmwareDirectory: directory
        )
        let offlineDirectory = try await relaunchedService.prepareFirmwareForPlay(
            for: 12,
            requirements: [requirement],
            in: session
        )
        #expect(offlineDirectory == systemDirectory)
        #expect(try Data(contentsOf: cachedURL) == data)
    }

    @Test("Imports the newest available cartridge save and uploads only local changes")
    func synchronizesCartridgeSaveMemory() async throws {
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "b", count: 64))
        let credentials = MemoryCredentialStore()
        await credentials.save(token)
        let saveDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: saveDirectory)
        }

        let serverURL = try ServerURL("https://romm.example.com")
        let importedData = Data(repeating: 0x42, count: 2_048)
        let changedData = Data(repeating: 0x7A, count: 2_048)
        let newerRemoteData = Data(repeating: 0x55, count: 2_048)
        let api = SaveSyncMockRomMClient(
            token: token,
            availableSaves: [
                141: importedData,
                143: newerRemoteData,
            ]
        )
        let service = RomMLibraryService(
            api: api,
            credentialStore: credentials,
            saveDirectory: saveDirectory
        )
        let session = ServerSession(
            serverURL: serverURL,
            username: "kenneth"
        )

        func save(id: Int, updatedAt: Date) -> GameSaveDataItem {
            GameSaveDataItem(
                id: id,
                kind: .save,
                fileName: "Super Mario World.srm",
                fileExtension: "srm",
                filePath: "saves/SNES",
                fullPath: "saves/SNES/Super Mario World.srm",
                downloadURL: serverURL.resourceURL(
                    for: "/api/saves/\(id)/content"
                ),
                fileSizeBytes: 2_048,
                isMissingFromFileSystem: false,
                createdAt: updatedAt,
                updatedAt: updatedAt,
                emulator: "Snes9x",
                slot: "autosave",
                contentHash: "remote-\(id)",
                isPublic: false,
                screenshotURL: nil
            )
        }

        let game = mockGameDetails(
            id: 1175,
            fileName: "Super Mario World (U) [!].sfc",
            systemName: "Super Nintendo Entertainment System",
            saves: [
                save(id: 142, updatedAt: Date(timeIntervalSince1970: 2_000)),
                save(id: 141, updatedAt: Date(timeIntervalSince1970: 1_000)),
            ]
        )
        let prepared = try await service.prepareCartridgeSaveForPlay(
            game,
            in: session,
            emulator: "OpenVault"
        )
        let configuration = try #require(prepared)

        #expect(await api.downloadedSaveIDs == [142, 141])
        #expect(try Data(contentsOf: configuration.localSaveURL) == importedData)
        #expect(configuration.uploadFileName == "Super Mario World (U) [!].srm")

        #expect(
            try await service.syncCartridgeSaveAfterPlay(configuration)
                == .unchanged
        )
        #expect(await api.uploadedSaves.isEmpty)

        try changedData.write(to: configuration.localSaveURL, options: .atomic)
        #expect(
            try await service.syncCartridgeSaveAfterPlay(configuration)
                == .uploaded
        )
        #expect(await api.uploadedSaves == [changedData])

        #expect(
            try await service.syncCartridgeSaveAfterPlay(configuration)
                == .unchanged
        )
        #expect(await api.uploadedSaves.count == 1)

        let newerRemoteGame = mockGameDetails(
            id: game.id,
            fileName: game.fileName,
            systemName: game.systemName,
            saves: [
                save(id: 143, updatedAt: Date(timeIntervalSince1970: 4_000))
            ]
        )
        await api.setLatestGameDetails(newerRemoteGame)
        let refreshCountBeforeLaunch = await api.gameDetailsRequestCount
        _ = try await service.prepareCartridgeSaveForPlay(
            game,
            in: session,
            emulator: "OpenVault"
        )
        let refreshedLaunchCount = await api.gameDetailsRequestCount
        #expect(refreshedLaunchCount == refreshCountBeforeLaunch + 1)
        #expect(await api.downloadedSaveIDs == [142, 141, 143])
        #expect(
            try Data(contentsOf: configuration.localSaveURL)
                == newerRemoteData
        )

        let unsynchronizedData = Data(repeating: 0x33, count: 2_048)
        try unsynchronizedData.write(
            to: configuration.localSaveURL,
            options: .atomic
        )
        let downloadCount = await api.downloadedSaveIDs.count
        let refreshCountBeforeUnsynchronizedLaunch =
            await api.gameDetailsRequestCount
        _ = try await service.prepareCartridgeSaveForPlay(
            game,
            in: session,
            emulator: "OpenVault"
        )
        let offlineSafeLaunchCount = await api.gameDetailsRequestCount
        #expect(
            offlineSafeLaunchCount
                == refreshCountBeforeUnsynchronizedLaunch + 1
        )
        #expect(await api.downloadedSaveIDs.count == downloadCount)
        #expect(
            try Data(contentsOf: configuration.localSaveURL)
                == unsynchronizedData
        )
    }
}

private actor SaveSyncMockRomMClient: RomMClient {
    let token: ClientToken
    let availableSaves: [Int: Data]
    private var latestGameDetails: GameDetails?
    private(set) var gameDetailsRequestCount = 0
    private(set) var downloadedSaveIDs: [Int] = []
    private(set) var uploadedSaves: [Data] = []

    init(token: ClientToken, availableSaves: [Int: Data]) {
        self.token = token
        self.availableSaves = availableSaves
    }

    func verifyServer(at serverURL: ServerURL) {}

    func exchange(
        pairingCode: PairingCode,
        at serverURL: ServerURL
    ) -> ClientToken {
        token
    }

    func currentUser(
        at serverURL: ServerURL,
        token: ClientToken
    ) -> RomMUser {
        RomMUser(
            id: 1,
            username: "kenneth",
            scopes: ["assets.read", "assets.write"]
        )
    }

    func systems(
        at serverURL: ServerURL,
        token: ClientToken
    ) -> [LibrarySystem] {
        []
    }

    func collections(
        at serverURL: ServerURL,
        token: ClientToken
    ) -> [LibraryCollection] {
        []
    }

    func games(
        at serverURL: ServerURL,
        token: ClientToken,
        matching filter: LibraryFilter,
        searchTerm: String?,
        offset: Int,
        limit: Int
    ) -> GamePage {
        GamePage(games: [], total: 0, limit: limit, offset: offset)
    }

    func gameDetails(
        for gameID: Int,
        at serverURL: ServerURL,
        token: ClientToken
    ) throws -> GameDetails {
        gameDetailsRequestCount += 1
        guard let latestGameDetails else {
            throw RomMAPIError.notFound
        }
        return latestGameDetails
    }

    func setLatestGameDetails(_ details: GameDetails) {
        latestGameDetails = details
    }

    func updateGameUserMetadata(
        _ metadata: GameUserMetadata,
        for gameID: Int,
        at serverURL: ServerURL,
        token: ClientToken
    ) -> GameUserMetadata {
        metadata
    }

    func downloadGame(
        for gameID: Int,
        fileName: String,
        at serverURL: ServerURL,
        token: ClientToken
    ) throws -> RomMDownload {
        throw RomMAPIError.notFound
    }

    func downloadSave(
        _ save: GameSaveDataItem,
        at serverURL: ServerURL,
        token: ClientToken
    ) throws -> RomMDownload {
        downloadedSaveIDs.append(save.id)
        guard let data = availableSaves[save.id] else {
            throw RomMAPIError.notFound
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try data.write(to: temporaryURL)
        return RomMDownload(
            temporaryFileURL: temporaryURL,
            suggestedFileName: save.fileName
        )
    }

    func uploadSave(
        _ data: Data,
        fileName: String,
        for gameID: Int,
        emulator: String,
        slot: String,
        at serverURL: ServerURL,
        token: ClientToken
    ) -> GameSaveDataItem {
        uploadedSaves.append(data)
        let id = 900 + uploadedSaves.count
        return GameSaveDataItem(
            id: id,
            kind: .save,
            fileName: fileName,
            fileExtension: URL(fileURLWithPath: fileName).pathExtension,
            filePath: "saves/SNES",
            fullPath: "saves/SNES/\(fileName)",
            downloadURL: serverURL.resourceURL(
                for: "/api/saves/\(id)/content"
            ),
            fileSizeBytes: Int64(data.count),
            isMissingFromFileSystem: false,
            createdAt: Date(timeIntervalSince1970: 3_000),
            updatedAt: Date(timeIntervalSince1970: 3_000),
            emulator: emulator,
            slot: slot,
            contentHash: "uploaded-\(id)",
            isPublic: false,
            screenshotURL: nil
        )
    }
}

private struct MockRomMClient: RomMClient {
    let token: ClientToken
    let user: RomMUser
    var downloadData = Data("downloaded".utf8)
    var firmwareFiles: [RomMFirmware: Data] = [:]
    var updatedCollection: LibraryCollection? = nil

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

    func updateCollectionMembership(
        collectionID: Int,
        gameIDs: [Int],
        adding: Bool,
        at serverURL: ServerURL,
        token: ClientToken
    ) throws -> LibraryCollection {
        guard let updatedCollection else {
            throw RomMAPIError.invalidResponse
        }
        return updatedCollection
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

    func firmware(
        for platformID: Int,
        at serverURL: ServerURL,
        token: ClientToken
    ) -> [RomMFirmware] {
        Array(firmwareFiles.keys)
    }

    func downloadFirmware(
        _ firmware: RomMFirmware,
        at serverURL: ServerURL,
        token: ClientToken
    ) throws -> RomMDownload {
        guard let data = firmwareFiles[firmware] else {
            throw RomMAPIError.notFound
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try data.write(to: temporaryURL)
        return RomMDownload(
            temporaryFileURL: temporaryURL,
            suggestedFileName: firmware.fileName
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
    private let blockedDownloadID: Int?
    private var localCachePurgeCount = 0
    private var downloadedIDs: Set<Int> = []
    private var downloadOrder: [Int] = []
    private var downloadStartWaiters:
        [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var blockedDownloadContinuation: CheckedContinuation<Void, Never>?

    init(
        allGames: [GameSummary]? = nil,
        rejectsMetadataUpdates: Bool = false,
        blockedDownloadID: Int? = nil
    ) {
        self.allGames = allGames ?? Self.defaultGames
        self.rejectsMetadataUpdates = rejectsMetadataUpdates
        self.blockedDownloadID = blockedDownloadID
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
        let synchronizedGames = allGames
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
                gameCount: min(5, synchronizedGames.count),
                virtualType: collection.virtualType
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

    func downloadGame(
        _ game: GameDetails,
        in session: ServerSession
    ) async -> URL {
        downloadOrder.append(game.id)
        let waiters = downloadStartWaiters.removeValue(forKey: game.id) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        if game.id == blockedDownloadID {
            await withCheckedContinuation {
                blockedDownloadContinuation = $0
            }
        }
        downloadedIDs.insert(game.id)
        return FileManager.default.temporaryDirectory.appending(path: game.fileName)
    }

    func waitUntilDownloadStarts(gameID: Int) async {
        guard !downloadOrder.contains(gameID) else {
            return
        }
        await withCheckedContinuation {
            downloadStartWaiters[gameID, default: []].append($0)
        }
    }

    func resumeBlockedDownload() {
        blockedDownloadContinuation?.resume()
        blockedDownloadContinuation = nil
    }

    func recordedDownloadOrder() -> [Int] {
        downloadOrder
    }

    func removeDownloadedGame(withID gameID: Int, in session: ServerSession) {
        downloadedIDs.remove(gameID)
    }

    func exportGame(_ game: GameDetails, in session: ServerSession) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Exported-\(game.fileName)")
    }

    func downloadedGameIDs(in session: ServerSession) async -> Set<Int> {
        downloadedIDs
    }

    func deleteGames(
        withIDs gameIDs: [Int],
        deletingFilesFromServer: Bool,
        in session: ServerSession
    ) -> GameDeletionResult {
        GameDeletionResult(
            successfulItemCount: Set(gameIDs).count,
            failedItemCount: 0,
            errors: []
        )
    }

    func resourceRequest(for url: URL?, in session: ServerSession) -> URLRequest? {
        nil
    }
}

private actor RecordingArtworkCache: ArtworkCaching {
    private var requestedGameIDs: [Int]?
    private var continuation: CheckedContinuation<[Int], Never>?

    func cacheArtwork(
        for games: [GameSummary],
        in session: ServerSession,
        using service: any LibraryServing,
        onProgress: @escaping @Sendable (ArtworkCacheProgress) async -> Void
    ) async {
        let artworkCount = Set(games.compactMap(\.coverURL)).count
        await onProgress(
            ArtworkCacheProgress(
                completedCount: artworkCount,
                totalCount: artworkCount,
                failedCount: 0
            )
        )

        let gameIDs = games.map(\.id)
        requestedGameIDs = gameIDs
        continuation?.resume(returning: gameIDs)
        continuation = nil
    }

    func waitForRequest() async -> [Int] {
        if let requestedGameIDs {
            return requestedGameIDs
        }
        return await withCheckedContinuation {
            continuation = $0
        }
    }
}

func mockGameDetails(
    id: Int,
    fileName: String? = nil,
    systemName: String = "Game Boy",
    saves: [GameSaveDataItem] = [],
    updatedAt: String = ""
) -> GameDetails {
    let resolvedFileName = fileName ?? "Game \(id).gb"
    return GameDetails(
        id: id,
        name: "Game \(id)",
        systemID: 1,
        systemName: systemName,
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
        fileName: resolvedFileName,
        fileExtension: URL(fileURLWithPath: resolvedFileName).pathExtension,
        filePath: "roms/GB",
        fullPath: "roms/GB/\(resolvedFileName)",
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
        updatedAt: updatedAt,
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
        saves: saves,
        states: [],
        contentCounts: GameContentCounts(
            siblingGames: 0,
            saves: saves.count,
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

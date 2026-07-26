import Foundation
import Testing

@testable import OpenVault

@Suite("Offline library cache")
struct LibraryCacheTests {
  @Test("Persists a server-scoped snapshot and full game details")
  func persistsSnapshotAndDetails() async throws {
    let cache = SwiftDataLibraryCache(isStoredInMemoryOnly: true)
    let serverURL = try ServerURL("https://romm.example.com")
    let otherServerURL = try ServerURL("https://other.example.com")
    let snapshot = testLibrarySnapshot()
    let details = mockGameDetails(id: 1)

    try await cache.replaceSnapshot(snapshot, for: serverURL)
    try await cache.saveGameDetails(details, for: serverURL)

    #expect(try await cache.snapshot(for: serverURL) == snapshot)
    #expect(try await cache.snapshot(for: otherServerURL) == nil)
    #expect(try await cache.gameDetails(for: 1, serverURL: serverURL) == details)
    #expect(try await cache.gameDetails(for: 1, serverURL: otherServerURL) == nil)
  }

  @Test("Serves cached metadata and details when RomM is unavailable")
  func servesCacheWhenServerIsUnavailable() async throws {
    let serverURL = try ServerURL("https://romm.example.com")
    let session = ServerSession(serverURL: serverURL, username: "kenneth")
    let snapshot = testLibrarySnapshot()
    let details = mockGameDetails(id: 1)
    let cache = InMemoryLibraryCache()
    await cache.replaceSnapshot(snapshot, for: serverURL)
    await cache.saveGameDetails(details, for: serverURL)

    let credentials = TestCredentialStore(
      token: try ClientToken(
        rawValue: "rmm_" + String(repeating: "a", count: 64)
      )
    )
    let service = RomMLibraryService(
      api: UnavailableRomMClient(),
      credentialStore: credentials,
      cache: cache
    )

    #expect(try await service.systems(in: session) == snapshot.systems)
    #expect(
      try await service.games(
        in: session,
        matching: .collection(.regular(10)),
        searchTerm: "Tetris",
        offset: 0,
        limit: 60
      ).games.map(\.name) == ["Tetris"]
    )
    #expect(try await service.gameDetails(for: 1, in: session) == details)
  }

  @Test("Commits a complete synchronized snapshot and excludes BIOS records")
  func commitsCompleteSnapshot() async throws {
    let serverURL = try ServerURL("https://romm.example.com")
    let session = ServerSession(serverURL: serverURL, username: "kenneth")
    let cache = InMemoryLibraryCache()
    let credentials = TestCredentialStore(
      token: try ClientToken(
        rawValue: "rmm_" + String(repeating: "b", count: 64)
      )
    )
    let service = RomMLibraryService(
      api: SynchronizationRomMClient(),
      credentialStore: credentials,
      cache: cache,
      now: { Date(timeIntervalSince1970: 2_000) }
    )

    let snapshot = try await service.synchronizeLibrary(in: session) { _ in }

    #expect(snapshot.games.map(\.name) == ["Tetris", "Metroid"])
    #expect(snapshot.systems.first?.gameCount == 2)
    #expect(snapshot.collections.first?.gameCount == 1)
    #expect(snapshot.collectionMemberships.first?.gameIDs == [1])
    #expect(snapshot.games.first(where: { $0.id == 1 })?.hasSave == true)
    #expect(snapshot.games.first(where: { $0.id == 2 })?.hasState == true)
    #expect(await cache.snapshot(for: serverURL) == snapshot)
  }

  @Test("Does not replace a good snapshot after a failed synchronization")
  func keepsPreviousSnapshotAfterSyncFailure() async throws {
    let serverURL = try ServerURL("https://romm.example.com")
    let session = ServerSession(serverURL: serverURL, username: "kenneth")
    let cache = InMemoryLibraryCache()
    let previousSnapshot = testLibrarySnapshot()
    await cache.replaceSnapshot(previousSnapshot, for: serverURL)
    let credentials = TestCredentialStore(
      token: try ClientToken(
        rawValue: "rmm_" + String(repeating: "c", count: 64)
      )
    )
    let service = RomMLibraryService(
      api: UnavailableRomMClient(),
      credentialStore: credentials,
      cache: cache
    )

    await #expect(throws: URLError.self) {
      try await service.synchronizeLibrary(in: session) { _ in }
    }

    #expect(await cache.snapshot(for: serverURL) == previousSnapshot)
  }

  @Test("Purges cached library metadata and game details")
  func purgesCachedLibraryData() async throws {
    let serverURL = try ServerURL("https://romm.example.com")
    let cache = InMemoryLibraryCache()
    await cache.replaceSnapshot(testLibrarySnapshot(), for: serverURL)
    await cache.saveGameDetails(mockGameDetails(id: 1), for: serverURL)
    let credentials = TestCredentialStore(
      token: try ClientToken(
        rawValue: "rmm_" + String(repeating: "e", count: 64)
      )
    )
    let service = RomMLibraryService(
      api: UnavailableRomMClient(),
      credentialStore: credentials,
      cache: cache
    )

    try await service.purgeLocalCache()

    #expect(await cache.snapshot(for: serverURL) == nil)
    #expect(await cache.gameDetails(for: 1, serverURL: serverURL) == nil)
  }

  @MainActor
  @Test("Keeps the cached library visible after a failed refresh")
  func keepsCacheAfterRefreshFailure() async throws {
    let session = ServerSession(
      serverURL: try ServerURL("https://romm.example.com"),
      username: "kenneth"
    )
    let snapshot = testLibrarySnapshot()
    let model = LibraryModel(
      session: session,
      service: OfflineLibraryService(snapshot: snapshot)
    )

    await model.load()

    #expect(model.displayedGames.map(\.name) == ["Tetris", "Metroid"])
    #expect(model.lastSuccessfulSync == snapshot.synchronizedAt)
    #expect(model.isShowingStaleData)
    #expect(model.refreshErrorMessage != nil)
    #expect(model.errorMessage == nil)
  }
}

private actor TestCredentialStore: CredentialStoring {
  private var token: ClientToken?

  init(token: ClientToken?) {
    self.token = token
  }

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

private struct UnavailableRomMClient: RomMClient {
  func verifyServer(at serverURL: ServerURL) async throws {
    throw URLError(.cannotConnectToHost)
  }

  func exchange(pairingCode: PairingCode, at serverURL: ServerURL) async throws -> ClientToken {
    throw URLError(.cannotConnectToHost)
  }

  func currentUser(at serverURL: ServerURL, token: ClientToken) async throws -> RomMUser {
    throw URLError(.cannotConnectToHost)
  }

  func systems(at serverURL: ServerURL, token: ClientToken) async throws -> [LibrarySystem] {
    throw URLError(.cannotConnectToHost)
  }

  func collections(
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> [LibraryCollection] {
    throw URLError(.cannotConnectToHost)
  }

  func games(
    at serverURL: ServerURL,
    token: ClientToken,
    matching filter: LibraryFilter,
    searchTerm: String?,
    offset: Int,
    limit: Int
  ) async throws -> GamePage {
    throw URLError(.cannotConnectToHost)
  }

  func gameDetails(
    for gameID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameDetails {
    throw URLError(.cannotConnectToHost)
  }

  func updateGameUserMetadata(
    _ metadata: GameUserMetadata,
    for gameID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameUserMetadata {
    throw URLError(.cannotConnectToHost)
  }

  func downloadGame(
    for gameID: Int,
    fileName: String,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> RomMDownload {
    throw URLError(.cannotConnectToHost)
  }
}

private struct SynchronizationRomMClient: RomMClient {
  private let allGames = [
    GameSummary(
      id: 1,
      name: "Tetris",
      systemID: 1,
      systemName: "Game Boy",
      coverURL: nil
    ),
    GameSummary(
      id: 2,
      name: "Metroid",
      systemID: 1,
      systemName: "Game Boy",
      coverURL: nil
    ),
    GameSummary(
      id: 3,
      name: "[BIOS] Game Boy",
      systemID: 1,
      systemName: "Game Boy",
      coverURL: nil,
      isBIOS: true
    ),
  ]

  func verifyServer(at serverURL: ServerURL) async throws {}

  func exchange(pairingCode: PairingCode, at serverURL: ServerURL) async throws -> ClientToken {
    try ClientToken(rawValue: "rmm_" + String(repeating: "d", count: 64))
  }

  func currentUser(at serverURL: ServerURL, token: ClientToken) async throws -> RomMUser {
    RomMUser(id: 1, username: "kenneth", scopes: [])
  }

  func systems(at serverURL: ServerURL, token: ClientToken) async throws -> [LibrarySystem] {
    [
      LibrarySystem(id: 1, name: "Game Boy", gameCount: 3)
    ]
  }

  func collections(
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> [LibraryCollection] {
    [
      LibraryCollection(id: .regular(10), name: "Favorites", gameCount: 2)
    ]
  }

  func gameIDsWithSaveData(
    _ kind: GameSaveDataKind,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> Set<Int> {
    switch kind {
    case .save:
      [1]
    case .state:
      [2]
    }
  }

  func games(
    at serverURL: ServerURL,
    token: ClientToken,
    matching filter: LibraryFilter,
    searchTerm: String?,
    offset: Int,
    limit: Int
  ) async throws -> GamePage {
    let filtered: [GameSummary]
    switch filter {
    case .allGames, .system:
      filtered = allGames
    case .collection:
      filtered = [allGames[0], allGames[2]]
    }

    return GamePage(
      games: Array(filtered.dropFirst(offset).prefix(limit)),
      total: filtered.count,
      limit: limit,
      offset: offset
    )
  }

  func gameDetails(
    for gameID: Int,
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> GameDetails {
    mockGameDetails(id: gameID)
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
    throw URLError(.unsupportedURL)
  }
}

private actor OfflineLibraryService: LibraryServing {
  let snapshot: LibrarySnapshot

  init(snapshot: LibrarySnapshot) {
    self.snapshot = snapshot
  }

  func cachedSnapshot(in session: ServerSession) -> LibrarySnapshot? {
    snapshot
  }

  func purgeLocalCache() {}

  func synchronizeLibrary(
    in session: ServerSession,
    onProgress: @escaping @Sendable (LibrarySyncProgress) async -> Void
  ) async throws -> LibrarySnapshot {
    throw URLError(.notConnectedToInternet)
  }

  func systems(in session: ServerSession) -> [LibrarySystem] {
    snapshot.systems
  }

  func collections(in session: ServerSession) -> [LibraryCollection] {
    snapshot.collections
  }

  func games(
    in session: ServerSession,
    matching filter: LibraryFilter,
    searchTerm: String?,
    offset: Int,
    limit: Int
  ) -> GamePage {
    snapshot.page(
      matching: filter,
      searchTerm: searchTerm,
      offset: offset,
      limit: limit
    )
  }

  func systemHasArtwork(_ systemID: Int, in session: ServerSession) -> Bool {
    snapshot.games.contains {
      $0.systemID == systemID && $0.coverURL != nil
    }
  }

  func gameDetails(for gameID: Int, in session: ServerSession) throws -> GameDetails {
    throw URLError(.notConnectedToInternet)
  }

  func updateUserMetadata(
    _ metadata: GameUserMetadata,
    for game: GameDetails,
    in session: ServerSession
  ) throws -> GameDetails {
    throw URLError(.notConnectedToInternet)
  }

  func downloadGame(_ game: GameDetails, in session: ServerSession) throws -> URL {
    throw URLError(.notConnectedToInternet)
  }

  func artworkRequest(for game: GameSummary, in session: ServerSession) -> URLRequest? {
    nil
  }

  func resourceRequest(for url: URL?, in session: ServerSession) -> URLRequest? {
    nil
  }
}

func testLibrarySnapshot() -> LibrarySnapshot {
  let games = [
    GameSummary(
      id: 1,
      name: "Tetris",
      systemID: 1,
      systemName: "Game Boy",
      coverURL: URL(string: "https://romm.example.com/tetris.webp")
    ),
    GameSummary(
      id: 2,
      name: "Metroid",
      systemID: 2,
      systemName: "Nintendo Entertainment System",
      coverURL: nil
    ),
  ]

  return LibrarySnapshot(
    synchronizedAt: Date(timeIntervalSince1970: 1_000),
    systems: [
      LibrarySystem(id: 1, name: "Game Boy", gameCount: 1),
      LibrarySystem(
        id: 2,
        name: "Nintendo Entertainment System",
        gameCount: 1
      ),
    ],
    collections: [
      LibraryCollection(id: .regular(10), name: "Favorites", gameCount: 1)
    ],
    games: games,
    collectionMemberships: [
      LibrarySnapshot.CollectionMembership(
        collectionID: .regular(10),
        gameIDs: [1]
      )
    ]
  )
}

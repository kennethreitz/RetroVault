import AppKit
import Foundation
import Testing

@testable import OpenVault

@Suite("Artwork sorting")
struct ArtworkSortTests {
  @Test("Sorts artwork alphabetically, by addition, or by release year")
  func sortsArtworkGames() {
    let olderGame = GameSummary(
      id: 1,
      name: "Zelda",
      systemID: 1,
      systemName: "Nintendo",
      coverURL: nil,
      releaseYear: 1991,
      createdAt: "2025-01-02T03:04:05Z"
    )
    let newerGame = GameSummary(
      id: 2,
      name: "Asteroids",
      systemID: 1,
      systemName: "Nintendo",
      coverURL: nil,
      releaseYear: 2001,
      createdAt: "2026-07-26T12:34:56.789Z"
    )
    let unknownDateGame = GameSummary(
      id: 3,
      name: "Metroid",
      systemID: 1,
      systemName: "Nintendo",
      coverURL: nil
    )

    let games = [olderGame, unknownDateGame, newerGame]

    #expect(
      ArtworkSort.alphabetical.sorted(games).map(\.name)
        == ["Asteroids", "Metroid", "Zelda"]
    )
    #expect(
      ArtworkSort.dateAdded.sorted(games).map(\.id)
        == [newerGame.id, olderGame.id, unknownDateGame.id]
    )
    #expect(
      ArtworkSort.releaseYear.sorted(games).map(\.id)
        == [newerGame.id, olderGame.id, unknownDateGame.id]
    )
  }

  @Test("Combines completed games with concurrent ROM byte progress")
  func calculatesBatchDownloadProgress() {
    let progress = LibraryDownloadProgress(
      processedGameCount: 1,
      totalGameCount: 4,
      currentGameID: 2,
      currentGameName: "Tetris",
      currentTransferProgress: RomMDownloadProgress(
        bytesReceived: 25,
        totalBytesExpected: 100
      ),
      failedGameCount: 0,
      activeGameCount: 2,
      activeTransferProgress: [
        2: RomMDownloadProgress(
          bytesReceived: 25,
          totalBytesExpected: 100
        ),
        3: RomMDownloadProgress(
          bytesReceived: 50,
          totalBytesExpected: 100
        ),
      ]
    )

    #expect(progress.currentGameNumber == 2)
    #expect(progress.fractionCompleted == 0.4375)
  }

  @Test("Prioritizes RomM favorites without changing secondary order")
  func prioritizesFavorites() {
    let games = [
      GameSummary(
        id: 1,
        name: "Asteroids",
        systemID: 1,
        systemName: "Atari 2600",
        coverURL: nil
      ),
      GameSummary(
        id: 2,
        name: "Centipede",
        systemID: 1,
        systemName: "Atari 2600",
        coverURL: nil
      ),
      GameSummary(
        id: 3,
        name: "Yars' Revenge",
        systemID: 1,
        systemName: "Atari 2600",
        coverURL: nil
      ),
    ]
    let favoriteCollection = LibraryCollection(
      id: .regular(10),
      name: "Favorites",
      gameCount: 2
    )
    let favoriteIDs = RomMFavorites.gameIDs(
      collections: [favoriteCollection],
      memberships: [
        LibrarySnapshot.CollectionMembership(
          collectionID: favoriteCollection.id,
          gameIDs: [2, 3]
        )
      ]
    )

    #expect(favoriteIDs == [2, 3])
    #expect(
      RomMFavorites.prioritizing(games, gameIDs: favoriteIDs).map(\.id)
        == [2, 3, 1]
    )
  }

  @Test("Adds a mixed Favorites selection and removes an all-favorite selection")
  func choosesFavoriteMembershipChange() {
    let favoriteGameIDs: Set<Int> = [1, 2]

    #expect(
      RomMFavorites.membershipChange(
        for: [1, 3],
        favoriteGameIDs: favoriteGameIDs
      ) == .add
    )
    #expect(
      RomMFavorites.membershipChange(
        for: [1, 2],
        favoriteGameIDs: favoriteGameIDs
      ) == .remove
    )
  }

  @Test("Replaces cached collection membership without changing library metadata")
  func replacesCollectionMembership() {
    let snapshot = LibrarySnapshot(
      synchronizedAt: Date(timeIntervalSince1970: 1_000),
      systems: [LibrarySystem(id: 1, name: "Test", gameCount: 3)],
      collections: [
        LibraryCollection(
          id: .regular(10),
          name: "Favorites",
          gameCount: 1,
          isFavorite: true
        )
      ],
      games: [
        GameSummary(
          id: 1,
          name: "One",
          systemID: 1,
          systemName: "Test",
          coverURL: nil
        ),
        GameSummary(
          id: 2,
          name: "Two",
          systemID: 1,
          systemName: "Test",
          coverURL: nil
        ),
        GameSummary(
          id: 3,
          name: "Three",
          systemID: 1,
          systemName: "Test",
          coverURL: nil
        ),
      ],
      collectionMemberships: [
        LibrarySnapshot.CollectionMembership(
          collectionID: .regular(10),
          gameIDs: [1]
        )
      ]
    )
    let updatedCollection = LibraryCollection(
      id: .regular(10),
      name: "Favorites",
      gameCount: 3,
      isFavorite: true,
      memberGameIDs: [1, 2, 2, 3]
    )

    let updated = snapshot.replacingCollectionMembership(
      with: updatedCollection,
      gameIDs: updatedCollection.memberGameIDs ?? []
    )

    #expect(updated.synchronizedAt == snapshot.synchronizedAt)
    #expect(updated.games == snapshot.games)
    #expect(updated.collections.first?.gameCount == 3)
    #expect(updated.collections.first?.isFavorite == true)
    #expect(updated.collectionMemberships.first?.gameIDs == [1, 2, 3])
  }
}

@Suite("Sidebar system sorting")
struct SidebarSystemSortTests {
  @Test("Sorts systems alphabetically or by descending game count")
  func sortsSidebarSystems() {
    let systems = [
      LibrarySystem(id: 1, name: "Game Boy", gameCount: 587),
      LibrarySystem(id: 2, name: "Atari 2600", gameCount: 443),
      LibrarySystem(id: 3, name: "DOS", gameCount: 3_061),
      LibrarySystem(id: 4, name: "Arcade", gameCount: 2_160),
    ]

    #expect(
      SidebarSystemSort.alphabetical.sorted(systems).map(\.name)
        == ["Arcade", "Atari 2600", "DOS", "Game Boy"]
    )
    #expect(
      SidebarSystemSort.gameCount.sorted(systems).map(\.name)
        == ["DOS", "Arcade", "Game Boy", "Atari 2600"]
    )
  }
}

@Suite("Library keyboard navigation")
struct LibraryKeyboardNavigationTests {
  @Test("Maps unmodified arrows and Return to library navigation")
  func mapsNavigationKeys() {
    #expect(
      LibraryKeyboardNavigation.command(
        forKeyCode: 126,
        modifierFlags: []
      ) == .up
    )
    #expect(
      LibraryKeyboardNavigation.command(
        forKeyCode: 125,
        modifierFlags: []
      ) == .down
    )
    #expect(
      LibraryKeyboardNavigation.command(
        forKeyCode: 123,
        modifierFlags: []
      ) == .left
    )
    #expect(
      LibraryKeyboardNavigation.command(
        forKeyCode: 124,
        modifierFlags: []
      ) == .right
    )
    #expect(
      LibraryKeyboardNavigation.command(
        forKeyCode: 36,
        modifierFlags: []
      ) == .activate
    )
    #expect(
      LibraryKeyboardNavigation.command(
        forKeyCode: 76,
        modifierFlags: [.numericPad]
      ) == .activate
    )
  }

  @Test("Leaves modified navigation keys to native controls")
  func preservesModifiedKeys() {
    #expect(
      LibraryKeyboardNavigation.command(
        forKeyCode: 125,
        modifierFlags: [.shift]
      ) == nil
    )
    #expect(
      LibraryKeyboardNavigation.command(
        forKeyCode: 123,
        modifierFlags: [.command]
      ) == nil
    )
    #expect(
      LibraryKeyboardNavigation.command(
        forKeyCode: 49,
        modifierFlags: []
      ) == nil
    )
  }
}

@Suite("Big Picture catalog")
struct BigPictureCatalogTests {
  @Test("Requires a matching core stamp for FAKE-08 quick states")
  func validatesFake08QuickStateCompatibility() {
    #expect(
      !LibretroQuickStateCompatibility.isCompatible(
        coreID: "libretro-fake08",
        expectedFingerprint: "new-core",
        storedFingerprint: nil
      )
    )
    #expect(
      !LibretroQuickStateCompatibility.isCompatible(
        coreID: "libretro-fake08",
        expectedFingerprint: "new-core",
        storedFingerprint: "old-core"
      )
    )
    #expect(
      LibretroQuickStateCompatibility.isCompatible(
        coreID: "libretro-fake08",
        expectedFingerprint: "new-core",
        storedFingerprint: "new-core"
      )
    )
    #expect(
      LibretroQuickStateCompatibility.isCompatible(
        coreID: "libretro-gambatte",
        expectedFingerprint: nil,
        storedFingerprint: nil
      )
    )
  }

  @Test("Does not resume a quick state older than RomM's cartridge save")
  func skipsStaleQuickStateAfterRomMSaveSync() {
    let quickStateDate = Date(timeIntervalSince1970: 1_000)
    let remoteSaveDate = Date(timeIntervalSince1970: 2_000)

    #expect(
      !LibretroQuickStateRestorePolicy.shouldRestore(
        requestAllowsRestore: true,
        remoteSaveUpdatedAt: remoteSaveDate,
        quickStateUpdatedAt: quickStateDate
      )
    )
    #expect(
      LibretroQuickStateRestorePolicy.shouldRestore(
        requestAllowsRestore: true,
        remoteSaveUpdatedAt: quickStateDate,
        quickStateUpdatedAt: remoteSaveDate
      )
    )
    #expect(
      LibretroQuickStateRestorePolicy.shouldRestore(
        requestAllowsRestore: true,
        remoteSaveUpdatedAt: nil,
        quickStateUpdatedAt: quickStateDate
      )
    )
    #expect(
      !LibretroQuickStateRestorePolicy.shouldRestore(
        requestAllowsRestore: false,
        remoteSaveUpdatedAt: quickStateDate,
        quickStateUpdatedAt: remoteSaveDate
      )
    )
  }

  @Test("Only advertises separate resume and play actions for save states")
  func presentsGameLaunchActions() {
    #expect(
      BigPictureGameLaunchPresentation.primaryActionTitle(
        hasSaveState: false
      ) == "Play"
    )
    #expect(
      !BigPictureGameLaunchPresentation.showsPlayFromBeginning(
        hasSaveState: false
      )
    )
    #expect(
      BigPictureGameLaunchPresentation.primaryActionTitle(
        hasSaveState: true
      ) == "Resume"
    )
    #expect(
      BigPictureGameLaunchPresentation.showsPlayFromBeginning(
        hasSaveState: true
      )
    )
  }

  @Test("Presents a useful system download action for every cache state")
  func presentsSystemDownloadActions() {
    #expect(
      BigPictureSystemDownloadPresentation.make(
        totalGameCount: 0,
        downloadedGameCount: 0
      ) == BigPictureSystemDownloadPresentation(
        action: .unavailable,
        title: "No Games Available",
        systemImage: "nosign"
      )
    )
    #expect(
      BigPictureSystemDownloadPresentation.make(
        totalGameCount: 10,
        downloadedGameCount: 0
      ) == BigPictureSystemDownloadPresentation(
        action: .download,
        title: "Download All 10 Games",
        systemImage: "arrow.down.circle"
      )
    )
    #expect(
      BigPictureSystemDownloadPresentation.make(
        totalGameCount: 10,
        downloadedGameCount: 4
      ) == BigPictureSystemDownloadPresentation(
        action: .download,
        title: "Download 6 Remaining Games",
        systemImage: "arrow.down.circle"
      )
    )
    #expect(
      BigPictureSystemDownloadPresentation.make(
        totalGameCount: 10,
        downloadedGameCount: 10
      ) == BigPictureSystemDownloadPresentation(
        action: .remove,
        title: "Remove All 10 Downloads",
        systemImage: "trash"
      )
    )
  }

  @Test("Uses immersive presentation only while fullscreen")
  func createsImmersivePresentationOptions() {
    let original: NSApplication.PresentationOptions = [
      .hideMenuBar,
      .hideDock,
      .disableAppleMenu,
    ]

    let immersive = BigPicturePresentationOptions.immersive(from: original)

    #expect(immersive.contains(.autoHideMenuBar))
    #expect(immersive.contains(.autoHideDock))
    #expect(!immersive.contains(.hideMenuBar))
    #expect(!immersive.contains(.hideDock))
    #expect(immersive.contains(.disableAppleMenu))

    let playback = BigPicturePresentationOptions.playbackImmersive(
      from: immersive
    )
    #expect(playback.contains(.hideMenuBar))
    #expect(playback.contains(.hideDock))
    #expect(!playback.contains(.autoHideMenuBar))
    #expect(!playback.contains(.autoHideDock))
  }

  @Test("Keeps native window controls available for optional fullscreen")
  @MainActor
  func configuresOptionalFullScreenWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 720),
      styleMask: [],
      backing: .buffered,
      defer: false
    )

    configureBigPictureWindow(window)

    #expect(window.styleMask.contains(.titled))
    #expect(window.styleMask.contains(.closable))
    #expect(window.styleMask.contains(.miniaturizable))
    #expect(window.styleMask.contains(.resizable))
    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    #expect(!window.collectionBehavior.contains(.fullScreenNone))
    #expect(window.backgroundColor == .black)
    #expect(window.acceptsMouseMovedEvents)
    #expect(window.isOpaque)
    #expect(!window.hasShadow)
    #expect(window.titlebarAppearsTransparent)
    #expect(window.titleVisibility == .hidden)
    #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
    #expect(window.standardWindowButton(.zoomButton)?.target === window)
    #expect(
      window.standardWindowButton(.zoomButton)?.action
        == #selector(NSWindow.toggleFullScreen(_:))
    )
  }

  @Test("Requests fullscreen only for the initial visible presentation")
  func requestsInitialFullScreenOnce() {
    var gate = BigPictureInitialFullScreenGate()

    let hiddenRequest = gate.shouldRequest(
      isWindowVisible: false,
      isFullScreen: false,
      preferenceEnabled: true
    )
    let initialRequest = gate.shouldRequest(
      isWindowVisible: true,
      isFullScreen: false,
      preferenceEnabled: true
    )
    let repeatedRequest = gate.shouldRequest(
      isWindowVisible: true,
      isFullScreen: false,
      preferenceEnabled: true
    )
    #expect(!hiddenRequest)
    #expect(initialRequest)
    #expect(!repeatedRequest)

    var alreadyFullScreen = BigPictureInitialFullScreenGate()
    let redundantRequest = alreadyFullScreen.shouldRequest(
      isWindowVisible: true,
      isFullScreen: true,
      preferenceEnabled: true
    )
    let requestAfterExiting = alreadyFullScreen.shouldRequest(
      isWindowVisible: true,
      isFullScreen: false,
      preferenceEnabled: true
    )
    #expect(!redundantRequest)
    #expect(!requestAfterExiting)

    var windowed = BigPictureInitialFullScreenGate()
    let disabledRequest = windowed.shouldRequest(
      isWindowVisible: true,
      isFullScreen: false,
      preferenceEnabled: false
    )
    let requestAfterEnabling = windowed.shouldRequest(
      isWindowVisible: true,
      isFullScreen: false,
      preferenceEnabled: true
    )
    #expect(!disabledRequest)
    #expect(!requestAfterEnabling)
  }

  @Test("Groups downloaded games into a browsable systems menu")
  func groupsDownloadedGamesBySystem() {
    let snes = GameSummary(
      id: 1,
      name: "Zelda",
      systemID: 1,
      systemName: "Super Nintendo Entertainment System",
      coverURL: nil
    )
    let otherSNES = GameSummary(
      id: 2,
      name: "Mario",
      systemID: 1,
      systemName: "Super Nintendo Entertainment System",
      coverURL: nil
    )
    let gameBoy = GameSummary(
      id: 3,
      name: "Tetris",
      systemID: 2,
      systemName: "Game Boy",
      coverURL: nil
    )
    let notDownloaded = GameSummary(
      id: 4,
      name: "Metroid",
      systemID: 3,
      systemName: "Nintendo Entertainment System",
      coverURL: nil
    )
    let catalog = BigPictureCatalog(
      source: BigPictureLibrarySource(
        synchronizedAt: nil,
        systems: [
          LibrarySystem(
            id: 1,
            name: "Super Nintendo Entertainment System",
            gameCount: 2
          ),
          LibrarySystem(id: 2, name: "Game Boy", gameCount: 1),
          LibrarySystem(
            id: 3,
            name: "Nintendo Entertainment System",
            gameCount: 1
          ),
        ],
        collections: [],
        games: [snes, otherSNES, gameBoy, notDownloaded],
        collectionMemberships: [],
        downloadedGameIDs: [1, 2, 3],
        playHistory: LocalPlayHistory()
      ),
      manifest: nil
    )

    // Only systems holding a download appear, in the library's own order.
    #expect(catalog.downloadedSystems.map(\.name) == [
      "Game Boy",
      "Super Nintendo Entertainment System",
    ])
    #expect(catalog.downloadedGameCount(inSystem: 1) == 2)
    #expect(catalog.downloadedGameCount(inSystem: 2) == 1)
    #expect(catalog.downloadedGameCount(inSystem: 3) == 0)

    #expect(
      catalog.games(in: .downloadedSystem(1)).map(\.name) == ["Mario", "Zelda"]
    )
    #expect(catalog.games(in: .downloadedSystem(2)).map(\.name) == ["Tetris"])
    #expect(catalog.games(in: .downloadedSystem(3)).isEmpty)
    // The flat list of everything downloaded stays reachable.
    #expect(catalog.downloadedGames.count == 3)
    #expect(catalog.title(for: .downloadedSystem(2)) == "Game Boy")
  }

  @Test("Builds recent, favorite, downloaded, system, and collection menus offline")
  func buildsControllerFirstCatalog() {
    let collectionID = LibraryCollection.ID.smart(11)
    let favoritesID = LibraryCollection.ID.regular(10)
    let olderGame = GameSummary(
      id: 1,
      name: "Zelda",
      systemID: 1,
      systemName: "Super Nintendo Entertainment System",
      coverURL: nil,
      createdAt: "2025-01-02T03:04:05Z"
    )
    let newerGame = GameSummary(
      id: 2,
      name: "Mario",
      systemID: 1,
      systemName: "Super Nintendo Entertainment System",
      coverURL: nil,
      createdAt: "2026-07-26T12:34:56.789Z"
    )
    let handheldGame = GameSummary(
      id: 3,
      name: "Tetris",
      systemID: 2,
      systemName: "Game Boy",
      coverURL: nil
    )
    let catalog = BigPictureCatalog(
      source: BigPictureLibrarySource(
        synchronizedAt: Date(timeIntervalSince1970: 1_000),
        systems: [
          LibrarySystem(
            id: 1,
            name: "Super Nintendo Entertainment System",
            gameCount: 2
          ),
          LibrarySystem(id: 2, name: "Game Boy", gameCount: 1),
          LibrarySystem(id: 3, name: "Empty", gameCount: 0),
        ],
        collections: [
          LibraryCollection(
            id: favoritesID,
            name: "Favorites",
            gameCount: 1
          ),
          LibraryCollection(
            id: collectionID,
            name: "Mario",
            gameCount: 2
          ),
        ],
        games: [olderGame, handheldGame, newerGame],
        collectionMemberships: [
          LibrarySnapshot.CollectionMembership(
            collectionID: favoritesID,
            gameIDs: [1]
          ),
          LibrarySnapshot.CollectionMembership(
            collectionID: collectionID,
            gameIDs: [1, 2]
          ),
        ],
        downloadedGameIDs: [3],
        playHistory: LocalPlayHistory()
      ),
      manifest: nil
    )

    #expect(
      catalog.systems.map(\.name) == [
        "Game Boy",
        "Super Nintendo Entertainment System",
      ])
    #expect(catalog.recentlyAddedGames.map(\.id) == [2, 1, 3])
    #expect(catalog.favoriteGames.map(\.id) == [1])
    #expect(catalog.downloadedGames.map(\.id) == [3])
    #expect(catalog.games(in: .favorites).map(\.id) == [1])
    #expect(catalog.games(in: .system(1)).map(\.id) == [1, 2])
    #expect(catalog.games(in: .collection(collectionID)).map(\.id) == [2, 1])
    #expect(catalog.favoriteGameIDs == [1])
    #expect(catalog.title(for: .favorites) == "Favorites")
    #expect(catalog.title(for: .collection(collectionID)) == "Mario")
  }

  @Test("Keeps only systems with a reviewed bundled core")
  func filtersUnsupportedSystems() throws {
    let repositoryURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let installation = try LibretroInstallation(
      manifestURL: repositoryURL
        .appending(path: "Libretro/CoreManifest.json"),
      coresDirectory: repositoryURL
        .appending(path: "Build/LibretroCores")
    )
    let source = BigPictureLibrarySource(
      synchronizedAt: nil,
      systems: [
        LibrarySystem(id: 1, name: "Game Boy", gameCount: 1),
        LibrarySystem(id: 2, name: "Dreamcast", gameCount: 1),
      ],
      collections: [],
      games: [
        GameSummary(
          id: 1,
          name: "Tetris",
          systemID: 1,
          systemName: "Game Boy",
          coverURL: nil
        ),
        GameSummary(
          id: 2,
          name: "Unsupported",
          systemID: 2,
          systemName: "Dreamcast",
          coverURL: nil
        ),
      ],
      collectionMemberships: [],
      downloadedGameIDs: [],
      playHistory: LocalPlayHistory()
    )

    // Stated rather than inherited: Dreamcast is only offered by an
    // experimental core, so leaving this to the running machine's preference
    // would make the test pass or fail depending on who ran it.
    let catalog = BigPictureCatalog(
      source: source,
      manifest: installation.manifest,
      includingExperimental: false
    )

    #expect(catalog.systems.map(\.name) == ["Game Boy"])
    #expect(catalog.recentlyAddedGames.map(\.id) == [1])
  }

  @Test("Repeats held controller navigation after a deliberate delay")
  func repeatsHeldControllerNavigation() {
    var navigation = BigPictureControllerNavigation()
    let up = BigPictureControllerState(isConnected: true, up: true)

    let initial = navigation.command(for: up, at: 10)
    let beforeDelay = navigation.command(for: up, at: 10.2)
    let firstRepeat = navigation.command(for: up, at: 10.35)
    let beforeInterval = navigation.command(for: up, at: 10.4)
    let secondRepeat = navigation.command(for: up, at: 10.45)
    let released = navigation.command(
      for: BigPictureControllerState(isConnected: true),
      at: 10.5
    )
    let reversed = navigation.command(
      for: BigPictureControllerState(isConnected: true, down: true),
      at: 10.51
    )

    #expect(initial == .up)
    #expect(beforeDelay == nil)
    #expect(firstRepeat == .up)
    #expect(beforeInterval == nil)
    #expect(secondRepeat == .up)
    #expect(released == nil)
    #expect(reversed == .down)
  }

  @Test("Repeats held Big Picture paging after a deliberate delay")
  func repeatsHeldBigPicturePaging() {
    var navigation = BigPictureControllerNavigation()
    let left = BigPictureControllerState(isConnected: true, left: true)

    #expect(navigation.command(for: left, at: 10) == .pageUp)
    #expect(navigation.command(for: left, at: 10.2) == nil)
    #expect(navigation.command(for: left, at: 10.35) == .pageUp)
    #expect(
      navigation.command(
        for: BigPictureControllerState(isConnected: true),
        at: 10.5
      ) == nil
    )

    let right = BigPictureControllerState(isConnected: true, right: true)
    #expect(navigation.command(for: right, at: 10.51) == .pageDown)
    #expect(navigation.command(for: right, at: 10.7) == nil)
    #expect(navigation.command(for: right, at: 10.86) == .pageDown)
  }

  @Test("Maps regular library controller navigation with directional repeat")
  func mapsRegularLibraryControllerNavigation() {
    var navigation = LibraryControllerNavigation()
    let up = BigPictureControllerState(isConnected: true, up: true)

    #expect(navigation.command(for: up, at: 10) == .up)
    #expect(navigation.command(for: up, at: 10.2) == nil)
    #expect(navigation.command(for: up, at: 10.35) == .up)
    #expect(
      navigation.command(
        for: BigPictureControllerState(isConnected: true),
        at: 10.5
      ) == nil
    )
    #expect(
      navigation.command(
        for: BigPictureControllerState(isConnected: true, left: true),
        at: 10.51
      ) == .left
    )
  }

  @Test("Maps regular library controller select and back on button edges")
  func mapsRegularLibraryControllerActions() {
    var navigation = LibraryControllerNavigation()
    let activate = BigPictureControllerState(
      isConnected: true,
      activate: true
    )

    #expect(navigation.command(for: activate, at: 20) == .activate)
    #expect(navigation.command(for: activate, at: 20.1) == nil)
    #expect(
      navigation.command(
        for: BigPictureControllerState(isConnected: true),
        at: 20.2
      ) == nil
    )
    #expect(
      navigation.command(
        for: BigPictureControllerState(isConnected: true, back: true),
        at: 20.3
      ) == .back
    )
  }

  @Test("Maps the controller Select button to Big Picture")
  func mapsControllerSelectToBigPicture() {
    var navigation = LibraryControllerNavigation()
    let select = BigPictureControllerState(
      isConnected: true,
      opensBigPicture: true
    )

    #expect(navigation.command(for: select, at: 30) == .openBigPicture)
    #expect(navigation.command(for: select, at: 30.1) == nil)
  }

  @Test("Maps controller actions and shoulders without repeating a hold")
  func mapsControllerNavigationActions() {
    var navigation = BigPictureControllerNavigation()

    let activate = navigation.command(
      for: BigPictureControllerState(isConnected: true, activate: true),
      at: 20
    )
    let heldActivate = navigation.command(
      for: BigPictureControllerState(isConnected: true, activate: true),
      at: 20.1
    )
    let start = navigation.command(
      for: BigPictureControllerState(
        isConnected: true,
        playsFromBeginning: true
      ),
      at: 20.2
    )
    let options = navigation.command(
      for: BigPictureControllerState(
        isConnected: true,
        opensGameOptions: true
      ),
      at: 20.25
    )
    let back = navigation.command(
      for: BigPictureControllerState(isConnected: true, back: true),
      at: 20.3
    )
    let pageUp = navigation.command(
      for: BigPictureControllerState(isConnected: true, pageUp: true),
      at: 20.4
    )
    let pageDown = navigation.command(
      for: BigPictureControllerState(isConnected: true, pageDown: true),
      at: 20.5
    )
    let left = navigation.command(
      for: BigPictureControllerState(isConnected: true, left: true),
      at: 20.6
    )
    let right = navigation.command(
      for: BigPictureControllerState(isConnected: true, right: true),
      at: 20.7
    )

    #expect(activate == .activate)
    #expect(heldActivate == nil)
    #expect(start == .playFromBeginning)
    #expect(options == .openGameOptions)
    #expect(back == .back)
    #expect(pageUp == .pageUp)
    #expect(pageDown == .pageDown)
    #expect(left == .pageUp)
    #expect(right == .pageDown)
  }

  @Test("Maps Select to exit Big Picture without repeating a hold")
  func mapsSelectToExitBigPicture() {
    var navigation = BigPictureControllerNavigation()
    let select = BigPictureControllerState(
      isConnected: true,
      exitsBigPicture: true
    )

    #expect(navigation.command(for: select, at: 21) == .exit)
    #expect(navigation.command(for: select, at: 21.1) == nil)
  }

  @Test("Maps Select to Big Picture and Start to game options")
  func mapsAuxiliaryButtons() {
    let select = BigPictureControllerState.extendedAuxiliaryButtonActions(
      optionsPressed: true,
      menuPressed: false,
      homePressed: false
    )
    let start = BigPictureControllerState.extendedAuxiliaryButtonActions(
      optionsPressed: false,
      menuPressed: true,
      homePressed: false
    )
    let home = BigPictureControllerState.extendedAuxiliaryButtonActions(
      optionsPressed: false,
      menuPressed: false,
      homePressed: true
    )

    #expect(select.opensBigPicture)
    #expect(select.exitsBigPicture)
    #expect(!select.opensGameOptions)
    #expect(!start.opensBigPicture)
    #expect(!start.exitsBigPicture)
    // Start/Menu is the game options button now.
    #expect(start.opensGameOptions)
    #expect(home.opensBigPicture)
    #expect(!home.exitsBigPicture)
    #expect(!home.opensGameOptions)
  }

  @Test("Maps the right face button to select and bottom face button to back")
  func mapsFaceButtonPositions() {
    let xboxA = BigPictureControllerState.extendedFaceButtonActions(
      buttonAPressed: true,
      buttonBPressed: false
    )
    let xboxB = BigPictureControllerState.extendedFaceButtonActions(
      buttonAPressed: false,
      buttonBPressed: true
    )

    #expect(xboxA.back)
    #expect(!xboxA.activate)
    #expect(xboxB.activate)
    #expect(!xboxB.back)
  }

  @Test("Escape leaves full screen before navigating")
  func prioritizesLeavingFullScreenForEscape() {
    #expect(
      BigPictureEscapeAction.resolve(
        isFullScreen: true,
        canNavigateBack: true
      ) == .leaveFullScreen
    )
    #expect(
      BigPictureEscapeAction.resolve(
        isFullScreen: false,
        canNavigateBack: true
      ) == .navigateBack
    )
    #expect(
      BigPictureEscapeAction.resolve(
        isFullScreen: false,
        canNavigateBack: false
      ) == .exit
    )
  }

  @Test("Big Picture applies only CRT display effects")
  func resolvesBigPictureVideoEffects() {
    #expect(
      BigPictureVideoEffectPolicy.resolved(
        filter: .crtSmart
      ) == .crt
    )
    #expect(
      BigPictureVideoEffectPolicy.resolved(
        filter: .crtCurved
      ) == .crt
    )
    #expect(
      BigPictureVideoEffectPolicy.resolved(
        filter: .crt
      ) == .crt
    )
    #expect(
      BigPictureVideoEffectPolicy.curvature(for: .nearest) == nil
    )
    #expect(
      BigPictureVideoEffectPolicy.curvature(for: .sharpBilinear) == nil
    )
    #expect(
      BigPictureVideoEffectPolicy.curvature(for: .xbr) == nil
    )
    #expect(
      BigPictureVideoEffectPolicy.curvature(for: .crt) == 0
    )
    #expect(
      BigPictureVideoEffectPolicy.curvature(for: .crtSmart) == 0
    )
    #expect(
      BigPictureVideoEffectPolicy.curvature(for: .crtCurved) == 1
    )
  }

  @Test("Maps Nintendo A to select and Nintendo B to back")
  func mapsNintendoFaceButtons() {
    let switchA = BigPictureControllerState.extendedFaceButtonActions(
      buttonAPressed: true,
      buttonBPressed: false,
      layout: .nintendo
    )
    let switchB = BigPictureControllerState.extendedFaceButtonActions(
      buttonAPressed: false,
      buttonBPressed: true,
      layout: .nintendo
    )

    #expect(switchA.activate)
    #expect(!switchA.back)
    #expect(switchB.back)
    #expect(!switchB.activate)
    #expect(
      ControllerFaceButtonLayout.resolve(
        vendorName: "Nintendo Co., Ltd.",
        productCategory: "Switch"
      ) == .nintendo
    )
  }

  @Test("Uses the connected controller's physical face-button labels")
  func usesPhysicalControllerButtonLabels() {
    let switchActivate = BigPictureControllerState.buttonPrompt(
      localizedName: "A Button",
      systemImage: "a.circle",
      fallbackLabel: "B"
    )
    let switchBack = BigPictureControllerState.buttonPrompt(
      localizedName: "Button B",
      systemImage: "b.circle",
      fallbackLabel: "A"
    )
    let fallback = BigPictureControllerState.buttonPrompt(
      localizedName: nil,
      systemImage: nil,
      fallbackLabel: "B"
    )

    #expect(switchActivate.label == "A")
    #expect(switchActivate.systemImage == "a.circle")
    #expect(switchBack.label == "B")
    #expect(switchBack.systemImage == "b.circle")
    #expect(fallback.label == "B")
    #expect(fallback.systemImage == nil)

    let switchOptions = BigPictureControllerState.buttonPrompt(
      localizedName: "X Button",
      systemImage: "x.circle",
      fallbackLabel: "X"
    )
    #expect(switchOptions.label == "X")
    #expect(switchOptions.systemImage == "x.circle")
  }

  @Test("Maps Backspace to Big Picture back navigation")
  func mapsBackspaceToBack() {
    #expect(
      BigPictureKeyboardNavigation.command(for: .delete) == .back
    )
    #expect(
      BigPictureKeyboardNavigation.command(forMacKeyCode: 51) == .back
    )
    #expect(
      BigPictureKeyboardNavigation.command(forMacKeyCode: 117) == nil
    )
    #expect(
      BigPictureKeyboardNavigation.command(for: .return) == .activate
    )
    #expect(
      BigPictureKeyboardNavigation.command(for: .space) == .activate
    )
  }

  @Test("Jumps to the first title matching a typed letter")
  func selectsBigPictureRowByLetter() {
    let titles = [
      "Alien Hominid",
      "Castlevania",
      "Écco the Dolphin",
      "EarthBound",
      "Zelda",
    ]

    #expect(
      BigPictureTypeSelection.index(matching: "c", in: titles) == 1
    )
    #expect(
      BigPictureTypeSelection.index(matching: "E", in: titles) == 2
    )
    #expect(
      BigPictureTypeSelection.index(matching: "z", in: titles) == 4
    )
    #expect(
      BigPictureTypeSelection.index(matching: "q", in: titles) == nil
    )
    #expect(
      BigPictureTypeSelection.index(matching: "12", in: titles) == nil
    )
  }

  @Test("Keeps Big Picture selection at list boundaries")
  func clampsBigPictureSelection() {
    #expect(
      BigPictureSelectionNavigation.index(
        afterMovingFrom: 0,
        by: -1,
        itemCount: 20
      ) == 0
    )
    #expect(
      BigPictureSelectionNavigation.index(
        afterMovingFrom: 19,
        by: 1,
        itemCount: 20
      ) == 19
    )
    #expect(
      BigPictureSelectionNavigation.index(
        afterMovingFrom: 7,
        by: 10,
        itemCount: 20
      ) == 17
    )
  }

  @Test("Does not carry held gameplay input back into Big Picture")
  func suppressesHeldInputWhileInactive() {
    var navigation = BigPictureControllerNavigation()
    let heldUp = BigPictureControllerState(isConnected: true, up: true)

    navigation.synchronize(with: heldUp)
    let whileStillHeld = navigation.command(for: heldUp, at: 30)
    let released = navigation.command(
      for: BigPictureControllerState(isConnected: true),
      at: 30.1
    )
    let pressedAgain = navigation.command(for: heldUp, at: 30.2)

    #expect(whileStillHeld == nil)
    #expect(released == nil)
    #expect(pressedAgain == .up)
  }

  @MainActor
  @Test("Uses the complete snapshot without changing desktop selection")
  func readsCompleteLibrarySnapshot() async throws {
    let snapshot = testLibrarySnapshot()
    let session = ServerSession(
      serverURL: try ServerURL("https://romm.example.com"),
      username: "kenneth"
    )
    let model = LibraryModel(
      session: session,
      service: OfflineLibraryService(
        snapshot: snapshot,
        downloadedGameIDs: [2]
      )
    )

    await model.load()
    model.selection = .system(1)
    await model.reloadGames()

    let source = model.bigPictureSource

    #expect(model.games.map(\.id) == [1])
    #expect(source.games.map(\.id) == [1, 2])
    #expect(source.downloadedGameIDs == [2])
    #expect(model.selection == .system(1))
  }
}

@Suite("Offline library cache")
struct LibraryCacheTests {
  @Test("Persists local Favorites and their pending RomM changes")
  func persistsLocalFavorites() async throws {
    let cache = SwiftDataLibraryCache(isStoredInMemoryOnly: true)
    let serverURL = try ServerURL("https://romm.example.com")
    let state = LocalFavoriteState(
      gameIDs: [1, 2],
      pendingChanges: [
        LocalFavoriteState.Change(gameID: 2, isFavorite: true)
      ]
    )

    try await cache.replaceLocalFavorites(state, for: serverURL)

    #expect(try await cache.localFavorites(for: serverURL) == state)
  }

  @Test("Keeps favorite changes local when RomM is unavailable")
  func keepsFavoriteChangesWhileOffline() async throws {
    let serverURL = try ServerURL("https://romm.example.com")
    let session = ServerSession(serverURL: serverURL, username: "kenneth")
    let cache = InMemoryLibraryCache()
    await cache.replaceSnapshot(testLibrarySnapshot(), for: serverURL)
    let service = RomMLibraryService(
      api: UnavailableRomMClient(),
      credentialStore: TestCredentialStore(
        token: try ClientToken(
          rawValue: "rmm_" + String(repeating: "f", count: 64)
        )
      ),
      cache: cache
    )

    let localSnapshot = try await service.updateFavoriteMembershipLocally(
      collectionID: 10,
      gameIDs: [2],
      adding: true,
      in: session
    )

    #expect(
      localSnapshot.collectionMemberships.first {
        $0.collectionID == .regular(10)
      }?.gameIDs == [1, 2]
    )
    await #expect(throws: (any Error).self) {
      try await service.synchronizePendingFavorites(in: session)
    }
    #expect(
      await cache.localFavorites(for: serverURL)?
        .pendingChanges == [
          LocalFavoriteState.Change(gameID: 2, isFavorite: true)
        ]
    )
    #expect(
      try await service.cachedSnapshot(in: session)?
        .collectionMemberships.first {
          $0.collectionID == .regular(10)
        }?.gameIDs == [1, 2]
    )
  }

  @Test("Filters a library snapshot to the union of selected systems")
  func filtersMultipleSystems() {
    let games = [
      GameSummary(
        id: 1,
        name: "Game Boy Game",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil
      ),
      GameSummary(
        id: 2,
        name: "NES Game",
        systemID: 2,
        systemName: "Nintendo Entertainment System",
        coverURL: nil
      ),
      GameSummary(
        id: 3,
        name: "SNES Game",
        systemID: 3,
        systemName: "Super Nintendo",
        coverURL: nil
      ),
    ]
    let snapshot = LibrarySnapshot(
      synchronizedAt: Date(timeIntervalSince1970: 1_000),
      systems: [
        LibrarySystem(id: 1, name: "Game Boy", gameCount: 1),
        LibrarySystem(
          id: 2,
          name: "Nintendo Entertainment System",
          gameCount: 1
        ),
        LibrarySystem(id: 3, name: "Super Nintendo", gameCount: 1),
      ],
      collections: [],
      games: games,
      collectionMemberships: []
    )

    let page = snapshot.page(
      matching: .systems([1, 3]),
      searchTerm: nil,
      offset: 0,
      limit: 60
    )

    #expect(page.games.map(\.id) == [1, 3])
    #expect(page.total == 2)
  }

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

    try await cache.removeGames(withIDs: [1], for: serverURL)

    #expect(try await cache.snapshot(for: serverURL)?.games.map(\.id) == [2])
    #expect(try await cache.snapshot(for: serverURL)?.systems.first?.gameCount == 0)
    #expect(try await cache.gameDetails(for: 1, serverURL: serverURL) == nil)
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
    #expect(
      try await service.cachedGameDetails(
        for: 1,
        in: session
      ) == details
    )
  }

  @Test("Commits a complete synchronized snapshot including BIOS records")
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

    #expect(
      snapshot.games.map(\.name)
        == ["Tetris", "Metroid", "[BIOS] Game Boy"]
    )
    #expect(snapshot.systems.first?.gameCount == 3)
    #expect(snapshot.collections.first { $0.id == .regular(10) }?.gameCount == 2)
    #expect(!snapshot.collections.contains { collection in
      if case .virtual = collection.id {
        return true
      }
      return false
    })
    #expect(
      snapshot.collectionMemberships.first {
        $0.collectionID == .regular(10)
      }?.gameIDs == [1, 3]
    )
    #expect(!snapshot.collectionMemberships.contains {
      if case .virtual = $0.collectionID {
        return true
      }
      return false
    })
    #expect(snapshot.games.first(where: { $0.id == 1 })?.hasSave == true)
    #expect(snapshot.games.first(where: { $0.id == 2 })?.hasState == true)
    #expect(await cache.snapshot(for: serverURL) == snapshot)
  }

  @Test("Orders play history by recency and drops removed games")
  func ordersPlayHistoryByRecency() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    var history = LocalPlayHistory()
    history.recordPlay(gameID: 1, at: base)
    history.recordPlay(gameID: 2, at: base.addingTimeInterval(60))
    history.recordPlay(gameID: 3, at: base.addingTimeInterval(30))

    #expect(history.gameIDsByRecency == [2, 3, 1])
    #expect(history.lastPlayed(gameID: 2) == base.addingTimeInterval(60))

    // Replaying moves a game to the front rather than adding an entry.
    history.recordPlay(gameID: 1, at: base.addingTimeInterval(90))
    #expect(history.gameIDsByRecency == [1, 2, 3])

    let pruned = history.removingGames(withIDs: [2])
    #expect(pruned.gameIDsByRecency == [1, 3])
  }

  @Test("Keeps the newer of local and RomM play timestamps")
  func mergesServerPlayTimestamps() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    var history = LocalPlayHistory()
    history.recordPlay(gameID: 1, at: base.addingTimeInterval(60))
    history.recordPlay(gameID: 2, at: base)

    let merged = history.merging(serverLastPlayedByGameID: [
      1: base,
      2: base.addingTimeInterval(120),
      3: base.addingTimeInterval(30),
    ])

    // Local wins for 1 because playing here is more recent than RomM's record,
    // RomM wins for 2, and a game only played on the server still appears.
    #expect(merged.lastPlayed(gameID: 1) == base.addingTimeInterval(60))
    #expect(merged.lastPlayed(gameID: 2) == base.addingTimeInterval(120))
    #expect(merged.lastPlayed(gameID: 3) == base.addingTimeInterval(30))
    #expect(merged.gameIDsByRecency == [2, 1, 3])
  }

  @Test("Adopts RomM play timestamps from synchronized games")
  func adoptsServerPlayTimestampsFromGames() {
    let games = [
      GameSummary(
        id: 1,
        name: "Played on RomM",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil,
        serverLastPlayed: "2026-07-20T12:00:00Z"
      ),
      GameSummary(
        id: 2,
        name: "Fractional seconds",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil,
        serverLastPlayed: "2026-07-21T12:00:00.523Z"
      ),
      GameSummary(
        id: 3,
        name: "Never played",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil
      ),
    ]

    let merged = LocalPlayHistory().merging(games: games)

    #expect(merged.gameIDsByRecency == [2, 1])
    #expect(merged.lastPlayed(gameID: 3) == nil)
  }

  @Test("Projects merged play history onto sortable library rows")
  func projectsPlayHistoryOntoLibraryRows() {
    let older = Date(timeIntervalSince1970: 1_000_000)
    let newer = older.addingTimeInterval(120)
    var history = LocalPlayHistory()
    history.recordPlay(gameID: 1, at: older)
    history.recordPlay(gameID: 2, at: newer)

    let snapshot = LibrarySnapshot(
      synchronizedAt: newer,
      systems: [],
      collections: [],
      games: [
        GameSummary(
          id: 1,
          name: "Older",
          systemID: 1,
          systemName: "Game Boy",
          coverURL: nil
        ),
        GameSummary(
          id: 2,
          name: "Newer",
          systemID: 1,
          systemName: "Game Boy",
          coverURL: nil
        ),
        GameSummary(
          id: 3,
          name: "Never",
          systemID: 1,
          systemName: "Game Boy",
          coverURL: nil
        ),
      ],
      collectionMemberships: []
    ).applying(history)

    #expect(snapshot.games[0].lastPlayedAt == older)
    #expect(snapshot.games[1].lastPlayedAt == newer)
    #expect(snapshot.games[2].lastPlayedAt == nil)
  }

  @Test("Finds typed game-name prefixes only in alphabetical list order")
  func findsTypedGameNamePrefixes() {
    let games = [
      GameSummary(
        id: 1,
        name: "Castlevania",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil
      ),
      GameSummary(
        id: 2,
        name: "Éclair",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil
      ),
      GameSummary(
        id: 3,
        name: "The Legend of Zelda",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil
      ),
    ]

    #expect(
      LibraryTypeSelection.isAlphabeticallySorted(
        games,
        prioritizedGameIDs: []
      )
    )
    #expect(LibraryTypeSelection.index(matching: "ca", in: games) == 0)
    #expect(LibraryTypeSelection.index(matching: "ec", in: games) == 1)
    #expect(LibraryTypeSelection.index(matching: "the l", in: games) == 2)
    #expect(LibraryTypeSelection.index(matching: "zel", in: games) == nil)
    #expect(
      !LibraryTypeSelection.isAlphabeticallySorted(
        Array(games.reversed()),
        prioritizedGameIDs: []
      )
    )
  }

  @Test("Treats favorite-first alphabetical groups as type-selectable")
  func recognizesFavoriteFirstAlphabeticalGroups() {
    let games = [
      GameSummary(
        id: 1,
        name: "Mario",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil
      ),
      GameSummary(
        id: 2,
        name: "Zelda",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil
      ),
      GameSummary(
        id: 3,
        name: "Asteroids",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: nil
      ),
    ]

    #expect(
      LibraryTypeSelection.isAlphabeticallySorted(
        games,
        prioritizedGameIDs: [1, 2]
      )
    )
  }

  @Test("Presents recently played games newest first in Big Picture")
  func presentsRecentlyPlayedGamesInBigPicture() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    var history = LocalPlayHistory()
    history.recordPlay(gameID: 3, at: base)
    history.recordPlay(gameID: 1, at: base.addingTimeInterval(60))

    let source = BigPictureLibrarySource(
      synchronizedAt: nil,
      systems: [LibrarySystem(id: 1, name: "Game Boy", gameCount: 3)],
      collections: [],
      games: (1...3).map {
        GameSummary(
          id: $0,
          name: "Game \($0)",
          systemID: 1,
          systemName: "Game Boy",
          coverURL: nil
        )
      },
      collectionMemberships: [],
      downloadedGameIDs: [],
      playHistory: history
    )
    let catalog = BigPictureCatalog(source: source, manifest: nil)

    #expect(catalog.recentlyPlayedGames.map(\.id) == [1, 3])
    #expect(catalog.games(in: .recentlyPlayed).map(\.id) == [1, 3])
    #expect(catalog.title(for: .recentlyPlayed) == "Recently Played")
  }

  @Test("Rereads the library sequentially when concurrent pages disagree")
  func fallsBackToSequentialSynchronization() async throws {
    let serverURL = try ServerURL("https://romm.example.com")
    let session = ServerSession(serverURL: serverURL, username: "kenneth")
    let client = SynchronizationRomMClient(
      gameCount: 2_505,
      gameRequestDelayMilliseconds: 20
    )
    await client.enableUnstableOrderingAcrossConcurrentPages()
    let service = RomMLibraryService(
      api: client,
      credentialStore: TestCredentialStore(
        token: try ClientToken(
          rawValue: "rmm_" + String(repeating: "e", count: 64)
        )
      ),
      cache: InMemoryLibraryCache()
    )

    let snapshot = try await service.synchronizeLibrary(in: session) { _ in }

    // The parallel pass cannot compose a complete library here, so the service
    // must fall back rather than surface an incomplete synchronization.
    #expect(snapshot.games.count == 2_505)
    #expect(snapshot.games.map(\.id) == Array(1...2_505))
  }

  @Test("Fetches large synchronized libraries in parallel")
  func fetchesSynchronizedPagesInParallel() async throws {
    let serverURL = try ServerURL("https://romm.example.com")
    let session = ServerSession(serverURL: serverURL, username: "kenneth")
    let client = SynchronizationRomMClient(
      gameCount: 2_505,
      gameRequestDelayMilliseconds: 20
    )
    let progress = SyncProgressRecorder()
    let service = RomMLibraryService(
      api: client,
      credentialStore: TestCredentialStore(
        token: try ClientToken(
          rawValue: "rmm_" + String(repeating: "e", count: 64)
        )
      ),
      cache: InMemoryLibraryCache()
    )

    let snapshot = try await service.synchronizeLibrary(in: session) {
      await progress.record($0)
    }
    let requestStats = await client.catalogRequestStats()
    let completedCounts = await progress.completedCounts()

    #expect(snapshot.games.count == 2_505)
    #expect(snapshot.games.map(\.id) == Array(1...2_505))
    #expect(requestStats.offsets.sorted() == [0, 1_000, 2_000])
    #expect(requestStats.limits == [1_000, 1_000, 1_000])
    #expect(requestStats.maximumConcurrentRequestCount > 1)
    #expect(completedCounts == completedCounts.sorted())
    #expect(completedCounts.last == 2_505)
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

  @MainActor
  @Test("Loads every cached game without view-driven pagination")
  func loadsCompleteCachedSelection() async throws {
    let games = (1...125).map { id in
      GameSummary(
        id: id,
        name: "Game \(id)",
        systemID: 1,
        systemName: "Game Boy",
        coverURL: id.isMultiple(of: 2)
          ? URL(string: "https://romm.example.com/\(id).webp")
          : nil
      )
    }
    let snapshot = LibrarySnapshot(
      synchronizedAt: Date(timeIntervalSince1970: 1_000),
      systems: [
        LibrarySystem(id: 1, name: "Game Boy", gameCount: games.count)
      ],
      collections: [],
      games: games,
      collectionMemberships: []
    )
    let session = ServerSession(
      serverURL: try ServerURL("https://romm.example.com"),
      username: "kenneth"
    )
    let model = LibraryModel(
      session: session,
      service: OfflineLibraryService(snapshot: snapshot)
    )

    await model.load()

    #expect(model.games.count == 125)
    #expect(model.totalGameCount == 125)

    await model.setHidesGamesWithoutArtwork(true)

    #expect(model.displayedGames.count == 62)
  }

  @MainActor
  @Test("Shows every game detail page from the library cache while offline")
  func showsSummaryDetailsOffline() async throws {
    let snapshot = testLibrarySnapshot()
    let session = ServerSession(
      serverURL: try ServerURL("https://romm.example.com"),
      username: "kenneth"
    )
    let model = GameDetailsModel(
      game: try #require(snapshot.games.first),
      session: session,
      service: OfflineLibraryService(snapshot: snapshot)
    )

    await model.load()

    #expect(model.details?.name == "Tetris")
    #expect(model.dataSource == .librarySummary)
    #expect(model.refreshErrorMessage != nil)
    #expect(model.errorMessage == nil)
  }

  @MainActor
  @Test("Prepares downloaded game metadata without contacting RomM")
  func loadsDownloadedPlaybackMetadataOffline() async throws {
    let snapshot = testLibrarySnapshot()
    let session = ServerSession(
      serverURL: try ServerURL("https://romm.example.com"),
      username: "kenneth"
    )
    let model = GameDetailsModel(
      game: try #require(snapshot.games.first),
      session: session,
      service: OfflineLibraryService(
        snapshot: snapshot,
        downloadedGameIDs: [1]
      )
    )

    await model.loadForPlayback(allowsRemoteAccess: false)

    #expect(model.details?.name == "Tetris")
    #expect(model.dataSource == .librarySummary)
    #expect(model.refreshErrorMessage == nil)
    #expect(model.errorMessage == nil)
  }

  @MainActor
  @Test("Filters the cached library to games downloaded on this Mac")
  func filtersDownloadedGames() async throws {
    let snapshot = testLibrarySnapshot()
    let session = ServerSession(
      serverURL: try ServerURL("https://romm.example.com"),
      username: "kenneth"
    )
    let model = LibraryModel(
      session: session,
      service: OfflineLibraryService(
        snapshot: snapshot,
        downloadedGameIDs: [2]
      )
    )

    await model.load()
    model.selection = .downloaded
    await model.reloadGames()

    #expect(model.downloadedGameCount == 1)
    #expect(model.displayedGames.map(\.name) == ["Metroid"])
    #expect(model.title == "Downloaded")
  }

  @MainActor
  @Test("Drops virtual collections retained by an older offline cache")
  func dropsLegacyVirtualCollections() async throws {
    let regularID = LibraryCollection.ID.regular(10)
    let virtualID = LibraryCollection.ID.virtual("virtual-nintendo")
    let snapshot = LibrarySnapshot(
      synchronizedAt: Date(timeIntervalSince1970: 1_000),
      systems: [],
      collections: [
        LibraryCollection(
          id: regularID,
          name: "Favorites",
          gameCount: 1,
          isFavorite: true
        ),
        LibraryCollection(
          id: virtualID,
          name: "Mario",
          gameCount: 1,
          virtualType: "collection"
        ),
      ],
      games: [
        GameSummary(
          id: 1,
          name: "Super Mario World",
          systemID: 1,
          systemName: "Super Nintendo Entertainment System",
          coverURL: nil
        )
      ],
      collectionMemberships: [
        LibrarySnapshot.CollectionMembership(
          collectionID: regularID,
          gameIDs: [1]
        ),
        LibrarySnapshot.CollectionMembership(
          collectionID: virtualID,
          gameIDs: [1]
        ),
      ]
    )
    let session = ServerSession(
      serverURL: try ServerURL("https://romm.example.com"),
      username: "kenneth"
    )
    let model = LibraryModel(
      session: session,
      service: OfflineLibraryService(snapshot: snapshot)
    )

    await model.load()

    #expect(model.collections.map(\.id) == [regularID])
    #expect(model.displayedGames.map(\.id) == [1])
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
    ordering: GamePageOrdering,
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

private actor SynchronizationRomMClient: RomMClient {
  private let allGames: [GameSummary]
  private let gameRequestDelayMilliseconds: Int64
  private var reordersConcurrentPages = false
  private var overlapsConcurrentPages = false
  private var catalogRequestOffsets: [Int] = []
  private var catalogRequestLimits: [Int] = []
  private var activeCatalogRequestCount = 0
  private var maximumConcurrentCatalogRequestCount = 0

  init(
    gameCount: Int? = nil,
    gameRequestDelayMilliseconds: Int64 = 0
  ) {
    self.gameRequestDelayMilliseconds = gameRequestDelayMilliseconds
    if let gameCount {
      allGames = (1...gameCount).map {
        GameSummary(
          id: $0,
          name: "Game \(String(format: "%05d", $0))",
          systemID: 1,
          systemName: "Game Boy",
          coverURL: nil
        )
      }
    } else {
      allGames = [
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
    }
  }

  func verifyServer(at serverURL: ServerURL) async throws {}

  func exchange(pairingCode: PairingCode, at serverURL: ServerURL) async throws -> ClientToken {
    try ClientToken(rawValue: "rmm_" + String(repeating: "d", count: 64))
  }

  func currentUser(at serverURL: ServerURL, token: ClientToken) async throws -> RomMUser {
    RomMUser(id: 1, username: "kenneth", scopes: [])
  }

  func systems(at serverURL: ServerURL, token: ClientToken) async throws -> [LibrarySystem] {
    [
      LibrarySystem(id: 1, name: "Game Boy", gameCount: allGames.count)
    ]
  }

  func collections(
    at serverURL: ServerURL,
    token: ClientToken
  ) async throws -> [LibraryCollection] {
    [
      LibraryCollection(id: .regular(10), name: "Favorites", gameCount: 2),
      LibraryCollection(
        id: .virtual("virtual-tetris"),
        name: "Tetris",
        gameCount: 1,
        virtualType: "collection",
        memberGameIDs: [1, 1]
      ),
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
    ordering: GamePageOrdering,
    offset: Int,
    limit: Int
  ) async throws -> GamePage {
    if case .allGames = filter {
      catalogRequestOffsets.append(offset)
      catalogRequestLimits.append(limit)
      activeCatalogRequestCount += 1
      maximumConcurrentCatalogRequestCount = max(
        maximumConcurrentCatalogRequestCount,
        activeCatalogRequestCount
      )
      defer {
        activeCatalogRequestCount -= 1
      }
      if gameRequestDelayMilliseconds > 0 {
        try await Task.sleep(
          for: .milliseconds(gameRequestDelayMilliseconds)
        )
      }
      overlapsConcurrentPages =
        reordersConcurrentPages && activeCatalogRequestCount > 1
    }

    let filtered: [GameSummary]
    switch filter {
    case .allGames, .system, .systems:
      filtered = allGames
    case .collection:
      filtered = [allGames[0], allGames[2]]
    }

    // A server ordering rows by a non-unique key can place a tied row
    // differently for each query, so a page fetched alongside others can repeat
    // a row its neighbour already returned. Reading one page at a time never
    // observes the disagreement.
    let start =
      overlapsConcurrentPages && offset > 0
      ? offset - 1
      : offset

    return GamePage(
      games: Array(filtered.dropFirst(start).prefix(limit)),
      total: filtered.count,
      limit: limit,
      offset: offset
    )
  }

  func enableUnstableOrderingAcrossConcurrentPages() {
    reordersConcurrentPages = true
  }

  func catalogRequestStats() -> (
    offsets: [Int],
    limits: [Int],
    maximumConcurrentRequestCount: Int
  ) {
    (
      catalogRequestOffsets,
      catalogRequestLimits,
      maximumConcurrentCatalogRequestCount
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

private actor SyncProgressRecorder {
  private var values: [Int] = []

  func record(_ progress: LibrarySyncProgress) {
    values.append(progress.completedGameCount)
  }

  func completedCounts() -> [Int] {
    values
  }
}

private actor OfflineLibraryService: LibraryServing {
  let snapshot: LibrarySnapshot
  let downloadedIDs: Set<Int>
  private var playHistory = LocalPlayHistory()

  init(
    snapshot: LibrarySnapshot,
    downloadedGameIDs: Set<Int> = []
  ) {
    self.snapshot = snapshot
    downloadedIDs = downloadedGameIDs
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

  func playHistory(in session: ServerSession) -> LocalPlayHistory {
    playHistory
  }

  func recordPlay(gameID: Int, in session: ServerSession) -> LocalPlayHistory {
    playHistory.recordPlay(gameID: gameID, at: .now)
    return playHistory
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

  func downloadedGameIDs(in session: ServerSession) -> Set<Int> {
    downloadedIDs
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

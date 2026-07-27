import AppKit
import Combine
@preconcurrency import GameController
import SwiftUI

enum LibraryCoordinateSpace {
  static let name = "OpenVault.Library"
}

enum LibraryControllerCommand: Equatable, Sendable {
  case up
  case down
  case left
  case right
  case activate
  case back
  case openBigPicture
  case focusContent
}

@MainActor
final class LibraryControllerRouter {
  let commands = PassthroughSubject<LibraryControllerCommand, Never>()

  func send(_ command: LibraryControllerCommand) {
    commands.send(command)
  }
}

struct LibraryControllerNavigation: Sendable {
  private static let initialRepeatDelay = 0.34
  private static let repeatInterval = 0.09

  private var previousState = BigPictureControllerState()
  private var repeatingCommand: LibraryControllerCommand?
  private var nextRepeatTime = 0.0

  mutating func synchronize(with state: BigPictureControllerState) {
    previousState = state
    repeatingCommand = nil
    nextRepeatTime = 0
  }

  mutating func command(
    for state: BigPictureControllerState,
    at uptime: TimeInterval
  ) -> LibraryControllerCommand? {
    defer {
      previousState = state
    }

    if state.opensBigPicture, !previousState.opensBigPicture {
      return .openBigPicture
    }
    if state.back, !previousState.back {
      return .back
    }
    if state.activate, !previousState.activate {
      return .activate
    }

    let directionalCommand: LibraryControllerCommand? =
      if state.up {
        .up
      } else if state.down {
        .down
      } else if state.left {
        .left
      } else if state.right {
        .right
      } else {
        nil
      }

    guard let directionalCommand else {
      repeatingCommand = nil
      return nil
    }

    guard repeatingCommand == directionalCommand else {
      repeatingCommand = directionalCommand
      nextRepeatTime = uptime + Self.initialRepeatDelay
      return directionalCommand
    }

    guard uptime >= nextRepeatTime else {
      return nil
    }
    nextRepeatTime = uptime + Self.repeatInterval
    return directionalCommand
  }
}

enum LibraryKeyboardNavigation {
  static func command(
    forKeyCode keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags
  ) -> LibraryControllerCommand? {
    let navigationModifiers: NSEvent.ModifierFlags = [
      .command,
      .control,
      .option,
      .shift,
    ]
    guard modifierFlags.intersection(navigationModifiers).isEmpty else {
      return nil
    }

    return switch keyCode {
    case 126:
      .up
    case 125:
      .down
    case 123:
      .left
    case 124:
      .right
    case 36, 76:
      .activate
    default:
      nil
    }
  }
}

private enum LibraryPreferenceKey {
  static let hidesBIOSGames = "library.hides-bios-games.v1"
  static let hidesGamesWithoutArtwork = "library.hides-games-without-artwork"
  static let allGamesPresentation = "library.presentation.all-games"
  static let systemPresentation = "library.presentation.system"
  static let collectionPresentation = "library.presentation.collection"
  static let artworkSort = "library.artwork-sort.v1"
  static let tableColumns = "library.table-columns.v2"
  static let showsGenreBrowser = "library.column-browser.genre.v1"
  static let showsYearBrowser = "library.column-browser.year.v1"
  static let showsRegionBrowser = "library.column-browser.region.v1"
  static let showsStatusBrowser = "library.column-browser.status.v1"
  static let showsSaveDataBrowser = "library.column-browser.save-data.v1"
  static let showsDownloadedBrowser = "library.column-browser.downloaded.v1"
  static let showsArtworkBrowser = "library.column-browser.artwork.v1"
  static let browserOrder = "library.column-browser.order.v1"
  static let expandsSmartCollections = "library.smart-collections.expanded.v1"
  static let expandsVirtualCollections = "library.virtual-collections.expanded.v1"
  static let sidebarSystemSort = "library.sidebar-system-sort.v1"
}

private enum LibraryPresentation: String {
  case list
  case artwork
}

enum ArtworkSort: String, CaseIterable, Identifiable, Sendable {
  case alphabetical
  case dateAdded
  case releaseYear

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .alphabetical:
      "Alphabetical"
    case .dateAdded:
      "Date Added"
    case .releaseYear:
      "Year"
    }
  }

  var systemImage: String {
    switch self {
    case .alphabetical:
      "textformat"
    case .dateAdded:
      "calendar.badge.plus"
    case .releaseYear:
      "calendar"
    }
  }

  nonisolated func sorted(_ games: [GameSummary]) -> [GameSummary] {
    switch self {
    case .alphabetical:
      return games.sorted(by: Self.isAlphabeticallyOrdered)
    case .dateAdded:
      let standardFormatter = ISO8601DateFormatter()
      let fractionalFormatter = ISO8601DateFormatter()
      fractionalFormatter.formatOptions = [
        .withInternetDateTime,
        .withFractionalSeconds,
      ]

      let preparedGames = games.map { game in
        (
          game: game,
          dateAdded:
            game.createdAt.flatMap {
              fractionalFormatter.date(from: $0)
                ?? standardFormatter.date(from: $0)
            }
        )
      }

      return preparedGames.sorted { lhs, rhs in
        switch (lhs.dateAdded, rhs.dateAdded) {
        case let (left?, right?) where left != right:
          return left > right
        case (_?, nil):
          return true
        case (nil, _?):
          return false
        default:
          return Self.isAlphabeticallyOrdered(lhs.game, rhs.game)
        }
      }
      .map(\.game)
    case .releaseYear:
      return games.sorted { lhs, rhs in
        switch (lhs.releaseYear, rhs.releaseYear) {
        case let (left?, right?) where left != right:
          return left > right
        case (_?, nil):
          return true
        case (nil, _?):
          return false
        default:
          return Self.isAlphabeticallyOrdered(lhs, rhs)
        }
      }
    }
  }

  private nonisolated static func isAlphabeticallyOrdered(
    _ lhs: GameSummary,
    _ rhs: GameSummary
  ) -> Bool {
    let comparison = lhs.name.localizedStandardCompare(rhs.name)
    if comparison == .orderedSame {
      return lhs.id < rhs.id
    }
    return comparison == .orderedAscending
  }
}

enum SidebarSystemSort: String, CaseIterable, Identifiable, Sendable {
  case alphabetical
  case gameCount

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .alphabetical:
      "Alphabetical"
    case .gameCount:
      "Game Count"
    }
  }

  var systemImage: String {
    switch self {
    case .alphabetical:
      "textformat"
    case .gameCount:
      "number"
    }
  }

  nonisolated func sorted(_ systems: [LibrarySystem]) -> [LibrarySystem] {
    systems.sorted { lhs, rhs in
      if self == .gameCount, lhs.gameCount != rhs.gameCount {
        return lhs.gameCount > rhs.gameCount
      }

      let comparison = lhs.name.localizedStandardCompare(rhs.name)
      if comparison == .orderedSame {
        return lhs.id < rhs.id
      }
      return comparison == .orderedAscending
    }
  }
}

private enum LibraryGamePlayability {
  private static let bundledLibretroManifest =
    try? LibretroInstallation.bundled().manifest

  static func isPlayable(
    _ game: GameSummary,
    downloadedGameIDs: Set<Int>
  ) -> Bool {
    guard
      game.isMissingFromFileSystem != true
        || downloadedGameIDs.contains(game.id)
    else {
      return false
    }

    return bundledLibretroManifest?
      .supportsSystem(named: game.systemName)
      ?? false
  }
}

private struct ArtworkFilterApplicationKey: Hashable {
  let presentation: LibraryPresentation
  let hidesGamesWithoutArtwork: Bool
  let synchronizedAt: Date?
}

private struct LibrarySearchApplicationKey: Hashable {
  let selection: LibrarySelection
  let searchText: String
}

private struct GameDeletionRequest: Identifiable {
  let id = UUID()
  let games: [GameSummary]
}

private struct LibraryAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  var fileURLs: [URL] = []
}

private enum LibraryPlaybackPreparation {
  case ready(LibretroRunRequest)
  case failed(LibraryAlert)
  case cancelled

  @MainActor
  static func prepare(
    _ game: GameSummary,
    model: LibraryModel
  ) async -> Self {
    switch await model.prioritizeDownloadForPlayback(game) {
    case .noActiveQueue, .downloaded:
      break
    case .failed(let message):
      return .failed(
        LibraryAlert(
          title: "Couldn’t Download Game",
          message: message
        )
      )
    case .cancelled:
      return .cancelled
    }

    let detailsModel = GameDetailsModel(
      game: game,
      session: model.session,
      service: model.service
    )
    await detailsModel.load()

    guard let details = detailsModel.details else {
      return .failed(
        LibraryAlert(
          title: "Couldn’t Prepare Game",
          message:
            detailsModel.errorMessage
            ?? "OpenVault couldn’t load the game’s playback information."
        )
      )
    }

    guard detailsModel.playbackCore != nil else {
      return .failed(
        LibraryAlert(
          title: "Game Isn’t Playable",
          message:
            "The bundled core for \(game.systemName) doesn’t support this game file."
        )
      )
    }

    guard let request = await detailsModel.prepareToPlay(details) else {
      return .failed(
        LibraryAlert(
          title: "Couldn’t Start Game",
          message:
            detailsModel.playbackErrorMessage
            ?? "OpenVault couldn’t prepare this game for playback."
        )
      )
    }

    await model.reloadDownloadedGames()
    return .ready(request)
  }
}

private enum LibraryBrowserColumn: String, CaseIterable, Identifiable {
  case system
  case genre
  case year
  case region
  case status
  case saveData
  case downloaded
  case artwork

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .system:
      "System"
    case .genre:
      "Genre"
    case .year:
      "Year"
    case .region:
      "Region"
    case .status:
      "Status"
    case .saveData:
      "Save Data"
    case .downloaded:
      "Downloaded"
    case .artwork:
      "Artwork"
    }
  }

  var systemImage: String? {
    switch self {
    case .downloaded:
      "icloud.and.arrow.down"
    default:
      nil
    }
  }

  var allLabel: String {
    switch self {
    case .system:
      "All Systems"
    case .genre:
      "All Genres"
    case .year:
      "All Years"
    case .region:
      "All Regions"
    case .status:
      "All Statuses"
    case .saveData:
      "All Save Data"
    case .downloaded:
      "All Download Statuses"
    case .artwork:
      "All Artwork"
    }
  }
}

struct LibraryView: View {
  private static let bundledLibretroManifest =
    try? LibretroInstallation.bundled().manifest

  @Bindable var model: LibraryModel
  let onOpenBigPicture: () -> Void
  @State private var searchText = ""
  @State private var showsEmptySystems = false
  @State private var showsUnsupportedSystems = false
  @State private var gameDeletionRequest: GameDeletionRequest?
  @State private var libraryAlert: LibraryAlert?
  @AppStorage(LibraryPreferenceKey.expandsSmartCollections)
  private var showsSmartCollections = true
  @AppStorage(LibraryPreferenceKey.expandsVirtualCollections)
  private var showsVirtualCollections = false
  @AppStorage(LibraryPreferenceKey.hidesBIOSGames)
  private var persistedHidesBIOSGames = true
  @AppStorage(LibraryPreferenceKey.hidesGamesWithoutArtwork)
  private var persistedHidesGamesWithoutArtwork = false
  @AppStorage(LibraryPreferenceKey.allGamesPresentation)
  private var allGamesPresentation = LibraryPresentation.list
  @AppStorage(LibraryPreferenceKey.systemPresentation)
  private var systemPresentation = LibraryPresentation.artwork
  @AppStorage(LibraryPreferenceKey.collectionPresentation)
  private var collectionPresentation = LibraryPresentation.list
  @AppStorage(LibraryPreferenceKey.artworkSort)
  private var artworkSort = ArtworkSort.alphabetical
  @AppStorage(LibraryPreferenceKey.sidebarSystemSort)
  private var sidebarSystemSort = SidebarSystemSort.alphabetical
  @FocusState private var hasSidebarFocus: Bool
  @State private var libraryWindow: NSWindow?
  @State private var controllerNavigation = LibraryControllerNavigation()
  @State private var controllerRouter = LibraryControllerRouter()

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        List(selection: sidebarSelectionBinding) {
          Label("All Games", systemImage: "rectangle.stack")
            .badge(model.allGameCount)
            .tag(LibrarySelection.allGames)

          Section("Collections") {
            LibraryDownloadedSidebarLabel(model: model)
              .tag(LibrarySelection.downloaded)

            ForEach(regularCollections) { collection in
              Label(collection.name, systemImage: collection.systemImage)
                .badge(collection.gameCount)
                .tag(LibrarySelection.collection(collection.id))
            }

            if !smartCollections.isEmpty {
              DisclosureGroup(isExpanded: $showsSmartCollections) {
                ForEach(smartCollections) { collection in
                  Label(collection.name, systemImage: collection.systemImage)
                    .badge(collection.gameCount)
                    .tag(LibrarySelection.collection(collection.id))
                }
              } label: {
                Label("Smart Collections", systemImage: "sparkles")
                  .badge(smartCollections.count)
              }
            }

            if !virtualCollections.isEmpty {
              DisclosureGroup(isExpanded: $showsVirtualCollections) {
                ForEach(virtualCollections) { collection in
                  Label(collection.name, systemImage: collection.systemImage)
                    .badge(collection.gameCount)
                    .tag(LibrarySelection.collection(collection.id))
                }
              } label: {
                Label("Virtual Collections", systemImage: "wand.and.stars")
                  .badge(virtualCollections.count)
              }
              .tag(LibrarySelection.virtualCollections)
            }
          }

          Section {
            ForEach(supportedPopulatedSystems) { system in
              sidebarSystemRow(system)
            }

            if model.hidesGamesWithoutArtwork, model.isCheckingSystemArtwork {
              HStack(spacing: 8) {
                ProgressView()
                  .controlSize(.small)
                Text("Checking artwork…")
                  .foregroundStyle(.secondary)
              }
            }

            if !unsupportedPopulatedSystems.isEmpty {
              DisclosureGroup(isExpanded: $showsUnsupportedSystems) {
                ForEach(unsupportedPopulatedSystems) { system in
                  sidebarSystemRow(system)
                }
              } label: {
                Label(
                  "Unsupported Systems",
                  systemImage: "questionmark.circle"
                )
                .badge(unsupportedPopulatedSystems.count)
              }
            }

            if !emptySystems.isEmpty {
              DisclosureGroup(isExpanded: $showsEmptySystems) {
                ForEach(emptySystems) { system in
                  sidebarSystemRow(system)
                }
              } label: {
                Label(
                  "Empty Systems",
                  systemImage: "tray.2"
                )
                .badge(emptySystems.count)
              }
            }
          } header: {
            HStack(spacing: 6) {
              Text("Systems")

              Spacer()

              Menu {
                ForEach(SidebarSystemSort.allCases) { option in
                  Button {
                    sidebarSystemSort = option
                  } label: {
                    Label(
                      option.title,
                      systemImage: sidebarSystemSort == option
                        ? "checkmark"
                        : option.systemImage
                    )
                  }
                }
              } label: {
                Label(
                  "Sort Systems",
                  systemImage: "arrow.up.arrow.down"
                )
                .labelStyle(.iconOnly)
              }
              .menuStyle(.borderlessButton)
              .fixedSize()
              .help(
                "Sort systems by \(sidebarSystemSort.title.lowercased())"
              )
              .accessibilityLabel("Sort Sidebar Systems")
              .accessibilityValue(sidebarSystemSort.title)
            }
          }
        }
        .focused($hasSidebarFocus)

        Divider()
        LibrarySidebarStatus(model: model)
      }
      .navigationTitle("OpenVault")
      .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } detail: {
      NavigationStack {
        Group {
          if model.selection == .virtualCollections {
            VirtualCollectionGalleryView(
              collections: filteredVirtualCollections,
              previewGames: model.collectionPreviewGames,
              session: model.session,
              service: model.service,
              controllerRouter: controllerRouter,
              focusSidebar: focusSidebar
            ) { collection in
              selectSidebarDestination(.collection(collection.id))
            }
          } else {
            switch currentPresentation {
            case .list:
              LibraryTableView(
                model: model,
                automaticallyFocusesContent: !hasSidebarFocus,
                setHidesGamesWithoutArtwork: setHidesGamesWithoutArtwork,
                requestFavoriteChange: requestFavoriteChange,
                requestGameDownload: requestGameDownload,
                requestGameDownloadRemoval: requestGameDownloadRemoval,
                requestGameExport: requestGameExport,
                requestGameDeletion: requestGameDeletion,
                controllerRouter: controllerRouter,
                focusSidebar: focusSidebar
              )
            case .artwork:
              LibraryGridView(
                model: model,
                sort: artworkSort,
                automaticallyFocusesContent: !hasSidebarFocus,
                setHidesGamesWithoutArtwork: setHidesGamesWithoutArtwork,
                requestFavoriteChange: requestFavoriteChange,
                requestGameDownload: requestGameDownload,
                requestGameDownloadRemoval: requestGameDownloadRemoval,
                requestGameExport: requestGameExport,
                requestGameDeletion: requestGameDeletion,
                controllerRouter: controllerRouter,
                focusSidebar: focusSidebar
              )
            }
          }
        }
        .onMoveCommand { direction in
          guard direction == .left else {
            return
          }
          hasSidebarFocus = true
        }
        .navigationTitle(model.title)
        .searchable(
          text: $searchText,
          placement: .toolbar,
          prompt:
            model.selection == .virtualCollections
            ? "Search Collections"
            : "Search Games"
        )
        .toolbar {
          if model.selection != .virtualCollections {
            ToolbarItem {
              Picker("Library View", selection: presentationBinding) {
                Label("List", systemImage: "list.bullet")
                  .tag(LibraryPresentation.list)
                Label("Artwork", systemImage: "square.grid.2x2")
                  .tag(LibraryPresentation.artwork)
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .help("Choose List or Artwork view")
            }
          }

          if model.selection != .virtualCollections,
            currentPresentation == .artwork
          {
            ToolbarItem {
              Menu {
                ForEach(ArtworkSort.allCases) { option in
                  Button {
                    artworkSort = option
                  } label: {
                    Label(
                      option.title,
                      systemImage: artworkSort == option
                        ? "checkmark"
                        : option.systemImage
                    )
                  }
                }
              } label: {
                Label("Sort Artwork", systemImage: "arrow.up.arrow.down")
              }
              .help("Sort artwork by \(artworkSort.title.lowercased())")
              .accessibilityLabel("Sort Artwork")
              .accessibilityValue(artworkSort.title)
            }
          }

          ToolbarItem {
            Button {
              Task {
                await model.refresh()
              }
            } label: {
              Label("Refresh Library", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.isSynchronizing)
          }

          if model.selection != .virtualCollections {
            ToolbarItem {
              Menu {
                Toggle(
                  "Hide [BIOS] Games",
                  isOn: hidesBIOSGamesBinding
                )

                if currentPresentation == .artwork {
                  Divider()
                  Toggle(
                    "Hide Games Without Artwork",
                    isOn: hidesGamesWithoutArtworkBinding
                  )
                }
              } label: {
                Label(
                  "Library Filters",
                  systemImage: isLibraryFilterActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
                )
              }
            }
          }

          if shouldOfferAllSystemsSearch {
            ToolbarItem {
              Toggle(
                "Search All Systems",
                isOn: searchesAllSystemsBinding
              )
              .toggleStyle(.checkbox)
            }
          }

          ToolbarItem(placement: .primaryAction) {
            Button {
              onOpenBigPicture()
            } label: {
              Label("Big Picture", systemImage: "tv")
            }
            .help("Enter Big Picture mode (or press Select/Home on a controller)")
            .accessibilityLabel("Enter Big Picture Mode")
          }
        }
      }
    }
    .coordinateSpace(name: LibraryCoordinateSpace.name)
    .background {
      ZStack {
        LibraryWindowProbe { window in
          libraryWindow = window
        }

        LibraryKeyboardMonitor { event in
          handleKeyboardEvent(event)
        }
      }
    }
    .task {
      await model.load()
    }
    .task {
      await pollControllers()
    }
    .task(id: persistedHidesBIOSGames) {
      await model.setHidesBIOSGames(persistedHidesBIOSGames)
    }
    .task(id: artworkFilterKey) {
      await model.setHidesGamesWithoutArtwork(
        currentPresentation == .artwork
          && persistedHidesGamesWithoutArtwork
      )
    }
    .task(
      id: LibrarySearchApplicationKey(
        selection: model.selection,
        searchText: searchText
      )
    ) {
      guard model.selection != .virtualCollections else {
        return
      }

      do {
        try await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else {
          return
        }
        await model.search(for: searchText)
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: .openVaultDownloadedGamesDidChange
      )
    ) { _ in
      Task {
        await model.reloadDownloadedGames()
      }
    }
    .sheet(item: $gameDeletionRequest) { request in
      GameDeletionConfirmationSheet(
        games: request.games,
        isDeleting: model.isDeletingGames
      ) { deletingFilesFromServer in
        await deleteGames(
          request.games,
          deletingFilesFromServer: deletingFilesFromServer
        )
      }
    }
    .alert(item: $libraryAlert) { alert in
      if alert.fileURLs.isEmpty {
        Alert(
          title: Text(alert.title),
          message: Text(alert.message),
          dismissButton: .default(Text("OK"))
        )
      } else {
        Alert(
          title: Text(alert.title),
          message: Text(alert.message),
          primaryButton: .default(Text("Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting(alert.fileURLs)
          },
          secondaryButton: .cancel(Text("OK"))
        )
      }
    }
  }

  private var populatedSystems: [LibrarySystem] {
    sidebarSystemSort.sorted(
      model.systems.filter {
        $0.gameCount > 0
          && (!model.hidesGamesWithoutArtwork
            || !model.systemIDsWithoutArtwork.contains($0.id))
      }
    )
  }

  private var supportedPopulatedSystems: [LibrarySystem] {
    populatedSystems.filter(isSystemSupported)
  }

  private var unsupportedPopulatedSystems: [LibrarySystem] {
    populatedSystems.filter { !isSystemSupported($0) }
  }

  private func isSystemSupported(_ system: LibrarySystem) -> Bool {
    Self.bundledLibretroManifest?
      .supportsSystem(named: system.name)
      ?? true
  }

  private var regularCollections: [LibraryCollection] {
    model.collections.filter {
      if case .regular = $0.id {
        true
      } else {
        false
      }
    }
  }

  private var smartCollections: [LibraryCollection] {
    model.collections.filter {
      if case .smart = $0.id {
        true
      } else {
        false
      }
    }
  }

  private var virtualCollections: [LibraryCollection] {
    model.collections.filter {
      if case .virtual = $0.id {
        true
      } else {
        false
      }
    }
  }

  private var filteredVirtualCollections: [LibraryCollection] {
    let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let collections =
      normalizedSearch.isEmpty
      ? virtualCollections
      : virtualCollections.filter {
        $0.name.localizedCaseInsensitiveContains(normalizedSearch)
          || ($0.virtualType?.localizedCaseInsensitiveContains(normalizedSearch) == true)
      }
    return collections.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private var emptySystems: [LibrarySystem] {
    sidebarSystemSort.sorted(
      model.systems.filter { $0.gameCount == 0 }
    )
  }

  private var shouldOfferAllSystemsSearch: Bool {
    guard !model.searchTerm.isEmpty else {
      return false
    }

    return switch model.selection {
    case .system, .systems, .collection:
      true
    case .allGames, .downloaded, .virtualCollections:
      false
    }
  }

  private func sidebarSystemRow(
    _ system: LibrarySystem
  ) -> some View {
    let systemGames = model.games(inSystem: system.id)
    let hasUndownloadedGames =
      !model.isDownloadingGames
      && systemGames.contains {
        !model.managedDownloadedGameIDs.contains($0.id)
      }

    return Text(system.name)
      .badge(system.gameCount)
      .tag(LibrarySelection.system(system.id))
      .contextMenu {
        Button {
          requestGameDownload(systemGames)
        } label: {
          Label(
            "Download All \(systemGames.count.formatted()) "
              + (systemGames.count == 1 ? "Game" : "Games"),
            systemImage: "arrow.down.circle"
          )
        }
        .disabled(
          systemGames.isEmpty
            || !hasUndownloadedGames
            || model.isDownloadingGames
        )
      }
  }

  private var currentPresentation: LibraryPresentation {
    switch model.selection {
    case .allGames:
      allGamesPresentation
    case .downloaded:
      collectionPresentation
    case .virtualCollections:
      .artwork
    case .system, .systems:
      systemPresentation
    case .collection:
      collectionPresentation
    }
  }

  private var presentationBinding: Binding<LibraryPresentation> {
    Binding(
      get: { currentPresentation },
      set: { newValue in
        switch model.selection {
        case .allGames:
          allGamesPresentation = newValue
        case .downloaded:
          collectionPresentation = newValue
        case .virtualCollections:
          break
        case .system, .systems:
          systemPresentation = newValue
        case .collection:
          collectionPresentation = newValue
        }
      }
    )
  }

  private var artworkFilterKey: ArtworkFilterApplicationKey {
    ArtworkFilterApplicationKey(
      presentation: currentPresentation,
      hidesGamesWithoutArtwork: persistedHidesGamesWithoutArtwork,
      synchronizedAt: model.lastSuccessfulSync
    )
  }

  private var hidesGamesWithoutArtworkBinding: Binding<Bool> {
    Binding(
      get: { persistedHidesGamesWithoutArtwork },
      set: setHidesGamesWithoutArtwork
    )
  }

  private var hidesBIOSGamesBinding: Binding<Bool> {
    Binding(
      get: { persistedHidesBIOSGames },
      set: { persistedHidesBIOSGames = $0 }
    )
  }

  private var isLibraryFilterActive: Bool {
    model.hidesBIOSGames
      || (currentPresentation == .artwork
        && model.hidesGamesWithoutArtwork)
  }

  private func setHidesGamesWithoutArtwork(_ enabled: Bool) {
    guard currentPresentation == .artwork else {
      return
    }
    persistedHidesGamesWithoutArtwork = enabled
  }

  private var searchesAllSystemsBinding: Binding<Bool> {
    Binding(
      get: { model.searchesAllSystems },
      set: { enabled in
        Task {
          await model.setSearchesAllSystems(enabled)
        }
      }
    )
  }

  private var sidebarSelectionBinding: Binding<Set<LibrarySelection>> {
    Binding(
      get: {
        sidebarSelectionTags(for: model.selection)
      },
      set: { selections in
        applySidebarSelections(selections)
      }
    )
  }

  private func sidebarSelectionTags(
    for selection: LibrarySelection
  ) -> Set<LibrarySelection> {
    switch selection {
    case .systems(let systemIDs):
      Set(systemIDs.map(LibrarySelection.system))
    default:
      [selection]
    }
  }

  private func applySidebarSelections(
    _ selections: Set<LibrarySelection>
  ) {
    let previousSelections = sidebarSelectionTags(for: model.selection)
    let systemIDs = Set(selections.compactMap { selection in
      if case .system(let systemID) = selection {
        return systemID
      }
      return nil
    })

    if selections.count == systemIDs.count {
      switch systemIDs.count {
      case 0:
        selectSidebarDestination(.allGames)
      case 1:
        if let systemID = systemIDs.first {
          selectSidebarDestination(.system(systemID))
        }
      default:
        selectSidebarDestination(.systems(systemIDs))
      }
      return
    }

    // Collections and special destinations stay single-select even though the
    // systems list supports native Command-click and Shift-click selection.
    if let newlySelected = selections.subtracting(previousSelections).first {
      selectSidebarDestination(newlySelected)
    } else if let nonSystemSelection = selections.first(where: {
      if case .system = $0 {
        return false
      }
      return true
    }) {
      selectSidebarDestination(nonSystemSelection)
    } else {
      selectSidebarDestination(.allGames)
    }
  }

  private func selectSidebarDestination(
    _ selection: LibrarySelection
  ) {
    guard model.selection != selection else {
      return
    }

    if model.selection == .virtualCollections
      || selection == .virtualCollections
    {
      searchText = ""
    }
    model.selection = selection
    Task {
      await model.reloadGames()
    }
  }

  private func requestGameDeletion(_ games: [GameSummary]) {
    var seenGameIDs: Set<Int> = []
    let uniqueGames = games.filter {
      seenGameIDs.insert($0.id).inserted
    }
    guard !uniqueGames.isEmpty else {
      return
    }
    gameDeletionRequest = GameDeletionRequest(games: uniqueGames)
  }

  private func requestFavoriteChange(
    _ games: [GameSummary],
    isFavorite: Bool
  ) {
    var seenGameIDs: Set<Int> = []
    let uniqueGames = games.filter {
      seenGameIDs.insert($0.id).inserted
    }
    guard !uniqueGames.isEmpty, !model.isUpdatingFavorites else {
      return
    }

    Task {
      do {
        try await model.setFavorite(isFavorite, for: uniqueGames)
      } catch is CancellationError {
        return
      } catch {
        libraryAlert = LibraryAlert(
          title:
            isFavorite
            ? "Couldn’t Add to Favorites"
            : "Couldn’t Remove from Favorites",
          message: error.localizedDescription
        )
      }
    }
  }

  private func requestGameDownload(_ games: [GameSummary]) {
    var seenGameIDs: Set<Int> = []
    let uniqueGames = games.filter {
      seenGameIDs.insert($0.id).inserted
    }
    guard !uniqueGames.isEmpty, !model.isDownloadingGames else {
      return
    }

    Task {
      let result = await model.downloadGames(uniqueGames)
      guard
        result.successfulItemCount > 0
          || result.failedItemCount > 0
      else {
        return
      }

      let errorDetails = result.errors.prefix(3).joined(separator: "\n")
      let omittedErrorCount = max(0, result.errors.count - 3)
      let omittedSuffix =
        omittedErrorCount > 0
        ? "\n…and \(omittedErrorCount.formatted()) more."
        : ""

      if result.completedWithoutErrors {
        libraryAlert = LibraryAlert(
          title:
            result.successfulItemCount == 1
            ? "Game Downloaded"
            : "\(result.successfulItemCount.formatted()) Games Downloaded",
          message:
            result.successfulItemCount == 1
            ? "Added the game to OpenVault’s local library."
            : "Added the selected games to OpenVault’s local library."
        )
      } else {
        libraryAlert = LibraryAlert(
          title:
            result.successfulItemCount > 0
            ? "Some Games Couldn’t Be Downloaded"
            : "Couldn’t Download Games",
          message:
            "Downloaded \(result.successfulItemCount.formatted()) and failed to download "
            + "\(result.failedItemCount.formatted())."
            + (errorDetails.isEmpty ? "" : "\n\n\(errorDetails)\(omittedSuffix)")
        )
      }
    }
  }

  private func requestGameDownloadRemoval(_ games: [GameSummary]) {
    var seenGameIDs: Set<Int> = []
    let uniqueGames = games.filter {
      seenGameIDs.insert($0.id).inserted
        && model.downloadedGameIDs.contains($0.id)
    }
    guard !uniqueGames.isEmpty, !model.isRemovingDownloads else {
      return
    }

    Task {
      let result = await model.removeDownloads(uniqueGames)
      guard
        result.successfulItemCount > 0
          || result.failedItemCount > 0
      else {
        return
      }

      let errorDetails = result.errors.prefix(3).joined(separator: "\n")
      let omittedErrorCount = max(0, result.errors.count - 3)
      let omittedSuffix =
        omittedErrorCount > 0
        ? "\n…and \(omittedErrorCount.formatted()) more."
        : ""

      if result.completedWithoutErrors {
        libraryAlert = LibraryAlert(
          title:
            result.successfulItemCount == 1
            ? "Download Removed"
            : "Downloads Removed",
          message:
            result.successfulItemCount == 1
            ? "Removed the game’s local ROM from OpenVault."
            : "Removed the selected local ROMs from OpenVault."
        )
      } else {
        libraryAlert = LibraryAlert(
          title:
            result.successfulItemCount > 0
            ? "Some Downloads Couldn’t Be Removed"
            : "Couldn’t Remove Downloads",
          message:
            "Removed \(result.successfulItemCount.formatted()) and failed to remove "
            + "\(result.failedItemCount.formatted())."
            + (errorDetails.isEmpty ? "" : "\n\n\(errorDetails)\(omittedSuffix)")
        )
      }
    }
  }

  private func requestGameExport(_ games: [GameSummary]) {
    var seenGameIDs: Set<Int> = []
    let uniqueGames = games.filter {
      seenGameIDs.insert($0.id).inserted
    }
    guard !uniqueGames.isEmpty, !model.isExportingGames else {
      return
    }

    Task {
      let result = await model.exportGames(uniqueGames)
      guard
        result.successfulItemCount > 0
          || result.failedItemCount > 0
      else {
        return
      }

      let errorDetails = result.errors.prefix(3).joined(separator: "\n")
      let omittedErrorCount = max(0, result.errors.count - 3)
      let omittedSuffix =
        omittedErrorCount > 0
        ? "\n…and \(omittedErrorCount.formatted()) more."
        : ""

      if result.completedWithoutErrors {
        libraryAlert = LibraryAlert(
          title:
            result.successfulItemCount == 1
            ? "Game Exported"
            : "\(result.successfulItemCount.formatted()) Games Exported",
          message:
            result.successfulItemCount == 1
            ? "Saved \(result.exportedFileURLs[0].lastPathComponent) to Downloads."
            : "Saved the selected games to Downloads.",
          fileURLs: result.exportedFileURLs
        )
      } else {
        libraryAlert = LibraryAlert(
          title:
            result.successfulItemCount > 0
            ? "Some Games Couldn’t Be Exported"
            : "Couldn’t Export Games",
          message:
            "Exported \(result.successfulItemCount.formatted()) and failed to export "
            + "\(result.failedItemCount.formatted())."
            + (errorDetails.isEmpty ? "" : "\n\n\(errorDetails)\(omittedSuffix)"),
          fileURLs: result.exportedFileURLs
        )
      }
    }
  }

  private func deleteGames(
    _ games: [GameSummary],
    deletingFilesFromServer: Bool
  ) async {
    do {
      let result = try await model.deleteGames(
        games,
        deletingFilesFromServer: deletingFilesFromServer
      )
      gameDeletionRequest = nil

      guard !result.completedWithoutErrors else {
        return
      }

      let errorDetails = result.errors.prefix(3).joined(separator: "\n")
      let omittedErrorCount = max(0, result.errors.count - 3)
      let omittedSuffix =
        omittedErrorCount > 0
        ? "\n…and \(omittedErrorCount.formatted()) more."
        : ""
      libraryAlert = LibraryAlert(
        title: "Some Games Couldn’t Be Deleted",
        message:
          "RomM deleted \(result.successfulItemCount.formatted()) and failed to delete "
          + "\(result.failedItemCount.formatted())."
          + (errorDetails.isEmpty ? "" : "\n\n\(errorDetails)\(omittedSuffix)")
      )
    } catch is CancellationError {
      gameDeletionRequest = nil
    } catch {
      gameDeletionRequest = nil
      libraryAlert = LibraryAlert(
        title: "Couldn’t Delete Games",
        message: error.localizedDescription
      )
    }
  }

  private var controllerSidebarSelections: [LibrarySelection] {
    var selections: [LibrarySelection] = [
      .allGames,
      .downloaded,
    ]
    selections.append(
      contentsOf: regularCollections.map {
        .collection($0.id)
      }
    )
    if showsSmartCollections {
      selections.append(
        contentsOf: smartCollections.map {
          .collection($0.id)
        }
      )
    }
    if !virtualCollections.isEmpty {
      selections.append(.virtualCollections)
      if showsVirtualCollections {
        selections.append(
          contentsOf: virtualCollections.map {
            .collection($0.id)
          }
        )
      }
    }
    selections.append(
      contentsOf: supportedPopulatedSystems.map {
        .system($0.id)
      }
    )
    if showsUnsupportedSystems {
      selections.append(
        contentsOf: unsupportedPopulatedSystems.map {
          .system($0.id)
        }
      )
    }
    if showsEmptySystems {
      selections.append(
        contentsOf: emptySystems.map {
          .system($0.id)
        }
      )
    }
    return selections
  }

  private func focusSidebar() {
    hasSidebarFocus = true
  }

  private func emitControllerEvent(_ command: LibraryControllerCommand) {
    controllerRouter.send(command)
  }

  private func handleKeyboardEvent(_ event: NSEvent) -> Bool {
    guard
      let command = LibraryKeyboardNavigation.command(
        forKeyCode: event.keyCode,
        modifierFlags: event.modifierFlags
      )
    else {
      return false
    }

    handleControllerCommand(command)
    return true
  }

  private func handleControllerCommand(_ command: LibraryControllerCommand) {
    if command == .openBigPicture {
      onOpenBigPicture()
      return
    }

    guard hasSidebarFocus else {
      emitControllerEvent(command)
      return
    }

    switch command {
    case .up:
      moveSidebarSelection(by: -1)
    case .down:
      moveSidebarSelection(by: 1)
    case .right, .activate:
      hasSidebarFocus = false
      emitControllerEvent(.focusContent)
    case .left, .back, .openBigPicture, .focusContent:
      break
    }
  }

  private func moveSidebarSelection(by offset: Int) {
    let selections = controllerSidebarSelections
    guard !selections.isEmpty else {
      return
    }

    let selectedIndices = sidebarSelectionTags(for: model.selection)
      .compactMap { selections.firstIndex(of: $0) }
    let currentIndex =
      offset > 0
      ? (selectedIndices.max() ?? -1)
      : (selectedIndices.min() ?? selections.count)
    let destinationIndex = min(
      max(currentIndex + offset, 0),
      selections.count - 1
    )
    let destination = selections[destinationIndex]
    guard destination != model.selection else {
      return
    }
    selectSidebarDestination(destination)
  }

  private func pollControllers() async {
    GCController.startWirelessControllerDiscovery(completionHandler: nil)
    defer {
      GCController.stopWirelessControllerDiscovery()
    }

    while !Task.isCancelled {
      let state = BigPictureControllerState.current
      guard
        let libraryWindow,
        NSApplication.shared.keyWindow === libraryWindow
      else {
        controllerNavigation.synchronize(with: state)
        try? await Task.sleep(for: .milliseconds(30))
        continue
      }

      if let command = controllerNavigation.command(
        for: state,
        at: ProcessInfo.processInfo.systemUptime
      ) {
        handleControllerCommand(command)
      }
      try? await Task.sleep(for: .milliseconds(30))
    }
  }
}

private struct LibraryDownloadedSidebarLabel: View {
  let model: LibraryModel

  var body: some View {
    Label("Downloaded", systemImage: "arrow.down.circle")
      .badge(model.downloadedGameCount)
  }
}

private struct LibrarySidebarStatus: View {
  let model: LibraryModel

  @ViewBuilder
  var body: some View {
    if model.isDownloadingGames, let progress = model.downloadProgress {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Image(systemName: "arrow.down.circle.fill")
          Text(downloadStatusLabel(progress))
            .lineLimit(1)
          Spacer(minLength: 4)
          Text(
            Int(progress.fractionCompleted * 100)
              .formatted()
              + "%"
          )
          .monospacedDigit()
        }

        ProgressView(value: progress.fractionCompleted)
          .progressViewStyle(.linear)
          .tint(Color.accentColor)
      }
      .sidebarDownloadStatusStyle()
      .help(downloadStatusHelp(progress))
      .accessibilityElement(children: .combine)
      .accessibilityLabel(downloadStatusLabel(progress))
      .accessibilityValue(
        "\(Int(progress.fractionCompleted * 100)) percent"
      )
    } else if model.isSynchronizing {
      HStack(spacing: 7) {
        ProgressView()
          .controlSize(.small)
        Text(
          model.isPurgingLocalCache
            ? "Purging local cache…"
            : synchronizationLabel
        )
        .lineLimit(1)
        Spacer(minLength: 0)
        sidebarSyncButton
      }
      .sidebarStatusStyle()
    } else if let refreshErrorMessage = model.refreshErrorMessage {
      HStack(spacing: 7) {
        Image(
          systemName: model.isShowingStaleData
            ? "wifi.slash"
            : "exclamationmark.triangle.fill"
        )
        Text(
          model.isShowingStaleData
            ? "Offline · \(model.allGameCount.formatted()) games"
            : "Sync failed"
        )
        .lineLimit(1)
        Spacer(minLength: 0)
        sidebarSyncButton
      }
      .sidebarStatusStyle()
      .help("\(cachedLibraryHelp) \(refreshErrorMessage)")
    } else if model.isShowingStaleData {
      HStack(spacing: 7) {
        Image(systemName: "wifi.slash")
        Text("Cached · \(model.allGameCount.formatted()) games")
          .lineLimit(1)
        Spacer(minLength: 0)
        sidebarSyncButton
      }
      .sidebarStatusStyle()
      .help(cachedLibraryHelp)
    } else {
      HStack(spacing: 7) {
        Image(systemName: "checkmark.circle")
        Text(idleStatusLabel)
          .lineLimit(1)
        Spacer(minLength: 0)
        sidebarSyncButton
      }
      .sidebarStatusStyle()
      .help(cachedLibraryHelp)
    }
  }

  private var sidebarSyncButton: some View {
    Button {
      Task {
        await model.refresh()
      }
    } label: {
      Image(systemName: "arrow.clockwise")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .disabled(model.isLoading || model.isSynchronizing)
    .help("Sync Library with RomM")
    .accessibilityLabel("Sync Library")
  }

  private func downloadStatusLabel(
    _ progress: LibraryDownloadProgress
  ) -> String {
    "Downloading \(progress.currentGameNumber.formatted()) of "
      + progress.totalGameCount.formatted()
  }

  private func downloadStatusHelp(
    _ progress: LibraryDownloadProgress
  ) -> String {
    var components: [String] = []
    if let currentGameName = progress.currentGameName {
      components.append("Downloading \(currentGameName).")
    }
    components.append(
      "\(progress.processedGameCount.formatted()) completed"
        + (
          progress.failedGameCount > 0
          ? ", \(progress.failedGameCount.formatted()) failed."
          : "."
        )
    )
    if let transferProgress = progress.currentTransferProgress {
      let received = transferProgress.bytesReceived.formatted(
        .byteCount(style: .file)
      )
      if let total = transferProgress.totalBytesExpected {
        components.append(
          "\(received) of \(total.formatted(.byteCount(style: .file)))."
        )
      } else {
        components.append("\(received) received.")
      }
    }
    return components.joined(separator: " ")
  }

  private var synchronizationLabel: String {
    guard model.synchronizationTotalGameCount > 0 else {
      return "Syncing Library"
    }

    if model.synchronizedGameCount >= model.synchronizationTotalGameCount {
      return "Finalizing Library"
    }

    return "Syncing \(model.synchronizedGameCount.formatted()) of "
      + model.synchronizationTotalGameCount.formatted()
  }

  private var cachedLibraryHelp: String {
    let timestamp =
      model.lastSuccessfulSync.map {
        "Last updated \($0.formatted(date: .abbreviated, time: .shortened))."
      } ?? "No complete synchronization timestamp is available."

    if let refreshErrorMessage = model.refreshErrorMessage {
      return "\(timestamp) \(refreshErrorMessage)"
    }
    return timestamp
  }

  private var idleStatusLabel: String {
    let gameCount = "\(model.allGameCount.formatted()) games"
    guard let lastSuccessfulSync = model.lastSuccessfulSync else {
      return gameCount
    }
    return "\(gameCount) · \(lastSuccessfulSync.formatted(date: .omitted, time: .shortened))"
  }
}

private struct LibraryWindowProbe: NSViewRepresentable {
  let didMoveToWindow: @MainActor (NSWindow?) -> Void

  func makeNSView(context: Context) -> LibraryProbeView {
    let view = LibraryProbeView()
    view.didMoveToWindow = didMoveToWindow
    return view
  }

  func updateNSView(_ nsView: LibraryProbeView, context: Context) {
    nsView.didMoveToWindow = didMoveToWindow
    Task { @MainActor in
      didMoveToWindow(nsView.window)
    }
  }
}

private final class LibraryProbeView: NSView {
  var didMoveToWindow: (@MainActor (NSWindow?) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    Task { @MainActor in
      didMoveToWindow?(window)
    }
  }
}

private struct LibraryKeyboardMonitor: NSViewRepresentable {
  let handleKeyDown: @MainActor (NSEvent) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(handleKeyDown: handleKeyDown)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.handleKeyDown = handleKeyDown
    context.coordinator.attach(to: nsView)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stopMonitoring()
  }

  @MainActor
  final class Coordinator {
    var handleKeyDown: @MainActor (NSEvent) -> Bool

    private weak var view: NSView?
    private var monitor: Any?

    init(handleKeyDown: @escaping @MainActor (NSEvent) -> Bool) {
      self.handleKeyDown = handleKeyDown
    }

    func attach(to view: NSView) {
      self.view = view
      guard monitor == nil else {
        return
      }

      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak self] event in
        guard
          let self,
          let window = self.view?.window,
          window.isKeyWindow,
          event.window === window,
          !Self.isEditingText(in: window),
          self.handleKeyDown(event)
        else {
          return event
        }
        return nil
      }
    }

    func stopMonitoring() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
      }
      monitor = nil
    }

    private static func isEditingText(in window: NSWindow) -> Bool {
      if let textView = window.firstResponder as? NSTextView {
        return textView.isEditable
      }
      if let textField = window.firstResponder as? NSTextField {
        return textField.isEditable
      }
      return false
    }
  }
}

private struct GameDeletionConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss

  let games: [GameSummary]
  let isDeleting: Bool
  let onConfirm: (Bool) async -> Void

  @State private var deletesFilesFromServer = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Image(systemName: "trash")
          .font(.title2)
          .foregroundStyle(.red)

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.headline)
          Text("This changes the connected RomM library.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      List(games) { game in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(game.name)
              .lineLimit(1)
            Text(game.systemName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
      }
      .frame(height: min(220, max(72, CGFloat(games.count) * 42)))

      Toggle(
        "Also permanently delete ROM files from the server",
        isOn: $deletesFilesFromServer
      )

      Text(deletionExplanation)
        .font(.callout)
        .foregroundStyle(deletesFilesFromServer ? .red : .secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()

        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isDeleting)

        Button(role: .destructive) {
          Task {
            await onConfirm(deletesFilesFromServer)
          }
        } label: {
          if isDeleting {
            HStack(spacing: 7) {
              ProgressView()
                .controlSize(.small)
              Text("Deleting…")
            }
          } else {
            Text("Delete")
          }
        }
        .disabled(isDeleting)
      }
    }
    .padding(24)
    .frame(width: 520)
    .interactiveDismissDisabled(isDeleting)
  }

  private var title: String {
    games.count == 1
      ? "Delete “\(games[0].name)” from RomM?"
      : "Delete \(games.count.formatted()) Games from RomM?"
  }

  private var deletionExplanation: String {
    if deletesFilesFromServer {
      return
        "The selected database records and ROM files will be deleted from the RomM server. This cannot be undone by OpenVault."
    }
    return
      "Only the RomM database records will be removed. The ROM files remain on the server and may be discovered again by a later scan."
  }
}

private struct VirtualCollectionGalleryView: View {
  @Environment(\.accessibilityReduceMotion) private var reducesMotion

  let collections: [LibraryCollection]
  let previewGames: [LibraryCollection.ID: [GameSummary]]
  let session: ServerSession
  let service: any LibraryServing
  let controllerRouter: LibraryControllerRouter
  let focusSidebar: () -> Void
  let openCollection: (LibraryCollection) -> Void

  @State private var selectedIndex = 0
  @State private var scrollTargetID: LibraryCollection.ID?
  @State private var gridWidth: CGFloat = 0
  @Namespace private var selectionHighlight

  private let columns = [
    GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 22, alignment: .top)
  ]

  var body: some View {
    if collections.isEmpty {
      ContentUnavailableView {
        Label("No Matching Collections", systemImage: "wand.and.stars")
      } description: {
        Text("Try a different collection search.")
      }
    } else {
      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
          ForEach(collections) { collection in
            Button {
              openCollection(collection)
            } label: {
              VirtualCollectionCard(
                collection: collection,
                games: previewGames[collection.id] ?? [],
                session: session,
                service: service
              )
            }
            .buttonStyle(.plain)
            .help("Open \(collection.name)")
            .id(collection.id)
            .overlay {
              if collections.indices.contains(selectedIndex),
                collections[selectedIndex].id == collection.id
              {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .stroke(Color.accentColor, lineWidth: 3)
                  .matchedGeometryEffect(
                    id: "virtual-collection-selection",
                    in: selectionHighlight
                  )
                  .allowsHitTesting(false)
              }
            }
          }
        }
      }
      .contentMargins(28, for: .scrollContent)
      .scrollPosition(id: $scrollTargetID, anchor: .center)
      .onGeometryChange(for: CGFloat.self) { geometry in
        geometry.size.width
      } action: { width in
        gridWidth = width
      }
      .overlay(alignment: .topTrailing) {
        Text(
          collections.count == 1
            ? "1 collection"
            : "\(collections.count.formatted()) collections"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 12)
        .padding(.trailing, 18)
        .allowsHitTesting(false)
      }
      .onReceive(controllerRouter.commands) { command in
        handleControllerCommand(command)
      }
      .onChange(of: collections.map(\.id)) { _, _ in
        selectedIndex = min(
          selectedIndex,
          max(collections.count - 1, 0)
        )
      }
    }
  }

  private var columnCount: Int {
    max(1, Int((gridWidth + 22) / (230 + 22)))
  }

  private func handleControllerCommand(
    _ command: LibraryControllerCommand
  ) {
    switch command {
    case .focusContent:
      updateScrollTarget()
    case .up:
      moveSelection(by: -columnCount)
    case .down:
      moveSelection(by: columnCount)
    case .left:
      guard selectedIndex % columnCount != 0 else {
        focusSidebar()
        return
      }
      moveSelection(by: -1)
    case .right:
      moveSelection(by: 1)
    case .activate:
      guard collections.indices.contains(selectedIndex) else {
        return
      }
      openCollection(collections[selectedIndex])
    case .back:
      focusSidebar()
    case .openBigPicture:
      break
    }
  }

  private func moveSelection(by offset: Int) {
    guard !collections.isEmpty else {
      return
    }
    withAnimation(
      reducesMotion ? nil : .snappy(duration: 0.16, extraBounce: 0)
    ) {
      selectedIndex = min(
        max(selectedIndex + offset, 0),
        collections.count - 1
      )
      updateScrollTarget()
    }
  }

  private func updateScrollTarget() {
    guard collections.indices.contains(selectedIndex) else {
      return
    }
    scrollTargetID = collections[selectedIndex].id
  }
}

private struct VirtualCollectionCard: View {
  let collection: LibraryCollection
  let games: [GameSummary]
  let session: ServerSession
  let service: any LibraryServing

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      collectionArtwork
        .frame(height: 160)

      VStack(alignment: .leading, spacing: 8) {
        Text(collection.name)
          .font(.headline)
          .lineLimit(2)

        HStack(spacing: 8) {
          Label(collectionTypeLabel, systemImage: collection.systemImage)
            .lineLimit(1)

          Spacer(minLength: 8)

          Text(
            collection.gameCount == 1
              ? "1 game"
              : "\(collection.gameCount.formatted()) games"
          )
          .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .padding(14)
    }
    .background(.quaternary.opacity(0.7))
    .clipShape(.rect(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(.separator.opacity(0.45), lineWidth: 0.5)
    }
    .contentShape(.rect(cornerRadius: 14))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(collection.name), \(collection.gameCount.formatted()) games"
    )
  }

  @ViewBuilder
  private var collectionArtwork: some View {
    let artworkGames = games.filter { $0.coverURL != nil }

    ZStack {
      Rectangle()
        .fill(.quaternary)

      if artworkGames.isEmpty {
        Image(systemName: collection.systemImage)
          .font(.system(size: 42, weight: .light))
          .foregroundStyle(.tertiary)
      } else {
        GeometryReader { geometry in
          let coverCount = CGFloat(artworkGames.count)
          let coverWidth = min(
            geometry.size.width / coverCount,
            geometry.size.height * 0.75
          )

          HStack(spacing: 4) {
            ForEach(artworkGames) { game in
              RomMImageView(
                url: game.coverURL,
                session: session,
                service: service,
                targetSize: CGSize(width: 240, height: 320),
                contentMode: .fit,
                placeholderSystemImage: "gamecontroller",
                cornerRadius: 6,
                imagePadding: 2
              )
              .frame(width: coverWidth)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(10)
        }
      }
    }
    .clipped()
  }

  private var collectionTypeLabel: String {
    guard let virtualType = collection.virtualType, !virtualType.isEmpty else {
      return "Automatic"
    }
    return
      virtualType
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }
}

private struct LibraryGameSelectionContextMenu<PrimaryActions: View>: View {
  let model: LibraryModel
  let selectedGames: [GameSummary]
  let requestFavoriteChange: ([GameSummary], Bool) -> Void
  let requestGameDownload: ([GameSummary]) -> Void
  let requestGameDownloadRemoval: ([GameSummary]) -> Void
  let requestGameExport: ([GameSummary]) -> Void
  let requestGameDeletion: ([GameSummary]) -> Void
  let requestGameInfo: (GameSummary) -> Void
  let primaryActions: () -> PrimaryActions

  init(
    model: LibraryModel,
    selectedGames: [GameSummary],
    requestFavoriteChange: @escaping ([GameSummary], Bool) -> Void,
    requestGameDownload: @escaping ([GameSummary]) -> Void,
    requestGameDownloadRemoval: @escaping ([GameSummary]) -> Void,
    requestGameExport: @escaping ([GameSummary]) -> Void,
    requestGameDeletion: @escaping ([GameSummary]) -> Void,
    requestGameInfo: @escaping (GameSummary) -> Void,
    @ViewBuilder primaryActions: @escaping () -> PrimaryActions
  ) {
    self.model = model
    self.selectedGames = selectedGames
    self.requestFavoriteChange = requestFavoriteChange
    self.requestGameDownload = requestGameDownload
    self.requestGameDownloadRemoval = requestGameDownloadRemoval
    self.requestGameExport = requestGameExport
    self.requestGameDeletion = requestGameDeletion
    self.requestGameInfo = requestGameInfo
    self.primaryActions = primaryActions
  }

  var body: some View {
    let gamesToDownload = selectedGames.filter {
      !model.downloadedGameIDs.contains($0.id)
    }
    let removesDownloads =
      !selectedGames.isEmpty && gamesToDownload.isEmpty
    let favoriteChange = RomMFavorites.membershipChange(
      for: Set(selectedGames.map(\.id)),
      favoriteGameIDs: model.favoriteGameIDs
    )
    let removesFavorites = favoriteChange == .remove

    primaryActions()

    if selectedGames.count == 1, let selectedGame = selectedGames.first {
      Button {
        requestGameInfo(selectedGame)
      } label: {
        Label("Get Info", systemImage: "info.circle")
      }

      Divider()
    }

    Button {
      requestFavoriteChange(selectedGames, !removesFavorites)
    } label: {
      Label(
        removesFavorites ? "Remove from Favorites" : "Add to Favorites",
        systemImage: removesFavorites ? "star.slash" : "star"
      )
    }
    .disabled(
      selectedGames.isEmpty
        || model.favoriteCollectionID == nil
        || model.isUpdatingFavorites
    )

    Divider()

    Button(role: removesDownloads ? .destructive : nil) {
      if removesDownloads {
        requestGameDownloadRemoval(selectedGames)
      } else {
        requestGameDownload(gamesToDownload)
      }
    } label: {
      Label(
        removesDownloads
          ? (
            selectedGames.count == 1
              ? "Remove Download"
              : "Remove \(selectedGames.count.formatted()) Downloads"
          )
          : (
            gamesToDownload.count == 1
              ? "Download"
              : "Download \(gamesToDownload.count.formatted()) Games"
          ),
        systemImage: removesDownloads ? "trash" : "arrow.down.circle"
      )
    }
    .disabled(
      selectedGames.isEmpty
        || model.isDownloadingGames
        || model.isRemovingDownloads
        || (!removesDownloads
          && gamesToDownload.allSatisfy {
            $0.isMissingFromFileSystem == true
          })
    )

    Button {
      requestGameExport(selectedGames)
    } label: {
      Label(
        selectedGames.count == 1
          ? "Export"
          : "Export \(selectedGames.count.formatted()) Games",
        systemImage: "square.and.arrow.up"
      )
    }
    .disabled(
      selectedGames.isEmpty
        || model.isExportingGames
        || selectedGames.allSatisfy {
          $0.isMissingFromFileSystem == true
            && !model.downloadedGameIDs.contains($0.id)
        }
    )

    if NSEvent.modifierFlags.contains(.option) {
      Divider()

      Button(role: .destructive) {
        requestGameDeletion(selectedGames)
      } label: {
        Label(
          selectedGames.count == 1
            ? "Delete from RomM…"
            : "Delete \(selectedGames.count.formatted()) Games from RomM…",
          systemImage: "trash"
        )
      }
      .disabled(selectedGames.isEmpty || model.isDeletingGames)
    }
  }
}

private struct LibraryTableView: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reducesMotion

  let model: LibraryModel
  let automaticallyFocusesContent: Bool
  let setHidesGamesWithoutArtwork: (Bool) -> Void
  let requestFavoriteChange: ([GameSummary], Bool) -> Void
  let requestGameDownload: ([GameSummary]) -> Void
  let requestGameDownloadRemoval: ([GameSummary]) -> Void
  let requestGameExport: ([GameSummary]) -> Void
  let requestGameDeletion: ([GameSummary]) -> Void
  let controllerRouter: LibraryControllerRouter
  let focusSidebar: () -> Void

  @State private var sortOrder = [
    KeyPathComparator(\GameSummary.name)
  ]
  @State private var sortedGames: [GameSummary] = []
  @State private var isSorting = true
  @State private var sortingRequestID = UUID()
  @State private var tableIdentity = UUID()
  @State private var selectedGameIDs: Set<Int> = []
  @State private var preparingGameID: Int?
  @State private var playbackAlert: LibraryAlert?
  @State private var hasPreparedRows = false
  @State private var controllerTableScrollTargetID: Int?
  @State private var controllerBrowserColumnIndex: Int?
  @FocusState private var hasTableFocus: Bool
  @AppStorage(LibraryPreferenceKey.tableColumns)
  private var columnCustomization = TableColumnCustomization<GameSummary>()
  @AppStorage(LibraryPreferenceKey.showsGenreBrowser)
  private var showsGenreBrowser = false
  @AppStorage(LibraryPreferenceKey.showsYearBrowser)
  private var showsYearBrowser = false
  @AppStorage(LibraryPreferenceKey.showsRegionBrowser)
  private var showsRegionBrowser = false
  @AppStorage(LibraryPreferenceKey.showsStatusBrowser)
  private var showsStatusBrowser = false
  @AppStorage(LibraryPreferenceKey.showsSaveDataBrowser)
  private var showsSaveDataBrowser = false
  @AppStorage(LibraryPreferenceKey.showsDownloadedBrowser)
  private var showsDownloadedBrowser = true
  @AppStorage(LibraryPreferenceKey.showsArtworkBrowser)
  private var showsArtworkBrowser = false
  @AppStorage(LibraryPreferenceKey.browserOrder)
  private var browserOrder = LibraryBrowserColumn.allCases
    .map(\.rawValue)
    .joined(separator: ",")

  @State private var selectedSystem: String?
  @State private var selectedGenre: String?
  @State private var selectedYear: String?
  @State private var selectedRegion: String?
  @State private var selectedStatus: String?
  @State private var selectedSaveData: String?
  @State private var selectedDownloaded: String?
  @State private var selectedArtwork: String?

  var body: some View {
    Group {
      if model.isLoading, model.games.isEmpty {
        ProgressView("Loading \(model.title)…")
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let errorMessage = model.errorMessage, model.games.isEmpty {
        ContentUnavailableView {
          Label("Couldn’t Load Library", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("Try Again") {
            Task {
              await model.retry()
            }
          }
          .buttonStyle(.glassProminent)
        }
      } else if model.games.isEmpty {
        if model.searchTerm.isEmpty {
          ContentUnavailableView {
            Label("No Games", systemImage: "rectangle.stack.badge.minus")
          } description: {
            Text("RomM did not return any games for \(model.title).")
          }
        } else {
          ContentUnavailableView.search(text: model.searchTerm)
        }
      } else if model.displayedGames.isEmpty {
        if model.hidesGamesWithoutArtwork {
          ContentUnavailableView {
            Label("No Games with Artwork", systemImage: "photo.badge.exclamationmark")
          } description: {
            Text("No artwork was found in the loaded results.")
          } actions: {
            Button("Show Games Without Artwork") {
              setHidesGamesWithoutArtwork(false)
            }
          }
        } else {
          ContentUnavailableView.search(text: model.searchTerm)
        }
      } else if isSorting, sortedGames.isEmpty {
        ProgressView("Preparing \(model.title)…")
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        gameTable
      }
    }
    .task(id: tableRowsKey) {
      await rebuildSortedGames()
    }
    .onChange(of: model.selection) { _, _ in
      clearBrowserFilters()
      selectedGameIDs.removeAll()
      controllerBrowserColumnIndex = nil
    }
    .onChange(of: model.searchTerm) { _, _ in
      selectedGameIDs.removeAll()
    }
    .onChange(of: sortOrder) {
      Task {
        await rebuildSortedGames()
      }
    }
    .onReceive(controllerRouter.commands) { command in
      handleControllerCommand(command)
    }
    .alert(item: $playbackAlert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text("OK"))
      )
    }
  }

  private var gameTable: some View {
    VSplitView {
      columnBrowser
        .frame(minHeight: 132, idealHeight: 190, maxHeight: 300)

      libraryTable
        .frame(minHeight: 260)
    }
  }

  private func isPlayable(_ game: GameSummary) -> Bool {
    LibraryGamePlayability.isPlayable(
      game,
      downloadedGameIDs: model.downloadedGameIDs
    )
  }

  private var libraryTable: some View {
    Table(
      sortedGames,
      selection: $selectedGameIDs,
      sortOrder: $sortOrder,
      columnCustomization: $columnCustomization
    ) {
      TableColumn("Game", value: \.name) { game in
        HStack(spacing: 7) {
          Button {
            play(game)
          } label: {
            Group {
              if preparingGameID == game.id {
                ProgressView()
                  .controlSize(.mini)
              } else {
                Image(systemName: "play.fill")
                  .font(.system(size: 8, weight: .bold))
                  .foregroundStyle(.secondary)
              }
            }
            .frame(width: 10)
          }
          .buttonStyle(.plain)
          .disabled(
            !isPlayable(game)
              || (preparingGameID != nil && preparingGameID != game.id)
          )
          .opacity(isPlayable(game) ? 1 : 0)
          .accessibilityLabel("Play \(game.name)")

          Text(game.name)
            .lineLimit(1)

          if model.prioritizesFavoritesInCurrentView,
            model.favoriteGameIDs.contains(game.id)
          {
            Image(systemName: "star.fill")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.yellow)
              .accessibilityLabel("Favorite")
          }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          play(game)
        }
      }
      .width(min: 220, ideal: 380)
      .customizationID("game")
      .disabledCustomizationBehavior(.visibility)

      if !isSingleSystemView {
        TableColumn("System", value: \.systemName)
          .width(min: 120, ideal: 170)
          .customizationID("system")
          .defaultVisibility(.visible)
      }

      TableColumn("Downloaded") { game in
        AvailabilityCheckbox(
          value: model.downloadedGameIDs.contains(game.id),
          availableLabel: "Downloaded",
          unavailableLabel: "Not downloaded"
        )
      }
      .width(86)
      .customizationID("downloaded")
      .defaultVisibility(.visible)

      TableColumn("Save", value: \.saveSortValue) { game in
        AvailabilityCheckbox(
          value: game.hasSave,
          availableLabel: "Has save",
          unavailableLabel: "No save"
        )
      }
      .width(58)
      .customizationID("save")
      .defaultVisibility(.visible)

      TableColumn("State", value: \.stateSortValue) { game in
        AvailabilityCheckbox(
          value: game.hasState,
          availableLabel: "Has save state",
          unavailableLabel: "No save state"
        )
      }
      .width(58)
      .customizationID("state")
      .defaultVisibility(.visible)

      Group {
        TableColumn("Status", value: \GameSummary.statusColumnValue) { game in
          Text(game.statusColumnValue)
        }
        .width(min: 90, ideal: 120)
        .customizationID("status")
        .defaultVisibility(.hidden)

        TableColumn("Completion", value: \GameSummary.completionSortValue) { game in
          Text("\(game.completionSortValue)%")
            .monospacedDigit()
        }
        .width(88)
        .customizationID("completion")
        .defaultVisibility(.hidden)

        TableColumn("Rating", value: \GameSummary.ratingSortValue) { game in
          Text(game.ratingColumnValue)
            .monospacedDigit()
        }
        .width(70)
        .customizationID("rating")
        .defaultVisibility(.hidden)

        TableColumn("Difficulty", value: \GameSummary.difficultySortValue) { game in
          Text(game.difficultyColumnValue)
            .monospacedDigit()
        }
        .width(76)
        .customizationID("difficulty")
        .defaultVisibility(.hidden)

        TableColumn("Region", value: \GameSummary.regionColumnValue)
          .width(min: 80, ideal: 120)
          .customizationID("region")
          .defaultVisibility(.hidden)

        TableColumn("Size", value: \GameSummary.fileSizeSortValue) { game in
          Text(game.fileSizeColumnValue)
            .monospacedDigit()
        }
        .width(min: 80, ideal: 100)
        .customizationID("size")
        .defaultVisibility(.hidden)

        TableColumn("Artwork", value: \GameSummary.artworkSortValue) { game in
          AvailabilityCheckbox(
            value: game.coverURL != nil,
            availableLabel: "Has artwork",
            unavailableLabel: "No artwork"
          )
        }
        .width(74)
        .customizationID("artwork")
        .defaultVisibility(.hidden)

        TableColumn("Identified", value: \GameSummary.identifiedSortValue) { game in
          AvailabilityCheckbox(
            value: game.isIdentified,
            availableLabel: "Identified",
            unavailableLabel: "Not identified"
          )
        }
        .width(78)
        .customizationID("identified")
        .defaultVisibility(.hidden)

        TableColumn("Missing", value: \GameSummary.missingSortValue) { game in
          AvailabilityCheckbox(
            value: game.isMissingFromFileSystem,
            availableLabel: "Missing from RomM",
            unavailableLabel: "Available in RomM",
            isWarning: true
          )
        }
        .width(70)
        .customizationID("missing")
        .defaultVisibility(.hidden)

        TableColumn("Updated", value: \GameSummary.updatedColumnValue)
          .width(min: 92, ideal: 110)
          .customizationID("updated")
          .defaultVisibility(.hidden)
      }
    }
    .scrollPosition(id: $controllerTableScrollTargetID, anchor: .center)
    .contextMenu(forSelectionType: Int.self) { selectedIDs in
      let selectedGames = sortedGames.filter { selectedIDs.contains($0.id) }
      LibraryGameSelectionContextMenu(
        model: model,
        selectedGames: selectedGames,
        requestFavoriteChange: requestFavoriteChange,
        requestGameDownload: requestGameDownload,
        requestGameDownloadRemoval: requestGameDownloadRemoval,
        requestGameExport: requestGameExport,
        requestGameDeletion: requestGameDeletion,
        requestGameInfo: openGameInfo
      ) {
        if selectedGames.count == 1,
          let selectedGame = selectedGames.first,
          isPlayable(selectedGame)
        {
          Button {
            play(selectedGame)
          } label: {
            Label("Play", systemImage: "play.fill")
          }

          Button {
            play(selectedGame, fromBeginning: true)
          } label: {
            Label(
              "Play from Beginning",
              systemImage: "forward.end.fill"
            )
          }

          Divider()
        }
      }
    }
    .focused($hasTableFocus)
    .focusedSceneValue(\.openGameInfo, gameInfoAction)
    .onKeyPress("a", phases: .down) { keyPress in
      guard keyPress.modifiers.contains(.command) else {
        return .ignored
      }

      selectedGameIDs = Set(sortedGames.lazy.map(\.id))
      return .handled
    }
    .overlay {
      if filteredGames.isEmpty {
        ContentUnavailableView {
          Label("No Matching Games", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
          Text("Clear one or more browser selections to see games.")
        } actions: {
          Button("Clear Browser Filters") {
            clearBrowserFilters()
          }
        }
      }
    }
    .overlay(alignment: .bottom) {
      if model.isLoadingMore || isSorting {
        ProgressView()
          .controlSize(.small)
          .padding(8)
          .openVaultGlass(in: Capsule())
          .padding()
      }
    }
    .id(tableIdentity)
  }

  private func play(
    _ game: GameSummary,
    fromBeginning: Bool = false
  ) {
    guard preparingGameID == nil, isPlayable(game) else {
      return
    }

    preparingGameID = game.id
    Task {
      defer {
        preparingGameID = nil
      }

      switch await LibraryPlaybackPreparation.prepare(game, model: model) {
      case let .ready(request):
        openWindow(
          value: fromBeginning ? request.startingFresh() : request
        )
      case let .failed(alert):
        playbackAlert = alert
      case .cancelled:
        break
      }
    }
  }

  private var gameInfoAction: OpenGameInfoAction? {
    guard
      selectedGameIDs.count == 1,
      let selectedGame = sortedGames.first(where: {
        selectedGameIDs.contains($0.id)
      })
    else {
      return nil
    }
    return OpenGameInfoAction {
      openGameInfo(selectedGame)
    }
  }

  private func openGameInfo(_ game: GameSummary) {
    openWindow(
      value: GameInfoRequest(
        game: game,
        lastLibrarySync: model.lastSuccessfulSync
      )
    )
  }

  private func handleControllerCommand(
    _ command: LibraryControllerCommand
  ) {
    switch command {
    case .focusContent:
      controllerBrowserColumnIndex = nil
      hasTableFocus = true
      selectTableGameIfNeeded()
    case .up:
      if let controllerBrowserColumnIndex {
        moveBrowserSelection(
          in: controllerBrowserColumnIndex,
          by: -1
        )
        return
      }
      if selectedTableIndex == 0 {
        self.controllerBrowserColumnIndex = 0
        hasTableFocus = false
        return
      }
      hasTableFocus = true
      moveTableSelection(by: -1)
    case .down:
      if let controllerBrowserColumnIndex {
        moveBrowserSelection(
          in: controllerBrowserColumnIndex,
          by: 1
        )
        return
      }
      hasTableFocus = true
      moveTableSelection(by: 1)
    case .activate:
      if controllerBrowserColumnIndex != nil {
        controllerBrowserColumnIndex = nil
        hasTableFocus = true
        selectTableGameIfNeeded()
        return
      }
      guard let game = selectedTableGame else {
        selectTableGameIfNeeded()
        return
      }
      play(game)
    case .left:
      if let controllerBrowserColumnIndex,
        controllerBrowserColumnIndex > 0
      {
        self.controllerBrowserColumnIndex =
          controllerBrowserColumnIndex - 1
        return
      }
      controllerBrowserColumnIndex = nil
      hasTableFocus = false
      focusSidebar()
    case .right:
      guard let controllerBrowserColumnIndex else {
        return
      }
      self.controllerBrowserColumnIndex = min(
        controllerBrowserColumnIndex + 1,
        max(visibleBrowserColumns.count - 1, 0)
      )
    case .back:
      if controllerBrowserColumnIndex != nil {
        controllerBrowserColumnIndex = nil
        hasTableFocus = true
      } else {
        hasTableFocus = false
        focusSidebar()
      }
    case .openBigPicture:
      break
    }
  }

  private var selectedTableGame: GameSummary? {
    sortedGames.first {
      selectedGameIDs.contains($0.id)
    }
  }

  private var selectedTableIndex: Int? {
    selectedTableGame.flatMap { selectedGame in
      sortedGames.firstIndex { $0.id == selectedGame.id }
    }
  }

  private func selectTableGameIfNeeded() {
    guard selectedTableGame == nil, let firstGame = sortedGames.first else {
      return
    }
    withAnimation(reducesMotion ? nil : .easeOut(duration: 0.12)) {
      selectedGameIDs = [firstGame.id]
      controllerTableScrollTargetID = firstGame.id
    }
  }

  private func moveTableSelection(by offset: Int) {
    guard !sortedGames.isEmpty else {
      return
    }
    let currentIndex =
      selectedTableGame.flatMap { selectedGame in
        sortedGames.firstIndex { $0.id == selectedGame.id }
      }
      ?? (offset > 0 ? -1 : sortedGames.count)
    let destinationIndex = min(
      max(currentIndex + offset, 0),
      sortedGames.count - 1
    )
    let gameID = sortedGames[destinationIndex].id
    withAnimation(reducesMotion ? nil : .easeOut(duration: 0.12)) {
      selectedGameIDs = [gameID]
      controllerTableScrollTargetID = gameID
    }
  }

  private var columnBrowser: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Label("Column Browser", systemImage: "rectangle.split.3x1")
          .font(.caption)
          .fontWeight(.semibold)

        Spacer()

        Text(browserResultCountLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()

        Menu {
          browserColumnActions
        } label: {
          Label("Browser Columns", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose columns for the browser")
      }
      .padding(.horizontal, 10)
      .frame(height: 34)

      Divider()

      GeometryReader { proxy in
        let columns = visibleBrowserColumns
        let minimumWidth = 174.0
        let fittedWidth = proxy.size.width / CGFloat(max(columns.count, 1))
        let paneWidth = max(minimumWidth, fittedWidth)

        ScrollView(.horizontal) {
          HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element) { index, column in
              browserPane(for: column)
                .frame(width: paneWidth)

              if index < columns.count - 1 {
                Divider()
              }
            }
          }
        }
        .scrollIndicators(.visible)
      }
    }
    .background(.background)
    .contextMenu {
      browserColumnActions
    }
  }

  @ViewBuilder
  private func browserPane(for column: LibraryBrowserColumn) -> some View {
    LibraryBrowserPane(
      column: column,
      title: column.title,
      systemImage: column.systemImage,
      allLabel: column.allLabel,
      allCount: gamesMatching(excluding: column).count,
      options: browserOptions(for: column),
      selection: selectionBinding(for: column),
      isControllerFocused:
        visibleBrowserColumns.firstIndex(of: column)
        == controllerBrowserColumnIndex,
      moveColumn: moveBrowserColumn
    )
  }

  private func moveBrowserSelection(
    in columnIndex: Int,
    by offset: Int
  ) {
    let columns = visibleBrowserColumns
    guard columns.indices.contains(columnIndex) else {
      return
    }
    let column = columns[columnIndex]
    let binding = selectionBinding(for: column)
    let values = browserOptions(for: column).map(\.value)
    let currentIndex =
      binding.wrappedValue.flatMap(values.firstIndex)
      .map { $0 + 1 }
      ?? 0
    let destinationIndex = min(
      max(currentIndex + offset, 0),
      values.count
    )
    binding.wrappedValue =
      destinationIndex == 0
      ? nil
      : values[destinationIndex - 1]
  }

  @ViewBuilder
  private var browserColumnActions: some View {
    ForEach(LibraryBrowserColumn.allCases.filter { $0 != .system }) { column in
      Toggle(
        column.title,
        isOn: visibilityBinding(for: column)
      )
    }

    Divider()

    Button("Clear Browser Filters") {
      clearBrowserFilters()
    }
    .disabled(activeBrowserFilterCount == 0)

    Button("Reset Column Order") {
      resetBrowserColumnOrder()
    }
    .disabled(orderedBrowserColumns == LibraryBrowserColumn.allCases)
  }

  private var visibleBrowserColumns: [LibraryBrowserColumn] {
    orderedBrowserColumns.filter { column in
      switch column {
      case .system:
        !isSingleSystemView
      case .genre:
        showsGenreBrowser
      case .year:
        showsYearBrowser
      case .region:
        showsRegionBrowser
      case .status:
        showsStatusBrowser
      case .saveData:
        showsSaveDataBrowser
      case .downloaded:
        showsDownloadedBrowser
      case .artwork:
        showsArtworkBrowser
      }
    }
  }

  private var isSingleSystemView: Bool {
    if case .system = model.selection {
      return true
    }
    return false
  }

  private var orderedBrowserColumns: [LibraryBrowserColumn] {
    var seen: Set<LibraryBrowserColumn> = []
    var columns =
      browserOrder
      .split(separator: ",")
      .compactMap { LibraryBrowserColumn(rawValue: String($0)) }
      .filter { seen.insert($0).inserted }

    columns.append(
      contentsOf: LibraryBrowserColumn.allCases.filter {
        seen.insert($0).inserted
      }
    )
    return columns
  }

  private var browserResultCountLabel: String {
    guard activeBrowserFilterCount > 0 else {
      return "\(model.displayedGames.count.formatted()) games"
    }

    return
      "\(filteredGames.count.formatted()) of "
      + "\(model.displayedGames.count.formatted()) games"
  }

  private var activeBrowserFilterCount: Int {
    [
      selectedSystem,
      showsGenreBrowser ? selectedGenre : nil,
      showsYearBrowser ? selectedYear : nil,
      showsRegionBrowser ? selectedRegion : nil,
      showsStatusBrowser ? selectedStatus : nil,
      showsSaveDataBrowser ? selectedSaveData : nil,
      showsDownloadedBrowser ? selectedDownloaded : nil,
      showsArtworkBrowser ? selectedArtwork : nil,
    ]
    .compactMap { $0 }
    .count
  }

  private var filteredGames: [GameSummary] {
    gamesMatching(excluding: nil)
  }

  private func gamesMatching(
    excluding excludedColumn: LibraryBrowserColumn?
  ) -> [GameSummary] {
    model.displayedGames.filter { game in
      if excludedColumn != .system,
        let selectedSystem,
        game.systemName != selectedSystem
      {
        return false
      }

      if excludedColumn != .genre,
        showsGenreBrowser,
        let selectedGenre,
        !browserGenres(for: game).contains(selectedGenre)
      {
        return false
      }

      if excludedColumn != .year,
        showsYearBrowser,
        let selectedYear,
        browserYear(for: game) != selectedYear
      {
        return false
      }

      if excludedColumn != .region,
        showsRegionBrowser,
        let selectedRegion,
        !browserRegions(for: game).contains(selectedRegion)
      {
        return false
      }

      if excludedColumn != .status,
        showsStatusBrowser,
        let selectedStatus,
        browserStatus(for: game) != selectedStatus
      {
        return false
      }

      if excludedColumn != .saveData,
        showsSaveDataBrowser,
        let selectedSaveData,
        !matchesSaveData(game, value: selectedSaveData)
      {
        return false
      }

      if excludedColumn != .downloaded,
        showsDownloadedBrowser,
        let selectedDownloaded,
        !matchesDownloaded(game, value: selectedDownloaded)
      {
        return false
      }

      if excludedColumn != .artwork,
        showsArtworkBrowser,
        let selectedArtwork,
        !matchesArtwork(game, value: selectedArtwork)
      {
        return false
      }

      return true
    }
  }

  private func browserOptions(
    for column: LibraryBrowserColumn
  ) -> [LibraryBrowserOption] {
    let games = gamesMatching(excluding: column)

    switch column {
    case .system:
      return countedOptions(in: games) { [$0.systemName] }
    case .genre:
      return countedOptions(in: games, values: browserGenres)
    case .year:
      return countedOptions(in: games) { [browserYear(for: $0)] }
        .sorted(by: compareYearOptions)
    case .region:
      return countedOptions(in: games, values: browserRegions)
    case .status:
      return countedOptions(in: games) { [browserStatus(for: $0)] }
    case .saveData:
      return [
        LibraryBrowserOption(
          value: "Has Save",
          count: games.count { $0.hasSave == true }
        ),
        LibraryBrowserOption(
          value: "Has State",
          count: games.count { $0.hasState == true }
        ),
        LibraryBrowserOption(
          value: "Has Either",
          count: games.count { $0.hasSave == true || $0.hasState == true }
        ),
        LibraryBrowserOption(
          value: "No Save Data",
          count: games.count { $0.hasSave == false && $0.hasState == false }
        ),
        LibraryBrowserOption(
          value: "Unknown",
          count: games.count { $0.hasSave == nil || $0.hasState == nil }
        ),
      ]
      .filter { $0.count > 0 }
    case .downloaded:
      return [
        LibraryBrowserOption(
          value: "Downloaded",
          count: games.count { model.downloadedGameIDs.contains($0.id) },
          systemImage: "checkmark.icloud"
        ),
        LibraryBrowserOption(
          value: "Not Downloaded",
          count: games.count { !model.downloadedGameIDs.contains($0.id) },
          systemImage: "icloud.and.arrow.down"
        ),
      ]
      .filter { $0.count > 0 }
    case .artwork:
      return [
        LibraryBrowserOption(
          value: "With Artwork",
          count: games.count { $0.coverURL != nil }
        ),
        LibraryBrowserOption(
          value: "Without Artwork",
          count: games.count { $0.coverURL == nil }
        ),
      ]
      .filter { $0.count > 0 }
    }
  }

  private func countedOptions(
    in games: [GameSummary],
    values: (GameSummary) -> [String]
  ) -> [LibraryBrowserOption] {
    var counts: [String: Int] = [:]

    for game in games {
      let uniqueValues = Set(
        values(game)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
      )
      for value in uniqueValues {
        counts[value, default: 0] += 1
      }
    }

    return
      counts
      .map { value, count in
        LibraryBrowserOption(value: value, count: count)
      }
      .sorted {
        $0.value.localizedStandardCompare($1.value) == .orderedAscending
      }
  }

  private func compareYearOptions(
    _ lhs: LibraryBrowserOption,
    _ rhs: LibraryBrowserOption
  ) -> Bool {
    if lhs.value == "Unknown" {
      return false
    }
    if rhs.value == "Unknown" {
      return true
    }
    return (Int(lhs.value) ?? 0) > (Int(rhs.value) ?? 0)
  }

  private func browserGenres(for game: GameSummary) -> [String] {
    let values = game.genres ?? []
    return values.isEmpty ? ["Unknown"] : values
  }

  private func browserRegions(for game: GameSummary) -> [String] {
    let values = game.regions ?? []
    return values.isEmpty ? ["Unknown"] : values
  }

  private func browserYear(for game: GameSummary) -> String {
    game.releaseYear.map(String.init) ?? "Unknown"
  }

  private func browserStatus(for game: GameSummary) -> String {
    game.statusColumnValue == "—" ? "Unplayed" : game.statusColumnValue
  }

  private func matchesSaveData(
    _ game: GameSummary,
    value: String
  ) -> Bool {
    switch value {
    case "Has Save":
      game.hasSave == true
    case "Has State":
      game.hasState == true
    case "Has Either":
      game.hasSave == true || game.hasState == true
    case "No Save Data":
      game.hasSave == false && game.hasState == false
    case "Unknown":
      game.hasSave == nil || game.hasState == nil
    default:
      true
    }
  }

  private func matchesArtwork(
    _ game: GameSummary,
    value: String
  ) -> Bool {
    switch value {
    case "With Artwork":
      game.coverURL != nil
    case "Without Artwork":
      game.coverURL == nil
    default:
      true
    }
  }

  private func matchesDownloaded(
    _ game: GameSummary,
    value: String
  ) -> Bool {
    switch value {
    case "Downloaded":
      model.downloadedGameIDs.contains(game.id)
    case "Not Downloaded":
      !model.downloadedGameIDs.contains(game.id)
    default:
      true
    }
  }

  private func selectionBinding(
    for column: LibraryBrowserColumn
  ) -> Binding<String?> {
    switch column {
    case .system:
      $selectedSystem
    case .genre:
      $selectedGenre
    case .year:
      $selectedYear
    case .region:
      $selectedRegion
    case .status:
      $selectedStatus
    case .saveData:
      $selectedSaveData
    case .downloaded:
      $selectedDownloaded
    case .artwork:
      $selectedArtwork
    }
  }

  private func visibilityBinding(
    for column: LibraryBrowserColumn
  ) -> Binding<Bool> {
    Binding(
      get: {
        switch column {
        case .system:
          true
        case .genre:
          showsGenreBrowser
        case .year:
          showsYearBrowser
        case .region:
          showsRegionBrowser
        case .status:
          showsStatusBrowser
        case .saveData:
          showsSaveDataBrowser
        case .downloaded:
          showsDownloadedBrowser
        case .artwork:
          showsArtworkBrowser
        }
      },
      set: { isVisible in
        switch column {
        case .system:
          break
        case .genre:
          showsGenreBrowser = isVisible
        case .year:
          showsYearBrowser = isVisible
        case .region:
          showsRegionBrowser = isVisible
        case .status:
          showsStatusBrowser = isVisible
        case .saveData:
          showsSaveDataBrowser = isVisible
        case .downloaded:
          showsDownloadedBrowser = isVisible
        case .artwork:
          showsArtworkBrowser = isVisible
        }

        if !isVisible {
          selectionBinding(for: column).wrappedValue = nil
        }
      }
    )
  }

  private func clearBrowserFilters() {
    selectedSystem = nil
    selectedGenre = nil
    selectedYear = nil
    selectedRegion = nil
    selectedStatus = nil
    selectedSaveData = nil
    selectedDownloaded = nil
    selectedArtwork = nil
  }

  private func moveBrowserColumn(
    _ source: LibraryBrowserColumn,
    _ target: LibraryBrowserColumn
  ) {
    guard source != target else {
      return
    }

    var columns = orderedBrowserColumns
    guard
      let sourceIndex = columns.firstIndex(of: source),
      let targetIndex = columns.firstIndex(of: target)
    else {
      return
    }

    columns.remove(at: sourceIndex)
    guard let adjustedTargetIndex = columns.firstIndex(of: target) else {
      return
    }

    let insertionIndex =
      sourceIndex < targetIndex
      ? columns.index(after: adjustedTargetIndex)
      : adjustedTargetIndex
    columns.insert(source, at: insertionIndex)
    browserOrder = columns.map(\.rawValue).joined(separator: ",")
  }

  private func resetBrowserColumnOrder() {
    browserOrder = LibraryBrowserColumn.allCases
      .map(\.rawValue)
      .joined(separator: ",")
  }

  private func rebuildSortedGames() async {
    let requestID = UUID()
    sortingRequestID = requestID

    let games = filteredGames
    let requestedSortOrder = sortOrder
    let favoriteGameIDs =
      model.prioritizesFavoritesInCurrentView
      ? model.favoriteGameIDs
      : []
    let shouldRestoreTableFocus =
      hasTableFocus || (!hasPreparedRows && automaticallyFocusesContent)
    guard !games.isEmpty else {
      sortedGames = []
      hasPreparedRows = true
      isSorting = false
      return
    }

    isSorting = true
    let sorted = await Task.detached(priority: .userInitiated) {
      RomMFavorites.prioritizing(
        games.sorted(using: requestedSortOrder),
        gameIDs: favoriteGameIDs
      )
    }.value

    guard sortingRequestID == requestID, !Task.isCancelled else {
      if sortingRequestID == requestID {
        isSorting = false
      }
      return
    }

    sortedGames = sorted
    selectedGameIDs.formIntersection(sorted.lazy.map(\.id))
    tableIdentity = UUID()
    hasPreparedRows = true
    if shouldRestoreTableFocus {
      hasTableFocus = true
    }
    isSorting = false
  }

  private var loadKey: LibraryTableLoadKey {
    LibraryTableLoadKey(
      selection: model.selection,
      searchTerm: model.searchTerm,
      synchronizedAt: model.lastSuccessfulSync
    )
  }

  private var tableRowsKey: LibraryTableRowsKey {
    LibraryTableRowsKey(
      loadKey: loadKey,
      loadedGameCount: model.games.count,
      hidesGamesWithoutArtwork: model.hidesGamesWithoutArtwork,
      selectedSystem: selectedSystem,
      selectedGenre: showsGenreBrowser ? selectedGenre : nil,
      selectedYear: showsYearBrowser ? selectedYear : nil,
      selectedRegion: showsRegionBrowser ? selectedRegion : nil,
      selectedStatus: showsStatusBrowser ? selectedStatus : nil,
      selectedSaveData: showsSaveDataBrowser ? selectedSaveData : nil,
      selectedDownloaded: showsDownloadedBrowser ? selectedDownloaded : nil,
      downloadedFilterGameIDs:
        showsDownloadedBrowser && selectedDownloaded != nil
        ? model.downloadedGameIDs
        : [],
      selectedArtwork: showsArtworkBrowser ? selectedArtwork : nil,
      favoriteGameIDs:
        model.prioritizesFavoritesInCurrentView
        ? model.favoriteGameIDs
        : []
    )
  }
}

private struct LibraryBrowserOption: Identifiable {
  var id: String {
    value
  }

  let value: String
  let count: Int
  var systemImage: String? = nil
}

private struct LibraryBrowserPane: View {
  let column: LibraryBrowserColumn
  let title: String
  let systemImage: String?
  let allLabel: String
  let allCount: Int
  let options: [LibraryBrowserOption]
  @Binding var selection: String?
  let isControllerFocused: Bool
  let moveColumn: (LibraryBrowserColumn, LibraryBrowserColumn) -> Void

  @State private var isDropTarget = false
  @State private var scrollTargetID: String?

  private static let allRowID = "__all__"

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "line.3.horizontal")
          .font(.caption2)
          .foregroundStyle(.tertiary)

        if let systemImage {
          Image(systemName: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Text(title.uppercased())
          .font(.caption2)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 10)
      .frame(height: 26)
      .contentShape(.rect)
      .draggable(column.rawValue) {
        Label(title, systemImage: "rectangle.split.3x1")
          .padding(8)
          .background(.regularMaterial, in: .rect(cornerRadius: 7))
      }
      .help("Drag to reorder browser columns")

      Divider()

      ScrollView {
        LazyVStack(spacing: 0) {
          browserRow(
            label: allLabel,
            count: allCount,
            systemImage: systemImage,
            isSelected: selection == nil
          ) {
            selection = nil
          }
          .id(Self.allRowID)

          ForEach(options) { option in
            browserRow(
              label: option.value,
              count: option.count,
              systemImage: option.systemImage,
              isSelected: selection == option.value
            ) {
              selection = option.value
            }
            .id(option.value)
          }
        }
        .scrollTargetLayout()
      }
      .scrollPosition(id: $scrollTargetID, anchor: .center)
    }
    .background {
      if isDropTarget {
        Color.accentColor.opacity(0.1)
      }
    }
    .overlay {
      if isDropTarget || isControllerFocused {
        Rectangle()
          .stroke(Color.accentColor, lineWidth: 2)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: String.self) { items, _ in
      guard
        let rawValue = items.first,
        let source = LibraryBrowserColumn(rawValue: rawValue)
      else {
        return false
      }

      moveColumn(source, column)
      return true
    } isTargeted: { isTargeted in
      isDropTarget = isTargeted
    }
    .onChange(of: selection, initial: true) { _, selection in
      scrollTargetID = selection ?? Self.allRowID
    }
    .onChange(of: isControllerFocused) { _, isFocused in
      guard isFocused else {
        return
      }
      scrollTargetID = selection ?? Self.allRowID
    }
  }

  private func browserRow(
    label: String,
    count: Int,
    systemImage: String?,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let systemImage {
          Image(systemName: systemImage)
            .foregroundStyle(
              isSelected ? Color.white : Color.secondary
            )
            .frame(width: 16)
        }

        Text(label)
          .lineLimit(1)

        Spacer(minLength: 8)

        Text(count.formatted())
          .foregroundStyle(
            isSelected ? Color.white.opacity(0.8) : Color.secondary
          )
          .monospacedDigit()
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 22)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .font(.caption)
    .foregroundStyle(isSelected ? Color.white : Color.primary)
    .background(isSelected ? Color.accentColor : Color.clear)
    .accessibilityLabel("\(label), \(count.formatted()) games")
    .accessibilityValue(isSelected ? "Selected" : "")
  }
}

private struct LibraryGridView: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reducesMotion

  let model: LibraryModel
  let sort: ArtworkSort
  let automaticallyFocusesContent: Bool
  let setHidesGamesWithoutArtwork: (Bool) -> Void
  let requestFavoriteChange: ([GameSummary], Bool) -> Void
  let requestGameDownload: ([GameSummary]) -> Void
  let requestGameDownloadRemoval: ([GameSummary]) -> Void
  let requestGameExport: ([GameSummary]) -> Void
  let requestGameDeletion: ([GameSummary]) -> Void
  let controllerRouter: LibraryControllerRouter
  let focusSidebar: () -> Void

  @State private var selectedGameIDs: Set<Int> = []
  @State private var selectionAnchorID: Int?
  @State private var sortedGames: [GameSummary] = []
  @State private var isSorting = true
  @State private var sortingRequestID = UUID()
  @State private var preparingGameID: Int?
  @State private var playbackAlert: LibraryAlert?
  @State private var controllerScrollTargetID: Int?
  @State private var gridWidth: CGFloat = 0
  @Namespace private var selectionHighlight
  @FocusState private var hasGridFocus: Bool

  private let columns = [
    GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 22, alignment: .top)
  ]

  var body: some View {
    Group {
      if model.isLoading, model.games.isEmpty {
        ProgressView("Loading \(model.title)…")
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let errorMessage = model.errorMessage, model.games.isEmpty {
        ContentUnavailableView {
          Label("Couldn’t Load Library", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("Try Again") {
            Task {
              await model.retry()
            }
          }
          .buttonStyle(.glassProminent)
        }
      } else if model.games.isEmpty {
        if model.searchTerm.isEmpty {
          ContentUnavailableView {
            Label("No Games", systemImage: "rectangle.stack.badge.minus")
          } description: {
            Text("RomM did not return any games for \(model.title).")
          }
        } else {
          ContentUnavailableView.search(text: model.searchTerm)
        }
      } else if model.displayedGames.isEmpty {
        if model.hidesGamesWithoutArtwork {
          ContentUnavailableView {
            Label("No Games with Artwork", systemImage: "photo.badge.exclamationmark")
          } description: {
            Text("No artwork was found in the loaded results.")
          } actions: {
            if model.hasMoreGames {
              Button("Search More Results") {
                Task {
                  await model.loadMore()
                }
              }
            }

            Button("Show Games Without Artwork") {
              setHidesGamesWithoutArtwork(false)
            }
          }
        } else if model.searchTerm.isEmpty {
          ContentUnavailableView {
            Label("No Games", systemImage: "rectangle.stack.badge.minus")
          } description: {
            Text("Only BIOS or firmware entries were found for \(model.title).")
          }
        } else {
          ContentUnavailableView.search(text: model.searchTerm)
        }
      } else if isSorting, sortedGames.isEmpty {
        ProgressView("Preparing \(model.title)…")
          .controlSize(.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
            ForEach(sortedGames) { game in
              ArtworkGameItem(
                game: game,
                session: model.session,
                service: model.service,
                isSelected: selectedGameIDs.contains(game.id),
                isPlayable: isPlayable(game),
                isFavorite:
                  model.prioritizesFavoritesInCurrentView
                  && model.favoriteGameIDs.contains(game.id),
                isDownloaded: model.downloadedGameIDs.contains(game.id),
                hasSaveState: game.hasState == true,
                secondaryText: cardSecondaryText(for: game),
                isPreparingToPlay: preparingGameID == game.id,
                isPlaybackBusy: preparingGameID != nil,
                selectionNamespace: selectionHighlight,
                animatesMovingSelection: selectedGameIDs.count == 1,
                selectGame: {
                  handleGameClick(game)
                },
                playGame: {
                  play(game)
                }
              )
              .id(game.id)
              .contextMenu {
                let selectedGames = contextGames(for: game)
                LibraryGameSelectionContextMenu(
                  model: model,
                  selectedGames: selectedGames,
                  requestFavoriteChange: requestFavoriteChange,
                  requestGameDownload: requestGameDownload,
                  requestGameDownloadRemoval: requestGameDownloadRemoval,
                  requestGameExport: requestGameExport,
                  requestGameDeletion: requestGameDeletion,
                  requestGameInfo: openGameInfo
                ) {
                  if selectedGames.count == 1,
                    let selectedGame = selectedGames.first,
                    isPlayable(selectedGame)
                  {
                    Button {
                      play(selectedGame)
                    } label: {
                      Label("Play", systemImage: "play.fill")
                    }

                    Button {
                      play(selectedGame, fromBeginning: true)
                    } label: {
                      Label(
                        "Play from Beginning",
                        systemImage: "forward.end.fill"
                      )
                    }

                    Divider()
                  }
                }
              }
              .task {
                await model.loadMoreIfNeeded(near: game)
              }
            }
          }

          paginationFooter
            .padding(.top, 20)
        }
        .contentMargins(28, for: .scrollContent)
        .scrollPosition(id: $controllerScrollTargetID, anchor: .center)
        .onGeometryChange(for: CGFloat.self) { geometry in
          geometry.size.width
        } action: { width in
          gridWidth = width
        }
        .focusable()
        .focused($hasGridFocus)
        .focusedSceneValue(\.openGameInfo, gameInfoAction)
        .focusEffectDisabled()
        .onKeyPress("a", phases: .down) { keyPress in
          guard keyPress.modifiers.contains(.command) else {
            return .ignored
          }

          selectAllDisplayedGames()
          return .handled
        }
        .onKeyPress(.escape) {
          guard !selectedGameIDs.isEmpty else {
            return .ignored
          }

          clearSelection()
          return .handled
        }
        .onAppear {
          if automaticallyFocusesContent {
            hasGridFocus = true
          }
        }
      }
    }
    .task(id: artworkRowsKey) {
      await rebuildSortedGames()
    }
    .onChange(of: model.selection) { _, _ in
      clearSelection()
    }
    .onChange(of: model.searchTerm) { _, _ in
      clearSelection()
    }
    .onChange(of: model.hidesGamesWithoutArtwork) { _, _ in
      selectedGameIDs.formIntersection(model.displayedGames.lazy.map(\.id))
    }
    .onReceive(controllerRouter.commands) { command in
      handleControllerCommand(command)
    }
    .alert(item: $playbackAlert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .overlay(alignment: .topTrailing) {
      if !model.displayedGames.isEmpty {
        if selectedGameIDs.isEmpty {
          Text(resultCountLabel)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.trailing, 18)
            .allowsHitTesting(false)
        } else {
          HStack(spacing: 8) {
            Text("\(selectedGameIDs.count.formatted()) selected")
              .monospacedDigit()

            Button {
              clearSelection()
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Clear Selection")
          }
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .openVaultGlass(in: Capsule())
          .padding(.top, 8)
          .padding(.trailing, 14)
        }
      }
    }
  }

  private func isPlayable(_ game: GameSummary) -> Bool {
    LibraryGamePlayability.isPlayable(
      game,
      downloadedGameIDs: model.downloadedGameIDs
    )
  }

  private var gameInfoAction: OpenGameInfoAction? {
    guard
      selectedGameIDs.count == 1,
      let selectedGame = sortedGames.first(where: {
        selectedGameIDs.contains($0.id)
      })
    else {
      return nil
    }
    return OpenGameInfoAction {
      openGameInfo(selectedGame)
    }
  }

  private func openGameInfo(_ game: GameSummary) {
    openWindow(
      value: GameInfoRequest(
        game: game,
        lastLibrarySync: model.lastSuccessfulSync
      )
    )
  }

  private func cardSecondaryText(for game: GameSummary) -> String {
    if case .system = model.selection {
      return game.releaseYear.map(String.init) ?? "Unknown Year"
    }
    return game.systemName
  }

  private func play(
    _ game: GameSummary,
    fromBeginning: Bool = false
  ) {
    guard preparingGameID == nil, isPlayable(game) else {
      return
    }

    preparingGameID = game.id
    Task {
      defer {
        preparingGameID = nil
      }

      switch await LibraryPlaybackPreparation.prepare(game, model: model) {
      case let .ready(request):
        openWindow(
          value: fromBeginning ? request.startingFresh() : request
        )
      case let .failed(alert):
        playbackAlert = alert
      case .cancelled:
        break
      }
    }
  }

  private func handleGameClick(_ game: GameSummary) {
    let modifiers =
      NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask) ?? []

    if modifiers.contains(.command) {
      if selectedGameIDs.contains(game.id) {
        selectedGameIDs.remove(game.id)
      } else {
        selectedGameIDs.insert(game.id)
      }
      selectionAnchorID = game.id
      hasGridFocus = true
      return
    }

    if modifiers.contains(.shift), let selectionAnchorID {
      selectRange(from: selectionAnchorID, through: game.id)
      hasGridFocus = true
      return
    }

    withAnimation(
      reducesMotion ? nil : .snappy(duration: 0.16, extraBounce: 0)
    ) {
      selectedGameIDs = [game.id]
      selectionAnchorID = game.id
    }
    hasGridFocus = true
  }

  private func handleControllerCommand(
    _ command: LibraryControllerCommand
  ) {
    switch command {
    case .focusContent:
      hasGridFocus = true
      selectGridGameIfNeeded()
    case .up:
      hasGridFocus = true
      moveGridSelection(by: -gridColumnCount)
    case .down:
      hasGridFocus = true
      moveGridSelection(by: gridColumnCount)
    case .left:
      hasGridFocus = true
      guard
        let selectedIndex = selectedGridIndex,
        selectedIndex % gridColumnCount != 0
      else {
        hasGridFocus = false
        focusSidebar()
        return
      }
      moveGridSelection(by: -1)
    case .right:
      hasGridFocus = true
      moveGridSelection(by: 1)
    case .activate:
      guard let game = selectedGridGame else {
        selectGridGameIfNeeded()
        return
      }
      play(game)
    case .back:
      hasGridFocus = false
      focusSidebar()
    case .openBigPicture:
      break
    }
  }

  private var selectedGridGame: GameSummary? {
    sortedGames.first {
      selectedGameIDs.contains($0.id)
    }
  }

  private var selectedGridIndex: Int? {
    selectedGridGame.flatMap { selectedGame in
      sortedGames.firstIndex { $0.id == selectedGame.id }
    }
  }

  private var gridColumnCount: Int {
    max(1, Int((gridWidth + 22) / (150 + 22)))
  }

  private func selectGridGameIfNeeded() {
    guard selectedGridGame == nil, let firstGame = sortedGames.first else {
      return
    }
    selectGridGame(at: 0)
    controllerScrollTargetID = firstGame.id
  }

  private func moveGridSelection(by offset: Int) {
    guard !sortedGames.isEmpty else {
      return
    }
    let currentIndex =
      selectedGridIndex
      ?? (offset > 0 ? -1 : sortedGames.count)
    let destinationIndex = min(
      max(currentIndex + offset, 0),
      sortedGames.count - 1
    )
    selectGridGame(at: destinationIndex)
  }

  private func selectGridGame(at index: Int) {
    guard sortedGames.indices.contains(index) else {
      return
    }
    let gameID = sortedGames[index].id
    withAnimation(
      reducesMotion ? nil : .snappy(duration: 0.16, extraBounce: 0)
    ) {
      selectedGameIDs = [gameID]
      selectionAnchorID = gameID
      controllerScrollTargetID = gameID
    }
  }

  private func selectRange(from anchorID: Int, through gameID: Int) {
    let games = sortedGames
    guard
      let anchorIndex = games.firstIndex(where: { $0.id == anchorID }),
      let gameIndex = games.firstIndex(where: { $0.id == gameID })
    else {
      selectedGameIDs.insert(gameID)
      selectionAnchorID = gameID
      return
    }

    let bounds = min(anchorIndex, gameIndex)...max(anchorIndex, gameIndex)
    selectedGameIDs.formUnion(games[bounds].map(\.id))
  }

  private func selectAllDisplayedGames() {
    selectedGameIDs = Set(sortedGames.lazy.map(\.id))
    selectionAnchorID = sortedGames.first?.id
  }

  private func clearSelection() {
    selectedGameIDs.removeAll()
    selectionAnchorID = nil
  }

  private func contextGames(for game: GameSummary) -> [GameSummary] {
    let gameIDs =
      selectedGameIDs.contains(game.id)
      ? selectedGameIDs
      : Set([game.id])
    return sortedGames.filter { gameIDs.contains($0.id) }
  }

  private func rebuildSortedGames() async {
    let requestID = UUID()
    sortingRequestID = requestID

    let games = model.displayedGames
    let requestedSort = sort
    let favoriteGameIDs =
      model.prioritizesFavoritesInCurrentView
      ? model.favoriteGameIDs
      : []
    guard !games.isEmpty else {
      sortedGames = []
      isSorting = false
      return
    }

    isSorting = true
    let sorted = await Task.detached(priority: .userInitiated) {
      RomMFavorites.prioritizing(
        requestedSort.sorted(games),
        gameIDs: favoriteGameIDs
      )
    }.value

    guard sortingRequestID == requestID, !Task.isCancelled else {
      if sortingRequestID == requestID {
        isSorting = false
      }
      return
    }

    sortedGames = sorted
    selectedGameIDs.formIntersection(sorted.lazy.map(\.id))
    isSorting = false
  }

  private var artworkRowsKey: LibraryArtworkRowsKey {
    LibraryArtworkRowsKey(
      selection: model.selection,
      searchTerm: model.searchTerm,
      synchronizedAt: model.lastSuccessfulSync,
      loadedGameCount: model.games.count,
      hidesBIOSGames: model.hidesBIOSGames,
      hidesGamesWithoutArtwork: model.hidesGamesWithoutArtwork,
      favoriteGameIDs:
        model.prioritizesFavoritesInCurrentView
        ? model.favoriteGameIDs
        : [],
      sort: sort
    )
  }

  private var resultCountLabel: String {
    if model.hidesGamesWithoutArtwork {
      return "\(model.displayedGames.count.formatted()) shown with artwork"
    }

    if model.searchTerm.isEmpty {
      return "\(model.totalGameCount.formatted()) games"
    } else {
      return "\(model.totalGameCount.formatted()) results"
    }
  }

  @ViewBuilder
  private var paginationFooter: some View {
    if model.isLoadingMore {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .padding()
    } else if let errorMessage = model.errorMessage {
      VStack(spacing: 10) {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.secondary)

        Button("Try Again") {
          Task {
            await model.retry()
          }
        }
      }
      .frame(maxWidth: .infinity)
      .padding()
    }
  }
}

private struct AvailabilityCheckbox: View {
  let value: Bool?
  let availableLabel: String
  let unavailableLabel: String
  var isWarning = false

  var body: some View {
    Image(systemName: systemImage)
      .foregroundStyle(foregroundStyle)
      .accessibilityLabel(accessibilityLabel)
  }

  private var systemImage: String {
    switch value {
    case true:
      "checkmark.square.fill"
    case false:
      "square"
    case nil:
      "minus.square"
    }
  }

  private var foregroundStyle: Color {
    if value == true {
      return isWarning ? .red : .accentColor
    }
    return .secondary
  }

  private var accessibilityLabel: String {
    switch value {
    case true:
      availableLabel
    case false:
      unavailableLabel
    case nil:
      "Unknown"
    }
  }
}

private struct LibraryTableLoadKey: Hashable {
  let selection: LibrarySelection
  let searchTerm: String
  let synchronizedAt: Date?
}

private struct LibraryTableRowsKey: Hashable {
  let loadKey: LibraryTableLoadKey
  let loadedGameCount: Int
  let hidesGamesWithoutArtwork: Bool
  let selectedSystem: String?
  let selectedGenre: String?
  let selectedYear: String?
  let selectedRegion: String?
  let selectedStatus: String?
  let selectedSaveData: String?
  let selectedDownloaded: String?
  /// Download membership affects the row set only while its browser filter is active.
  ///
  /// Keeping ordinary checkbox updates out of this structural key prevents each
  /// completed background download from replacing the table and losing its scroll
  /// position.
  let downloadedFilterGameIDs: Set<Int>
  let selectedArtwork: String?
  let favoriteGameIDs: Set<Int>
}

private struct LibraryArtworkRowsKey: Hashable {
  let selection: LibrarySelection
  let searchTerm: String
  let synchronizedAt: Date?
  let loadedGameCount: Int
  let hidesBIOSGames: Bool
  let hidesGamesWithoutArtwork: Bool
  let favoriteGameIDs: Set<Int>
  let sort: ArtworkSort
}

private struct ArtworkGameItem: View {
  let game: GameSummary
  let session: ServerSession
  let service: any LibraryServing
  let isSelected: Bool
  let isPlayable: Bool
  let isFavorite: Bool
  let isDownloaded: Bool
  let hasSaveState: Bool
  let secondaryText: String
  let isPreparingToPlay: Bool
  let isPlaybackBusy: Bool
  let selectionNamespace: Namespace.ID
  let animatesMovingSelection: Bool
  let selectGame: () -> Void
  let playGame: () -> Void

  @State private var isHovered = false

  var body: some View {
    ZStack(alignment: .top) {
      Button(action: selectGame) {
        GameCard(
          game: game,
          session: session,
          service: service,
          isFavorite: isFavorite,
          isDownloaded: isDownloaded,
          hasSaveState: hasSaveState,
          secondaryText: secondaryText
        )
        .padding(5)
      }
      .buttonStyle(.plain)
      .simultaneousGesture(
        TapGesture(count: 2)
          .onEnded {
            guard isPlayable, !isPlaybackBusy else {
              return
            }
            playGame()
          }
      )

      if isPlayable, isHovered || isPreparingToPlay {
        VStack(spacing: 0) {
          ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(.black.opacity(0.14))
              .allowsHitTesting(false)

            Button(action: playGame) {
              Group {
                if isPreparingToPlay {
                  ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                } else {
                  Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .offset(x: 1)
                }
              }
              .foregroundStyle(.white)
              .frame(width: 46, height: 46)
              .background(.black.opacity(0.52), in: Circle())
              .overlay {
                Circle()
                  .stroke(.white.opacity(0.28), lineWidth: 0.75)
              }
              .shadow(color: .black.opacity(0.34), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(isPlaybackBusy && !isPreparingToPlay)
            .help(
              isPreparingToPlay
                ? "Preparing \(game.name)…"
                : "Play \(game.name)"
            )
            .accessibilityLabel(
              isPreparingToPlay
                ? "Preparing \(game.name)"
                : "Play \(game.name)"
            )
          }
          .aspectRatio(3 / 4, contentMode: .fit)

          Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
      }
    }
    .background {
      if isSelected {
        if animatesMovingSelection {
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(.tint.opacity(0.14))
            .matchedGeometryEffect(
              id: "artwork-selection",
              in: selectionNamespace
            )
        } else {
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(.tint.opacity(0.14))
        }
      }
    }
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
          .stroke(.tint, lineWidth: 2)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .overlay(alignment: .topTrailing) {
      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .font(.title2)
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .tint)
          .background(.black.opacity(0.25), in: Circle())
          .padding(12)
          .allowsHitTesting(false)
          .transition(.scale(scale: 0.8).combined(with: .opacity))
      }
    }
    .onHover { isHovered in
      withAnimation(.easeOut(duration: 0.14)) {
        self.isHovered = isHovered
      }
    }
    .help("Click to select; press Command-I for information")
  }
}

private struct GameCard: View {
  let game: GameSummary
  let session: ServerSession
  let service: any LibraryServing
  let isFavorite: Bool
  let isDownloaded: Bool
  let hasSaveState: Bool
  let secondaryText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      GameCoverView(
        game: game,
        session: session,
        service: service
      )
      .overlay(alignment: .bottomLeading) {
        if isDownloaded || hasSaveState {
          HStack(spacing: 6) {
            if isDownloaded {
              ArtworkStatusBadge(
                title: "Downloaded",
                systemImage: "arrow.down.circle.fill",
                tint: .blue
              )
            }

            if hasSaveState {
              ArtworkStatusBadge(
                title: "Save State",
                systemImage: "clock.arrow.circlepath",
                tint: .purple
              )
            }
          }
          .padding(10)
        }
      }

      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(game.name)
          .font(.headline)
          .lineLimit(2)

        if isFavorite {
          Image(systemName: "star.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.yellow)
            .accessibilityLabel("Favorite")
        }
      }

      Text(secondaryText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(game.name), \(secondaryText)"
        + "\(isFavorite ? ", Favorite" : "")"
        + "\(isDownloaded ? ", Downloaded" : "")"
        + "\(hasSaveState ? ", Has save state" : "")"
    )
  }
}

private struct ArtworkStatusBadge: View {
  let title: String
  let systemImage: String
  let tint: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 24, height: 24)
      .background(tint.opacity(0.9), in: Circle())
      .overlay {
        Circle()
          .stroke(.white.opacity(0.35), lineWidth: 0.5)
      }
      .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
      .help(title)
      .accessibilityLabel(title)
  }
}

extension View {
  fileprivate func sidebarDownloadStatusStyle() -> some View {
    font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .frame(height: 48)
      .openVaultGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .padding(8)
  }

  fileprivate func sidebarStatusStyle() -> some View {
    font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .frame(height: 34)
      .openVaultGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .padding(8)
  }
}

extension GameSummary {
  fileprivate var saveSortValue: Int {
    hasSave == true ? 1 : 0
  }

  fileprivate var stateSortValue: Int {
    hasState == true ? 1 : 0
  }

  fileprivate var statusColumnValue: String {
    guard let userStatus, !userStatus.isEmpty else {
      return "—"
    }
    return
      userStatus
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }

  fileprivate var completionSortValue: Int {
    completion ?? 0
  }

  fileprivate var ratingSortValue: Int {
    rating ?? 0
  }

  fileprivate var ratingColumnValue: String {
    ratingSortValue > 0 ? "\(ratingSortValue)/10" : "—"
  }

  fileprivate var difficultySortValue: Int {
    difficulty ?? 0
  }

  fileprivate var difficultyColumnValue: String {
    difficultySortValue > 0 ? "\(difficultySortValue)/10" : "—"
  }

  fileprivate var regionColumnValue: String {
    guard let regions, !regions.isEmpty else {
      return "—"
    }
    return regions.joined(separator: ", ")
  }

  fileprivate var fileSizeSortValue: Int64 {
    fileSizeBytes ?? 0
  }

  fileprivate var fileSizeColumnValue: String {
    guard let fileSizeBytes else {
      return "—"
    }
    return ByteCountFormatter.string(
      fromByteCount: fileSizeBytes,
      countStyle: .file
    )
  }

  fileprivate var artworkSortValue: Int {
    coverURL == nil ? 0 : 1
  }

  fileprivate var identifiedSortValue: Int {
    isIdentified == true ? 1 : 0
  }

  fileprivate var missingSortValue: Int {
    isMissingFromFileSystem == true ? 1 : 0
  }

  fileprivate var updatedColumnValue: String {
    guard let updatedAt, updatedAt.count >= 10 else {
      return "—"
    }
    return String(updatedAt.prefix(10))
  }
}

extension LibraryCollection {
  fileprivate var systemImage: String {
    switch id {
    case .regular:
      "square.stack"
    case .smart:
      "line.3.horizontal.decrease.circle"
    case .virtual:
      "wand.and.stars"
    }
  }
}

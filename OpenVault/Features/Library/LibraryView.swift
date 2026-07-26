import AppKit
import SwiftUI

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
}

private enum LibraryPresentation: String {
  case list
  case artwork
}

enum ArtworkSort: String, CaseIterable, Identifiable, Sendable {
  case alphabetical
  case dateAdded

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .alphabetical:
      "Alphabetical"
    case .dateAdded:
      "Date Added"
    }
  }

  var systemImage: String {
    switch self {
    case .alphabetical:
      "textformat"
    case .dateAdded:
      "calendar.badge.plus"
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
  @Environment(\.openWindow) private var openWindow
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
  @FocusState private var hasSidebarFocus: Bool

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        List(selection: selectionBinding) {
          Label("All Games", systemImage: "rectangle.stack")
            .badge(model.allGameCount)
            .tag(LibrarySelection.allGames)

          Section("Collections") {
            Label("Downloaded", systemImage: "arrow.down.circle")
              .badge(model.downloadedGameCount)
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

          Section("Systems") {
            ForEach(supportedPopulatedSystems) { system in
              Text(system.name)
                .badge(system.gameCount)
                .tag(LibrarySelection.system(system.id))
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
                  Text(system.name)
                    .badge(system.gameCount)
                    .tag(LibrarySelection.system(system.id))
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
                  Text(system.name)
                    .badge(system.gameCount)
                    .tag(LibrarySelection.system(system.id))
                }
              } label: {
                Label(
                  "Empty Systems",
                  systemImage: "tray.2"
                )
                .badge(emptySystems.count)
              }
            }
          }
        }
        .focused($hasSidebarFocus)

        Divider()
        sidebarStatus
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
              service: model.service
            ) { collection in
              selectionBinding.wrappedValue = .collection(collection.id)
            }
          } else {
            switch currentPresentation {
            case .list:
              LibraryTableView(
                model: model,
                automaticallyFocusesContent: !hasSidebarFocus,
                setHidesGamesWithoutArtwork: setHidesGamesWithoutArtwork,
                requestGameDownload: requestGameDownload,
                requestGameDownloadRemoval: requestGameDownloadRemoval,
                requestGameExport: requestGameExport,
                requestGameDeletion: requestGameDeletion
              )
            case .artwork:
              LibraryGridView(
                model: model,
                sort: artworkSort,
                automaticallyFocusesContent: !hasSidebarFocus,
                setHidesGamesWithoutArtwork: setHidesGamesWithoutArtwork,
                requestGameDownload: requestGameDownload,
                requestGameDownloadRemoval: requestGameDownloadRemoval,
                requestGameExport: requestGameExport,
                requestGameDeletion: requestGameDeletion
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
        .navigationDestination(for: GameSummary.self) { game in
          GameDetailsView(
            game: game,
            session: model.session,
            service: model.service
          )
          .id(game.id)
        }
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
              openWindow(id: BigPictureScene.id)
            } label: {
              Label("Big Picture", systemImage: "tv")
            }
            .help("Enter Big Picture mode")
            .accessibilityLabel("Enter Big Picture Mode")
          }
        }
      }
    }
    .task {
      await model.load()
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
    model.systems.filter {
      $0.gameCount > 0
        && (!model.hidesGamesWithoutArtwork
          || !model.systemIDsWithoutArtwork.contains($0.id))
    }
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
    model.systems.filter { $0.gameCount == 0 }
  }

  private var shouldOfferAllSystemsSearch: Bool {
    guard !model.searchTerm.isEmpty else {
      return false
    }

    return switch model.selection {
    case .system, .collection:
      true
    case .allGames, .downloaded, .virtualCollections:
      false
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
    case .system:
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
        case .system:
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

  @ViewBuilder
  private var sidebarStatus: some View {
    if model.isSynchronizing {
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
    } else if model.isCachingArtwork {
      HStack(spacing: 7) {
        ProgressView()
          .controlSize(.small)
        Text(artworkCachingLabel)
          .lineLimit(1)
        Spacer(minLength: 0)
        sidebarSyncButton
      }
      .sidebarStatusStyle()
      .help("Caching artwork locally for offline browsing.")
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

  private var artworkCachingLabel: String {
    guard model.artworkCacheTotalCount > 0 else {
      return "Caching Artwork"
    }
    return "Artwork \(model.cachedArtworkCount.formatted()) of "
      + model.artworkCacheTotalCount.formatted()
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

  private var selectionBinding: Binding<LibrarySelection> {
    Binding(
      get: { model.selection },
      set: { selection in
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
    )
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
  let collections: [LibraryCollection]
  let previewGames: [LibraryCollection.ID: [GameSummary]]
  let session: ServerSession
  let service: any LibraryServing
  let openCollection: (LibraryCollection) -> Void

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
          }
        }
      }
      .contentMargins(28, for: .scrollContent)
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
    }
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

private struct LibraryTableView: View {
  let model: LibraryModel
  let automaticallyFocusesContent: Bool
  let setHidesGamesWithoutArtwork: (Bool) -> Void
  let requestGameDownload: ([GameSummary]) -> Void
  let requestGameDownloadRemoval: ([GameSummary]) -> Void
  let requestGameExport: ([GameSummary]) -> Void
  let requestGameDeletion: ([GameSummary]) -> Void

  @State private var sortOrder = [
    KeyPathComparator(\GameSummary.name)
  ]
  @State private var sortedGames: [GameSummary] = []
  @State private var isSorting = true
  @State private var sortingRequestID = UUID()
  @State private var tableIdentity = UUID()
  @State private var selectedGameIDs: Set<Int> = []
  @State private var hasPreparedRows = false
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
    }
    .onChange(of: model.searchTerm) { _, _ in
      selectedGameIDs.removeAll()
    }
    .onChange(of: sortOrder) {
      Task {
        await rebuildSortedGames()
      }
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

  private var libraryTable: some View {
    Table(
      sortedGames,
      selection: $selectedGameIDs,
      sortOrder: $sortOrder,
      columnCustomization: $columnCustomization
    ) {
      TableColumn("Game", value: \.name) { game in
        NavigationLink(value: game) {
          Text(game.name)
            .lineLimit(1)
        }
        .buttonStyle(.plain)
      }
      .width(min: 220, ideal: 380)
      .customizationID("game")
      .disabledCustomizationBehavior(.visibility)

      TableColumn("System", value: \.systemName)
        .width(min: 120, ideal: 170)
        .customizationID("system")
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
    .contextMenu(forSelectionType: Int.self) { selectedIDs in
      let selectedGames = sortedGames.filter { selectedIDs.contains($0.id) }
      let downloadedGames = selectedGames.filter {
        model.downloadedGameIDs.contains($0.id)
      }
      let gamesToDownload = selectedGames.filter {
        !model.downloadedGameIDs.contains($0.id)
      }

      if !gamesToDownload.isEmpty {
        Button {
          requestGameDownload(gamesToDownload)
        } label: {
          Label(
            gamesToDownload.count == 1
              ? "Download"
              : "Download \(gamesToDownload.count.formatted()) Games",
            systemImage: "arrow.down.circle"
          )
        }
        .disabled(
          model.isDownloadingGames
            || model.isRemovingDownloads
            || gamesToDownload.allSatisfy {
              $0.isMissingFromFileSystem == true
            }
        )
      }

      if !downloadedGames.isEmpty {
        Button(role: .destructive) {
          requestGameDownloadRemoval(downloadedGames)
        } label: {
          Label(
            downloadedGames.count == 1
              ? "Remove Download"
              : "Remove \(downloadedGames.count.formatted()) Downloads",
            systemImage: "trash"
          )
        }
        .disabled(model.isRemovingDownloads || model.isDownloadingGames)
      }

      Button {
        requestGameExport(selectedGames)
      } label: {
        Label(
          selectedIDs.count == 1
            ? "Export"
            : "Export \(selectedIDs.count.formatted()) Games",
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

      Divider()

      Button(role: .destructive) {
        requestGameDeletion(selectedGames)
      } label: {
        Label(
          selectedIDs.count == 1
            ? "Delete from RomM…"
            : "Delete \(selectedIDs.count.formatted()) Games from RomM…",
          systemImage: "trash"
        )
      }
      .disabled(selectedGames.isEmpty || model.isDeletingGames)
    }
    .focused($hasTableFocus)
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
      moveColumn: moveBrowserColumn
    )
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
    }
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
      games.sorted(using: requestedSortOrder)
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
      downloadedGameIDs: model.downloadedGameIDs,
      selectedArtwork: showsArtworkBrowser ? selectedArtwork : nil
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
  let moveColumn: (LibraryBrowserColumn, LibraryBrowserColumn) -> Void

  @State private var isDropTarget = false

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

          ForEach(options) { option in
            browserRow(
              label: option.value,
              count: option.count,
              systemImage: option.systemImage,
              isSelected: selection == option.value
            ) {
              selection = option.value
            }
          }
        }
      }
    }
    .background {
      if isDropTarget {
        Color.accentColor.opacity(0.1)
      }
    }
    .overlay {
      if isDropTarget {
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
  let model: LibraryModel
  let sort: ArtworkSort
  let automaticallyFocusesContent: Bool
  let setHidesGamesWithoutArtwork: (Bool) -> Void
  let requestGameDownload: ([GameSummary]) -> Void
  let requestGameDownloadRemoval: ([GameSummary]) -> Void
  let requestGameExport: ([GameSummary]) -> Void
  let requestGameDeletion: ([GameSummary]) -> Void

  @State private var selectedGameIDs: Set<Int> = []
  @State private var selectionAnchorID: Int?
  @State private var gameToOpen: GameSummary?
  @State private var sortedGames: [GameSummary] = []
  @State private var isSorting = true
  @State private var sortingRequestID = UUID()
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
              Button {
                handleGameClick(game)
              } label: {
                GameCard(
                  game: game,
                  session: model.session,
                  service: model.service
                )
                .padding(5)
                .background {
                  if selectedGameIDs.contains(game.id) {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                      .fill(.tint.opacity(0.14))
                  }
                }
                .overlay {
                  if selectedGameIDs.contains(game.id) {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                      .stroke(.tint, lineWidth: 2)
                  }
                }
                .overlay(alignment: .topTrailing) {
                  if selectedGameIDs.contains(game.id) {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.title2)
                      .symbolRenderingMode(.palette)
                      .foregroundStyle(.white, .tint)
                      .background(.black.opacity(0.25), in: Circle())
                      .padding(12)
                  }
                }
              }
              .buttonStyle(.plain)
              .help("Click to open; Command-click or Shift-click to select")
              .contextMenu {
                let selectedGames = contextGames(for: game)
                let downloadedGames = selectedGames.filter {
                  model.downloadedGameIDs.contains($0.id)
                }
                let gamesToDownload = selectedGames.filter {
                  !model.downloadedGameIDs.contains($0.id)
                }

                if !gamesToDownload.isEmpty {
                  Button {
                    requestGameDownload(gamesToDownload)
                  } label: {
                    Label(
                      gamesToDownload.count == 1
                        ? "Download"
                        : "Download \(gamesToDownload.count.formatted()) Games",
                      systemImage: "arrow.down.circle"
                    )
                  }
                  .disabled(
                    model.isDownloadingGames
                      || model.isRemovingDownloads
                      || gamesToDownload.allSatisfy {
                        $0.isMissingFromFileSystem == true
                      }
                  )
                }

                if !downloadedGames.isEmpty {
                  Button(role: .destructive) {
                    requestGameDownloadRemoval(downloadedGames)
                  } label: {
                    Label(
                      downloadedGames.count == 1
                        ? "Remove Download"
                        : "Remove \(downloadedGames.count.formatted()) Downloads",
                      systemImage: "trash"
                    )
                  }
                  .disabled(model.isRemovingDownloads || model.isDownloadingGames)
                }

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
              .task {
                await model.loadMoreIfNeeded(near: game)
              }
            }
          }

          paginationFooter
            .padding(.top, 20)
        }
        .contentMargins(28, for: .scrollContent)
        .focusable()
        .focused($hasGridFocus)
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
    .navigationDestination(item: $gameToOpen) { game in
      GameDetailsView(
        game: game,
        session: model.session,
        service: model.service
      )
      .id(game.id)
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

    gameToOpen = game
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
    guard !games.isEmpty else {
      sortedGames = []
      isSorting = false
      return
    }

    isSorting = true
    let sorted = await Task.detached(priority: .userInitiated) {
      requestedSort.sorted(games)
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
      downloadedGameIDs: model.downloadedGameIDs,
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
  let downloadedGameIDs: Set<Int>
  let selectedArtwork: String?
}

private struct LibraryArtworkRowsKey: Hashable {
  let selection: LibrarySelection
  let searchTerm: String
  let synchronizedAt: Date?
  let loadedGameCount: Int
  let hidesBIOSGames: Bool
  let hidesGamesWithoutArtwork: Bool
  let downloadedGameIDs: Set<Int>
  let sort: ArtworkSort
}

private struct GameCard: View {
  let game: GameSummary
  let session: ServerSession
  let service: any LibraryServing

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      GameCoverView(
        game: game,
        session: session,
        service: service
      )

      Text(game.name)
        .font(.headline)
        .lineLimit(2)

      Text(game.systemName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(game.name), \(game.systemName)")
  }
}

extension View {
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

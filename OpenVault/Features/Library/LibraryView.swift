import SwiftUI

private enum LibraryPreferenceKey {
  static let hidesGamesWithoutArtwork = "library.hides-games-without-artwork"
  static let allGamesPresentation = "library.presentation.all-games"
  static let systemPresentation = "library.presentation.system"
  static let collectionPresentation = "library.presentation.collection"
  static let tableColumns = "library.table-columns.v2"
  static let showsGenreBrowser = "library.column-browser.genre.v1"
  static let showsYearBrowser = "library.column-browser.year.v1"
  static let showsRegionBrowser = "library.column-browser.region.v1"
  static let showsStatusBrowser = "library.column-browser.status.v1"
  static let showsSaveDataBrowser = "library.column-browser.save-data.v1"
  static let showsArtworkBrowser = "library.column-browser.artwork.v1"
  static let browserOrder = "library.column-browser.order.v1"
}

private enum LibraryPresentation: String {
  case list
  case artwork
}

private enum LibraryBrowserColumn: String, CaseIterable, Identifiable {
  case system
  case genre
  case year
  case region
  case status
  case saveData
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
    case .artwork:
      "Artwork"
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
    case .artwork:
      "All Artwork"
    }
  }
}

struct LibraryView: View {
  @Bindable var model: LibraryModel
  @State private var searchText = ""
  @State private var showsEmptySystems = false
  @AppStorage(LibraryPreferenceKey.hidesGamesWithoutArtwork)
  private var persistedHidesGamesWithoutArtwork = false
  @AppStorage(LibraryPreferenceKey.allGamesPresentation)
  private var allGamesPresentation = LibraryPresentation.list
  @AppStorage(LibraryPreferenceKey.systemPresentation)
  private var systemPresentation = LibraryPresentation.artwork
  @AppStorage(LibraryPreferenceKey.collectionPresentation)
  private var collectionPresentation = LibraryPresentation.list

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        List(selection: selectionBinding) {
          Label("All Games", systemImage: "rectangle.stack")
            .badge(model.allGameCount)
            .tag(LibrarySelection.allGames)

          Section("Systems") {
            ForEach(populatedSystems) { system in
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

          Section("Collections") {
            if model.collections.isEmpty, !model.isLoading {
              Text("No Collections")
                .foregroundStyle(.secondary)
            } else {
              ForEach(model.collections) { collection in
                Label(collection.name, systemImage: collection.systemImage)
                  .badge(collection.gameCount)
                  .tag(LibrarySelection.collection(collection.id))
              }
            }
          }
        }

        Divider()
        sidebarStatus
      }
      .navigationTitle("OpenVault")
      .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } detail: {
      NavigationStack {
        Group {
          switch currentPresentation {
          case .list:
            LibraryTableView(
              model: model,
              setHidesGamesWithoutArtwork: setHidesGamesWithoutArtwork
            )
          case .artwork:
            LibraryGridView(
              model: model,
              setHidesGamesWithoutArtwork: setHidesGamesWithoutArtwork
            )
          }
        }
        .navigationTitle(model.title)
        .searchable(
          text: $searchText,
          placement: .toolbar,
          prompt: "Search Games"
        )
        .navigationDestination(for: GameSummary.self) { game in
          GameDetailsView(
            game: game,
            session: model.session,
            service: model.service
          )
        }
        .toolbar {
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

          ToolbarItem {
            Menu {
              Toggle(
                "Hide Games Without Artwork",
                isOn: hidesGamesWithoutArtworkBinding
              )
            } label: {
              Label(
                "Library Filters",
                systemImage: model.hidesGamesWithoutArtwork
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle"
              )
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
        }
      }
    }
    .task {
      await model.setHidesGamesWithoutArtwork(
        persistedHidesGamesWithoutArtwork
      )
      await model.load()
    }
    .task(id: searchText) {
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
  }

  private var populatedSystems: [LibrarySystem] {
    model.systems.filter {
      $0.gameCount > 0
        && (!model.hidesGamesWithoutArtwork
          || !model.systemIDsWithoutArtwork.contains($0.id))
    }
  }

  private var emptySystems: [LibrarySystem] {
    model.systems.filter { $0.gameCount == 0 }
  }

  private var shouldOfferAllSystemsSearch: Bool {
    !model.searchTerm.isEmpty && model.selection != .allGames
  }

  private var currentPresentation: LibraryPresentation {
    switch model.selection {
    case .allGames:
      allGamesPresentation
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
        case .system:
          systemPresentation = newValue
        case .collection:
          collectionPresentation = newValue
        }
      }
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
      }
      .accessibilityElement(children: .combine)
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
      }
      .sidebarStatusStyle()
      .help("\(cachedLibraryHelp) \(refreshErrorMessage)")
    } else if model.isShowingStaleData {
      HStack(spacing: 7) {
        Image(systemName: "wifi.slash")
        Text("Cached · \(model.allGameCount.formatted()) games")
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .sidebarStatusStyle()
      .help(cachedLibraryHelp)
    } else {
      HStack(spacing: 7) {
        Image(systemName: "checkmark.circle")
        Text(idleStatusLabel)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .sidebarStatusStyle()
      .help(cachedLibraryHelp)
    }
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

  private var hidesGamesWithoutArtworkBinding: Binding<Bool> {
    Binding(
      get: { model.hidesGamesWithoutArtwork },
      set: setHidesGamesWithoutArtwork
    )
  }

  private func setHidesGamesWithoutArtwork(_ enabled: Bool) {
    persistedHidesGamesWithoutArtwork = enabled
    Task {
      await model.setHidesGamesWithoutArtwork(enabled)
    }
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

        model.selection = selection
        Task {
          await model.reloadGames()
        }
      }
    )
  }
}

private struct LibraryTableView: View {
  let model: LibraryModel
  let setHidesGamesWithoutArtwork: (Bool) -> Void

  @State private var sortOrder = [
    KeyPathComparator(\GameSummary.name)
  ]
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
          .buttonStyle(.borderedProminent)
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
      } else {
        gameTable
      }
    }
    .task(id: loadKey) {
      await model.loadAllGamesForTable()
    }
    .onChange(of: model.selection) { _, _ in
      clearBrowserFilters()
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
      if model.isLoadingMore {
        ProgressView()
          .controlSize(.small)
          .padding(8)
          .background(.regularMaterial, in: .capsule)
          .padding()
      }
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
      .map(LibraryBrowserOption.init(value:count:))
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

  private var sortedGames: [GameSummary] {
    filteredGames.sorted(using: sortOrder)
  }

  private var loadKey: LibraryTableLoadKey {
    LibraryTableLoadKey(
      selection: model.selection,
      searchTerm: model.searchTerm,
      synchronizedAt: model.lastSuccessfulSync
    )
  }
}

private struct LibraryBrowserOption: Identifiable {
  var id: String {
    value
  }

  let value: String
  let count: Int
}

private struct LibraryBrowserPane: View {
  let column: LibraryBrowserColumn
  let title: String
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
            isSelected: selection == nil
          ) {
            selection = nil
          }

          ForEach(options) { option in
            browserRow(
              label: option.value,
              count: option.count,
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
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
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
  let setHidesGamesWithoutArtwork: (Bool) -> Void

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
          .buttonStyle(.borderedProminent)
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
      } else {
        ScrollView {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
            ForEach(model.displayedGames) { game in
              NavigationLink(value: game) {
                GameCard(
                  game: game,
                  session: model.session,
                  service: model.service
                )
              }
              .buttonStyle(.plain)
              .task {
                await model.loadMoreIfNeeded(near: game)
              }
            }
          }

          paginationFooter
            .padding(.top, 20)
        }
        .contentMargins(28, for: .scrollContent)
      }
    }
    .overlay(alignment: .topTrailing) {
      if !model.displayedGames.isEmpty {
        Text(resultCountLabel)
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.top, 12)
          .padding(.trailing, 18)
          .allowsHitTesting(false)
      }
    }
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
    }
  }
}

@preconcurrency import AppKit
@preconcurrency import GameController
import SwiftUI

enum BigPictureScene {
  static let id = "big-picture"
}

struct BigPictureView: View {
  private static let bundledManifest =
    try? LibretroInstallation.bundled().manifest

  @Bindable var model: LibraryModel

  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.accessibilityReduceMotion) private var reducesMotion

  @State private var catalog = BigPictureCatalog.empty
  @State private var rows: [BigPictureRow] = []
  @State private var isBuildingCatalog = true
  @State private var page = BigPicturePage.home
  @State private var history: [BigPictureHistoryEntry] = []
  @State private var selectedIndex = 0
  @State private var scrollTargetID: BigPictureRow.ID?
  @State private var controllerState = BigPictureControllerState()
  @State private var controllerNavigation = BigPictureControllerNavigation()
  @State private var inputPriority = BigPictureInputPriority()
  @State private var bigPictureWindow: NSWindow?
  @State private var playbackModel: GameDetailsModel?
  @State private var playbackTask: Task<Void, Never>?
  @State private var isLoadingGameDetails = false
  @State private var playbackErrorMessage: String?
  @State private var requestedGame: GameSummary?
  @State private var requestedGameStartsFresh = false
  @State private var activePlayerRequest: LibretroRunRequest?
  @State private var optionsGame: GameSummary?
  @State private var selectedGameOptionIndex = 0
  @State private var actionProgressTitle: String?
  @State private var actionNotice: BigPictureActionNotice?
  @Namespace private var selectionHighlight
  @FocusState private var hasInterfaceFocus: Bool

  var body: some View {
    ZStack {
      if let activePlayerRequest {
        LibretroGameView(
          request: activePlayerRequest,
          service: model.service,
          onCloseRequested: returnToBigPicture
        )
        .id(activePlayerRequest)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        libraryInterface
      }
    }
    .background {
      BigPictureWindowProbe { window in
        bigPictureWindow = window
      }
    }
    .task {
      await model.load()
    }
    .task(id: catalogKey) {
      await rebuildCatalog()
    }
    .task {
      await pollControllers()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: NSWindow.didExitFullScreenNotification
      )
    ) { notification in
      guard notification.object as? NSWindow === bigPictureWindow else {
        return
      }
      dismissWindow(id: BigPictureScene.id)
    }
    .onDisappear {
      playbackTask?.cancel()
    }
  }

  private var libraryInterface: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      VStack(spacing: 0) {
        header
        menu
        footer
      }
      .padding(.horizontal, 44)
      .padding(.vertical, 28)

      if isPreparingPlayback {
        preparationOverlay
      } else if let playbackErrorMessage {
        errorOverlay(playbackErrorMessage)
      } else if let actionProgressTitle {
        actionProgressOverlay(actionProgressTitle)
      } else if let optionsGame {
        gameOptionsOverlay(optionsGame)
      } else if let actionNotice {
        actionNoticeOverlay(actionNotice)
      }
    }
    .foregroundStyle(.white)
    .fontDesign(.rounded)
    .focusable()
    .focused($hasInterfaceFocus)
    .onAppear {
      hasInterfaceFocus = true
    }
    .onTapGesture {
      hasInterfaceFocus = true
    }
    .onMoveCommand { direction in
      switch direction {
      case .up:
        handleNavigationInput(.up)
      case .down:
        handleNavigationInput(.down)
      case .left:
        handleNavigationInput(.pageUp)
      case .right:
        handleNavigationInput(.pageDown)
      default:
        break
      }
    }
    .onExitCommand {
      handleEscape()
    }
    .onKeyPress(.return) {
      handleKeyboardKey(.return)
    }
    .onKeyPress(.space) {
      handleKeyboardKey(.space)
    }
    .onKeyPress(.delete) {
      handleKeyboardKey(.delete)
    }
    .onKeyPress("x") {
      handleNavigationInput(.openGameOptions)
      return .handled
    }
    .onKeyPress(.escape) {
      handleEscape()
      return .handled
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(pageTitle)
          .font(.system(size: 42, weight: .black, design: .rounded))
          .lineLimit(1)

        Text(pageSubtitle)
          .font(.system(size: 13, weight: .bold, design: .rounded))
          .tracking(2.2)
          .foregroundStyle(.white.opacity(0.55))
      }

      Spacer()

      HStack(spacing: 14) {
        if controllerState.isConnected {
          controllerPill
        }

        statusPill

        TimelineView(.periodic(from: .now, by: 30)) { context in
          Text(
            context.date.formatted(
              date: .omitted,
              time: .shortened
            )
          )
          .font(.system(size: 17, weight: .bold, design: .rounded))
          .monospacedDigit()
        }
      }
    }
    .frame(height: 78)
  }

  private var statusPill: some View {
    HStack(spacing: 8) {
      Image(
        systemName: model.isShowingStaleData
          ? "wifi.slash"
          : "checkmark.circle.fill"
      )
      Text(model.isShowingStaleData ? "OFFLINE" : "ROMM")
    }
    .font(.system(size: 13, weight: .black, design: .rounded))
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.white.opacity(0.12), in: Capsule())
    .accessibilityLabel(
      model.isShowingStaleData
        ? "Browsing the offline library"
        : "Connected to RomM"
    )
  }

  private var controllerPill: some View {
    Label("CONTROLLER", systemImage: "gamecontroller.fill")
      .font(.system(size: 13, weight: .black, design: .rounded))
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.white.opacity(0.12), in: Capsule())
  }

  @ViewBuilder
  private var menu: some View {
    if isBuildingCatalog, catalog.systems.isEmpty {
      VStack(spacing: 18) {
        ProgressView()
          .controlSize(.large)
          .tint(.white)
        Text("PREPARING LIBRARY")
          .font(.system(size: 15, weight: .black, design: .rounded))
          .tracking(2)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if rows.isEmpty {
      VStack(spacing: 14) {
        Image(systemName: "rectangle.stack.badge.minus")
          .font(.system(size: 42, weight: .light))
        Text("NO GAMES")
          .font(.system(size: 24, weight: .black, design: .rounded))
        Text(
          page == .home
            ? "Press Escape to exit."
            : "Press A or Escape to go back."
        )
          .foregroundStyle(.white.opacity(0.55))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      HStack(alignment: .center, spacing: 54) {
        menuRows
          .frame(maxWidth: 720)

        if case .games = page, let selectedGame {
          selectedGamePreview(selectedGame)
            .frame(maxWidth: 350)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var menuRows: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(rows.indices, id: \.self) { index in
            let row = rows[index]
            Button {
              selectRow(at: index, scrollsIntoView: false)
              activate(row)
            } label: {
              HStack(spacing: 16) {
                if page.isGameList {
                  Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.yellow)
                    .opacity(row.isFavorite ? 1 : 0)
                    .accessibilityHidden(!row.isFavorite)
                    .accessibilityLabel("Favorite")
                }

                Text(row.title)
                  .lineLimit(1)

                Spacer(minLength: 20)

                if let detail = row.detail {
                  Text(detail)
                    .font(.system(size: rowDetailSize, weight: .bold, design: .rounded))
                    .foregroundStyle(
                      index == selectedIndex
                        ? .black.opacity(0.56)
                        : .white.opacity(0.46)
                    )
                    .monospacedDigit()
                    .lineLimit(1)
                }
              }
              .font(.system(size: rowFontSize, weight: .black, design: .rounded))
              .foregroundStyle(index == selectedIndex ? .black : .white)
              .padding(.horizontal, 20)
              .frame(height: rowHeight)
              .background {
                if index == selectedIndex {
                  Capsule()
                    .fill(.white)
                    .matchedGeometryEffect(
                      id: "big-picture-selection",
                      in: selectionHighlight
                    )
                }
              }
              .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .id(row.id)
            .onContinuousHover { phase in
              if case .active = phase,
                inputPriority.acceptsPointerHover(
                  at: NSEvent.mouseLocation
                )
              {
                selectRow(at: index, scrollsIntoView: false)
              }
            }
            .accessibilityAddTraits(
              index == selectedIndex ? .isSelected : []
            )
          }
        }
        .padding(.vertical, 6)
      }
      .scrollIndicators(.hidden)
      .onChange(of: scrollTargetID) { _, targetID in
        guard let targetID else {
          return
        }
        withAnimation(reducesMotion ? nil : .easeOut(duration: 0.14)) {
          proxy.scrollTo(targetID, anchor: .center)
        }

        Task { @MainActor in
          if scrollTargetID == targetID {
            scrollTargetID = nil
          }
        }
      }
    }
  }

  private func selectedGamePreview(_ game: GameSummary) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      RomMImageView(
        url: game.coverURL,
        session: model.session,
        service: model.service,
        targetSize: CGSize(width: 480, height: 640),
        contentMode: .fit,
        placeholderSystemImage: "gamecontroller",
        cornerRadius: 14,
        imagePadding: 6
      )
      .aspectRatio(3 / 4, contentMode: .fit)
      .frame(maxHeight: 330)

      VStack(alignment: .leading, spacing: 6) {
        Text(game.name)
          .font(.system(size: 25, weight: .black, design: .rounded))
          .lineLimit(2)

        HStack(spacing: 12) {
          Text(game.systemName.uppercased())
          if model.downloadedGameIDs.contains(game.id) {
            Label("LOCAL", systemImage: "arrow.down.circle.fill")
          }
          if game.hasSave == true {
            Label("SAVE", systemImage: "memorychip.fill")
          }
        }
        .font(.system(size: 12, weight: .black, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
        .labelStyle(.titleAndIcon)
      }
    }
  }

  private var footer: some View {
    HStack {
      HStack(spacing: 10) {
        actionHint(
          key:
            controllerState.isConnected
            ? controllerState.exitButtonPrompt.label
            : "ESC",
          systemImage:
            controllerState.isConnected
            ? controllerState.exitButtonPrompt.systemImage
            : nil,
          label: "EXIT"
        )

        if page != .home {
          actionHint(
            key: controllerState.backButtonPrompt.label,
            systemImage: controllerState.backButtonPrompt.systemImage,
            label: "BACK"
          )
        }
      }

      Spacer()

      Text(model.allGameCount.formatted() + " GAMES")
        .font(.system(size: 13, weight: .black, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(.white.opacity(0.45))

      Spacer()

      HStack(spacing: 10) {
        if rows.count > pageSelectionStride {
          actionHint(key: "←/→", label: "PAGE")
        }
        if page.isGameList {
          actionHint(
            key: controllerState.optionsButtonPrompt.label,
            systemImage: controllerState.optionsButtonPrompt.systemImage,
            label: "OPTIONS"
          )
        }
        actionHint(
          key: controllerState.activateButtonPrompt.label,
          systemImage: controllerState.activateButtonPrompt.systemImage,
          label: page.isGameList ? "PLAY" : "OPEN"
        )
      }
    }
    .frame(height: 64)
  }

  private func actionHint(
    key: String,
    systemImage: String? = nil,
    label: String
  ) -> some View {
    HStack(spacing: 10) {
      Group {
        if let systemImage {
          Image(systemName: systemImage)
        } else {
          Text(key)
        }
      }
        .foregroundStyle(.black.opacity(0.68))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.white, in: Capsule())
      Text(label)
    }
    .font(.system(size: 16, weight: .black, design: .rounded))
    .padding(7)
    .padding(.trailing, 8)
    .background(.white.opacity(0.12), in: Capsule())
  }

  private var preparationOverlay: some View {
    VStack(spacing: 24) {
      ProgressView()
        .controlSize(.large)
        .tint(.white)

      VStack(spacing: 8) {
        Text(preparationTitle)
          .font(.system(size: 25, weight: .black, design: .rounded))
        if let game = requestedGame {
          Text(game.name)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
        }
      }

      if let progress = playbackModel?.playbackDownloadProgress {
        VStack(spacing: 9) {
          if let fraction = progress.fractionCompleted {
            ProgressView(value: fraction)
              .progressViewStyle(.linear)
              .tint(.white)
          } else {
            ProgressView()
              .progressViewStyle(.linear)
              .tint(.white)
          }
          Text(downloadProgressLabel(progress))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
            .monospacedDigit()
        }
        .frame(width: 360)
      }

      actionHint(
        key: controllerState.backButtonPrompt.label,
        systemImage: controllerState.backButtonPrompt.systemImage,
        label: "CANCEL"
      )
    }
    .padding(42)
    .frame(minWidth: 520)
    .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 28))
    .overlay {
      RoundedRectangle(cornerRadius: 28)
        .stroke(.white.opacity(0.18), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.8), radius: 50)
  }

  private func errorOverlay(_ message: String) -> some View {
    VStack(spacing: 20) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 42, weight: .light))

      Text("COULDN’T START GAME")
        .font(.system(size: 25, weight: .black, design: .rounded))

      Text(message)
        .font(.system(size: 16, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.65))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)

      HStack(spacing: 18) {
        actionHint(
          key: controllerState.backButtonPrompt.label,
          systemImage: controllerState.backButtonPrompt.systemImage,
          label: "BACK"
        )
        actionHint(
          key: controllerState.activateButtonPrompt.label,
          systemImage: controllerState.activateButtonPrompt.systemImage,
          label: "TRY AGAIN"
        )
      }
    }
    .padding(42)
    .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 28))
    .overlay {
      RoundedRectangle(cornerRadius: 28)
        .stroke(.white.opacity(0.18), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.8), radius: 50)
  }

  private func gameOptionsOverlay(_ game: GameSummary) -> some View {
    let options = gameOptions(for: game)

    return VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 5) {
        Text("GAME OPTIONS")
          .font(.system(size: 13, weight: .black, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.52))
        Text(game.name)
          .font(.system(size: 27, weight: .black, design: .rounded))
          .lineLimit(2)
      }

      VStack(spacing: 5) {
        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
          Button {
            selectedGameOptionIndex = index
            perform(option.action, for: game)
          } label: {
            HStack(spacing: 13) {
              Image(systemName: option.systemImage)
                .frame(width: 24)
              Text(option.title)
              Spacer()
            }
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .foregroundStyle(
              index == selectedGameOptionIndex ? .black : .white
            )
            .padding(.horizontal, 17)
            .frame(height: 48)
            .background {
              if index == selectedGameOptionIndex {
                Capsule().fill(.white)
              }
            }
            .contentShape(Capsule())
          }
          .buttonStyle(.plain)
          .disabled(!option.isEnabled)
          .opacity(option.isEnabled ? 1 : 0.34)
          .onContinuousHover { phase in
            if case .active = phase,
              option.isEnabled,
              inputPriority.acceptsPointerHover(
                at: NSEvent.mouseLocation
              )
            {
              selectedGameOptionIndex = index
            }
          }
        }
      }

      HStack(spacing: 12) {
        actionHint(
          key: controllerState.activateButtonPrompt.label,
          systemImage: controllerState.activateButtonPrompt.systemImage,
          label: "SELECT"
        )
        actionHint(
          key: controllerState.backButtonPrompt.label,
          systemImage: controllerState.backButtonPrompt.systemImage,
          label: "BACK"
        )
      }
    }
    .padding(30)
    .frame(width: 540)
    .background(.black.opacity(0.97), in: RoundedRectangle(cornerRadius: 28))
    .overlay {
      RoundedRectangle(cornerRadius: 28)
        .stroke(.white.opacity(0.2), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.85), radius: 55)
  }

  private func actionNoticeOverlay(
    _ notice: BigPictureActionNotice
  ) -> some View {
    VStack(spacing: 18) {
      Image(systemName: notice.systemImage)
        .font(.system(size: 38, weight: .light))

      Text(notice.title.uppercased())
        .font(.system(size: 24, weight: .black, design: .rounded))

      Text(notice.message)
        .font(.system(size: 16, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.66))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)

      actionHint(
        key: controllerState.activateButtonPrompt.label,
        systemImage: controllerState.activateButtonPrompt.systemImage,
        label: "OK"
      )
    }
    .padding(38)
    .frame(minWidth: 500)
    .background(.black.opacity(0.97), in: RoundedRectangle(cornerRadius: 28))
    .overlay {
      RoundedRectangle(cornerRadius: 28)
        .stroke(.white.opacity(0.2), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.85), radius: 55)
  }

  private func actionProgressOverlay(_ title: String) -> some View {
    VStack(spacing: 20) {
      ProgressView()
        .controlSize(.large)
        .tint(.white)

      Text(title.uppercased())
        .font(.system(size: 22, weight: .black, design: .rounded))

      if let fraction = model.downloadProgress?
        .currentTransferProgress?
        .fractionCompleted
      {
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
          .tint(.white)
          .frame(width: 320)

        Text("\(Int(fraction * 100))%")
          .font(.system(size: 14, weight: .bold, design: .rounded))
          .foregroundStyle(.white.opacity(0.58))
          .monospacedDigit()
      }
    }
    .padding(38)
    .frame(minWidth: 460)
    .background(.black.opacity(0.97), in: RoundedRectangle(cornerRadius: 28))
    .overlay {
      RoundedRectangle(cornerRadius: 28)
        .stroke(.white.opacity(0.2), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.85), radius: 55)
  }

  private func makeRows(
    for page: BigPicturePage,
    catalog: BigPictureCatalog
  ) -> [BigPictureRow] {
    let downloadedGameIDs = model.downloadedGameIDs

    return switch page {
    case .home:
      [
        BigPictureRow(
          id: .home("recent"),
          title: "Recently Added",
          detail: catalog.recentlyAddedGames.count.formatted(),
          isFavorite: false,
          action: .navigate(.games(.recentlyAdded))
        ),
        BigPictureRow(
          id: .home("downloaded"),
          title: "Downloaded",
          detail: catalog.downloadedGames.count.formatted(),
          isFavorite: false,
          action: .navigate(.games(.downloaded))
        ),
        BigPictureRow(
          id: .home("collections"),
          title: "Collections",
          detail: catalog.collections.count.formatted(),
          isFavorite: false,
          action: .navigate(.collections)
        ),
      ]
        + catalog.systems.map { system in
          BigPictureRow(
            id: .system(system.id),
            title: system.name,
            detail: system.gameCount.formatted(),
            isFavorite: false,
            action: .navigate(.games(.system(system.id)))
          )
        }

    case .collections:
      catalog.collections.map { collection in
        BigPictureRow(
          id: .collection(collection.id),
          title: collection.name,
          detail: collectionDetail(collection),
          isFavorite: false,
          action: .navigate(.games(.collection(collection.id)))
        )
      }

    case .games(let scope):
      catalog.games(in: scope).map { game in
        BigPictureRow(
          id: .game(game.id),
          title: game.name,
          detail:
            downloadedGameIDs.contains(game.id)
            ? "LOCAL"
            : game.releaseYear.map(String.init),
          isFavorite:
            scope.isSystem && catalog.favoriteGameIDs.contains(game.id),
          action: .play(game)
        )
      }
    }
  }

  private var selectedGame: GameSummary? {
    guard rows.indices.contains(selectedIndex) else {
      return nil
    }
    if case .play(let game) = rows[selectedIndex].action {
      return game
    }
    return nil
  }

  private func gameOptions(
    for game: GameSummary
  ) -> [BigPictureGameOption] {
    let isFavorite = model.favoriteGameIDs.contains(game.id)
    let isDownloaded = model.downloadedGameIDs.contains(game.id)

    return [
      BigPictureGameOption(
        action: .play,
        title: "Play",
        systemImage: "play.fill"
      ),
      BigPictureGameOption(
        action: .playFromBeginning,
        title: "Play from Beginning",
        systemImage: "forward.end.fill"
      ),
      BigPictureGameOption(
        action: .setFavorite(!isFavorite),
        title:
          isFavorite
          ? "Remove from Favorites"
          : "Add to Favorites",
        systemImage: isFavorite ? "star.slash" : "star",
        isEnabled:
          model.favoriteCollectionID != nil
          && !model.isUpdatingFavorites
          && !model.isShowingStaleData
      ),
      BigPictureGameOption(
        action: .setDownloaded(!isDownloaded),
        title: isDownloaded ? "Remove Download" : "Download",
        systemImage:
          isDownloaded
          ? "trash"
          : "arrow.down.circle",
        isEnabled:
          !model.isDownloadingGames
          && !model.isRemovingDownloads
          && (isDownloaded || game.isMissingFromFileSystem != true)
      ),
      BigPictureGameOption(
        action: .export,
        title: "Export",
        systemImage: "square.and.arrow.up",
        isEnabled:
          !model.isExportingGames
          && (
            game.isMissingFromFileSystem != true
              || isDownloaded
          )
      ),
    ]
  }

  private var pageTitle: String {
    switch page {
    case .home:
      "OpenVault"
    case .collections:
      "Collections"
    case .games(let scope):
      catalog.title(for: scope)
    }
  }

  private var pageSubtitle: String {
    switch page {
    case .home:
      "BIG PICTURE"
    case .collections:
      "\(catalog.collections.count.formatted()) ROMM COLLECTIONS"
    case .games(let scope):
      "\(catalog.games(in: scope).count.formatted()) GAMES"
    }
  }

  private var rowFontSize: CGFloat {
    switch page {
    case .home:
      31
    case .collections, .games:
      25
    }
  }

  private var rowDetailSize: CGFloat {
    page == .home ? 17 : 14
  }

  private var rowHeight: CGFloat {
    page == .home ? 57 : 50
  }

  private var catalogKey: BigPictureCatalogKey {
    BigPictureCatalogKey(
      synchronizedAt: model.lastSuccessfulSync,
      downloadedGameIDs: model.downloadedGameIDs,
      favoriteGameIDs: model.favoriteGameIDs,
      hidesBIOSGames: model.hidesBIOSGames
    )
  }

  private var isPreparingPlayback: Bool {
    isLoadingGameDetails || playbackModel?.isPreparingToPlay == true
  }

  private var preparationTitle: String {
    if let progress = playbackModel?.playbackDownloadProgress,
      let fraction = progress.fractionCompleted
    {
      return "DOWNLOADING \(Int(fraction * 100))%"
    }
    return isLoadingGameDetails ? "CHECKING ROMM" : "PREPARING GAME"
  }

  private func rebuildCatalog() async {
    isBuildingCatalog = true
    let source = model.bigPictureSource
    let manifest = Self.bundledManifest
    let preparedCatalog = await Task.detached(priority: .userInitiated) {
      BigPictureCatalog(source: source, manifest: manifest)
    }.value
    guard !Task.isCancelled else {
      return
    }
    catalog = preparedCatalog
    rows = makeRows(for: page, catalog: preparedCatalog)
    isBuildingCatalog = false
    selectedIndex = min(selectedIndex, max(rows.count - 1, 0))
  }

  private func handle(_ command: BigPictureCommand) {
    if command == .exit {
      dismissWindow(id: BigPictureScene.id)
      return
    }

    if actionProgressTitle != nil {
      return
    }

    if actionNotice != nil {
      switch command {
      case .activate, .launchGame, .back, .openGameOptions:
        actionNotice = nil
      case .up, .down, .pageUp, .pageDown, .exit:
        break
      }
      return
    }

    if let optionsGame {
      switch command {
      case .up:
        moveGameOptionSelection(by: -1, for: optionsGame)
      case .down:
        moveGameOptionSelection(by: 1, for: optionsGame)
      case .activate, .launchGame:
        activateSelectedGameOption(for: optionsGame)
      case .back, .openGameOptions:
        self.optionsGame = nil
      case .pageUp, .pageDown, .exit:
        break
      }
      return
    }

    if playbackErrorMessage != nil {
      switch command {
      case .activate:
        playbackErrorMessage = nil
        if let requestedGame {
          play(
            requestedGame,
            fromBeginning: requestedGameStartsFresh
          )
        }
      case .back:
        playbackErrorMessage = nil
      case .up, .down, .pageUp, .pageDown, .launchGame,
        .openGameOptions, .exit:
        break
      }
      return
    }

    if isPreparingPlayback {
      if command == .back {
        playbackTask?.cancel()
        playbackTask = nil
        playbackModel = nil
        isLoadingGameDetails = false
      }
      return
    }

    switch command {
    case .up:
      moveSelection(by: -1)
    case .down:
      moveSelection(by: 1)
    case .pageUp:
      moveSelection(by: -pageSelectionStride)
    case .pageDown:
      moveSelection(by: pageSelectionStride)
    case .activate:
      guard rows.indices.contains(selectedIndex) else {
        return
      }
      activate(rows[selectedIndex])
    case .launchGame:
      launchSelectedGame()
    case .openGameOptions:
      presentSelectedGameOptions()
    case .back:
      navigateBack()
    case .exit:
      break
    }
  }

  private var pageSelectionStride: Int {
    page == .home ? 7 : 10
  }

  private func moveSelection(by offset: Int) {
    guard !rows.isEmpty else {
      return
    }
    let newIndex = BigPictureSelectionNavigation.index(
      afterMovingFrom: selectedIndex,
      by: offset,
      itemCount: rows.count
    )
    selectRow(at: newIndex, scrollsIntoView: true)
  }

  private func selectRow(
    at index: Int,
    scrollsIntoView: Bool
  ) {
    guard rows.indices.contains(index) else {
      return
    }
    withAnimation(
      reducesMotion ? nil : .snappy(duration: 0.16, extraBounce: 0)
    ) {
      selectedIndex = index
      if scrollsIntoView {
        scrollTargetID = rows[index].id
      }
    }
  }

  private func activate(_ row: BigPictureRow) {
    switch row.action {
    case .navigate(let destination):
      history.append(
        BigPictureHistoryEntry(page: page, selectedIndex: selectedIndex)
      )
      page = destination
      rows = makeRows(for: destination, catalog: catalog)
      selectedIndex = 0
      scrollTargetID = rows.first?.id
    case .play(let game):
      play(game)
    }
  }

  private func launchSelectedGame() {
    guard rows.indices.contains(selectedIndex),
      case let .play(game) = rows[selectedIndex].action
    else {
      return
    }
    play(game)
  }

  private func presentSelectedGameOptions() {
    guard let selectedGame else {
      return
    }
    let options = gameOptions(for: selectedGame)
    optionsGame = selectedGame
    selectedGameOptionIndex =
      options.firstIndex(where: \.isEnabled) ?? 0
  }

  private func moveGameOptionSelection(
    by offset: Int,
    for game: GameSummary
  ) {
    let options = gameOptions(for: game)
    guard !options.isEmpty, offset != 0 else {
      return
    }

    var index = selectedGameOptionIndex
    while true {
      let candidate = index + (offset > 0 ? 1 : -1)
      guard options.indices.contains(candidate) else {
        return
      }
      index = candidate
      if options[index].isEnabled {
        selectedGameOptionIndex = index
        return
      }
    }
  }

  private func activateSelectedGameOption(for game: GameSummary) {
    let options = gameOptions(for: game)
    guard options.indices.contains(selectedGameOptionIndex) else {
      return
    }
    let option = options[selectedGameOptionIndex]
    guard option.isEnabled else {
      return
    }
    perform(option.action, for: game)
  }

  private func perform(
    _ action: BigPictureGameOption.Action,
    for game: GameSummary
  ) {
    optionsGame = nil

    switch action {
    case .play:
      play(game)
    case .playFromBeginning:
      play(game, fromBeginning: true)
    case .setFavorite(let isFavorite):
      updateFavorite(isFavorite, for: game)
    case .setDownloaded(let isDownloaded):
      if isDownloaded {
        download(game)
      } else {
        removeDownload(for: game)
      }
    case .export:
      export(game)
    }
  }

  private func updateFavorite(
    _ isFavorite: Bool,
    for game: GameSummary
  ) {
    actionProgressTitle = "Updating Favorites"
    Task {
      defer {
        actionProgressTitle = nil
      }
      do {
        try await model.setFavorite(isFavorite, for: [game])
      } catch is CancellationError {
        return
      } catch {
        actionNotice = BigPictureActionNotice(
          title:
            isFavorite
            ? "Couldn’t Add Favorite"
            : "Couldn’t Remove Favorite",
          message: error.localizedDescription,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  private func download(_ game: GameSummary) {
    actionProgressTitle = "Downloading Game"
    Task {
      defer {
        actionProgressTitle = nil
      }
      let result = await model.downloadGames([game])
      guard !result.completedWithoutErrors else {
        return
      }
      actionNotice = operationFailureNotice(
        title: "Couldn’t Download Game",
        errors: result.errors
      )
    }
  }

  private func removeDownload(for game: GameSummary) {
    actionProgressTitle = "Removing Download"
    Task {
      defer {
        actionProgressTitle = nil
      }
      let result = await model.removeDownloads([game])
      guard !result.completedWithoutErrors else {
        return
      }
      actionNotice = operationFailureNotice(
        title: "Couldn’t Remove Download",
        errors: result.errors
      )
    }
  }

  private func export(_ game: GameSummary) {
    actionProgressTitle = "Exporting Game"
    Task {
      defer {
        actionProgressTitle = nil
      }
      let result = await model.exportGames([game])
      if result.completedWithoutErrors,
        let exportedURL = result.exportedFileURLs.first
      {
        actionNotice = BigPictureActionNotice(
          title: "Game Exported",
          message: "Saved \(exportedURL.lastPathComponent) to Downloads.",
          systemImage: "checkmark.circle"
        )
      } else {
        actionNotice = operationFailureNotice(
          title: "Couldn’t Export Game",
          errors: result.errors
        )
      }
    }
  }

  private func operationFailureNotice(
    title: String,
    errors: [String]
  ) -> BigPictureActionNotice {
    BigPictureActionNotice(
      title: title,
      message:
        errors.first
        ?? "OpenVault couldn’t complete this action.",
      systemImage: "exclamationmark.triangle"
    )
  }

  private func navigateBack() {
    guard let previous = history.popLast() else {
      return
    }
    page = previous.page
    rows = makeRows(for: previous.page, catalog: catalog)
    selectedIndex = previous.selectedIndex
    if rows.indices.contains(selectedIndex) {
      scrollTargetID = rows[selectedIndex].id
    }
  }

  private func handleEscape() {
    recordNavigationInput()
    if playbackErrorMessage != nil
      || isPreparingPlayback
      || !history.isEmpty
    {
      handle(.back)
    } else {
      dismissWindow(id: BigPictureScene.id)
    }
  }

  private func handleNavigationInput(_ command: BigPictureCommand) {
    recordNavigationInput()
    handle(command)
  }

  private func handleKeyboardKey(
    _ key: KeyEquivalent
  ) -> KeyPress.Result {
    guard let command = BigPictureKeyboardNavigation.command(for: key) else {
      return .ignored
    }
    handleNavigationInput(command)
    return .handled
  }

  private func recordNavigationInput() {
    inputPriority.recordNavigationInput(
      pointerPosition: NSEvent.mouseLocation
    )
  }

  private func play(
    _ game: GameSummary,
    fromBeginning: Bool = false
  ) {
    guard playbackTask == nil else {
      return
    }

    requestedGame = game
    requestedGameStartsFresh = fromBeginning
    playbackErrorMessage = nil
    let detailsModel = GameDetailsModel(
      game: game,
      session: model.session,
      service: model.service
    )
    playbackModel = detailsModel
    isLoadingGameDetails = true

    playbackTask = Task {
      await detailsModel.load()
      guard !Task.isCancelled else {
        finishPlaybackPreparation()
        return
      }
      isLoadingGameDetails = false

      guard let details = detailsModel.details else {
        playbackErrorMessage =
          detailsModel.errorMessage
          ?? "OpenVault could not load this game’s RomM metadata."
        finishPlaybackPreparation(keepingError: true)
        return
      }
      guard let request = await detailsModel.prepareToPlay(details) else {
        playbackErrorMessage =
          detailsModel.playbackErrorMessage
          ?? "No bundled core supports this game file."
        finishPlaybackPreparation(keepingError: true)
        return
      }
      guard !Task.isCancelled else {
        finishPlaybackPreparation()
        return
      }

      await model.reloadDownloadedGames()
      activePlayerRequest =
        (fromBeginning ? request.startingFresh() : request)
        .launched(from: .bigPicture)
      finishPlaybackPreparation()
    }
  }

  private func returnToBigPicture() {
    guard activePlayerRequest != nil else {
      return
    }
    activePlayerRequest = nil
    controllerNavigation.synchronize(with: .current)
    recordNavigationInput()

    Task { @MainActor in
      await Task.yield()
      hasInterfaceFocus = true
      bigPictureWindow?.makeKeyAndOrderFront(nil)
    }
  }

  private func finishPlaybackPreparation(keepingError: Bool = false) {
    playbackTask = nil
    playbackModel = nil
    isLoadingGameDetails = false
    if !keepingError {
      requestedGame = nil
      requestedGameStartsFresh = false
    }
  }

  private func collectionDetail(
    _ collection: LibraryCollection
  ) -> String {
    let type: String
    switch collection.id {
    case .regular:
      type = "ROMM"
    case .smart:
      type = "SMART"
    case .virtual:
      type = "AUTO"
    }
    let playableCount = catalog.games(in: .collection(collection.id)).count
    return "\(type) · \(playableCount.formatted())"
  }

  private func downloadProgressLabel(
    _ progress: RomMDownloadProgress
  ) -> String {
    let received = progress.bytesReceived.formatted(.byteCount(style: .file))
    guard let total = progress.totalBytesExpected else {
      return received
    }
    return "\(received) OF \(total.formatted(.byteCount(style: .file)))"
  }

  private func pollControllers() async {
    GCController.startWirelessControllerDiscovery(completionHandler: nil)
    defer {
      GCController.stopWirelessControllerDiscovery()
    }

    while !Task.isCancelled {
      let currentState = BigPictureControllerState.current
      controllerState = currentState
      guard
        activePlayerRequest == nil,
        NSApplication.shared.keyWindow === bigPictureWindow
      else {
        controllerNavigation.synchronize(with: currentState)
        try? await Task.sleep(for: .milliseconds(30))
        continue
      }
      if let command = controllerNavigation.command(
        for: currentState,
        at: ProcessInfo.processInfo.systemUptime
      ) {
        handleNavigationInput(command)
      }
      try? await Task.sleep(for: .milliseconds(30))
    }
  }
}

private enum BigPicturePage: Hashable {
  case home
  case collections
  case games(BigPictureScope)

  var isGameList: Bool {
    if case .games = self {
      return true
    }
    return false
  }
}

private struct BigPictureHistoryEntry {
  let page: BigPicturePage
  let selectedIndex: Int
}

private struct BigPictureCatalogKey: Hashable {
  let synchronizedAt: Date?
  let downloadedGameIDs: Set<Int>
  let favoriteGameIDs: Set<Int>
  let hidesBIOSGames: Bool
}

enum BigPictureCommand: Equatable, Sendable {
  case up
  case down
  case pageUp
  case pageDown
  case activate
  case launchGame
  case openGameOptions
  case back
  case exit
}

enum BigPictureKeyboardNavigation {
  static func command(for key: KeyEquivalent) -> BigPictureCommand? {
    switch key {
    case .return, .space:
      .activate
    case .delete:
      .back
    default:
      nil
    }
  }
}

private struct BigPictureRow: Identifiable {
  enum ID: Hashable {
    case home(String)
    case system(Int)
    case collection(LibraryCollection.ID)
    case game(Int)
  }

  enum Action {
    case navigate(BigPicturePage)
    case play(GameSummary)
  }

  let id: ID
  let title: String
  let detail: String?
  let isFavorite: Bool
  let action: Action
}

private struct BigPictureGameOption: Identifiable {
  enum Action: Hashable {
    case play
    case playFromBeginning
    case setFavorite(Bool)
    case setDownloaded(Bool)
    case export
  }

  var id: Action {
    action
  }

  let action: Action
  let title: String
  let systemImage: String
  var isEnabled = true
}

private struct BigPictureActionNotice {
  let title: String
  let message: String
  let systemImage: String
}

extension BigPictureScope {
  fileprivate var isSystem: Bool {
    if case .system = self {
      return true
    }
    return false
  }
}

struct BigPictureControllerState: Equatable, Sendable {
  var isConnected = false
  var up = false
  var down = false
  var left = false
  var right = false
  var activate = false
  var startsGame = false
  var opensGameOptions = false
  var back = false
  var exitsBigPicture = false
  var opensBigPicture = false
  var pageUp = false
  var pageDown = false
  var activateButtonPrompt = BigPictureControllerPrompt(label: "B")
  var backButtonPrompt = BigPictureControllerPrompt(label: "A")
  var optionsButtonPrompt = BigPictureControllerPrompt(label: "X")
  var exitButtonPrompt = BigPictureControllerPrompt(label: "SELECT")

  static var current: Self {
    let controllers = GCController.controllers()
    var state = Self(isConnected: !controllers.isEmpty)

    if let controller = GCController.current ?? controllers.first,
       let gamepad = controller.extendedGamepad
    {
      let layout = controllerLayout(
        vendorName: controller.vendorName,
        productCategory: controller.productCategory
      )
      let activateButton =
        layout == .nintendo ? gamepad.buttonA : gamepad.buttonB
      let backButton =
        layout == .nintendo ? gamepad.buttonB : gamepad.buttonA
      state.activateButtonPrompt = buttonPrompt(
        localizedName: activateButton.localizedName,
        systemImage: activateButton.sfSymbolsName,
        fallbackLabel: layout == .nintendo ? "A" : "B"
      )
      state.backButtonPrompt = buttonPrompt(
        localizedName: backButton.localizedName,
        systemImage: backButton.sfSymbolsName,
        fallbackLabel: layout == .nintendo ? "B" : "A"
      )
      state.optionsButtonPrompt = buttonPrompt(
        localizedName: gamepad.buttonX.localizedName,
        systemImage: gamepad.buttonX.sfSymbolsName,
        fallbackLabel: "X"
      )
      state.exitButtonPrompt = buttonPrompt(
        localizedName: gamepad.buttonOptions?.localizedName,
        systemImage: gamepad.buttonOptions?.sfSymbolsName,
        fallbackLabel: "SELECT"
      )
    }

    for controller in controllers {
      if let gamepad = controller.extendedGamepad {
        let faceButtons = Self.extendedFaceButtonActions(
          buttonAPressed: gamepad.buttonA.isPressed,
          buttonBPressed: gamepad.buttonB.isPressed,
          layout: controllerLayout(
            vendorName: controller.vendorName,
            productCategory: controller.productCategory
          )
        )
        let auxiliaryButtons = Self.extendedAuxiliaryButtonActions(
          optionsPressed: gamepad.buttonOptions?.isPressed == true,
          menuPressed: gamepad.buttonMenu.isPressed,
          homePressed: gamepad.buttonHome?.isPressed == true
        )
        state.up =
          state.up
          || gamepad.dpad.up.isPressed
          || gamepad.leftThumbstick.yAxis.value > 0.72
        state.down =
          state.down
          || gamepad.dpad.down.isPressed
          || gamepad.leftThumbstick.yAxis.value < -0.72
        state.left =
          state.left
          || gamepad.dpad.left.isPressed
          || gamepad.leftThumbstick.xAxis.value < -0.72
        state.right =
          state.right
          || gamepad.dpad.right.isPressed
          || gamepad.leftThumbstick.xAxis.value > 0.72
        state.activate = state.activate || faceButtons.activate
        state.opensGameOptions =
          state.opensGameOptions || gamepad.buttonX.isPressed
        state.startsGame =
          state.startsGame || auxiliaryButtons.startsGame
        state.exitsBigPicture =
          state.exitsBigPicture
          || auxiliaryButtons.exitsBigPicture
        state.opensBigPicture =
          state.opensBigPicture
          || auxiliaryButtons.opensBigPicture
        state.back =
          state.back
          || faceButtons.back
        state.pageUp =
          state.pageUp || gamepad.leftShoulder.isPressed
        state.pageDown =
          state.pageDown || gamepad.rightShoulder.isPressed
      } else if let gamepad = controller.microGamepad {
        state.up = state.up || gamepad.dpad.up.isPressed
        state.down = state.down || gamepad.dpad.down.isPressed
        state.left = state.left || gamepad.dpad.left.isPressed
        state.right = state.right || gamepad.dpad.right.isPressed
        state.activate = state.activate || gamepad.buttonA.isPressed
        state.back = state.back || gamepad.buttonX.isPressed
      }
    }
    return state
  }

  static func extendedFaceButtonActions(
    buttonAPressed: Bool,
    buttonBPressed: Bool,
    layout: BigPictureControllerLayout = .standard
  ) -> (activate: Bool, back: Bool) {
    switch layout {
    case .standard:
      (
        activate: buttonBPressed,
        back: buttonAPressed
      )
    case .nintendo:
      (
        activate: buttonAPressed,
        back: buttonBPressed
      )
    }
  }

  static func extendedAuxiliaryButtonActions(
    optionsPressed: Bool,
    menuPressed: Bool,
    homePressed: Bool
  ) -> (
    opensBigPicture: Bool,
    exitsBigPicture: Bool,
    startsGame: Bool
  ) {
    (
      opensBigPicture: optionsPressed || homePressed,
      exitsBigPicture: optionsPressed,
      startsGame: menuPressed
    )
  }

  static func controllerLayout(
    vendorName: String?,
    productCategory: String
  ) -> BigPictureControllerLayout {
    let identity = [vendorName, productCategory]
      .compactMap { $0 }
      .joined(separator: " ")
      .lowercased()

    return identity.contains("nintendo") || identity.contains("switch")
      ? .nintendo
      : .standard
  }

  static func buttonPrompt(
    localizedName: String?,
    systemImage: String?,
    fallbackLabel: String
  ) -> BigPictureControllerPrompt {
    let buttonLetters = Set(["A", "B", "X", "Y"])
    let label =
      localizedName?
      .uppercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .first(where: buttonLetters.contains)
      ?? fallbackLabel

    return BigPictureControllerPrompt(
      label: label,
      systemImage: systemImage
    )
  }
}

struct BigPictureControllerPrompt: Equatable, Sendable {
  let label: String
  var systemImage: String?
}

enum BigPictureControllerLayout: Equatable, Sendable {
  case standard
  case nintendo
}

struct BigPictureControllerNavigation: Sendable {
  private static let initialRepeatDelay = 0.34
  private static let repeatInterval = 0.09

  private var previousState = BigPictureControllerState()
  private var repeatingCommand: BigPictureCommand?
  private var nextRepeatTime = 0.0

  mutating func synchronize(with state: BigPictureControllerState) {
    previousState = state
    if state.up {
      repeatingCommand = .up
      nextRepeatTime = .greatestFiniteMagnitude
    } else if state.down {
      repeatingCommand = .down
      nextRepeatTime = .greatestFiniteMagnitude
    } else {
      repeatingCommand = nil
      nextRepeatTime = 0
    }
  }

  mutating func command(
    for state: BigPictureControllerState,
    at uptime: TimeInterval
  ) -> BigPictureCommand? {
    defer {
      previousState = state
    }

    if state.exitsBigPicture, !previousState.exitsBigPicture {
      return .exit
    }
    if state.back, !previousState.back {
      return .back
    }
    if state.opensGameOptions, !previousState.opensGameOptions {
      return .openGameOptions
    }
    if state.startsGame, !previousState.startsGame {
      return .launchGame
    }
    if state.activate, !previousState.activate {
      return .activate
    }
    if state.pageUp, !previousState.pageUp {
      return .pageUp
    }
    if state.pageDown, !previousState.pageDown {
      return .pageDown
    }
    if state.left, !previousState.left {
      return .pageUp
    }
    if state.right, !previousState.right {
      return .pageDown
    }

    let directionalCommand: BigPictureCommand? =
      if state.up {
        .up
      } else if state.down {
        .down
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

enum BigPictureSelectionNavigation {
  static func index(
    afterMovingFrom index: Int,
    by offset: Int,
    itemCount: Int
  ) -> Int {
    guard itemCount > 0 else {
      return 0
    }
    return min(max(index + offset, 0), itemCount - 1)
  }
}

struct BigPictureInputPriority: Sendable {
  private static let pointerMovementThreshold: CGFloat = 3
  private var navigationPointerPosition: CGPoint?

  mutating func recordNavigationInput(pointerPosition: CGPoint) {
    navigationPointerPosition = pointerPosition
  }

  mutating func acceptsPointerHover(at pointerPosition: CGPoint) -> Bool {
    guard let navigationPointerPosition else {
      return true
    }

    let horizontalMovement =
      pointerPosition.x - navigationPointerPosition.x
    let verticalMovement =
      pointerPosition.y - navigationPointerPosition.y
    let movementSquared =
      horizontalMovement * horizontalMovement
      + verticalMovement * verticalMovement
    let thresholdSquared =
      Self.pointerMovementThreshold * Self.pointerMovementThreshold

    guard movementSquared >= thresholdSquared else {
      return false
    }
    self.navigationPointerPosition = nil
    return true
  }
}

private struct BigPictureWindowProbe: NSViewRepresentable {
  let didMoveToWindow: @MainActor (NSWindow?) -> Void

  func makeNSView(context: Context) -> BigPictureProbeView {
    let view = BigPictureProbeView()
    view.didMoveToWindow = didMoveToWindow
    return view
  }

  func updateNSView(_ nsView: BigPictureProbeView, context: Context) {
    nsView.didMoveToWindow = didMoveToWindow
    nsView.requestFullScreenIfNeeded()
  }
}

@MainActor
private final class BigPictureProbeView: NSView {
  var didMoveToWindow: (@MainActor (NSWindow?) -> Void)?
  private weak var observedWindow: NSWindow?
  private var fullScreenRequest: Task<Void, Never>?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    didMoveToWindow?(window)
    guard let window else {
      stopObservingWindow()
      return
    }

    observe(window)
    window.backgroundColor = .black
    configureFullScreen(for: window)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar?.isVisible = false
    requestFullScreenIfNeeded()
  }

  func requestFullScreenIfNeeded() {
    guard
      let window,
      window.isVisible,
      !window.styleMask.contains(.fullScreen),
      fullScreenRequest == nil
    else {
      return
    }

    fullScreenRequest = Task { @MainActor [weak self, weak window] in
      defer {
        self?.fullScreenRequest = nil
      }
      try? await Task.sleep(for: .milliseconds(120))
      guard
        !Task.isCancelled,
        let window,
        window.isVisible,
        !window.styleMask.contains(.fullScreen)
      else {
        return
      }
      configureFullScreen(for: window)
      window.toggleFullScreen(nil)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func observe(_ window: NSWindow) {
    guard observedWindow !== window else {
      return
    }

    stopObservingWindow()
    observedWindow = window
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: window
    )
  }

  private func stopObservingWindow() {
    fullScreenRequest?.cancel()
    fullScreenRequest = nil
    if let observedWindow {
      NotificationCenter.default.removeObserver(
        self,
        name: NSWindow.didBecomeKeyNotification,
        object: observedWindow
      )
    }
    observedWindow = nil
  }

  @objc
  private func windowDidBecomeKey(_ notification: Notification) {
    requestFullScreenIfNeeded()
  }
}

@MainActor
private func configureFullScreen(for window: NSWindow) {
  window.collectionBehavior.remove(.fullScreenNone)
  window.collectionBehavior.insert(.fullScreenPrimary)
  window.styleMask.insert([.titled, .resizable])
}

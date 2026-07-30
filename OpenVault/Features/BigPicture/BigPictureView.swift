@preconcurrency import AppKit
@preconcurrency import GameController
import SwiftUI

enum BigPictureScene {
  static let opensInFullScreenPreferenceKey =
    "big-picture.opens-in-full-screen.v1"
  static let opensInFullScreenByDefault = true
}

struct BigPictureView: View {
  private static let bundledManifest =
    try? LibretroInstallation.bundled().manifest

  @Bindable var model: LibraryModel
  let onExitRequested: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reducesMotion
  @AppStorage(BigPictureScene.opensInFullScreenPreferenceKey)
  private var opensInFullScreen =
    BigPictureScene.opensInFullScreenByDefault

  @State private var catalog = BigPictureCatalog.empty
  @State private var rows: [BigPictureRow] = []
  @State private var isBuildingCatalog = true
  @State private var page = BigPicturePage.home
  @State private var history: [BigPictureHistoryEntry] = []
  @AppStorage(LibretroCorePreferences.enablesExperimentalCoresKey)
  private var enablesExperimentalCores =
    LibretroCorePreferences.enabledByDefault
  @AppStorage(LibretroVideoPreferences.filterKey)
  private var videoFilter = LibretroVideoPreferences.defaultFilter
  @State private var selectedIndex = 0
  @State private var scrollTargetID: BigPictureRow.ID?
  @State private var controllerState = BigPictureControllerState()
  @State private var controllerNavigation = BigPictureControllerNavigation()
  @State private var bigPictureWindow: NSWindow?
  @State private var playbackModel: GameDetailsModel?
  @State private var playbackTask: Task<Void, Never>?
  @State private var exitTask: Task<Void, Never>?
  @State private var fullScreenEscapeTask: Task<Void, Never>?
  @State private var isLoadingGameDetails = false
  @State private var playbackErrorMessage: String?
  @State private var requestedGame: GameSummary?
  @State private var requestedGameStartsFresh = false
  @State private var activePlayerRequest: LibretroRunRequest?
  @State private var optionsGame: GameSummary?
  @State private var optionsSystem: LibrarySystem?
  @State private var selectedGameOptionIndex = 0
  @State private var actionProgressTitle: String?
  @State private var actionNotice: BigPictureActionNotice?
  @State private var isShowingSyncStatus = false
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
          .modifier(
            BigPictureVideoEffectModifier(
              filter: resolvedBigPictureVideoFilter
            )
          )
      }
    }
    .background {
      BigPictureWindowProbe(
        isPlaybackActive: activePlayerRequest != nil,
        opensInFullScreen: opensInFullScreen,
        onBackspaceRequested: handleEscape
      ) { window in
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
    .task {
      await model.observeReachability()
    }
    .onDisappear {
      playbackTask?.cancel()
      exitTask?.cancel()
      fullScreenEscapeTask?.cancel()
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
      } else if let optionsSystem {
        systemOptionsOverlay(optionsSystem)
      } else if let actionNotice {
        actionNoticeOverlay(actionNotice)
      } else if isShowingSyncStatus {
        syncStatusOverlay
      }
    }
    .foregroundStyle(.white)
    .fontDesign(.rounded)
    .focusable()
    .focused($hasInterfaceFocus)
    .focusEffectDisabled()
    .allowsHitTesting(false)
    .onAppear {
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
    .onKeyPress(phases: .down) { keyPress in
      handleTypeSelection(keyPress)
    }
    .onKeyPress(.escape) {
      handleEscape()
      return .handled
    }
  }

  private var resolvedBigPictureVideoFilter: LibretroVideoFilter {
    BigPictureVideoEffectPolicy.resolved(filter: videoFilter)
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
      Image(systemName: statusSymbol)
      Text(statusLabel)
    }
    .font(.system(size: 13, weight: .black, design: .rounded))
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.white.opacity(0.12), in: Capsule())
    .accessibilityLabel(statusDescription)
  }

  /// Unreachable and merely stale are different states: the first blocks
  /// downloads, the second just means the sync has not finished yet.
  private var statusSymbol: String {
    if !model.isServerReachable {
      "wifi.slash"
    } else if model.isShowingStaleData {
      "clock.arrow.circlepath"
    } else {
      "checkmark.circle.fill"
    }
  }

  private var statusLabel: String {
    if !model.isServerReachable {
      "OFFLINE"
    } else if model.isShowingStaleData {
      "CACHED"
    } else {
      "ROMM"
    }
  }

  private var statusDescription: String {
    if !model.isServerReachable {
      "RomM is unreachable; browsing the offline library"
    } else if model.isShowingStaleData {
      "Connected to RomM; showing the cached library"
    } else {
      "Connected to RomM"
    }
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
      menuRows
        .frame(maxWidth: 1_080)
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
            .accessibilityAddTraits(
              index == selectedIndex ? .isSelected : []
            )
          }
        }
        .padding(.vertical, 6)
      }
      .id(page)
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

  private var footer: some View {
    HStack {
      HStack(spacing: 10) {
        actionHint(
          key:
            controllerState.isConnected
            ? controllerState.syncStatusButtonPrompt.label
            : "SELECT",
          systemImage:
            controllerState.isConnected
            ? controllerState.syncStatusButtonPrompt.systemImage
            : nil,
          label: "STATUS"
        )

        actionHint(key: "ESC", label: "EXIT")

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
        if page.isGameList || selectedSystem != nil {
          actionHint(
            key: controllerState.optionsButtonPrompt.label,
            systemImage: controllerState.optionsButtonPrompt.systemImage,
            label: "OPTIONS"
          )
        }
        if
          let selectedGame,
          BigPictureGameLaunchPresentation.showsPlayFromBeginning(
            hasSaveState: hasResumeState(for: selectedGame)
          )
        {
          actionHint(
            key: controllerState.playFromBeginningButtonPrompt.label,
            systemImage:
              controllerState.playFromBeginningButtonPrompt.systemImage,
            label: "PLAY"
          )
        }
        actionHint(
          key: controllerState.activateButtonPrompt.label,
          systemImage: controllerState.activateButtonPrompt.systemImage,
          label:
            selectedGame.map {
              BigPictureGameLaunchPresentation.primaryActionTitle(
                hasSaveState: hasResumeState(for: $0)
              ).uppercased()
            } ?? "OPEN"
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

  private func systemOptionsOverlay(
    _ system: LibrarySystem
  ) -> some View {
    let systemGames = model.games(inSystem: system.id)
    let downloadedGameCount = systemGames.count {
      model.managedDownloadedGameIDs.contains($0.id)
    }
    let presentation = BigPictureSystemDownloadPresentation.make(
      totalGameCount: systemGames.count,
      downloadedGameCount: downloadedGameCount
    )
    let isBusy =
      model.isDownloadingGames
      || model.isRemovingDownloads

    return VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 5) {
        Text("SYSTEM OPTIONS")
          .font(.system(size: 13, weight: .black, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.52))
        Text(system.name)
          .font(.system(size: 27, weight: .black, design: .rounded))
          .lineLimit(2)
      }

      Button {
        performSystemDownloadAction(
          presentation.action,
          for: system
        )
      } label: {
        HStack(spacing: 13) {
          Image(systemName: presentation.systemImage)
            .frame(width: 24)
          Text(presentation.title)
          Spacer()
        }
        .font(.system(size: 19, weight: .bold, design: .rounded))
        .foregroundStyle(.black)
        .padding(.horizontal, 17)
        .frame(height: 48)
        .background {
          Capsule().fill(.white)
        }
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .disabled(presentation.action == .unavailable || isBusy)
      .opacity(presentation.action == .unavailable || isBusy ? 0.34 : 1)

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

  private var syncStatusOverlay: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 15) {
        Image(systemName: syncStatusSystemImage)
          .font(.system(size: 34, weight: .light))
          .foregroundStyle(syncStatusColor)

        VStack(alignment: .leading, spacing: 4) {
          Text("SYNC STATUS")
            .font(.system(size: 13, weight: .black, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.52))
          Text(syncStatusTitle)
            .font(.system(size: 25, weight: .black, design: .rounded))
        }
      }

      if model.isSynchronizing {
        VStack(alignment: .leading, spacing: 9) {
          if model.synchronizationTotalGameCount > 0 {
            ProgressView(
              value: Double(model.synchronizedGameCount),
              total: Double(model.synchronizationTotalGameCount)
            )
            .progressViewStyle(.linear)
            .tint(.white)

            Text(
              "\(model.synchronizedGameCount.formatted()) of "
                + "\(model.synchronizationTotalGameCount.formatted()) games"
            )
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.58))
            .monospacedDigit()
          } else {
            ProgressView()
              .controlSize(.small)
              .tint(.white)
          }
        }
      }

      Divider()
        .overlay(.white.opacity(0.16))

      VStack(spacing: 13) {
        syncStatusRow(
          title: "RomM",
          value: model.isServerReachable ? "Connected" : "Offline"
        )
        syncStatusRow(
          title: "Library",
          value: "\(model.allGameCount.formatted()) games"
        )
        syncStatusRow(
          title: "Downloaded",
          value: "\(model.downloadedGameCount.formatted()) games"
        )
        syncStatusRow(
          title: "Last Complete Sync",
          value: lastSyncDescription
        )
      }

      if let error = model.refreshErrorMessage, !error.isEmpty {
        Text(error)
          .font(.system(size: 13, weight: .medium, design: .rounded))
          .foregroundStyle(.red.opacity(0.85))
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 12) {
        actionHint(
          key: controllerState.syncStatusButtonPrompt.label,
          systemImage: controllerState.syncStatusButtonPrompt.systemImage,
          label: "CLOSE"
        )
        actionHint(
          key: controllerState.backButtonPrompt.label,
          systemImage: controllerState.backButtonPrompt.systemImage,
          label: "BACK"
        )
      }
    }
    .padding(34)
    .frame(width: 590)
    .background(.black.opacity(0.97), in: RoundedRectangle(cornerRadius: 28))
    .overlay {
      RoundedRectangle(cornerRadius: 28)
        .stroke(.white.opacity(0.2), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.85), radius: 55)
  }

  private func syncStatusRow(
    title: String,
    value: String
  ) -> some View {
    HStack {
      Text(title.uppercased())
        .font(.system(size: 13, weight: .black, design: .rounded))
        .tracking(1.1)
        .foregroundStyle(.white.opacity(0.48))
      Spacer()
      Text(value)
        .font(.system(size: 15, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.88))
        .multilineTextAlignment(.trailing)
    }
  }

  private var syncStatusTitle: String {
    if model.isSynchronizing {
      return "Synchronizing with RomM"
    }
    if !model.isServerReachable {
      return "Using the Offline Library"
    }
    if model.isShowingStaleData {
      return "Using Cached Metadata"
    }
    return "Library Is Up to Date"
  }

  private var syncStatusSystemImage: String {
    if model.isSynchronizing {
      return "arrow.triangle.2.circlepath"
    }
    return model.isServerReachable
      ? "checkmark.circle.fill"
      : "wifi.slash"
  }

  private var syncStatusColor: Color {
    if model.isSynchronizing || model.isShowingStaleData {
      return .yellow
    }
    return model.isServerReachable ? .green : .red
  }

  private var lastSyncDescription: String {
    guard let date = model.lastSuccessfulSync else {
      return "Never"
    }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  private func actionProgressOverlay(_ title: String) -> some View {
    VStack(spacing: 20) {
      ProgressView()
        .controlSize(.large)
        .tint(.white)

      Text(title.uppercased())
        .font(.system(size: 22, weight: .black, design: .rounded))

      if let progress = model.downloadProgress {
        ProgressView(value: progress.fractionCompleted)
          .progressViewStyle(.linear)
          .tint(.white)
          .frame(width: 320)

        Text(
          "\(progress.currentGameNumber.formatted()) of "
            + "\(progress.totalGameCount.formatted())"
        )
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
          id: .home("recently-played"),
          title: "Recently Played",
          detail: catalog.recentlyPlayedGames.count.formatted(),
          isFavorite: false,
          action: .navigate(.games(.recentlyPlayed))
        ),
        BigPictureRow(
          id: .home("recent"),
          title: "Recently Added",
          detail: catalog.recentlyAddedGames.count.formatted(),
          isFavorite: false,
          action: .navigate(.games(.recentlyAdded))
        ),
        BigPictureRow(
          id: .home("favorites"),
          title: "Favorites",
          detail: catalog.favoriteGames.count.formatted(),
          isFavorite: false,
          action: .navigate(.games(.favorites))
        ),
        BigPictureRow(
          id: .home("downloaded"),
          title: "Downloaded",
          detail: catalog.downloadedGames.count.formatted(),
          isFavorite: false,
          action: .navigate(.downloaded)
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

    case .downloaded:
      [
        BigPictureRow(
          id: .home("downloaded-all"),
          title: "All Downloaded",
          detail: catalog.downloadedGames.count.formatted(),
          isFavorite: false,
          action: .navigate(.games(.downloaded))
        )
      ]
        + catalog.downloadedSystems.map { system in
          BigPictureRow(
            id: .system(system.id),
            title: system.name,
            detail: catalog.downloadedGameCount(inSystem: system.id).formatted(),
            isFavorite: false,
            action: .navigate(.games(.downloadedSystem(system.id)))
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
          isFavorite: catalog.favoriteGameIDs.contains(game.id),
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

  private var selectedSystem: LibrarySystem? {
    guard page == .home, rows.indices.contains(selectedIndex) else {
      return nil
    }
    guard case .system(let systemID) = rows[selectedIndex].id else {
      return nil
    }
    return catalog.systems.first(where: { $0.id == systemID })
  }

  private func hasResumeState(for game: GameSummary) -> Bool {
    game.hasState == true
      || model.localQuickStateGameIDs.contains(game.id)
  }

  private func gameOptions(
    for game: GameSummary
  ) -> [BigPictureGameOption] {
    let isFavorite = model.favoriteGameIDs.contains(game.id)
    let isDownloaded = model.downloadedGameIDs.contains(game.id)
    let hasSaveState = hasResumeState(for: game)

    var options = [
      BigPictureGameOption(
        action: .play,
        title: BigPictureGameLaunchPresentation.primaryActionTitle(
          hasSaveState: hasSaveState
        ),
        systemImage: "play.fill"
      )
    ]
    if BigPictureGameLaunchPresentation.showsPlayFromBeginning(
      hasSaveState: hasSaveState
    ) {
      options.append(
        BigPictureGameOption(
          action: .playFromBeginning,
          title: "Play from Beginning",
          systemImage: "forward.end.fill"
        )
      )
    }
    options.append(
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
      )
    )
    options.append(
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
      )
    )
    options.append(
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
      )
    )
    return options
  }

  private var pageTitle: String {
    switch page {
    case .home:
      "OpenVault"
    case .collections:
      "Collections"
    case .downloaded:
      "Downloaded"
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
    case .downloaded:
      "\(catalog.downloadedSystems.count.formatted()) SYSTEMS"
    case .games(let scope):
      "\(catalog.games(in: scope).count.formatted()) GAMES"
    }
  }

  private var rowFontSize: CGFloat {
    switch page {
    case .home:
      31
    case .collections, .downloaded, .games:
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
      hidesBIOSGames: model.hidesBIOSGames,
      includesExperimentalCores: enablesExperimentalCores,
      recentlyPlayedGameIDs: model.playHistory.gameIDsByRecency
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
    let includingExperimental = enablesExperimentalCores

    if catalog.systems.isEmpty, !source.systems.isEmpty {
      let startupCatalog = await Task.detached(priority: .userInitiated) {
        BigPictureCatalog(
          source: source,
          manifest: manifest,
          includingExperimental: includingExperimental,
          preparation: .startup
        )
      }.value
      guard !Task.isCancelled else {
        return
      }
      publishCatalog(startupCatalog)
    }

    let preparedCatalog = await Task.detached(priority: .userInitiated) {
      BigPictureCatalog(
        source: source,
        manifest: manifest,
        includingExperimental: includingExperimental,
        preparation: .full
      )
    }.value
    guard !Task.isCancelled else {
      return
    }
    publishCatalog(preparedCatalog)
    isBuildingCatalog = false
  }

  private func publishCatalog(_ preparedCatalog: BigPictureCatalog) {
    let selectedRowID =
      rows.indices.contains(selectedIndex)
      ? rows[selectedIndex].id
      : nil
    catalog = preparedCatalog
    rows = makeRows(for: page, catalog: preparedCatalog)
    if
      let selectedRowID,
      let preservedIndex = rows.firstIndex(where: {
        $0.id == selectedRowID
      })
    {
      selectedIndex = preservedIndex
    } else {
      selectedIndex = min(selectedIndex, max(rows.count - 1, 0))
    }
  }

  private func handle(_ command: BigPictureCommand) {
    if command == .exit {
      exitBigPicture()
      return
    }

    if command == .showSyncStatus {
      guard actionProgressTitle == nil, !isPreparingPlayback else {
        return
      }
      actionNotice = nil
      optionsGame = nil
      optionsSystem = nil
      playbackErrorMessage = nil
      isShowingSyncStatus.toggle()
      return
    }

    if actionProgressTitle != nil {
      return
    }

    if isShowingSyncStatus {
      switch command {
      case .activate, .playFromBeginning, .openGameOptions, .back:
        isShowingSyncStatus = false
      case .up, .down, .pageUp, .pageDown, .showSyncStatus, .exit:
        break
      }
      return
    }

    if actionNotice != nil {
      switch command {
      case .activate, .playFromBeginning, .back, .openGameOptions:
        actionNotice = nil
      case .up, .down, .pageUp, .pageDown, .showSyncStatus, .exit:
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
      case .activate, .playFromBeginning:
        activateSelectedGameOption(for: optionsGame)
      case .back, .openGameOptions:
        self.optionsGame = nil
      case .pageUp, .pageDown, .showSyncStatus, .exit:
        break
      }
      return
    }

    if let optionsSystem {
      switch command {
      case .activate, .playFromBeginning:
        let systemGames = model.games(inSystem: optionsSystem.id)
        let presentation = BigPictureSystemDownloadPresentation.make(
          totalGameCount: systemGames.count,
          downloadedGameCount: systemGames.count {
            model.managedDownloadedGameIDs.contains($0.id)
          }
        )
        performSystemDownloadAction(
          presentation.action,
          for: optionsSystem
        )
      case .back, .openGameOptions:
        self.optionsSystem = nil
      case .up, .down, .pageUp, .pageDown, .showSyncStatus, .exit:
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
      case .up, .down, .pageUp, .pageDown, .playFromBeginning,
        .openGameOptions, .showSyncStatus, .exit:
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
    case .playFromBeginning:
      playSelectedGameFromBeginning()
    case .openGameOptions:
      presentSelectedOptions()
    case .showSyncStatus:
      break
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

  /// Boots the selected game without restoring its quick state.
  ///
  /// The confirm button already resumes, because `play(_:)` restores the quick
  /// state whenever one exists and boots normally when it does not. This is
  /// the deliberate way past that, for when the saved position is somewhere
  /// you no longer want to be.
  private func playSelectedGameFromBeginning() {
    guard rows.indices.contains(selectedIndex),
      case let .play(game) = rows[selectedIndex].action
    else {
      return
    }
    play(game, fromBeginning: true)
  }

  private func presentSelectedOptions() {
    if let selectedGame {
      let options = gameOptions(for: selectedGame)
      optionsGame = selectedGame
      selectedGameOptionIndex =
        options.firstIndex(where: \.isEnabled) ?? 0
    } else if let selectedSystem {
      optionsSystem = selectedSystem
    }
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

  private func downloadAllGames(in system: LibrarySystem) {
    let systemGames = model.games(inSystem: system.id)
    guard
      !model.isDownloadingGames,
      systemGames.contains(where: {
        !model.managedDownloadedGameIDs.contains($0.id)
      })
    else {
      return
    }

    optionsSystem = nil
    actionProgressTitle =
      "Downloading \(systemGames.count.formatted()) "
      + (systemGames.count == 1 ? "Game" : "Games")
    Task {
      defer {
        actionProgressTitle = nil
      }
      let result = await model.downloadGames(systemGames)
      if result.completedWithoutErrors {
        actionNotice = BigPictureActionNotice(
          title: "System Downloaded",
          message:
            "Added \(result.successfulItemCount.formatted()) "
            + (result.successfulItemCount == 1 ? "game" : "games")
            + " from \(system.name) to OpenVault’s local library.",
          systemImage: "checkmark.circle"
        )
      } else {
        actionNotice = BigPictureActionNotice(
          title: "Some Games Couldn’t Be Downloaded",
          message:
            "Downloaded \(result.successfulItemCount.formatted()) and failed "
            + "to download \(result.failedItemCount.formatted()).\n\n"
            + (
              result.errors.first
                ?? "OpenVault couldn’t complete this action."
            ),
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  private func performSystemDownloadAction(
    _ action: BigPictureSystemDownloadAction,
    for system: LibrarySystem
  ) {
    switch action {
    case .download:
      downloadAllGames(in: system)
    case .remove:
      removeAllDownloads(in: system)
    case .unavailable:
      break
    }
  }

  private func removeAllDownloads(in system: LibrarySystem) {
    let downloadedGames = model.games(inSystem: system.id).filter {
      model.managedDownloadedGameIDs.contains($0.id)
    }
    guard !downloadedGames.isEmpty, !model.isRemovingDownloads else {
      return
    }

    optionsSystem = nil
    actionProgressTitle =
      "Removing \(downloadedGames.count.formatted()) "
      + (downloadedGames.count == 1 ? "Download" : "Downloads")
    Task {
      defer {
        actionProgressTitle = nil
      }
      let result = await model.removeDownloads(downloadedGames)
      if result.completedWithoutErrors {
        actionNotice = BigPictureActionNotice(
          title: "System Downloads Removed",
          message:
            "Removed \(result.successfulItemCount.formatted()) "
            + (result.successfulItemCount == 1 ? "game" : "games")
            + " from OpenVault’s local library.",
          systemImage: "checkmark.circle"
        )
      } else {
        actionNotice = operationFailureNotice(
          title: "Some Downloads Couldn’t Be Removed",
          errors: result.errors
        )
      }
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
    let action = BigPictureEscapeAction.resolve(
      isFullScreen: bigPictureWindow?.styleMask.contains(.fullScreen) == true,
      canNavigateBack: playbackErrorMessage != nil
        || isPreparingPlayback
        || isShowingSyncStatus
        || !history.isEmpty
    )

    switch action {
    case .leaveFullScreen:
      leaveFullScreenForEscape()
    case .navigateBack:
      handle(.back)
    case .exit:
      exitBigPicture()
    }
  }

  private func leaveFullScreenForEscape() {
    guard
      fullScreenEscapeTask == nil,
      let window = bigPictureWindow,
      window.styleMask.contains(.fullScreen)
    else {
      return
    }

    window.toggleFullScreen(nil)
    fullScreenEscapeTask = Task { @MainActor in
      defer {
        fullScreenEscapeTask = nil
      }
      for _ in 0..<160 {
        guard !Task.isCancelled else {
          return
        }
        guard window.styleMask.contains(.fullScreen) else {
          return
        }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  private func exitBigPicture() {
    guard exitTask == nil else {
      return
    }
    guard
      let window = bigPictureWindow,
      window.styleMask.contains(.fullScreen)
    else {
      onExitRequested()
      return
    }

    window.toggleFullScreen(nil)
    exitTask = Task { @MainActor in
      defer {
        exitTask = nil
      }
      for _ in 0..<160 {
        guard !Task.isCancelled else {
          return
        }
        guard window.styleMask.contains(.fullScreen) else {
          onExitRequested()
          return
        }
        try? await Task.sleep(for: .milliseconds(25))
      }
      onExitRequested()
    }
  }

  private func handleNavigationInput(_ command: BigPictureCommand) {
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

  private func handleTypeSelection(
    _ keyPress: KeyPress
  ) -> KeyPress.Result {
    guard
      keyPress.modifiers.intersection([.command, .control, .option]).isEmpty,
      BigPictureTypeSelection.isSearchCharacter(keyPress.characters),
      actionProgressTitle == nil,
      actionNotice == nil,
      optionsGame == nil,
      optionsSystem == nil,
      playbackErrorMessage == nil,
      !isPreparingPlayback
    else {
      return .ignored
    }

    if let index = BigPictureTypeSelection.index(
      matching: keyPress.characters,
      in: rows.map(\.title)
    ) {
      selectRow(at: index, scrollsIntoView: true)
    }
    return .handled
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
      switch await model.prioritizeDownloadForPlayback(game) {
      case .noActiveQueue, .downloaded:
        break
      case .failed(let message):
        playbackErrorMessage = message
        finishPlaybackPreparation(keepingError: true)
        return
      case .cancelled:
        finishPlaybackPreparation()
        return
      }

      await detailsModel.loadForPlayback(
        allowsRemoteAccess: model.isServerReachable
      )
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
      guard
        let request = await detailsModel.prepareToPlay(
          details,
          synchronizesWithServer: model.isServerReachable
        )
      else {
        // Preparation returns nothing both when it was cancelled and when it
        // genuinely failed, so cancellation has to be ruled out before any of
        // this is called an error. Checking it afterwards blamed a library
        // refresh that interrupted playback on the game file instead.
        guard !Task.isCancelled else {
          finishPlaybackPreparation()
          return
        }
        playbackErrorMessage =
          detailsModel.playbackErrorMessage
          ?? (
            detailsModel.playbackCore == nil
              ? "No bundled core supports this game file."
              : "OpenVault could not prepare this game."
          )
        finishPlaybackPreparation(keepingError: true)
        return
      }

      model.recordManagedDownload(gameID: game.id)
      await model.reloadDownloadedGames(reconcilingDuringDownloads: true)
      await model.recordPlay(gameID: game.id)
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

    Task { @MainActor in
      await model.reloadLocalQuickStates()
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

private struct BigPictureVideoEffectModifier: ViewModifier {
  @Environment(\.displayScale) private var displayScale
  let filter: LibretroVideoFilter

  @ViewBuilder
  func body(content: Content) -> some View {
    if let curvature = BigPictureVideoEffectPolicy.curvature(for: filter) {
      let scale = displayScale
      content.overlay {
        Rectangle()
          .fill(.white)
          .visualEffect { effect, geometry in
            effect.colorEffect(
              ShaderLibrary.openVaultBigPictureCRT(
                .float2(geometry.size),
                .float(scale),
                .float(curvature)
              )
            )
          }
          .blendMode(.multiply)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    } else {
      content
    }
  }
}

enum BigPictureVideoEffectPolicy {
  static func resolved(filter: LibretroVideoFilter) -> LibretroVideoFilter {
    switch filter {
    case .crtSmart, .crtCurved:
      // Curvature suits game imagery, but bends navigation and requires
      // flattening SwiftUI's lazy list. Keep Big Picture itself crisp and
      // flat while preserving the user's CRT scanlines and phosphor mask.
      return .crt
    case .nearest, .sharpBilinear, .xbr, .crt:
      return filter
    }
  }

  static func curvature(for filter: LibretroVideoFilter) -> Float? {
    switch filter {
    case .crt:
      0
    case .crtCurved:
      1
    case .crtSmart:
      // Smart is normally resolved before this point. A flat fallback keeps
      // aggregate pages such as Home and Favorites from implying a system.
      0
    case .nearest, .sharpBilinear, .xbr:
      nil
    }
  }
}

private enum BigPicturePage: Hashable {
  case home
  case collections
  /// The systems that have something downloaded, browsed before the games.
  case downloaded
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
  /// Part of the key so switching experimental cores on rebuilds the catalog
  /// instead of leaving their systems missing until something else changes.
  let includesExperimentalCores: Bool
  /// Only the ordering matters here. Comparing the identifiers by recency
  /// rather than the timestamps keeps a replay of the game already at the front
  /// from rebuilding a catalog that would come out identical.
  let recentlyPlayedGameIDs: [Int]
}

enum BigPictureCommand: Equatable, Sendable {
  case up
  case down
  case pageUp
  case pageDown
  case activate
  case playFromBeginning
  case openGameOptions
  case showSyncStatus
  case back
  case exit
}

enum BigPictureGameLaunchPresentation {
  static func primaryActionTitle(hasSaveState: Bool) -> String {
    hasSaveState ? "Resume" : "Play"
  }

  static func showsPlayFromBeginning(hasSaveState: Bool) -> Bool {
    hasSaveState
  }
}

enum BigPictureSystemDownloadAction: Equatable, Sendable {
  case download
  case remove
  case unavailable
}

struct BigPictureSystemDownloadPresentation: Equatable, Sendable {
  let action: BigPictureSystemDownloadAction
  let title: String
  let systemImage: String

  static func make(
    totalGameCount: Int,
    downloadedGameCount: Int
  ) -> Self {
    guard totalGameCount > 0 else {
      return Self(
        action: .unavailable,
        title: "No Games Available",
        systemImage: "nosign"
      )
    }

    let localCount = min(max(downloadedGameCount, 0), totalGameCount)
    if localCount == totalGameCount {
      return Self(
        action: .remove,
        title:
          "Remove All \(totalGameCount.formatted()) "
          + (totalGameCount == 1 ? "Download" : "Downloads"),
        systemImage: "trash"
      )
    }

    let remainingCount = totalGameCount - localCount
    return Self(
      action: .download,
      title:
        localCount == 0
        ? "Download All \(totalGameCount.formatted()) "
          + (totalGameCount == 1 ? "Game" : "Games")
        : "Download \(remainingCount.formatted()) Remaining "
          + (remainingCount == 1 ? "Game" : "Games"),
      systemImage: "arrow.down.circle"
    )
  }
}

enum BigPictureKeyboardNavigation {
  static let backspaceKeyCode: UInt16 = 51

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

  static func command(forMacKeyCode keyCode: UInt16) -> BigPictureCommand? {
    keyCode == backspaceKeyCode ? .back : nil
  }
}

enum BigPictureEscapeAction: Equatable, Sendable {
  case leaveFullScreen
  case navigateBack
  case exit

  static func resolve(
    isFullScreen: Bool,
    canNavigateBack: Bool
  ) -> Self {
    if isFullScreen {
      return .leaveFullScreen
    }
    return canNavigateBack ? .navigateBack : .exit
  }
}

enum BigPictureTypeSelection {
  static func isSearchCharacter(_ characters: String) -> Bool {
    characters.count == 1 && characters.first?.isLetter == true
  }

  static func index(
    matching characters: String,
    in titles: [String]
  ) -> Int? {
    guard isSearchCharacter(characters) else {
      return nil
    }

    let prefix = normalized(characters)
    return titles.firstIndex {
      normalized(
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      ).hasPrefix(prefix)
    }
  }

  private static func normalized(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: .current
    )
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

struct BigPictureControllerState: Equatable, Sendable {
  var isConnected = false
  var up = false
  var down = false
  var left = false
  var right = false
  var activate = false
  var playsFromBeginning = false
  var opensGameOptions = false
  var showsSyncStatus = false
  var back = false
  var opensBigPicture = false
  var pageUp = false
  var pageDown = false
  var activateButtonPrompt = BigPictureControllerPrompt(label: "B")
  var backButtonPrompt = BigPictureControllerPrompt(label: "A")
  var optionsButtonPrompt = BigPictureControllerPrompt(label: "START")
  var playFromBeginningButtonPrompt = BigPictureControllerPrompt(label: "X")
  var syncStatusButtonPrompt = BigPictureControllerPrompt(label: "SELECT")

  static var current: Self {
    let controllers = GCController.controllers()
    var state = Self(isConnected: !controllers.isEmpty)
    var hasLocalPrompts = false

    if let controller = GCController.current ?? controllers.first,
       let gamepad = controller.extendedGamepad
    {
      hasLocalPrompts = true
      let layout = ControllerFaceButtonLayout.resolve(
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
        localizedName: gamepad.buttonMenu.localizedName,
        systemImage: gamepad.buttonMenu.sfSymbolsName,
        fallbackLabel: "START"
      )
      state.playFromBeginningButtonPrompt = buttonPrompt(
        localizedName: gamepad.buttonX.localizedName,
        systemImage: gamepad.buttonX.sfSymbolsName,
        fallbackLabel: "X"
      )
      state.syncStatusButtonPrompt = buttonPrompt(
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
          layout: ControllerFaceButtonLayout.resolve(
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
          state.opensGameOptions || auxiliaryButtons.opensGameOptions
        state.playsFromBeginning =
          state.playsFromBeginning || gamepad.buttonX.isPressed
        state.showsSyncStatus =
          state.showsSyncStatus
          || auxiliaryButtons.showsSyncStatus
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

    if let pad = DSUConnection.shared.currentPad() {
      let layout = DSUConnection.shared.padLayout
      // A DSU pad names the on-screen prompts only when no local controller
      // is there to name them first.
      if !hasLocalPrompts {
        state.applyPrompts(for: layout)
      }
      state.merge(pad, layout: layout)
    }

    return state
  }

  /// Names the prompts for a pad that reports no button titles of its own.
  mutating func applyPrompts(for layout: ControllerFaceButtonLayout) {
    activateButtonPrompt = BigPictureControllerPrompt(
      label: layout == .nintendo ? "A" : "B"
    )
    backButtonPrompt = BigPictureControllerPrompt(
      label: layout == .nintendo ? "B" : "A"
    )
    optionsButtonPrompt = BigPictureControllerPrompt(label: "START")
    playFromBeginningButtonPrompt = BigPictureControllerPrompt(label: "X")
    syncStatusButtonPrompt = BigPictureControllerPrompt(label: "SELECT")
  }

  /// Folds a DSU pad into the same navigation state a local controller
  /// produces, so a network pad drives the interface as well as the emulator.
  mutating func merge(
    _ pad: DSUPadState,
    layout: ControllerFaceButtonLayout = .standard
  ) {
    isConnected = true

    let stick = pad.leftStick.normalized
    let faceButtons = Self.extendedFaceButtonActions(
      buttonAPressed: pad.buttons.contains(.a),
      buttonBPressed: pad.buttons.contains(.b),
      layout: layout
    )
    let auxiliaryButtons = Self.extendedAuxiliaryButtonActions(
      optionsPressed: pad.buttons.contains(.share),
      menuPressed: pad.buttons.contains(.options),
      homePressed: pad.isHomePressed
    )

    // The stick is already in screen orientation, where positive is down.
    up = up || pad.buttons.contains(.up) || stick.y < -0.72
    down = down || pad.buttons.contains(.down) || stick.y > 0.72
    left = left || pad.buttons.contains(.left) || stick.x < -0.72
    right = right || pad.buttons.contains(.right) || stick.x > 0.72
    activate = activate || faceButtons.activate
    back = back || faceButtons.back
    opensGameOptions = opensGameOptions || auxiliaryButtons.opensGameOptions
    playsFromBeginning = playsFromBeginning || pad.buttons.contains(.x)
    showsSyncStatus =
      showsSyncStatus || auxiliaryButtons.showsSyncStatus
    opensBigPicture = opensBigPicture || auxiliaryButtons.opensBigPicture
    pageUp = pageUp || pad.buttons.contains(.l1)
    pageDown = pageDown || pad.buttons.contains(.r1)
  }

  static func extendedFaceButtonActions(
    buttonAPressed: Bool,
    buttonBPressed: Bool,
    layout: ControllerFaceButtonLayout = .standard
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
    showsSyncStatus: Bool,
    opensGameOptions: Bool
  ) {
    (
      opensBigPicture: optionsPressed || homePressed,
      showsSyncStatus: optionsPressed,
      opensGameOptions: menuPressed
    )
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
    } else if state.left {
      repeatingCommand = .pageUp
      nextRepeatTime = .greatestFiniteMagnitude
    } else if state.right {
      repeatingCommand = .pageDown
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

    if state.showsSyncStatus, !previousState.showsSyncStatus {
      return .showSyncStatus
    }
    if state.back, !previousState.back {
      return .back
    }
    if state.opensGameOptions, !previousState.opensGameOptions {
      return .openGameOptions
    }
    if state.playsFromBeginning, !previousState.playsFromBeginning {
      return .playFromBeginning
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
    let directionalCommand: BigPictureCommand? =
      if state.up {
        .up
      } else if state.down {
        .down
      } else if state.left {
        .pageUp
      } else if state.right {
        .pageDown
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

private struct BigPictureWindowProbe: NSViewRepresentable {
  let isPlaybackActive: Bool
  let opensInFullScreen: Bool
  let onBackspaceRequested: @MainActor () -> Void
  let didMoveToWindow: @MainActor (NSWindow?) -> Void

  func makeNSView(context: Context) -> BigPictureProbeView {
    let view = BigPictureProbeView()
    view.setPlaybackActive(isPlaybackActive)
    view.setOpensInFullScreen(opensInFullScreen)
    view.onBackspaceRequested = onBackspaceRequested
    view.didMoveToWindow = didMoveToWindow
    return view
  }

  func updateNSView(_ nsView: BigPictureProbeView, context: Context) {
    nsView.didMoveToWindow = didMoveToWindow
    nsView.onBackspaceRequested = onBackspaceRequested
    nsView.setPlaybackActive(isPlaybackActive)
    nsView.setOpensInFullScreen(opensInFullScreen)
    nsView.configureWindow()
    nsView.requestFullScreenIfNeeded()
  }
}

struct BigPictureInitialFullScreenGate: Sendable {
  private(set) var hasHandledInitialPresentation = false

  mutating func shouldRequest(
    isWindowVisible: Bool,
    isFullScreen: Bool,
    preferenceEnabled: Bool
  ) -> Bool {
    guard isWindowVisible, !hasHandledInitialPresentation else {
      return false
    }

    hasHandledInitialPresentation = true
    return preferenceEnabled && !isFullScreen
  }
}

enum BigPicturePresentationOptions {
  static func immersive(
    from current: NSApplication.PresentationOptions
  ) -> NSApplication.PresentationOptions {
    var options = current
    options.remove(.hideMenuBar)
    options.remove(.hideDock)
    options.insert(.autoHideMenuBar)
    options.insert(.autoHideDock)
    return options
  }

  static func playbackImmersive(
    from current: NSApplication.PresentationOptions
  ) -> NSApplication.PresentationOptions {
    var options = current
    options.remove(.autoHideMenuBar)
    options.remove(.autoHideDock)
    options.insert(.hideMenuBar)
    options.insert(.hideDock)
    return options
  }
}

@MainActor
private final class BigPictureWindowState {
  private let collectionBehavior: NSWindow.CollectionBehavior
  private let styleMask: NSWindow.StyleMask
  private let backgroundColor: NSColor
  private let acceptsMouseMovedEvents: Bool
  private let isOpaque: Bool
  private let hasShadow: Bool
  private let titlebarAppearsTransparent: Bool
  private let titleVisibility: NSWindow.TitleVisibility
  private let zoomButtonTarget: AnyObject?
  private let zoomButtonAction: Selector?
  private let isZoomButtonEnabled: Bool?

  init(window: NSWindow) {
    collectionBehavior = window.collectionBehavior
    styleMask = window.styleMask
    backgroundColor = window.backgroundColor
    acceptsMouseMovedEvents = window.acceptsMouseMovedEvents
    isOpaque = window.isOpaque
    hasShadow = window.hasShadow
    titlebarAppearsTransparent = window.titlebarAppearsTransparent
    titleVisibility = window.titleVisibility

    let zoomButton = window.standardWindowButton(.zoomButton)
    zoomButtonTarget = zoomButton?.target
    zoomButtonAction = zoomButton?.action
    isZoomButtonEnabled = zoomButton?.isEnabled
  }

  func restore(on window: NSWindow) {
    window.collectionBehavior = collectionBehavior
    window.styleMask = styleMask
    window.backgroundColor = backgroundColor
    window.acceptsMouseMovedEvents = acceptsMouseMovedEvents
    window.isOpaque = isOpaque
    window.hasShadow = hasShadow
    window.titlebarAppearsTransparent = titlebarAppearsTransparent
    window.titleVisibility = titleVisibility

    if let zoomButton = window.standardWindowButton(.zoomButton) {
      zoomButton.target = zoomButtonTarget
      zoomButton.action = zoomButtonAction
      if let isZoomButtonEnabled {
        zoomButton.isEnabled = isZoomButtonEnabled
      }
    }
  }
}

@MainActor
private final class BigPictureProbeView: NSView {
  private static let cursorIdleInterval: TimeInterval = 1.5

  var didMoveToWindow: (@MainActor (NSWindow?) -> Void)?
  var onBackspaceRequested: (@MainActor () -> Void)?
  private weak var observedWindow: NSWindow?
  private var previousWindowState: BigPictureWindowState?
  private var fullScreenRequest: Task<Void, Never>?
  private var cursorHideTask: Task<Void, Never>?
  private var keyboardMonitor: Any?
  private var pointerTrackingArea: NSTrackingArea?
  private var initialFullScreenGate = BigPictureInitialFullScreenGate()
  private var previousPresentationOptions:
    NSApplication.PresentationOptions?
  private var isPlaybackActive = false
  private var opensInFullScreen = true

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    didMoveToWindow?(window)
    guard let window else {
      stopObservingWindow()
      return
    }

    observe(window)
    window.backgroundColor = .black
    configureWindow()
    if window.styleMask.contains(.fullScreen) {
      beginImmersivePresentation()
    }
    requestFullScreenIfNeeded()
    recordPointerActivity()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      restoreCursor()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let pointerTrackingArea {
      removeTrackingArea(pointerTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [
        .activeInKeyWindow,
        .inVisibleRect,
        .mouseEnteredAndExited,
        .mouseMoved,
      ],
      owner: self
    )
    addTrackingArea(trackingArea)
    pointerTrackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    recordPointerActivity()
  }

  override func mouseMoved(with event: NSEvent) {
    recordPointerActivity()
  }

  override func mouseExited(with event: NSEvent) {
    restoreCursor()
  }

  func requestFullScreenIfNeeded() {
    guard
      let window,
      initialFullScreenGate.shouldRequest(
        isWindowVisible: window.isVisible,
        isFullScreen: window.styleMask.contains(.fullScreen),
        preferenceEnabled: opensInFullScreen
      ),
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
      configureBigPictureWindow(window)
      window.toggleFullScreen(nil)
    }
  }

  func configureWindow() {
    guard let window else {
      return
    }
    configureBigPictureWindow(window)
  }

  func setPlaybackActive(_ isPlaybackActive: Bool) {
    guard self.isPlaybackActive != isPlaybackActive else {
      return
    }
    self.isPlaybackActive = isPlaybackActive
    if isPlaybackActive {
      restoreCursor()
    } else {
      recordPointerActivity()
    }
    applyImmersivePresentation()
  }

  func setOpensInFullScreen(_ opensInFullScreen: Bool) {
    self.opensInFullScreen = opensInFullScreen
  }

  isolated deinit {
    cursorHideTask?.cancel()
    if let keyboardMonitor {
      NSEvent.removeMonitor(keyboardMonitor)
    }
    NSCursor.setHiddenUntilMouseMoves(false)
    NotificationCenter.default.removeObserver(self)
  }

  private func observe(_ window: NSWindow) {
    guard observedWindow !== window else {
      return
    }

    stopObservingWindow()
    observedWindow = window
    previousWindowState = BigPictureWindowState(window: window)
    keyboardMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown
    ) { [weak self, weak window] event in
      guard
        let self,
        window?.isKeyWindow == true,
        !self.isPlaybackActive,
        BigPictureKeyboardNavigation.command(
          forMacKeyCode: event.keyCode
        ) == .back,
        event.modifierFlags
          .intersection([.command, .control, .option])
          .isEmpty
      else {
        return event
      }

      if !event.isARepeat {
        self.onBackspaceRequested?()
      }
      return nil
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidResignKey(_:)),
      name: NSWindow.didResignKeyNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidEnterFullScreen(_:)),
      name: NSWindow.didEnterFullScreenNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidExitFullScreen(_:)),
      name: NSWindow.didExitFullScreenNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: window
    )
  }

  private func stopObservingWindow() {
    fullScreenRequest?.cancel()
    fullScreenRequest = nil
    if let keyboardMonitor {
      NSEvent.removeMonitor(keyboardMonitor)
      self.keyboardMonitor = nil
    }
    restoreCursor()
    endImmersivePresentation()
    if let observedWindow {
      NotificationCenter.default.removeObserver(
        self,
        name: nil,
        object: observedWindow
      )
      previousWindowState?.restore(on: observedWindow)
    }
    previousWindowState = nil
    observedWindow = nil
  }

  @objc
  private func windowDidBecomeKey(_ notification: Notification) {
    configureWindow()
    requestFullScreenIfNeeded()
    recordPointerActivity()
  }

  @objc
  private func windowDidResignKey(_ notification: Notification) {
    restoreCursor()
  }

  @objc
  private func windowDidEnterFullScreen(_ notification: Notification) {
    configureWindow()
    beginImmersivePresentation()
  }

  @objc
  private func windowDidExitFullScreen(_ notification: Notification) {
    configureWindow()
    endImmersivePresentation()
  }

  @objc
  private func windowWillClose(_ notification: Notification) {
    restoreCursor()
    endImmersivePresentation()
  }

  private func recordPointerActivity() {
    NSCursor.setHiddenUntilMouseMoves(false)
    cursorHideTask?.cancel()
    cursorHideTask = nil
    guard
      !isPlaybackActive,
      let window,
      window.isKeyWindow,
      window.frame.contains(NSEvent.mouseLocation)
    else {
      return
    }

    cursorHideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.cursorIdleInterval))
      guard
        let self,
        !Task.isCancelled,
        !self.isPlaybackActive,
        let window = self.window,
        window.isKeyWindow,
        window.frame.contains(NSEvent.mouseLocation)
      else {
        return
      }
      NSCursor.setHiddenUntilMouseMoves(true)
    }
  }

  private func restoreCursor() {
    cursorHideTask?.cancel()
    cursorHideTask = nil
    NSCursor.setHiddenUntilMouseMoves(false)
  }

  private func beginImmersivePresentation() {
    if previousPresentationOptions == nil {
      previousPresentationOptions = NSApplication.shared.presentationOptions
    }
    applyImmersivePresentation()
  }

  private func applyImmersivePresentation() {
    guard
      let previousPresentationOptions,
      window?.styleMask.contains(.fullScreen) == true
    else {
      return
    }
    let application = NSApplication.shared
    application.presentationOptions =
      isPlaybackActive
      ? BigPicturePresentationOptions.playbackImmersive(
        from: previousPresentationOptions
      )
      : BigPicturePresentationOptions.immersive(
        from: previousPresentationOptions
      )
  }

  private func endImmersivePresentation() {
    guard let previousPresentationOptions else {
      return
    }

    NSApplication.shared.presentationOptions = previousPresentationOptions
    self.previousPresentationOptions = nil
  }
}

@MainActor
func configureBigPictureWindow(_ window: NSWindow) {
  window.collectionBehavior.remove(.fullScreenNone)
  window.collectionBehavior.insert(.fullScreenPrimary)
  window.styleMask.insert([
    .titled,
    .closable,
    .miniaturizable,
    .resizable,
    .fullSizeContentView,
  ])
  window.backgroundColor = .black
  window.acceptsMouseMovedEvents = true
  window.isOpaque = true
  window.hasShadow = false
  window.titlebarAppearsTransparent = true
  window.titleVisibility = .hidden
  let fullScreenButton = window.standardWindowButton(.zoomButton)
  fullScreenButton?.target = window
  fullScreenButton?.action = #selector(NSWindow.toggleFullScreen(_:))
  fullScreenButton?.isEnabled = true
}

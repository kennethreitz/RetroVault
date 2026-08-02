@preconcurrency import AppKit
@preconcurrency import GameController
import SwiftUI

enum BigPictureScene {
  static let opensInFullScreenPreferenceKey =
    "big-picture.opens-in-full-screen.v1"
  static let opensInFullScreenByDefault = true
  static let systemGameSortPreferenceKey =
    "big-picture.system-game-sort.v1"
  static let ignoredSystemIDsPreferenceKey =
    "big-picture.ignored-system-ids.v1"
}

struct BigPictureSynchronizationFooterPresentation:
  Equatable, Sendable
{
  let completedGameCount: Int
  let totalGameCount: Int

  static func make(
    isSynchronizing: Bool,
    completedGameCount: Int,
    totalGameCount: Int,
    lastSuccessfulSync: Date?,
    refreshErrorMessage: String?
  ) -> Self? {
    let hasRefreshError =
      !(refreshErrorMessage?.isEmpty ?? true)
    let isWaitingForInitialSync =
      lastSuccessfulSync == nil && !hasRefreshError

    guard isSynchronizing || isWaitingForInitialSync else {
      return nil
    }

    return Self(
      completedGameCount: completedGameCount,
      totalGameCount: totalGameCount
    )
  }

  var label: String {
    guard totalGameCount > 0 else {
      return "SYNCHRONIZING WITH ROMM…"
    }
    return
      "SYNCHRONIZING \(min(completedGameCount, totalGameCount).formatted())"
      + " OF \(totalGameCount.formatted())"
  }
}

struct BigPictureView: View {
  private static let bundledManifest =
    try? LibretroInstallation.bundled().manifest

  @Bindable var model: LibraryModel
  let onExitRequested: () -> Void
  let onDisconnectRequested: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reducesMotion
  @Environment(\.openWindow) private var openWindow
  @AppStorage(BigPictureScene.opensInFullScreenPreferenceKey)
  private var opensInFullScreen =
    BigPictureScene.opensInFullScreenByDefault
  @AppStorage(BigPictureScene.systemGameSortPreferenceKey)
  private var systemGameSortRawValue =
    BigPictureSystemGameSort.defaultSort.rawValue
  @AppStorage(BigPictureScene.ignoredSystemIDsPreferenceKey)
  private var ignoredSystemIDsRawValue = ""
  @AppStorage(LibretroTransportPreferences.enablesFastForwardKey)
  private var enablesR3FastForward =
    LibretroTransportPreferences.enabledByDefault
  @AppStorage(LibretroTransportPreferences.enablesRewindKey)
  private var enablesL3Rewind =
    LibretroTransportPreferences.enabledByDefault
  @AppStorage(LibretroInternalResolutionPreferences.scaleKey)
  private var internalResolution =
    LibretroInternalResolutionPreferences.defaultResolution
  @AppStorage(LibretroPlayerPreferences.opensInFullScreenKey)
  private var opensGamesInFullScreen =
    LibretroPlayerPreferences.opensInFullScreenByDefault
  @AppStorage(LibretroWiiControllerPreferences.profileKey)
  private var wiiControllerProfile =
    LibretroWiiControllerPreferences.defaultProfile
  @AppStorage(LibretroDigitalInputPreferences.mapsLeftAnalogToDPadKey)
  private var mapsLeftAnalogToDPad =
    LibretroDigitalInputPreferences.mapsLeftAnalogToDPadByDefault
  @AppStorage(DSUPreferences.isEnabledKey)
  private var usesDSUController = DSUPreferences.enabledByDefault
  @AppStorage(DSUPreferences.hostKey)
  private var dsuHost = DSUProtocol.defaultHost
  @AppStorage(DSUPreferences.portKey)
  private var dsuPort = Int(DSUProtocol.defaultPort)
  @AppStorage(DSUPreferences.layoutKey)
  private var dsuLayout = DSUPreferences.defaultLayout.rawValue

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
  @State private var sortTask: Task<Void, Never>?
  @State private var sortGeneration = 0
  @State private var isLoadingGameDetails = false
  @State private var playbackErrorMessage: String?
  @State private var requestedGame: GameSummary?
  @State private var requestedGameStartsFresh = false
  @State private var activePlayerRequest: LibretroRunRequest?
  @State private var activeVita3KRequest: Vita3KRunRequest?
  @State private var activeCemuRequest: CemuRunRequest?
  @State private var optionsGame: GameSummary?
  @State private var optionsSystem: LibrarySystem?
  @State private var selectedGameOptionIndex = 0
  @State private var selectedSystemOptionIndex = 0
  @State private var queuedSystemIDs: Set<Int> = []
  @State private var actionProgress: BigPictureActionProgress?
  @State private var bulkDownloadTask: Task<Void, Never>?
  @State private var actionNotice: BigPictureActionNotice?
  @State private var settingsConfirmation: BigPictureSetting?
  @State private var isShowingSyncStatus = false
  @Namespace private var selectionHighlight
  @FocusState private var hasInterfaceFocus: Bool

  var body: some View {
    ZStack {
      if let activeVita3KRequest {
        Vita3KGameView(
          request: activeVita3KRequest,
          onCloseRequested: returnToBigPicture
        )
        .id(activeVita3KRequest)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let activeCemuRequest {
        CemuGameView(
          request: activeCemuRequest,
          service: model.service,
          dsuConfiguration: cemuDSUConfiguration,
          launchPresentation: cemuLaunchPresentation,
          onCloseRequested: returnToBigPicture
        )
        .id(activeCemuRequest)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let activePlayerRequest {
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
        isPlaybackActive:
          activePlayerRequest != nil || activeVita3KRequest != nil
            || activeCemuRequest != nil,
        opensInFullScreen: opensInFullScreen,
        onBackspaceRequested: handleEscape
      ) { window in
        bigPictureWindow = window
      }
    }
    .task {
      await model.load()
      await model.reloadSaveCenter()
      if page == .home || page == .saveCenter {
        rows = makeRows(for: page, catalog: catalog)
      }
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
      sortTask?.cancel()
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
      } else if let gameID = model.saveCenterSyncingGameID {
        saveSynchronizationOverlay(gameID: gameID)
      } else if let playbackErrorMessage {
        errorOverlay(playbackErrorMessage)
      } else if let actionProgress, !actionProgress.isBackgrounded {
        actionProgressOverlay(actionProgress)
      } else if let optionsGame {
        gameOptionsOverlay(optionsGame)
      } else if let optionsSystem {
        systemOptionsOverlay(optionsSystem)
      } else if let settingsConfirmation {
        settingsConfirmationOverlay(settingsConfirmation)
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
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 4) {
        // Keep each render pass self-contained. The catalog can replace
        // `rows` while SwiftUI is still evaluating a lazy child from the
        // previous pass; indexing back into the newer array would then trap
        // when a system has fewer games.
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          Button {
            selectRow(at: index, scrollsIntoView: false)
            activate(row)
          } label: {
            HStack(spacing: 16) {
              if page == .saveCenter, let item = saveCenterItem(for: row) {
                Image(systemName: item.status.systemImage)
                  .font(.system(size: 15, weight: .bold))
                  .foregroundStyle(saveCenterStatusColor(item.status))
                  .accessibilityLabel(item.status.title)
              } else if page.isGameList {
                Image(systemName: "star.fill")
                  .font(.system(size: 13, weight: .bold))
                  .foregroundStyle(.yellow)
                  .opacity(row.isFavorite ? 1 : 0)
                  .accessibilityHidden(!row.isFavorite)
                  .accessibilityLabel("Favorite")
              } else if page == .home {
                // Every Home row reserves the same indicator column. Without
                // it, only system rows move to the right and visually read as
                // children of Downloaded even though they are peers.
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 16, weight: .bold))
                  .foregroundStyle(
                    index == selectedIndex ? .black : .yellow
                  )
                  .opacity(
                    homeSystemID(for: row).map(queuedSystemIDs.contains)
                      == true
                      ? 1 : 0
                  )
                  .accessibilityHidden(
                    homeSystemID(for: row).map(queuedSystemIDs.contains)
                      != true
                  )
                  .accessibilityLabel("Queued for download")
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
      .scrollTargetLayout()
      .padding(.vertical, 6)
    }
    .id(page)
    .scrollIndicators(.hidden)
    .scrollPosition(id: $scrollTargetID, anchor: .center)
  }

  private var footer: some View {
    HStack {
      HStack(spacing: 10) {
        if page == .home {
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
        }

        if page != .home {
          actionHint(
            key: controllerState.backButtonPrompt.label,
            systemImage: controllerState.backButtonPrompt.systemImage,
            label: "BACK"
          )
        }
      }

      Spacer()

      if let synchronizationFooter {
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.2.circlepath")
          Text(synchronizationFooter.label)
        }
        .font(.system(size: 13, weight: .black, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(.yellow.opacity(0.78))
        .monospacedDigit()
        .accessibilityLabel(synchronizationFooter.label)
      } else if let progress = model.downloadProgress {
        HStack(spacing: 8) {
          Image(systemName: "arrow.down.circle")
          Text(
            "DOWNLOADING \(progress.currentGameNumber.formatted())"
              + " OF \(progress.totalGameCount.formatted())"
          )
        }
        .font(.system(size: 13, weight: .black, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(.yellow.opacity(0.78))
        .monospacedDigit()
      } else {
        Text(model.allGameCount.formatted() + " GAMES")
          .font(.system(size: 13, weight: .black, design: .rounded))
          .tracking(1.2)
          .foregroundStyle(.white.opacity(0.45))
      }

      Spacer()

      HStack(spacing: 10) {
        if isSortableGameList {
          actionHint(
            key: controllerState.sortButtonPrompt.label,
            systemImage: controllerState.sortButtonPrompt.systemImage,
            label: "SORT"
          )
        }
        if selectedSaveCenterItem != nil {
          actionHint(
            key: controllerState.playFromBeginningButtonPrompt.label,
            systemImage:
              controllerState.playFromBeginningButtonPrompt.systemImage,
            label: BigPictureGameLaunchPresentation.secondaryActionTitle(
              isSaveCenter: true
            ).uppercased()
          )
        } else if page.isGameList || selectedSystem != nil {
          actionHint(
            key: controllerState.optionsButtonPrompt.label,
            systemImage: controllerState.optionsButtonPrompt.systemImage,
            label: "OPTIONS"
          )
        }
        actionHint(
          key: controllerState.activateButtonPrompt.label,
          systemImage: controllerState.activateButtonPrompt.systemImage,
          label:
            selectedSaveCenterItem.map {
              BigPictureSaveCenterPresentation.primaryActionTitle(
                for: $0.status
              ).uppercased()
            } ?? selectedSetting.map(settingActionLabel) ?? selectedGame.map {
              BigPictureGameLaunchPresentation.primaryActionTitle(
                hasSaveState: hasResumeState(for: $0)
              ).uppercased()
            } ?? "OPEN"
        )
      }
    }
    .frame(height: 64)
  }

  private var synchronizationFooter:
    BigPictureSynchronizationFooterPresentation?
  {
    BigPictureSynchronizationFooterPresentation.make(
      isSynchronizing: model.isSynchronizing,
      completedGameCount: model.synchronizedGameCount,
      totalGameCount: model.synchronizationTotalGameCount,
      lastSuccessfulSync: model.lastSuccessfulSync,
      refreshErrorMessage: model.refreshErrorMessage
    )
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
    let options = systemOptions(for: system)

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

      VStack(spacing: 5) {
        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
          Button {
            selectedSystemOptionIndex = index
            perform(option.action, for: system)
          } label: {
            HStack(spacing: 13) {
              Image(systemName: option.systemImage)
                .frame(width: 24)
              Text(option.title)
              Spacer()
            }
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .foregroundStyle(
              index == selectedSystemOptionIndex ? .black : .white
            )
            .padding(.horizontal, 17)
            .frame(height: 48)
            .background {
              if index == selectedSystemOptionIndex {
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

  private func settingsConfirmationOverlay(
    _ setting: BigPictureSetting
  ) -> some View {
    let presentation = BigPictureSettingsConfirmationPresentation.make(
      for: setting
    )
    return VStack(spacing: 18) {
      Image(systemName: presentation.systemImage)
        .font(.system(size: 38, weight: .light))

      Text(presentation.title.uppercased())
        .font(.system(size: 24, weight: .black, design: .rounded))

      Text(presentation.message)
        .font(.system(size: 16, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.66))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 500)

      HStack(spacing: 12) {
        actionHint(
          key: controllerState.activateButtonPrompt.label,
          systemImage: controllerState.activateButtonPrompt.systemImage,
          label: "CONFIRM"
        )
        actionHint(
          key: controllerState.backButtonPrompt.label,
          systemImage: controllerState.backButtonPrompt.systemImage,
          label: "BACK"
        )
      }
    }
    .padding(38)
    .frame(minWidth: 540)
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
          key: controllerState.activateButtonPrompt.label,
          systemImage: controllerState.activateButtonPrompt.systemImage,
          label: model.isSynchronizing ? "SYNCING" : "SYNC NOW"
        )
        .opacity(model.isSynchronizing ? 0.48 : 1)
        actionHint(
          key: controllerState.optionsButtonPrompt.label,
          systemImage: controllerState.optionsButtonPrompt.systemImage,
          label: "SETTINGS"
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

  private func actionProgressOverlay(
    _ operation: BigPictureActionProgress
  ) -> some View {
    VStack(spacing: 20) {
      ProgressView()
        .controlSize(.large)
        .tint(.white)

      Text(operation.title.uppercased())
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
    let ignoredSystemIDs = BigPictureIgnoredSystems.decode(
      ignoredSystemIDsRawValue
    )
    let visibleSystems = catalog.systems.filter {
      !ignoredSystemIDs.contains($0.id)
    }
    let ignoredSystems = catalog.systems.filter {
      ignoredSystemIDs.contains($0.id)
    }

    return switch page {
    case .home:
      BigPictureHomeLibrarySection.displayOrder.map {
        homeLibraryRow(for: $0, catalog: catalog)
      }
        + (queuedSystemIDs.isEmpty
          ? []
          : [
            BigPictureRow(
              id: .home("download-queue"),
              title: "Download Queue",
              detail: systemDownloadQueueDetail,
              isFavorite: false,
              action: .downloadSystemQueue
            )
          ])
        + visibleSystems.map { system in
          BigPictureRow(
            id: .system(system.id),
            title: system.name,
            detail: system.gameCount.formatted(),
            isFavorite: false,
            action: .navigate(.games(.system(system.id)))
          )
        }
        + [
          BigPictureRow(
            id: .home("save-center"),
            title: "Save Center",
            detail: model.saveCenterItems.count.formatted(),
            isFavorite: false,
            action: .navigate(.saveCenter)
          )
        ]

    case .ignoredSystems:
      ignoredSystems.map { system in
        BigPictureRow(
          id: .system(system.id),
          title: system.name,
          detail: system.gameCount.formatted(),
          isFavorite: false,
          action: .navigate(.games(.system(system.id)))
        )
      }

    case .settings:
      settingsRows

    case .saveCenter:
      model.saveCenterItems.map { item in
        BigPictureRow(
          id: .save(item.id),
          title: item.game.name,
          detail: item.detail,
          isFavorite: false,
          action:
            BigPictureSaveCenterPresentation.primaryAction(for: item.status)
              == .play
            ? .play(item.game)
            : .synchronizeSave(item.id)
        )
      }

    case .downloaded:
      [
        BigPictureRow(
          id: .home("downloaded-all"),
          title: "All Downloaded Games",
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
      sortedGames(in: scope).map { game in
        BigPictureRow(
          id: .game(game.id),
          title: game.name,
          detail: BigPictureGameRowPresentation.detail(
            releaseYear: game.releaseYear,
            isDownloaded: downloadedGameIDs.contains(game.id),
            systemName:
              scope == .favorites || scope == .recentlyPlayed
              ? game.systemName
              : nil
          ),
          isFavorite: catalog.favoriteGameIDs.contains(game.id),
          action: .play(game)
        )
      }
    }
  }

  private func homeLibraryRow(
    for section: BigPictureHomeLibrarySection,
    catalog: BigPictureCatalog
  ) -> BigPictureRow {
    switch section {
    case .downloadedGames:
      BigPictureRow(
        id: .home("downloaded"),
        title: section.title,
        detail: catalog.downloadedGames.count.formatted(),
        isFavorite: false,
        action: .navigate(.downloaded)
      )
    case .recentlyPlayed:
      BigPictureRow(
        id: .home("recently-played"),
        title: section.title,
        detail: catalog.recentlyPlayedGames.count.formatted(),
        isFavorite: false,
        action: .navigate(.games(.recentlyPlayed))
      )
    case .favoriteGames:
      BigPictureRow(
        id: .home("favorites"),
        title: section.title,
        detail: catalog.favoriteGames.count.formatted(),
        isFavorite: false,
        action: .navigate(.games(.favorites))
      )
    case .recentlyAdded:
      BigPictureRow(
        id: .home("recent"),
        title: section.title,
        detail: catalog.recentlyAddedGames.count.formatted(),
        isFavorite: false,
        action: .navigate(.games(.recentlyAdded))
      )
    case .allGames:
      BigPictureRow(
        id: .home("all-games"),
        title: section.title,
        detail: catalog.allGames.count.formatted(),
        isFavorite: false,
        action: .navigate(.games(.all))
      )
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

  private var selectedSaveCenterItem: SaveCenterItem? {
    guard page == .saveCenter, rows.indices.contains(selectedIndex) else {
      return nil
    }
    return saveCenterItem(for: rows[selectedIndex])
  }

  private var selectedSystem: LibrarySystem? {
    guard
      page == .home || page == .ignoredSystems,
      rows.indices.contains(selectedIndex)
    else {
      return nil
    }
    guard case .system(let systemID) = rows[selectedIndex].id else {
      return nil
    }
    return catalog.systems.first(where: { $0.id == systemID })
  }

  private func homeSystemID(for row: BigPictureRow) -> Int? {
    guard case .system(let systemID) = row.id else {
      return nil
    }
    return systemID
  }

  private var ignoredSystemIDs: Set<Int> {
    BigPictureIgnoredSystems.decode(ignoredSystemIDsRawValue)
  }

  private var selectedSetting: BigPictureSetting? {
    guard page == .settings, rows.indices.contains(selectedIndex) else {
      return nil
    }
    guard case .setting(let setting) = rows[selectedIndex].id else {
      return nil
    }
    return setting
  }

  private func settingActionLabel(_ setting: BigPictureSetting) -> String {
    switch setting {
    case .romMServer, .romMUser, .runtime, .dsuEndpoint, .dsuStatus:
      "VIEW"
    case .resynchronizeLibrary:
      "SYNC"
    case .purgeAndResynchronize:
      "PURGE"
    case .openLogs:
      "OPEN"
    case .disconnect:
      "DISCONNECT"
    case .videoFilter, .internalResolution, .wiiController,
      .mapsLeftAnalogToDPad, .fastForward, .rewind, .gamesFullScreen,
      .experimentalCores, .dsuEnabled, .dsuLayout,
      .bigPictureFullScreen:
      "CHANGE"
    }
  }

  private var settingsRows: [BigPictureRow] {
    (ignoredSystemIDs.isEmpty
      ? []
      : [
        BigPictureRow(
          id: .home("ignored-systems"),
          title: "Ignored Systems",
          detail: ignoredSystemIDs.count.formatted(),
          isFavorite: false,
          action: .navigate(.ignoredSystems)
        )
      ])
      + [
      settingRow(
        .romMServer,
        title: "RomM Server",
        detail: model.session.serverURL.value.absoluteString
      ),
      settingRow(
        .romMUser,
        title: "RomM User",
        detail: model.session.username
      ),
      settingRow(
        .resynchronizeLibrary,
        title: "Resync Library",
        detail: model.isSynchronizing ? "IN PROGRESS" : nil
      ),
      settingRow(
        .purgeAndResynchronize,
        title: "Purge Local Cache & Resync"
      ),
      settingRow(
        .runtime,
        title: "Emulation Runtime",
        detail: "Bundled Libretro"
      ),
      settingRow(
        .videoFilter,
        title: "Video Filter",
        detail: videoFilter.displayName
      ),
      settingRow(
        .internalResolution,
        title: "Internal Resolution",
        detail: internalResolution.displayName
      ),
      settingRow(
        .wiiController,
        title: "Wii Controller",
        detail: wiiControllerProfile.displayName
      ),
      settingRow(
        .mapsLeftAnalogToDPad,
        title: "Left Stick to D-Pad",
        detail: onOff(mapsLeftAnalogToDPad)
      ),
      settingRow(
        .fastForward,
        title: "Fast Forward with R3",
        detail: onOff(enablesR3FastForward)
      ),
      settingRow(
        .rewind,
        title: "Rewind with L3",
        detail: onOff(enablesL3Rewind)
      ),
      settingRow(
        .gamesFullScreen,
        title: "Open Games in Full Screen",
        detail: onOff(opensGamesInFullScreen)
      ),
      settingRow(
        .experimentalCores,
        title: "Experimental Cores",
        detail: onOff(enablesExperimentalCores)
      ),
      settingRow(
        .dsuEnabled,
        title: "DSU Controller",
        detail: onOff(usesDSUController)
      ),
      settingRow(
        .dsuEndpoint,
        title: "DSU Server",
        detail: "\(dsuHost):\(dsuPort)"
      ),
      settingRow(
        .dsuLayout,
        title: "DSU Button Layout",
        detail:
          dsuLayout == ControllerFaceButtonLayout.nintendo.rawValue
          ? "Nintendo"
          : "Standard"
      ),
      settingRow(
        .dsuStatus,
        title: "DSU Status",
        detail: DSUConnection.shared.status.summary
      ),
      settingRow(
        .bigPictureFullScreen,
        title: "Open RetroVault in Full Screen",
        detail: onOff(opensInFullScreen)
      ),
      settingRow(.openLogs, title: "Open Log Viewer"),
      settingRow(.disconnect, title: "Disconnect from RomM"),
      ]
  }

  private func settingRow(
    _ setting: BigPictureSetting,
    title: String,
    detail: String? = nil
  ) -> BigPictureRow {
    BigPictureRow(
      id: .setting(setting),
      title: title,
      detail: detail,
      isFavorite: false,
      action: .setting(setting)
    )
  }

  private func onOff(_ value: Bool) -> String {
    value ? "ON" : "OFF"
  }

  private var queuedSystems: [LibrarySystem] {
    catalog.systems.filter { queuedSystemIDs.contains($0.id) }
  }

  private var queuedSystemGames: [GameSummary] {
    queuedSystems.flatMap { model.games(inSystem: $0.id) }
  }

  private var queuedRemainingGames: [GameSummary] {
    queuedSystemGames.filter {
      !model.managedDownloadedGameIDs.contains($0.id)
    }
  }

  private var systemDownloadQueueDetail: String {
    let systemCount = queuedSystems.count
    let gameCount = queuedRemainingGames.count
    return
      "\(systemCount.formatted()) "
      + (systemCount == 1 ? "SYSTEM" : "SYSTEMS")
      + " · \(gameCount.formatted()) "
      + (gameCount == 1 ? "GAME" : "GAMES")
  }

  private func systemOptions(
    for system: LibrarySystem
  ) -> [BigPictureSystemOption] {
    let systemGames = model.games(inSystem: system.id)
    let downloadedGameCount = systemGames.count {
      model.managedDownloadedGameIDs.contains($0.id)
    }
    let presentation = BigPictureSystemDownloadPresentation.make(
      totalGameCount: systemGames.count,
      downloadedGameCount: downloadedGameCount
    )
    let isBusy = model.isDownloadingGames || model.isRemovingDownloads

    var options: [BigPictureSystemOption] = []
    if presentation.action == .download {
      let isQueued = queuedSystemIDs.contains(system.id)
      options.append(
        BigPictureSystemOption(
          action: .setQueued(!isQueued),
          title:
            isQueued
            ? "Remove from Download Queue"
            : "Add to Download Queue",
          systemImage:
            isQueued ? "checkmark.circle.fill" : "plus.circle",
          isEnabled: !isBusy
        )
      )
    }
    options.append(
      BigPictureSystemOption(
        action: .performDownload(presentation.action),
        title: presentation.title,
        systemImage: presentation.systemImage,
        isEnabled: presentation.action != .unavailable && !isBusy
      )
    )
    let isIgnored = ignoredSystemIDs.contains(system.id)
    options.append(
      BigPictureSystemOption(
        action: .setIgnored(!isIgnored),
        title: isIgnored ? "Restore System" : "Ignore System",
        systemImage: isIgnored ? "eye" : "eye.slash"
      )
    )
    return options
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
    let hasManagedSave = BigPictureGameSavePresentation.isAvailable(
      gameHasRemoteSave: game.hasSave == true,
      hasLocalSave: model.saveCenterItems.contains { $0.id == game.id }
    )

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
    if hasManagedSave {
      options.append(
        BigPictureGameOption(
          action: .manageSaves,
          title: "Manage Saves",
          systemImage: "externaldrive.fill"
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

  private var systemGameSort: BigPictureSystemGameSort {
    BigPictureSystemGameSort(rawValue: systemGameSortRawValue)
      ?? .defaultSort
  }

  private var isSortableGameList: Bool {
    guard case .games(let scope) = page else {
      return false
    }
    switch scope {
    case .all, .system:
      return true
    default:
      return false
    }
  }

  private func sortedGames(in scope: BigPictureScope) -> [GameSummary] {
    let games = catalog.games(in: scope)
    switch scope {
    case .all, .system:
      break
    default:
      return games
    }
    return systemGameSort.sorted(
      games,
      downloadedGameIDs: model.downloadedGameIDs,
      favoriteGameIDs: catalog.favoriteGameIDs
    )
  }

  private func cycleSystemGameSort() {
    guard case .games(let scope) = page, isSortableGameList else {
      return
    }

    let selectedGameID = selectedGame?.id
    systemGameSortRawValue = systemGameSort.next.rawValue
    prepareSortedRows(
      for: scope,
      preservingGameID: selectedGameID,
      fallbackIndex: selectedIndex
    )
  }

  /// Prepares a potentially large game list away from the main actor, then
  /// replaces the visible rows in one pass. The existing rows stay interactive
  /// while sorting, so cycling a sort never blanks or incrementally rebuilds
  /// the menu.
  private func prepareSortedRows(
    for scope: BigPictureScope,
    preservingGameID selectedGameID: Int?,
    fallbackIndex: Int
  ) {
    let games = catalog.games(in: scope)
    let downloadedGameIDs = model.downloadedGameIDs
    let favoriteGameIDs = catalog.favoriteGameIDs
    let sort = systemGameSort

    sortTask?.cancel()
    sortGeneration += 1
    let generation = sortGeneration

    sortTask = Task {
      let preparedRows = await Task.detached(priority: .userInitiated) {
        let sortedGames = sort.sorted(
          games,
          downloadedGameIDs: downloadedGameIDs,
          favoriteGameIDs: favoriteGameIDs
        )
        return Self.gameRows(
          for: sortedGames,
          downloadedGameIDs: downloadedGameIDs,
          favoriteGameIDs: favoriteGameIDs,
          showsSystemName:
            scope == .favorites || scope == .recentlyPlayed
        )
      }.value

      guard
        !Task.isCancelled,
        generation == sortGeneration,
        page == .games(scope),
        systemGameSort == sort
      else {
        return
      }

      rows = preparedRows
      if
        let selectedGameID,
        let index = preparedRows.firstIndex(where: {
          $0.id == .game(selectedGameID)
        })
      {
        selectedIndex = index
      } else {
        selectedIndex = min(fallbackIndex, max(preparedRows.count - 1, 0))
      }
      scrollTargetID = preparedRows.indices.contains(selectedIndex)
        ? preparedRows[selectedIndex].id
        : nil
    }
  }

  nonisolated private static func gameRows(
    for games: [GameSummary],
    downloadedGameIDs: Set<Int>,
    favoriteGameIDs: Set<Int>,
    showsSystemName: Bool
  ) -> [BigPictureRow] {
    games.map { game in
      BigPictureRow(
        id: .game(game.id),
        title: game.name,
        detail: BigPictureGameRowPresentation.detail(
          releaseYear: game.releaseYear,
          isDownloaded: downloadedGameIDs.contains(game.id),
          systemName: showsSystemName ? game.systemName : nil
        ),
        isFavorite: favoriteGameIDs.contains(game.id),
        action: .play(game)
      )
    }
  }

  private var pageTitle: String {
    switch page {
    case .home:
      "RetroVault"
    case .ignoredSystems:
      "Ignored Systems"
    case .settings:
      "Settings"
    case .collections:
      "Collections"
    case .saveCenter:
      "Save Center"
    case .downloaded:
      BigPictureHomeLibrarySection.downloadedGames.title
    case .games(let scope):
      catalog.title(for: scope)
    }
  }

  private var pageSubtitle: String {
    switch page {
    case .home:
      "BIG PICTURE"
    case .ignoredSystems:
      "\(ignoredSystemIDs.count.formatted()) SYSTEMS"
    case .settings:
      "RETROVAULT PREFERENCES"
    case .collections:
      "\(catalog.collections.count.formatted()) ROMM COLLECTIONS"
    case .saveCenter:
      "\(model.saveCenterItems.count.formatted()) SAVED GAMES"
    case .downloaded:
      "\(catalog.downloadedSystems.count.formatted()) SYSTEMS"
    case .games(let scope):
      switch scope {
      case .all, .system:
        "\(catalog.games(in: scope).count.formatted()) GAMES · "
          + systemGameSort.title.uppercased()
      default:
        "\(catalog.games(in: scope).count.formatted()) GAMES"
      }
    }
  }

  private var rowFontSize: CGFloat {
    switch page {
    case .home:
      31
    case .collections, .saveCenter, .downloaded, .ignoredSystems,
      .settings, .games:
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
    sortTask?.cancel()
    sortGeneration += 1
    let selectedRowID =
      rows.indices.contains(selectedIndex)
      ? rows[selectedIndex].id
      : nil
    queuedSystemIDs.formIntersection(
      Set(preparedCatalog.systems.map(\.id))
    )
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
      guard actionProgress?.isBackgrounded != false, !isPreparingPlayback else {
        return
      }
      actionNotice = nil
      optionsGame = nil
      optionsSystem = nil
      playbackErrorMessage = nil
      isShowingSyncStatus.toggle()
      return
    }

    if let progress = actionProgress, !progress.isBackgrounded {
      if command == .activate, progress.allowsBackgrounding {
        var backgroundedProgress = progress
        backgroundedProgress.isBackgrounded = true
        actionProgress = backgroundedProgress
      } else if command == .back, progress.allowsCancellation {
        bulkDownloadTask?.cancel()
      }
      return
    }

    if isShowingSyncStatus {
      switch command {
      case .activate:
        synchronizeNow()
      case .openGameOptions:
        isShowingSyncStatus = false
        navigate(to: .settings)
      case .playFromBeginning, .back:
        isShowingSyncStatus = false
      case .up, .down, .pageUp, .pageDown, .cycleSort, .showSyncStatus,
        .exit:
        break
      }
      return
    }

    if let settingsConfirmation {
      switch command {
      case .activate, .playFromBeginning:
        confirm(settingsConfirmation)
      case .back, .openGameOptions:
        self.settingsConfirmation = nil
      case .up, .down, .pageUp, .pageDown, .cycleSort, .showSyncStatus,
        .exit:
        break
      }
      return
    }

    if actionNotice != nil {
      switch command {
      case .activate, .playFromBeginning, .back, .openGameOptions:
        actionNotice = nil
      case .up, .down, .pageUp, .pageDown, .cycleSort, .showSyncStatus,
        .exit:
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
      case .pageUp, .pageDown, .cycleSort, .showSyncStatus, .exit:
        break
      }
      return
    }

    if let optionsSystem {
      switch command {
      case .up:
        moveSystemOptionSelection(by: -1, for: optionsSystem)
      case .down:
        moveSystemOptionSelection(by: 1, for: optionsSystem)
      case .activate, .playFromBeginning:
        activateSelectedSystemOption(for: optionsSystem)
      case .back, .openGameOptions:
        self.optionsSystem = nil
      case .pageUp, .pageDown, .cycleSort, .showSyncStatus, .exit:
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
        .openGameOptions, .cycleSort, .showSyncStatus, .exit:
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
      switch BigPictureGameLaunchPresentation.secondaryAction(
        isSaveCenter: selectedSaveCenterItem != nil
      ) {
      case .play:
        guard let selectedSaveCenterItem else {
          return
        }
        play(selectedSaveCenterItem.game)
      case .options:
        presentSelectedOptions()
      }
    case .openGameOptions:
      presentSelectedOptions()
    case .cycleSort:
      cycleSystemGameSort()
    case .showSyncStatus:
      break
    case .back:
      navigateBack()
    case .exit:
      break
    }
  }

  private func synchronizeNow() {
    guard !model.isSynchronizing else {
      return
    }

    Task {
      await model.refresh()
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
      navigate(to: destination)
    case .play(let game):
      play(game)
    case .synchronizeSave(let gameID):
      synchronizeSave(gameID: gameID)
    case .downloadSystemQueue:
      downloadQueuedSystems()
    case .setting(let setting):
      perform(setting)
    }
  }

  private func navigate(
    to destination: BigPicturePage,
    selecting selectedRowID: BigPictureRow.ID? = nil
  ) {
    history.append(
      BigPictureHistoryEntry(page: page, selectedIndex: selectedIndex)
    )
    page = destination
    rows = makeRows(for: destination, catalog: catalog)
    selectInitialRow(selectedRowID)

    guard destination == .saveCenter else {
      return
    }
    Task {
      await model.reloadSaveCenter()
      guard page == .saveCenter else {
        return
      }
      rows = makeRows(for: page, catalog: catalog)
      selectInitialRow(selectedRowID)
    }
  }

  private func selectInitialRow(_ selectedRowID: BigPictureRow.ID?) {
    if
      let selectedRowID,
      let index = rows.firstIndex(where: { $0.id == selectedRowID })
    {
      selectedIndex = index
    } else {
      selectedIndex = 0
    }
    scrollTargetID = rows.indices.contains(selectedIndex)
      ? rows[selectedIndex].id
      : nil
  }

  private func synchronizeSave(gameID: Int) {
    Task {
      let result = await model.synchronizeSave(gameID: gameID)
      rows = makeRows(for: page, catalog: catalog)
      switch result {
      case .synchronized:
        actionNotice = BigPictureActionNotice(
          title: "Save Uploaded",
          message: "The latest local save is now stored in RomM.",
          systemImage: "checkmark.icloud.fill"
        )
      case .unchanged:
        actionNotice = BigPictureActionNotice(
          title: "Save Synchronized",
          message: "The local save and RomM are already reconciled.",
          systemImage: "checkmark.circle.fill"
        )
      case .failed(let message):
        actionNotice = BigPictureActionNotice(
          title: "Save Sync Failed",
          message: message,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func saveCenterItem(for row: BigPictureRow) -> SaveCenterItem? {
    guard case .save(let gameID) = row.id else {
      return nil
    }
    return model.saveCenterItems.first { $0.id == gameID }
  }

  private func saveCenterStatusColor(_ status: SaveCenterStatus) -> Color {
    switch status {
    case .synchronized:
      .green
    case .uploadPending:
      .yellow
    case .remoteOnly:
      .cyan
    case .failed:
      .red
    }
  }

  private func saveSynchronizationOverlay(gameID: Int) -> some View {
    VStack(spacing: 20) {
      ProgressView()
        .controlSize(.large)
        .tint(.white)

      Text("SYNCHRONIZING SAVE")
        .font(.system(size: 22, weight: .black, design: .rounded))

      if let game = model.saveCenterItems.first(where: { $0.id == gameID })?.game {
        Text(game.name)
          .font(.system(size: 16, weight: .bold, design: .rounded))
          .foregroundStyle(.white.opacity(0.58))
          .lineLimit(1)
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

  private func presentSelectedOptions() {
    if let selectedGame {
      let options = gameOptions(for: selectedGame)
      optionsGame = selectedGame
      selectedGameOptionIndex =
        options.firstIndex(where: \.isEnabled) ?? 0
    } else if let selectedSystem {
      optionsSystem = selectedSystem
      let options = systemOptions(for: selectedSystem)
      selectedSystemOptionIndex =
        options.firstIndex(where: \.isEnabled) ?? 0
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

  private func moveSystemOptionSelection(
    by offset: Int,
    for system: LibrarySystem
  ) {
    let options = systemOptions(for: system)
    guard !options.isEmpty, offset != 0 else {
      return
    }

    var index = selectedSystemOptionIndex
    while true {
      let candidate = index + (offset > 0 ? 1 : -1)
      guard options.indices.contains(candidate) else {
        return
      }
      index = candidate
      if options[index].isEnabled {
        selectedSystemOptionIndex = index
        return
      }
    }
  }

  private func activateSelectedSystemOption(
    for system: LibrarySystem
  ) {
    let options = systemOptions(for: system)
    guard options.indices.contains(selectedSystemOptionIndex) else {
      return
    }
    let option = options[selectedSystemOptionIndex]
    guard option.isEnabled else {
      return
    }
    perform(option.action, for: system)
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
    case .manageSaves:
      navigate(to: .saveCenter, selecting: .save(game.id))
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
    let progressID = beginActionProgress("Updating Favorites")
    Task {
      defer {
        endActionProgress(progressID)
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
    let progressID = beginActionProgress(
      "Downloading Game",
      allowsBackgrounding: true
    )
    Task {
      defer {
        endActionProgress(progressID)
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
    let progressID = beginActionProgress(
      "Downloading \(systemGames.count.formatted()) "
        + (systemGames.count == 1 ? "Game" : "Games"),
      allowsBackgrounding: true,
      allowsCancellation: true
    )
    bulkDownloadTask = Task {
      defer {
        endActionProgress(progressID)
        bulkDownloadTask = nil
      }
      let result = await model.downloadGames(systemGames)
      guard !Task.isCancelled else {
        return
      }
      if result.completedWithoutErrors {
        actionNotice = BigPictureActionNotice(
          title: "System Downloaded",
          message:
            "Added \(result.successfulItemCount.formatted()) "
            + (result.successfulItemCount == 1 ? "game" : "games")
            + " from \(system.name) to RetroVault’s local library.",
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
                ?? "RetroVault couldn’t complete this action."
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

  private func perform(
    _ action: BigPictureSystemOption.Action,
    for system: LibrarySystem
  ) {
    switch action {
    case .setQueued(let isQueued):
      if isQueued {
        queuedSystemIDs.insert(system.id)
      } else {
        queuedSystemIDs.remove(system.id)
      }
      optionsSystem = nil
      rebuildHomeRowsPreservingSelection()
    case .performDownload(let downloadAction):
      queuedSystemIDs.remove(system.id)
      rebuildHomeRowsPreservingSelection()
      performSystemDownloadAction(downloadAction, for: system)
    case .setIgnored(let isIgnored):
      setSystem(system, isIgnored: isIgnored)
    }
  }

  private func perform(_ setting: BigPictureSetting) {
    switch setting {
    case .romMServer:
      actionNotice = BigPictureActionNotice(
        title: "RomM Server",
        message: model.session.serverURL.value.absoluteString,
        systemImage: "server.rack"
      )
    case .romMUser:
      actionNotice = BigPictureActionNotice(
        title: "RomM User",
        message: model.session.username,
        systemImage: "person.crop.circle"
      )
    case .runtime:
      actionNotice = BigPictureActionNotice(
        title: "Emulation Runtime",
        message: "RetroVault uses its bundled Libretro runtime and reviewed cores.",
        systemImage: "cpu"
      )
    case .resynchronizeLibrary:
      guard !model.isSynchronizing else {
        return
      }
      Task {
        await model.refresh(strategy: .fullReconciliation)
        refreshSettingsRowsPreservingSelection()
      }
    case .purgeAndResynchronize, .disconnect:
      settingsConfirmation = setting
    case .videoFilter:
      videoFilter = next(videoFilter, in: LibretroVideoFilter.allCases)
      refreshSettingsRowsPreservingSelection()
    case .internalResolution:
      internalResolution = next(
        internalResolution,
        in: LibretroInternalResolution.allCases
      )
      refreshSettingsRowsPreservingSelection()
    case .wiiController:
      wiiControllerProfile = next(
        wiiControllerProfile,
        in: LibretroWiiControllerProfile.allCases
      )
      refreshSettingsRowsPreservingSelection()
    case .mapsLeftAnalogToDPad:
      mapsLeftAnalogToDPad.toggle()
      refreshSettingsRowsPreservingSelection()
    case .fastForward:
      enablesR3FastForward.toggle()
      refreshSettingsRowsPreservingSelection()
    case .rewind:
      enablesL3Rewind.toggle()
      refreshSettingsRowsPreservingSelection()
    case .gamesFullScreen:
      opensGamesInFullScreen.toggle()
      refreshSettingsRowsPreservingSelection()
    case .experimentalCores:
      enablesExperimentalCores.toggle()
      refreshSettingsRowsPreservingSelection()
    case .dsuEnabled:
      usesDSUController.toggle()
      applyDSUConfiguration()
      refreshSettingsRowsPreservingSelection()
    case .dsuEndpoint:
      actionNotice = BigPictureActionNotice(
        title: "DSU Server",
        message: "\(dsuHost):\(dsuPort)",
        systemImage: "network"
      )
    case .dsuStatus:
      actionNotice = BigPictureActionNotice(
        title: "DSU Status",
        message: DSUConnection.shared.status.summary,
        systemImage: "gamecontroller"
      )
    case .dsuLayout:
      let layout = ControllerFaceButtonLayout(rawValue: dsuLayout)
        ?? DSUPreferences.defaultLayout
      let nextLayout: ControllerFaceButtonLayout =
        layout == .standard ? .nintendo : .standard
      dsuLayout = nextLayout.rawValue
      DSUConnection.shared.apply(layout: nextLayout)
      refreshSettingsRowsPreservingSelection()
    case .bigPictureFullScreen:
      opensInFullScreen.toggle()
      refreshSettingsRowsPreservingSelection()
    case .openLogs:
      openWindow(id: "diagnostics")
    }
  }

  private func confirm(_ setting: BigPictureSetting) {
    settingsConfirmation = nil
    switch setting {
    case .purgeAndResynchronize:
      guard !model.isSynchronizing else {
        return
      }
      let progressID = beginActionProgress(
        "Purging Local Cache & Resynchronizing",
        allowsBackgrounding: true
      )
      Task {
        await model.purgeLocalCacheAndResync()
        endActionProgress(progressID)
        refreshSettingsRowsPreservingSelection()
      }
    case .disconnect:
      onDisconnectRequested()
    default:
      break
    }
  }

  private func applyDSUConfiguration() {
    guard usesDSUController else {
      DSUConnection.shared.apply(nil)
      return
    }
    DSUConnection.shared.apply(
      DSUConfiguration(
        host: dsuHost,
        port: UInt16(clamping: dsuPort)
      ).normalized
    )
  }

  private func refreshSettingsRowsPreservingSelection() {
    guard page == .settings else {
      return
    }
    let selectedRowID = rows.indices.contains(selectedIndex)
      ? rows[selectedIndex].id
      : nil
    rows = makeRows(for: page, catalog: catalog)
    if
      let selectedRowID,
      let index = rows.firstIndex(where: { $0.id == selectedRowID })
    {
      selectedIndex = index
      scrollTargetID = selectedRowID
    }
  }

  private func next<Value: Equatable>(
    _ value: Value,
    in values: [Value]
  ) -> Value {
    guard
      !values.isEmpty,
      let index = values.firstIndex(of: value)
    else {
      return values.first ?? value
    }
    return values[(index + 1) % values.count]
  }

  private func setSystem(
    _ system: LibrarySystem,
    isIgnored: Bool
  ) {
    var systemIDs = ignoredSystemIDs
    if isIgnored {
      systemIDs.insert(system.id)
      queuedSystemIDs.remove(system.id)
    } else {
      systemIDs.remove(system.id)
    }
    ignoredSystemIDsRawValue = BigPictureIgnoredSystems.encode(systemIDs)
    optionsSystem = nil

    if page == .ignoredSystems {
      if systemIDs.isEmpty {
        navigateBack()
      } else {
        rows = makeRows(for: page, catalog: catalog)
        selectedIndex = min(selectedIndex, max(rows.count - 1, 0))
        scrollTargetID = rows.indices.contains(selectedIndex)
          ? rows[selectedIndex].id
          : nil
      }
    } else {
      rebuildHomeRowsPreservingSelection()
    }
  }

  private func downloadQueuedSystems() {
    let systems = queuedSystems
    let games = queuedRemainingGames
    guard
      !systems.isEmpty,
      !games.isEmpty,
      !model.isDownloadingGames,
      !model.isRemovingDownloads
    else {
      return
    }

    queuedSystemIDs.removeAll()
    rebuildHomeRowsPreservingSelection()
    let systemCount = systems.count
    let gameCount = games.count
    let progressID = beginActionProgress(
      "Downloading \(gameCount.formatted()) "
        + (gameCount == 1 ? "Game" : "Games")
        + " from \(systemCount.formatted()) "
        + (systemCount == 1 ? "System" : "Systems"),
      allowsBackgrounding: true,
      allowsCancellation: true
    )
    bulkDownloadTask = Task {
      defer {
        endActionProgress(progressID)
        bulkDownloadTask = nil
      }
      let result = await model.downloadGames(games)
      guard !Task.isCancelled else {
        return
      }
      if result.completedWithoutErrors {
        actionNotice = BigPictureActionNotice(
          title: "Systems Downloaded",
          message:
            "Added \(result.successfulItemCount.formatted()) "
            + (result.successfulItemCount == 1 ? "game" : "games")
            + " from \(systemCount.formatted()) "
            + (systemCount == 1 ? "system" : "systems")
            + " to RetroVault’s local library.",
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
                ?? "RetroVault couldn’t complete this action."
            ),
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }

  private func rebuildHomeRowsPreservingSelection() {
    guard page == .home else {
      return
    }
    let selectedRowID = rows.indices.contains(selectedIndex)
      ? rows[selectedIndex].id
      : nil
    rows = makeRows(for: page, catalog: catalog)
    if
      let selectedRowID,
      let preservedIndex = rows.firstIndex(where: { $0.id == selectedRowID })
    {
      selectedIndex = preservedIndex
      scrollTargetID = selectedRowID
    } else {
      selectedIndex = min(selectedIndex, max(rows.count - 1, 0))
      scrollTargetID = rows.indices.contains(selectedIndex)
        ? rows[selectedIndex].id
        : nil
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
    let progressID = beginActionProgress(
      "Removing \(downloadedGames.count.formatted()) "
      + (downloadedGames.count == 1 ? "Download" : "Downloads")
    )
    Task {
      defer {
        endActionProgress(progressID)
      }
      let result = await model.removeDownloads(downloadedGames)
      if result.completedWithoutErrors {
        actionNotice = BigPictureActionNotice(
          title: "System Downloads Removed",
          message:
            "Removed \(result.successfulItemCount.formatted()) "
            + (result.successfulItemCount == 1 ? "game" : "games")
            + " from RetroVault’s local library.",
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
    let progressID = beginActionProgress("Removing Download")
    Task {
      defer {
        endActionProgress(progressID)
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
    let progressID = beginActionProgress("Exporting Game")
    Task {
      defer {
        endActionProgress(progressID)
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

  private func beginActionProgress(
    _ title: String,
    allowsBackgrounding: Bool = false,
    allowsCancellation: Bool = false
  ) -> UUID {
    let id = UUID()
    actionProgress = BigPictureActionProgress(
      id: id,
      title: title,
      allowsBackgrounding: allowsBackgrounding,
      allowsCancellation: allowsCancellation
    )
    return id
  }

  private func endActionProgress(_ id: UUID) {
    guard actionProgress?.id == id else {
      return
    }
    actionProgress = nil
  }

  private func operationFailureNotice(
    title: String,
    errors: [String]
  ) -> BigPictureActionNotice {
    BigPictureActionNotice(
      title: title,
      message:
        errors.first
        ?? "RetroVault couldn’t complete this action.",
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
      actionProgress?.isBackgrounded != false,
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
          ?? "RetroVault could not load this game’s RomM metadata."
        finishPlaybackPreparation(keepingError: true)
        return
      }
      if Vita3KInstallation.supports(
        systemName: details.systemName,
        includingExperimental: enablesExperimentalCores
      ) {
        guard
          let request = await detailsModel.prepareForVita3K(
            details,
            synchronizesWithServer: model.isServerReachable
          )
        else {
          guard !Task.isCancelled else {
            finishPlaybackPreparation()
            return
          }
          playbackErrorMessage =
            detailsModel.playbackErrorMessage
            ?? "RetroVault could not prepare this Vita archive."
          finishPlaybackPreparation(keepingError: true)
          return
        }

        model.recordManagedDownload(gameID: game.id)
        await model.reloadDownloadedGames(reconcilingDuringDownloads: true)
        await model.recordPlay(gameID: game.id)
        activeVita3KRequest = request
        finishPlaybackPreparation()
        return
      }

      if CemuInstallation.supports(systemName: details.systemName) {
        guard
          let request = await detailsModel.prepareForCemu(
            details,
            synchronizesWithServer: model.isServerReachable
          )
        else {
          guard !Task.isCancelled else {
            finishPlaybackPreparation()
            return
          }
          playbackErrorMessage =
            detailsModel.playbackErrorMessage
            ?? "RetroVault could not prepare this Wii U game for Cemu."
          finishPlaybackPreparation(keepingError: true)
          return
        }

        model.recordManagedDownload(gameID: game.id)
        await model.reloadDownloadedGames(reconcilingDuringDownloads: true)
        await model.recordPlay(gameID: game.id)
        activeCemuRequest = request
        finishPlaybackPreparation()
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
              : "RetroVault could not prepare this game."
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
    guard activePlayerRequest != nil || activeVita3KRequest != nil
      || activeCemuRequest != nil
    else {
      return
    }
    activePlayerRequest = nil
    activeVita3KRequest = nil
    activeCemuRequest = nil
    controllerNavigation.synchronize(with: .current)

    Task { @MainActor in
      await model.reloadLocalQuickStates()
      await model.reloadSaveCenter()
      if page == .home || page == .saveCenter {
        rows = makeRows(for: page, catalog: catalog)
      }
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
        activeVita3KRequest == nil,
        activeCemuRequest == nil,
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

  private var cemuDSUConfiguration: CemuDSUConfiguration? {
    guard usesDSUController else { return nil }
    return CemuDSUConfiguration(
      host: dsuHost,
      port: UInt16(clamping: dsuPort),
      playerCount: Int(DSUProtocol.slotCount)
    )
  }

  private var cemuLaunchPresentation: CemuLaunchPresentation {
    .matching(
      hostWindowIsFullScreen:
        bigPictureWindow?.styleMask.contains(.fullScreen) == true
    )
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

private enum BigPicturePage: Hashable, Sendable {
  case home
  case ignoredSystems
  case settings
  case collections
  case saveCenter
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
  case cycleSort
  case showSyncStatus
  case back
  case exit
}

enum BigPictureIgnoredSystems {
  static func decode(_ rawValue: String) -> Set<Int> {
    Set(
      rawValue.split(separator: ",").compactMap {
        Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    )
  }

  static func encode(_ systemIDs: Set<Int>) -> String {
    systemIDs.sorted().map(String.init).joined(separator: ",")
  }
}

private enum BigPictureSetting: Hashable, Sendable {
  case romMServer
  case romMUser
  case resynchronizeLibrary
  case purgeAndResynchronize
  case runtime
  case videoFilter
  case internalResolution
  case wiiController
  case mapsLeftAnalogToDPad
  case fastForward
  case rewind
  case gamesFullScreen
  case experimentalCores
  case dsuEnabled
  case dsuEndpoint
  case dsuLayout
  case dsuStatus
  case bigPictureFullScreen
  case openLogs
  case disconnect
}

private struct BigPictureSettingsConfirmationPresentation {
  let title: String
  let message: String
  let systemImage: String

  static func make(for setting: BigPictureSetting) -> Self {
    switch setting {
    case .purgeAndResynchronize:
      Self(
        title: "Purge Local Cache?",
        message:
          "RetroVault will remove cached library metadata, game details, "
          + "and artwork, then rebuild them from RomM. Managed ROMs, saves, "
          + "and playback history are preserved.",
        systemImage: "trash"
      )
    case .disconnect:
      Self(
        title: "Disconnect from RomM?",
        message:
          "RetroVault will remove this server connection and its cached "
          + "metadata. Managed ROMs and saves remain on this Mac.",
        systemImage: "network.slash"
      )
    default:
      Self(
        title: "Confirm Action",
        message: "Apply this setting?",
        systemImage: "questionmark.circle"
      )
    }
  }
}

enum BigPictureSystemGameSort: String, CaseIterable, Sendable {
  case favoritesFirst
  case alphabetical
  case localFirst
  case releaseYear
  case recentlyPlayed
  case recentlyAdded

  static let defaultSort = Self.favoritesFirst

  var title: String {
    switch self {
    case .favoritesFirst:
      "Favorites First"
    case .alphabetical:
      "Alphabetical"
    case .localFirst:
      "Local First"
    case .releaseYear:
      "Release Year"
    case .recentlyPlayed:
      "Recently Played"
    case .recentlyAdded:
      "Recently Added"
    }
  }

  var next: Self {
    let sorts = Self.allCases
    guard let index = sorts.firstIndex(of: self) else {
      return Self.defaultSort
    }
    return sorts[(index + 1) % sorts.count]
  }

  func sorted(
    _ games: [GameSummary],
    downloadedGameIDs: Set<Int>,
    favoriteGameIDs: Set<Int>
  ) -> [GameSummary] {
    games.sorted { lhs, rhs in
      switch self {
      case .favoritesFirst:
        let leftIsFavorite = favoriteGameIDs.contains(lhs.id)
        let rightIsFavorite = favoriteGameIDs.contains(rhs.id)
        if leftIsFavorite != rightIsFavorite {
          return leftIsFavorite
        }
      case .alphabetical:
        break
      case .localFirst:
        let leftIsLocal = downloadedGameIDs.contains(lhs.id)
        let rightIsLocal = downloadedGameIDs.contains(rhs.id)
        if leftIsLocal != rightIsLocal {
          return leftIsLocal
        }
      case .releaseYear:
        if lhs.releaseYear != rhs.releaseYear {
          return (lhs.releaseYear ?? Int.min) > (rhs.releaseYear ?? Int.min)
        }
      case .recentlyPlayed:
        if lhs.lastPlayedAt != rhs.lastPlayedAt {
          return (lhs.lastPlayedAt ?? .distantPast)
            > (rhs.lastPlayedAt ?? .distantPast)
        }
      case .recentlyAdded:
        if lhs.createdAt != rhs.createdAt {
          return (lhs.createdAt ?? "") > (rhs.createdAt ?? "")
        }
      }
      return Self.isAlphabeticallyOrdered(lhs, rhs)
    }
  }

  private static func isAlphabeticallyOrdered(
    _ lhs: GameSummary,
    _ rhs: GameSummary
  ) -> Bool {
    let comparison = lhs.name.localizedStandardCompare(rhs.name)
    return comparison == .orderedSame
      ? lhs.id < rhs.id
      : comparison == .orderedAscending
  }
}

enum BigPictureGameRowPresentation {
  static func detail(
    releaseYear: Int?,
    isDownloaded: Bool,
    systemName: String? = nil
  ) -> String? {
    let components = [
      isDownloaded ? "LOCAL" : nil,
      systemName,
      releaseYear.map(String.init),
    ]
    .compactMap { $0 }
    return components.isEmpty ? nil : components.joined(separator: " · ")
  }
}

enum BigPictureGameLaunchPresentation {
  enum SecondaryAction: Equatable {
    case options
    case play
  }

  static func primaryActionTitle(hasSaveState: Bool) -> String {
    hasSaveState ? "Resume" : "Play"
  }

  static func showsPlayFromBeginning(hasSaveState: Bool) -> Bool {
    hasSaveState
  }

  static func secondaryAction(isSaveCenter: Bool) -> SecondaryAction {
    isSaveCenter ? .play : .options
  }

  static func secondaryActionTitle(isSaveCenter: Bool) -> String {
    switch secondaryAction(isSaveCenter: isSaveCenter) {
    case .options:
      "Options"
    case .play:
      "Play"
    }
  }
}

enum BigPictureSaveCenterPresentation {
  enum PrimaryAction: Equatable {
    case play
    case synchronize
  }

  static func primaryAction(
    for status: SaveCenterStatus
  ) -> PrimaryAction {
    status == .synchronized ? .play : .synchronize
  }

  static func primaryActionTitle(
    for status: SaveCenterStatus
  ) -> String {
    switch primaryAction(for: status) {
    case .play:
      "Play"
    case .synchronize:
      "Sync"
    }
  }
}

enum BigPictureSystemDownloadAction: Equatable, Hashable, Sendable {
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

private struct BigPictureRow: Identifiable, Sendable {
  enum ID: Hashable, Sendable {
    case home(String)
    case system(Int)
    case collection(LibraryCollection.ID)
    case save(Int)
    case game(Int)
    case setting(BigPictureSetting)
  }

  enum Action: Sendable {
    case navigate(BigPicturePage)
    case play(GameSummary)
    case synchronizeSave(Int)
    case downloadSystemQueue
    case setting(BigPictureSetting)
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
    case manageSaves
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

enum BigPictureGameSavePresentation {
  static func isAvailable(
    gameHasRemoteSave: Bool,
    hasLocalSave: Bool
  ) -> Bool {
    gameHasRemoteSave || hasLocalSave
  }
}

private struct BigPictureSystemOption: Identifiable {
  enum Action: Hashable {
    case setQueued(Bool)
    case performDownload(BigPictureSystemDownloadAction)
    case setIgnored(Bool)
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

private struct BigPictureActionProgress {
  let id: UUID
  let title: String
  let allowsBackgrounding: Bool
  let allowsCancellation: Bool
  var isBackgrounded = false
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
  var cyclesSort = false
  var showsSyncStatus = false
  var back = false
  var opensBigPicture = false
  var pageUp = false
  var pageDown = false
  var activateButtonPrompt = BigPictureControllerPrompt(label: "B")
  var backButtonPrompt = BigPictureControllerPrompt(label: "A")
  var optionsButtonPrompt = BigPictureControllerPrompt(label: "START")
  var playFromBeginningButtonPrompt = BigPictureControllerPrompt(label: "X")
  var sortButtonPrompt = BigPictureControllerPrompt(label: "Y")
  var syncStatusButtonPrompt = BigPictureControllerPrompt(label: "SELECT")

  static var current: Self {
    let controllers = GCController.controllers()
    let routedPads = DSUConnection.shared.currentPads()
    var state = Self(isConnected: !routedPads.isEmpty)
    var hasLocalPrompts = false

    if
      routedPads.first?.source == .gameController,
      let controller = GCController.current ?? controllers.first,
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
        localizedName: gamepad.buttonX.localizedName,
        systemImage: gamepad.buttonX.sfSymbolsName,
        fallbackLabel: "X"
      )
      state.playFromBeginningButtonPrompt = buttonPrompt(
        localizedName: gamepad.buttonX.localizedName,
        systemImage: gamepad.buttonX.sfSymbolsName,
        fallbackLabel: "X"
      )
      state.sortButtonPrompt = buttonPrompt(
        localizedName: gamepad.buttonY.localizedName,
        systemImage: gamepad.buttonY.sfSymbolsName,
        fallbackLabel: "Y"
      )
      state.syncStatusButtonPrompt = buttonPrompt(
        localizedName: gamepad.buttonOptions?.localizedName,
        systemImage: gamepad.buttonOptions?.sfSymbolsName,
        fallbackLabel: "SELECT"
      )
    }

    if let firstPad = routedPads.first {
      // A network pad names the on-screen prompts only when no local
      // controller is there to provide localized button symbols.
      if !hasLocalPrompts {
        state.applyPrompts(for: firstPad.layout)
      }
    }
    for pad in routedPads {
      state.merge(pad.state, layout: pad.layout)
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
    optionsButtonPrompt = BigPictureControllerPrompt(label: "X")
    playFromBeginningButtonPrompt = BigPictureControllerPrompt(label: "X")
    sortButtonPrompt = BigPictureControllerPrompt(label: "Y")
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
    cyclesSort = cyclesSort || pad.buttons.contains(.y)
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
    if state.cyclesSort, !previousState.cyclesSort {
      return .cycleSort
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
    let remainder = (index + offset) % itemCount
    return remainder >= 0 ? remainder : remainder + itemCount
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

@preconcurrency import AppKit
import Observation
import SwiftUI

struct CemuGameView: View {
  let request: CemuRunRequest
  let service: any LibraryServing
  let dsuConfiguration: CemuDSUConfiguration?
  let launchPresentation: CemuLaunchPresentation
  let onCloseRequested: @MainActor @Sendable () -> Void

  @State private var coordinator = CemuPlayerCoordinator()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      switch coordinator.status {
      case .ready:
        EmptyView()
      case .starting(let message):
        VStack(spacing: 18) {
          ProgressView().controlSize(.large)
          Text(message.uppercased())
            .font(.title2.weight(.black))
        }
      case .running:
        VStack(spacing: 14) {
          Image(systemName: "display")
            .font(.system(size: 48))
          Text("CEMU IS RUNNING")
            .font(.title2.weight(.black))
          Text("RetroVault will return when the Wii U session ends.")
            .foregroundStyle(.secondary)
        }
      case .synchronizing:
        VStack(spacing: 18) {
          ProgressView().controlSize(.large)
          Text("SYNCHRONIZING WII U SAVE…")
            .font(.title2.weight(.black))
        }
      case .failed(let message):
        VStack(spacing: 18) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 52))
          Text("COULDN’T START CEMU")
            .font(.title.weight(.black))
          Text(message)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 620)
          Button("Back", action: onCloseRequested)
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    .task(id: request) {
      await coordinator.start(
        request: request,
        service: service,
        dsuConfiguration: dsuConfiguration,
        launchPresentation: launchPresentation,
        onFinished: onCloseRequested
      )
    }
    .onDisappear { coordinator.stop() }
  }
}

@MainActor
@Observable
private final class CemuPlayerCoordinator {
  enum Status: Equatable {
    case ready
    case starting(String)
    case running
    case synchronizing
    case failed(String)
  }

  var status = Status.ready

  private var runningApplication: NSRunningApplication?
  private var runningProcess: Process?
  private var launcherLogHandle: FileHandle?
  private var controllerRelay: CemuDSURelay?
  private var monitorTask: Task<Void, Never>?
  private var expectsEscapeToLeaveFullScreen = false
  private var didHideHostApplication = false
  private var isFinishing = false

  func start(
    request: CemuRunRequest,
    service: any LibraryServing,
    dsuConfiguration: CemuDSUConfiguration?,
    launchPresentation: CemuLaunchPresentation,
    onFinished: @escaping @MainActor @Sendable () -> Void
  ) async {
    guard runningProcess == nil, runningApplication == nil else {
      return
    }
    guard
      let installation = CemuInstallation.available(
        forGameTitle: request.title,
        rendererPreference: request.rendererPreference
      )
    else {
      status = .failed(CemuError.unavailable.localizedDescription)
      return
    }

    if request.rendererPreference != .automatic {
      RetroVaultLog.cemu.notice(
        "Using the per-game \(request.rendererPreference.title, privacy: .public) renderer override for \(request.title, privacy: .public)"
      )
    } else if CemuCompatibilityOverrides.requiresVulkan(
      forGameTitle: request.title
    ) {
      if installation.rendererName == "Vulkan" {
        RetroVaultLog.cemu.notice(
          "Using the stable Vulkan compatibility fallback for \(request.title, privacy: .public)"
        )
      } else {
        RetroVaultLog.cemu.error(
          "The Vulkan compatibility fallback for \(request.title, privacy: .public) is not bundled; continuing with Metal"
        )
      }
    }

    status = .starting("Preparing Cemu…")
    do {
      let relay = CemuDSURelay()
      let relayPort: UInt16?
      do {
        relayPort = try await Task.detached(priority: .userInitiated) {
          try relay.start()
        }.value
        controllerRelay = relay
      } catch {
        relay.stop()
        relayPort = nil
        RetroVaultLog.cemu.error(
          "Could not start the controller relay; falling back to direct DSU input: \(error.localizedDescription, privacy: .public)"
        )
      }
      let effectiveDSUConfiguration = relayPort.map {
        CemuDSUConfiguration(
          host: "127.0.0.1",
          port: $0,
          playerCount: Int(DSUProtocol.slotCount)
        )
      } ?? dsuConfiguration
      let runtime = try await Task.detached(priority: .userInitiated) {
        try installation.prepareRuntime(
          dsuConfiguration: effectiveDSUConfiguration,
          contentURL: request.contentURL,
          mlcURL: request.saveSync.localSaveURL,
          launchPresentation: launchPresentation
        )
      }.value
      guard !Task.isCancelled else { return }

      let process = Process()
      // Execute the signed Cemu binary embedded in RetroVault directly.
      // LaunchServices rewrites forwarded arguments for sandboxed callers and
      // App-Translocates writable app copies, causing Cemu to open an empty
      // library instead of the requested title.
      process.executableURL = runtime.executableURL
      process.currentDirectoryURL = runtime.executableURL.deletingLastPathComponent()
      process.environment = runtime.processEnvironment()
      let launcherLogURL = runtime.userDataDirectory.appending(
        path: "launcher.log"
      )
      process.arguments = runtime.launchArguments(
        contentURL: request.contentURL,
        mlcURL: request.saveSync.localSaveURL,
        presentation: launchPresentation
      )

      _ = FileManager.default.createFile(
        atPath: launcherLogURL.path,
        contents: nil
      )
      let launcherLogHandle = try FileHandle(forWritingTo: launcherLogURL)
      try launcherLogHandle.truncate(atOffset: 0)
      process.standardOutput = launcherLogHandle
      process.standardError = launcherLogHandle
      RetroVaultLog.cemu.notice(
        "Launching bundled Cemu with \(installation.rendererName, privacy: .public) \(launchPresentation.logDescription, privacy: .public) for game \(request.gameID, privacy: .public) with content \(request.contentURL.path, privacy: .public)"
      )

      let existingCemuProcessIDs = Set(
        NSRunningApplication.runningApplications(
          withBundleIdentifier: "info.cemu.Cemu"
        ).map(\.processIdentifier)
      )
      do {
        try process.run()
      } catch {
        try? launcherLogHandle.close()
        throw CemuError.launchFailed(error.localizedDescription)
      }
      runningProcess = process
      self.launcherLogHandle = launcherLogHandle

      // `open -W` remains alive for the Cemu session. A short launch window
      // lets us distinguish a successful handoff from an immediate launcher
      // failure and locate the new Cemu instance for the exit chord.
      try? await Task.sleep(for: .milliseconds(350))
      guard process.isRunning else {
        let status = process.terminationStatus
        runningProcess = nil
        try? launcherLogHandle.close()
        self.launcherLogHandle = nil
        throw CemuError.launchFailed(
          "The macOS launcher exited with status \(status)."
        )
      }

      let application = NSRunningApplication(
        processIdentifier: process.processIdentifier
      ) ?? NSRunningApplication.runningApplications(
        withBundleIdentifier: "info.cemu.Cemu"
      ).first { !existingCemuProcessIDs.contains($0.processIdentifier) }
      runningApplication = application
      expectsEscapeToLeaveFullScreen = launchPresentation == .fullScreen
      if let application {
        // Cemu is intentionally a separate hosted application. Hiding the
        // host is the reliable modern macOS handoff: activation options that
        // used to force another process forward are ignored on macOS 14+.
        NSApplication.shared.hide(nil)
        didHideHostApplication = true
        if !application.activate(options: [.activateAllWindows]) {
          RetroVaultLog.cemu.error(
            "Cemu started, but macOS did not move it to the foreground."
          )
        }
      }
      process.terminationHandler = { [weak self] _ in
        Task { @MainActor [weak self] in
          await self?.finish(
            request: request,
            service: service,
            onFinished: onFinished
          )
        }
      }
      status = .running
      RetroVaultLog.cemu.notice(
        "Started Cemu for game \(request.gameID, privacy: .public); logs: \(runtime.logURL.path, privacy: .public), \(launcherLogURL.path, privacy: .public)"
      )
      monitorTask = Task { @MainActor [weak self] in
        var wasExitChordPressed = false
        var wasEscapeKeyPressed = Self.isEscapeKeyPressed
        while !Task.isCancelled {
          let isPressed = Self.isExitChordPressed
          if isPressed, !wasExitChordPressed {
            if self?.runningApplication?.terminate() != true {
              self?.runningProcess?.terminate()
            }
          }
          wasExitChordPressed = isPressed

          let isEscapeKeyPressed = Self.isEscapeKeyPressed
          if isEscapeKeyPressed, !wasEscapeKeyPressed {
            self?.handleEscapeKey()
          }
          wasEscapeKeyPressed = isEscapeKeyPressed
          try? await Task.sleep(for: .milliseconds(24))
        }
      }
    } catch {
      expectsEscapeToLeaveFullScreen = false
      controllerRelay?.stop()
      controllerRelay = nil
      RetroVaultLog.cemu.error(
        "Could not prepare or launch Cemu for game \(request.gameID, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      status = .failed(error.localizedDescription)
    }
  }

  func stop() {
    expectsEscapeToLeaveFullScreen = false
    monitorTask?.cancel()
    monitorTask = nil
    runningProcess?.terminationHandler = nil
    runningProcess = nil
    controllerRelay?.stop()
    controllerRelay = nil
    try? launcherLogHandle?.close()
    launcherLogHandle = nil
    restoreRetroVaultFocusIfNeeded()
  }

  private func finish(
    request: CemuRunRequest,
    service: any LibraryServing,
    onFinished: @escaping @MainActor @Sendable () -> Void
  ) async {
    guard !isFinishing else { return }
    isFinishing = true
    expectsEscapeToLeaveFullScreen = false
    monitorTask?.cancel()
    monitorTask = nil
    runningProcess?.terminationHandler = nil
    runningProcess = nil
    runningApplication = nil
    controllerRelay?.stop()
    controllerRelay = nil
    try? launcherLogHandle?.close()
    launcherLogHandle = nil
    restoreRetroVaultFocusIfNeeded()
    status = .synchronizing

    do {
      _ = try await service.syncCartridgeSaveAfterPlay(request.saveSync)
      RetroVaultLog.cemu.notice(
        "Synchronized Cemu save data for game \(request.gameID, privacy: .public)"
      )
    } catch {
      // The save remains in RetroVault's managed directory and Save Center
      // will expose it for retry even when RomM is temporarily unavailable.
      RetroVaultLog.cemu.error(
        "Could not synchronize Cemu save data for game \(request.gameID, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
    onFinished()
  }

  private func restoreRetroVaultFocusIfNeeded() {
    guard didHideHostApplication else { return }
    didHideHostApplication = false
    NSApplication.shared.unhide(nil)
    NSRunningApplication.current.activate(options: [.activateAllWindows])
  }

  private func handleEscapeKey() {
    guard runningApplication?.isActive == true else { return }

    switch GameplayEscapeAction.resolve(
      isFullScreen: expectsEscapeToLeaveFullScreen
    ) {
    case .leaveFullScreen:
      // Cemu receives this key as well and performs the actual transition.
      expectsEscapeToLeaveFullScreen = false
    case .closeGame:
      if runningApplication?.terminate() != true {
        runningProcess?.terminate()
      }
    }
  }

  private static var isExitChordPressed: Bool {
    if let pad = DSUConnection.shared.currentPad() {
      return pad.state.buttons.contains(.share)
        && pad.state.buttons.contains(.options)
    }
    return false
  }

  private static var isEscapeKeyPressed: Bool {
    CGEventSource.keyState(
      .combinedSessionState,
      key: CGKeyCode(53)
    )
  }
}

enum GameplayEscapeAction: Equatable, Sendable {
  case leaveFullScreen
  case closeGame

  static func resolve(isFullScreen: Bool) -> Self {
    isFullScreen ? .leaveFullScreen : .closeGame
  }
}

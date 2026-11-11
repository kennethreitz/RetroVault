@preconcurrency import AppKit
import Darwin
import Observation
import SwiftUI

/// Hosts Ryubing in its own process and projects its save data back to RomM.
///
/// Input is Ryubing's own SDL keyboard/gamepad handling. macOS gives RetroVault
/// no virtual-HID entitlement, so an external emulator cannot be fed synthetic
/// input; the emulator sees the real controller directly.
struct SwitchGameView: View {
  let request: SwitchRunRequest
  let service: any LibraryServing
  let launchPresentation: SwitchLaunchPresentation
  let onCloseRequested: @MainActor @Sendable () -> Void

  @State private var coordinator = SwitchPlayerCoordinator()

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
          Text("RYUJINX IS RUNNING")
            .font(.title2.weight(.black))
          Text("RetroVault will return when the Switch session ends.")
            .foregroundStyle(.secondary)
        }
      case .synchronizing:
        VStack(spacing: 18) {
          ProgressView().controlSize(.large)
          Text("SYNCHRONIZING SWITCH SAVE…")
            .font(.title2.weight(.black))
        }
      case .failed(let message):
        VStack(spacing: 18) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 52))
          Text("COULDN’T START RYUJINX")
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
        launchPresentation: launchPresentation,
        onFinished: onCloseRequested
      )
    }
    .onDisappear { coordinator.stop() }
    .focusedSceneValue(
      \.hostedGameplayControl,
      HostedGameplayControl(
        title: request.title,
        canStop: coordinator.canStop,
        stop: coordinator.requestClose
      )
    )
  }
}

/// Window-scene wrapper for launches from the desktop library.
struct SwitchPlayerWindow: View {
  let request: SwitchRunRequest
  let service: any LibraryServing
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    SwitchGameView(
      request: request,
      service: service,
      launchPresentation: .windowed
    ) {
      dismiss()
    }
  }
}

@MainActor
@Observable
private final class SwitchPlayerCoordinator {
  enum Status: Equatable {
    case ready
    case starting(String)
    case running
    case synchronizing
    case failed(String)
  }

  var status = Status.ready

  var canStop: Bool {
    runningApplication != nil || runningProcess != nil
  }

  private var runningApplication: NSRunningApplication?
  private var runningProcess: Process?
  private var launcherLogHandle: FileHandle?
  private var monitorTask: Task<Void, Never>?
  private var expectsEscapeToLeaveFullScreen = false
  private var didHideHostApplication = false
  private var isFinishing = false

  func start(
    request: SwitchRunRequest,
    service: any LibraryServing,
    launchPresentation: SwitchLaunchPresentation,
    onFinished: @escaping @MainActor @Sendable () -> Void
  ) async {
    guard runningProcess == nil, runningApplication == nil else {
      return
    }
    guard let installation = SwitchInstallation.available else {
      status = .failed(SwitchError.unavailable.localizedDescription)
      return
    }

    status = .starting("Preparing Ryujinx…")
    do {
      // A stale RetroVault-launched Ryujinx can swallow a new launch and leave
      // its empty library window on screen. Quit our own instances first.
      let ourExecutable = installation.executableURL
        .standardizedFileURL
        .resolvingSymlinksInPath()
      let staleInstances = NSRunningApplication.runningApplications(
        withBundleIdentifier: "org.ryujinx.Ryujinx"
      ).filter {
        $0.executableURL?
          .standardizedFileURL
          .resolvingSymlinksInPath() == ourExecutable
      }
      if !staleInstances.isEmpty {
        for instance in staleInstances {
          instance.terminate()
        }
        try? await Task.sleep(for: .milliseconds(600))
      }

      let runtime = try await Task.detached(priority: .userInitiated) {
        try installation.prepareRuntime(
          saveSync: request.saveSync,
          titleID: request.titleID
        )
      }.value
      guard !Task.isCancelled else { return }

      let process = Process()
      process.executableURL = runtime.executableURL
      process.currentDirectoryURL = runtime.executableURL
        .deletingLastPathComponent()
      process.environment = runtime.processEnvironment()
      process.arguments = runtime.launchArguments(
        contentURL: request.contentURL,
        presentation: launchPresentation
      )

      let launcherLogURL = runtime.dataRootURL.appending(
        path: "launcher.log"
      )
      _ = FileManager.default.createFile(
        atPath: launcherLogURL.path,
        contents: nil
      )
      let launcherLogHandle = try FileHandle(forWritingTo: launcherLogURL)
      try launcherLogHandle.truncate(atOffset: 0)
      process.standardOutput = launcherLogHandle
      process.standardError = launcherLogHandle
      RetroVaultLog.switch.notice(
        "Launching Ryubing for game \(request.gameID, privacy: .public) with content \(request.contentURL.path, privacy: .public)"
      )

      let existingProcessIDs = Set(
        NSRunningApplication.runningApplications(
          withBundleIdentifier: "org.ryujinx.Ryujinx"
        ).map(\.processIdentifier)
      )
      do {
        try process.run()
      } catch {
        try? launcherLogHandle.close()
        throw SwitchError.launchFailed(error.localizedDescription)
      }
      runningProcess = process
      self.launcherLogHandle = launcherLogHandle
      installation.recordDiagnostic("launch: started pid \(process.processIdentifier)")

      // Give the launcher a moment to fail before claiming success.
      try? await Task.sleep(for: .milliseconds(350))
      guard process.isRunning else {
        let status = process.terminationStatus
        runningProcess = nil
        try? launcherLogHandle.close()
        self.launcherLogHandle = nil
        throw SwitchError.launchFailed(
          "The Ryujinx process exited with status \(status)."
        )
      }

      let application =
        NSRunningApplication(processIdentifier: process.processIdentifier)
        ?? NSRunningApplication.runningApplications(
          withBundleIdentifier: "org.ryujinx.Ryujinx"
        ).first { !existingProcessIDs.contains($0.processIdentifier) }
      runningApplication = application
      expectsEscapeToLeaveFullScreen = launchPresentation == .fullScreen
      if let application {
        NSApplication.shared.hide(nil)
        didHideHostApplication = true
        if !application.activate(options: [.activateAllWindows]) {
          RetroVaultLog.switch.error(
            "Ryujinx started, but macOS did not move it to the foreground."
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
      RetroVaultLog.switch.notice(
        "Started Ryujinx for game \(request.gameID, privacy: .public); logs: \(runtime.logURL.path, privacy: .public), \(launcherLogURL.path, privacy: .public)"
      )
      monitorTask = Task { @MainActor [weak self] in
        var wasExitChordPressed = false
        var wasEscapeKeyPressed = Self.isEscapeKeyPressed
        while !Task.isCancelled {
          let isPressed = Self.isExitChordPressed
          if isPressed, !wasExitChordPressed {
            self?.requestClose()
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
      RetroVaultLog.switch.error(
        "Could not prepare or launch Ryubing for game \(request.gameID, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      installation.recordDiagnostic("launch: failed: \(error.localizedDescription)")
      status = .failed(error.localizedDescription)
    }
  }

  func stop() {
    expectsEscapeToLeaveFullScreen = false
    monitorTask?.cancel()
    monitorTask = nil
    runningProcess?.terminationHandler = nil
    runningProcess = nil
    try? launcherLogHandle?.close()
    launcherLogHandle = nil
    restoreRetroVaultFocusIfNeeded()
  }

  func requestClose() {
    guard canStop else { return }
    if runningApplication?.terminate() != true {
      runningProcess?.terminate()
    }
    forceKillIfNeeded()
  }

  private func forceKillIfNeeded() {
    guard let process = runningProcess else { return }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
  }

  private func finish(
    request: SwitchRunRequest,
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
    try? launcherLogHandle?.close()
    launcherLogHandle = nil
    restoreRetroVaultFocusIfNeeded()
    status = .synchronizing

    if let installation = SwitchInstallation.available {
      do {
        try installation.adoptDeviceSaves(
          titleID: request.titleID,
          saveSync: request.saveSync
        )
      } catch {
        RetroVaultLog.switch.error(
          "Could not adopt Ryujinx device saves for game \(request.gameID, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    do {
      _ = try await service.syncCartridgeSaveAfterPlay(request.saveSync)
      RetroVaultLog.switch.notice(
        "Synchronized Switch save data for game \(request.gameID, privacy: .public)"
      )
    } catch {
      // The save stays in RetroVault's managed bundle and Save Center exposes
      // it for retry even when RomM is temporarily unavailable.
      RetroVaultLog.switch.error(
        "Could not synchronize Switch save data for game \(request.gameID, privacy: .public): \(error.localizedDescription, privacy: .public)"
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
      // Ryujinx receives this key too and performs the actual transition.
      expectsEscapeToLeaveFullScreen = false
    case .closeGame:
      requestClose()
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

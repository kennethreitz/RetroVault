@preconcurrency import AppKit
@preconcurrency import GameController
import Observation
import SwiftUI

struct CemuGameView: View {
  let request: CemuRunRequest
  let service: any LibraryServing
  let dsuConfiguration: CemuDSUConfiguration?
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
  private var monitorTask: Task<Void, Never>?
  private var isFinishing = false

  func start(
    request: CemuRunRequest,
    service: any LibraryServing,
    dsuConfiguration: CemuDSUConfiguration?,
    onFinished: @escaping @MainActor @Sendable () -> Void
  ) async {
    guard runningProcess == nil, runningApplication == nil else {
      return
    }
    guard let installation = CemuInstallation.available else {
      status = .failed(CemuError.unavailable.localizedDescription)
      return
    }

    status = .starting("Preparing Cemu…")
    do {
      let runtime = try await Task.detached(priority: .userInitiated) {
        try installation.prepareRuntime(
          dsuConfiguration: dsuConfiguration,
          contentURL: request.contentURL,
          mlcURL: request.saveSync.localSaveURL
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
        mlcURL: request.saveSync.localSaveURL
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
        "Launching bundled Cemu directly for game \(request.gameID, privacy: .public) with content \(request.contentURL.path, privacy: .public)"
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
      application?.activate(options: [.activateAllWindows])
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
        while !Task.isCancelled {
          let isPressed = Self.isExitChordPressed
          if isPressed, !wasExitChordPressed {
            if self?.runningApplication?.terminate() != true {
              self?.runningProcess?.terminate()
            }
          }
          wasExitChordPressed = isPressed
          try? await Task.sleep(for: .milliseconds(24))
        }
      }
    } catch {
      RetroVaultLog.cemu.error(
        "Could not prepare or launch Cemu for game \(request.gameID, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      status = .failed(error.localizedDescription)
    }
  }

  func stop() {
    monitorTask?.cancel()
    monitorTask = nil
    runningProcess?.terminationHandler = nil
    runningProcess = nil
    try? launcherLogHandle?.close()
    launcherLogHandle = nil
  }

  private func finish(
    request: CemuRunRequest,
    service: any LibraryServing,
    onFinished: @escaping @MainActor @Sendable () -> Void
  ) async {
    guard !isFinishing else { return }
    isFinishing = true
    monitorTask?.cancel()
    monitorTask = nil
    runningProcess?.terminationHandler = nil
    runningProcess = nil
    runningApplication = nil
    try? launcherLogHandle?.close()
    launcherLogHandle = nil
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

  private static var isExitChordPressed: Bool {
    if let pad = DSUConnection.shared.currentPad() {
      return pad.buttons.contains(.share) && pad.buttons.contains(.options)
    }
    guard
      let controller = GCController.current ?? GCController.controllers().first,
      let gamepad = controller.extendedGamepad
    else {
      return false
    }
    return gamepad.buttonMenu.isPressed
      && gamepad.buttonOptions?.isPressed == true
  }
}

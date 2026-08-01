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
  private var monitorTask: Task<Void, Never>?
  private var terminationObserver: NSObjectProtocol?
  private var isFinishing = false

  func start(
    request: CemuRunRequest,
    service: any LibraryServing,
    dsuConfiguration: CemuDSUConfiguration?,
    onFinished: @escaping @MainActor @Sendable () -> Void
  ) async {
    guard runningApplication == nil, terminationObserver == nil else {
      return
    }
    guard let installation = CemuInstallation.available else {
      status = .failed(CemuError.unavailable.localizedDescription)
      return
    }

    status = .starting("Preparing Cemu…")
    do {
      let runtime = try await Task.detached(priority: .userInitiated) {
        try installation.prepareRuntime(dsuConfiguration: dsuConfiguration)
      }.value
      guard !Task.isCancelled else { return }

      let configuration = NSWorkspace.OpenConfiguration()
      configuration.arguments = [
        "-g", request.contentURL.path,
        "-m", request.saveSync.localSaveURL.path,
        "-f",
      ]
      // LaunchServices otherwise reuses an existing Cemu process. Cemu only
      // parses game arguments at process startup, so reuse opens its empty game
      // list instead of the selected title.
      configuration.createsNewApplicationInstance = true
      configuration.activates = true
      configuration.addsToRecentItems = false

      RetroVaultLog.cemu.notice(
        "Launching Cemu for game \(request.gameID, privacy: .public) with content \(request.contentURL.path, privacy: .public)"
      )

      let application = try await NSWorkspace.shared.openApplication(
        at: runtime.applicationURL,
        configuration: configuration
      )
      runningApplication = application
      status = .running
      RetroVaultLog.cemu.notice(
        "Started Cemu for game \(request.gameID, privacy: .public); log: \(runtime.logURL.path, privacy: .public)"
      )

      terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard
          let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          terminated.processIdentifier == application.processIdentifier
        else {
          return
        }
        Task { @MainActor [weak self] in
          await self?.finish(
            request: request,
            service: service,
            onFinished: onFinished
          )
        }
      }
      monitorTask = Task { @MainActor [weak self] in
        var wasExitChordPressed = false
        while !Task.isCancelled {
          let isPressed = Self.isExitChordPressed
          if isPressed, !wasExitChordPressed {
            self?.runningApplication?.terminate()
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
    removeTerminationObserver()
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
    removeTerminationObserver()
    runningApplication = nil
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

  private func removeTerminationObserver() {
    if let terminationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
      self.terminationObserver = nil
    }
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

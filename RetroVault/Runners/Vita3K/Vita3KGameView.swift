@preconcurrency import AppKit
import SwiftUI
import QuartzCore
import Observation

struct Vita3KGameView: View {
  let request: Vita3KRunRequest
  let onCloseRequested: () -> Void

  @State private var coordinator = Vita3KPlayerCoordinator()

  var body: some View {
    ZStack {
      Color.black
      Vita3KSurfaceView(coordinator: coordinator)

      switch coordinator.status {
      case .ready, .running:
        EmptyView()
      case .starting(let message):
        VStack(spacing: 18) {
          ProgressView()
            .controlSize(.large)
          Text(message.uppercased())
            .font(.title2.weight(.bold))
        }
      case .failed(let message):
        VStack(spacing: 18) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 52))
          Text("COULDN’T START VITA3K")
            .font(.title.weight(.black))
          Text(message)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560)
          Button("Back", action: onCloseRequested)
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    .task(id: request) {
      await coordinator.start(request: request)
    }
    .onDisappear {
      coordinator.stop()
    }
    .onExitCommand(perform: onCloseRequested)
  }
}

@MainActor
@Observable
private final class Vita3KPlayerCoordinator {
  enum Status: Equatable {
    case ready
    case starting(String)
    case running
    case failed(String)
  }

  var status = Status.ready
  weak var surfaceView: NSView?

  private var bridge: Vita3KBridge?
  private var runTask: Task<Void, Never>?
  private var eventPumpTask: Task<Void, Never>?

  func start(request: Vita3KRunRequest) async {
    guard runTask == nil, let surfaceView else {
      return
    }
    guard let installation = Vita3KInstallation.bundled else {
      status = .failed(Vita3KBridgeError.unavailable.localizedDescription)
      return
    }

    status = .starting("Starting Vita3K…")
    do {
      let bridge = try Vita3KBridge(installation: installation)
      self.bridge = bridge
      if !bridge.hasRequiredFirmware {
        for firmwareURL in request.firmwareURLs {
          status = .starting("Installing Vita firmware…")
          try await Task.detached(priority: .userInitiated) {
            try bridge.installFirmware(at: firmwareURL)
          }.value
          if bridge.hasRequiredFirmware {
            break
          }
        }
      }
      guard bridge.hasRequiredFirmware else {
        if let error = request.firmwarePreparationError {
          throw Vita3KBridgeError.firmwareInstallFailed(error)
        }
        throw Vita3KBridgeError.firmwareMissing
      }

      status = .starting("Installing \(request.title)…")
      let titleID = try await Task.detached(priority: .userInitiated) {
        try bridge.installArchive(at: request.archiveURL, gameID: request.gameID)
      }.value

      let pixelSize = surfaceView.pixelSize
      status = .running
      eventPumpTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          bridge.pumpEvents()
          try? await Task.sleep(for: .milliseconds(8))
        }
        self?.eventPumpTask = nil
      }
      runTask = Task.detached(priority: .userInitiated) { [weak self] in
        do {
          try bridge.run(
            in: surfaceView,
            pixelSize: pixelSize,
            titleID: titleID
          )
          await MainActor.run {
            self?.eventPumpTask?.cancel()
          }
        } catch {
          await MainActor.run {
            self?.eventPumpTask?.cancel()
            self?.status = .failed(error.localizedDescription)
          }
        }
      }
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  func resize(to size: CGSize) {
    bridge?.resize(to: size)
  }

  func stop() {
    eventPumpTask?.cancel()
    eventPumpTask = nil
    bridge?.stop()
    runTask?.cancel()
    runTask = nil
    bridge = nil
  }
}

private struct Vita3KSurfaceView: NSViewRepresentable {
  let coordinator: Vita3KPlayerCoordinator

  func makeNSView(context: Context) -> NSView {
    let view = Vita3KMetalView()
    view.onResize = { [weak coordinator] size in
      coordinator?.resize(to: size)
    }
    coordinator.surfaceView = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    coordinator.surfaceView = nsView
  }
}

private final class Vita3KMetalView: NSView {
  var onResize: ((CGSize) -> Void)?

  override func makeBackingLayer() -> CALayer {
    let layer = CAMetalLayer()
    layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    layer.framebufferOnly = false
    return layer
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.contentsScale = window?.backingScaleFactor ?? 2
      metalLayer.drawableSize = pixelSize
    }
    onResize?(pixelSize)
  }
}

private extension NSView {
  var pixelSize: CGSize {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    return CGSize(width: bounds.width * scale, height: bounds.height * scale)
  }
}

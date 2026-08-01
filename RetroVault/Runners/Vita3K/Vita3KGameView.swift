@preconcurrency import AppKit
@preconcurrency import GameController
import SwiftUI
import QuartzCore
import Observation

struct Vita3KGameView: View {
  let request: Vita3KRunRequest
  let onCloseRequested: () -> Void

  @State private var coordinator = Vita3KPlayerCoordinator()
  @AppStorage(LibretroVideoPreferences.filterKey)
  private var videoFilter = LibretroVideoPreferences.defaultFilter

  var body: some View {
    ZStack {
      Color.black
      Vita3KSurfaceView(coordinator: coordinator)
        // Vita3K renders Vulkan directly into the hosted CAMetalLayer, so it
        // never passes through Libretro's frame-texture compositor. Apply the
        // selected CRT glass as an independent presentation layer above that
        // surface. Smart is flat for the Vita because it is a handheld.
        .modifier(
          BigPictureVideoEffectModifier(
            filter: videoFilter.resolved(
              forSystemName: Vita3KInstallation.systemName
            )
          )
        )

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
        var previousControllerState: Vita3KControllerState?
        while !Task.isCancelled {
          bridge.pumpEvents()
          let controllerState = Vita3KControllerInput.currentState()
          if controllerState != previousControllerState {
            bridge.setController(controllerState)
            previousControllerState = controllerState
          }
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

  func setFrontTouch(at point: CGPoint, pressed: Bool, active: Bool) {
    bridge?.setFrontTouch(at: point, pressed: pressed, active: active)
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

/// A controller frame in the format consumed by Vita3K's virtual keyboard
/// controller. It is intentionally value-only so unchanged frames do not take
/// Vita3K's input lock on every event-pump tick.
struct Vita3KControllerState: Equatable, Sendable {
  var buttons: UInt32 = 0
  var extendedButtons: UInt32 = 0
  var leftX: Float = 0
  var leftY: Float = 0
  var rightX: Float = 0
  var rightY: Float = 0
}

struct Vita3KControllerSnapshot: Equatable, Sendable {
  var up = false
  var right = false
  var down = false
  var left = false
  var buttonA = false
  var buttonB = false
  var buttonX = false
  var buttonY = false
  var leftShoulder = false
  var rightShoulder = false
  var leftTrigger = false
  var rightTrigger = false
  var select = false
  var start = false
  var leftStick = false
  var rightStick = false
  var leftX: Float = 0
  var leftY: Float = 0
  var rightX: Float = 0
  var rightY: Float = 0
}

enum Vita3KControllerInput {
  private enum Button {
    static let select: UInt32 = 0x0000_0001
    static let leftStick: UInt32 = 0x0000_0002
    static let rightStick: UInt32 = 0x0000_0004
    static let start: UInt32 = 0x0000_0008
    static let up: UInt32 = 0x0000_0010
    static let right: UInt32 = 0x0000_0020
    static let down: UInt32 = 0x0000_0040
    static let left: UInt32 = 0x0000_0080
    static let leftTrigger: UInt32 = 0x0000_0100
    static let rightTrigger: UInt32 = 0x0000_0200
    static let leftShoulder: UInt32 = 0x0000_0400
    static let rightShoulder: UInt32 = 0x0000_0800
    static let triangle: UInt32 = 0x0000_1000
    static let circle: UInt32 = 0x0000_2000
    static let cross: UInt32 = 0x0000_4000
    static let square: UInt32 = 0x0000_8000
  }

  @MainActor
  static func currentState() -> Vita3KControllerState {
    if let state = DSUConnection.shared.currentPad() {
      return makeState(
        snapshot: snapshot(from: state),
        layout: DSUConnection.shared.padLayout
      )
    }
    guard
      let controller = GCController.current ?? GCController.controllers().first,
      let gamepad = controller.extendedGamepad
    else {
      return Vita3KControllerState()
    }
    return makeState(
      snapshot: snapshot(from: gamepad),
      layout: ControllerFaceButtonLayout.resolve(
        vendorName: controller.vendorName,
        productCategory: controller.productCategory
      )
    )
  }

  static func makeState(
    snapshot: Vita3KControllerSnapshot,
    layout: ControllerFaceButtonLayout
  ) -> Vita3KControllerState {
    var common: UInt32 = 0
    common.set(Button.select, when: snapshot.select)
    common.set(Button.leftStick, when: snapshot.leftStick)
    common.set(Button.rightStick, when: snapshot.rightStick)
    common.set(Button.start, when: snapshot.start)
    common.set(Button.up, when: snapshot.up)
    common.set(Button.right, when: snapshot.right)
    common.set(Button.down, when: snapshot.down)
    common.set(Button.left, when: snapshot.left)

    switch layout {
    case .standard:
      common.set(Button.cross, when: snapshot.buttonA)
      common.set(Button.circle, when: snapshot.buttonB)
      common.set(Button.square, when: snapshot.buttonX)
      common.set(Button.triangle, when: snapshot.buttonY)
    case .nintendo:
      common.set(Button.circle, when: snapshot.buttonA)
      common.set(Button.cross, when: snapshot.buttonB)
      common.set(Button.triangle, when: snapshot.buttonX)
      common.set(Button.square, when: snapshot.buttonY)
    }

    // Legacy Vita APIs expose one shoulder pair; the extended APIs split
    // shoulders and triggers into L1/R1 and L2/R2.
    var buttons = common
    buttons.set(Button.leftTrigger, when: snapshot.leftShoulder)
    buttons.set(Button.rightTrigger, when: snapshot.rightShoulder)
    var extendedButtons = common
    extendedButtons.set(Button.leftShoulder, when: snapshot.leftShoulder)
    extendedButtons.set(Button.rightShoulder, when: snapshot.rightShoulder)
    extendedButtons.set(Button.leftTrigger, when: snapshot.leftTrigger)
    extendedButtons.set(Button.rightTrigger, when: snapshot.rightTrigger)

    return Vita3KControllerState(
      buttons: buttons,
      extendedButtons: extendedButtons,
      leftX: clamped(snapshot.leftX),
      leftY: clamped(snapshot.leftY),
      rightX: clamped(snapshot.rightX),
      rightY: clamped(snapshot.rightY)
    )
  }

  private static func snapshot(from state: DSUPadState) -> Vita3KControllerSnapshot {
    let left = state.leftStick.normalized
    let right = state.rightStick.normalized
    return Vita3KControllerSnapshot(
      up: state.buttons.contains(.up),
      right: state.buttons.contains(.right),
      down: state.buttons.contains(.down),
      left: state.buttons.contains(.left),
      buttonA: state.buttons.contains(.a),
      buttonB: state.buttons.contains(.b),
      buttonX: state.buttons.contains(.x),
      buttonY: state.buttons.contains(.y),
      leftShoulder: state.buttons.contains(.l1),
      rightShoulder: state.buttons.contains(.r1),
      leftTrigger: state.buttons.contains(.l2),
      rightTrigger: state.buttons.contains(.r2),
      select: state.buttons.contains(.share),
      start: state.buttons.contains(.options),
      leftStick: state.buttons.contains(.leftStick),
      rightStick: state.buttons.contains(.rightStick),
      leftX: left.x,
      leftY: left.y,
      rightX: right.x,
      rightY: right.y
    )
  }

  private static func snapshot(
    from gamepad: GCExtendedGamepad
  ) -> Vita3KControllerSnapshot {
    Vita3KControllerSnapshot(
      up: gamepad.dpad.up.isPressed,
      right: gamepad.dpad.right.isPressed,
      down: gamepad.dpad.down.isPressed,
      left: gamepad.dpad.left.isPressed,
      buttonA: gamepad.buttonA.isPressed,
      buttonB: gamepad.buttonB.isPressed,
      buttonX: gamepad.buttonX.isPressed,
      buttonY: gamepad.buttonY.isPressed,
      leftShoulder: gamepad.leftShoulder.isPressed,
      rightShoulder: gamepad.rightShoulder.isPressed,
      leftTrigger: gamepad.leftTrigger.isPressed,
      rightTrigger: gamepad.rightTrigger.isPressed,
      select: gamepad.buttonOptions?.isPressed == true,
      start: gamepad.buttonMenu.isPressed,
      leftStick: gamepad.leftThumbstickButton?.isPressed == true,
      rightStick: gamepad.rightThumbstickButton?.isPressed == true,
      leftX: gamepad.leftThumbstick.xAxis.value,
      leftY: -gamepad.leftThumbstick.yAxis.value,
      rightX: gamepad.rightThumbstick.xAxis.value,
      rightY: -gamepad.rightThumbstick.yAxis.value
    )
  }

  private static func clamped(_ value: Float) -> Float {
    min(max(value, -1), 1)
  }
}

private extension UInt32 {
  mutating func set(_ mask: UInt32, when condition: Bool) {
    if condition {
      self |= mask
    }
  }
}

private struct Vita3KSurfaceView: NSViewRepresentable {
  let coordinator: Vita3KPlayerCoordinator

  func makeNSView(context: Context) -> NSView {
    let view = Vita3KMetalView()
    view.onResize = { [weak coordinator] size in
      coordinator?.resize(to: size)
    }
    view.onFrontTouch = { [weak coordinator] point, pressed, active in
      coordinator?.setFrontTouch(
        at: point,
        pressed: pressed,
        active: active
      )
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
  var onFrontTouch: ((CGPoint, Bool, Bool) -> Void)?
  private var eventMonitor: Any?
  private var pointerIsDown = false

  override var acceptsFirstResponder: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    removeEventMonitor()
    guard window != nil else { return }
    window?.acceptsMouseMovedEvents = true
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [
        .leftMouseDown,
        .leftMouseDragged,
        .leftMouseUp,
        .mouseMoved,
      ]
    ) { [weak self] event in
      self?.handlePointerEvent(event)
      return event
    }
  }

  override func layout() {
    super.layout()
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.contentsScale = window?.backingScaleFactor ?? 2
      metalLayer.drawableSize = pixelSize
    }
    onResize?(pixelSize)
  }

  private func handlePointerEvent(_ event: NSEvent) {
    guard event.window === window else {
      if event.type == .leftMouseUp, pointerIsDown {
        pointerIsDown = false
        onFrontTouch?(.zero, false, false)
      }
      return
    }

    switch event.type {
    case .leftMouseDown:
      pointerIsDown = true
      window?.makeFirstResponder(self)
    case .leftMouseUp:
      pointerIsDown = false
    case .leftMouseDragged, .mouseMoved:
      break
    default:
      return
    }
    updateFrontTouch(with: event, pressed: pointerIsDown)
  }

  private func updateFrontTouch(with event: NSEvent, pressed: Bool) {
    let location = convert(event.locationInWindow, from: nil)
    guard let point = Vita3KTouchMapper.normalized(
      point: location,
      in: bounds
    ) else {
      onFrontTouch?(.zero, false, false)
      return
    }
    onFrontTouch?(point, pressed, bounds.contains(location))
  }

  private func removeEventMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    pointerIsDown = false
  }
}

enum Vita3KTouchMapper {
  /// Converts AppKit's bottom-left coordinate space into normalized,
  /// top-left-origin coordinates for Vita3K's renderer surface.
  static func normalized(point: CGPoint, in bounds: CGRect) -> CGPoint? {
    guard bounds.width > 0, bounds.height > 0 else {
      return nil
    }
    return CGPoint(
      x: (point.x - bounds.minX) / bounds.width,
      y: 1 - ((point.y - bounds.minY) / bounds.height)
    )
  }
}

private extension NSView {
  var pixelSize: CGSize {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    return CGSize(width: bounds.width * scale, height: bounds.height * scale)
  }
}

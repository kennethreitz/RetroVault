@preconcurrency import AppKit
import SwiftUI
import QuartzCore
import CoreImage
import Observation

struct Vita3KGameView: View {
  let request: Vita3KRunRequest
  let service: any LibraryServing
  let onCloseRequested: @MainActor @Sendable () -> Void

  @State private var coordinator = Vita3KPlayerCoordinator()
  @State private var playerWindow: NSWindow?
  @AppStorage(LibretroVideoPreferences.filterKey)
  private var videoFilter = LibretroVideoPreferences.defaultFilter

  var body: some View {
    ZStack {
      Color.black
      Vita3KSurfaceView(
        coordinator: coordinator,
        filter: videoFilter.resolved(
          forSystemName: Vita3KInstallation.systemName
        )
      )
        // Vita3K renders Vulkan directly into the hosted CAMetalLayer, so it
        // never passes through Libretro's frame-texture compositor. The
        // representable installs the CRT glass in that same Core Animation
        // subtree; a SwiftUI blend layer is promoted separately in fullscreen
        // and can cover the Vulkan surface with solid white.

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
      case .synchronizing:
        VStack(spacing: 18) {
          ProgressView()
            .controlSize(.large)
          Text("SYNCHRONIZING VITA SAVE…")
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
    .background {
      Vita3KWindowAccessor { window in
        playerWindow = window
      }
      .frame(width: 0, height: 0)
    }
    .task(id: request) {
      await coordinator.start(
        request: request,
        service: service,
        onFinished: onCloseRequested
      )
    }
    .onDisappear {
      coordinator.stopAndPreserveLocalSave()
    }
    .onExitCommand {
      switch GameplayEscapeAction.resolve(
        isFullScreen: playerWindow?.styleMask.contains(.fullScreen) == true
      ) {
      case .leaveFullScreen:
        playerWindow?.toggleFullScreen(nil)
      case .closeGame:
        coordinator.requestClose()
      }
    }
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

private struct Vita3KWindowAccessor: NSViewRepresentable {
  let didMoveToWindow: @MainActor (NSWindow?) -> Void

  func makeNSView(context: Context) -> Vita3KWindowObservationView {
    let view = Vita3KWindowObservationView()
    view.didMoveToWindow = didMoveToWindow
    return view
  }

  func updateNSView(
    _ nsView: Vita3KWindowObservationView,
    context: Context
  ) {
    nsView.didMoveToWindow = didMoveToWindow
  }
}

private final class Vita3KWindowObservationView: NSView {
  var didMoveToWindow: (@MainActor (NSWindow?) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    didMoveToWindow?(window)
  }
}

@MainActor
@Observable
private final class Vita3KPlayerCoordinator {
  enum Status: Equatable {
    case ready
    case starting(String)
    case running
    case synchronizing
    case failed(String)
  }

  var status = Status.ready
  weak var surfaceView: NSView?

  var canStop: Bool {
    runTask != nil || bridge != nil
  }

  private var bridge: Vita3KBridge?
  private var runTask: Task<Void, Never>?
  private var eventPumpTask: Task<Void, Never>?
  private var activeRequest: Vita3KRunRequest?
  private var activeTitleID: String?
  private var activeService: (any LibraryServing)?
  private var onFinished: (@MainActor @Sendable () -> Void)?
  private var isClosing = false
  private var isFinishing = false

  func start(
    request: Vita3KRunRequest,
    service: any LibraryServing,
    onFinished: @escaping @MainActor @Sendable () -> Void
  ) async {
    guard runTask == nil, let surfaceView else {
      return
    }
    guard let installation = Vita3KInstallation.bundled else {
      status = .failed(Vita3KBridgeError.unavailable.localizedDescription)
      return
    }

    activeRequest = request
    activeService = service
    self.onFinished = onFinished
    isClosing = false
    isFinishing = false

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
      activeTitleID = titleID
      guard !isClosing else { return }

      if let saveSync = request.saveSync {
        status = .starting("Restoring Vita save…")
        let restored = try await Task.detached(priority: .userInitiated) {
          try Vita3KBridge.prepareRestoredSaveData(
            from: saveSync.localSaveURL,
            titleID: titleID
          )
        }.value
        if restored {
          RetroVaultLog.libretro.notice(
            "Restored Vita save data for game \(request.gameID, privacy: .public)"
          )
        }
      }
      guard !isClosing else { return }

      let pixelSize = surfaceView.pixelSize
      status = .running
      eventPumpTask = Task { @MainActor [weak self] in
        var previousControllerState: Vita3KControllerState?
        var previousRumbleState = Vita3KRumbleState(packed: 0)
        var exitChord = LibretroControllerExitChord()
        while !Task.isCancelled {
          bridge.pumpEvents()
          let controllerState = Vita3KControllerInput.currentState()
          if exitChord.update(
            startPressed: controllerState.isStartPressed,
            selectPressed: controllerState.isSelectPressed
          ) {
            RetroVaultLog.libretro.notice(
              "Start and Select pressed; requesting clean Vita3K exit"
            )
            self?.requestClose()
            break
          }
          if controllerState != previousControllerState {
            bridge.setController(controllerState)
            previousControllerState = controllerState
          }
          let rumbleState = bridge.rumbleState(forPlayer: 0)
          if rumbleState != previousRumbleState {
            _ = DSUConnection.shared.setRumble(
              slot: 0,
              strong: rumbleState.strong,
              weak: rumbleState.weak
            )
            previousRumbleState = rumbleState
          }
          try? await Task.sleep(for: .milliseconds(8))
        }
        if previousRumbleState.isActive {
          _ = DSUConnection.shared.setRumble(slot: 0, strong: 0, weak: 0)
        }
        self?.eventPumpTask = nil
      }
      runTask = Task.detached(priority: .userInitiated) { [self] in
        do {
          try bridge.run(
            in: surfaceView,
            pixelSize: pixelSize,
            titleID: titleID
          )
          await finishRun(errorMessage: nil)
        } catch {
          await finishRun(errorMessage: error.localizedDescription)
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

  func requestClose() {
    isClosing = true
    guard runTask != nil else {
      bridge?.stop()
      onFinished?()
      return
    }
    bridge?.stop()
  }

  func stopAndPreserveLocalSave() {
    isClosing = true
    eventPumpTask?.cancel()
    eventPumpTask = nil
    _ = DSUConnection.shared.setRumble(slot: 0, strong: 0, weak: 0)
    bridge?.stop()
    // The native runner owns Vita3K's teardown. Releasing the task or bridge
    // here can destroy the engine while its guest threads are still exiting.
    // `finishRun` captures and synchronizes the save after the runner returns.
    if runTask == nil {
      bridge = nil
    }
  }

  private func finishRun(errorMessage: String?) async {
    guard !isFinishing else { return }
    isFinishing = true
    eventPumpTask?.cancel()
    eventPumpTask = nil
    _ = DSUConnection.shared.setRumble(slot: 0, strong: 0, weak: 0)
    runTask = nil
    bridge = nil

    if let request = activeRequest,
      let titleID = activeTitleID,
      let service = activeService,
      let saveSync = request.saveSync
    {
      status = .synchronizing
      do {
        let captured = try await Task.detached(priority: .userInitiated) {
          try Vita3KBridge.captureSaveData(
            to: saveSync.localSaveURL,
            titleID: titleID
          )
        }.value
        if captured {
          RetroVaultLog.libretro.notice(
            "Captured Vita3K save data for game \(request.gameID, privacy: .public)"
          )
        }
        _ = try await service.syncCartridgeSaveAfterPlay(saveSync)
        RetroVaultLog.libretro.notice(
          "Synchronized Vita3K save data for game \(request.gameID, privacy: .public)"
        )
      } catch {
        // The managed save remains available to Save Center for a later retry.
        RetroVaultLog.libretro.error(
          "Could not synchronize Vita3K save data for game \(request.gameID, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    if let errorMessage {
      status = .failed(errorMessage)
      return
    }
    onFinished?()
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

  var isSelectPressed: Bool {
    buttons & 0x0000_0001 != 0
  }

  var isStartPressed: Bool {
    buttons & 0x0000_0008 != 0
  }
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
    if let pad = DSUConnection.shared.currentPad() {
      return makeState(
        snapshot: snapshot(from: pad.state),
        layout: pad.layout
      )
    }
    return Vita3KControllerState()
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
  let filter: LibretroVideoFilter

  func makeNSView(context: Context) -> NSView {
    let view = Vita3KMetalView()
    view.videoFilter = filter
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
    (nsView as? Vita3KMetalView)?.videoFilter = filter
  }
}

private final class Vita3KMetalView: NSView {
  var onResize: ((CGSize) -> Void)?
  var onFrontTouch: ((CGPoint, Bool, Bool) -> Void)?
  private var eventMonitor: Any?
  private var pointerIsDown = false
  private let displayOverlay = Vita3KDisplayOverlayView()

  var videoFilter = LibretroVideoFilter.nearest {
    didSet {
      displayOverlay.videoFilter = videoFilter
    }
  }

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
    displayOverlay.frame = bounds
    displayOverlay.autoresizingMask = [.width, .height]
    addSubview(displayOverlay)
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
    displayOverlay.frame = bounds
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

/// The CRT presentation for an engine that owns its drawable directly.
///
/// Keeping this layer beneath the hosted view's Core Animation root makes its
/// multiply composition stable when macOS promotes the Vulkan surface for
/// fullscreen. SwiftUI's equivalent overlay is correct for ordinary views,
/// but becomes a separate white plane above an externally rendered layer.
private final class Vita3KDisplayOverlayView: NSView {
  var videoFilter = LibretroVideoFilter.nearest {
    didSet {
      refreshVisibility()
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    refreshVisibility()
  }

  convenience init() {
    self.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func makeBackingLayer() -> CALayer {
    let layer = Vita3KCRTOverlayLayer()
    layer.needsDisplayOnBoundsChange = true
    layer.compositingFilter = CIFilter(name: "CIMultiplyCompositing")
    return layer
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    refreshScale()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refreshScale()
  }

  private func refreshVisibility() {
    isHidden = !Vita3KVideoEffectPolicy.usesCRTOverlay(videoFilter)
    refreshScale()
  }

  private func refreshScale() {
    guard let layer = layer as? Vita3KCRTOverlayLayer else {
      return
    }
    layer.contentsScale = window?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor
      ?? 2
    layer.setNeedsDisplay()
  }
}

enum Vita3KVideoEffectPolicy {
  static func usesCRTOverlay(_ filter: LibretroVideoFilter) -> Bool {
    switch filter {
    case .crt, .crtSmart, .crtCurved:
      true
    case .nearest, .sharpBilinear, .xbr:
      false
    }
  }
}

private final class Vita3KCRTOverlayLayer: CALayer {
  override func draw(in context: CGContext) {
    let scale = max(contentsScale, 1)
    let patternInfo = Vita3KCRTOverlayPatternInfo(displayScale: scale)
    var callbacks = CGPatternCallbacks(
      version: 0,
      drawPattern: drawVita3KCRTOverlayPattern,
      releaseInfo: nil
    )
    guard
      let pattern = CGPattern(
        info: Unmanaged.passUnretained(patternInfo).toOpaque(),
        bounds: CGRect(
          x: 0,
          y: 0,
          width: CGFloat(Vita3KCRTOverlayPattern.width) / scale,
          height: CGFloat(Vita3KCRTOverlayPattern.height) / scale
        ),
        matrix: .identity,
        xStep: CGFloat(Vita3KCRTOverlayPattern.width) / scale,
        yStep: CGFloat(Vita3KCRTOverlayPattern.height) / scale,
        tiling: .constantSpacingMinimalDistortion,
        isColored: true,
        callbacks: &callbacks
      ),
      let colorSpace = CGColorSpace(patternBaseSpace: nil)
    else {
      return
    }

    context.setFillColorSpace(colorSpace)
    var alpha: CGFloat = 1
    context.setFillPattern(pattern, colorComponents: &alpha)
    context.fill(bounds)
  }
}

private final class Vita3KCRTOverlayPatternInfo {
  let displayScale: CGFloat

  init(displayScale: CGFloat) {
    self.displayScale = displayScale
  }
}

private func drawVita3KCRTOverlayPattern(
  info: UnsafeMutableRawPointer?,
  context: CGContext
) {
  guard let info else {
    return
  }
  let patternInfo = Unmanaged<Vita3KCRTOverlayPatternInfo>
    .fromOpaque(info)
    .takeUnretainedValue()
  let scale = patternInfo.displayScale

  for y in 0..<Vita3KCRTOverlayPattern.height {
    for x in 0..<Vita3KCRTOverlayPattern.width {
      let color = Vita3KCRTOverlayPattern.color(x: x, y: y)
      context.setFillColor(
        red: CGFloat(color.x),
        green: CGFloat(color.y),
        blue: CGFloat(color.z),
        alpha: 1
      )
      context.fill(
        CGRect(
          x: CGFloat(x) / scale,
          y: CGFloat(y) / scale,
          width: 1 / scale,
          height: 1 / scale
        )
      )
    }
  }
}

enum Vita3KCRTOverlayPattern {
  static let width = 6
  static let height = 12

  static func color(x: Int, y: Int) -> SIMD3<Float> {
    let rowInBank = y % 3
    let bank = (y / 3) % 2
    let phosphor = ((x + bank * 2) / 2) % 3

    var mask = SIMD3<Float>(repeating: 0.78)
    mask[phosphor] = 1.22
    if rowInBank == 2 {
      mask *= 0.78
    }
    mask = mix(SIMD3<Float>(repeating: 1), mask * 1.165, amount: 0.72)

    let scanlinePhase = Float(y % 4) / 4
    let distanceFromCenter = scanlinePhase - 0.5
    let beam = exp2(-8 * distanceFromCenter * distanceFromCenter)
    let scanline = mix(1, beam, amount: 0.34)
    let output = mask * scanline * Float(1.18)
    return SIMD3<Float>(
      min(output.x, 1),
      min(output.y, 1),
      min(output.z, 1)
    )
  }

  private static func mix<T: SIMD>(
    _ start: T,
    _ end: T,
    amount: T.Scalar
  ) -> T where T.Scalar == Float {
    start + (end - start) * amount
  }

  private static func mix(
    _ start: Float,
    _ end: Float,
    amount: Float
  ) -> Float {
    start + (end - start) * amount
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

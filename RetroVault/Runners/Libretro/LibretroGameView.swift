import AppKit
import MetalKit
import SwiftUI

struct LibretroAudioControl {
    let isMuted: Bool
    private let toggle: @MainActor () -> Void

    init(
        isMuted: Bool,
        toggle: @escaping @MainActor () -> Void
    ) {
        self.isMuted = isMuted
        self.toggle = toggle
    }

    @MainActor
    func toggleMute() {
        toggle()
    }
}

private struct LibretroAudioControlFocusedValueKey: FocusedValueKey {
    typealias Value = LibretroAudioControl
}

extension FocusedValues {
    var libretroAudioControl: LibretroAudioControl? {
        get { self[LibretroAudioControlFocusedValueKey.self] }
        set { self[LibretroAudioControlFocusedValueKey.self] = newValue }
    }
}

struct LibretroGameView: View {
    @State private var session: LibretroSession
    @State private var playerWindow: NSWindow?
    @State private var isFullScreen = false
    @AppStorage(LibretroTransportPreferences.enablesFastForwardKey)
    private var enablesR3FastForward =
        LibretroTransportPreferences.enabledByDefault
    @AppStorage(LibretroTransportPreferences.enablesRewindKey)
    private var enablesL3Rewind =
        LibretroTransportPreferences.enabledByDefault
    @AppStorage(LibretroPlayerPreferences.opensInFullScreenKey)
    private var opensInFullScreen =
        LibretroPlayerPreferences.opensInFullScreenByDefault
    @AppStorage(LibretroVideoPreferences.filterKey)
    private var videoFilter = LibretroVideoPreferences.defaultFilter
    @State private var hasRequestedFullScreen = false
    private let onCloseRequested: (@MainActor () -> Void)?

    init(
        request: LibretroRunRequest,
        service: any LibraryServing,
        onCloseRequested: (@MainActor () -> Void)? = nil
    ) {
        self.onCloseRequested = onCloseRequested
        _session = State(
            initialValue: LibretroSession(request: request) { configuration in
                try await service.syncCartridgeSaveAfterPlay(configuration)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                switch session.phase {
                case .idle, .starting:
                    ProgressView("Starting \(session.request.title)…")
                        .controlSize(.large)
                        .foregroundStyle(.white)
                case .running:
                    LibretroMetalView(
                        videoBuffer: session.videoBuffer,
                        input: session.input,
                        filter: videoFilter.resolved(
                            forSystemName: session.request.systemName
                        )
                    )
                    // Keep windowed gameplay inside the native content area
                    // so the title bar never covers the picture. Fullscreen
                    // still extends beneath the hover-only toolbar to avoid
                    // resizing the drawable when the controls appear.
                    .ignoresSafeArea(
                        edges: isFullScreen ? .all : []
                    )
                case .stopped:
                    ContentUnavailableView {
                        Label("Session Ended", systemImage: "stop.circle")
                    } description: {
                        VStack(spacing: 8) {
                            Text("Your local save memory has been preserved.")
                            saveSyncStatus
                        }
                    } actions: {
                        if case .failed = session.saveSyncPhase {
                            Button("Retry Save Sync") {
                                session.retrySaveSync()
                            }
                        }

                        Button("Play Again") {
                            session.start()
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(session.saveSyncPhase == .syncing)
                    }
                    .foregroundStyle(.white)
                case let .failed(message):
                    ContentUnavailableView {
                        Label(
                            "Couldn’t Start Libretro",
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(message)
                            .frame(maxWidth: 520)
                    } actions: {
                        Button("Try Again") {
                            session.start()
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .foregroundStyle(.white)
                }

                LibretroKeyboardCapture(input: session.input)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)

                playbackStatusOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if case .running = session.phase, !isFullScreen {
                controls
            }
        }
        .background(Color.black)
        .navigationTitle(
            isImmersiveBigPicturePlayback ? "" : session.request.title
        )
        .frame(minWidth: 640, minHeight: 480)
        .background {
            PlayerWindowAccessor { window in
                playerWindow = window
                // NSWindow suppresses passive mouse-moved events by default.
                // DOSBox Pure needs every relative delta, not just movement
                // received while a button happens to be held.
                window?.acceptsMouseMovedEvents = true
                isFullScreen = window?.styleMask.contains(.fullScreen) == true
                updatePlayerToolbarVisibility(
                    forFullScreen: isFullScreen
                )
                enterFullScreenIfPreferred()
            }
            .frame(width: 0, height: 0)
        }
        .task {
            configureTransportControls()
            session.start()
        }
        .onChange(of: enablesR3FastForward) {
            configureTransportControls()
        }
        .onChange(of: enablesL3Rewind) {
            configureTransportControls()
        }
        .onDisappear {
            if session.shouldClosePlayer {
                session.stop()
            } else {
                session.exitPlayer()
            }
        }
        .onExitCommand {
            switch LibretroEscapeAction.resolve(
                isFullScreen: isFullScreen,
                playerOrigin: session.request.playerOrigin
            ) {
            case .leaveFullScreen:
                playerWindow?.toggleFullScreen(nil)
            case .exitPlayer:
                session.exitPlayer()
            case .stopSession:
                session.stop()
            }
        }
        .onChange(of: session.shouldClosePlayer) { _, shouldClosePlayer in
            guard shouldClosePlayer, session.isReadyToClosePlayer else {
                return
            }
            closePlayer()
        }
        .onChange(of: session.phase) { _, phase in
            guard
                phase == .stopped,
                session.shouldClosePlayer,
                session.isReadyToClosePlayer
            else {
                return
            }
            closePlayer()
        }
        .onKeyPress("w", phases: .down) { keyPress in
            guard
                onCloseRequested != nil,
                keyPress.modifiers.contains(.command)
            else {
                return .ignored
            }
            session.exitPlayer()
            return .handled
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSWindow.didEnterFullScreenNotification
            )
        ) { notification in
            guard notification.object as? NSWindow === playerWindow else {
                return
            }
            isFullScreen = true
            updatePlayerToolbarVisibility(forFullScreen: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSWindow.didExitFullScreenNotification
            )
        ) { notification in
            guard notification.object as? NSWindow === playerWindow else {
                return
            }
            isFullScreen = false
            updatePlayerToolbarVisibility(forFullScreen: false)
        }
        .focusedSceneValue(\.libretroAudioControl, audioControl)
        .windowToolbarFullScreenVisibility(.onHover)
        .toolbarVisibility(
            isImmersiveBigPicturePlayback ? .hidden : .automatic,
            for: .windowToolbar
        )
        .toolbar {
            if !isImmersiveBigPicturePlayback {
                ToolbarItemGroup {
                    Button {
                        session.togglePause()
                    } label: {
                        Label(
                            session.isPaused ? "Resume" : "Pause",
                            systemImage: session.isPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .disabled(!isRunning)

                    Button {
                        session.toggleMute()
                    } label: {
                        Label(
                            session.isMuted ? "Unmute" : "Mute",
                            systemImage: session.isMuted
                                ? "speaker.slash.fill"
                                : "speaker.wave.2.fill"
                        )
                    }
                    .disabled(!isRunning)
                    .help(
                        session.isMuted
                            ? "Restore game audio (⌘M)"
                            : "Mute game audio (⌘M)"
                    )

                    Button {
                        session.reset()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!isRunning)

                    Button {
                        session.rewind()
                    } label: {
                        Label("Rewind", systemImage: "gobackward")
                    }
                    .buttonRepeatBehavior(.enabled)
                    .disabled(!isRunning || !session.canRewind)
                    .help(
                        session.allowsRewind
                            ? "Step backward; hold for continuous rewind"
                            : "Rewind is disabled for Nintendo 64 games"
                    )

                    Menu {
                        Button("Save Quick State") {
                            session.saveQuickState()
                        }

                        Button("Load Quick State") {
                            session.loadQuickState()
                        }
                        .disabled(!session.hasQuickState)
                    } label: {
                        Label("State", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(!isRunning || !session.allowsQuickStates)

                    Button {
                        playerWindow?.toggleFullScreen(nil)
                    } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .keyboardShortcut("f", modifiers: [.control, .command])

                    Button(role: .destructive) {
                        if onCloseRequested == nil {
                            session.stop()
                        } else {
                            session.exitPlayer(mode: .explicitStop)
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(!isRunning)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if session.isPaused {
                Label("Paused", systemImage: "pause.fill")
                    .fontWeight(.semibold)
            } else {
                Text("Arrow keys or D-pad to move")
            }

            Divider()
                .frame(height: 18)
            Text("Start + Select to exit")

            if let transportControlsHint {
                Divider()
                    .frame(height: 18)
                Text(transportControlsHint)
            }

            if let message = session.message {
                Divider()
                    .frame(height: 18)
                Text(message)
            }

            Spacer()

            if case let .running(coreName, framesPerSecond) = session.phase {
                Text(coreName)
                Text(
                    "\(framesPerSecond.formatted(.number.precision(.fractionLength(0)))) FPS"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .openVaultGlass(
            tint: .black.opacity(0.58),
            in: Capsule()
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var playbackStatusOverlay: some View {
        if session.isRewinding || session.isFastForwarding || session.isMuted {
            VStack(alignment: .trailing, spacing: 10) {
                if session.isRewinding || session.isFastForwarding {
                    transportStatusBadge
                }

                if session.isMuted {
                    Label("Muted", systemImage: "speaker.slash.fill")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .openVaultGlass(
                            tint: .black.opacity(0.68),
                            in: Capsule()
                        )
                        .accessibilityLabel("Game audio muted")
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topTrailing
            )
            .padding(20)
            .allowsHitTesting(false)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var transportStatusBadge: some View {
        HStack(spacing: 8) {
            Image(
                systemName: session.isRewinding
                    ? "backward.fill"
                    : "forward.fill"
            )
            if session.isFastForwarding {
                Text(
                    LibretroTransportPreferences
                        .fastForwardMultiplierLabel()
                )
                .fontDesign(.rounded)
                if session.isFastForwardLatched {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                }
            }
        }
        .font(.title2.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .openVaultGlass(
            tint: .black.opacity(0.68),
            in: Capsule()
        )
        .accessibilityLabel(
            session.isRewinding
                ? "Rewinding"
                : session.isFastForwardLatched
                ? "Fast forward locked"
                : "Fast forwarding"
        )
    }

    @ViewBuilder
    private var saveSyncStatus: some View {
        switch session.saveSyncPhase {
        case .idle:
            if session.request.saveSync != nil {
                Text("Waiting to sync the cartridge save with RomM.")
                    .foregroundStyle(.secondary)
            }
        case .syncing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing cartridge save to RomM…")
            }
        case .unchanged:
            Label("Cartridge save is already synchronized.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .uploaded:
            Label("Cartridge save uploaded to RomM.", systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.icloud")
                .foregroundStyle(.orange)
                .frame(maxWidth: 520)
        }
    }

    private var isRunning: Bool {
        if case .running = session.phase {
            return true
        }
        return false
    }

    private var isImmersiveBigPicturePlayback: Bool {
        session.request.playerOrigin == .bigPicture && isFullScreen
    }

    private var audioControl: LibretroAudioControl? {
        guard isRunning else {
            return nil
        }
        return LibretroAudioControl(
            isMuted: session.isMuted,
            toggle: session.toggleMute
        )
    }

    /// SwiftUI can leave the toolbar hidden after an immersive Big Picture
    /// session exits fullscreen because the same NSWindow is reused. Keep the
    /// AppKit toolbar in sync with the actual presentation state so windowed
    /// gameplay always regains its controls.
    private func updatePlayerToolbarVisibility(forFullScreen fullScreen: Bool) {
        guard let playerWindow else {
            return
        }
        let shouldHide =
            session.request.playerOrigin == .bigPicture && fullScreen
        Task { @MainActor in
            playerWindow.toolbar?.isVisible = !shouldHide
        }
    }

    private var transportControlsHint: String? {
        switch (enablesL3Rewind, enablesR3FastForward) {
        case (true, true):
            "Hold L3 to rewind · Hold R3 to fast-forward; 4s locks"
        case (true, false):
            "Hold L3 to rewind"
        case (false, true):
            "Hold R3 to fast-forward; 4s locks"
        case (false, false):
            nil
        }
    }

    /// Opens the player full screen when the preference asks for it.
    ///
    /// Only once per player: the accessor reports the window more than once,
    /// and leaving full screen by hand should not be undone.
    private func enterFullScreenIfPreferred() {
        guard
            opensInFullScreen,
            !hasRequestedFullScreen,
            let playerWindow,
            !playerWindow.styleMask.contains(.fullScreen)
        else {
            return
        }

        hasRequestedFullScreen = true
        // Deferred past the layout pass that produced the window, since
        // toggling full screen mid-update fights the window's own setup.
        Task { @MainActor in
            playerWindow.toggleFullScreen(nil)
        }
    }

    private func configureTransportControls() {
        session.setTransportControlsEnabled(
            rewind: enablesL3Rewind,
            fastForward: enablesR3FastForward
        )
    }

    private func closePlayer() {
        if let onCloseRequested {
            onCloseRequested()
        } else {
            playerWindow?.performClose(nil)
        }
    }
}

enum LibretroEscapeAction: Equatable, Sendable {
    case leaveFullScreen
    case exitPlayer
    case stopSession

    static func resolve(
        isFullScreen: Bool,
        playerOrigin: LibretroPlayerOrigin?
    ) -> Self {
        if isFullScreen {
            return .leaveFullScreen
        }
        return playerOrigin == .bigPicture ? .exitPlayer : .stopSession
    }
}

private struct PlayerWindowAccessor: NSViewRepresentable {
    let didMoveToWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> PlayerWindowObservationView {
        let view = PlayerWindowObservationView()
        view.didMoveToWindow = didMoveToWindow
        return view
    }

    func updateNSView(
        _ nsView: PlayerWindowObservationView,
        context: Context
    ) {
        nsView.didMoveToWindow = didMoveToWindow
    }
}

private final class PlayerWindowObservationView: NSView {
    var didMoveToWindow: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        didMoveToWindow?(window)
    }
}

private struct LibretroMetalView: NSViewRepresentable {
    let videoBuffer: LibretroVideoBuffer
    let input: LibretroInputState
    let filter: LibretroVideoFilter

    func makeNSView(context: Context) -> LibretroMTKView {
        LibretroMTKView(
            videoBuffer: videoBuffer,
            input: input,
            filter: filter
        )
    }

    func updateNSView(_ nsView: LibretroMTKView, context: Context) {
        nsView.filter = filter
    }
}

private final class LibretroMTKView: MTKView, MTKViewDelegate {
    private static let cursorIdleInterval: TimeInterval = 1.5
    private static let transparentCursor = NSCursor(
        image: NSImage(
            size: NSSize(width: 1, height: 1),
            flipped: false
        ) { _ in true },
        hotSpot: .zero
    )

    private enum CursorHidingMode {
        case visible
        case window
        case display
    }

    private let videoBuffer: LibretroVideoBuffer
    private let input: LibretroInputState
    private let commandQueue: MTLCommandQueue
    private let pipelineStates: [LibretroVideoFilter: MTLRenderPipelineState]
    private let fallbackPipelineState: MTLRenderPipelineState
    /// Which filter the next frame is drawn with. Swapping it only picks a
    /// different pipeline state that was already built at startup, so a
    /// change mid-game costs nothing and takes effect on the next frame.
    var filter: LibretroVideoFilter
    private var sourceTextures: [MTLTexture] = []
    private var currentSourceTextureIndex: Int?
    private var previousSourceTextureIndex: Int?
    private var lastUploadedFrameRevision: UInt64?
    private var sourceSize = CGSize.zero
    private var sourceAspectRatio: CGFloat = 0
    private var pointerPressed = false
    private var pointerTrackingArea: NSTrackingArea?
    private var cursorHideTask: Task<Void, Never>?
    private var isPointerInside = false
    private var cursorHidingMode = CursorHidingMode.visible
    private var observedWindow: NSWindow?

    init(
        videoBuffer: LibretroVideoBuffer,
        input: LibretroInputState,
        filter: LibretroVideoFilter
    ) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(
                source: LibretroMetalShader.source,
                options: nil
            ),
            let vertexFunction = library.makeFunction(
                name: "openVaultPixelVertex"
            )
        else {
            fatalError("RetroVault requires a Metal-capable Apple-silicon Mac.")
        }

        // Every filter's pipeline is built once here rather than when the
        // preference changes, so switching filters mid-game never stalls the
        // render loop compiling one.
        var pipelineStates: [LibretroVideoFilter: MTLRenderPipelineState] = [:]
        for candidate in LibretroVideoFilter.allCases {
            guard let fragmentFunction = library.makeFunction(
                name: candidate.fragmentFunctionName
            ) else {
                continue
            }
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "RetroVault \(candidate.rawValue) video"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineStates[candidate] = try? device.makeRenderPipelineState(
                descriptor: pipelineDescriptor
            )
        }

        guard let fallbackPipelineState = pipelineStates[.nearest] else {
            fatalError("RetroVault could not create its Libretro video pipeline.")
        }

        self.videoBuffer = videoBuffer
        self.input = input
        self.commandQueue = commandQueue
        self.pipelineStates = pipelineStates
        self.fallbackPipelineState = fallbackPipelineState
        self.filter = filter
        super.init(frame: .zero, device: device)

        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        // Core Animation buffers three drawables by default so a renderer can
        // work ahead, which costs a finished frame roughly one extra refresh
        // before it reaches the display. Presenting a game frame is a single
        // nearest-neighbour blit that never needs that headroom, so trade the
        // spare buffer for lower input-to-photon latency.
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        cursorHideTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        if cursorHidingMode == .display {
            NSCursor.unhide()
        } else if cursorHidingMode == .window {
            NSCursor.arrow.set()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if cursorHidingMode == .window {
            addCursorRect(bounds, cursor: Self.transparentCursor)
        }
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
        synchronizePointerLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingWindow()
        // SwiftUI can replace the Metal view underneath a stationary pointer.
        // Re-evaluate after that layout pass rather than waiting for a mouse
        // movement that may never arrive.
        Task { @MainActor [weak self] in
            self?.synchronizePointerLocation()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== observedWindow {
            restoreCursor()
            stopObservingWindow()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        recordPointerActivity()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        pointerPressed = false
        input.releaseMouseButtons()
        restoreCursor()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerPressed = true
        input.setMouseButton(LibretroMouseID.left, pressed: true)
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pointerPressed = false
        input.setMouseButton(LibretroMouseID.left, pressed: false)
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        input.setMouseButton(LibretroMouseID.right, pressed: true)
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        input.setMouseButton(LibretroMouseID.right, pressed: false)
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            return
        }
        window?.makeFirstResponder(self)
        input.setMouseButton(LibretroMouseID.middle, pressed: true)
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            return
        }
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            return
        }
        input.setMouseButton(LibretroMouseID.middle, pressed: false)
        recordPointerActivity()
        updatePointingDevices(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard pointerIsOverPicture(event.locationInWindow) else {
            return
        }
        input.scrollMouse(deltaY: event.scrollingDeltaY)
        recordPointerActivity()
    }

    private func recordPointerActivity() {
        cursorHideTask?.cancel()

        // A core being aimed with the mouse gets the cursor back while the
        // mouse is actually moving, then loses it again once it settles.
        // Everything else keeps it hidden throughout.
        guard revealsCursorWhileMoving else {
            setCursorHidden(true)
            return
        }

        setCursorHidden(false)
        guard isPointerInside, window?.isKeyWindow == true else {
            return
        }

        cursorHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(Self.cursorIdleInterval)
            )
            guard
                let self,
                !Task.isCancelled,
                self.isPointerInside,
                self.window?.isKeyWindow == true
            else {
                return
            }
            self.setCursorHidden(true)
        }
    }

    private func restoreCursor() {
        cursorHideTask?.cancel()
        cursorHideTask = nil
        setCursorHidden(false)
    }

    /// Whether moving the mouse should bring the cursor back.
    ///
    /// A core that reads the pointer is being aimed with the mouse, so hiding
    /// the cursor outright would make it unusable; it is revealed while the
    /// mouse moves and hidden again once it settles. DOS is the exception
    /// that matters: DOSBox reads the pointer but draws its own cursor, and
    /// leaving the system one on top gives a game two cursors that do not
    /// quite line up, so it stays hidden throughout.
    private var revealsCursorWhileMoving: Bool {
        input.readsPointer && !input.readsKeyboard
    }

    /// Hides the cursor only over this game view in a normal window.
    ///
    /// `NSCursor.hide()` is display-wide, so using it for a windowed player
    /// also hides the pointer over every other app and display. Windowed play
    /// instead owns a transparent cursor rect and sets it immediately for the
    /// stationary-pointer case. Fullscreen retains the balanced AppKit hide.
    private func setCursorHidden(_ hidden: Bool) {
        let targetMode: CursorHidingMode
        if !hidden {
            targetMode = .visible
        } else if window?.styleMask.contains(.fullScreen) == true {
            targetMode = .display
        } else {
            targetMode = .window
        }

        guard targetMode != cursorHidingMode else {
            return
        }

        let previousMode = cursorHidingMode
        if previousMode == .display {
            NSCursor.unhide()
        }

        cursorHidingMode = targetMode
        window?.invalidateCursorRects(for: self)

        switch targetMode {
        case .visible:
            if previousMode == .window {
                NSCursor.arrow.set()
            }
        case .window:
            if isPointerInside, window?.isKeyWindow == true {
                Self.transparentCursor.set()
            }
        case .display:
            NSCursor.hide()
        }
    }

    private func synchronizePointerLocation() {
        guard
            let window,
            window.isKeyWindow
        else {
            isPointerInside = false
            restoreCursor()
            return
        }

        let windowPoint = window.convertPoint(
            fromScreen: NSEvent.mouseLocation
        )
        let localPoint = convert(windowPoint, from: nil)
        isPointerInside = bounds.contains(localPoint)
        if isPointerInside {
            recordPointerActivity()
        } else {
            restoreCursor()
        }
    }

    private func startObservingWindow() {
        guard observedWindow !== window else {
            return
        }
        stopObservingWindow()
        guard let window else {
            return
        }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerWindowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerWindowFullScreenDidChange(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerWindowFullScreenDidChange(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
    }

    private func stopObservingWindow() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: nil,
                object: observedWindow
            )
        }
        observedWindow = nil
    }

    @objc
    private func playerWindowDidBecomeKey(_ notification: Notification) {
        synchronizePointerLocation()
    }

    @objc
    private func playerWindowDidResignKey(_ notification: Notification) {
        pointerPressed = false
        input.releaseMouseButtons()
        restoreCursor()
    }

    @objc
    private func playerWindowWillClose(_ notification: Notification) {
        restoreCursor()
    }

    @objc
    private func playerWindowFullScreenDidChange(_ notification: Notification) {
        setCursorHidden(cursorHidingMode != .visible)
    }

    func draw(in view: MTKView) {
        guard
            let snapshot = videoBuffer.versionedSnapshot(),
            let drawable = currentDrawable,
            let renderPassDescriptor = currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }
        let frame = snapshot.frame

        guard
            frame.width > 0,
            frame.height > 0,
            frame.pixels.count >= frame.width * frame.height * 4,
            let textures = textures(for: snapshot)
        else {
            return
        }
        sourceSize = CGSize(width: frame.width, height: frame.height)
        sourceAspectRatio = CGFloat(frame.aspectRatio)

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            0,
            0,
            0,
            1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            return
        }

        let pictureRect = pictureRect(
            forSourceSize: CGSize(width: frame.width, height: frame.height),
            aspectRatio: CGFloat(frame.aspectRatio)
        )
        let viewport = LibretroVideoLayout.viewport(
            pictureRect: pictureRect,
            viewBounds: bounds,
            drawableSize: CGSize(
                width: drawable.texture.width,
                height: drawable.texture.height
            )
        )
        encoder.setViewport(
            MTLViewport(
                originX: viewport.origin.x,
                originY: viewport.origin.y,
                width: viewport.width,
                height: viewport.height,
                znear: 0,
                zfar: 1
            )
        )
        encoder.setRenderPipelineState(
            pipelineStates[filter] ?? fallbackPipelineState
        )
        encoder.setFragmentTexture(textures.current, index: 0)
        if filter.usesFrameHistory {
            // On the first frame both bindings intentionally point at the
            // current image, which makes persistence a no-op until a genuine
            // prior emulated frame exists.
            encoder.setFragmentTexture(
                textures.previous ?? textures.current,
                index: 1
            )
        }
        // The filters need the on-screen size of a source pixel, which is the
        // viewport the layout just chose rather than the whole drawable.
        var uniforms = LibretroVideoUniforms(
            sourceWidth: Float(frame.width),
            sourceHeight: Float(frame.height),
            targetWidth: Float(viewport.width),
            targetHeight: Float(viewport.height)
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<LibretroVideoUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The part of the view the title bar and toolbar do not cover.
    ///
    /// The view deliberately extends underneath them, so that a toolbar
    /// revealing itself on hover in full screen never resizes the drawable
    /// mid-game. The picture therefore has to be placed against this rather
    /// than against the whole view, or its top edge ends up behind the
    /// toolbar.
    private var visibleContentBounds: CGRect {
        guard let window, let contentView = window.contentView else {
            return bounds
        }
        let layoutRect = contentView.convert(
            window.contentLayoutRect,
            to: self
        )
        let visible = bounds.intersection(layoutRect)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            return bounds
        }
        return visible
    }

    /// Where the picture lands on screen, in view points.
    ///
    /// Rendering and pointer mapping both read this, so a game cannot end up
    /// drawing the picture in one place while reading the mouse against
    /// another.
    private func pictureRect(
        forSourceSize sourceSize: CGSize,
        aspectRatio: CGFloat
    ) -> CGRect {
        let contentBounds = visibleContentBounds
        return LibretroVideoLayout.pictureRect(
            sourceSize: sourceSize,
            visibleBounds: contentBounds,
            aspectRatio: aspectRatio
        )
    }

    private func textures(
        for snapshot: LibretroVideoSnapshot
    ) -> (current: MTLTexture, previous: MTLTexture?)? {
        let frame = snapshot.frame
        if
            sourceTextures.first?.width != frame.width
                || sourceTextures.first?.height != frame.height
                || sourceTextures.count != 3
        {
            guard allocateSourceTextures(for: frame) else {
                return nil
            }
        }

        if lastUploadedFrameRevision != snapshot.revision {
            let writeIndex: Int
            if let currentSourceTextureIndex {
                writeIndex = sourceTextures.indices.first {
                    $0 != currentSourceTextureIndex
                        && $0 != previousSourceTextureIndex
                } ?? 0
                previousSourceTextureIndex = currentSourceTextureIndex
            } else {
                writeIndex = 0
            }

            let texture = sourceTextures[writeIndex]
            frame.pixels.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: frame.width * 4
                )
            }
            currentSourceTextureIndex = writeIndex
            lastUploadedFrameRevision = snapshot.revision
        }

        guard let currentSourceTextureIndex else {
            return nil
        }
        let previous = previousSourceTextureIndex.map {
            sourceTextures[$0]
        }
        return (sourceTextures[currentSourceTextureIndex], previous)
    }

    private func allocateSourceTextures(
        for frame: LibretroVideoFrame
    ) -> Bool {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead

        sourceTextures = (0..<3).compactMap { index in
            let texture = device?.makeTexture(descriptor: descriptor)
            texture?.label = "RetroVault Libretro frame \(index + 1)"
            return texture
        }
        currentSourceTextureIndex = nil
        previousSourceTextureIndex = nil
        lastUploadedFrameRevision = nil
        return sourceTextures.count == 3
    }

    private func updatePointingDevices(with event: NSEvent) {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let picture = pictureRect(
            forSourceSize: sourceSize,
            aspectRatio: sourceAspectRatio
        )
        let inside = picture.contains(location)
        if inside {
            // AppKit's Y delta is positive upward while Libretro mouse Y is
            // positive downward. DOSBox Pure consumes this relative device;
            // the absolute pointer below remains available to touch cores.
            input.moveMouse(
                deltaX: event.deltaX,
                deltaY: -event.deltaY
            )
        }
        let normalizedX = min(
            max((location.x - picture.minX) / max(picture.width, 1), 0),
            1
        )
        // The picture's top edge is normalized zero, so this counts down from
        // the top while the view counts up from the bottom.
        let normalizedY = min(
            max((picture.maxY - location.y) / max(picture.height, 1), 0),
            1
        )
        input.setPointer(
            x: Int16((normalizedX * 65_534 - 32_767).rounded()),
            y: Int16((normalizedY * 65_534 - 32_767).rounded()),
            pressed: pointerPressed,
            inside: inside
        )
    }

    private func pointerIsOverPicture(_ windowPoint: NSPoint) -> Bool {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return false
        }
        return pictureRect(
            forSourceSize: sourceSize,
            aspectRatio: sourceAspectRatio
        ).contains(convert(windowPoint, from: nil))
    }

}

private enum LibretroMouseID {
    static let left: UInt32 = 2
    static let right: UInt32 = 3
    static let middle: UInt32 = 6
}

struct LibretroVideoLayout {
    /// Places the picture inside the part of the view the window chrome
    /// leaves visible.
    ///
    /// Returned in view points with the origin at the bottom left, which is
    /// how AppKit reports mouse locations, so pointer mapping can compare
    /// against it directly.
    static func pictureRect(
        sourceSize: CGSize,
        visibleBounds: CGRect,
        aspectRatio: CGFloat = 0
    ) -> CGRect {
        let layout = viewport(
            sourceSize: sourceSize,
            targetSize: visibleBounds.size,
            aspectRatio: aspectRatio
        )
        // `layout` measures down from the top of the visible area.
        return CGRect(
            x: visibleBounds.minX + layout.origin.x,
            y: visibleBounds.maxY - layout.origin.y - layout.height,
            width: layout.width,
            height: layout.height
        )
    }

    /// Converts a picture rect in view points into a Metal viewport.
    ///
    /// A Metal viewport is measured in drawable pixels down from the top of
    /// the render target, where an AppKit view is measured in points up from
    /// the bottom.
    static func viewport(
        pictureRect: CGRect,
        viewBounds: CGRect,
        drawableSize: CGSize
    ) -> CGRect {
        let scaleX = viewBounds.width > 0
            ? drawableSize.width / viewBounds.width
            : 1
        let scaleY = viewBounds.height > 0
            ? drawableSize.height / viewBounds.height
            : 1
        return CGRect(
            x: (pictureRect.minX - viewBounds.minX) * scaleX,
            y: (viewBounds.maxY - pictureRect.maxY) * scaleY,
            width: pictureRect.width * scaleX,
            height: pictureRect.height * scaleY
        )
    }

    /// Fits a frame into the drawable.
    ///
    /// `aspectRatio` is what the core says its picture should look like, which
    /// is not always the shape of the buffer it hands over: N64 cores render a
    /// 4:3 picture into buffers whose pixels are not square, so scaling the
    /// buffer directly stretches the image. Pass 0 to derive the ratio from
    /// the buffer, which is right for cores with square pixels.
    static func viewport(
        sourceSize: CGSize,
        targetSize: CGSize,
        aspectRatio: CGFloat = 0
    ) -> CGRect {
        guard
            sourceSize.width > 0,
            sourceSize.height > 0,
            targetSize.width > 0,
            targetSize.height > 0
        else {
            return .zero
        }

        let sourceAspect = sourceSize.width / sourceSize.height
        let displayAspect = aspectRatio > 0 ? aspectRatio : sourceAspect

        // A core whose pixels are not square cannot also be scaled by whole
        // pixels, so correcting the shape takes priority over the crisper
        // integer scale that square-pixel cores keep below.
        guard abs(displayAspect - sourceAspect) <= 0.001 else {
            var width = targetSize.width
            var height = width / displayAspect
            if height > targetSize.height {
                height = targetSize.height
                width = height * displayAspect
            }
            return CGRect(
                x: floor((targetSize.width - width) / 2),
                y: floor((targetSize.height - height) / 2),
                width: floor(width),
                height: floor(height)
            )
        }

        let fittingScale = min(
            targetSize.width / sourceSize.width,
            targetSize.height / sourceSize.height
        )
        let scale = fittingScale >= 1 ? floor(fittingScale) : fittingScale
        let renderedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        return CGRect(
            x: floor((targetSize.width - renderedSize.width) / 2),
            y: floor((targetSize.height - renderedSize.height) / 2),
            width: renderedSize.width,
            height: renderedSize.height
        )
    }
}

private struct LibretroKeyboardCapture: NSViewRepresentable {
    let input: LibretroInputState

    func makeNSView(context: Context) -> LibretroKeyboardView {
        LibretroKeyboardView(input: input)
    }

    func updateNSView(_ nsView: LibretroKeyboardView, context: Context) {}
}

private final class LibretroEventMonitor: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    deinit {
        NSEvent.removeMonitor(value)
    }
}

private final class LibretroKeyboardView: NSView {
    private let input: LibretroInputState
    private var eventMonitor: LibretroEventMonitor?

    init(input: LibretroInputState) {
        self.input = input
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        eventMonitor = nil

        if window != nil {
            let monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .keyUp, .flagsChanged]
            ) { [weak self] event in
                guard let self, window?.isKeyWindow == true else {
                    return event
                }

                if event.type == .flagsChanged {
                    // Modifiers only ever reach a keyboard core, and letting
                    // them through as well keeps the menu shortcuts working
                    // for everything else.
                    guard input.readsKeyboard else {
                        return event
                    }
                    handleFlagsChanged(event)
                    return nil
                }

                if input.readsKeyboard {
                    // Command stays with the system so a keyboard core cannot
                    // swallow Cmd-Q, Cmd-W, or the full-screen shortcut.
                    guard !event.modifierFlags.contains(.command) else {
                        return event
                    }
                    guard let retroKey = LibretroKeyboard.retroKey(
                        forMacKeyCode: event.keyCode
                    ) else {
                        return event
                    }
                    input.setKey(
                        retroKey,
                        pressed: event.type == .keyDown,
                        modifiers: LibretroKeyboardView.modifiers(
                            for: event.modifierFlags
                        )
                    )
                    return nil
                }

                guard
                    event.modifierFlags
                        .intersection([.command, .control, .option])
                        .isEmpty,
                    let button = button(for: event)
                else {
                    return event
                }

                input.setKeyboardButton(
                    button,
                    pressed: event.type == .keyDown
                )
                return nil
            }
            if let monitor {
                eventMonitor = LibretroEventMonitor(monitor)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let button = button(for: event) else {
            super.keyDown(with: event)
            return
        }
        input.setKeyboardButton(button, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let button = button(for: event) else {
            super.keyUp(with: event)
            return
        }
        input.setKeyboardButton(button, pressed: false)
    }

    override func resignFirstResponder() -> Bool {
        input.releaseKeyboard()
        return super.resignFirstResponder()
    }

    /// Turns a modifier state change into the key that must have caused it.
    ///
    /// `flagsChanged` reports which modifiers are now active rather than which
    /// key moved, so the key code on the event identifies the physical key and
    /// the flags say whether it is now down.
    private func handleFlagsChanged(_ event: NSEvent) {
        guard let retroKey = LibretroKeyboard.retroKey(
            forMacKeyCode: event.keyCode
        ) else {
            return
        }

        let flags = event.modifierFlags
        let isDown = switch event.keyCode {
        case 56, 60: flags.contains(.shift)
        case 59, 62: flags.contains(.control)
        case 58, 61: flags.contains(.option)
        case 54, 55: flags.contains(.command)
        case 57: flags.contains(.capsLock)
        default: false
        }

        input.setKey(
            retroKey,
            pressed: isDown,
            modifiers: Self.modifiers(for: flags)
        )
    }

    static func modifiers(
        for flags: NSEvent.ModifierFlags
    ) -> UInt16 {
        var modifiers: UInt16 = 0
        if flags.contains(.shift) {
            modifiers |= LibretroKeyboard.Modifier.shift.rawValue
        }
        if flags.contains(.control) {
            modifiers |= LibretroKeyboard.Modifier.control.rawValue
        }
        if flags.contains(.option) {
            modifiers |= LibretroKeyboard.Modifier.alt.rawValue
        }
        if flags.contains(.command) {
            modifiers |= LibretroKeyboard.Modifier.meta.rawValue
        }
        if flags.contains(.capsLock) {
            modifiers |= LibretroKeyboard.Modifier.capsLock.rawValue
        }
        return modifiers
    }

    private func button(for event: NSEvent) -> LibretroButton? {
        switch event.keyCode {
        case 123:
            .left
        case 124:
            .right
        case 125:
            .down
        case 126:
            .up
        case 36:
            .start
        case 49:
            .select
        case 6:
            .b
        case 7:
            .a
        default:
            nil
        }
    }
}

import AppKit
import MetalKit
import SwiftUI

struct LibretroGameView: View {
    @State private var session: LibretroSession
    @State private var playerWindow: NSWindow?
    @State private var isFullScreen = false
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
                        input: session.input
                    )
                        .ignoresSafeArea()
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
                isFullScreen = window?.styleMask.contains(.fullScreen) == true
            }
            .frame(width: 0, height: 0)
        }
        .task {
            session.start()
        }
        .onDisappear {
            if session.shouldClosePlayer {
                session.stop()
            } else {
                session.exitPlayer()
            }
        }
        .onExitCommand {
            if session.request.playerOrigin == .bigPicture {
                session.exitPlayer()
            } else if isFullScreen {
                playerWindow?.toggleFullScreen(nil)
            } else {
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
        }
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
                            ? "Rewind about one second; hold to continue rewinding"
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
                    .disabled(!isRunning)

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

            Divider()
                .frame(height: 18)
            Text("Hold L3 to rewind · R3 to fast-forward")

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

    private func closePlayer() {
        if let onCloseRequested {
            onCloseRequested()
        } else {
            playerWindow?.performClose(nil)
        }
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

    func makeNSView(context: Context) -> LibretroMTKView {
        LibretroMTKView(videoBuffer: videoBuffer, input: input)
    }

    func updateNSView(_ nsView: LibretroMTKView, context: Context) {}
}

private final class LibretroMTKView: MTKView, MTKViewDelegate {
    private static let cursorIdleInterval: TimeInterval = 1.5

    private let videoBuffer: LibretroVideoBuffer
    private let input: LibretroInputState
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var sourceTexture: MTLTexture?
    private var sourceSize = CGSize.zero
    private var pointerPressed = false
    private var pointerTrackingArea: NSTrackingArea?
    private var cursorHideTask: Task<Void, Never>?
    private var isPointerInside = false

    init(videoBuffer: LibretroVideoBuffer, input: LibretroInputState) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(
                source: LibretroMetalShader.source,
                options: nil
            ),
            let vertexFunction = library.makeFunction(name: "openVaultPixelVertex"),
            let fragmentFunction = library.makeFunction(name: "openVaultPixelFragment")
        else {
            fatalError("OpenVault requires a Metal-capable Apple-silicon Mac.")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "OpenVault nearest-neighbor video"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipelineState = try? device.makeRenderPipelineState(
            descriptor: pipelineDescriptor
        ) else {
            fatalError("OpenVault could not create its Libretro video pipeline.")
        }

        self.videoBuffer = videoBuffer
        self.input = input
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
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
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cursorHideTask?.cancel()
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            restoreCursor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        recordPointerActivity()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        restoreCursor()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerPressed = true
        recordPointerActivity()
        updatePointer(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        recordPointerActivity()
        updatePointer(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        recordPointerActivity()
        updatePointer(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pointerPressed = false
        recordPointerActivity()
        updatePointer(with: event)
    }

    private func recordPointerActivity() {
        NSCursor.setHiddenUntilMouseMoves(false)
        cursorHideTask?.cancel()
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
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func restoreCursor() {
        cursorHideTask?.cancel()
        cursorHideTask = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    func draw(in view: MTKView) {
        guard
            let frame = videoBuffer.snapshot(),
            let drawable = currentDrawable,
            let renderPassDescriptor = currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        guard
            frame.width > 0,
            frame.height > 0,
            frame.pixels.count >= frame.width * frame.height * 4,
            let texture = texture(for: frame)
        else {
            return
        }
        sourceSize = CGSize(width: frame.width, height: frame.height)

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

        let viewport = LibretroVideoLayout.viewport(
            sourceSize: CGSize(width: frame.width, height: frame.height),
            targetSize: CGSize(
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
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func texture(for frame: LibretroVideoFrame) -> MTLTexture? {
        if
            let sourceTexture,
            sourceTexture.width == frame.width,
            sourceTexture.height == frame.height
        {
            return sourceTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        sourceTexture = device?.makeTexture(descriptor: descriptor)
        sourceTexture?.label = "OpenVault Libretro frame"
        return sourceTexture
    }

    private func updatePointer(with event: NSEvent) {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let viewport = LibretroVideoLayout.viewport(
            sourceSize: sourceSize,
            targetSize: bounds.size
        )
        let inside = viewport.contains(location)
        let normalizedX = min(
            max((location.x - viewport.minX) / max(viewport.width, 1), 0),
            1
        )
        let normalizedY = min(
            max((viewport.maxY - location.y) / max(viewport.height, 1), 0),
            1
        )
        input.setPointer(
            x: Int16((normalizedX * 65_534 - 32_767).rounded()),
            y: Int16((normalizedY * 65_534 - 32_767).rounded()),
            pressed: pointerPressed,
            inside: inside
        )
    }

}

enum LibretroMetalShader {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct OpenVaultPixelVertex {
            float4 position [[position]];
            float2 textureCoordinate;
        };

        vertex OpenVaultPixelVertex openVaultPixelVertex(
            uint vertexID [[vertex_id]]
        ) {
            constexpr float2 positions[] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            constexpr float2 textureCoordinates[] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            OpenVaultPixelVertex output;
            output.position = float4(positions[vertexID], 0.0, 1.0);
            output.textureCoordinate = textureCoordinates[vertexID];
            return output;
        }

        fragment float4 openVaultPixelFragment(
            OpenVaultPixelVertex input [[stage_in]],
            texture2d<float> frame [[texture(0)]]
        ) {
            constexpr sampler pixelSampler(
                coord::normalized,
                address::clamp_to_edge,
                mag_filter::nearest,
                min_filter::nearest,
                mip_filter::none
            );
            return frame.sample(pixelSampler, input.textureCoordinate);
        }
        """
}

struct LibretroVideoLayout {
    static func viewport(
        sourceSize: CGSize,
        targetSize: CGSize
    ) -> CGRect {
        guard
            sourceSize.width > 0,
            sourceSize.height > 0,
            targetSize.width > 0,
            targetSize.height > 0
        else {
            return .zero
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
                matching: [.keyDown, .keyUp]
            ) { [weak self] event in
                guard
                    let self,
                    window?.isKeyWindow == true,
                    event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
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

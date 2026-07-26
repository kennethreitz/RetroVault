import AppKit
import CoreImage
import MetalKit
import SwiftUI

struct LibretroGameView: View {
    @State private var session: LibretroSession

    init(request: LibretroRunRequest) {
        _session = State(initialValue: LibretroSession(request: request))
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            switch session.phase {
            case .idle, .starting:
                ProgressView("Starting \(session.request.title)…")
                    .controlSize(.large)
                    .foregroundStyle(.white)
            case .running:
                LibretroMetalView(videoBuffer: session.videoBuffer)
                    .ignoresSafeArea()
            case .stopped:
                ContentUnavailableView {
                    Label("Session Ended", systemImage: "stop.circle")
                } description: {
                    Text("Your local save memory has been preserved.")
                } actions: {
                    Button("Play Again") {
                        session.start()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t Start Libretro", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                        .frame(maxWidth: 520)
                } actions: {
                    Button("Try Again") {
                        session.start()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            }

            if case .running = session.phase {
                controls
            }

            LibretroKeyboardCapture(input: session.input)
                .frame(width: 1, height: 1)
                .opacity(0.001)
        }
        .navigationTitle(session.request.title)
        .frame(minWidth: 640, minHeight: 480)
        .task {
            session.start()
        }
        .onDisappear {
            session.stop()
        }
        .onExitCommand {
            session.stop()
        }
        .toolbar {
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
                    NSApplication.shared.keyWindow?.toggleFullScreen(nil)
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Button(role: .destructive) {
                    session.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!isRunning)
            }
        }
    }

    private var controls: some View {
        VStack {
            Spacer()

            HStack(spacing: 14) {
                if session.isPaused {
                    Label("Paused", systemImage: "pause.fill")
                        .fontWeight(.semibold)
                } else {
                    Text("Arrow keys or D-pad to move")
                }

                if let message = session.message {
                    Divider()
                        .frame(height: 18)
                    Text(message)
                }

                Spacer()

                if case let .running(coreName, framesPerSecond) = session.phase {
                    Text(coreName)
                    Text("\(framesPerSecond.formatted(.number.precision(.fractionLength(0)))) FPS")
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.72), in: Capsule())
            .padding()
        }
    }

    private var isRunning: Bool {
        if case .running = session.phase {
            return true
        }
        return false
    }
}

private struct LibretroMetalView: NSViewRepresentable {
    let videoBuffer: LibretroVideoBuffer

    func makeNSView(context: Context) -> LibretroMTKView {
        LibretroMTKView(videoBuffer: videoBuffer)
    }

    func updateNSView(_ nsView: LibretroMTKView, context: Context) {}
}

private final class LibretroMTKView: MTKView, MTKViewDelegate {
    private let videoBuffer: LibretroVideoBuffer
    private let coreImageContext: CIContext
    private let commandQueue: MTLCommandQueue
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(videoBuffer: LibretroVideoBuffer) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            fatalError("OpenVault requires a Metal-capable Apple-silicon Mac.")
        }

        self.videoBuffer = videoBuffer
        self.commandQueue = commandQueue
        coreImageContext = CIContext(mtlDevice: device)
        super.init(frame: .zero, device: device)

        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let frame = videoBuffer.snapshot(),
            let drawable = currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let targetSize = CGSize(
            width: drawable.texture.width,
            height: drawable.texture.height
        )
        let targetBounds = CGRect(origin: .zero, size: targetSize)
        let background = CIImage(color: .black).cropped(to: targetBounds)
        coreImageContext.render(
            background,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: targetBounds,
            colorSpace: colorSpace
        )

        let sourceSize = CGSize(width: frame.width, height: frame.height)
        var image = CIImage(
            bitmapData: frame.pixels,
            bytesPerRow: frame.width * 4,
            size: sourceSize,
            format: .BGRA8,
            colorSpace: colorSpace
        )

        let scale = min(
            targetSize.width / sourceSize.width,
            targetSize.height / sourceSize.height
        )
        let renderedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let origin = CGPoint(
            x: (targetSize.width - renderedSize.width) / 2,
            y: (targetSize.height - renderedSize.height) / 2
        )
        image = image.transformed(
            by: CGAffineTransform(translationX: origin.x, y: origin.y)
                .scaledBy(x: scale, y: scale)
        )

        coreImageContext.render(
            image,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: targetBounds,
            colorSpace: colorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
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

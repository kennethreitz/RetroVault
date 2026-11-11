import AppKit
import Metal
import QuartzCore
import SwiftUI

/// The `CAMetalLayer` a Vulkan session presents into.
///
/// The layer exists for the whole player lifetime, not only once the core is
/// running: a Libretro Vulkan core asks for its context during
/// `retro_load_game`, and the frontend's `VkSurfaceKHR` needs this layer
/// before the phase changes to `.running`.
final class LibretroVulkanSurface: @unchecked Sendable {
    let layer = CAMetalLayer()

    private let sizeLock = NSLock()
    private var size = CGSize.zero

    init() {
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
        layer.allowsNextDrawableTimeout = false
        layer.displaySyncEnabled =
            !LibretroVulkanPreferences.usesLowestLatency()
    }

    /// Drawable size in pixels, read by the render queue.
    var pixelSize: CGSize {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return size
    }

    /// Called from the view on the main thread.
    func update(bounds: CGSize, scale: CGFloat) {
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))

        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: width, height: height)

        sizeLock.lock()
        size = CGSize(width: width, height: height)
        sizeLock.unlock()
    }

    /// The bridge calls this before creating the swapchain. The layer's
    /// format has to match the swapchain's sRGB-ness, or the picture doubles
    /// or drops the transfer function. The bridge runs on the render queue.
    func setLayerSRGB(_ srgb: Bool) {
        let update = { [layer] in
            layer.pixelFormat = srgb ? .bgra8Unorm_srgb : .bgra8Unorm
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.sync(execute: update)
        }
    }
}

final class LibretroVulkanView: NSView {
    private let surface: LibretroVulkanSurface

    init(surface: LibretroVulkanSurface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        surface.layer.delegate = self
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        true
    }

    /// The keyboard capture and the player controls own input. This view is
    /// only a presentation surface.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        surface.layer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        surface.update(
            bounds: bounds.size,
            scale: window?.backingScaleFactor ?? 1
        )
    }
}

extension LibretroVulkanView: CALayerDelegate {}

struct LibretroVulkanSurfaceView: NSViewRepresentable {
    let surface: LibretroVulkanSurface

    func makeNSView(context: Context) -> LibretroVulkanView {
        LibretroVulkanView(surface: surface)
    }

    func updateNSView(_ nsView: LibretroVulkanView, context: Context) {}
}

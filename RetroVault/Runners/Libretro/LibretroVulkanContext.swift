import Darwin
import Foundation

private typealias VulkanLayerFormatCallback =
    @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void

@_silgen_name("rv_vulkan_create")
private func rvVulkanCreate(
    _ libraryPath: UnsafePointer<CChar>?,
    _ metalLayer: UnsafeMutableRawPointer?,
    _ layerFormat: VulkanLayerFormatCallback?,
    _ layerContext: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<CChar>?,
    _ errorSize: Int
) -> OpaquePointer?

@_silgen_name("rv_vulkan_set_negotiation")
private func rvVulkanSetNegotiation(
    _ context: OpaquePointer?,
    _ interface: UnsafeRawPointer?
)

@_silgen_name("rv_vulkan_start")
private func rvVulkanStart(
    _ context: OpaquePointer?,
    _ error: UnsafeMutablePointer<CChar>?,
    _ errorSize: Int
) -> Bool

@_silgen_name("rv_vulkan_interface")
private func rvVulkanInterface(_ context: OpaquePointer?)
    -> UnsafeMutableRawPointer?

@_silgen_name("rv_vulkan_set_drawable_size")
private func rvVulkanSetDrawableSize(
    _ context: OpaquePointer?,
    _ width: UInt32,
    _ height: UInt32
)

@_silgen_name("rv_vulkan_begin_frame")
private func rvVulkanBeginFrame(
    _ context: OpaquePointer?,
    _ error: UnsafeMutablePointer<CChar>?,
    _ errorSize: Int
) -> Bool

@_silgen_name("rv_vulkan_present")
private func rvVulkanPresent(
    _ context: OpaquePointer?,
    _ width: UInt32,
    _ height: UInt32,
    _ aspectRatio: Float,
    _ error: UnsafeMutablePointer<CChar>?,
    _ errorSize: Int
) -> Bool

@_silgen_name("rv_vulkan_destroy")
private func rvVulkanDestroy(_ context: OpaquePointer?)

private let libretroVulkanLayerFormatCallback:
    @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void = {
        context,
        srgb in
        guard let context else {
            return
        }
        Unmanaged<LibretroVulkanSurface>
            .fromOpaque(context)
            .takeUnretainedValue()
            .setLayerSRGB(srgb)
    }

enum LibretroVulkanError: LocalizedError {
    case moltenVKMissing
    case contextCreation(String)
    case initialization(String)
    case presentation(String)

    var errorDescription: String? {
        switch self {
        case .moltenVKMissing:
            "This build does not include the MoltenVK runtime."
        case let .contextCreation(reason):
            "Could not create the Vulkan context: \(reason)"
        case let .initialization(reason):
            "Could not initialize Vulkan: \(reason)"
        case let .presentation(reason):
            "Could not present the Vulkan frame: \(reason)"
        }
    }
}

/// One Libretro Vulkan session's frontend context.
final class LibretroVulkanContext: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let surface: LibretroVulkanSurface

    let libraryPath: String

    static var bundledLibraryURL: URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[
            "RETROVAULT_MOLTENVK_PATH"
        ], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        #endif

        let candidates = [
            Bundle.main.privateFrameworksURL?
                .appending(path: "libMoltenVK.dylib"),
            Bundle.main.bundleURL
                .appending(path: "Contents/Frameworks/libMoltenVK.dylib"),
        ]
        return candidates.compactMap(\.self).first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Loads the dylib before the core does, and points its own loader at the
    /// same copy. ARMSX2's Vulkan loader consults `LIBVULKAN_PATH` first.
    static func prepareEnvironment() {
        guard let url = bundledLibraryURL else {
            return
        }
        setenv("LIBVULKAN_PATH", url.path, 0)
        _ = dlopen(url.path, RTLD_LAZY | RTLD_LOCAL)
    }

    init(surface: LibretroVulkanSurface) throws {
        guard let url = Self.bundledLibraryURL else {
            throw LibretroVulkanError.moltenVKMissing
        }
        self.surface = surface
        libraryPath = url.path

        let layerPointer = Unmanaged.passUnretained(surface.layer).toOpaque()
        let surfacePointer = Unmanaged.passUnretained(surface).toOpaque()

        var error = [CChar](repeating: 0, count: 512)
        let context = url.path.withCString { path in
            error.withUnsafeMutableBufferPointer { buffer in
                rvVulkanCreate(
                    path,
                    layerPointer,
                    libretroVulkanLayerFormatCallback,
                    surfacePointer,
                    buffer.baseAddress,
                    buffer.count
                )
            }
        }
        guard let context else {
            throw LibretroVulkanError.contextCreation(Self.message(error))
        }
        handle = context
    }

    deinit {
        destroy()
    }

    func setNegotiationInterface(_ pointer: UnsafeRawPointer?) {
        rvVulkanSetNegotiation(handle, pointer)
    }

    func start() throws {
        var error = [CChar](repeating: 0, count: 512)
        let started = error.withUnsafeMutableBufferPointer { buffer in
            rvVulkanStart(handle, buffer.baseAddress, buffer.count)
        }
        guard started else {
            throw LibretroVulkanError.initialization(Self.message(error))
        }
    }

    /// The pointer handed to the core for `GET_HW_RENDER_INTERFACE`.
    func interfacePointer() -> UnsafeMutableRawPointer? {
        rvVulkanInterface(handle)
    }

    /// Acquires this frame's swapchain image before the core runs.
    func beginFrame() {
        var error = [CChar](repeating: 0, count: 512)
        let began = error.withUnsafeMutableBufferPointer { buffer in
            rvVulkanBeginFrame(handle, buffer.baseAddress, buffer.count)
        }
        if !began {
            RetroVaultLog.libretro.error(
                "Vulkan frame acquisition failed: \(Self.message(error), privacy: .public)"
            )
        }
    }

    func present(width: Int, height: Int, aspectRatio: Float) throws {
        let size = surface.pixelSize
        rvVulkanSetDrawableSize(
            handle,
            UInt32(clamping: Int(size.width)),
            UInt32(clamping: Int(size.height))
        )

        var error = [CChar](repeating: 0, count: 512)
        let presented = error.withUnsafeMutableBufferPointer { buffer in
            rvVulkanPresent(
                handle,
                UInt32(clamping: max(0, width)),
                UInt32(clamping: max(0, height)),
                aspectRatio,
                buffer.baseAddress,
                buffer.count
            )
        }
        guard presented else {
            throw LibretroVulkanError.presentation(Self.message(error))
        }
    }

    func destroy() {
        lock.lock()
        let context = handle
        handle = nil
        lock.unlock()
        if let context {
            rvVulkanDestroy(context)
        }
    }

    private static func message(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else {
                return "unknown error"
            }
            let message = String(cString: base)
            return message.isEmpty ? "unknown error" : message
        }
    }
}

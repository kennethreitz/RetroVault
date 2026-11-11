import AppKit
import Foundation
import Testing
@testable import RetroVault

@Suite("Vulkan environment")
struct LibretroVulkanEnvironmentTests {
    /// Skipped unless the test process was started with the pinned MoltenVK
    /// path. The app always has it embedded; `swift test` does not.
    private var moltenVKPath: String? {
        guard
            let path = ProcessInfo.processInfo.environment[
                "RETROVAULT_MOLTENVK_PATH"
            ],
            FileManager.default.fileExists(atPath: path)
        else {
            return nil
        }
        return path
    }

    @Test("A Vulkan core is offered the Vulkan context and interface")
    @MainActor
    func vulkanEnvironment() throws {
        guard moltenVKPath != nil else {
            return
        }

        let temporary = FileManager.default.temporaryDirectory
            .appending(
                path: "RetroVaultVulkanEnvironment-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }

        let surface = LibretroVulkanSurface()
        let environment = LibretroEnvironment(
            systemDirectory: temporary,
            saveDirectory: temporary,
            assetsDirectory: temporary,
            internalResolution: .native,
            capabilities: ["vulkanVideo", "audio", "retropad"],
            prefersVulkan: true,
            vulkanSurface: surface
        )
        defer {
            environment.destroyHardwareRenderer()
        }

        var preferred: Int32 = -1
        withUnsafeMutableBytes(of: &preferred) { bytes in
            #expect(
                environment.handle(
                    command: 56,
                    data: bytes.baseAddress
                )
            )
        }
        #expect(preferred == 6)

        var callback = RetroHardwareRenderCallback(
            contextType: 6,
            contextReset: nil,
            getCurrentFramebuffer: nil,
            getProcAddress: nil,
            depth: false,
            stencil: false,
            bottomLeftOrigin: false,
            versionMajor: 1,
            versionMinor: 1,
            cacheContext: true,
            contextDestroy: nil,
            debugContext: false
        )
        withUnsafeMutableBytes(of: &callback) { bytes in
            #expect(
                environment.handle(
                    command: 14,
                    data: bytes.baseAddress
                )
            )
        }
        #expect(environment.usesVulkan)

        #expect(environment.activateHardwareRenderer())

        var interface: UnsafeMutableRawPointer?
        withUnsafeMutableBytes(of: &interface) { bytes in
            #expect(
                environment.handle(
                    command: 65_577,
                    data: bytes.baseAddress
                )
            )
        }
        #expect(interface != nil)
    }

    @Test("A core without the capability is not offered Vulkan")
    @MainActor
    func capabilityGatesVulkan() throws {
        let temporary = FileManager.default.temporaryDirectory
        let environment = LibretroEnvironment(
            systemDirectory: temporary,
            saveDirectory: temporary,
            assetsDirectory: temporary,
            internalResolution: .native,
            capabilities: ["hardwareVideo", "audio"],
            prefersVulkan: true,
            vulkanSurface: LibretroVulkanSurface()
        )

        var preferred: Int32 = -1
        withUnsafeMutableBytes(of: &preferred) { bytes in
            #expect(
                environment.handle(
                    command: 56,
                    data: bytes.baseAddress
                )
            )
        }
        #expect(preferred != 6)
    }

    @Test("The Vulkan preference defaults off and follows the override")
    func preferenceDefault() {
        let suiteName = "RetroVaultVulkanPreference-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create a defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        #expect(
            LibretroVulkanPreferences.prefersVulkan(defaults: defaults)
                == LibretroVulkanPreferences.prefersVulkanByDefault
        )
        defaults.set(
            true,
            forKey: LibretroVulkanPreferences.prefersVulkanKey
        )
        #expect(
            LibretroVulkanPreferences.prefersVulkan(defaults: defaults)
        )
        #expect(
            !LibretroVulkanPreferences.usesLowestLatency(
                defaults: defaults
            )
        )
        defaults.set(
            true,
            forKey: LibretroVulkanPreferences.lowestLatencyKey
        )
        #expect(
            LibretroVulkanPreferences.usesLowestLatency(
                defaults: defaults
            )
        )
    }

    @Test("A Vulkan frame can be acquired and presented")
    @MainActor
    func vulkanFramePresentation() throws {
        guard moltenVKPath != nil else {
            return
        }
        _ = NSApplication.shared

        let temporary = FileManager.default.temporaryDirectory
        let surface = LibretroVulkanSurface()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = LibretroVulkanView(surface: surface)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        window.contentView = view
        surface.update(
            bounds: CGSize(width: 320, height: 240),
            scale: 1
        )

        let environment = LibretroEnvironment(
            systemDirectory: temporary,
            saveDirectory: temporary,
            assetsDirectory: temporary,
            internalResolution: .native,
            capabilities: ["vulkanVideo", "audio", "retropad"],
            prefersVulkan: true,
            vulkanSurface: surface
        )
        defer {
            environment.destroyHardwareRenderer()
            window.contentView = nil
        }

        var callback = RetroHardwareRenderCallback(
            contextType: 6,
            contextReset: nil,
            getCurrentFramebuffer: nil,
            getProcAddress: nil,
            depth: false,
            stencil: false,
            bottomLeftOrigin: false,
            versionMajor: 1,
            versionMinor: 1,
            cacheContext: true,
            contextDestroy: nil,
            debugContext: false
        )
        withUnsafeMutableBytes(of: &callback) { bytes in
            #expect(
                environment.handle(
                    command: 14,
                    data: bytes.baseAddress
                )
            )
        }
        #expect(environment.activateHardwareRenderer())
        environment.beginHardwareFrame()
        #expect(environment.presentHardwareFrame(width: 0, height: 0))

        // A drawable-size change goes through swapchain teardown and rebuild.
        surface.update(
            bounds: CGSize(width: 640, height: 480),
            scale: 1
        )
        environment.beginHardwareFrame()
        #expect(environment.presentHardwareFrame(width: 0, height: 0))

        surface.update(
            bounds: CGSize(width: 200, height: 150),
            scale: 2
        )
        environment.beginHardwareFrame()
        #expect(environment.presentHardwareFrame(width: 0, height: 0))
    }

    @Test("The preference gates a Vulkan-capable core")
    @MainActor
    func preferenceGatesVulkan() throws {
        let temporary = FileManager.default.temporaryDirectory
        let environment = LibretroEnvironment(
            systemDirectory: temporary,
            saveDirectory: temporary,
            assetsDirectory: temporary,
            internalResolution: .native,
            capabilities: ["vulkanVideo", "audio"],
            prefersVulkan: false,
            vulkanSurface: LibretroVulkanSurface()
        )

        var preferred: Int32 = -1
        withUnsafeMutableBytes(of: &preferred) { bytes in
            #expect(
                environment.handle(
                    command: 56,
                    data: bytes.baseAddress
                )
            )
        }
        #expect(preferred != 6)
    }
}

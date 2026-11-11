import Testing
@testable import RetroVault

@_silgen_name("rv_abi_hw_render_callback_size")
private func rvABIHardwareRenderCallbackSize() -> Int

@_silgen_name("rv_abi_hw_render_callback_context_type_offset")
private func rvABIContextTypeOffset() -> Int

@_silgen_name("rv_abi_hw_render_callback_context_reset_offset")
private func rvABIContextResetOffset() -> Int

@_silgen_name("rv_abi_hw_render_callback_get_current_framebuffer_offset")
private func rvABIGetCurrentFramebufferOffset() -> Int

@_silgen_name("rv_abi_hw_render_callback_get_proc_address_offset")
private func rvABIGetProcAddressOffset() -> Int

@_silgen_name("rv_abi_hw_render_callback_depth_offset")
private func rvABIDepthOffset() -> Int

@_silgen_name("rv_abi_hw_render_callback_version_major_offset")
private func rvABIVersionMajorOffset() -> Int

@_silgen_name("rv_abi_hw_render_callback_cache_context_offset")
private func rvABICacheContextOffset() -> Int

@_silgen_name("rv_abi_hw_render_callback_context_destroy_offset")
private func rvABIContextDestroyOffset() -> Int

@_silgen_name("rv_abi_hw_render_callback_debug_context_offset")
private func rvABIDebugContextOffset() -> Int

@_silgen_name("rv_abi_vulkan_context_value")
private func rvABIVulkanContextValue() -> Int

@_silgen_name("rv_abi_vulkan_interface_version")
private func rvABIVulkanInterfaceVersion() -> Int

@Suite("Vulkan Libretro ABI")
struct LibretroVulkanABITests {
    @Test("The Swift hardware callback mirror matches libretro.h")
    func hardwareRenderCallbackLayout() {
        let layout = MemoryLayout<RetroHardwareRenderCallback>.self
        // C sizeof includes trailing padding; Swift's stride is the
        // equivalent value. The offsets below are the load-bearing check.
        #expect(layout.stride == rvABIHardwareRenderCallbackSize())
        #expect(
            layout.offset(of: \.contextType) == rvABIContextTypeOffset()
        )
        #expect(
            layout.offset(of: \.contextReset) == rvABIContextResetOffset()
        )
        #expect(
            layout.offset(of: \.getCurrentFramebuffer)
                == rvABIGetCurrentFramebufferOffset()
        )
        #expect(
            layout.offset(of: \.getProcAddress)
                == rvABIGetProcAddressOffset()
        )
        #expect(layout.offset(of: \.depth) == rvABIDepthOffset())
        #expect(
            layout.offset(of: \.versionMajor) == rvABIVersionMajorOffset()
        )
        #expect(
            layout.offset(of: \.cacheContext)
                == rvABICacheContextOffset()
        )
        #expect(
            layout.offset(of: \.contextDestroy)
                == rvABIContextDestroyOffset()
        )
        #expect(
            layout.offset(of: \.debugContext) == rvABIDebugContextOffset()
        )
    }

    @Test("The Vulkan context and interface constants match libretro.h")
    func constants() {
        #expect(rvABIVulkanContextValue() == 6)
        #expect(rvABIVulkanInterfaceVersion() == 5)
    }
}

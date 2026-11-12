# Vulkan runtime (Phase 1)

RetroVault can load Libretro cores that ask for a Vulkan hardware context.
The first implementation is a proof of concept: the runtime, a content-free
smoke core, and the packaging exist; no user-facing core is enabled yet.

## What works

- `SET_HW_RENDER` accepts `RETRO_HW_CONTEXT_VULKAN` when the core's manifest
  entry declares `vulkanVideo` and Settings → Emulation → "Prefer Vulkan for
  Vulkan-capable cores" is on. The preference is off by default.
- `GET_PREFERRED_HW_RENDER` answers Vulkan only for those cores.
- `GET_HW_RENDER_INTERFACE` returns a v5
  `retro_hw_render_interface_vulkan`; context negotiation v1
  (`create_device`) is honoured, with a frontend device as the fallback.
- The swapchain image is acquired **before** `retro_run`, so cores that call
  `get_sync_index` while rendering (PPSSPP) see the image they will present.
  Duplicate frames (`video_cb(NULL)`) re-present the last image instead of
  leaking the acquired one.
- `set_image` frames are presented through a MoltenVK swapchain on the
  player's `CAMetalLayer` with `vkCmdBlitImage`. `get_sync_index`,
  `get_sync_index_mask`, `set_command_buffers`, `wait_sync_index`,
  `lock_queue`, `unlock_queue`, and `set_signal_semaphore` are implemented.
  The image handoff is locked, because a core may call `set_image` from its
  GPU thread while `retro_run` presents.
- Resize, fullscreen, minimize, and teardown are handled. `context_destroy`
  runs before `retro_unload_game` (PPSSPP deletes its graphics context during
  unload), and the Vulkan device is destroyed only after the core has
  unloaded.
- MoltenVK 1.4.2 is pinned and embedded by `Scripts/fetch-moltenvk.sh` and
  `Scripts/embed-moltenvk.sh`; Vita3K builds against the same version.

## Layout

- `RetroVault/Runners/Libretro/Vulkan/LibretroVulkanBridge.c` — instance,
  surface, device, swapchain, presentation, Libretro callbacks.
- `RetroVault/Runners/Libretro/LibretroVulkanContext.swift` — Swift wrapper,
  MoltenVK path and `LIBVULKAN_PATH` preload.
- `RetroVault/Runners/Libretro/LibretroVulkanSurface.swift` —
  `CAMetalLayer` and `NSView`.
- `RetroVault/Runners/Libretro/LibretroRuntime.swift` — environment commands,
  renderer selection, lifecycle, video callback.
- `Tests/Fixtures/VulkanTestCore/vulkan_test_core.c` and
  `Scripts/build-vulkan-test-core.sh` — content-free smoke core.
- `RetroVaultTests/LibretroVulkanABITests.swift` — Swift/`libretro.h` callback
  layout checks.

## Verification

```sh
Scripts/fetch-moltenvk.sh
RETROVAULT_MOLTENVK_PATH="$PWD/Build/MoltenVK/libMoltenVK.dylib" \
  swift test --filter LibretroVulkan
```

`Tests/Fixtures/VulkanTestCore` and `Scripts/build-vulkan-test-core.sh` are a
developer fixture for manual harness work. The fixture is not listed in the
catalog and is not exposed in the app.

PPSSPP is the first real-core target. It already selects its backend from
`GET_PREFERRED_HW_RENDER`, so enabling the preference and using a PSP ISO is
enough; no PPSSPP core option is forced. Build its core with
`Scripts/build-libretro-cores.sh --core libretro-ppsspp`.

PPSSPP is pinned to `39205d99ad2ede48be878659f4021fda9e5ec858` (2026-10-16)
rather than the previous v1.20.4 release. v1.20.4 still used the old
`libretro_vulkan.cpp` wrapper and called `vk->InitSwapchain`; its render
manager then entered `vkCmdBeginRenderPass` with no backbuffer and crashed in
MoltenVK. The newer `LibretroVulkanPresentation` backend implements the
shared-context contract this runtime provides: `get_sync_index`/
`set_image` on the frontend's queue, with the acquire before `retro_run`.

Settings → Emulation → **Lowest latency (may tear)** disables display vsync
on the Vulkan layer. It removes roughly one frame of input latency at the
cost of possible tearing; restart the game after changing it.

Settings → Emulation → **Buffer PPSSPP frames** restores PPSSPP's upstream
one-frame render-ahead buffer. It is off by default for lower input latency;
turning it on can be smoother on demanding titles. Restart the game.

## Not done (Phase 2+)

- The 3DS core entry, its build arguments, and its firmware/resource
  handling.
- Core-options v2. Both scoped cores fall back to `SET_VARIABLES`, so the
  renderer option is currently a flat list.
- The Metal video filters and integer-scaling presets. Vulkan presentation
  uses nearest for integral scales and linear otherwise.
- `create_device2` (v2 negotiation). Cores that only provide it fall back to
  a frontend-created device.
- Cross-queue-family image handover; formats other than 8-bit RGBA/BGRA;
  HDR; `set_command_buffers` coverage from a real core.
- An ARMSX2 entry. Its libretro core is Vulkan-only on macOS, needs
  `pcsx2/resources` matched to the build, and asks for entitlements
  (`allow-unsigned-executable-memory`) this app does not carry. PlayStation 2
  ships through LRPS2 on the OpenGL path instead.
- A PR, a manifest entry, and release/notarization validation with a
  Developer ID identity.

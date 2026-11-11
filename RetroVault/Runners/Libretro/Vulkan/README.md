# Vulkan and Libretro headers

`RetroVaultVulkanBridge.c` is compiled against headers fetched at build time
into `Build/MoltenVK/include`. They are not committed to the repository.
`RetroVaultVulkanBridge.h` is RetroVault's own C API.

## Fetching

`Scripts/fetch-moltenvk.sh` downloads the pinned **MoltenVK 1.4.2** macOS
tarball and keeps its `include/vulkan` and `include/vk_video` trees. The same
script fetches the two Libretro headers from pinned `libretro-common`
commits:

- `libretro.h` from `d9597c359a5ca8399a4e244f816e7e975a92a2aa`.
- `libretro_vulkan.h` from
  `a0403d4273fbd5ce6971f6f41c90c6df2b02e14b`.

Each download is checked against a SHA-256 recorded in the script.

The Xcode target runs the script in a build phase before Sources. For
`swift build`/`swift test`, run `Scripts/fetch-moltenvk.sh` first (the
verification commands in `docs/vulkan-runtime.md` do).

## Licenses

- Khronos Vulkan headers: Copyright 2015-2026 The Khronos Group Inc.,
  SPDX-License-Identifier: Apache-2.0 OR MIT, Vulkan header version 357.
- Libretro headers: Copyright 2010-2026 The RetroArch team, MIT.

See `THIRD_PARTY_NOTICES.md`.

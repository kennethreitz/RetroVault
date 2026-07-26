# Bundled Libretro Cores

`CoreManifest.json` is the reviewed source of truth for every libretro binary
that may ship with OpenVault.

The manifest includes a content-free 2048 pipeline test and Gambatte as the
first user-facing core. The test core proves source pinning, ARM64 compilation,
license collection, hashing, signing, and the frontend lifecycle. Gambatte
adds reviewed Game Boy and Game Boy Color support, including ZIP-wrapped games
whose archive contains a supported ROM file.

## Core states

- `pipelineTest`: built and packaged to validate the toolchain, but never
  selected for a user's RomM game.
- `bundled`: a reviewed, user-facing core that is included in OpenVault.
- `planned`: recorded for review but excluded from build artifacts.
- `excluded`: documented but prohibited from build artifacts.

A `bundled` entry must have approved redistribution status, a full source
revision, a license notice, deterministic build arguments, and a declared set
of frontend capabilities.

## Commands

Validate the manifest:

```sh
Scripts/validate-libretro-cores.sh
```

Build and ad-hoc sign every enabled core:

```sh
Scripts/build-libretro-cores.sh
```

Build one core:

```sh
Scripts/build-libretro-cores.sh --core libretro-2048
Scripts/build-libretro-cores.sh --core libretro-gambatte
```

Build release artifacts with a Developer ID identity:

```sh
OPENVAULT_CORE_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
  Scripts/build-libretro-cores.sh
```

Generated artifacts are written to `Build/LibretroCores` and are intentionally
not committed. The OpenVault Xcode target embeds their core binaries under the
application's `Contents/PlugIns/Libretro` directory and their manifest,
receipt, and license notices under `Contents/Resources/Libretro`. Development
builds may omit the artifacts; Release builds fail until the pipeline has
produced them.

## Runtime smoke tests

Open Settings → Emulation → Open 2048 Runtime Test to exercise the player
without game content.

Debug builds can expose a local Gambatte test without adding file-picker or
library-import behavior:

```sh
OPENVAULT_LIBRETRO_TEST_ROM="/path/to/test.gb" \
  /path/to/OpenVault.app/Contents/MacOS/OpenVault
```

This adds a debug-only Settings button. Release builds launch game content only
through compatible RomM details.

## Adding a core

1. Confirm the core can be redistributed under OpenVault's release model.
2. Pin a full Git commit rather than a branch or tag.
3. Declare the content systems, extensions, firmware, and frontend
   capabilities accurately.
4. Add deterministic ARM64 build instructions.
5. Validate and build locally.
6. Add frontend compatibility coverage before changing the status to
   `bundled`.

OpenVault never packages games, firmware, BIOS files, or cryptographic keys.

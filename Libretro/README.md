# Bundled Libretro Cores

`CoreManifest.json` is the reviewed source of truth for every libretro binary
that may ship with OpenVault.

The manifest includes a content-free 2048 pipeline test plus 25 reviewed
user-facing cores. The current catalog supports Game Boy, Game Boy Color,
Game Boy Advance, NES, SNES, Master System, Game Gear, SG-1000, Atari 2600,
Atari 5200, Atari 7800, ColecoVision, Nintendo 64, Arcade, Virtual Boy, Neo Geo
Pocket and Pocket Color, WonderSwan and WonderSwan Color, Pokémon Mini,
PlayStation, Nintendo DS, PC Engine /
TurboGrafx-16, SuperGrafx, PC Engine CD / TurboGrafx-CD, Genesis / Mega Drive,
Sega CD / Mega CD, Sega 32X, DOS, Arduboy, Pico-8, GameCube, Wii, and PSP.

The test core proves source pinning, ARM64 compilation, license collection,
hashing, signing, and the frontend lifecycle. User-facing cores additionally
support raw or ZIP-wrapped games whose archive contains one supported ROM
file. Descriptor-based disc sets are also supported: OpenVault prefers the
declared CUE or M3U file and extracts its safe regular-file companions from the
same archive directory. PlayStation prefers M3U/CUE disc descriptors and also
accepts BIN, CHD, ISO, and PBP
content.

## Core states

- `pipelineTest`: built and packaged to validate the toolchain, but never
  selected for a user's RomM game.
- `bundled`: a reviewed, user-facing core that is included in OpenVault.
- `planned`: recorded for review but excluded from build artifacts.
- `excluded`: documented but prohibited from build artifacts.

A `bundled` entry must have approved redistribution status, a full source
revision, a license notice, deterministic build arguments, and a declared set
of frontend capabilities. When a pinned release needs a narrowly scoped
upstream fix, `source.patches` may list full commits from the same repository;
the build tool fetches, verifies, and applies them without creating a new
source revision, and records them in the build receipt.

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
Scripts/build-libretro-cores.sh --core libretro-nestopia
Scripts/build-libretro-cores.sh --core libretro-bsnes-mercury-balanced
Scripts/build-libretro-cores.sh --core libretro-mgba
Scripts/build-libretro-cores.sh --core libretro-melonds
Scripts/build-libretro-cores.sh --core libretro-gearcoleco
Scripts/build-libretro-cores.sh --core libretro-geargrafx
Scripts/build-libretro-cores.sh --core libretro-a5200
Scripts/build-libretro-cores.sh --core libretro-fbneo
Scripts/build-libretro-cores.sh --core libretro-parallel-n64
Scripts/build-libretro-cores.sh --core libretro-genesis-plus-gx
Scripts/build-libretro-cores.sh --core libretro-picodrive
Scripts/build-libretro-cores.sh --core libretro-dosbox-pure
Scripts/build-libretro-cores.sh --core libretro-arduous
Scripts/build-libretro-cores.sh --core libretro-fake08
Scripts/build-libretro-cores.sh --core libretro-dolphin
Scripts/build-libretro-cores.sh --core libretro-ppsspp
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
produced them. Reviewed non-firmware system assets, such as Dolphin's
`dolphin-emu/Sys` data, are embedded under `Contents/Resources/Libretro/System`.

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

Genesis Plus GX, PicoDrive, and FinalBurn Neo use source-available,
noncommercial licenses. They are approved only for OpenVault's free
open-source release model and must be removed or replaced before any paid or
commercial distribution.

## RomM firmware

OpenVault never packages games, firmware, BIOS files, or cryptographic keys in
the application. Firmware comes from the paired RomM server's system-level
firmware records, not from games named `[BIOS]`.

Before launch, OpenVault:

1. Lists firmware for the game's RomM platform using the `firmware.read`
   permission.
2. Matches filenames declared by the selected core's manifest.
3. Downloads matching files through RomM's authenticated firmware-content
   endpoint.
4. Verifies the server-provided SHA-1 and any hashes declared by the manifest.
5. Stores valid files in a server- and platform-scoped Application Support
   cache and supplies that directory to the core.

A cached firmware set remains usable while RomM is offline. Optional firmware
does not block cores with a built-in or HLE fallback; required firmware
produces an actionable launch error when it is absent or invalid. Nestopia's
Famicom Disk System format remains disabled until its multi-file content and
firmware behavior is covered end to end.

Geargrafx uses RomM's `syscard3.pce` system firmware for PC Engine CD content.
HuCard and SuperGrafx games do not require it. CD support initially accepts
single-file CHD images; multi-file CUE sets remain disabled until OpenVault can
prepare their complete track set safely.

Gearcoleco requires RomM's `colecovision.rom` system firmware. OpenVault fetches
and verifies it through the same platform-scoped firmware cache before starting
ColecoVision content.

Dolphin provides GameCube playback through an OpenGL 4.1 Libretro hardware
context, with OpenVault presenting the completed frame through its native Metal
view. Its upstream `Data/Sys` tree is pinned, built, and bundled as runtime
system data; it is not console firmware or game content.

PPSSPP provides PSP playback through the same hardware-rendering frontend and
accepts ISO, CSO, PBP, CHD, ELF, and PRX content. Its pinned `assets` tree is
bundled under `System/PPSSPP`; these are redistributable emulator runtime
assets, not PSP firmware or game content. The stable source pin carries
PPSSPP's upstream macOS Core-profile context fix so its GLSL shaders and
framebuffer presentation are correct on Apple silicon.

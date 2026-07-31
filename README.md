<p align="center">
  <img src="RetroVault/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" alt="RetroVault app icon" width="128" height="128">
</p>

<h1 align="center">RetroVault</h1>

<p align="center">
  <strong>A native macOS library and player for RomM.</strong>
</p>

<p align="center">
  <a href="MILESTONES/README.md"><img src="https://img.shields.io/badge/status-active_development-7657ff?style=flat-square" alt="Active development"></a>
  <img src="https://img.shields.io/badge/macOS-26-111827?style=flat-square&logo=apple" alt="macOS 26">
  <img src="https://img.shields.io/badge/architecture-Apple_silicon-111827?style=flat-square" alt="Apple silicon">
  <img src="https://img.shields.io/badge/Swift-6.2-f05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-2563eb?style=flat-square" alt="GPL-3.0"></a>
</p>

RetroVault is a native macOS client for [RomM](https://romm.app), the
self-hosted game-library manager maintained by
[the RomM Project](https://github.com/rommapp/romm). It connects to one RomM
server, synchronizes its catalog into an offline cache, and presents the
library through a fast, controller-first interface built with SwiftUI.

For supported systems, RetroVault is also a Libretro frontend. It downloads a
game into managed local storage, fetches required firmware and newer saves from
RomM, and runs the game through a bundled Apple-silicon core. Metal video,
Core Audio, native controllers, quick states, rewind, fullscreen play, and
save synchronization are part of the app rather than separate emulator setup.

RomM remains the source of truth. RetroVault does not import or reorganize the
server library. **Download** keeps a managed copy for offline play;
**Export** writes a separate copy outside the app.

> [!IMPORTANT]
> RetroVault is under active development and is not ready for a general release.
> It currently requires macOS 26 on Apple silicon and targets the RomM 5.x API.
> Emulator compatibility and save synchronization still vary by system and
> title.

## What it does

- Synchronizes systems, games, metadata, artwork, favorites, and saves from a
  single RomM server.
- Starts from the last complete local snapshot when RomM or Wi-Fi is
  unavailable.
- Provides controller and keyboard navigation for Recently Played, Recently
  Added, Favorites, Downloaded, and individual systems.
- Sorts, downloads, and exports games without modifying the server's library
  layout.
- Keeps downloaded games, firmware, artwork, and save data in managed local
  storage for offline use.
- Runs reviewed systems through 24 bundled ARM64 Libretro cores.
- Presents software and OpenGL core output through Metal, with native,
  upscaled, and CRT video modes.
- Supports windowed and fullscreen play, macOS Game Mode, two controllers,
  quick-state resume, rewind, fast-forward, and automatic state creation on
  exit where the core supports them.
- Accepts native macOS controllers and DSU/Cemuhook-compatible controller
  servers, including the Switch 2 Pro Controller through
  [Kenneth Reitz's switch2bridge-macos fork](https://github.com/kennethreitz/switch2bridge-macos).
- Refreshes cartridge or memory-card saves before launch and uploads changed
  save data to RomM after play. Quick states remain local.
- Shows live library-sync and bulk-download progress from the Select screen.

## Why preservation matters

A game archive is more than a directory of ROMs. Releases, regions, revisions,
hashes, artwork, manuals, firmware relationships, and player saves all help
document software whose original media, hardware, storefronts, and online
services will not remain available forever.

RetroVault focuses on older systems with maintainable Apple-silicon emulation
paths. A platform is considered supported only when content loading, video,
audio, input, firmware, offline play, and save handling are dependable enough
to be useful. RomM can still catalog newer or unsupported systems; RetroVault
continues to preserve their metadata without claiming that they are playable.

## Reviewed systems

Compatibility still varies by title while RetroVault is in development.

| Family | Systems | Core |
| --- | --- | --- |
| Nintendo | Game Boy, Game Boy Color | Gambatte |
| Nintendo | Game Boy Advance | mGBA |
| Nintendo | NES | Nestopia UE |
| Nintendo | SNES | bsnes-mercury Balanced |
| Nintendo | Nintendo 64 | ParaLLEl-N64 |
| Nintendo | Nintendo DS | melonDS |
| Nintendo | GameCube, Wii | Dolphin |
| Sega | Master System, Game Gear, SG-1000 | Gearsystem |
| Sega | Genesis / Mega Drive, Sega CD / Mega CD | Genesis Plus GX |
| Sega | Sega 32X | PicoDrive |
| Sony | PlayStation | PCSX-ReARMed |
| Sony | PlayStation Portable | PPSSPP |
| NEC | PC Engine / TurboGrafx-16, SuperGrafx, PC Engine CD | Beetle PCE |
| Atari | Atari 2600 | Stella 2014 |
| Atari | Atari 5200 | A5200 |
| Atari | Atari 7800 | ProSystem |
| Coleco | ColecoVision | Gearcoleco |
| SNK | Neo Geo Pocket, Neo Geo Pocket Color | Beetle NeoPop |
| Bandai | WonderSwan, WonderSwan Color | Beetle Cygne |
| Other | Arcade | FinalBurn Neo |
| Other | DOS | DOSBox Pure |
| Other | Virtual Boy | Beetle VB |
| Other | Pokémon Mini | PokeMini |
| Other | Arduboy | Arduous |

Dreamcast through Flycast and Pico-8 through FAKE-08 are bundled as
experimental cores and remain hidden unless experimental support is enabled.

Core revisions, licenses, hashes, build instructions, and frontend requirements
are recorded in [`Libretro/CoreManifest.json`](Libretro/CoreManifest.json).
RetroVault does not bundle games, firmware, BIOS files, or cryptographic keys.

## Library rules

- **RomM owns the catalog.** RetroVault caches and presents it; it does not
  create a competing library database.
- **Offline is normal.** Cached metadata and managed downloads continue to
  work during server restarts and network outages.
- **Download is not Export.** Download is app-managed storage for offline play.
  Export creates a user-owned copy.
- **Saves are not states.** In-game save data synchronizes with RomM. Emulator
  quick states and rewind history are local and core-specific.

## Architecture

RetroVault is a modular SwiftUI application with explicit boundaries between
features, services, networking, persistence, models, and the Libretro runtime.
RomM DTOs stay inside the API layer; features depend on protocols and
`Sendable` domain values. SwiftData and files provide the offline cache, while
Swift concurrency coordinates synchronization, downloads, and playback.

```text
App
 ├─ Features       Big Picture, Settings
 ├─ Services       Library, downloads, saves, firmware
 ├─ Networking     RomM API
 ├─ Persistence    SwiftData and managed files
 └─ Runners        Libretro, Metal, audio, input
```

Architectural decisions and milestone acceptance criteria live in
[`MILESTONES/`](MILESTONES/README.md).

## Build

Requirements:

- Apple silicon Mac
- macOS 26 or later
- Xcode 26 or later

Open the project and run the `RetroVault` scheme:

```shell
open RetroVault.xcodeproj
```

Or build and test from the command line:

```shell
swift build
swift test
Scripts/build-app.sh
```

The standalone app produced by `Scripts/build-app.sh` is signed ad hoc for
local development. Core build and licensing details are in
[`Libretro/README.md`](Libretro/README.md).

RetroVault's only Swift package dependencies are
[Nuke](https://github.com/kean/Nuke) for artwork and
[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for archive
extraction.

# OpenVault

> **Photos.app for your games.**

OpenVault is a native macOS client for RomM.

It brings your entire game library together into a beautiful, first-class Mac experience. Whether your games live on a server in your home, a NAS, or on the Mac itself, OpenVault makes them feel like they belong.

No importing.
No duplicate libraries.
No web browser.

Just your games.

---

## Why?

Retro gaming today is surprisingly fragmented.

You have ROM collections.
You have emulators.
You have metadata.
You have artwork.
You have save files.
You have multiple devices.

RomM solved the problem of organizing and serving a game library.

OpenVault exists to make that library feel at home on macOS.

Think of it as **Photos.app**, but for your games.

---

## Principles

OpenVault is built around a few simple ideas.

### RomM is the source of truth

Your library already exists.

OpenVault never asks you to import or reorganize it.

It simply connects to your RomM server and presents your collection as a native macOS application.

### Native first

OpenVault is written specifically for macOS.

SwiftUI.
AppKit where appropriate.
Spotlight.
Quick Look.
Drag & Drop.
System Search.
Beautiful keyboard shortcuts.

It should feel like an Apple application.

### Your games stay yours

Your library belongs to you.

No accounts.
No cloud lock-in.
No subscriptions.
No proprietary database.

Open source from day one.

### One Play button

Playing a game should be effortless.

Select a game.

Press **Play**.

OpenVault handles the rest.

Whether that means launching an external emulator, using a libretro core, or downloading a cached copy from your RomM server is an implementation detail.

---

## Features

### Library

* Native macOS interface
* Fast search
* Collections
* Favorites
* Recently Played
* Smart filters
* Rich artwork
* Manuals
* Screenshots
* Metadata

### RomM Integration

* Connect to one local or remote RomM server
* Automatic library synchronization
* Transparent ROM caching
* Offline mode
* Save synchronization (planned)

### Game Launching

* Configurable emulator runners
* Per-system defaults
* Per-game overrides
* Native emulator launching
* Native bundled Libretro runtime
* Game Boy and Game Boy Color through Gambatte
* NES through Nestopia UE
* SNES through bsnes-mercury Balanced
* GameCube through Dolphin
* PSP through PPSSPP

### macOS

* Spotlight integration
* Quick Look previews
* Dock menus
* Notifications
* Shortcuts support
* Native menu bar
* Beautiful dark mode

---

## Architecture

OpenVault intentionally separates responsibilities.

```
             ┌─────────────────────┐
             │     OpenVault       │
             │   Native Swift App  │
             └──────────┬──────────┘
                        │
                  RomM REST API
                        │
             ┌──────────▼──────────┐
             │        RomM         │
             └──────────┬──────────┘
                        │
          Local Storage / NAS / Cloud
                        │
                  Cached ROMs
                        │
             ┌──────────▼──────────┐
             │ Emulator Runners    │
             │ Dolphin             │
             │ RPCS3               │
             │ RetroArch           │
             │ OpenEmu             │
             │ libretro            │
             └─────────────────────┘
```

OpenVault is intentionally modular.

RomM manages the library.

Runner plugins launch games.

OpenVault provides the experience.

---

## Local Libraries

Don't have a RomM server?

OpenVault can create one for you.

On supported versions of macOS, OpenVault can automatically start a local RomM instance using Apple's container technologies.

No Docker knowledge required.

No manual configuration.

Just your library.

---

## Open Source

OpenVault is released under the GPL.

You are free to:

* inspect the source
* build it yourself
* modify it
* contribute improvements
* redistribute it under the terms of the license

Official signed and notarized builds help fund development.

---

## Roadmap

### Version 1

* Native macOS client
* RomM integration
* Transparent caching
* Emulator runners
* Beautiful library

### Version 2

* Save synchronization
* Runner plugins
* Native artwork management

### Future

* Additional reviewed Libretro cores and systems
* Cloud save providers
* Companion iPhone and iPad apps
* Apple TV support
* Steam Deck companion
* Plugin ecosystem

---

## Non-Goals

OpenVault is **not**:

* a ROM download service
* an emulator
* a replacement for RomM
* a proprietary launcher

It exists to make your existing library feel incredible.

---

## Contributing

OpenVault welcomes contributions of every kind.

Whether you're fixing bugs, improving documentation, designing icons, building runners, or polishing the user experience, we'd love your help.

---

## Development

OpenVault targets macOS 26 and Apple silicon.

Requirements:

* Apple silicon Mac
* macOS 26 or later
* Xcode 26 or later

Open `OpenVault.xcodeproj` to build and run the native application. The same
source tree is also described by `Package.swift` for command-line builds and
tests.

The project currently has two application dependencies: Nuke's core image
pipeline and ZIPFoundation for safe extraction of archived game content. The
Libretro frontend uses Apple frameworks and a small Swift-owned C ABI bridge
rather than a frontend package. All dependencies are managed with Swift
Package Manager.

The bundled Libretro pipeline is intentionally separate from ordinary
development builds. Its manifest, validation command, and build instructions
live in [`Libretro/`](Libretro/README.md). Run
`Scripts/build-libretro-cores.sh` to produce reviewed ARM64 core artifacts
before making a Release build.

The reviewed user-facing core catalog supports Game Boy, Game Boy Color, Game
Boy Advance, NES, SNES, Master System, Game Gear, SG-1000, Atari 2600, Atari
5200, Atari 7800, Nintendo 64, Arcade, Virtual Boy, Neo Geo Pocket and Pocket
Color, WonderSwan and WonderSwan Color, Pokémon Mini, PlayStation, Nintendo
DS, PC Engine / TurboGrafx-16, SuperGrafx, CHD-based PC Engine CD /
TurboGrafx-CD, Genesis / Mega Drive, Sega CD / Mega CD, Sega 32X, DOS,
Arduboy, Pico-8, GameCube, Wii, and PSP. A content-free 2048 core remains
available from Settings as a frontend smoke test.

Compatible RomM games expose Play in their details header. Play-on-demand
copies use a disposable 20 GB runtime cache, while an explicit Download keeps
a managed local copy in OpenVault. Export writes a shareable copy to Downloads
without changing the Downloaded collection. ZIP-wrapped games are supported
when the archive contains a file type declared by the selected core. Disc sets
use their cue sheet and preserve its companion tracks in the same extraction
directory.

Firmware is a RomM system-level resource. OpenVault requests it by platform
through the authenticated firmware API, validates it, and keeps a
server-scoped local copy for offline playback. Firmware is not bundled in the
application and is not inferred from `[BIOS]` games.

---

## Inspiration

OpenVault stands on the shoulders of incredible open-source projects, including:

* RomM
* OpenEmu
* RetroArch
* libretro
* Dolphin
* RPCS3
* PPSSPP
* Ryujinx (historically)
* countless emulator authors and preservationists

Thank you for keeping gaming history alive.

---

> **Your games. Beautifully organized.**
>
> **OpenVault.**

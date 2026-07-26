# Milestone 2A — Bundled Libretro

## Goal

Launch compatible games from the user's RomM library through a native
OpenVault-owned libretro frontend using reviewed cores bundled with the signed
application.

RomM remains the source of truth for games, saves, and states. OpenVault owns
only a replaceable local runtime cache and the temporary state required for an
active play session.

Milestone 1B is not a prerequisite. The runner must work with the paired remote
server from milestone 1A and with a future OpenVault-managed local server
through the same service boundary.

## Current implementation

- A Swift-owned Libretro C ABI loader validates API version 1 and required
  symbols before starting a core.
- One serial core thread owns initialization, callbacks, frame pacing,
  serialization, save RAM, and teardown.
- Software video is normalized to BGRA and presented by a dedicated Metal
  pipeline with explicit nearest-neighbor sampling. Hardware-rendered cores
  receive a native OpenGL 4.1 context; completed frames rejoin the same Metal
  presentation path. Integer scaling is used whenever the source fits, with
  centered black borders for the remainder.
- Stereo samples are sent through `AVAudioEngine`; keyboard and the first
  `GameController` map digital and analog controls to RetroPad port 0. Pointer
  input maps the visible rendered viewport to the Libretro pointer range for
  Nintendo DS touch input.
- The player is a separate native window with pause, reset, immersive
  fullscreen, bounded in-memory rewind, quick save/load, stop, and clean
  library-window isolation.
- The content-free 2048 core remains a Settings smoke test.
- Twenty-five reviewed user-facing cores support Game Boy, Game Boy Color, Game
  Boy Advance, NES, SNES, Master System, Game Gear, SG-1000, Atari 2600,
  Atari 5200, Atari 7800, ColecoVision, Nintendo 64, Arcade, Virtual Boy, Neo
  Geo Pocket and Pocket Color, WonderSwan and WonderSwan Color, Pokémon Mini,
  PlayStation, Nintendo DS, PC Engine / TurboGrafx-16, SuperGrafx, PC Engine CD /
  TurboGrafx-CD, Genesis / Mega Drive, Sega CD / Mega CD, Sega 32X, DOS,
  Arduboy, Pico-8, GameCube, Wii, and PSP.
- Compatible RomM details expose Play. Content is downloaded into a
  server/game/version-keyed, 20 GB disposable cache and can be replayed from
  that cache while RomM is unavailable.
- ZIPFoundation extracts a regular file whose extension is declared by the
  selected core. For CUE and M3U descriptors it also extracts safe regular-file
  companions from the same archive directory. Archive paths, symbolic links,
  metadata entries, and unrelated directories are never materialized.
- Core firmware is resolved from RomM's system-level firmware API by platform,
  verified against RomM and manifest hashes, and cached per server and
  platform for offline playback. Firmware is never inferred from `[BIOS]`
  library games or bundled with OpenVault.
- Save RAM is isolated per server and game, restored before core startup, and
  synchronized back to RomM when it changes. Quick states and rewind history
  remain local and core-specific. Play automatically resumes a local quick
  state when one exists; a state rejected by the selected core falls back to a
  clean boot without preventing launch.

## User journey

1. The user selects Play from a game details screen.
2. OpenVault presents a full-page launch screen with artwork, Saves and States,
   the selected core, fullscreen preference, and a clear Start Fresh option.
3. OpenVault verifies that a bundled core supports the game's system and file
   type.
4. OpenVault prepares required or available firmware from the platform's RomM
   firmware records, reusing its verified local cache when offline.
5. OpenVault downloads the game into a managed, bounded cache when necessary.
6. OpenVault optionally downloads the selected save or state from RomM.
7. The game opens in a separate native game window.
8. Battery-backed memory is persisted locally during play.
9. Closing the game returns to the existing library without terminating
   OpenVault.

## Architecture boundary

The UI depends on a small runner contract rather than libretro directly:

```swift
protocol GameRunner: Sendable {
    func compatibility(for request: RunRequest) async -> RunCompatibility
    func launch(_ request: RunRequest) async throws -> GameSession
}
```

The libretro implementation owns:

- Core selection through the bundled-core manifest
- Core loading and API-version validation
- The `libretro.h` callback bridge
- Frame scheduling and lifecycle
- Metal presentation of software and hardware-rendered frames
- Core Audio output and rate matching
- GameController and keyboard input
- Core system, save, state, and content directories
- Session teardown after normal exit or core failure

RomM networking, library presentation, and core execution remain separate
modules.

## Bundled cores

- Every core officially supported by OpenVault ships inside the application.
- Core binaries are `arm64`, pinned to reviewed source revisions, and signed
  with the same team identity as the enclosing app.
- OpenVault does not initially download cores or load arbitrary user-provided
  binaries.
- The versioned manifest is the source of truth for provenance, build
  instructions, supported content, required frontend capabilities, firmware,
  and license notices.
- A core enters the supported catalog only after its redistribution terms and
  source build have been reviewed.
- Games, firmware, BIOS files, and cryptographic keys are never bundled.

The first pipeline artifact is a deliberately content-free libretro core used
to verify deterministic ARM64 compilation, packaging, signing, and license
collection. User-facing emulator cores are added to the same manifest only
after the frontend can execute their declared capabilities.

The reviewed user-facing catalog includes:

- Gambatte for Game Boy and Game Boy Color
- mGBA for Game Boy Advance
- Nestopia UE for NES
- bsnes-mercury Balanced for SNES
- Gearsystem for Master System, Game Gear, and SG-1000
- Gearcoleco for ColecoVision
- Stella 2014 for Atari 2600
- A5200 for Atari 5200
- ProSystem for Atari 7800
- Beetle VB for Virtual Boy
- Beetle NeoPop for Neo Geo Pocket and Pocket Color
- Beetle WonderSwan for WonderSwan and WonderSwan Color
- PokeMini for Pokémon Mini
- PCSX-ReARMed for PlayStation
- melonDS for Nintendo DS
- Geargrafx for PC Engine / TurboGrafx-16, SuperGrafx, and CHD-based PC Engine
  CD / TurboGrafx-CD content
- Genesis Plus GX for Genesis / Mega Drive and Sega CD / Mega CD
- PicoDrive for Sega 32X
- DOSBox Pure for DOS
- FinalBurn Neo for Arcade
- Arduous for Arduboy
- FAKE-08 for Pico-8
- ParaLLEl-N64 for Nintendo 64
- Dolphin for GameCube and Wii, including its pinned non-firmware
  `dolphin-emu/Sys` runtime data
- PPSSPP for PSP, including its pinned non-firmware `PPSSPP` runtime assets

Every core is pinned to a reviewed revision and passes the same manifest,
runtime-compatibility, license, ARM64, hashing, and signing gates.

Genesis Plus GX, PicoDrive, and FinalBurn Neo are approved only for the
project's free, noncommercial release model. Their licenses prohibit
commercial use and sale, so they are explicit release blockers for any future
paid distribution.

## Initial frontend scope

- Software-rendered video and OpenGL hardware-rendered video
- Stereo audio
- One digital and analog RetroPad-compatible controller
- Keyboard fallback
- Windowed and fullscreen presentation
- Battery-backed save memory
- Manual save-state creation and restore
- Bounded in-memory rewind at one-second intervals
- Clean reset, pause, resume, and exit
- One active game session

## Cache and save rules

- Games prepared only for playback live in a bounded OpenVault cache. The
  user-initiated Download action instead keeps a durable managed copy in
  Application Support, while Export writes a shareable copy to Downloads.
- The cache is disposable and can always be rebuilt from RomM.
- A cache entry is keyed by server identity, game identity, and content hash
  when the server provides one.
- Firmware is separate from the game cache. It is keyed by server and platform,
  validated before use, and retained in Application Support so a prepared
  system can continue to launch offline.
- The built-in Downloaded collection is the union of durable managed downloads
  and valid playback-cache entries. Exported destinations are intentionally
  excluded.
- Save files and save states are not interchangeable. A battery save is placed
  in the core's save directory before launch; a state is restored explicitly
  after the core and content have loaded.
- Before every launch, OpenVault requests fresh game details from RomM and
  imports the newest available cartridge save before starting the core,
  falling back through older revisions when a stale database row points to a
  missing file. Unsynchronized local data always wins over a remote import. If
  RomM is offline, launch continues with the local save without waiting for a
  server timeout beyond the failed refresh.
- When a session ends, OpenVault uploads changed cartridge memory as a new
  RomM autosave revision and leaves unchanged saves alone. It never overwrites
  an existing remote revision, and RomM retains a bounded ten-save history.

## Acceptance criteria

- The checked-in manifest passes structural and policy validation.
- A clean Apple-silicon machine can build every enabled manifest entry from its
  pinned revision with one command.
- Every output is an ARM64 Mach-O dynamic library with a recorded SHA-256.
- The pipeline collects the exact license file from each pinned source tree.
- The pipeline supports ad-hoc signing for development and a supplied Developer
  ID identity for release artifacts.
- Release packaging fails rather than weakening library validation when a core
  is missing or signed incorrectly.
- A compatible RomM game can be cached, opened in a separate native window,
  controlled with a gamepad, heard through Core Audio, saved locally, and
  closed without destabilizing the library window.
- Missing firmware, unsupported content, core load failure, and session crash
  produce distinct, actionable errors.

## Out of scope

- Runtime core downloads or a core store
- Arbitrary third-party core loading
- Bundled games, firmware, BIOS files, or keys
- Netplay, achievements, cheats, shaders, run-ahead, or recording
- Multiple simultaneous sessions
- External emulator configuration
- Automatic synchronization of core-specific save states
- Intel builds

## Completion boundary

Milestone 2A is complete when the bundled-core pipeline is reproducible and a
signed development build can launch at least one real game from RomM through
the native libretro frontend, persist its local save, restore a compatible
state, and return cleanly to the OpenVault library.

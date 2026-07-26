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
- Software video is normalized to BGRA and presented through Metal/Core Image
  with aspect-fit scaling.
- Stereo samples are sent through `AVAudioEngine`; keyboard and the first
  `GameController` map to RetroPad port 0.
- The player is a separate native window with pause, reset, fullscreen, quick
  save/load, stop, and clean library-window isolation.
- The content-free 2048 core remains a Settings smoke test.
- Gambatte is the first reviewed user-facing core, supporting raw or
  ZIP-wrapped Game Boy and Game Boy Color content.
- Compatible RomM details expose Play. Content is downloaded into a
  server/game/version-keyed, 20 GB disposable cache and can be replayed from
  that cache while RomM is unavailable.
- ZIPFoundation extracts only one regular file whose extension is declared by
  the selected core. Archive directories, symbolic links, metadata entries,
  and unrelated content are never materialized.
- Save RAM and quick states are local and isolated per core and content. They
  are not uploaded to RomM.

## User journey

1. The user selects Play from a game details screen.
2. OpenVault presents a full-page launch screen with artwork, Saves and States,
   the selected core, fullscreen preference, and a clear Start Fresh option.
3. OpenVault verifies that a bundled core supports the game's system and file
   type and explains any missing firmware requirement.
4. OpenVault downloads the game into a managed, bounded cache when necessary.
5. OpenVault optionally downloads the selected save or state from RomM.
6. The game opens in a separate native game window.
7. Battery-backed memory is persisted locally during play.
8. Closing the game returns to the existing library without terminating
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

The first such user-facing core is Gambatte, pinned to a reviewed revision and
licensed under GPL-2.0-only. Additional systems follow the same manifest and
runtime-compatibility gate.

## Initial frontend scope

- Software-rendered video
- Stereo audio
- One RetroPad-compatible controller
- Keyboard fallback
- Windowed and fullscreen presentation
- Battery-backed save memory
- Manual save-state creation and restore
- Clean reset, pause, resume, and exit
- One active game session

## Cache and save rules

- Downloaded games live in a bounded OpenVault cache, not in the user's RomM
  library and not in Downloads.
- The cache is disposable and can always be rebuilt from RomM.
- A cache entry is keyed by server identity, game identity, and content hash
  when the server provides one.
- Save files and save states are not interchangeable. A battery save is placed
  in the core's save directory before launch; a state is restored explicitly
  after the core and content have loaded.
- Save synchronization back to RomM is a separate milestone. Until then,
  OpenVault must never overwrite a remote save automatically.

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
- Netplay, achievements, cheats, shaders, run-ahead, rewind, or recording
- Multiple simultaneous sessions
- External emulator configuration
- Automatic remote save mutation or conflict resolution
- Intel builds

## Completion boundary

Milestone 2A is complete when the bundled-core pipeline is reproducible and a
signed development build can launch at least one real game from RomM through
the native libretro frontend, persist its local save, restore a compatible
state, and return cleanly to the OpenVault library.

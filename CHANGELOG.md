# Changelog

RetroVault uses Calendar Versioning in `YYYY.M.D` form. This changelog records
notable user-facing and architectural changes and is intentionally curated
rather than being a list of every commit.

## 2026.8.4 (2026-08-04)

### Added

- Added the first downloadable Apple-silicon DMG release, with an ad-hoc signed
  application bundle, SHA-256 checksum, and explicit Gatekeeper instructions.
- Added a native **Acknowledgements…** command beside the macOS About menu.
  Its window lists Swift packages, hosted emulators, and the exact bundled
  Libretro core revisions and license links from the reviewed manifest.
- Added a distribution-ready third-party notice that records bundled
  component licenses and ships inside release application bundles.

### Changed

- Adopted Calendar Versioning in `YYYY.M.D` form.
- Relicensed RetroVault original code from GPL-3.0 to GPL-2.0-or-later with a
  narrowly scoped Libretro core-linking exception. Every third-party component
  remains governed by its own license, including noncommercial restrictions.

## 2026-08-02

### Added

- PlayStation Vita titles now run as a PlayStation TV by default. Vita3K
  actuator requests are routed through RetroVault's shared DSU/native rumble
  pipeline, matching the app's controller-first hosted configuration.
- Added a reversible, separately built native-arm64 Cemu Metal trial. When the
  capability-marked trial companion is present, RetroVault selects Cemu's
  native Metal renderer; the stable Cemu 2.6 Vulkan companion remains intact
  as the fallback. Windowed Metal sessions retain native green-button
  fullscreen and RetroVault's Command-F shortcut.
- Added one automatic controller roster shared by Big Picture, Libretro,
  Vita3K, and the hosted Cemu runner. Every live external DSU slot keeps its
  player number, while native macOS controllers fill vacant slots; runners
  that support multiplayer can consume up to four players.
- Added four managed Wii U Pro Controller profiles backed by RetroVault's
  localhost DSU relay for multiplayer Cemu titles.
- Added Wii U rumble handling to RetroVault's local DSU relay and an opt-in
  patched Cemu companion build path. The default companion remains upstream
  Cemu 2.6 until the patch is rebuilt with a validated toolchain.

### Changed

- Removed the manual DSU slot preference. RetroVault now discovers every live
  slot and converts direct controllers into the same internal DSU-shaped input
  stream.
- Reordered the home library shortcuts around local play: Downloaded Games,
  Recently Played, Favorite Games, Recently Added, and All Games. Save Center
  now sits at the bottom of the home page after the systems list.
- Cemu now inherits RetroVault's current presentation when a Wii U game starts:
  windowed RetroVault sessions launch Cemu windowed, while fullscreen sessions
  continue launching Cemu fullscreen.
- Removed the shared internal-resolution selector. Libretro cores and hosted
  emulators now use their own native/default rendering resolution.
- Save Center no longer shows a redundant `X Play` hint when the selected save
  is already synchronized and `A Play` is available.
- RetroVault now embeds the stable Vulkan Cemu companion beside the native
  Metal companion and selects it only for titles with known Metal rendering
  regressions. Super Mario 3D World uses Vulkan while other Wii U games keep
  the faster Metal path.

### Fixed

- Restored the official Cemu 2.6 companion after the Apple Clang 21 rebuild
  caused MoltenVK render-pipeline failures in games such as Wind Waker HD.
  Patched Cemu builds now refuse that known-bad toolchain instead of producing
  an executable that fails only after a title starts.

## 2026-08-01

### Added

- Added front-touchscreen input for the experimental Vita3K runner using
  mouse clicks and click-drag gestures on the rendered game surface.
- Added a local-build-only PlayStation Vita technical preview. A pinned Vita3K
  engine can render through MoltenVK into RetroVault's own native player view,
  while its firmware and installed titles remain isolated from Libretro data.
  Required `.PUP` packages are discovered through the authenticated RomM
  system-firmware API, validated, cached, and installed before Vita playback.
- Added Switch X as the selected game's contextual action: it opens Options in
  library lists and launches the game from Save Center. Start remains an
  alternate Options shortcut.
- Added a controller-first Save Center that combines RomM save availability
  with RetroVault's local save inventory.
- Added visible synchronized, upload-needed, RomM-only, and failed save states,
  with manual conflict-safe reconciliation and retry.
- Persisted failed save uploads so they remain visible after gameplay and
  across app launches.

### Fixed

- Fixed an experimental Vita3K crash caused by SDL pumping AppKit events from
  the emulation worker thread.
- Allowed the experimental Vita runner to launch with main system firmware
  when Vita3K's optional font and preinstalled-content packages are absent.

## 2026-07-31

### Added

- Renamed OpenVault to RetroVault, including the application identity and
  project documentation.
- Added DSU/Cemuhook controller support documentation, including the
  Switch 2 Pro Controller bridge.
- Added backgroundable and cancellable bulk downloads, one shared queue for
  multiple systems, and controller-accessible system actions.
- Added incremental RomM synchronization: a complete initial baseline,
  `updated_after` polling, Socket.IO change notifications, and periodic full
  reconciliation for missed updates and deletions.

### Changed

- Made large initial RomM synchronizations faster and exposed their progress
  in the controller interface.
- Improved rewind and fast-forward feedback and behavior.

## 2026-07-30

### Added

- Added sync status and a manual **Sync Now** action to the Select overlay.
- Enabled the supported macOS Game Mode integration during gameplay.

### Changed

- The cached library now appears before secondary catalog indexing finishes.
- Game lists preserve their selection and scroll position after playback.
- Removed the redundant Collections entry from the main menu.

### Fixed

- Fixed quick-state resume after save synchronization.
- Fixed a crash caused by short Big Picture menu snapshots.
- Prevented unsafe Dolphin state restoration from crashing GameCube and Wii
  sessions.

## 2026-07-29

### Added

- Made the controller-first Big Picture interface the default application
  experience.
- Added Smart CRT presentation, including flat and curved treatments selected
  by system, and applied the selected treatment consistently to Big Picture.
- Added improved windowed gameplay controls and kept game content clear of
  window chrome and status controls.
- Added experimental Pico-8 support behind the experimental-cores setting.

### Changed

- Replaced Geargrafx with Beetle PCE for PC Engine and TurboGrafx playback.
- Refined save handling, library browsing, and DSU input latency measurement.
- Fullscreen Escape now leaves fullscreen before navigating away.

### Fixed

- Fixed Pico-8 cartridge startup.
- Rewind now pauses at the oldest retained frame and remains there until the
  rewind control is released.

## 2026-07-28

### Added

- Added internal-resolution upscaling for supported 3D cores.
- Added keyboard gameplay input and DSU network-controller input.
- Added Nintendo 64 Controller Pak save support.

### Changed

- Let ParaLLEl-N64 choose its RSP plugin automatically for broader audio
  compatibility.
- Refined Big Picture launch, Resume, fresh-play, and download actions.
- Updated the documented supported-system and bundled-core status.

## 2026-07-27

### Added

- Added complete PPSSPP savedata-directory synchronization with RomM.
- Added concurrent bulk downloads with aggregate progress and playback
  priority.
- Added a game information inspector, favorite and download badges, keyboard
  library navigation, and persistent Big Picture fullscreen preference.
- Added L3 rewind and R3 fast-forward controls with configurable behavior.
- Added fully offline launch for games in managed local storage.

### Changed

- Full-library synchronization now fetches pages concurrently and replaces
  the cached snapshot atomically.
- Played games remain in managed downloads for later offline use.
- Download progress no longer forces library lists to redraw, lose their
  scroll position, or interrupt gameplay.
- Rewind became frame-fluid and deterministic while held.
- Project documentation now emphasizes preservation and the historical value
  of maintained game libraries.

### Fixed

- Fixed reconciliation of downloaded-game counts and status indicators.
- Fixed keyboard navigation and idle cursor visibility in Big Picture.

## 2026-07-26

### Added

- Added the offline library cache and bundled Libretro runtime foundation,
  including managed ROM downloads, firmware, saves, quick states, Metal
  presentation, Core Audio, and controller input.
- Added the controller-first Big Picture browser with paging, type-to-select,
  fullscreen and windowed presentation, in-window gameplay, and controller
  options menus.
- Added artwork and column library views, system and multi-system browsing,
  year sorting, playable/downloaded indicators, Favorites, and system-wide
  download actions.
- Added managed **Download**, user-owned **Export**, favorite actions, and
  Option-gated deletion from RomM through a shared multi-selection context
  menu.
- Added quick-state creation on exit, Resume, and non-destructive fresh play.
- Added ColecoVision playback and expanded support for PlayStation, arcade,
  DOS, and other bundled cores.
- Added regression coverage for the library cache, networking, downloads,
  saves, and runtime behavior.

### Changed

- Made Favorites local-first while synchronizing membership back to RomM.
- Prioritized a game being launched ahead of queued bulk downloads.
- Removed the metadata-heavy game detail page in favor of direct browsing and
  play actions.
- Removed eager whole-library artwork prefetch after measuring its effect on
  responsiveness.

### Fixed

- Fixed live ROM-download progress and reuse of already downloaded ROMs after
  metadata changes.
- Fixed PlayStation launches from long sandbox cache paths.
- Fixed controller mappings and prompts for Xbox and Nintendo layouts.
- Fixed Big Picture scroll resets, focus churn, safe-area offsets, menu-bar
  visibility, cursor handling, and edge-to-edge fullscreen presentation.
- Preserved arcade ROM-set filenames and selected a safer DOSBox interpreter
  mode for compatibility.

## 2026-07-25

### Added

- Established the native macOS architecture, project principles, milestone
  documents, and GPL-3.0 license.
- Added pairing with a single RomM server using an alphanumeric client token.
- Added the first SwiftUI library browser backed by RomM systems, collections,
  games, metadata, search, and artwork.
- Added secure local session persistence and the initial networking, models,
  services, and test boundaries.

### Project decisions

- RomM remains the source of truth; RetroVault does not import or reorganize
  the server library.
- The application targets Apple-silicon Macs and a native SwiftUI experience.
- Offline browsing and managed local playback are explicit product goals,
  while multi-server support is out of scope.

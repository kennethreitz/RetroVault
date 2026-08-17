# Future Platform — Apple TV Feasibility

## Status

Tabled for future exploration. This document records the intended boundary so
an Apple TV experiment does not distort the macOS application architecture.

## Product shape

A tvOS edition of RetroVault would be a controller-first RomM client for an
Apple TV 4K. It would share library, networking, persistence, and save-sync
code with the Mac app while providing its own tvOS interface and game runner.
RomM would remain the source of truth.

The first useful version would support:

- Pairing with one RomM server.
- Browsing systems, favorites, recent games, and downloaded games.
- Controller navigation and playback through a reviewed subset of bundled
  Libretro cores built for tvOS and Apple silicon.
- Replaceable local game caching with immediate save synchronization.
- A Metal presentation path appropriate for a television.

## Explicitly out of scope for the first experiment

- Cemu, Vita3K, and other desktop application integrations.
- Running a local containerized RomM server on Apple TV.
- Full parity with every Mac core.
- Treating Apple TV storage as permanent or irreplaceable.
- An App Store release before the technical and licensing model is proven.

## Architecture boundary

The existing shared Swift models and RomM services should remain independent
of AppKit. A future `RetroVaultTV` target would own tvOS navigation, focus,
scene lifecycle, storage policy, and runner integration. macOS window and menu
code must not leak into that target.

Libretro cores would need reviewed tvOS arm64 builds and static integration
where dynamic loading is unavailable. Higher-complexity systems should enter
the catalog only after input, audio, save, thermal, and memory behavior are
verified on physical Apple TV hardware.

## Platform constraints

- tvOS is focus- and controller-driven rather than pointer-driven.
- Downloaded games live in purgeable local storage and must be recoverable
  from RomM; save data should be synchronized promptly.
- App Store Review Guideline 4.7 places additional requirements on software
  that downloads and runs retro-game content.
- Core licenses and redistribution terms still apply independently of Apple's
  review requirements.

## Recommended first spike

Use a developer-signed build on a physical Apple TV 4K. The spike succeeds
when it can pair with RomM, browse a real library, launch a small set of
low-complexity systems with a controller, upload a save, and recover cleanly
after the local game cache is removed.

Only after that should the project decide whether tvOS remains a personal
side-loaded target or becomes a supported distribution.

## References

- [App Programming Guide for tvOS](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/index.html)
- [Game Controller framework](https://developer.apple.com/documentation/gamecontroller)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

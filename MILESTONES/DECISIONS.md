# Architecture Decisions

Decision date: July 25, 2026

These decisions define the initial architecture of OpenVault. Reversals should
be recorded deliberately because several choices affect persistence, signing,
entitlements, and public APIs.

## Product

- OpenVault is a native macOS application written in Swift and SwiftUI.
- RomM is the source of truth for the game library.
- OpenVault does not import, reorganize, or maintain a competing library.
- The first milestone is library browsing, not game launching.
- The application should feel consistent with native apps such as Photos and
  Music.
- Simplicity, testability, modern Swift concurrency, and minimal dependencies
  take precedence over speculative flexibility.

## Platform and distribution

- The deployment target is macOS 26.
- OpenVault supports Apple silicon only and is built for `arm64`.
- The minimum macOS version is gated by Apple's supported container
  technologies, even before local RomM support ships.
- Initial distribution will be a directly downloaded, signed, and notarized
  application.
- Mac App Store distribution is not an initial target.
- The application icon is compiled from `AppIcon.appiconset` and applied from
  the bundled `AppIcon.icns` at launch so Xcode Debug runs cannot fall back to
  a stale LaunchServices icon.

## Application structure

OpenVault begins as a modular monolith with one application target and explicit
internal boundaries:

```text
OpenVault/
    App/
    UI/
    Features/
        BigPicture/
        ServerConnection/
        Library/
        Search/
        GameDetails/
        Settings/
        Runners/
    Networking/
        RomMAPI/
    Models/
    Persistence/
    Services/
    Shared/
    Resources/
```

The dependency direction is:

```text
App → Features → Services → Networking
                    ↓            ↓
                Persistence    Models
                    ↓
                  Models

UI → Models
```

- `App` is the composition root.
- Features do not access `URLSession`, credential persistence, or SwiftData
  directly.
- RomM API DTOs are distinct from domain models.
- Domain models are immutable `Sendable` value types.
- Feature state is isolated to the main actor.
- Protocols are introduced at meaningful seams, not for every concrete type.
- External packages and local Swift packages are added only when a proven
  boundary requires them.

## Server model

- OpenVault has exactly one configured server at a time.
- Multi-server aggregation and multiple simultaneous server profiles are
  non-goals.
- The active server may be remote or managed locally.
- Changing the configured server clears or replaces the existing metadata
  cache after confirmation so libraries cannot be mixed.
- Remote and managed-local modes both produce the same RomM API connection for
  the rest of the application.

Conceptually:

```swift
enum ServerConfiguration: Sendable {
    case remote(RemoteServerConfiguration)
    case managedLocal(ManagedLocalServerConfiguration)
}
```

## RomM compatibility and authentication

- Initial development targets the current stable RomM 5.0 release line.
- Compatibility with recent older releases may be retained when inexpensive,
  but is not promised without fixtures and tests.
- Prerelease RomM versions are not an initial compatibility target.
- The first live development run targets a paired remote server.
- Client API tokens are the preferred authentication mechanism.
- Pairing-code exchange and direct client-token entry are the initial
  authentication paths.
- The connection screen links to the configured server's
  `/client-api-tokens` page, preserving any reverse-proxy base path. Until the
  server URL is valid, the link falls back to RomM's client-token
  documentation.
- Username and password authentication may be added as a fallback.
- Release builds will store tokens, passwords, and generated secrets in
  Keychain.
- Temporary development exception: the RomM client token is currently stored
  in OpenVault's sandboxed Application Support directory as an owner-readable
  file (`0700` directory and `0600` file). This avoids unstable Keychain access
  control while development builds are ad-hoc signed. It is security debt and
  must migrate back to Keychain before release.
- Secrets must never be stored in source code, fixtures, logs, or ordinary
  preferences.
- OpenVault requests only the scopes required by the features it implements.
- The library requires `me.read`, `platforms.read`, `roms.read`,
  `roms.write`, `collections.read`, `roms.user.write`, `assets.read`, and
  `assets.write`. `roms.user.write` covers personal state such as completion
  and rating; `roms.write` is required for explicitly confirmed game deletion;
  the asset scopes download and upload cartridge saves.
- OpenVault should explain missing-scope failures rather than presenting a
  generic networking error.
- OIDC is an extension point, not an initial deliverable.

## Library navigation

- The primary library uses a native `NavigationSplitView`.
- The sidebar contains All Games, Collections, and Systems.
- Pressing Left from the regular library content moves keyboard focus to the
  sidebar. Subsequent Up and Down commands continue navigating sidebar
  destinations instead of the rebuilt game table reclaiming focus.
- "Systems" is the user-facing name for RomM platforms.
- Systems with games are shown directly. Empty systems are collapsed under an
  Empty Systems disclosure at the bottom of the Systems section so future
  upload targets remain reachable without cluttering everyday browsing.
- User-created RomM collections are read-only navigation destinations. Smart
  collections use a collapsible subgroup whose expanded state is remembered.
- RomM's automatically generated virtual collections are synchronized with
  their complete membership and cached for offline navigation. They use a
  separate, collapsed-by-default subgroup whose expanded state is remembered.
- Downloaded is a built-in, server-scoped local collection. It includes ROMs
  that exist in OpenVault's durable managed ROM library or disposable playback
  cache. External exports do not affect Downloaded membership.
- Every destination filters one shared, incrementally paginated cover grid.
- The standard macOS toolbar search field filters the active destination through
  RomM's server-side search, so results cover the full remote library rather
  than only the currently loaded page.
- A Search All Systems checkbox appears for scoped searches and can temporarily
  lift the active system or collection filter without changing the sidebar
  selection.
- Game records whose metadata name or filename begins with `[BIOS]` are
  retained in the offline metadata snapshot but hidden by default. A persisted
  `Hide [BIOS] Games` library filter can reveal them without another network
  request. Detection uses the same case-insensitive prefix rule regardless of
  how RomM tags the game. These are separate from RomM's system-level firmware
  records used by emulator cores.
- The artwork gallery can hide games that do not expose artwork. The preference
  does not affect List view. While the gallery filter is active, OpenVault also inspects
  and caches each populated system's games, hiding a system from the primary
  list only after confirming it has no artwork. Empty systems remain available
  in their disclosure as future upload targets. The user's filter choice is
  persisted as a non-secret application preference and restored on launch.
- Cover cards keep a consistent footprint while fitting the complete source
  image, preserving unusually wide or tall artwork without distortion.
- List view supports native multiple selection. A contextual Delete from RomM
  action always presents a confirmation sheet naming the selected games.
  Database-only removal is the default; permanent deletion of the corresponding
  ROM files is a separate unchecked option with a stronger warning.
- After RomM confirms a complete bulk deletion, OpenVault removes the games
  from its local snapshot and cached details. Partial results trigger a server
  reconciliation and present RomM's errors.
- Collection editing, smart-filter creation, and other unimplemented RomM
  mutations remain outside the current slice.

## Big Picture

- The library toolbar exposes a TV button that opens a dedicated, single
  Big Picture window and enters native macOS full screen.
- Big Picture follows MinUI's visual grammar: a black canvas, large rounded
  typography, an inverted white selection, shallow navigation, and persistent
  controller action hints. It does not reuse the desktop sidebar, toolbar,
  column browser, or artwork grid.
- The root menu contains Recently Added, Downloaded, Collections, and only
  systems with a bundled reviewed core. Regular, smart, and virtual RomM
  collections remain available in one controller-friendly collection list.
- The mode reads the complete persisted RomM snapshot without changing the
  desktop library selection or search. Cached artwork and metadata continue to
  work when RomM is unavailable.
- Keyboard, mouse, and extended game controllers share one navigation model.
  D-pad or left stick moves with hold-to-repeat, A opens or plays, B moves
  back or exits, and the shoulder buttons page through long lists. OpenVault
  reads every connected extended or compact controller rather than binding
  navigation to the first device returned by the system.
- Big Picture directional selection clamps at the beginning and end of a list
  instead of wrapping unexpectedly. Pointer hover can update selection without
  issuing a programmatic scroll, preventing wheel scrolling from feeding back
  into a jump toward the first rows.
- Starting a game reuses the production details, download, firmware, save-sync,
  and Libretro preparation pipeline. Large uncached ROMs show byte and
  percentage progress rather than an indefinite Preparing state.
- A player launched from Big Picture treats Escape, the standard window-close
  shortcut, and Start + Select as a clean return to the still-open Big Picture
  library. Local save memory is persisted and RomM synchronization begins
  before the player window closes. Desktop-launched players retain the native
  fullscreen Escape behavior.

## Game details

- A game card pushes a full-page destination inside the detail column's native
  `NavigationStack`; it does not open a sheet or a separate window.
- Game-detail foreground content consumes only the portion of a window safe
  area that its `NavigationSplitView` container has not already accounted for.
  This prevents sidebar and titlebar insets from being applied twice.
- Each game-detail destination and scroll container has game-specific identity,
  so opening another game begins at the top instead of inheriting the previous
  game's vertical scroll position.
- The native details screen follows RomM 5.0's information hierarchy: a fixed
  cover column, title and activity header, and Overview, Files, Media, and
  Metadata tabs. On wide windows only the active tab panel scrolls; narrow
  windows collapse into one natural document scroll.
- Unsupported actions are not rendered as inert imitations. Play appears only
  when a bundled, reviewed core declares support for both the RomM system and
  content extension. Open in RomM remains available for server-owned
  operations that have no native feature slice.
- RomM remains the source of truth. Full details are fetched on selection from
  the authenticated game-detail endpoint rather than inferred from the lighter
  paginated grid response.
- The details view presents normalized metadata, provider IDs,
  per-user state, content counts, screenshots, every returned file, file paths,
  sizes, hashes, archive members, and soundtrack track metadata when present.
- Save and state availability is visible as separate, clickable counts in the
  details header. Each count opens a read-only Save Data tab with Saves and
  States sections. OpenVault presents the server-provided filename, emulator,
  slot, size, path, timestamps, availability, and state screenshot when
  present.
- The details header offers separate Download and Export actions. Download adds
  the ROM to OpenVault's server-scoped managed local library in Application
  Support. Export writes a shareable copy to macOS Downloads, preserves the
  server-provided name, and adds a numeric suffix instead of overwriting an
  existing file. Export can reuse a managed or playback-cached copy offline and
  never changes Downloaded membership.
- Personal completion, rating, difficulty, play status, backlog, now-playing,
  and hidden values are editable through compact native controls. Changes are
  optimistic, written to RomM through its per-user ROM properties endpoint, and
  rolled back with an actionable error if the server rejects or cannot receive
  the update. Confirmed values replace the cached details for offline browsing;
  OpenVault does not queue offline mutations.
- RomM descriptive metadata editing, save mutation or synchronization, and
  manual presentation remain separate feature slices.

## Networking and trust

- Remote internet-facing RomM servers should use HTTPS.
- Plain HTTP is supported for managed-local and explicitly configured local
  network servers.
- OpenVault uses the narrow local-network App Transport Security allowance
  rather than disabling transport security globally.
- Self-signed certificate bypasses and "trust any certificate" behavior are
  not supported initially.
- Certificate validation for public HTTPS servers uses the system trust store.

## Offline library

- Offline library browsing is part of the first milestone.
- SwiftData stores a complete, disposable cache of synchronized library
  metadata.
- SwiftData persistence records remain separate from domain models.
- Cached data is shown immediately at launch and refreshed in the background.
- A synchronization downloads every paginated game summary plus regular and
  smart collection membership. System and collection counts are rebuilt from
  the synchronized games rather than trusted independently.
- The new snapshot replaces the previous snapshot only after every required
  page succeeds. Cancellation, server restarts, Wi-Fi loss, and partial API
  failures cannot erase the last complete library.
- A failed refresh preserves the last successful library and exposes a clear
  stale or offline state.
- Search operates against cached metadata and remains available offline.
- Full details are cached after a game has been viewed, allowing those details
  to reopen offline without turning the cache into a second source of truth.
- Every synchronized game can open offline. Games without a previously cached
  full-detail response render a summary-only detail page from the library
  snapshot and clearly identify it as a cached summary.
- Artwork uses a 10 GB bounded disk cache separate from SwiftData. OpenVault
  fetches and retains each game's canonical library cover only when a library
  or collection view requests it; synchronization does not sweep the complete
  library. Screenshots and other detail media are likewise loaded on demand.
- The offline promise covers all synchronized metadata. Artwork remains
  available offline after its corresponding library cover has been viewed.
- Managed downloads and play-on-demand cache entries can launch and export
  offline while their local files remain available.
- The local cache is replaceable and never becomes a second source of truth.
- Explicitly disconnecting the server clears its metadata cache along with the
  stored configuration and client token.
- Settings offers two client-side maintenance actions. Resync fetches and
  transactionally replaces a complete RomM metadata snapshot while preserving
  the prior cache on failure. Purge Local Cache & Resync first removes
  OpenVault's disposable metadata, viewed-game details, and artwork caches,
  then rebuilds them from RomM after explicit confirmation. Neither action
  deletes managed or exported ROMs, saves, or playback data, and neither
  initiates a RomM server scan.

## Managed local RomM

- Managed local RomM is milestone 1B, after the paired remote-library flow.
- It uses Apple's container technologies and does not require Docker.
- Apple's Containerization Swift package is an acceptable necessary
  dependency for this feature.
- Containerization is hidden behind an OpenVault-owned runtime protocol so
  Apple API changes do not propagate through the application.
- The local runtime manages a pinned RomM image and a pinned MariaDB image.
- Container images use native `linux/arm64` variants and are pinned by digest
  rather than mutable `latest` tags.
- The selected ROM library is mounted rather than copied.
- The ROM library mount is read-only initially.
- Database, resources, assets, Redis data, and configuration use managed
  writable storage.
- Access to a user-selected library is persisted with a security-scoped
  bookmark.
- Generated database credentials and RomM authentication secrets are stored in
  Keychain.
- The managed local stack starts on demand and stops when OpenVault quits.
- Persistent background-server mode is not an initial target.
- A signed-application technical spike must prove image pulling, mounts,
  networking, startup, shutdown, and recovery before the full local setup UI is
  implemented.

## Libretro core distribution

- Every libretro core officially supported by OpenVault is bundled with the
  application. OpenVault does not initially download cores at runtime or load
  arbitrary user-provided core binaries.
- Bundled cores are built for `arm64`, pinned to reviewed source revisions, and
  code signed with the same team identity as OpenVault. Core updates ship as
  ordinary OpenVault application updates.
- A versioned core manifest records each core's identifier, version, source
  revision, supported systems and file extensions, required frontend
  capabilities, firmware requirements, and license notices.
- "Bundle every core" means every core that OpenVault can test, support, and
  legally redistribute under its release model. A core is excluded until its
  macOS compatibility, redistribution terms, and required frontend features
  have been reviewed.
- Bundling a core does not bundle firmware, BIOS files, games, or other
  copyrighted content. OpenVault obtains game content from the user's RomM
  library and obtains firmware from RomM's system-level firmware API using the
  paired token's `firmware.read` scope.
- Firmware is selected by RomM platform and exact manifest filename, verified
  against RomM's SHA-1 and manifest-declared hashes, and cached in Application
  Support under server and platform identities. A verified cached copy can be
  reused offline. Firmware is not inferred from `[BIOS]` game rows.
- Library validation remains enabled. OpenVault will not weaken the hardened
  runtime merely to support third-party or unsigned core binaries.
- The frontend bridge is implemented in Swift against Libretro API version 1.
  Explicit ARM64 C layouts are kept at the ABI boundary rather than leaking
  Libretro types through the feature layer.
- One serial runtime queue owns one active core session. A global callback
  router is acceptable only while the product supports exactly one active
  session.
- Software frames are presented by a dedicated Metal pipeline with explicit
  nearest-neighbor sampling and integer scaling whenever the source fits.
  Hardware-rendered cores receive an OpenGL 4.1 context and feed their
  completed frames into that same Metal presentation path. No Core Image
  resampling is used. Audio uses `AVAudioEngine`, and input maps one keyboard
  or `GameController` to the digital and analog controls on RetroPad port 0.
- The reviewed catalog supports Game Boy, Game Boy Color, Game Boy Advance,
  NES, SNES, Master System, Game Gear, SG-1000, Atari 2600, Atari 7800,
  Virtual Boy, Neo Geo Pocket and Pocket Color, WonderSwan and WonderSwan
  Color, Pokémon Mini, PlayStation, Nintendo DS, PC Engine / TurboGrafx-16,
  SuperGrafx, CHD-based PC Engine CD / TurboGrafx-CD, GameCube, and PSP. The
  2048 core remains a content-free pipeline and runtime test.
- Runtime ROMs use a disposable 20 GB cache keyed by server, game, and content
  version. A cache hit can launch offline; a cache miss still requires RomM.
- ZIP-wrapped games use ZIPFoundation 0.9.20. OpenVault selects a regular
  archive member whose extension is declared by the chosen core. A selected
  CUE or M3U descriptor brings along safe regular-file companions from the same
  archive directory; other archive paths, symbolic links, metadata entries,
  and unrelated files are never materialized.
- Local save RAM and quick states are isolated per core and game. Changed
  cartridge save memory is uploaded as a new RomM save revision when a session
  ends; existing server revisions are never overwritten. Every launch performs
  a fresh RomM game-details request before core startup so a newer remote
  cartridge save can be reconciled. Offline launches immediately retain the
  local save, and unsynchronized local data is never overwritten.

## Library presentation

- All Games defaults to a native sortable List view; individual systems default
  to the artwork gallery. Collections default to List.
- Each scope remembers a manual List or Artwork override independently.
- List always shows Game, System, Save, and State initially. The Game column
  cannot be hidden. Its leading edge reserves a compact play glyph for games
  that can be opened by a bundled core; unsupported or unavailable games keep
  the same text alignment without showing the glyph.
- Playable Artwork cards reveal a restrained direct-play control over the cover
  on pointer hover. Preparing a game keeps that control visible as progress,
  while clicking elsewhere on the card continues to open game details.
- Native SwiftUI table column customization supplies the header context menu,
  column reordering, resizing, and persisted visibility. Optional columns
  include status, completion, rating, difficulty, region, file size, artwork,
  identification, missing-file status, and update date.
- The List column browser supports a persisted Downloaded column alongside
  system and metadata filters. It can restrict the current list to games that
  are or are not available locally. Downloaded is visible by default and uses
  iTunes-style cloud download status iconography.
- List and Artwork context menus expose the same transfer actions. Download
  adds one or more ROMs to OpenVault's durable local library and immediately
  updates Downloaded membership. For locally available games that action
  becomes Remove Download, which deletes both durable and playback-cache ROM
  copies while leaving the RomM game, metadata, saves, and exported files
  untouched. Export writes collision-safe copies to the user's Downloads
  folder without changing local-library membership.
- Save and state checkmarks are synchronized as server-filtered ID sets during
  the normal library refresh. OpenVault does not issue a detail request for
  every game.
- Library synchronization, cached/offline state, failure state, total game
  count, and last refresh time appear in a compact footer at the lower-left of
  the sidebar rather than consuming toolbar space.

## Dependencies

Milestone 1A uses Apple frameworks:

- SwiftUI
- Observation
- Foundation and `URLSession`
- OSLog
- SwiftData

Nuke 13 provides the artwork
pipeline's async loading, request coalescing, image processing, and bounded
memory and disk caches. OpenVault depends on Nuke's core product,
not its ready-made SwiftUI views, so the app retains control of its native UI.

ZIPFoundation 0.9.20 provides focused ZIP parsing and single-entry extraction
for Libretro content. OpenVault owns core compatibility, archive member
selection, cache placement, limits, and user-facing errors.

Swift OpenAPI Generator is deliberately deferred. OpenVault will begin with a
small hand-written RomM client and reconsider generation after several stable
endpoints demonstrate that the generated surface would reduce rather than add
complexity.

OpenVault should not initially depend on another networking framework,
state-management framework, dependency-injection container, or credential
storage wrapper.

The Apple Containerization package is deferred until milestone 1B.

## Diagnostics

- OpenVault writes structured diagnostics to the macOS unified log under the
  `org.kennethreitz.OpenVault` subsystem, with separate application,
  connection, networking, library, and Libretro categories.
- Settings opens a native viewer that reads only this process's recent unified
  log entries, refreshes live, and supports level filtering, text search, and
  copying. OpenVault does not maintain a second persistent log store or
  generate executable diagnostic scripts.
- Diagnostic messages never include pairing codes, client tokens, request
  headers, or response bodies. Dynamic error details remain private in unified
  logging unless explicitly classified as safe.

## Deferred capabilities

The following are intentionally outside milestone 1A and remain deferred unless
assigned to a later milestone:

- External emulator runners
- Automatic or bulk ROM downloads outside explicit user actions
- Save and state synchronization
- OIDC
- Multiple servers
- Plugin architecture
- Persistent local-server operation while OpenVault is closed

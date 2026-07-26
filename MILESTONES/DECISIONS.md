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

## Application structure

OpenVault begins as a modular monolith with one application target and explicit
internal boundaries:

```text
OpenVault/
    App/
    UI/
    Features/
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
  `collections.read`, and `roms.user.write`. The write scope is limited to
  personal game state such as completion, rating, difficulty, play status,
  backlog, now-playing, and hidden flags.
- OpenVault should explain missing-scope failures rather than presenting a
  generic networking error.
- OIDC is an extension point, not an initial deliverable.

## Library navigation

- The primary library uses a native `NavigationSplitView`.
- The initial sidebar contains All Games, Systems, and Collections.
- "Systems" is the user-facing name for RomM platforms.
- Systems with games are shown directly. Empty systems are collapsed under an
  Empty Systems disclosure at the bottom of the Systems section so future
  upload targets remain reachable without cluttering everyday browsing.
- User-created and smart RomM collections are presented together as read-only
  navigation destinations.
- RomM virtual collections span generated genres, franchises, modes, and other
  filters; they are deferred to a dedicated filtering experience rather than
  flooding the primary sidebar.
- Every destination filters one shared, incrementally paginated cover grid.
- The standard macOS toolbar search field filters the active destination through
  RomM's server-side search, so results cover the full remote library rather
  than only the currently loaded page.
- A Search All Systems checkbox appears for scoped searches and can temporarily
  lift the active system or collection filter without changing the sidebar
  selection.
- Firmware records whose metadata name or filename begins with `[BIOS]` are not
  presented as games. OpenVault asks RomM to exclude the `BIOS` tag so totals
  and pagination remain server-authoritative, then applies the same
  case-insensitive prefix rule locally as a defensive fallback.
- A library filter can hide games that do not expose artwork. This is applied to
  the incrementally loaded results because RomM 5.0 does not expose a dedicated
  has-artwork query filter. While the filter is active, OpenVault also inspects
  and caches each populated system's games, hiding a system from the primary
  list only after confirming it has no artwork. Empty systems remain available
  in their disclosure as future upload targets. The user's filter choice is
  persisted as a non-secret application preference and restored on launch.
- Cover cards keep a consistent footprint while fitting the complete source
  image, preserving unusually wide or tall artwork without distortion.
- Collection editing, smart-filter creation, and other RomM mutations remain
  outside the first slice.

## Game details

- A game card pushes a full-page destination inside the detail column's native
  `NavigationStack`; it does not open a sheet or a separate window.
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
- The details header offers an authenticated, user-initiated ROM download.
  OpenVault streams RomM's single-file or multipart ZIP response to macOS
  Downloads, preserves the server-provided name, and adds a numeric suffix
  instead of overwriting an existing file. This is an explicit export, not a
  managed library or offline ROM cache.
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
- Artwork uses a 512 MB bounded disk cache separate from SwiftData.
- The initial offline promise covers all synchronized metadata and previously
  downloaded artwork.
- Offline ROM binary caching is not part of the first milestone.
- The local cache is replaceable and never becomes a second source of truth.
- Explicitly disconnecting the server clears its metadata cache along with the
  stored configuration and client token.
- Settings offers two client-side maintenance actions. Resync fetches and
  transactionally replaces a complete RomM metadata snapshot while preserving
  the prior cache on failure. Purge Local Cache & Resync first removes
  OpenVault's disposable metadata, viewed-game details, and artwork caches,
  then rebuilds them from RomM after explicit confirmation. Neither action
  deletes exported ROMs, saves, or playback data, and neither initiates a RomM
  server scan.

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
  library and identifies missing firmware requirements without supplying that
  firmware.
- Library validation remains enabled. OpenVault will not weaken the hardened
  runtime merely to support third-party or unsigned core binaries.
- The frontend bridge is implemented in Swift against Libretro API version 1.
  Explicit ARM64 C layouts are kept at the ABI boundary rather than leaking
  Libretro types through the feature layer.
- One serial runtime queue owns one active core session. A global callback
  router is acceptable only while the product supports exactly one active
  session.
- Software frames are presented with Metal/Core Image, audio uses
  `AVAudioEngine`, and input maps one keyboard or `GameController` to RetroPad
  port 0.
- Gambatte is the first user-facing core and supports Game Boy and Game Boy
  Color. The 2048 core remains a content-free pipeline and runtime test.
- Runtime ROMs use a disposable 20 GB cache keyed by server, game, and content
  version. A cache hit can launch offline; a cache miss still requires RomM.
- ZIP-wrapped games use ZIPFoundation 0.9.20. OpenVault selects one regular
  archive member whose extension is declared by the chosen core, extracts it
  inside the disposable runtime cache, and never materializes archive paths,
  symbolic links, metadata entries, or unrelated files.
- Local save RAM and quick states are isolated per core and game. Automatic
  upload or replacement of RomM save data remains deferred.

## Library presentation

- All Games defaults to a native sortable List view; individual systems default
  to the artwork gallery. Collections default to List.
- Each scope remembers a manual List or Artwork override independently.
- List always shows Game, System, Save, and State initially. The Game column
  cannot be hidden.
- Native SwiftUI table column customization supplies the header context menu,
  column reordering, resizing, and persisted visibility. Optional columns
  include status, completion, rating, difficulty, region, file size, artwork,
  identification, missing-file status, and update date.
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
pipeline's async loading, request coalescing, prefetching, image processing,
and bounded memory and disk caches. OpenVault depends on Nuke's core product,
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
- Automatic or bulk ROM downloads outside the bounded on-demand runtime cache
- Save and state synchronization
- OIDC
- Multiple servers
- Plugin architecture
- Persistent local-server operation while OpenVault is closed

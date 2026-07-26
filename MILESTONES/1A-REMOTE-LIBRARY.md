# Milestone 1A — Remote Library

## Goal

Connect OpenVault to one paired remote RomM 5.0 server and present the user's
library as a fast, native macOS experience that remains useful offline.

## Connection flow

1. The user enters the RomM server URL.
2. OpenVault verifies reachability and compatible server behavior.
3. The user enters an eight-character alphanumeric pairing code or an existing
   client API token.
4. OpenVault exchanges the pairing code when necessary.
5. During development, the client token is stored in OpenVault's sandboxed
   Application Support directory with owner-only permissions.
6. OpenVault validates the authenticated connection and required scopes.
7. Initial library synchronization begins.

No secret is written to source code, logs, fixtures, or ordinary preferences.
Keychain storage remains required before a release build ships.

## In scope

- macOS 26, Apple silicon application target
- Native SwiftUI application shell
- One remote server configuration
- HTTPS and explicitly configured local-network HTTP
- RomM 5.0 client-token authentication and pairing
- Sandboxed credential storage for development, with Keychain migration
  required before release
- Platforms and paginated library metadata
- Read-only user-created, smart, and automatic virtual collections
- Built-in Downloaded collection for local ROM availability
- DTO-to-domain mapping
- SwiftData metadata cache
- Background refresh and reconciliation
- Offline library browsing
- Cache-first game details with a summary fallback for unvisited games
- Offline metadata search
- Bounded artwork disk cache
- Native library grid
- Game selection and an initial details presentation
- Editable per-user game progress, rating, difficulty, status, and activity flags
- Authenticated, user-initiated download into OpenVault's managed local library
- Explicit export of selected games to macOS Downloads
- Loading, empty, offline, stale, permission, and failure states
- Request, decoding, mapping, repository, cache, and feature-state tests

## Acceptance criteria

- A fresh installation can connect using a valid pairing code without storing
  the user's account password.
- The initial sidebar presents All Games, Systems, and Collections from RomM.
- Automatic virtual collections remain collapsed by default, can be expanded
  as a separate sidebar group, and remain navigable from the cached library
  while RomM is unavailable.
- Selecting a game opens a full-page native details view with its artwork,
  description, normalized metadata, user state, files, hashes, related-content
  counts, and screenshots.
- The details view lists the connected user's RomM saves and save states in a
  read-only Save Data tab, including file metadata and state screenshots when
  available.
- Completion, rating, difficulty, play status, backlog, now-playing, and hidden
  state can be edited in the details view and are persisted to RomM.
- One or more selected games can be downloaded into OpenVault's managed local
  library without loading complete ROMs into memory.
- One or more selected games can be exported to macOS Downloads without
  overwriting existing files. Exporting does not change Downloaded membership.
- Downloaded status is available as a persisted List column-browser filter and
  includes managed downloads and games retained by the playback cache. The
  filter is visible by default and uses cloud download status iconography.
- One or more selected games can be removed from RomM through a destructive
  context-menu action with explicit confirmation. Server-file deletion is a
  separate opt-in choice.
- OpenVault relaunches into the cached library without waiting for the network.
- A successful refresh updates changed games and removes games no longer
  returned by RomM.
- Snapshot replacement is transactional: an interrupted or partially failed
  synchronization leaves the previous complete snapshot untouched.
- A failed refresh leaves the cached library usable and clearly indicates that
  it may be stale.
- Search works while disconnected.
- Large libraries load incrementally without blocking the main actor.
- BIOS and firmware entries conventionally named with a leading `[BIOS]` marker
  are hidden by default through a persisted library filter, but can be revealed
  from the filter checklist without requiring RomM to be online.
- Artwork loading is cancellable. Library and collection views fetch the
  canonical cover they display on demand into a bounded 10 GB disk cache;
  metadata synchronization does not prefetch the complete library.
- Authentication, permission, decoding, and transport errors produce distinct,
  actionable messages.
- Network and persistence implementations can be replaced by test doubles at
  the repository boundary.
- No game-launching or managed offline ROM-binary cache is present.

## Out of scope

- Managed local RomM
- Multiple servers
- Username/password and OIDC login unless needed as a narrowly scoped fallback
- Game launching
- Emulator runners
- Automatic or bulk ROM downloads
- Save and state synchronization
- Collections editing and RomM mutations other than confirmed game deletion
- Plugin APIs

## Completion boundary

Milestone 1A is complete when a signed development build can pair with the
target remote RomM server, display and search its library, relaunch from its
cache without a network connection, and reconcile successfully after
connectivity returns.

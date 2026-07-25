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
5. The client token is stored in Keychain.
6. OpenVault validates the authenticated connection and required scopes.
7. Initial library synchronization begins.

No secret is written to source code, logs, fixtures, or ordinary preferences.

## In scope

- macOS 26, Apple silicon application target
- Native SwiftUI application shell
- One remote server configuration
- HTTPS and explicitly configured local-network HTTP
- RomM 5.0 client-token authentication and pairing
- Keychain credential storage
- Platforms and paginated library metadata
- Read-only user-created and smart collections
- DTO-to-domain mapping
- SwiftData metadata cache
- Background refresh and reconciliation
- Offline library browsing
- Offline metadata search
- Bounded artwork disk cache
- Native library grid
- Game selection and an initial details presentation
- Loading, empty, offline, stale, permission, and failure states
- Request, decoding, mapping, repository, cache, and feature-state tests

## Acceptance criteria

- A fresh installation can connect using a valid pairing code without storing
  the user's account password.
- The initial sidebar presents All Games, Systems, and Collections from RomM.
- OpenVault relaunches into the cached library without waiting for the network.
- A successful refresh updates changed games and removes games no longer
  returned by RomM.
- A failed refresh leaves the cached library usable and clearly indicates that
  it may be stale.
- Search works while disconnected.
- Large libraries load incrementally without blocking the main actor.
- Artwork loading is cancellable and does not cause unbounded memory or disk
  growth.
- Authentication, permission, decoding, and transport errors produce distinct,
  actionable messages.
- Network and persistence implementations can be replaced by test doubles at
  the repository boundary.
- No game-launching or ROM-download behavior is present.

## Out of scope

- Managed local RomM
- Multiple servers
- Username/password and OIDC login unless needed as a narrowly scoped fallback
- Game launching
- Emulator runners
- ROM downloads or offline ROM binary storage
- Save and state synchronization
- Collections editing and other RomM mutations
- Plugin APIs

## Completion boundary

Milestone 1A is complete when a signed development build can pair with the
target remote RomM server, display and search its library, relaunch from its
cache without a network connection, and reconcile successfully after
connectivity returns.

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
- Features do not access `URLSession`, Keychain, or SwiftData directly.
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
- Username and password authentication may be added as a fallback.
- Tokens, passwords, and generated secrets are stored in Keychain.
- Secrets must never be stored in source code, fixtures, logs, or ordinary
  preferences.
- OpenVault requests only the scopes required by the features it implements.
- OpenVault should explain missing-scope failures rather than presenting a
  generic networking error.
- OIDC is an extension point, not an initial deliverable.

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
- A failed refresh preserves the last successful library and exposes a clear
  stale or offline state.
- Search operates against cached metadata and remains available offline.
- Artwork uses a bounded disk cache separate from SwiftData.
- The initial offline promise covers all synchronized metadata and previously
  downloaded artwork.
- Offline ROM binary caching is not part of the first milestone.
- The local cache is replaceable and never becomes a second source of truth.

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

## Dependencies

Milestone 1A should use Apple frameworks:

- SwiftUI
- Observation
- Foundation and `URLSession`
- Security
- OSLog
- SwiftData

It should not initially depend on a networking framework, state-management
framework, dependency-injection container, Keychain wrapper, or image-loading
package.

The Apple Containerization package is deferred until milestone 1B.

## Deferred capabilities

The following are intentionally outside the initial milestones:

- Game launching
- Emulator runners
- Embedded libretro
- ROM downloads and binary caching
- Save and state synchronization
- OIDC
- Multiple servers
- Plugin architecture
- Persistent local-server operation while OpenVault is closed

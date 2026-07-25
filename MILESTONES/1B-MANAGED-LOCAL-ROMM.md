# Milestone 1B — Managed Local RomM

## Goal

Allow a user without an external server to select an existing ROM library and
have OpenVault provision and manage a local RomM installation using Apple's
container technologies.

The rest of OpenVault must consume the managed instance through the same RomM
API boundary used by milestone 1A.

## Runtime shape

OpenVault manages:

- A pinned native ARM64 RomM container image
- A pinned native ARM64 MariaDB container image
- Private container networking
- Persistent MariaDB storage
- Persistent RomM resources, Redis data, assets, and configuration
- Generated secrets stored in Keychain
- A read-only mount of the user-selected ROM library

The container implementation is isolated behind an OpenVault-owned
`ContainerRuntime` protocol.

## In scope

- Apple Containerization package integration
- Signed and notarized application entitlements
- Security-scoped library-folder selection
- Managed writable storage under Application Support
- Image pulling with visible progress
- First-run storage and secret generation
- Database startup and health checking
- RomM startup and health checking
- Initial RomM setup handoff
- Clean shutdown when OpenVault quits
- Relaunch reconciliation after an interrupted or unclean shutdown
- Actionable logs and recovery states
- A local-server reset operation that preserves the user's ROM files

## Acceptance criteria

- A user can select a ROM directory without copying or reorganizing it.
- The selected directory is mounted read-only.
- OpenVault can pull and start the pinned stack on a clean macOS 26 Apple
  silicon installation without Docker.
- OpenVault does not report readiness until MariaDB and RomM are healthy.
- Once ready, the existing milestone 1A library flow works without a
  local-server-specific UI path.
- Quitting OpenVault stops the managed stack cleanly.
- Relaunching restores the managed instance using its persistent database and
  resources.
- Interrupted startup and stale runtime state can be detected and recovered.
- Resetting managed infrastructure never deletes or modifies the user's ROM
  library.
- Container logs expose enough information to diagnose startup failures without
  leaking secrets.

## Required technical spike

Before building the complete setup experience, a signed development build must
prove:

1. Pulling both ARM64 OCI images
2. Creating persistent writable storage
3. Mounting a security-scoped host directory read-only
4. Private communication between RomM and MariaDB
5. Host communication with the RomM HTTP endpoint
6. Health checks and startup ordering
7. Graceful stop and subsequent restart
8. Recovery after forced termination

## Out of scope

- Importing or copying the ROM library
- Writable ROM-library mounts
- Running the local server permanently after OpenVault quits
- Exposing the managed server to other devices
- Docker or Docker Compose
- Automatic migration from an unrelated RomM installation
- Game launching
- Save synchronization

## Completion boundary

Milestone 1B is complete when a signed development build can create, stop,
restart, and recover a local RomM stack and then display its library through the
same repository and UI used for a paired remote server.

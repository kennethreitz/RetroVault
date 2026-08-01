# Vita3K hosted-engine spike

RetroVault can optionally load a pinned Vita3K engine and give it a native
`NSView` backed by `CAMetalLayer`. Vita3K creates its Vulkan surface from that
view, so Vita output lives inside RetroVault's existing player rather than a
captured or nested Vita3K window.

This is an experimental technical preview. It is absent from ordinary builds,
Vita remains hidden unless Experimental Cores is enabled, and the engine is
only offered when a local build artifact is present.

Build it with:

```sh
Scripts/build-vita3k-engine.sh
Scripts/build-app.sh
```

The first launch uses a separate `RetroVault/Vita3K` application-support
directory without changing the Libretro installation. RetroVault discovers
`.PUP` packages uploaded as system firmware for the game's Vita platform in
the authenticated RomM server, validates and caches them, then installs them
into that private Vita environment. Game archives remain managed RetroVault
downloads; Vita3K installs their contents into its private environment.

## Distribution boundary

Vita3K currently declares GPL-2.0-only while RetroVault is GPL-3.0. The hosted
engine proves the integration but must not ship in a public RetroVault release
until the projects establish a compatible licensing boundary. The bridge is
therefore dynamically loaded, locally built, and never fetched by the app.

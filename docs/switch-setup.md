# Nintendo Switch setup

RetroVault hosts **Ryubing** (the maintained Ryujinx fork) for Nintendo Switch
games. Ryubing is not bundled and is not downloaded by RetroVault.

## Requirements

- Apple-silicon Mac, macOS 15 or later.
- Ryubing: either
  - the official `Ryujinx.app` **Canary 1.3.352** embedded by the build
    (stable 1.3.3 hangs loading some titles on macOS 27), or
  - a newer Canary `Ryujinx.app` in `/Applications` or `~/Applications` for
    an unsandboxed development build.
- `prod.keys` from your own console. `title.keys` is optional.
- Switch firmware dumped from your own console. Recommended: some titles need
  it for system services and fonts.

The sandboxed app cannot execute a binary outside its bundle. Nix users can
install `nixpkgs#ryubing` for standalone use, but RetroVault itself needs the
official `.app` embedded:

```sh
Scripts/fetch-ryujinx-companion.sh   # downloads and verifies Ryubing Canary 1.3.352
Scripts/build-app.sh                 # Xcode build phase embeds it
```

Do not re-sign `Ryujinx.app`; the embed phase copies it untouched because
re-signing its nested frameworks breaks startup after `Loading sdk`.

For development, `nix profile install nixpkgs#ryubing` gives you a `Ryujinx`
CLI to test independently. RetroVault will only use it when the app is built
without a sandbox (for example, `swift run`).

Switch 2 is not supported. There is no maintained macOS engine with a stable
save format; RetroVault leaves those titles catalog-only.

## Install the system files

1. Open **Settings → Nintendo Switch**.
2. Choose **prod.keys**. RetroVault copies it into its private data root with
   owner-only permissions.
3. Optionally choose **title.keys**.
4. Choose **Firmware Folder or ZIP**. Select the dumped `registered` folder,
   its parent (`.../Contents` or the firmware root), or a ZIP containing one.
   RetroVault copies the `.nca` files into Ryujinx's private NAND.

Nothing is uploaded to RomM. RetroVault does not read, log, or include keys or
firmware in save bundles.

## Data isolation

RetroVault launches Ryujinx with `-r` pointing at RetroVault's own
`Application Support/RetroVault/Switch/Ryujinx` folder (inside the sandbox
container in a signed build). Your own Ryujinx profile, saves, and firmware
under `~/Library/Application Support/Ryujinx` are not touched.

The engine is launched with:

```text
Ryujinx -r <private root> -g vulkan --docked-mode [-f] <game>
```

`vulkan` is Ryujinx's bundled MoltenVK backend on macOS. RetroVault does not
create a Vulkan context.

## Input

Ryujinx reads keyboards and gamepads directly through SDL. RetroVault cannot
inject synthetic input into an external app, so:

- Keyboard play works with Ryujinx's default bindings.
- Configure a controller once in Ryujinx's **Input** settings. The configuration
  is stored in the shared private root and survives later launches.
- For automatic keyboard/controller switching, enable **Dynamic Input Swap**
  for Player 1 and tick each controller once. Ryujinx has no Libretro-style
  per-device autoconfig, so a newly connected controller needs one assignment.
- RetroVault's DSU/Cemuhook controller pipeline is not used for Switch. Ryujinx's
  CemuHook support is motion-only.

## Saves

Switch saves live under `bis/user/save/<base title id>`. Some titles also use
**device save data** at `bis/user/save/0000000000000001`; its `ExtraData0/1`
records the owning title ID. RetroVault links both the title folder and any
matching device-save folder into its managed `Ryujinx` bundle, so the normal
Save Center and RomM `directoryBundle` sync work:

- Before launch, a newer RomM save is restored into the bundle.
- After exit, a changed bundle is uploaded as a `.ryujinx.zip` autosave.
- Device saves written during the first session are adopted before the upload.
- Offline play keeps the local bundle and retries from Save Center.

The managed bundle now has `title/` and `device/<save-data-id>/` subtrees.

RetroVault resolves the base title ID from RomM's `save_target`, then `title_id`,
then the `[TITLEID]` token RomM embeds in Switch file names, and finally from the
downloaded NSP filename when RomM details are unavailable offline.

**Save states are not supported.** Ryubing has none, and RomM's Switch
capability record has no save-state slots.

## Troubleshooting

- **"RetroVault could not find Ryubing"**: install `Ryujinx.app` and relaunch
  RetroVault.
- **"Switch games need prod.keys"**: import `prod.keys` in Settings.
- **"HTTP 413" saving**: the reverse proxy body limit is too low. nginx
  defaults to 1 MB; a Switch save bundle can exceed that. Raise it to `128m`
  (RomM's ROM uploader uses 64 MB chunks, so `32m` would break ROM uploads).
  A single multi-gigabyte Switch ROM never travels as one request; Cloudflare
  also caps requests at 100 MB, so chunked upload is the correct path.
- **Missing firmware/services in a game**: import the dumped `registered`
  folder in Settings.
- **Title ID error**: rescan the game in RomM so sigil records its identity.
- **Controller ignored**: open Ryujinx's Input settings and assign Player 1
  once. RetroVault preserves that configuration.

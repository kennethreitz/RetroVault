#!/bin/sh

set -eu

stable_artifact_directory="$SRCROOT/Build/CemuCompanion"
metal_artifact_directory="$SRCROOT/Build/CemuMetalCompanion"
artifact_directory="$stable_artifact_directory"
if [ -x "$metal_artifact_directory/Cemu.app/Contents/MacOS/Cemu" ] \
  && [ -f "$metal_artifact_directory/Cemu.app/Contents/Resources/RetroVaultMetalRenderer" ]; then
  artifact_directory="$metal_artifact_directory"
  echo "note: Embedding the native Cemu Metal trial companion."
fi
source_application="$artifact_directory/Cemu.app"
if [ ! -x "$source_application/Contents/MacOS/Cemu" ]; then
  echo "note: No Cemu companion found; skipping Wii U support."
  echo "note: Run Scripts/fetch-cemu-companion.sh to enable it."
  exit 0
fi

if [ ! -f "$source_application/Contents/Resources/RetroVaultDSURumble" ]; then
  echo "note: This Cemu companion does not include RetroVault DSU rumble."
  if [ "$artifact_directory" = "$metal_artifact_directory" ]; then
    echo "note: The stable Cemu 2.6 companion remains available as a fallback."
  else
    echo "note: Build it with a macOS 14/Xcode 15-compatible toolchain to enable it."
  fi
fi

plugins_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/PlugIns"
resources_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Cemu"
destination_application="$plugins_directory/Cemu.app"
mkdir -p "$plugins_directory" "$resources_directory"
cp "$artifact_directory/COPYING-Cemu.txt" \
  "$resources_directory/COPYING-Cemu.txt"

# LaunchServices does not reliably forward command-line arguments to an app
# opened through `open`, while RetroVault's sandbox cannot execute a writable
# Application Support copy directly. Keep the original Cemu binary alongside
# a tiny bundle launcher. The launcher reads RetroVault's atomic request file,
# then execs the original binary with Cemu's normal quick-launch arguments.
signing_identity="-"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] \
  && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  signing_identity="$EXPANDED_CODE_SIGN_IDENTITY"
fi

embed_companion() {
  embed_source_application="$1"
  embed_destination_application="$2"
  rm -rf "$embed_destination_application"
  ditto "$embed_source_application" "$embed_destination_application"
  mv "$embed_destination_application/Contents/MacOS/Cemu" \
    "$embed_destination_application/Contents/MacOS/Cemu.real"
  cp "$SRCROOT/Scripts/cemu-launcher.sh" \
    "$embed_destination_application/Contents/MacOS/Cemu"
  chmod 755 \
    "$embed_destination_application/Contents/MacOS/Cemu" \
    "$embed_destination_application/Contents/MacOS/Cemu.real"
  codesign --force --deep --sign "$signing_identity" --timestamp=none \
    "$embed_destination_application"
}

embed_companion "$source_application" "$destination_application"
echo "Embedded Cemu companion in $destination_application"

vulkan_fallback_application="$plugins_directory/CemuVulkan.app"
if [ "$artifact_directory" = "$metal_artifact_directory" ] \
  && [ -x "$stable_artifact_directory/Cemu.app/Contents/MacOS/Cemu" ]; then
  embed_companion \
    "$stable_artifact_directory/Cemu.app" \
    "$vulkan_fallback_application"
  cp "$stable_artifact_directory/COPYING-Cemu.txt" \
    "$resources_directory/COPYING-Cemu-Vulkan.txt"
  echo "Embedded stable Cemu Vulkan fallback in $vulkan_fallback_application"
else
  rm -rf "$vulkan_fallback_application"
  rm -f "$resources_directory/COPYING-Cemu-Vulkan.txt"
fi

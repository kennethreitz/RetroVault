#!/bin/sh

set -eu

artifact_directory="$SRCROOT/Build/CemuCompanion"
source_application="$artifact_directory/Cemu.app"
if [ ! -x "$source_application/Contents/MacOS/Cemu" ]; then
  echo "note: No Cemu companion found; skipping Wii U support."
  echo "note: Run Scripts/fetch-cemu-companion.sh to enable it."
  exit 0
fi

if [ ! -f "$source_application/Contents/Resources/RetroVaultDSURumble" ]; then
  echo "note: This Cemu companion does not include RetroVault DSU rumble."
  echo "note: Run Scripts/build-cemu-companion.sh to enable it."
fi

plugins_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/PlugIns"
resources_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Cemu"
destination_application="$plugins_directory/Cemu.app"
mkdir -p "$plugins_directory" "$resources_directory"
rm -rf "$destination_application"
ditto "$source_application" "$destination_application"
cp "$artifact_directory/COPYING-Cemu.txt" \
  "$resources_directory/COPYING-Cemu.txt"

# LaunchServices does not reliably forward command-line arguments to an app
# opened through `open`, while RetroVault's sandbox cannot execute a writable
# Application Support copy directly. Keep the original Cemu binary alongside
# a tiny bundle launcher. The launcher reads RetroVault's atomic request file,
# then execs the original binary with Cemu's normal quick-launch arguments.
mv "$destination_application/Contents/MacOS/Cemu" \
  "$destination_application/Contents/MacOS/Cemu.real"
cp "$SRCROOT/Scripts/cemu-launcher.sh" \
  "$destination_application/Contents/MacOS/Cemu"
chmod 755 \
  "$destination_application/Contents/MacOS/Cemu" \
  "$destination_application/Contents/MacOS/Cemu.real"

signing_identity="-"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] \
  && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  signing_identity="$EXPANDED_CODE_SIGN_IDENTITY"
fi

codesign --force --deep --sign "$signing_identity" --timestamp=none \
  "$destination_application"
echo "Embedded Cemu companion in $destination_application"

#!/bin/sh

set -eu

artifact_directory="$SRCROOT/Build/CemuCompanion"
source_application="$artifact_directory/Cemu.app"
if [ ! -x "$source_application/Contents/MacOS/Cemu" ]; then
  echo "note: No Cemu companion found; skipping Wii U support."
  echo "note: Run Scripts/fetch-cemu-companion.sh to enable it."
  exit 0
fi

plugins_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/PlugIns"
resources_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Cemu"
destination_application="$plugins_directory/Cemu.app"
mkdir -p "$plugins_directory" "$resources_directory"
rm -rf "$destination_application"
ditto "$source_application" "$destination_application"
cp "$artifact_directory/COPYING-Cemu.txt" \
  "$resources_directory/COPYING-Cemu.txt"

signing_identity="-"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] \
  && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  signing_identity="$EXPANDED_CODE_SIGN_IDENTITY"
fi

codesign --force --deep --sign "$signing_identity" --timestamp=none \
  "$destination_application"
echo "Embedded Cemu companion in $destination_application"

#!/bin/sh

set -eu

artifact_directory="$SRCROOT/Build/RyujinxCompanion"
source_application="$artifact_directory/Ryujinx.app"
if [ ! -x "$source_application/Contents/MacOS/Ryujinx" ]; then
  echo "note: No Ryubing companion found; skipping Switch support."
  echo "note: Run Scripts/fetch-ryujinx-companion.sh to enable it."
  exit 0
fi

plugins_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/PlugIns"
resources_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Ryujinx"
destination_application="$plugins_directory/Ryujinx.app"
mkdir -p "$plugins_directory" "$resources_directory"
rm -rf "$destination_application"
ditto "$source_application" "$destination_application"
if [ -f "$artifact_directory/COPYING-Ryujinx.txt" ]; then
  cp "$artifact_directory/COPYING-Ryujinx.txt" \
    "$resources_directory/COPYING-Ryujinx.txt"
fi

# Do not re-sign Ryujinx. Re-signing its nested frameworks with an ad-hoc
# signature makes the emulator hang after "Loading sdk". The official app's
# original ad-hoc signature must stay intact; the outer RetroVault signature
# seals it as copied.
echo "Embedded Ryubing companion in $destination_application"

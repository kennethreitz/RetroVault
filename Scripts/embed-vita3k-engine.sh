#!/bin/sh

set -eu

artifact_directory="$SRCROOT/Build/Vita3KEngine"
if [ ! -f "$artifact_directory/PlugIns/RetroVaultVita3K.dylib" ]; then
  echo "note: No experimental Vita3K engine found; skipping Vita support."
  exit 0
fi

plugins_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/PlugIns/Vita3K"
resources_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Vita3K"
mkdir -p "$plugins_directory" "$resources_directory"
ditto "$artifact_directory/PlugIns" "$plugins_directory"
ditto "$artifact_directory/Resources" "$resources_directory"
cp "$artifact_directory/COPYING-Vita3K.txt" \
  "$resources_directory/COPYING-Vita3K.txt"

signing_identity="-"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] \
  && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  signing_identity="$EXPANDED_CODE_SIGN_IDENTITY"
fi

find "$plugins_directory" -type f -name '*.dylib' -print0 |
while IFS= read -r -d '' library; do
  codesign --force --sign "$signing_identity" --timestamp=none "$library"
done

echo "Embedded experimental Vita3K engine in $plugins_directory"

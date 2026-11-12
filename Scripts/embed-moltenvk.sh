#!/bin/sh
#
# Embeds the pinned MoltenVK runtime beside the app and signs it with the app's
# own identity. Library validation under the hardened runtime requires every
# loaded dylib to share the app's Team ID; the upstream tarball is ad-hoc
# signed and would be rejected.

set -eu

artifact_directory="$SRCROOT/Build/MoltenVK"
dylib="$artifact_directory/libMoltenVK.dylib"

if [ ! -f "$dylib" ]; then
  if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    echo "error: Release builds require MoltenVK." >&2
    echo "error: Run Scripts/fetch-moltenvk.sh before archiving." >&2
    exit 1
  fi

  echo "note: No MoltenVK runtime found; skipping Vulkan support for this development build."
  exit 0
fi

frameworks_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Frameworks"
resources_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Acknowledgements"
mkdir -p -- "$frameworks_directory" "$resources_directory"

cp "$dylib" "$frameworks_directory/libMoltenVK.dylib"
cp "$artifact_directory/LICENSE" "$resources_directory/MoltenVK-LICENSE.txt"

signing_identity="-"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] \
  && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  signing_identity="$EXPANDED_CODE_SIGN_IDENTITY"
fi

if [ "$signing_identity" = "-" ]; then
  codesign --force --sign - --timestamp=none "$frameworks_directory/libMoltenVK.dylib"
else
  if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    codesign \
      --force \
      --sign "$signing_identity" \
      --options runtime \
      --timestamp \
      "$frameworks_directory/libMoltenVK.dylib"
  else
    codesign \
      --force \
      --sign "$signing_identity" \
      --options runtime \
      --timestamp=none \
      "$frameworks_directory/libMoltenVK.dylib"
  fi
fi

echo "Embedded MoltenVK in $frameworks_directory"

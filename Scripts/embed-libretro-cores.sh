#!/bin/sh

set -eu

artifact_directory="$SRCROOT/Build/LibretroCores"

case "${TARGET_BUILD_DIR:-}" in
    ""|/)
        echo "error: Refusing to embed resources without a safe TARGET_BUILD_DIR." >&2
        exit 1
        ;;
esac

acknowledgements_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Acknowledgements"
mkdir -p -- "$acknowledgements_directory"
ditto "$SRCROOT/THIRD_PARTY_NOTICES.md" \
    "$acknowledgements_directory/THIRD_PARTY_NOTICES.md"

if [ ! -d "$artifact_directory/Cores" ]; then
    if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
        echo "error: Release builds require bundled core artifacts." >&2
        echo "error: Run Scripts/build-libretro-cores.sh before archiving." >&2
        exit 1
    fi

    echo "note: No Libretro artifacts found; skipping cores for this development build."
    exit 0
fi

plugins_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/PlugIns/Libretro"
resources_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Libretro"

rm -rf -- "$plugins_directory" "$resources_directory"
mkdir -p -- "$plugins_directory" "$resources_directory"

ditto "$artifact_directory/Cores" "$plugins_directory"
ditto "$artifact_directory/Licenses" "$resources_directory/Licenses"
if [ -d "$artifact_directory/System" ]; then
    ditto "$artifact_directory/System" "$resources_directory/System"
fi
ditto "$artifact_directory/CoreManifest.json" "$resources_directory/CoreManifest.json"
ditto "$artifact_directory/BuildReceipt.json" "$resources_directory/BuildReceipt.json"

core_count=$(find "$plugins_directory" -type f -name '*_libretro.dylib' | wc -l | tr -d ' ')
if [ "$core_count" -eq 0 ]; then
    echo "error: The Libretro artifact set contains no core binaries." >&2
    exit 1
fi

signing_identity="-"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] \
    && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    signing_identity="$EXPANDED_CODE_SIGN_IDENTITY"
fi

find "$plugins_directory" -type f -name '*_libretro.dylib' -print0 |
while IFS= read -r -d '' core_binary; do
    architectures=$(lipo -archs "$core_binary")
    if [ "$architectures" != "arm64" ]; then
        echo "error: $core_binary is not arm64-only: $architectures" >&2
        exit 1
    fi

    if [ "$signing_identity" = "-" ]; then
        codesign --force --sign - --timestamp=none "$core_binary"
    else
        if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
            codesign \
                --force \
                --sign "$signing_identity" \
                --options runtime \
                --timestamp \
                "$core_binary"
        else
            codesign \
                --force \
                --sign "$signing_identity" \
                --options runtime \
                --timestamp=none \
                "$core_binary"
        fi
    fi

    codesign --verify --strict --verbose=2 "$core_binary"
done

echo "Embedded bundled Libretro cores in $plugins_directory"

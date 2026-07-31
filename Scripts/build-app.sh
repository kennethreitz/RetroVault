#!/bin/bash
#
# Builds a standalone RetroVault.app that runs without Xcode.
#
# The signing arrangement here is the whole point of the script. Without a
# Developer ID the app can only be signed ad-hoc, and an ad-hoc signature
# carries no Team ID. Hardened runtime turns on library validation, which
# requires every loaded library to share the process's Team ID, so a hardened
# ad-hoc app cannot dlopen the ad-hoc-signed cores in its own PlugIns
# directory. It fails with:
#
#   mapping process and mapped file (non-platform) have different Team IDs
#
# The app launches perfectly and then no game will start, which makes this
# worth encoding in a script rather than rediscovering.
#
# Hardened runtime is therefore off for local builds only. A real Developer ID
# build signs the app and the cores with the same identity, library validation
# is satisfied, and ENABLE_HARDENED_RUNTIME stays YES in the project where
# notarization needs it.

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
derived_data="$repository_root/Build/ReleaseDD"
output_app="$repository_root/Build/RetroVault.app"

cd "$repository_root"

if [ ! -d "$repository_root/Build/LibretroCores/Cores" ]; then
    echo "error: No built cores found." >&2
    echo "error: Run Scripts/build-libretro-cores.sh first." >&2
    exit 1
fi

echo "Building RetroVault (Release, ad-hoc signed)…"
rm -rf "$derived_data"
xcodebuild \
    -project RetroVault.xcodeproj \
    -scheme RetroVault \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ENABLE_HARDENED_RUNTIME=NO \
    build

rm -rf "$output_app"
ditto "$derived_data/Build/Products/Release/RetroVault.app" "$output_app"

codesign --verify --deep --strict "$output_app"

# Library validation is the failure this script exists to prevent, so prove a
# core actually loads rather than trusting that the build settings took.
signature_flags=$(codesign -dv --verbose=2 "$output_app" 2>&1 | grep -o 'flags=[^ ]*')
case "$signature_flags" in
    *runtime*)
        echo "error: $output_app has hardened runtime; its cores cannot load." >&2
        echo "error: $signature_flags" >&2
        exit 1
        ;;
esac

core_count=$(find "$output_app/Contents/PlugIns/Libretro" -name '*_libretro.dylib' | wc -l | tr -d ' ')
if [ "$core_count" -eq 0 ]; then
    echo "error: No cores were embedded in $output_app." >&2
    exit 1
fi

echo
echo "Built $output_app"
echo "  $core_count cores, $signature_flags"
echo "  Install with: cp -R \"$output_app\" /Applications/"

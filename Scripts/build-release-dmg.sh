#!/bin/bash
#
# Builds and verifies the public Apple-silicon RetroVault disk image.
#
# The app is ad-hoc signed unless a future release workflow supplies a
# Developer ID identity. An ad-hoc signature protects bundle integrity but is
# not trusted by Gatekeeper and cannot be notarized.

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
output_app="$repository_root/Build/RetroVault.app"
release_directory="$repository_root/Build/Releases"
staging_directory="$release_directory/DMG-staging"

"$repository_root/Scripts/build-app.sh"

version=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$output_app/Contents/Info.plist")
architecture=$(lipo -archs "$output_app/Contents/MacOS/RetroVault")

if [ "$architecture" != "arm64" ]; then
    echo "error: Expected an arm64 release, found: $architecture" >&2
    exit 1
fi

dmg_name="RetroVault-$version-arm64.dmg"
dmg_path="$release_directory/$dmg_name"
checksum_path="$dmg_path.sha256"

rm -rf "$staging_directory"
mkdir -p "$staging_directory" "$release_directory"
ditto "$output_app" "$staging_directory/RetroVault.app"
ln -s /Applications "$staging_directory/Applications"

rm -f "$dmg_path" "$checksum_path"
hdiutil create \
    -volname "RetroVault $version" \
    -srcfolder "$staging_directory" \
    -format UDZO \
    -ov \
    "$dmg_path"

hdiutil verify "$dmg_path"
codesign --verify --deep --strict "$staging_directory/RetroVault.app"
(
    cd "$release_directory"
    shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
)
rm -rf "$staging_directory"

echo
echo "Built $dmg_path"
echo "Checksum: $checksum_path"

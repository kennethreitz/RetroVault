#!/bin/bash
#
# Fetches the pinned MoltenVK runtime that the app embeds.
#
# The release tarball is the upstream prebuilt dylib, so the version is
# reproducible without building MoltenVK from source. It is universal; the
# app is arm64-only, so the arm64 slice is extracted here. The signature in
# the tarball is ad-hoc, which library validation rejects under a Developer ID
# build; the embed phase re-signs whatever replaces the app's identity.

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
artifact_directory="$repository_root/Build/MoltenVK"
version="1.4.2"
archive_url="https://github.com/KhronosGroup/MoltenVK/releases/download/v${version}/MoltenVK-macos.tar"
archive_sha256="f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e"

force=false
if [ "$#" -eq 1 ] && [ "$1" = "--force" ]; then
  force=true
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--force]" >&2
  exit 2
fi

if [ "$force" = false ] \
  && [ -f "$artifact_directory/libMoltenVK.dylib" ] \
  && [ -d "$artifact_directory/include/vulkan" ] \
  && [ -f "$artifact_directory/LICENSE" ]; then
  echo "MoltenVK $version is already prepared in $artifact_directory"
  exit 0
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/retrovault-moltenvk.XXXXXX")
archive="$temporary_directory/MoltenVK-macos.tar"

cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

echo "Downloading MoltenVK v${version}..."
curl --fail --location --silent --show-error "$archive_url" --output "$archive"

actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual_sha256" != "$archive_sha256" ]; then
  echo "error: MoltenVK archive checksum mismatch." >&2
  echo "error: expected $archive_sha256" >&2
  echo "error: received $actual_sha256" >&2
  exit 1
fi

rm -rf "$artifact_directory"
mkdir -p "$artifact_directory"

# Strip MoltenVK/MoltenVK/ so the dylib and headers land where the build
# expects them: Build/MoltenVK/dylib and Build/MoltenVK/include.
tar -xf "$archive" \
  --strip-components=2 \
  -C "$artifact_directory" \
  MoltenVK/MoltenVK/dynamic/dylib \
  MoltenVK/MoltenVK/include
tar -xf "$archive" \
  --strip-components=1 \
  -C "$artifact_directory" \
  MoltenVK/LICENSE

lipo -thin arm64 \
  "$artifact_directory/dynamic/dylib/macOS/libMoltenVK.dylib" \
  -output "$artifact_directory/libMoltenVK.dylib"
rm -rf "$artifact_directory/dynamic"
codesign --force --sign - --timestamp=none "$artifact_directory/libMoltenVK.dylib"

echo "Prepared MoltenVK $version in $artifact_directory"

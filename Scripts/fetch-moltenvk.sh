#!/bin/bash
#
# Fetches the pinned MoltenVK runtime used by the Libretro Vulkan renderer.
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
libretro_h_revision="d9597c359a5ca8399a4e244f816e7e975a92a2aa"
libretro_vulkan_revision="a0403d4273fbd5ce6971f6f41c90c6df2b02e14b"
libretro_h_sha256="5b6d8fe1056a39591ee6c479512eed4a6f6efd8f89f64f10cf8b4757a2aa48a0"
libretro_vulkan_sha256="8c17fe6647069e22779cc5126cef43f8f5f0c83debf2ca2726385b5c8f493f9d"

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
  && [ -f "$artifact_directory/include/libretro/libretro.h" ] \
  && [ -f "$artifact_directory/include/libretro/libretro_vulkan.h" ] \
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

fetch_libretro_header() {
  url="$1"
  output="$2"
  expected="$3"
  curl --fail --location --silent --show-error "$url" --output "$output"
  actual=$(shasum -a 256 "$output" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "error: Libretro header checksum mismatch: $url" >&2
    echo "error: expected $expected" >&2
    echo "error: received $actual" >&2
    exit 1
  fi
}

mkdir -p "$artifact_directory/include/libretro"
fetch_libretro_header \
  "https://raw.githubusercontent.com/libretro/libretro-common/${libretro_h_revision}/include/libretro.h" \
  "$artifact_directory/include/libretro/libretro.h" \
  "$libretro_h_sha256"
fetch_libretro_header \
  "https://raw.githubusercontent.com/libretro/libretro-common/${libretro_vulkan_revision}/include/libretro_vulkan.h" \
  "$artifact_directory/include/libretro/libretro_vulkan.h" \
  "$libretro_vulkan_sha256"

lipo -thin arm64 \
  "$artifact_directory/dynamic/dylib/macOS/libMoltenVK.dylib" \
  -output "$artifact_directory/libMoltenVK.dylib"
rm -rf "$artifact_directory/dynamic"
codesign --force --sign - --timestamp=none "$artifact_directory/libMoltenVK.dylib"

echo "Prepared MoltenVK $version and pinned Libretro headers in $artifact_directory"

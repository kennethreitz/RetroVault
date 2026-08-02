#!/bin/bash

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
artifact_directory="$repository_root/Build/CemuCompanion"
application="$artifact_directory/Cemu.app"
version="2.6"
archive_url="https://github.com/cemu-project/Cemu/releases/download/v${version}/cemu-${version}-macos-12-x64.dmg"
archive_sha256="698c4b298f94983e4d6c30e9687ba8ff05094dd3930837c5104cddc0b0a49e4e"
license_url="https://raw.githubusercontent.com/cemu-project/Cemu/v${version}/LICENSE.txt"

force=false
if [ "$#" -eq 1 ] && [ "$1" = "--force" ]; then
  force=true
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--force]" >&2
  exit 2
fi

if [ "$force" = false ] \
  && [ -x "$application/Contents/MacOS/Cemu" ] \
  && [ -f "$artifact_directory/COPYING-Cemu.txt" ]; then
  echo "Cemu $version is already prepared in $artifact_directory"
  exit 0
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/retrovault-cemu.XXXXXX")
mount_point="$temporary_directory/mount"
archive="$temporary_directory/Cemu.dmg"

cleanup() {
  # /var is reported as /private/var by `mount`, so matching the literal
  # mount point can leave the read-only image attached and make cleanup fail.
  hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

mkdir -p "$mount_point"
echo "Downloading official Cemu v$version companion…"
curl --fail --location --silent --show-error "$archive_url" --output "$archive"

actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual_sha256" != "$archive_sha256" ]; then
  echo "error: Cemu archive checksum mismatch." >&2
  echo "error: expected $archive_sha256" >&2
  echo "error: received $actual_sha256" >&2
  exit 1
fi

hdiutil attach "$archive" -nobrowse -readonly -mountpoint "$mount_point" -quiet
if [ ! -x "$mount_point/Cemu.app/Contents/MacOS/Cemu" ]; then
  echo "error: The official Cemu image did not contain Cemu.app." >&2
  exit 1
fi

if [ "$force" = true ]; then
  echo "Replacing the existing Cemu companion with official v${version}…"
fi
rm -rf "$artifact_directory"
mkdir -p "$artifact_directory"
ditto "$mount_point/Cemu.app" "$application"
curl --fail --location --silent --show-error "$license_url" \
  --output "$artifact_directory/COPYING-Cemu.txt"

echo "Prepared official Cemu v${version} in $artifact_directory"

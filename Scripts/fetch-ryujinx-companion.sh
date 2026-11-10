#!/bin/bash

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
artifact_directory="$repository_root/Build/RyujinxCompanion"
application="$artifact_directory/Ryujinx.app"
version="1.3.352"
archive_url="https://git.ryujinx.app/Ryubing/Canary/releases/download/${version}/ryujinx-canary-${version}-macos_universal.app.tar.gz"
archive_sha256="7a7612e698dfef90d915b89553c0b583d1de4e180e916319dbdfa469229d0216"
license_url="https://git.ryujinx.app/projects/Ryubing/raw/tag/1.3.3/LICENSE.txt"

force=false
if [ "$#" -eq 1 ] && [ "$1" = "--force" ]; then
  force=true
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--force]" >&2
  exit 2
fi

if [ "$force" = false ] \
  && [ -x "$application/Contents/MacOS/Ryujinx" ] \
  && [ -f "$artifact_directory/COPYING-Ryujinx.txt" ]; then
  echo "Ryubing $version is already prepared in $artifact_directory"
  exit 0
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/retrovault-ryujinx.XXXXXX")
archive="$temporary_directory/Ryujinx.app.tar.gz"

cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

echo "Downloading official Ryubing v$version companion…"
curl --fail --location --silent --show-error "$archive_url" --output "$archive"

actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual_sha256" != "$archive_sha256" ]; then
  echo "error: Ryubing archive checksum mismatch." >&2
  echo "error: expected $archive_sha256" >&2
  echo "error: received $actual_sha256" >&2
  exit 1
fi

tar -xzf "$archive" -C "$temporary_directory"
if [ ! -x "$temporary_directory/Ryujinx.app/Contents/MacOS/Ryujinx" ]; then
  echo "error: The official Ryubing archive did not contain Ryujinx.app." >&2
  exit 1
fi

if [ "$force" = true ]; then
  echo "Replacing the existing Ryubing companion with official v${version}…"
fi
rm -rf "$artifact_directory"
mkdir -p "$artifact_directory"
ditto "$temporary_directory/Ryujinx.app" "$application"
curl --fail --location --silent --show-error "$license_url" \
  --output "$artifact_directory/COPYING-Ryujinx.txt"

echo "Prepared official Ryubing v${version} in $artifact_directory"

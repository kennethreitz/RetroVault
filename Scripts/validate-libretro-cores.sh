#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)

swift run \
    --package-path "$repository_root" \
    OpenVaultCoreTool \
    validate \
    "$repository_root/Libretro/CoreManifest.json"

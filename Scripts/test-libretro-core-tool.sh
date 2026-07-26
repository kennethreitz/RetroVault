#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
fixture="$repository_root/Tools/OpenVaultCoreTool/Fixtures/unsupported-schema.json"

swift build \
    --package-path "$repository_root" \
    --product OpenVaultCoreTool

tool_directory=$(swift build \
    --package-path "$repository_root" \
    --show-bin-path)
tool_path="$tool_directory/OpenVaultCoreTool"

"$tool_path" validate "$repository_root/Libretro/CoreManifest.json"

error_output=$(mktemp "${TMPDIR:-/tmp}/openvault-core-tool-error.XXXXXX")
trap 'rm -f -- "$error_output"' EXIT

if "$tool_path" validate "$fixture" >"$error_output" 2>&1; then
    echo "Expected the unsupported schema fixture to fail validation." >&2
    exit 1
fi

if ! grep -q "Unsupported schemaVersion 2" "$error_output"; then
    echo "The validation failure did not explain the unsupported schema." >&2
    cat "$error_output" >&2
    exit 1
fi

echo "Core manifest tool checks passed."

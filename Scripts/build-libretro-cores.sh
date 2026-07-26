#!/bin/bash

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
manifest_path="$repository_root/Libretro/CoreManifest.json"
output_directory="$repository_root/Build/LibretroCores"
signing_identity="${OPENVAULT_CORE_SIGNING_IDENTITY:--}"
selected_cores=()

usage() {
    echo "Usage: Scripts/build-libretro-cores.sh [--core <id>]... [--output <directory>]"
}

while (($# > 0)); do
    case "$1" in
        --core)
            if (($# < 2)); then
                usage >&2
                exit 2
            fi
            selected_cores+=("$2")
            shift 2
            ;;
        --output)
            if (($# < 2)); then
                usage >&2
                exit 2
            fi
            output_directory="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$output_directory" != /* ]]; then
    output_directory="$repository_root/$output_directory"
fi

case "$output_directory" in
    /|"$repository_root"|"$repository_root/"|"$HOME"|"$HOME/")
        echo "Refusing unsafe output directory: $output_directory" >&2
        exit 2
        ;;
esac

swift build \
    --package-path "$repository_root" \
    --product OpenVaultCoreTool

tool_directory=$(swift build \
    --package-path "$repository_root" \
    --show-bin-path)
tool_path="$tool_directory/OpenVaultCoreTool"

work_directory=$(mktemp -d "${TMPDIR:-/tmp}/openvault-libretro-work.XXXXXX")
staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/openvault-libretro-output.XXXXXX")
backup_directory=""

cleanup() {
    rm -rf -- "$work_directory" "$staging_directory"
}
trap cleanup EXIT

build_arguments=(
    build
    --manifest "$manifest_path"
    --output "$staging_directory"
    --work "$work_directory"
    --sign "$signing_identity"
)

if ((${#selected_cores[@]} > 0)); then
    for core_id in "${selected_cores[@]}"; do
        build_arguments+=(--core "$core_id")
    done
fi

"$tool_path" "${build_arguments[@]}"

mkdir -p -- "$(dirname -- "$output_directory")"

if [[ -e "$output_directory" ]]; then
    backup_directory="${output_directory}.previous.$$"
    if [[ -e "$backup_directory" ]]; then
        echo "Refusing to overwrite backup path: $backup_directory" >&2
        exit 1
    fi
    mv -- "$output_directory" "$backup_directory"
fi

if mv -- "$staging_directory" "$output_directory"; then
    staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/openvault-libretro-empty.XXXXXX")
    if [[ -n "$backup_directory" ]]; then
        rm -rf -- "$backup_directory"
    fi
else
    if [[ -n "$backup_directory" && -e "$backup_directory" ]]; then
        mv -- "$backup_directory" "$output_directory"
    fi
    exit 1
fi

echo "Libretro artifacts: $output_directory"

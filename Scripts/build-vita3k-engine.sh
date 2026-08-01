#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
work_root="$repository_root/.vita3k-work"
source_directory="$work_root/Vita3K"
build_directory="$work_root/build"
artifact_directory="$repository_root/Build/Vita3KEngine"
revision="a10485eb61b1ed4a291adab6017acd785659cccb"

if [ ! -d "$source_directory/.git" ]; then
  mkdir -p "$work_root"
  git clone https://github.com/Vita3K/Vita3K.git "$source_directory"
fi

git -C "$source_directory" fetch origin "$revision"
git -C "$source_directory" checkout --detach "$revision"
git -C "$source_directory" submodule update --init --recursive --depth 1

if ! git -C "$source_directory" apply --unidiff-zero --reverse --check \
  "$repository_root/Vita3K/Patches/retrovault-embedded.patch" >/dev/null 2>&1
then
  git -C "$source_directory" apply --unidiff-zero \
    "$repository_root/Vita3K/Patches/retrovault-embedded.patch"
fi

mkdir -p "$source_directory/vita3k/retrovault"
cp "$repository_root/Vita3K/Bridge/bridge.cpp" \
  "$source_directory/vita3k/retrovault/bridge.cpp"

cmake -S "$source_directory" -B "$build_directory" \
  -G "Unix Makefiles" \
  -DRETROVAULT_EMBEDDED=ON \
  -DUSE_DISCORD_RICH_PRESENCE=OFF \
  -DUSE_LTO=NEVER \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_directory" \
  --target retrovault_vita3k \
  --parallel "$(sysctl -n hw.logicalcpu)"

mkdir -p "$artifact_directory/PlugIns" "$artifact_directory/Resources"
cp "$build_directory/lib/libRetroVaultVita3K.dylib" \
  "$artifact_directory/PlugIns/RetroVaultVita3K.dylib"
cp "$build_directory/external/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" \
  "$artifact_directory/PlugIns/libMoltenVK.dylib"
ditto "$source_directory/data" "$artifact_directory/Resources/data"
ditto "$source_directory/vita3k/shaders-builtin" \
  "$artifact_directory/Resources/shaders-builtin"
cp "$source_directory/COPYING.txt" "$artifact_directory/COPYING-Vita3K.txt"

echo "Built experimental Vita3K engine at $artifact_directory"

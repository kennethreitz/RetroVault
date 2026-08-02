#!/bin/bash

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
work_directory="$repository_root/Build/CemuMetalWork"
source_directory="$work_directory/Cemu"
build_directory="$work_directory/build"
artifact_directory="$repository_root/Build/CemuMetalCompanion"
staging_directory="$repository_root/Build/CemuMetalCompanion.staging"
application="$artifact_directory/Cemu.app"
standalone_metal_patch="$script_directory/patches/cemu-metal-standalone.patch"

# Pin the trial to a reviewed upstream revision. Updating this value is an
# explicit compatibility decision rather than an accidental moving-main build.
cemu_revision="1706e5f37910fc6962ee54a41b219a53c1eed8b4"

for required_tool in autoconf automake autoreconf nasm; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "error: $required_tool is required to build the Cemu Metal trial." >&2
    echo "Install the host tools with: brew install autoconf automake libtool nasm" >&2
    exit 1
  fi
done

cmake="$repository_root/.cemu-work/tools/cmake-3.30.9-macos-universal/CMake.app/Contents/bin/cmake"
if [ ! -x "$cmake" ]; then
  cmake=$(command -v cmake || true)
fi
if [ -z "$cmake" ] || [ ! -x "$cmake" ]; then
  echo "error: CMake is required to build the Cemu Metal trial." >&2
  exit 1
fi

ninja="$repository_root/.cemu-work/Cemu/dependencies/vcpkg/downloads/tools/ninja/1.10.2-osx/ninja"
if [ ! -x "$ninja" ]; then
  ninja=$(command -v ninja || true)
fi
if [ -z "$ninja" ] || [ ! -x "$ninja" ]; then
  echo "error: Ninja is required to build the Cemu Metal trial." >&2
  echo "Install it with: brew install ninja" >&2
  exit 1
fi

mkdir -p "$work_directory"
if [ ! -d "$source_directory/.git" ]; then
  git clone --filter=blob:none \
    https://github.com/cemu-project/Cemu.git "$source_directory"
fi

if [ -n "$(git -C "$source_directory" status --porcelain)" ]; then
  echo "error: The Cemu Metal source checkout contains local changes." >&2
  echo "error: Preserve or remove them before rebuilding the trial companion." >&2
  exit 1
fi

git -C "$source_directory" fetch --depth 1 origin "$cemu_revision"
git -C "$source_directory" checkout --detach "$cemu_revision"
git -C "$source_directory" submodule sync --recursive
git -C "$source_directory" submodule update --init --recursive --depth 1

# Upstream's Metal-only configuration currently relied on VulkanRenderer.h to
# include robin_hood transitively. Apply the narrow include fix only while
# compiling, then restore the generated checkout even when the build fails.
git -C "$source_directory" apply --unidiff-zero "$standalone_metal_patch"
cleanup_source_patch() {
  if git -C "$source_directory" apply --unidiff-zero --reverse --check "$standalone_metal_patch" >/dev/null 2>&1; then
    git -C "$source_directory" apply --unidiff-zero --reverse "$standalone_metal_patch"
  fi
}
trap cleanup_source_patch EXIT

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
PATH="$(dirname "$cmake"):$(dirname "$ninja"):$PATH" "$cmake" \
  -S "$source_directory" \
  -B "$build_directory" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MAKE_PROGRAM="$ninja" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT="$sdk_path" \
  -DMACOS_BUNDLE=ON \
  -DENABLE_OPENGL=OFF \
  -DENABLE_VULKAN=OFF \
  -DENABLE_METAL=ON

PATH="$(dirname "$cmake"):$(dirname "$ninja"):$PATH" "$cmake" \
  --build "$build_directory" \
  --target CemuBin \
  --parallel "$(sysctl -n hw.ncpu)"

built_application="$source_directory/bin/Cemu_release.app"
built_executable="$built_application/Contents/MacOS/Cemu_release"
if [ ! -x "$built_executable" ]; then
  echo "error: The Cemu Metal build did not produce its app executable." >&2
  exit 1
fi
if ! otool -L "$built_executable" | grep -q '/Metal.framework/'; then
  echo "error: The trial executable was not linked against Metal." >&2
  exit 1
fi

rm -rf "$staging_directory"
mkdir -p "$staging_directory"
ditto "$built_application" "$staging_directory/Cemu.app"
mv "$staging_directory/Cemu.app/Contents/MacOS/Cemu_release" \
  "$staging_directory/Cemu.app/Contents/MacOS/Cemu"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Cemu' \
  "$staging_directory/Cemu.app/Contents/Info.plist"
mkdir -p "$staging_directory/Cemu.app/Contents/Resources"
touch "$staging_directory/Cemu.app/Contents/Resources/RetroVaultMetalRenderer"
printf '%s\n' "$cemu_revision" > \
  "$staging_directory/Cemu.app/Contents/Resources/RetroVaultCemuSourceRevision"
cp "$source_directory/LICENSE.txt" "$staging_directory/COPYING-Cemu.txt"

codesign --force --deep --sign - --timestamp=none \
  "$staging_directory/Cemu.app"
rm -rf "$artifact_directory"
mv "$staging_directory" "$artifact_directory"

echo "Prepared native arm64 Cemu Metal trial at $application"
echo "  upstream revision: $cemu_revision"
echo "  stable Cemu 2.6 remains in Build/CemuCompanion"

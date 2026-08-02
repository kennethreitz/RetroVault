#!/bin/bash

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
work_directory="$repository_root/.cemu-work"
source_directory="$work_directory/Cemu"
build_directory="$source_directory/build-retrovault-rumble"
artifact_directory="$repository_root/Build/CemuCompanion"
application="$artifact_directory/Cemu.app"
rumble_patch="$repository_root/Patches/Cemu/0001-retrovault-dsu-rumble.patch"
toolchain_patch="$repository_root/Patches/Cemu/0002-xcode-27-fmt-compatibility.patch"

for required_tool in autoconf automake autoreconf nasm; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "error: $required_tool is required to build Cemu and its pinned dependencies." >&2
    echo "Install the host tools with: brew install autoconf automake libtool nasm" >&2
    exit 1
  fi
done

cemu_version="2.6"
cmake_version="3.30.9"
cmake_archive="$work_directory/tools/cmake-${cmake_version}-macos-universal.tar.gz"
cmake_directory="$work_directory/tools/cmake-${cmake_version}-macos-universal"
cmake="$cmake_directory/CMake.app/Contents/bin/cmake"
cmake_sha256="572bf27e2e98d7513e0835525a2b9dc0f3947f6ad7494615e22b60369e87db11"
ninja="$source_directory/dependencies/vcpkg/downloads/tools/ninja/1.10.2-osx/ninja"

"$script_directory/fetch-cemu-companion.sh"

mkdir -p "$work_directory/tools"
if [ ! -x "$cmake" ]; then
  echo "Downloading CMake $cmake_version for Cemu's pinned dependency tree…"
  curl --fail --location --silent --show-error \
    "https://github.com/Kitware/CMake/releases/download/v${cmake_version}/cmake-${cmake_version}-macos-universal.tar.gz" \
    --output "$cmake_archive"

  actual_sha256=$(shasum -a 256 "$cmake_archive" | awk '{print $1}')
  if [ "$actual_sha256" != "$cmake_sha256" ]; then
    echo "error: CMake archive checksum mismatch." >&2
    exit 1
  fi
  tar -xzf "$cmake_archive" -C "$work_directory/tools"
fi

if [ ! -d "$source_directory/.git" ]; then
  git clone --branch "v$cemu_version" --depth 1 --recurse-submodules \
    --shallow-submodules https://github.com/cemu-project/Cemu.git \
    "$source_directory"
else
  git -C "$source_directory" submodule update --init --recursive
fi

if ! git -C "$source_directory" apply --reverse --check "$rumble_patch" 2>/dev/null; then
  git -C "$source_directory" apply --check "$rumble_patch"
  git -C "$source_directory" apply "$rumble_patch"
fi

if ! git -C "$source_directory" apply --reverse --check "$toolchain_patch" 2>/dev/null; then
  git -C "$source_directory" apply --check "$toolchain_patch"
  git -C "$source_directory" apply "$toolchain_patch"
fi

# Cemu 2.6 pins a 2024 vcpkg helper that emits a bare `-isysroot` when
# cross-compiling without an explicit SDK value. The next compiler flag then
# becomes the SDK path. Newer vcpkg already has this guard.
vcpkg_vars="$source_directory/dependencies/vcpkg/scripts/get_cmake_vars/CMakeLists.txt"
if ! grep -A2 'if(CMAKE_OSX_SYSROOT)' "$vcpkg_vars" | grep -q 'isysroot'; then
  perl -0pi -e \
    's/string\(APPEND \$\{flag_var\} " -isysroot \$\{CMAKE_OSX_SYSROOT\}"\)/if(CMAKE_OSX_SYSROOT)\n                string(APPEND \${flag_var} " -isysroot \${CMAKE_OSX_SYSROOT}")\n            endif()/g' \
    "$vcpkg_vars"
fi

moltenvk="$application/Contents/Frameworks/libMoltenVK.dylib"
if [ ! -f "$moltenvk" ]; then
  echo "error: The official Cemu companion did not include MoltenVK." >&2
  exit 1
fi

# Upstream's macOS build assumes a Homebrew-style /usr/local install. Reuse
# the checksum-verified framework from the official Cemu bundle instead.
cemu_cmake="$source_directory/src/CMakeLists.txt"
perl -0pi -e \
  's|"/usr/local/lib/libMoltenVK\.dylib"|"'"$moltenvk"'"|g' \
  "$cemu_cmake"

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
PATH="$(dirname "$cmake"):$PATH" "$cmake" -S "$source_directory" -B "$build_directory" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MAKE_PROGRAM="$ninja" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_SYSROOT="$sdk_path" \
  -DCMAKE_CXX_FLAGS= \
  -DCMAKE_OBJCXX_FLAGS= \
  -DMACOS_BUNDLE=ON

PATH="$(dirname "$cmake"):$PATH" "$cmake" --build "$build_directory" \
  --target CemuBin --parallel "$(sysctl -n hw.ncpu)"

built_binary="$source_directory/bin/Cemu_release.app/Contents/MacOS/Cemu_release"
if [ ! -x "$built_binary" ]; then
  echo "error: The patched Cemu build did not produce its release executable." >&2
  exit 1
fi

cp "$built_binary" "$application/Contents/MacOS/Cemu"
chmod 755 "$application/Contents/MacOS/Cemu"
touch "$application/Contents/Resources/RetroVaultDSURumble"

echo "Prepared patched Cemu $cemu_version with RetroVault DSU rumble support."

#!/bin/sh
#
# Builds the content-free Vulkan libretro core used by Phase 1 smoke tests.
# It is a development fixture, not a bundled core.

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
output_directory="$repository_root/Build/VulkanTestCore"
source_file="$repository_root/Tests/Fixtures/VulkanTestCore/vulkan_test_core.c"
include_directory="$repository_root/Build/MoltenVK/include"
libretro_include_directory="$include_directory/libretro"

if [ ! -f "$include_directory/vulkan/vulkan.h" ] \
  || [ ! -f "$libretro_include_directory/libretro.h" ]; then
  "$repository_root/Scripts/fetch-moltenvk.sh"
fi

mkdir -p "$output_directory"
output="$output_directory/vulkan_test_libretro.dylib"

clang \
  -dynamiclib \
  -O2 \
  -arch arm64 \
  -mmacosx-version-min=15.0 \
  -Wall \
  -Wextra \
  -Wno-unused-parameter \
  -I "$include_directory" \
  -I "$libretro_include_directory" \
  -o "$output" \
  "$source_file"

codesign --force --sign - --timestamp=none "$output"

echo "Built $output"

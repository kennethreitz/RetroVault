#!/bin/sh

set -eu

launcher_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
application_directory=$(CDPATH= cd -- "$launcher_directory/../.." && pwd -P)
runtime_directory=$(dirname -- "$application_directory")
portable_directory="$runtime_directory/portable"
request_file="$portable_directory/retrovault-launch.txt"
real_executable="$launcher_directory/Cemu.real"

if [ -f "$request_file" ]; then
  game_path=$(/usr/bin/sed -n '1p' "$request_file")
  mlc_path=$(/usr/bin/sed -n '2p' "$request_file")
  /bin/rm -f "$request_file"

  if [ -n "$game_path" ] && [ -n "$mlc_path" ]; then
    /usr/bin/printf 'RetroVault launcher: game=%s mlc=%s\n' \
      "$game_path" "$mlc_path" >> "$portable_directory/launcher.log"
    exec "$real_executable" -g "$game_path" -m "$mlc_path" -f
  fi

  /usr/bin/printf 'RetroVault launcher: invalid launch request\n' \
    >> "$portable_directory/launcher.log"
  exit 64
fi

exec "$real_executable" "$@"

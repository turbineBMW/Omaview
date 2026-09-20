#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'Omaview: %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local missing=() command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null || missing+=("$command_name")
  done
  ((${#missing[@]} == 0)) || fail "Missing commands: ${missing[*]}. A standard Omarchy installation includes these; build tools are supplied by base-devel."
}

# Runs on open. Dependencies are checked, never silently installed. On a
# standard Omarchy installation they are already provided by system packages.
require_commands hyprctl jq
native_loaded() {
  local plugins version
  plugins=$(hyprctl -j plugin list) || fail "Cannot contact the running Hyprland instance."
  version=$(jq -r '.[] | select(.name == "omaview") | .version' <<< "$plugins")
  [[ -n $version ]] || return 1
  [[ $version == 1.1.2 ]] || fail "An older native companion is still loaded. Restart your Hyprland session to finish updating Omaview."
}
if native_loaded; then exit 0; fi

require_commands dirname sha256sum cut mkdir flock mv rm
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
abi=$(hyprctl -j version | jq -er .abiHash) || fail "Hyprland does not expose the required ABI information. This companion is tested with Hyprland 0.56.2."
case "$abi" in
  *[!a-zA-Z0-9._-]*|'') fail "Could not determine the running Hyprland ABI." ;;
esac
digest=$(sha256sum "$source_dir/omaview.cpp" | cut -c1-16)
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omaview/$abi/$digest"
mkdir -p -- "$cache_dir"
exec 9>"$cache_dir/build.lock"
flock 9

# Another opener may have loaded it while this one waited for the build.
if native_loaded; then exit 0; fi

binary="$cache_dir/omaview.so"
if [[ ! -s $binary ]]; then
  require_commands g++ pkg-config
  packages=(hyprland pixman-1 libdrm libinput libudev wayland-server xkbcommon lua)
  missing_packages=()
  for package in "${packages[@]}"; do
    pkg-config --exists "$package" || missing_packages+=("$package")
  done
  ((${#missing_packages[@]} == 0)) || fail "Missing development files: ${missing_packages[*]}. Install the corresponding packages for your distribution."
  flags=$(pkg-config --cflags "${packages[@]}")
  read -r -a compiler_flags <<< "$flags"
  temporary="$cache_dir/omaview.$$.so"
  trap 'rm -f -- "$temporary"' EXIT
  g++ -shared -fPIC -fno-gnu-unique -fno-access-control -std=c++23 -O2 -Wall -Wextra \
    "${compiler_flags[@]}" "$source_dir/omaview.cpp" -o "$temporary" \
    || fail "Native build failed. The installed Hyprland headers/compiler must support this companion (tested with 0.56.2)."
  mv -- "$temporary" "$binary"
fi

reply=$(hyprctl plugin load "$binary") || fail "Hyprland could not load its companion."
if [[ $reply != ok ]]; then
  fail "$reply"
fi

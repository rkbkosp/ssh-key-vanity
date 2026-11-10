#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'This utility requires macOS.' >&2; exit 1; }
SODIUM_ROOT="${SODIUM_ROOT:-/opt/homebrew/opt/libsodium}"
if [[ ! -f "$SODIUM_ROOT/include/sodium.h" ]] && command -v brew >/dev/null 2>&1; then
  SODIUM_ROOT="$(brew --prefix libsodium)"
fi
[[ -f "$SODIUM_ROOT/include/sodium.h" ]] || { echo 'Install libsodium: brew install libsodium' >&2; exit 1; }
target=ssh-vanity
source_file="$ROOT/src/vanity.mm"
case "${1:-}" in
  '') ;;
  --profile) target=ssh-vanity-profile; source_file="$ROOT/tools/profile.mm" ;;
  *) echo 'Usage: scripts/build.sh [--profile]' >&2; exit 1 ;;
esac
mkdir -p "$ROOT/build"
if [[ ! -x "$ROOT/build/$target" || "$source_file" -nt "$ROOT/build/$target" || "$ROOT/src/vanity.mm" -nt "$ROOT/build/$target" || "${BASH_SOURCE[0]}" -nt "$ROOT/build/$target" ]]; then
  task_binary="$(mktemp "$ROOT/build/$target.XXXXXX")"
  trap '[[ ! -f "$task_binary" ]] || unlink "$task_binary"' EXIT
  xcrun clang++ -O3 -std=c++17 -fobjc-arc -fblocks -Wno-deprecated-declarations \
    -I"$SODIUM_ROOT/include" -L"$SODIUM_ROOT/lib" -lsodium \
    -framework Foundation -framework Metal "$source_file" -o "$task_binary"
  chmod +x "$task_binary"
  # Atomic replacement leaves any already-running executable intact.
  mv -f "$task_binary" "$ROOT/build/$target"
fi

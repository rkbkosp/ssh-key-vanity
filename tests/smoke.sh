#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_dir="$(mktemp -d "${TMPDIR:-/tmp}/ssh-vanity-test.XXXXXX")"
cleanup() {
  for task_name in key key.pub key.sig derived message message.sig allowed stdout stderr; do
    [[ ! -f "$task_dir/$task_name" && ! -L "$task_dir/$task_name" ]] || unlink "$task_dir/$task_name"
  done
  rmdir "$task_dir"
}
trap cleanup EXIT
case "${1:-}" in
  '') backend=cpu; depths='1' ;;
  --metal) backend=metal; depths='1 2 3 4' ;;
  *) echo 'Usage: tests/smoke.sh [--metal]' >&2; exit 1 ;;
esac
"$ROOT/run.sh" --help >/dev/null
if "$ROOT/run.sh" --suffix '78=' >"$task_dir/stdout" 2>"$task_dir/stderr"; then
  echo 'Invalid Base64 suffix unexpectedly accepted' >&2; exit 1
fi
for depth in $depths; do
  "$ROOT/run.sh" --backend "$backend" --suffix 78 --inflight "$depth" \
    --batch 1024 --max-seconds 30 --output "$task_dir/key" >"$task_dir/stdout"
  awk 'NF != 2 || $1 != "ssh-ed25519" || $2 !~ /78$/ { exit 1 }' "$task_dir/key.pub"
  [[ "$(stat -f '%Lp' "$task_dir/key")" == 600 ]]
  ssh-keygen -y -f "$task_dir/key" >"$task_dir/derived"
  cmp "$task_dir/derived" "$task_dir/key.pub"
  task_hash="$(shasum -a 256 "$task_dir/key")"
  if "$ROOT/run.sh" --output "$task_dir/key" >"$task_dir/stdout" 2>"$task_dir/stderr"; then
    echo 'Existing key unexpectedly overwritten' >&2; exit 1
  fi
  [[ "$task_hash" == "$(shasum -a 256 "$task_dir/key")" ]]
  printf 'OpenSSH signature roundtrip\n' >"$task_dir/message"
  printf 'smoke-test ' >"$task_dir/allowed"
  cat "$task_dir/key.pub" >>"$task_dir/allowed"
  ssh-keygen -Y sign -f "$task_dir/key" -n ssh-vanity "$task_dir/message"
  ssh-keygen -Y verify -f "$task_dir/allowed" -I smoke-test -n ssh-vanity \
    -s "$task_dir/message.sig" <"$task_dir/message"
  unlink "$task_dir/key"
  unlink "$task_dir/key.pub"
  unlink "$task_dir/message.sig"
done
printf '%s smoke checks passed.\n' "$backend"

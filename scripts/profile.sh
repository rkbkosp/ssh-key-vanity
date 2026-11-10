#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export SSH_VANITY_ROOT="$ROOT"
"$ROOT/scripts/build.sh" --profile
exec "$ROOT/build/ssh-vanity-profile" "$@"

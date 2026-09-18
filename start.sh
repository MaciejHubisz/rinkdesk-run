#!/usr/bin/env bash
# RinkDesk run entry point. The lifecycle lives in common/ops/start.sh; this
# wrapper points it at this checkout.
#
#   ./start.sh --start
#   ./start.sh --stop
#   ./start.sh --update
#   ./start.sh --help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export APP_RUN_ROOT="$ROOT"
export APP_CONFIG="${APP_CONFIG:-$ROOT/app.conf}"

# The lifecycle lives in the common submodule. A fresh clone leaves common/
# empty, so initialize it before handing over instead of dying on a missing file.
ensure_common() {
  local entry="$ROOT/common/ops/start.sh"
  [[ -f "$entry" ]] && return 0
  command -v git >/dev/null 2>&1 ||
    { echo "common/ is empty and git is not installed" >&2; exit 1; }
  echo "Initializing common/ submodule…" >&2
  git -C "$ROOT" submodule update --init --recursive ||
    { echo "could not initialize common/ submodule" >&2; exit 1; }
  [[ -f "$entry" ]] ||
    { echo "common/ops/start.sh still missing after submodule update" >&2; exit 1; }
}

ensure_common

exec "$ROOT/common/ops/start.sh" "$@"

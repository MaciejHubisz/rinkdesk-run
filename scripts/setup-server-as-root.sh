#!/usr/bin/env bash
# RinkDesk host setup entry point. The host operations live in
# common/ops/setup-server-as-root.sh; this wrapper points it at this checkout
# and its app.conf.
#
#   sudo scripts/setup-server-as-root.sh USER [--install-service] [--install-nginx]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export APP_RUN_ROOT="$ROOT"
export APP_CONFIG="${APP_CONFIG:-$ROOT/app.conf}"

# The host operations live in the common submodule. A fresh clone leaves
# common/ empty, so initialize it before handing over.
ensure_common() {
  local entry="$ROOT/common/ops/setup-server-as-root.sh"
  bash "$ROOT/scripts/ensure-common.sh"
  [[ -f "$entry" ]] ||
    { echo "common/ops/setup-server-as-root.sh still missing after submodule update" >&2; exit 1; }
}

ensure_common

exec "$ROOT/common/ops/setup-server-as-root.sh" "$@"

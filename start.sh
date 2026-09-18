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

exec "$ROOT/common/ops/start.sh" "$@"

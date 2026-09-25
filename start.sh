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

entry="$ROOT/common/ops/start.sh"
[[ -f "$entry" ]] || {
  echo "common/ops/start.sh is missing (vendor common with tools/vendor.sh)" >&2
  exit 1
}

# The shared lifecycle is Linux-only. On macOS bring up Homebrew + a container
# runtime (Colima / Docker Desktop / OrbStack / Podman machine) first, and let
# it own --install-service via launchd. Linux is unaffected.
if [[ "$(uname -s)" == Darwin ]]; then
  # shellcheck source=scripts/macos.sh
  source "$ROOT/scripts/macos.sh"
  macos_main "$@"
fi

exec "$entry" "$@"

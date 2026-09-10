# shellcheck shell=bash
# Runtime configuration: defaults, .env loading, and bind-mount helpers.
# Requires ROOT and platform.sh.

PORT="${RINKDESK_PORT:-8765}"
HOST="${RINKDESK_HOST:-127.0.0.1}"
URL="http://${HOST}:${PORT}/"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || printf '1.0.0')"

refresh_url() { URL="http://${HOST}:${PORT}/"; }

# Bind-mount relabel suffix shared by docker-compose (see volume_opts).
RINKDESK_VOL_OPTS="${RINKDESK_VOL_OPTS:-$(volume_opts)}"
export RINKDESK_VOL_OPTS
RINKDESK_VOL_OPTS_RO="${RINKDESK_VOL_OPTS_RO:-$(volume_opts_ro)}"
export RINKDESK_VOL_OPTS_RO
# The default protocols mount is a host bind, so it wants the same suffix.
RINKDESK_PROTOCOLS_OPTS="${RINKDESK_PROTOCOLS_OPTS:-$RINKDESK_VOL_OPTS}"
export RINKDESK_PROTOCOLS_OPTS

# Source one or more env files (later files win) and re-read port/host.
load_env() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  done
  PORT="${RINKDESK_PORT:-$PORT}"
  HOST="${RINKDESK_HOST:-$HOST}"
  refresh_url
}

# Bind /app/exports to a local folder. rinkdesk-run uses a named volume unless
# this is set.
apply_export_path() {
  local resolved
  resolved="$(resolve_host_path "$1")"
  mkdir -p "$resolved/archive" || die "cannot create $resolved/archive"
  export RINKDESK_EXPORTS_SOURCE="$resolved"
  export RINKDESK_EXPORTS_OPTS="$RINKDESK_VOL_OPTS"
  say "${DIM}exports → ${resolved}${RESET}"
}

# Bind /app/protocols (generated protocol PDFs) to a local folder.
apply_protocols_path() {
  local resolved
  resolved="$(resolve_host_path "$1")"
  export RINKDESK_PROTOCOLS_SOURCE="$resolved"
  export RINKDESK_PROTOCOLS_OPTS="$RINKDESK_VOL_OPTS"
  say "${DIM}protocols → ${resolved}${RESET}"
}

#!/usr/bin/env bash
# RinkDesk — pull images and run. Same file in rinkdesk and rinkdesk-run.
#
#   ./start.sh --start
#   ./start.sh --stop
#   ./start.sh --force-recreate
#
# Windows:  .\install\windows.cmd --start
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=run/common.sh
source "$ROOT/run/common.sh"
maybe_reexec_wsl "$@"

CMD=help
OPEN=1
RECREATE=0

print_usage() {
  cat <<EOF
${BOLD}RinkDesk${RESET} ${APP_VERSION}  rink-clerk desk

  ${GREEN}./start.sh --start${RESET}             start or resume (keep data)
  ${GREEN}./start.sh --force-recreate${RESET}    wipe database, pull, start empty
  ${GREEN}./start.sh --stop${RESET}              stop (data kept)
  ${GREEN}./start.sh --manual${RESET}            how the desk works

  -p, --port PORT                UI port (default ${PORT})
  -n, --no-open                  do not open a browser
  -V, --version
  -h, --help

  Windows:  .\\install\\windows.cmd --start
  Images:   pulled, never built here.
EOF
}

cmd_start() {
  local open_it="$1" recreate="$2"
  ensure_runtime
  cd "$ROOT"
  export RINKDESK_PORT="$PORT"
  export RINKDESK_VERSION="$APP_VERSION"
  export RINKDESK_IMAGE_TAG="${RINKDESK_IMAGE_TAG:-$APP_VERSION}"

  say "${DIM}Pulling images…${RESET}"
  compose pull || say "${DIM}pull failed — using local images if present${RESET}"

  if [[ "$recreate" == 1 ]]; then
    say "Wiping volumes…"
    compose down --remove-orphans -v >/dev/null 2>&1 || true
    compose up --force-recreate --no-build -d
  else
    compose up --no-build -d
  fi

  if ! wait_until_up; then
    compose logs --tail 40
    die "desk did not start on ${URL}"
  fi
  printf '%s\n' "${BOLD}RinkDesk${RESET} ${APP_VERSION}  ${GREEN}up${RESET}  ${BOLD}${URL}${RESET}"
  [[ "$recreate" == 1 ]] && say "Empty desk (database wiped)."
  [[ "$open_it" == 1 ]] && open_browser "$URL"
}

cmd_stop() {
  ensure_runtime
  cd "$ROOT"
  compose down --remove-orphans >/dev/null 2>&1 || true
  say "Stopped RinkDesk ${APP_VERSION} on ${URL}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      [[ $# -ge 2 ]] || die "$1 needs a port"
      PORT="$2"; refresh_url; shift 2 ;;
    -H|--host)
      [[ $# -ge 2 ]] || die "$1 needs a host"
      HOST="$2"; refresh_url; shift 2 ;;
    -n|--no-open) OPEN=0; shift ;;
    --start|start) CMD=start; shift ;;
    --stop|stop) CMD=stop; shift ;;
    --force-recreate|--reset) CMD=start; RECREATE=1; shift ;;
    --manual|--data|manual) CMD=manual; shift ;;
    -h|--help|help) CMD=help; shift ;;
    -V|--version) print_version; exit 0 ;;
    *) die "unknown argument: $1  (try: $0 --help)" ;;
  esac
done

case "$CMD" in
  help) print_usage ;;
  manual) cat "$ROOT/run/manual.txt" ;;
  start) cmd_start "$OPEN" "$RECREATE" ;;
  stop) cmd_stop ;;
esac

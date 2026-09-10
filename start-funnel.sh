#!/usr/bin/env bash
# RinkDesk — expose ONLY the read-only live page to the internet via
# Tailscale Funnel. The rest of the desk (login, editing, settings) is not
# reachable: the funnel points at the dedicated live listener on
# RINKDESK_LIVE_PORT, which serves the live page and the anonymous
# /api/public/* endpoints only.
#
#   ./start-funnel.sh                 # https://<machine>.<tailnet>.ts.net/live/
#   ./start-funnel.sh --path /scores  # use a different URL path
#   ./start-funnel.sh --port 8766     # live listener port (default 8766)
#   ./start-funnel.sh --status        # show the current funnel config
#   ./start-funnel.sh --stop          # stop exposing this path
#
# Requirements: the desk must be running (./start.sh --start), Tailscale must
# be installed and connected, and Funnel must be allowed in your tailnet.
# Tailscale prints a consent URL the first time it needs to enable Funnel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

LIVE_PORT="${RINKDESK_LIVE_PORT:-8766}"
FUNNEL_PATH="${RINKDESK_FUNNEL_PATH:-/live}"
CMD=start

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      [[ $# -ge 2 ]] || die "$1 needs a path"
      FUNNEL_PATH="$2"; shift 2 ;;
    --port)
      [[ $# -ge 2 ]] || die "$1 needs a port"
      LIVE_PORT="$2"; shift 2 ;;
    --status) CMD=status; shift ;;
    --stop|--off) CMD=stop; shift ;;
    -h|--help|help) CMD=help; shift ;;
    *) die "unknown argument: $1  (try: $0 --help)" ;;
  esac
done

[[ "$FUNNEL_PATH" == /* ]] || FUNNEL_PATH="/$FUNNEL_PATH"
FUNNEL_PATH="${FUNNEL_PATH%/}"
[[ -n "$FUNNEL_PATH" ]] || FUNNEL_PATH="/live"

have tailscale || die "tailscale is not installed (https://tailscale.com/download)"

print_usage() {
  cat <<EOF
${BOLD}RinkDesk live funnel${RESET}

  ${GREEN}./start-funnel.sh${RESET}                 expose the live page (path ${FUNNEL_PATH})
  ${GREEN}./start-funnel.sh --path /scores${RESET}  use a different URL path
  ${GREEN}./start-funnel.sh --port 8766${RESET}     live listener port
  ${GREEN}./start-funnel.sh --status${RESET}        show current funnel config
  ${GREEN}./start-funnel.sh --stop${RESET}          stop exposing the path

Env: RINKDESK_LIVE_PORT (default 8766), RINKDESK_FUNNEL_PATH (default /live).
EOF
}

dns_name() {
  tailscale status --json 2>/dev/null | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true
}

require_up() {
  tailscale status >/dev/null 2>&1 || die "tailscale is not connected — run: tailscale up"
  if have curl && ! curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${LIVE_PORT}/"; then
    die "live listener is not answering on 127.0.0.1:${LIVE_PORT}.
  Start the desk first:  ./start.sh --start
  (and check RINKDESK_LIVE_PORT matches docker-compose)"
  fi
}

cmd_status() {
  tailscale funnel status || true
}

cmd_stop() {
  say "Stopping funnel for ${FUNNEL_PATH}…"
  if ! tailscale funnel --set-path "$FUNNEL_PATH" off 2>/dev/null; then
    say "${DIM}could not remove just that path; resetting all funnel config${RESET}"
    tailscale funnel reset
  fi
  say "${GREEN}done${RESET}"
}

cmd_start() {
  require_up
  say "Exposing ${BOLD}http://127.0.0.1:${LIVE_PORT}${RESET} at ${BOLD}${FUNNEL_PATH}${RESET}"
  tailscale funnel --bg --set-path "$FUNNEL_PATH" "http://127.0.0.1:${LIVE_PORT}"
  local dns
  dns="$(dns_name)"
  if [[ -n "$dns" ]]; then
    say "${GREEN}Live page:${RESET}  ${BOLD}https://${dns}${FUNNEL_PATH}/${RESET}"
  else
    say "Run ${BOLD}tailscale funnel status${RESET} for the public URL."
  fi
  say "${DIM}Only ${FUNNEL_PATH} is public; the desk itself stays private.${RESET}"
}

case "$CMD" in
  help) print_usage ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  start) cmd_start ;;
esac

#!/usr/bin/env bash
# RinkDesk — expose ONLY the read-only live page to the internet via
# Tailscale Funnel. The rest of the desk (login, editing, settings) is not
# reachable: the funnel points at the dedicated live listener on
# RINKDESK_LIVE_PORT, which serves the live page and the anonymous
# /api/public/* endpoints only.
#
# This script sets everything up from scratch:
#   1. installs Tailscale if it is missing,
#   2. starts the tailscaled daemon,
#   3. logs in / connects (interactive the first time — the only manual step),
#   4. starts the desk if the live listener is not already answering,
#   5. enables and starts the Funnel, then prints the public URL.
#
#   ./start-funnel.sh                 # https://<machine>.<tailnet>.ts.net/live/
#   ./start-funnel.sh --path /scores  # use a different URL path
#   ./start-funnel.sh --port 8766     # live listener port (default 8766)
#   ./start-funnel.sh --authkey KEY   # non-interactive login (Tailscale auth key)
#   ./start-funnel.sh --no-desk       # never auto-start the desk
#   ./start-funnel.sh --status        # show the current funnel config
#   ./start-funnel.sh --stop          # stop exposing this path
#
# Env: RINKDESK_LIVE_PORT, RINKDESK_FUNNEL_PATH, RINKDESK_TS_AUTHKEY (or
# TS_AUTHKEY).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$ROOT/scripts/lib/platform.sh"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
# shellcheck source=scripts/lib/tailscale.sh
source "$ROOT/scripts/lib/tailscale.sh"

maybe_reexec_wsl "$@"
load_env "$ROOT/.env"

LIVE_PORT="${RINKDESK_LIVE_PORT:-8766}"
FUNNEL_PATH="${RINKDESK_FUNNEL_PATH:-/live}"
AUTHKEY="${RINKDESK_TS_AUTHKEY:-${TS_AUTHKEY:-}}"
START_DESK=1
CMD=start

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      [[ $# -ge 2 ]] || die "$1 needs a path"
      FUNNEL_PATH="$2"; shift 2 ;;
    --port)
      [[ $# -ge 2 ]] || die "$1 needs a port"
      LIVE_PORT="$2"; shift 2 ;;
    --authkey)
      [[ $# -ge 2 ]] || die "$1 needs a key"
      AUTHKEY="$2"; shift 2 ;;
    --no-desk) START_DESK=0; shift ;;
    --status) CMD=status; shift ;;
    --stop | --off) CMD=stop; shift ;;
    -h | --help | help) CMD=help; shift ;;
    *) die "unknown argument: $1  (try: $0 --help)" ;;
  esac
done

[[ "$FUNNEL_PATH" == /* ]] || FUNNEL_PATH="/$FUNNEL_PATH"
FUNNEL_PATH="${FUNNEL_PATH%/}"
[[ -n "$FUNNEL_PATH" ]] || FUNNEL_PATH="/live"

print_usage() {
  cat <<EOF
${BOLD}RinkDesk live funnel${RESET}

  ${GREEN}./start-funnel.sh${RESET}                 set up Tailscale and expose the live page
  ${GREEN}./start-funnel.sh --path /scores${RESET}  use a different URL path
  ${GREEN}./start-funnel.sh --port 8766${RESET}     live listener port
  ${GREEN}./start-funnel.sh --authkey KEY${RESET}   non-interactive Tailscale login
  ${GREEN}./start-funnel.sh --no-desk${RESET}       do not auto-start the desk
  ${GREEN}./start-funnel.sh --status${RESET}        show current funnel config
  ${GREEN}./start-funnel.sh --stop${RESET}          stop exposing the path

Everything is automatic except the Tailscale login, which opens in a browser
(or prints a URL) the first time. Env: RINKDESK_LIVE_PORT (default 8766),
RINKDESK_FUNNEL_PATH (default /live), RINKDESK_TS_AUTHKEY / TS_AUTHKEY.
EOF
}

ensure_desk() {
  [[ "$START_DESK" == 1 ]] || return 0
  if have curl && curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${LIVE_PORT}/"; then
    say "${DIM}desk already answering on 127.0.0.1:${LIVE_PORT}${RESET}"
    return 0
  fi
  say "${BOLD}Live listener is not up — starting the desk…${RESET}"
  bash "$ROOT/start.sh" --start --no-open
  local i
  for i in $(seq 1 60); do
    if have curl && curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${LIVE_PORT}/"; then
      return 0
    fi
    sleep 1
  done
  die "the live listener did not come up on 127.0.0.1:${LIVE_PORT}.
  Check that RINKDESK_LIVE_PORT (${LIVE_PORT}) matches docker-compose, then: ./start.sh --start"
}

cmd_status() {
  find_tailscale || die "Tailscale is not installed. Run: $0"
  ts_do funnel status || true
}

cmd_stop() {
  find_tailscale || die "Tailscale is not installed. Run: $0"
  say "Stopping funnel for ${FUNNEL_PATH}…"
  if ! ts_run funnel --set-path "$FUNNEL_PATH" off >/dev/null 2>&1; then
    say "${DIM}could not remove just that path; resetting all funnel config${RESET}"
    ts_do funnel reset || true
  fi
  say "${GREEN}done${RESET}"
}

cmd_start() {
  ensure_tailscale
  ensure_json_tool
  ensure_tailscaled
  ensure_login
  ensure_desk
  say "Exposing ${BOLD}http://127.0.0.1:${LIVE_PORT}${RESET} at ${BOLD}${FUNNEL_PATH}${RESET}"
  local out rc
  out="$(ts_run funnel --bg --set-path "$FUNNEL_PATH" "http://127.0.0.1:${LIVE_PORT}" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$out"
  if [[ $rc -ne 0 ]]; then
    if printf '%s' "$out" | grep -qiE 'not enabled|enable.*funnel|funnel.*(disabled|admin|acl)'; then
      die "Funnel is not enabled for your tailnet yet.
  Open the link above (Tailscale admin → Access controls) to enable Funnel, then re-run: $0"
    fi
    die "could not start the funnel (see the message above)"
  fi
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

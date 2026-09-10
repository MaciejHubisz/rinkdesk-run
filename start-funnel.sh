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
# TS_AUTHKEY). Windows: .\scripts\start-funnel.cmd
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
    --stop|--off) CMD=stop; shift ;;
    -h|--help|help) CMD=help; shift ;;
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

# Install Tailscale when the command is missing. On Fedora atomic desktops
# (Bazzite/Silverblue) it must be layered, which needs a reboot; on everything
# else the official installer is used.
ensure_tailscale() {
  have tailscale && return 0
  say "${BOLD}Tailscale is not installed — installing it now…${RESET}"
  case "$OS" in
    macos)
      if have brew; then
        brew install tailscale
      else
        die "install Tailscale from https://tailscale.com/download/mac, then re-run $0"
      fi ;;
    *)
      if have rpm-ostree; then
        sudo rpm-ostree install --idempotent tailscale
        die "Tailscale is staged on this atomic system. Reboot, then re-run $0."
      elif have apt-get || have dnf || have yum; then
        curl -fsSL https://tailscale.com/install.sh | sh
      elif have pacman; then
        sudo pacman -S --noconfirm tailscale
      elif have zypper; then
        sudo zypper --non-interactive install tailscale
      else
        die "install Tailscale manually from https://tailscale.com/download"
      fi ;;
  esac
  have tailscale || die "Tailscale install finished but the 'tailscale' command is missing"
}

tailscaled_running() {
  local out
  out="$(tailscale status --json 2>/dev/null || true)"
  [[ "$out" == \{* ]] && return 0
  have systemctl && systemctl is-active --quiet tailscaled 2>/dev/null
}

ensure_tailscaled() {
  tailscaled_running && return 0
  say "Starting the Tailscale daemon…"
  if have systemctl && systemctl list-unit-files tailscaled.service >/dev/null 2>&1; then
    sudo systemctl enable --now tailscaled 2>/dev/null || sudo systemctl start tailscaled 2>/dev/null || true
  elif have rc-service; then
    sudo rc-service tailscaled start 2>/dev/null || true
  elif have brew; then
    brew services start tailscale 2>/dev/null || true
  fi
  local i
  for i in $(seq 1 30); do tailscaled_running && return 0; sleep 1; done
  die "could not start tailscaled. Start it manually, then re-run $0:
  Linux:  sudo systemctl enable --now tailscaled
  macOS:  open the Tailscale app (or: brew services start tailscale)"
}

ts_json() {
  local out
  out="$(tailscale status --json 2>/dev/null || true)"
  if [[ "$out" != \{* && "${EUID:-$(id -u)}" -ne 0 ]]; then
    out="$(sudo tailscale status --json 2>/dev/null || true)"
  fi
  [[ "$out" == \{* ]] && printf '%s' "$out"
}

ts_state() {
  ts_json | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true
}

# Log in / bring the node up. `tailscale up` blocks until login finishes and
# prints the consent URL, which is the one interactive step.
ensure_login() {
  if [[ "$(ts_state)" != Running ]]; then
    say "${BOLD}Tailscale is not connected — starting login…${RESET}"
    if [[ -n "$AUTHKEY" ]]; then
      sudo tailscale up --authkey "$AUTHKEY" --hostname "$(hostname)" \
        || die "tailscale up with the provided auth key failed"
    else
      say "${DIM}Finish the login in the browser (or at the printed URL).${RESET}"
      sudo tailscale up || die "tailscale up failed"
    fi
  fi
  # Make the current user a Tailscale operator so funnel/serve need no sudo.
  if [[ "${EUID:-$(id -u)}" -ne 0 && -n "${USER:-}" ]] \
    && ! tailscale funnel status >/dev/null 2>&1; then
    sudo tailscale set --operator="$USER" >/dev/null 2>&1 || true
  fi
  local i
  for i in $(seq 1 60); do
    [[ "$(ts_state)" == Running ]] && return 0
    sleep 1
  done
  die "Tailscale is still not connected — run: sudo tailscale up"
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

# Run `tailscale funnel`, streaming its output live. Output is never captured:
# when Funnel is not enabled yet Tailscale prints an enable link and waits, so
# the user must see it immediately. Use sudo only when not an operator.
tailscale_funnel() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] || tailscale funnel status >/dev/null 2>&1; then
    tailscale funnel "$@"
  else
    sudo tailscale funnel "$@"
  fi
}

dns_name() {
  ts_json | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true
}

# The one-time URL that enables Funnel for this node. Built from Self.ID so we
# can print it before `tailscale funnel` (which blocks while waiting for it).
enable_funnel_url() {
  local id
  id="$(ts_json | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["Self"].get("ID",""))' 2>/dev/null || true)"
  [[ -n "$id" ]] && printf 'https://login.tailscale.com/f/funnel?node=%s' "$id" || true
}

# Clickable OSC 8 hyperlink where supported; plain URL otherwise.
link() {
  local url="$1" text="${2:-$1}"
  if [[ -t 1 ]]; then
    printf '\033]8;;%s\033\\%s\033]8;;\033\\\n' "$url" "$text"
  else
    printf '%s\n' "$text"
  fi
}

cmd_status() {
  tailscale funnel status 2>/dev/null || sudo tailscale funnel status || true
}

cmd_stop() {
  say "Stopping funnel for ${FUNNEL_PATH}…"
  if ! tailscale_funnel --set-path "$FUNNEL_PATH" off >/dev/null 2>&1; then
    say "${DIM}could not remove just that path; resetting all funnel config${RESET}"
    tailscale_funnel reset >/dev/null 2>&1 || true
  fi
  say "${GREEN}done${RESET}"
}

cmd_start() {
  ensure_tailscale
  ensure_tailscaled
  ensure_login
  ensure_desk
  say "Exposing ${BOLD}http://127.0.0.1:${LIVE_PORT}${RESET} at ${BOLD}${FUNNEL_PATH}${RESET}"
  local eurl
  eurl="$(enable_funnel_url)"
  if [[ -n "$eurl" ]]; then
    say "${DIM}If Funnel is not enabled yet, enable it once (click the link):${RESET}"
    link "$eurl"
  fi
  if ! tailscale_funnel --bg --set-path "$FUNNEL_PATH" "http://127.0.0.1:${LIVE_PORT}"; then
    die "could not start the funnel (see the message above).
  If Funnel is not enabled for your tailnet, open the enable link above and re-run: $0"
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

# shellcheck shell=bash
# Tailscale: locate/install the CLI, start the daemon, log in, and read status.
# Requires platform.sh (and ensure_json_tool before any *_state call).

TAILSCALE=""

# The CLI is on PATH with the Homebrew formula, but the macOS app ships it
# inside the bundle. Look in both places.
find_tailscale() {
  if have tailscale; then TAILSCALE="$(command -v tailscale)"; return 0; fi
  local c
  for c in \
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale" \
    "$HOME/Applications/Tailscale.app/Contents/MacOS/Tailscale"; do
    if [[ -x "$c" ]]; then TAILSCALE="$c"; return 0; fi
  done
  return 1
}

# Run the CLI, escalating to sudo when the daemon refuses (first login has no
# operator set). Output is printed live so interactive URLs are visible.
ts_do() {
  "$TAILSCALE" "$@" && return 0
  [[ "${EUID:-$(id -u)}" -ne 0 ]] || return 1
  sudo "$TAILSCALE" "$@"
}

# Same, but capture output so callers can inspect it.
ts_run() {
  local out rc
  out="$("$TAILSCALE" "$@" 2>&1)" && rc=0 || rc=$?
  if [[ $rc -ne 0 && "${EUID:-$(id -u)}" -ne 0 ]]; then
    out="$(sudo "$TAILSCALE" "$@" 2>&1)" && rc=0 || rc=$?
  fi
  printf '%s\n' "$out"
  return $rc
}

ensure_tailscale() {
  find_tailscale && return 0
  say "${BOLD}Tailscale is not installed — installing it now…${RESET}"
  case "$OS" in
    macos)
      # The macOS app is the supported install: it runs the daemon and bundles
      # the CLI that find_tailscale() looks for.
      ensure_brew
      if ! confirm "Install the Tailscale app with Homebrew?"; then
        die "install Tailscale from https://tailscale.com/download/mac, then re-run $0"
      fi
      brew install --cask tailscale || die "brew install --cask tailscale failed"
      find_tailscale || die "Tailscale installed but its CLI was not found" ;;
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
      fi
      find_tailscale || die "Tailscale install finished but the CLI was not found" ;;
  esac
}

tailscaled_running() {
  local out
  out="$("$TAILSCALE" status --json 2>/dev/null || true)"
  [[ "$out" == \{* ]] && return 0
  have systemctl && systemctl is-active --quiet tailscaled 2>/dev/null
}

ensure_tailscaled() {
  tailscaled_running && return 0
  say "Starting the Tailscale daemon…"
  if is_macos; then
    if [[ -d /Applications/Tailscale.app ]]; then
      open -a Tailscale >/dev/null 2>&1 || true
    elif have brew; then
      # tailscaled needs root; use the absolute brew path so sudo keeps it.
      sudo "$(command -v brew)" services start tailscale 2>/dev/null ||
        brew services start tailscale 2>/dev/null || true
    fi
  elif have systemctl && systemctl list-unit-files tailscaled.service >/dev/null 2>&1; then
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
  macOS:  open the Tailscale app (or: sudo brew services start tailscale)"
}

ts_json() {
  local out
  out="$("$TAILSCALE" status --json 2>/dev/null || true)"
  if [[ "$out" != \{* && "${EUID:-$(id -u)}" -ne 0 ]]; then
    out="$(sudo "$TAILSCALE" status --json 2>/dev/null || true)"
  fi
  [[ "$out" == \{* ]] && printf '%s' "$out"
}

ts_state() {
  local j
  j="$(ts_json)"
  [[ -n "$j" ]] || return 0
  if have python3; then
    printf '%s' "$j" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true
  elif have jq; then
    printf '%s' "$j" | jq -r '.BackendState // ""' 2>/dev/null || true
  fi
}

dns_name() {
  local j
  j="$(ts_json)"
  [[ -n "$j" ]] || return 0
  if have python3; then
    printf '%s' "$j" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true
  elif have jq; then
    printf '%s' "$j" | jq -r '.Self.DNSName | rtrimstr(".")' 2>/dev/null || true
  fi
}

# Log in / bring the node up. `tailscale up` blocks until login finishes and
# prints the consent URL, which is the one interactive step.
ensure_login() {
  [[ "$(ts_state)" == Running ]] && return 0
  say "${BOLD}Tailscale is not connected — starting login…${RESET}"
  if [[ -n "${AUTHKEY:-}" ]]; then
    ts_do up --authkey "$AUTHKEY" --hostname "$(hostname)" ||
      die "tailscale up with the provided auth key failed"
  else
    say "${DIM}Finish the login in the browser (or at the printed URL).${RESET}"
    ts_do up || die "tailscale up failed"
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 && -n "${USER:-}" ]]; then
    ts_do set --operator="$USER" >/dev/null 2>&1 || true
  fi
  local i
  for i in $(seq 1 60); do
    [[ "$(ts_state)" == Running ]] && { say "${GREEN}Tailscale connected${RESET}"; return 0; }
    sleep 1
  done
  die "Tailscale is still not connected — run: sudo tailscale up"
}

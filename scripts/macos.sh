# shellcheck shell=bash
# macOS runtime bootstrap for the shared lifecycle.
#
# Sourced by start.sh on Darwin before it execs common/ops/start.sh. The shared
# lifecycle assumes Linux (systemd, SELinux, native Docker/Podman); on macOS the
# container engine runs inside a Linux VM, so this brings up Homebrew's PATH and
# a container runtime (Colima, Docker Desktop, OrbStack, or a Podman machine)
# before handing over. Linux never sources this file.
#
# Can also be run directly:
#   scripts/macos.sh
#   scripts/macos.sh --install-service
#   scripts/macos.sh --uninstall-service

MACOS_ROOT="${APP_RUN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MACOS_APP_CONFIG="${APP_CONFIG:-$MACOS_ROOT/app.conf}"
# shellcheck disable=SC1090
[[ -f "$MACOS_APP_CONFIG" ]] && source "$MACOS_APP_CONFIG"

macos_say() { printf '%s\n' "$*"; }
macos_warn() { printf '%s\n' "warn: $*" >&2; }
macos_die() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

# --- Homebrew -------------------------------------------------------------

macos_brew_bin() {
  local c
  for c in "$(command -v brew 2>/dev/null || true)" \
    /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -n "$c" && -x "$c" ]] && {
      printf '%s\n' "$c"
      return 0
    }
  done
  return 1
}

# Put Homebrew's bin dirs on PATH for this (possibly non-interactive) shell.
macos_brew_path() {
  local b
  b="$(macos_brew_bin)" || return 1
  eval "$("$b" shellenv)" 2>/dev/null || true
  hash -r 2>/dev/null || true
}

# --- Container engine -----------------------------------------------------

macos_engine_ready() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    return 0
  fi
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Start a Docker-compatible CLI: Colima (the common brew setup), Docker
# Desktop, or OrbStack. Returns non-zero when none of them is installed.
macos_start_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  local ctx
  ctx="$(docker context show 2>/dev/null || true)"
  if [[ "$ctx" == colima ]] && command -v colima >/dev/null 2>&1; then
    macos_say "Starting Colima…"
    colima start || return 1
    return 0
  fi
  if [[ -d /Applications/Docker.app ]]; then
    macos_say "Starting Docker Desktop…"
    open -ga Docker || return 1
    return 0
  fi
  if [[ -d /Applications/OrbStack.app ]]; then
    macos_say "Starting OrbStack…"
    open -ga OrbStack || return 1
    return 0
  fi
  if command -v colima >/dev/null 2>&1; then
    macos_say "Starting Colima…"
    colima start || return 1
    return 0
  fi
  return 1
}

# Ensure Podman exists (install from Homebrew if needed) and its Linux VM is
# up. The vm must be initialised once; `machine start` is a no-op if running.
macos_start_podman() {
  if ! command -v podman >/dev/null 2>&1; then
    local b
    b="$(macos_brew_bin)" || return 1
    macos_say "Installing Podman with Homebrew…"
    HOMEBREW_NO_AUTO_UPDATE=1 "$b" install podman podman-compose || return 1
    hash -r 2>/dev/null || true
  fi
  command -v podman >/dev/null 2>&1 || return 1
  local machines
  machines="$(podman machine list --format '{{.Name}}' 2>/dev/null | grep -v '^[[:space:]]*$' || true)"
  if [[ -z "$machines" ]]; then
    macos_say "Creating the Podman machine (first run downloads a VM)…"
    podman machine init || return 1
  fi
  macos_say "Starting the Podman machine…"
  podman machine start >/dev/null 2>&1 || true
  return 0
}

macos_wait_engine() {
  local i
  for i in $(seq 1 180); do
    macos_engine_ready && return 0
    sleep 1
  done
  return 1
}

# Remove the credsStore key from a docker config, with jq or python3.
macos_strip_creds_store() {
  local cfg="$1" tmp
  tmp="$(mktemp)" || return 1
  if command -v jq >/dev/null 2>&1; then
    if ! jq 'del(.credsStore)' "$cfg" >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if ! python3 - "$cfg" >"$tmp" 2>/dev/null <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
data.pop("credsStore", None)
json.dump(data, sys.stdout, indent="\t")
sys.stdout.write("\n")
PY
    then
      rm -f "$tmp"
      return 1
    fi
  else
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$cfg"
}

# A leftover `credsStore` from a since-removed Docker Desktop makes every pull
# fail with "docker-credential-desktop: executable file not found". Drop the
# stale helper (backing the file up) so docker stores creds in config.json.
macos_fix_docker_creds() {
  [[ "${MACOS_NO_CONFIG_FIX:-0}" == 1 ]] && return 0
  local cfg="$HOME/.docker/config.json" store helper
  [[ -f "$cfg" ]] || return 0
  store="$(sed -n 's/.*"credsStore"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -1)"
  [[ -n "$store" ]] || return 0
  helper="docker-credential-${store}"
  command -v "$helper" >/dev/null 2>&1 && return 0
  macos_say "Docker config uses ${helper}, which is not installed — removing credsStore."
  cp -p "$cfg" "${cfg}.bak" 2>/dev/null || true
  if macos_strip_creds_store "$cfg"; then
    macos_say "  backup: ${cfg}.bak"
  else
    macos_warn "could not edit ${cfg} automatically; remove \"credsStore\": \"${store}\" by hand (no ${helper} installed)."
  fi
}

# Make sure a compose implementation is on PATH for the engine we ended up with.
macos_ensure_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  command -v docker-compose >/dev/null 2>&1 && return 0
  command -v podman-compose >/dev/null 2>&1 && return 0
  local b
  b="$(macos_brew_bin)" || return 1
  if command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    macos_say "Installing Compose with Homebrew…"
    HOMEBREW_NO_AUTO_UPDATE=1 "$b" install podman-compose || true
  else
    macos_say "Installing Compose with Homebrew…"
    HOMEBREW_NO_AUTO_UPDATE=1 "$b" install docker-compose || true
  fi
  hash -r 2>/dev/null || true
}

# Bring up brew, the engine, and compose. Safe to call when everything is
# already running (returns immediately).
macos_prepare() {
  [[ "$(uname -s)" == Darwin ]] || return 0
  macos_brew_path || true
  if macos_engine_ready; then
    macos_fix_docker_creds || true
    macos_ensure_compose || true
    return 0
  fi
  macos_say "No container runtime is running — starting one…"
  if macos_start_docker; then
    if macos_wait_engine; then
      macos_fix_docker_creds || true
      macos_ensure_compose || true
      macos_say "Container runtime is ready."
      return 0
    fi
    macos_warn "Docker did not come up — trying Podman."
  fi
  if macos_start_podman && macos_wait_engine; then
    macos_ensure_compose || true
    macos_say "Container runtime is ready."
    return 0
  fi
  macos_die "no container runtime on macOS.
  Install one and re-run:
    Colima:         brew install colima docker docker-compose && colima start
    Docker Desktop: https://www.docker.com/products/docker-desktop/
    Podman:         brew install podman podman-compose && podman machine init && podman machine start"
}

# --- Run-on-login service (launchd) --------------------------------------

macos_service_label() {
  printf 'com.%s.run\n' "${APP_SLUG:-${APP_SYSTEMD_UNIT:-rinkdesk}}"
}

macos_plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(macos_service_label)"
}

macos_install_service() {
  local plist label uid
  plist="$(macos_plist_path)"
  label="$(macos_service_label)"
  uid="${UID:-$(id -u)}"
  mkdir -p "$HOME/Library/LaunchAgents" || macos_die "cannot create ~/Library/LaunchAgents"
  macos_say "Installing launchd agent ${label}"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${MACOS_ROOT}/start.sh</string>
    <string>--start</string>
    <string>--no-open</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${MACOS_ROOT}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${MACOS_ROOT}/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>${MACOS_ROOT}/launchd.err.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${uid}" "$plist" || macos_die "launchctl bootstrap failed"
  launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true
  macos_say "installed and started — it runs at login (needs a graphical login)"
  macos_say "  launchctl print gui/${uid}/${label}"
  macos_say "  tail -f ${MACOS_ROOT}/launchd.err.log"
}

macos_uninstall_service() {
  local plist label uid
  plist="$(macos_plist_path)"
  label="$(macos_service_label)"
  uid="${UID:-$(id -u)}"
  launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
  rm -f "$plist"
  macos_say "removed ${label}"
}

# --- Entry point ----------------------------------------------------------

# Called by start.sh with the original argv. Intercepts the service commands
# (systemd does not exist here); otherwise only spins up the engine for
# commands that actually need it, and just fixes PATH for read-only ones.
macos_main() {
  local arg needs_engine=0
  for arg in "$@"; do
    case "$arg" in
      --install-service) macos_install_service; exit 0 ;;
      --uninstall-service) macos_uninstall_service; exit 0 ;;
      -h | --help | help | -V | --version | --manual | --paths | --where) return 0 ;;
      --start | start | --update | update | --force-recreate | --reset | --login) needs_engine=1 ;;
    esac
  done
  if [[ "$needs_engine" == 1 ]]; then
    macos_prepare
  else
    macos_brew_path || true
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  macos_main "$@"
fi

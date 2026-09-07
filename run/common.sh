# Shared by ./start.sh and ./build.sh. Expects ROOT.

: "${ROOT:?ROOT must be set}"

PORT="${RINKDESK_PORT:-8765}"
HOST="${RINKDESK_HOST:-127.0.0.1}"
URL="http://${HOST}:${PORT}/"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || printf '1.0.0')"

ENGINE=""
COMPOSE=()
OS=""
WSL=0

if [[ -t 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[38;5;203m' GREEN=$'\033[38;5;114m' RESET=$'\033[0m'
else
  BOLD="" DIM="" RED="" GREEN="" RESET=""
fi

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
git_commit() { git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf 'dev'; }
print_version() { printf '%s\n' "RinkDesk ${APP_VERSION} ($(git_commit))"; }
refresh_url() { URL="http://${HOST}:${PORT}/"; }

detect_os() {
  WSL=0
  case "$(uname -s 2>/dev/null)" in
    Darwin) OS=macos ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *)
      OS=linux
      if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] \
        || { [[ -r /proc/version ]] && grep -qi microsoft /proc/version; }; then
        WSL=1
      fi
      ;;
  esac
}

# Git Bash on Windows cannot talk to Docker Desktop reliably — jump into WSL.
maybe_reexec_wsl() {
  detect_os
  [[ "$OS" == windows ]] || return 0
  local wslbin="" distro unix
  if have wsl.exe; then wslbin=wsl.exe
  elif have wsl; then wslbin=wsl
  else
    die "Windows needs WSL. In Administrator PowerShell: wsl --install
Then:  .\\install\\windows.cmd --start"
  fi
  distro="$(
    "$wslbin" --list --quiet --utf8 2>/dev/null || "$wslbin" --list --quiet 2>/dev/null | tr -d '\0'
  )"
  distro="$(printf '%s\n' "$distro" | while IFS= read -r n; do
    n="${n//$'\r'/}"
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    case "$n" in ''|docker-desktop|docker-desktop-data|rancher-desktop) continue ;; esac
    printf '%s\n' "$n"
    break
  done)"
  [[ -n "$distro" ]] || die "No WSL Linux distro (docker-desktop is not enough). wsl --install -d Ubuntu"
  unix="$("$wslbin" -d "$distro" wslpath -a "$ROOT" 2>/dev/null | tr -d '\r')"
  [[ -n "$unix" ]] || die "could not map $ROOT into WSL ($distro)"
  say "${DIM}Windows → WSL (${distro})${RESET}"
  exec "$wslbin" -d "$distro" -e bash "$unix/$(basename "$0")" "$@"
}

find_engine() {
  local bin
  for bin in docker podman; do
    if have "$bin" && "$bin" info >/dev/null 2>&1; then ENGINE="$bin"; return 0; fi
  done
  for bin in docker podman; do
    if have "$bin"; then ENGINE="$bin"; return 0; fi
  done
  return 1
}

find_compose() {
  COMPOSE=()
  if [[ "$ENGINE" == docker ]]; then
    docker compose version >/dev/null 2>&1 && { COMPOSE=(docker compose); return 0; }
    have docker-compose && { COMPOSE=(docker-compose); return 0; }
  fi
  if [[ "$ENGINE" == podman ]]; then
    podman compose version >/dev/null 2>&1 && { COMPOSE=(podman compose); return 0; }
    have podman-compose && { COMPOSE=(podman-compose); return 0; }
  fi
  have docker-compose && { COMPOSE=(docker-compose); return 0; }
  have podman-compose && { COMPOSE=(podman-compose); return 0; }
  return 1
}

engine_ready() { [[ -n "${ENGINE:-}" ]] && "$ENGINE" info >/dev/null 2>&1; }

wake_engine() {
  engine_ready && return 0
  if [[ "$OS" == macos ]]; then
    if have colima; then colima start >/dev/null 2>&1 || true
    elif [[ -d /Applications/Docker.app ]]; then open -a Docker >/dev/null 2>&1 || true
    elif have podman; then podman machine start >/dev/null 2>&1 || true
    fi
  else
    if have podman && have systemctl; then systemctl --user start podman.socket >/dev/null 2>&1 || true; fi
    if have docker && have systemctl && systemctl list-unit-files docker.service >/dev/null 2>&1; then
      sudo systemctl start docker >/dev/null 2>&1 || true
    fi
  fi
}

ensure_runtime() {
  detect_os
  [[ -n "${ENGINE:-}" && ${#COMPOSE[@]} -gt 0 ]] && engine_ready && return 0
  find_engine || die "no docker or podman. Install Docker Desktop (Windows/macOS) or docker/podman (Linux)."
  wake_engine
  local i
  for i in $(seq 1 30); do engine_ready && break; sleep 1; done
  engine_ready || die "$ENGINE is installed but the daemon is not running.
  macOS: colima start   or open Docker Desktop
  Linux: sudo systemctl start docker   or   systemctl --user start podman.socket
  Windows: Docker Desktop + WSL integration, then rerun."
  find_compose || die "no compose for $ENGINE (need: docker compose / podman compose)"
  say "${DIM}engine ${ENGINE}  compose ${COMPOSE[*]}${RESET}"
}

compose() {
  "${COMPOSE[@]}" -f "$ROOT/docker-compose.yml" "$@"
}

open_browser() {
  local target="$1"
  if [[ "$OS" == macos ]] && have open; then open "$target" >/dev/null 2>&1 || true
  elif [[ "$WSL" == 1 ]]; then
    if have wslview; then wslview "$target" >/dev/null 2>&1 || true
    elif have explorer.exe; then explorer.exe "$target" >/dev/null 2>&1 || true
    elif [[ -x /mnt/c/Windows/explorer.exe ]]; then /mnt/c/Windows/explorer.exe "$target" >/dev/null 2>&1 || true
    elif have xdg-open; then xdg-open "$target" >/dev/null 2>&1 || true
    else say "Open ${target} in a browser."
    fi
  elif have xdg-open; then xdg-open "$target" >/dev/null 2>&1 || true
  elif have open; then open "$target" >/dev/null 2>&1 || true
  else say "Open ${target} in a browser."
  fi
}

wait_until_up() {
  local i
  say "${DIM}Waiting for ${URL}…${RESET}"
  for i in $(seq 1 180); do
    if have curl && curl -sf -o /dev/null --max-time 1 "$URL"; then return 0; fi
    sleep 1
  done
  return 1
}

detect_os

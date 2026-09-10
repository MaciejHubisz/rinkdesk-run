# shellcheck shell=bash
# Container runtime: find/start docker or podman + compose, and wait for the desk.
# Requires ROOT and platform.sh.

ENGINE=""
COMPOSE=()

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
  if is_macos; then
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
  if ! find_engine; then
    if is_macos; then
      say "No Docker runtime found on macOS."
      brew_ensure colima docker docker-compose
      find_engine || die "docker is still missing after install"
    else
      die "no docker or podman. Install Docker Desktop (Windows) or docker/podman (Linux)."
    fi
  fi
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

wait_until_up() {
  local i
  say "${DIM}Waiting for ${URL}…${RESET}"
  for i in $(seq 1 180); do
    if have curl && curl -sf -o /dev/null --max-time 1 "$URL"; then return 0; fi
    sleep 1
  done
  return 1
}

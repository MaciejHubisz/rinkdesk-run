# RinkDesk — docker/podman + compose.
# Sourced by commands that talk to the container runtime.

ENGINE=""
COMPOSE=()

# Prefer a runtime that actually answers `info`. Homebrew often ships a
# docker CLI with no daemon (typical on Bazzite); that must not win over
# Podman. Remember the first engine present so we can start its daemon.
find_engine() {
  local bin
  for bin in docker podman; do
    if have "$bin" && "$bin" info >/dev/null 2>&1; then
      ENGINE="$bin"
      return 0
    fi
  done
  for bin in podman docker; do
    if have "$bin"; then
      ENGINE="$bin"
      return 0
    fi
  done
  return 1
}

find_compose() {
  COMPOSE=()
  if [[ "$ENGINE" == docker ]]; then
    if docker compose version >/dev/null 2>&1; then
      COMPOSE=(docker compose)
      return 0
    fi
    if have docker-compose; then
      COMPOSE=(docker-compose)
      return 0
    fi
  fi
  if [[ "$ENGINE" == podman ]]; then
    if podman compose version >/dev/null 2>&1; then
      COMPOSE=(podman compose)
      return 0
    fi
    if have podman-compose; then
      COMPOSE=(podman-compose)
      return 0
    fi
  fi
  if have docker-compose; then
    COMPOSE=(docker-compose)
    return 0
  fi
  if have podman-compose; then
    COMPOSE=(podman-compose)
    return 0
  fi
  return 1
}

engine_ready() {
  [[ -n "${ENGINE:-}" ]] || return 1
  "$ENGINE" info >/dev/null 2>&1
}

# Nothing usable on PATH — put one on (brew first).
install_engine_packages() {
  if is_macos; then
    say "${DIM}No container runtime on macOS — installing Colima + Docker + Compose via brew.${RESET}"
    install_packages colima docker docker-compose
    return 0
  fi
  say "No container engine in PATH (no docker, no podman)."
  if have rpm-ostree; then
    install_packages podman podman-compose
  elif have apt-get; then
    install_packages docker.io docker-compose-v2 || install_packages docker.io docker-compose
  else
    install_packages podman podman-compose || install_packages docker docker-compose
  fi
}

# Initialise (once) and boot the podman VM on macOS.
mac_podman_start() {
  if podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
    say "${DIM}Starting podman machine…${RESET}"
    podman machine start >/dev/null 2>&1 || true
  else
    say "${DIM}Initialising podman machine…${RESET}"
    podman machine init >/dev/null 2>&1 || true
    podman machine start >/dev/null 2>&1 || true
  fi
}

# Wake the daemon behind an installed-but-idle CLI.
# macOS containers always run in a VM: Colima (default) or a podman machine.
engine_daemon_up() {
  if engine_ready; then
    return 0
  fi
  if is_macos; then
    if [[ "$ENGINE" == docker ]]; then
      if have colima; then
        say "${DIM}Starting Colima VM…${RESET}"
        colima start >/dev/null 2>&1 || true
      elif [[ -d /Applications/Docker.app ]]; then
        say "${DIM}Opening Docker Desktop…${RESET}"
        open -a Docker >/dev/null 2>&1 || true
      elif have podman; then
        mac_podman_start
      else
        say "${DIM}Installing Colima + Docker + Compose via brew…${RESET}"
        install_packages colima docker docker-compose || true
        colima start >/dev/null 2>&1 || true
      fi
    elif [[ "$ENGINE" == podman ]]; then
      mac_podman_start
    fi
    return 0
  fi
  if have podman && have systemctl; then
    systemctl --user start podman.socket >/dev/null 2>&1 || true
  fi
  if have docker && have systemctl && systemctl list-unit-files docker.service >/dev/null 2>&1; then
    say "${DIM}Starting docker.service…${RESET}"
    sudo systemctl start docker >/dev/null 2>&1 || true
  fi
  return 0
}

# Give a freshly started daemon up to ~30s to answer.
wait_engine() {
  local i
  for i in $(seq 1 30); do
    engine_ready && return 0
    sleep 1
  done
  return 1
}

# A compose provider for the chosen engine (brew first).
ensure_compose() {
  if [[ "$ENGINE" == docker ]]; then
    if ! docker compose version >/dev/null 2>&1 && ! have docker-compose; then
      say "${DIM}Installing docker compose plugin…${RESET}"
      install_packages docker-compose || install_packages docker-compose-plugin || true
    fi
  else
    if ! podman compose version >/dev/null 2>&1 && ! have podman-compose; then
      if have python3; then
        say "${DIM}Installing podman-compose with pip --user${RESET}"
        python3 -m pip install --user podman-compose || true
      else
        install_packages podman-compose || true
      fi
    fi
  fi
}

ensure_runtime() {
  [[ -n "${ENGINE:-}" && ${#COMPOSE[@]} -gt 0 ]] && engine_ready && return 0

  ensure_python

  if ! find_engine; then
    install_engine_packages
    find_engine || die "still no docker or podman after install"
  fi

  engine_daemon_up

  if ! engine_ready; then
    wait_engine || {
      die "${ENGINE} is installed but cannot talk to the container runtime (${ENGINE} info failed).
  macOS: start the VM manually and rerun:
         colima start            (Docker via Colima, the default)
         podman machine start    (Podman VM)
  Linux (Bazzite): Podman is bundled — a Homebrew docker CLI without a daemon is not enough.
  Windows: run from PowerShell as .\\start.ps1 (WSL). Inside WSL start Docker Desktop
           WSL integration, or podman, then rerun."
    }
  fi

  if ! find_compose; then
    say "Compose plugin missing for ${ENGINE}."
    ensure_compose
    find_compose || die "still no compose after install (tried docker compose / podman compose / podman-compose)"
  fi

  say "${DIM}engine ${ENGINE}  compose ${COMPOSE[*]}${RESET}"
}

compose() {
  ensure_runtime
  "${COMPOSE[@]}" -f "$ROOT/docker-compose.yml" "$@"
}

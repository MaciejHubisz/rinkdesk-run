# shellcheck shell=bash
# Container runtime: find/start docker or podman + compose, and wait for the desk.
# Requires ROOT and platform.sh.

ENGINE=""
COMPOSE=()

# Rootless Docker and user-local installs live under $HOME. Make sure they are
# on PATH, and point the CLI at the rootless socket when one exists.
prepare_user_paths() {
  local d
  for d in "$HOME/bin" "$HOME/.local/bin"; do
    [[ -d "$d" ]] || continue
    case ":$PATH:" in
      *":$d:"*) ;;
      *) PATH="$d:$PATH" ;;
    esac
  done
  export PATH
  if [[ -z "${DOCKER_HOST:-}" && -S "/run/user/$(id -u)/docker.sock" ]]; then
    export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
  fi
}

find_engine() {
  prepare_user_paths
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
    # Rootless daemons run as the user (systemd --user), no root needed.
    have systemctl && systemctl --user start podman.socket >/dev/null 2>&1 || true
    have systemctl && systemctl --user start docker >/dev/null 2>&1 || true
    # Rootful daemons need root; only try when we can actually get it.
    if can_sudo; then
      if have podman && have systemctl; then
        as_root systemctl enable --now podman.socket >/dev/null 2>&1 || true
      fi
      if have docker && have systemctl; then
        as_root systemctl enable --now docker >/dev/null 2>&1 ||
          as_root systemctl start docker >/dev/null 2>&1 || true
      fi
    fi
  fi
}

# Install Docker rootless under $HOME, for hosts where the user has no sudo.
# Prerequisites (uidmap, subuid range) need one-time admin help and are
# reported clearly instead of attempting a doomed sudo.
install_engine_rootless() {
  say "${BOLD}No sudo available — installing rootless Docker into your home directory…${RESET}"
  have curl || die "curl is required to install rootless Docker"
  if ! have newuidmap || ! have newgidmap; then
    die "rootless Docker needs newuidmap/newgidmap (the 'uidmap' package).
  Ask an administrator for one of these, then re-run $0:
    a) rootless:      sudo apt-get install -y uidmap   # or: sudo dnf install -y shadow-utils
                      sudo loginctl enable-linger $(id -un)
    b) docker group:  sudo usermod -aG docker $(id -un)   # then log out and back in"
  fi
  if ! grep -qE "^($(id -un)|$(id -u)):" /etc/subuid 2>/dev/null ||
    ! grep -qE "^($(id -un)|$(id -u)):" /etc/subgid 2>/dev/null; then
    die "no subuid/subgid range for $(id -un).
  Ask an administrator to run once, then re-run $0:
    echo '$(id -un):100000:65536' | sudo tee -a /etc/subuid
    echo '$(id -un):100000:65536' | sudo tee -a /etc/subgid"
  fi
  curl -fsSL https://get.docker.com/rootless | sh ||
    die "rootless Docker install failed (see the messages above)"
  export PATH="$HOME/bin:$PATH"
  export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
  hash -r 2>/dev/null || true
  install_compose_plugin_rootless
  if have loginctl; then
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 ||
      say "${DIM}note: could not enable-linger; the daemon may stop when you log out${RESET}"
  fi
  say "${DIM}rootless Docker installed under $HOME/bin${RESET}"
}

# The rootless installer ships the CLI and daemon but not the compose plugin.
install_compose_plugin_rootless() {
  docker compose version >/dev/null 2>&1 && return 0
  local arch dir="$HOME/.docker/cli-plugins"
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) arch="$(uname -m)" ;;
  esac
  say "${DIM}installing the docker compose plugin…${RESET}"
  mkdir -p "$dir" || die "cannot create $dir"
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
    -o "$dir/docker-compose" || die "could not download the compose plugin"
  chmod +x "$dir/docker-compose"
}

# Install Docker system-wide with the package manager (needs root).
install_engine_system() {
  if ! confirm "Install Docker with the system package manager?"; then
    die "no docker or podman. Install one and re-run $0:
  Debian/Ubuntu:  sudo apt-get install -y docker.io docker-compose-v2
  Fedora/RHEL:    sudo dnf install -y docker docker-compose-plugin
  Arch:           sudo pacman -S --noconfirm docker docker-compose
  openSUSE:       sudo zypper install -y docker docker-compose
  Or just re-run with --yes to let this script do it."
  fi

  local installed=0
  if have rpm-ostree && [[ -e /run/ostree-booted ]]; then
    say "${BOLD}Atomic host detected — staging Docker with rpm-ostree…${RESET}"
    as_root rpm-ostree install --idempotent docker docker-compose ||
      die "rpm-ostree install failed"
    die "Docker is staged on this atomic system. Reboot, then re-run $0."
  elif have apt-get; then
    as_root apt-get update -y || die "apt-get update failed"
    if as_root apt-get install -y docker.io docker-compose-v2; then installed=1; fi
    if [[ "$installed" == 0 ]]; then
      if as_root apt-get install -y docker.io docker-compose; then installed=1; fi
    fi
  elif have dnf; then
    if as_root dnf install -y docker docker-compose-plugin; then installed=1; fi
    if [[ "$installed" == 0 ]] && as_root dnf install -y moby-engine docker-compose; then installed=1; fi
  elif have yum; then
    if as_root yum install -y docker docker-compose-plugin; then installed=1; fi
    if [[ "$installed" == 0 ]] && as_root yum install -y docker docker-compose; then installed=1; fi
  elif have pacman; then
    as_root pacman -S --noconfirm docker docker-compose && installed=1
  elif have zypper; then
    as_root zypper --non-interactive install docker docker-compose && installed=1
  fi

  if [[ "$installed" == 0 ]]; then
    if have curl; then
      say "${DIM}package manager failed or unsupported — using get.docker.com${RESET}"
      curl -fsSL https://get.docker.com | as_root sh ||
        die "Docker install script failed"
    else
      die "could not install a container runtime automatically (need curl or a supported package manager)"
    fi
  fi

  hash -r 2>/dev/null || true
  find_engine || die "a runtime was installed but no docker/podman was found on PATH"
}

# Install a container runtime on a Linux host that has none. Use the system
# package manager when we can get root, otherwise fall back to rootless Docker.
install_engine_linux() {
  say "${BOLD}No container runtime found — installing one…${RESET}"
  if can_sudo; then
    install_engine_system
  else
    install_engine_rootless
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
      install_engine_linux
    fi
  fi
  wake_engine
  local i
  for i in $(seq 1 30); do engine_ready && break; sleep 1; done
  engine_ready || die "$ENGINE is installed but the daemon is not running.
  Rootless: systemctl --user start docker
  Linux:    sudo systemctl start docker   or   systemctl --user start podman.socket
  Then re-run $0."
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

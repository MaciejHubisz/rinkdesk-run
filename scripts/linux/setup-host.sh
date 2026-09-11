#!/usr/bin/env bash
# One-time host setup for RinkDesk. An administrator runs this once with
# root (or sudo); after that the operator can run ./start.sh without sudo.
#
# It installs Docker + Compose, enables the daemon on boot, and adds the
# operator to the docker group.
#
#   sudo scripts/linux/setup-host.sh              # user = $SUDO_USER
#   sudo scripts/linux/setup-host.sh maciej
#
# Idempotent: safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$ROOT/scripts/lib/platform.sh"
# shellcheck source=scripts/lib/engine.sh
source "$ROOT/scripts/lib/engine.sh"

usage() {
  cat <<EOF
${BOLD}RinkDesk host setup${RESET} (run as root)

  sudo $0 [USER]     install Docker, enable it, grant USER docker access

  USER defaults to \$SUDO_USER.
EOF
}

case "${1:-}" in
  -h | --help | help) usage; exit 0 ;;
esac

detect_os
is_linux || die "this host setup script is Linux only"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "run me as root:  sudo $0 [USER]"
fi

TARGET_USER="${1:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
  die "specify the operator account:  sudo $0 USER"
fi
id "$TARGET_USER" >/dev/null 2>&1 || die "no such user: $TARGET_USER"

say "${BOLD}Setting up this host for RinkDesk${RESET}  (operator: ${TARGET_USER})"

# Install Docker if there is no runtime yet. The script is being run on
# purpose, so do not ask again.
RINKDESK_ASSUME_YES=1
export RINKDESK_ASSUME_YES
if ! find_engine; then
  install_engine_linux
fi
find_engine || die "no docker/podman on PATH after install"
say "${DIM}engine ${ENGINE}${RESET}"

# Make the daemon start now and on every boot.
if have systemctl; then
  if [[ "$ENGINE" == docker ]]; then
    systemctl enable --now docker >/dev/null 2>&1 ||
      systemctl start docker >/dev/null 2>&1 || true
  elif [[ "$ENGINE" == podman ]]; then
    systemctl enable --now podman.socket >/dev/null 2>&1 || true
  fi
fi

# Let the operator talk to the daemon without sudo.
if [[ "$ENGINE" == docker ]]; then
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$TARGET_USER"
    say "${GREEN}added${RESET} ${TARGET_USER} to the docker group"
  else
    warn "no 'docker' group found — the operator may still need sudo"
  fi
fi

# Compose must be available as 'docker compose' (plugin) or 'docker-compose'.
if ! find_compose; then
  warn "no compose found. Install the compose plugin, e.g.:
  Debian/Ubuntu:  apt-get install -y docker-compose-v2
  Fedora/RHEL:    dnf install -y docker-compose-plugin"
fi

say ""
say "${GREEN}Host ready.${RESET}"
say "The group change applies to new logins. The operator should now run:"
say "  ${BOLD}ssh ${TARGET_USER}@$(hostname)${RESET}   (or: newgrp docker)"
say "  cd ${ROOT} && ./start.sh --start"

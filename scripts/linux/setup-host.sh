#!/usr/bin/env bash
# One-time host setup for RinkDesk. An administrator runs this once with
# root (or sudo). It installs Homebrew for the operator and the few system
# bits Homebrew needs, then everything else (Podman + the app) is done by
# ./start.sh without sudo.
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

usage() {
  cat <<EOF
${BOLD}RinkDesk host setup${RESET} (run as root)

  sudo $0 [USER]     install Homebrew prerequisites + Homebrew for USER

  USER defaults to \$SUDO_USER. After this, USER runs ./start.sh (no sudo);
  start.sh installs Podman and the rest with Homebrew.
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

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || die "no home directory for $TARGET_USER"

# Run a command as the operator (we are root, so no password is needed).
if have runuser; then
  as_user() { runuser -u "$TARGET_USER" -- "$@"; }
elif have su; then
  as_user() { su -s /bin/bash "$TARGET_USER" -c "$(printf '%q ' "$@")"; }
else
  die "need 'runuser' or 'su' to install Homebrew as ${TARGET_USER}"
fi

say "${BOLD}Setting up this host for RinkDesk${RESET}  (operator: ${TARGET_USER})"

install_prereqs() {
  say "${DIM}installing Homebrew prerequisites…${RESET}"
  if have apt-get; then
    apt-get update -y
    apt-get install -y build-essential procps curl file git python3
  elif have dnf; then
    dnf install -y @development-tools procps-ng curl file git python3
  elif have yum; then
    yum install -y gcc gcc-c++ make procps-ng curl file git python3
  elif have pacman; then
    pacman -S --noconfirm base-devel procps-ng curl file git python3
  elif have zypper; then
    zypper --non-interactive install -t pattern devel_basis
    zypper --non-interactive install procps curl file git python3
  else
    warn "unknown package manager — install build tools, curl, file, git, python3 manually"
  fi
}

# Install Homebrew into the operator's home without sudo (clone method), then
# make the shell pick it up on the next login.
install_homebrew() {
  local prefix="$TARGET_HOME/.linuxbrew"
  if [[ -x "$prefix/bin/brew" ]]; then
    say "${DIM}Homebrew already present at ${prefix}${RESET}"
  else
    say "${DIM}installing Homebrew into ${prefix}…${RESET}"
    as_user git clone --depth=1 https://github.com/Homebrew/brew "$prefix/Homebrew"
    as_user mkdir -p "$prefix/bin"
    as_user ln -sfn ../Homebrew/bin/brew "$prefix/bin/brew"
  fi

  local rc="$TARGET_HOME/.bashrc"
  if ! grep -qs 'linuxbrew/bin/brew shellenv' "$rc" 2>/dev/null; then
    {
      printf '\n# Homebrew (RinkDesk host setup)\n'
      printf 'eval "$(%s/bin/brew shellenv)"\n' "$prefix"
    } >>"$rc"
    chown "$TARGET_USER" "$rc"
  fi
}

# Let the operator's systemd user manager keep running after logout, so the
# user-level RinkDesk service survives an SSH session ending.
enable_linger() {
  if have loginctl; then
    if loginctl enable-linger "$TARGET_USER" >/dev/null 2>&1; then
      say "${GREEN}enabled${RESET} lingering for ${TARGET_USER}"
    else
      warn "could not enable-linger; the user service may stop at logout"
    fi
  fi
}

install_prereqs
install_homebrew
enable_linger

say ""
say "${GREEN}Host ready.${RESET}"
say "The operator should now log in and run:"
say "  ${BOLD}ssh ${TARGET_USER}@$(hostname)${RESET}"
say "  cd ${ROOT} && ./start.sh --start"
say "${DIM}start.sh installs Podman via Homebrew — no sudo needed.${RESET}"

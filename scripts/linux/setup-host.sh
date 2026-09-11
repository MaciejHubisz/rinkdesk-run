#!/usr/bin/env bash
# One-time host setup for RinkDesk. An administrator runs this once with
# root (or sudo). It installs Homebrew for the operator and the few system
# bits Homebrew/Podman need, then everything else (Podman + the app) is done
# by ./start.sh without sudo.
#
#   sudo scripts/linux/setup-host.sh              # user = $SUDO_USER
#   sudo scripts/linux/setup-host.sh maciej
#
# Idempotent: safe to re-run. Tuned for Ubuntu/Debian (also tries Fedora,
# Arch, openSUSE); handles Ubuntu's unprivileged-userns AppArmor restriction.
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

BREW_PREFIX="/home/linuxbrew/.linuxbrew"
# Respect an existing per-user Homebrew install if the operator already has one.
if [[ -x "$TARGET_HOME/.linuxbrew/bin/brew" ]]; then
  BREW_PREFIX="$TARGET_HOME/.linuxbrew"
fi

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
  say "${DIM}installing Homebrew/Podman prerequisites…${RESET}"
  if have apt-get; then
    apt-get update -y
    apt-get install -y build-essential procps curl file git python3 uidmap fuse3
  elif have dnf; then
    dnf install -y @development-tools procps-ng curl file git python3 shadow-utils fuse3
  elif have yum; then
    yum install -y gcc gcc-c++ make procps-ng curl file git python3 shadow-utils fuse3
  elif have pacman; then
    pacman -S --noconfirm base-devel procps-ng curl file git python3 shadow fuse3
  elif have zypper; then
    zypper --non-interactive install -t pattern devel_basis
    zypper --non-interactive install procps curl file git python3 shadow fuse3
  else
    warn "unknown package manager — install build tools, curl, file, git, python3, uidmap, fuse3 manually"
  fi
}

# Rootless containers need a subordinate UID/GID range for the operator.
ensure_subids() {
  if grep -qE "^(${TARGET_USER}|$(id -u "$TARGET_USER")):" /etc/subuid 2>/dev/null &&
    grep -qE "^(${TARGET_USER}|$(id -u "$TARGET_USER")):" /etc/subgid 2>/dev/null; then
    return 0
  fi
  if have usermod; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$TARGET_USER" &&
      say "${GREEN}added${RESET} subordinate UID/GID range for ${TARGET_USER}"
  else
    warn "no subuid/subgid range for ${TARGET_USER}; rootless Podman may fail"
  fi
}

# Ubuntu restricts unprivileged user namespaces with AppArmor, which breaks
# rootless Podman. Grant it for the Homebrew Podman binary (fall back to
# relaxing the sysctl if the profile cannot be loaded).
setup_userns() {
  local sysctl=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  if [[ -e "$sysctl" && "$(cat "$sysctl" 2>/dev/null)" == 1 ]]; then
    local profile=/etc/apparmor.d/rinkdesk-homebrew
    cat >"$profile" <<'EOF'
abi <abi/4.0>,
include <tunables/global>

# Allow rootless containers from Homebrew-installed Podman.
profile rinkdesk-homebrew-podman-bin /home/*/.linuxbrew/bin/podman flags=(unconfined) {
  userns,
}
profile rinkdesk-homebrew-podman-cellar /home/*/.linuxbrew/Cellar/podman/*/bin/podman flags=(unconfined) {
  userns,
}
EOF
    if have apparmor_parser && apparmor_parser -r "$profile" 2>/dev/null; then
      say "${GREEN}allowed${RESET} unprivileged user namespaces for Homebrew Podman (AppArmor)"
      return 0
    fi
    warn "could not load the AppArmor profile — relaxing the userns sysctl instead"
    printf 'kernel.apparmor_restrict_unprivileged_userns=0\n' \
      >/etc/sysctl.d/99-rinkdesk-userns.conf
    have sysctl && sysctl --system >/dev/null 2>&1 || true
  fi
}

# Install Homebrew into the supported prefix (owned by the operator) without
# sudo, then make the shell pick it up on the next login.
install_homebrew() {
  mkdir -p "$(dirname "$BREW_PREFIX")"
  chown "$TARGET_USER" "$(dirname "$BREW_PREFIX")"
  if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
    say "${DIM}Homebrew already present at ${BREW_PREFIX}${RESET}"
  else
    say "${DIM}installing Homebrew into ${BREW_PREFIX}…${RESET}"
    mkdir -p "$BREW_PREFIX"
    chown "$TARGET_USER" "$BREW_PREFIX"
    as_user git clone --depth=1 https://github.com/Homebrew/brew "$BREW_PREFIX/Homebrew"
    as_user mkdir -p "$BREW_PREFIX/bin"
    as_user ln -sfn ../Homebrew/bin/brew "$BREW_PREFIX/bin/brew"
  fi

  local rc="$TARGET_HOME/.bashrc"
  if ! grep -qs 'linuxbrew/bin/brew shellenv' "$rc" 2>/dev/null; then
    {
      printf '\n# Homebrew (RinkDesk host setup)\n'
      printf 'eval "$(%s/bin/brew shellenv)"\n' "$BREW_PREFIX"
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
ensure_subids
setup_userns
install_homebrew
enable_linger

say ""
say "${GREEN}Host ready.${RESET}"
say "The operator should now log in and run:"
say "  ${BOLD}ssh ${TARGET_USER}@$(hostname)${RESET}"
say "  cd ${ROOT} && ./start.sh --start"
say "${DIM}start.sh installs Podman via Homebrew — no sudo needed.${RESET}"

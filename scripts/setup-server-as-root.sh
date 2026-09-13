#!/usr/bin/env bash
# Prepare a Linux server to run RinkDesk. An administrator runs this once with
# root (or sudo). It installs Homebrew for the operator and the few system
# bits Homebrew/Podman need, then everything else (Podman + the app) is done
# by ./start.sh without sudo.
#
# The filename says what it does and who runs it: setup-server-as-root.sh.
#
#   sudo scripts/setup-server-as-root.sh                    # user = $SUDO_USER
#   sudo scripts/setup-server-as-root.sh maciej             # prepare server only
#   sudo scripts/setup-server-as-root.sh maciej --install-service
#                                                           # prepare + run on boot
#
# Two phases, clearly split by privilege:
#   Phase 1 (root):   prerequisites, Homebrew, subuid range, userns, lingering.
#   Phase 2 (USER):   ./start.sh --install-service — installs Podman, starts the
#                     desk now, and enables it on every boot. Run as the
#                     operator; never as root.
# With --install-service this script runs both phases for you (Phase 2 via
# runuser). Without it, Phase 2 is printed as the next command.
#
# Idempotent: safe to re-run. Tuned for Ubuntu/Debian (also tries Fedora,
# Arch, openSUSE); handles Ubuntu's unprivileged-userns AppArmor restriction.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$ROOT/scripts/lib/platform.sh"

usage() {
  cat <<EOF
${BOLD}RinkDesk server setup${RESET} (run as root)

  sudo $0 [USER]                     prepare the server only (Phase 1)
  sudo $0 [USER] --install-service   prepare the server + run the desk on boot

  USER defaults to \$SUDO_USER.

  Phase 1 (root):  prerequisites, Homebrew, subuid range, user namespaces,
                   and lingering for USER.
  Phase 2 (USER):  ./start.sh --install-service — installs Podman, starts the
                   desk now, and enables it on every boot. No sudo.

  With --install-service this script runs Phase 2 for you as USER. Without it,
  run Phase 2 yourself as USER:
    ./start.sh --install-service
EOF
}

TARGET_USER=""
INSTALL_SERVICE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help | help) usage; exit 0 ;;
    --install-service) INSTALL_SERVICE=1; shift ;;
    -*) die "unknown argument: $1  (try: $0 --help)" ;;
    *) TARGET_USER="$1"; shift ;;
  esac
done

detect_os
is_linux || die "this host setup script is Linux only"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "run me as root:  sudo $0 [USER]"
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
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

# Run a command as the operator with a working systemd --user environment, for
# Phase 2 after lingering is enabled. Waits briefly for the user manager bus.
run_as_operator() {
  local uid runtime_dir
  uid="$(id -u "$TARGET_USER")"
  runtime_dir="/run/user/$uid"
  for _ in $(seq 1 15); do [[ -S "$runtime_dir/bus" ]] && break; sleep 1; done
  if have runuser; then
    runuser -u "$TARGET_USER" -- env \
      HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
      RINKDESK_ASSUME_YES=1 \
      "$@"
  else
    su -s /bin/bash "$TARGET_USER" -c \
      "HOME=$(printf '%q' "$TARGET_HOME") XDG_RUNTIME_DIR=$(printf '%q' "$runtime_dir") DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime_dir/bus RINKDESK_ASSUME_YES=1 $(printf '%q ' "$@")"
  fi
}

say "${BOLD}Phase 1 — prepare the server (as root)${RESET}  (operator: ${TARGET_USER})"

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
say "${GREEN}Server ready.${RESET}"

# Phase 2: install the boot service as the operator (never as root), so the
# unit is a user unit that lives in the operator's systemd manager.
install_service() {
  say ""
  say "${BOLD}Phase 2 — install the boot service as ${TARGET_USER} (no sudo)${RESET}"
  if ! run_as_operator bash "$ROOT/start.sh" --install-service; then
    die "could not install the service as ${TARGET_USER}.
  Log in and run it yourself:
    cd ${ROOT} && ./start.sh --install-service"
  fi
  if run_as_operator systemctl --user is-enabled rinkdesk >/dev/null 2>&1; then
    say "${GREEN}rinkdesk.service enabled${RESET} — starts on every boot"
  else
    warn "could not confirm rinkdesk.service is enabled as ${TARGET_USER}"
  fi
}

if [[ "$INSTALL_SERVICE" == 1 ]]; then
  install_service
  say ""
  say "Check it as ${TARGET_USER}:"
  say "  ${BOLD}systemctl --user status rinkdesk${RESET}"
else
  say "Phase 2 — as ${TARGET_USER}, install the boot service (no sudo):"
  say "  ${BOLD}ssh ${TARGET_USER}@$(hostname)${RESET}"
  say "  cd ${ROOT} && ./start.sh --install-service"
  say "${DIM}Or re-run this script with --install-service to do it now.${RESET}"
fi

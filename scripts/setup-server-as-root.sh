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
#   sudo scripts/setup-server-as-root.sh maciej --install-service --install-nginx
#                                                           # + public HTTPS site
#
# Three phases, clearly split by privilege:
#   Phase 1 (root):    prerequisites, Homebrew, subuid range, userns, lingering.
#   Phase 1b (root):   nginx reverse proxy + certbot TLS, driven by
#                      scripts/admin/admin.env (that folder is the mini-project:
#                      an env file and a site template; this script runs it).
#   Phase 2 (USER):    ./start.sh --install-service — installs Podman, starts the
#                      desk now, and enables it on every boot. Run as the
#                      operator; never as root.
# With --install-service this script runs both phases for you (Phase 2 via
# runuser). Without it, Phase 2 is printed as the next command.
#
# Idempotent: safe to re-run. Tuned for Ubuntu/Debian (also tries Fedora,
# Arch, openSUSE); handles Ubuntu's unprivileged-userns AppArmor restriction.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Image prefix (registry host) used by start.sh, for the login step below.
# shellcheck disable=SC1090
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env"
# Registry credentials (gitignored) let the login run unattended.
# shellcheck disable=SC1090
[[ -f "$ROOT/registry.env" ]] && source "$ROOT/registry.env"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$ROOT/scripts/lib/platform.sh"
# shellcheck source=scripts/lib/registry.sh
source "$ROOT/scripts/lib/registry.sh"

# Admin-level configuration (nginx site + TLS). This folder is the mini-project;
# the logic that applies it lives in this one script.
ADMIN_ENV="$ROOT/scripts/admin/admin.env"
# shellcheck disable=SC1090
[[ -f "$ADMIN_ENV" ]] && source "$ADMIN_ENV"
DOMAIN="${RINKDESK_DOMAIN:-}"
NGINX_PORT="${RINKDESK_PORT:-8765}"
TLS_EMAIL="${RINKDESK_TLS_EMAIL:-}"
ENABLE_TLS="${RINKDESK_ENABLE_TLS:-1}"
NGINX_TEMPLATE="$ROOT/scripts/admin/nginx-site.conf.template"

usage() {
  cat <<EOF
${BOLD}RinkDesk server setup${RESET} (run as root)

  sudo $0 [USER]                     prepare the server only (Phase 1)
  sudo $0 [USER] --install-service   prepare the server + run the desk on boot
  sudo $0 [USER] --install-nginx     also install nginx + TLS (Phase 1b)

  USER defaults to \$SUDO_USER.

  Phase 1 (root):  prerequisites, Homebrew, subuid range, user namespaces,
                   and lingering for USER.
  Phase 1b (root): nginx reverse proxy + certbot TLS, configured from
                   scripts/admin/admin.env.
  Phase 2 (USER):  ./start.sh --install-service — installs Podman, starts the
                   desk now, and enables it on every boot. No sudo.

  Overrides for Phase 1b:
    --domain HOST    public hostname        (RINKDESK_DOMAIN)
    --port PORT      local desk port        (RINKDESK_PORT, default ${NGINX_PORT})
    --email ADDR     Let's Encrypt contact  (RINKDESK_TLS_EMAIL)
    --no-tls         install nginx HTTP-only, skip certbot

  Private image registry (ghcr.io):
    --registry-user USER        registry username (RINKDESK_REGISTRY_USER)
    --registry-token-file FILE  file with a read:packages token
                                (RINKDESK_REGISTRY_TOKEN_FILE)

  The images are private, so the operator logs in once. With --install-service
  the script logs in when a token is available (from the file, the
  RINKDESK_REGISTRY_TOKEN / CR_PAT environment, or a prompt); otherwise it
  prints the one-time ./start.sh --login command. Re-running is safe — an
  existing login is left alone.

  With --install-service this script runs Phase 2 for you as USER. Without it,
  run Phase 2 yourself as USER:
    ./start.sh --install-service
EOF
}

TARGET_USER=""
INSTALL_SERVICE=0
INSTALL_NGINX=0
# Registry login for the private images (optional; also read from the env).
REGISTRY_USER="${RINKDESK_REGISTRY_USER:-}"
REGISTRY_TOKEN_FILE="${RINKDESK_REGISTRY_TOKEN_FILE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help | help) usage; exit 0 ;;
    --install-service) INSTALL_SERVICE=1; shift ;;
    --install-nginx) INSTALL_NGINX=1; shift ;;
    --registry-user)
      [[ $# -ge 2 ]] || die "$1 needs a username"
      REGISTRY_USER="$2"; shift 2 ;;
    --registry-token-file)
      [[ $# -ge 2 ]] || die "$1 needs a path"
      REGISTRY_TOKEN_FILE="$2"; shift 2 ;;
    --domain)
      [[ $# -ge 2 ]] || die "$1 needs a hostname"
      DOMAIN="$2"; shift 2 ;;
    --port)
      [[ $# -ge 2 ]] || die "$1 needs a port"
      NGINX_PORT="$2"; shift 2 ;;
    --email)
      [[ $# -ge 2 ]] || die "$1 needs an address"
      TLS_EMAIL="$2"; shift 2 ;;
    --no-tls) ENABLE_TLS=0; shift ;;
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

# Log the operator in to the private image registry so the boot service can
# pull. Idempotent: skips when a credential is already present. The token can
# come from --registry-token-file, RINKDESK_REGISTRY_TOKEN/CR_PAT, or a prompt.
# It is piped over stdin, never passed on a command line.
ensure_registry_login() {
  local host token user env_args=()
  host="$(registry_host)"

  if run_as_operator bash "$ROOT/start.sh" --login --check >/dev/null 2>&1; then
    say "${GREEN}already${RESET} logged in to ${host}"
    return 0
  fi

  if [[ -n "$REGISTRY_TOKEN_FILE" ]]; then
    [[ -r "$REGISTRY_TOKEN_FILE" ]] || die "cannot read token file: $REGISTRY_TOKEN_FILE"
    token="$(tr -d '\r\n' <"$REGISTRY_TOKEN_FILE")"
  else
    token="${RINKDESK_REGISTRY_TOKEN:-${CR_PAT:-}}"
  fi
  if [[ -z "$token" && -t 0 ]]; then
    printf 'Registry token for %s (scope read:packages; blank to skip): ' "$host"
    IFS= read -r -s token || true
    printf '\n'
  fi
  if [[ -z "$token" ]]; then
    warn "not logged in to ${host}; pulling the private images will fail.
  As ${TARGET_USER}, run once:
    cd ${ROOT} && ./start.sh --login"
    return 0
  fi

  user="$REGISTRY_USER"
  [[ -n "$user" ]] || die "a registry username is required with the token:
  pass --registry-user USER (or set RINKDESK_REGISTRY_USER)"
  env_args=(env "RINKDESK_REGISTRY_USER=$user")

  say "${DIM}logging ${TARGET_USER} in to ${host}…${RESET}"
  if ! printf '%s' "$token" | run_as_operator "${env_args[@]}" bash "$ROOT/start.sh" --login; then
    die "registry login failed for ${TARGET_USER}"
  fi
  say "${GREEN}logged in${RESET} to ${host} as ${TARGET_USER}"
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

# --- Phase 1b: nginx reverse proxy + TLS -------------------------------------
# Reads scripts/admin/admin.env (sourced above) and applies
# scripts/admin/nginx-site.conf.template. Distro-aware: Debian-style
# sites-available, or conf.d for Fedora/RHEL/Arch.

install_nginx_pkgs() {
  if have nginx && have certbot; then
    say "${DIM}nginx and certbot already installed${RESET}"
    return 0
  fi
  say "${DIM}installing nginx + certbot…${RESET}"
  if have apt-get; then
    apt-get update -y
    apt-get install -y nginx certbot python3-certbot-nginx
  elif have dnf; then
    dnf install -y nginx certbot python3-certbot-nginx
  elif have yum; then
    yum install -y nginx certbot python3-certbot-nginx
  elif have pacman; then
    pacman -S --noconfirm nginx certbot certbot-nginx
  elif have zypper; then
    zypper --non-interactive install nginx certbot python3-certbot-nginx
  else
    die "unknown package manager — install nginx and certbot manually, then re-run"
  fi
}

write_nginx_site() {
  [[ -f "$NGINX_TEMPLATE" ]] || die "missing nginx template: $NGINX_TEMPLATE"
  local target
  if [[ -d /etc/nginx/sites-available ]]; then
    target=/etc/nginx/sites-available/rinkdesk.conf
  else
    target=/etc/nginx/conf.d/rinkdesk.conf
  fi
  sed -e "s/__DOMAIN__/${DOMAIN}/g" -e "s/__PORT__/${NGINX_PORT}/g" \
    "$NGINX_TEMPLATE" >"$target"
  if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sfn "$target" /etc/nginx/sites-enabled/rinkdesk.conf
  fi
  say "${GREEN}wrote${RESET} ${target}"
}

reload_nginx() {
  nginx -t || die "nginx config test failed"
  if have systemctl; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
  else
    nginx -s reload 2>/dev/null || nginx
  fi
}

open_firewall() {
  if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    say "${GREEN}opened${RESET} http/https in firewalld"
  fi
}

allow_selinux_proxy() {
  if have getenforce && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] && have setsebool; then
    if setsebool -P httpd_can_network_connect 1 2>/dev/null; then
      say "${GREEN}allowed${RESET} nginx to proxy (SELinux httpd_can_network_connect)"
    fi
  fi
}

setup_nginx() {
  say ""
  say "${BOLD}Phase 1b — nginx reverse proxy + TLS (as root)${RESET}"
  [[ -n "$DOMAIN" ]] || die "set RINKDESK_DOMAIN in scripts/admin/admin.env (or pass --domain)"
  install_nginx_pkgs
  write_nginx_site
  allow_selinux_proxy
  open_firewall
  reload_nginx
  if [[ "$ENABLE_TLS" == 1 ]]; then
    [[ -n "$TLS_EMAIL" ]] || die "set RINKDESK_TLS_EMAIL in scripts/admin/admin.env (or pass --email) for certbot"
    say "${DIM}obtaining TLS certificate for ${DOMAIN} (certbot)…${RESET}"
    if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
      -m "$TLS_EMAIL" --redirect --keep-until-expiring; then
      say "${GREEN}https://${DOMAIN}/${RESET} is live"
    else
      warn "certbot could not issue a certificate yet.
  Check that DNS for ${DOMAIN} points here, then run:
    sudo certbot --nginx -d ${DOMAIN} -m ${TLS_EMAIL} --agree-tos --redirect"
    fi
  else
    warn "TLS disabled — the site is HTTP-only on ${DOMAIN}"
  fi
}

install_prereqs
ensure_subids
setup_userns
install_homebrew
enable_linger
# Log in only when the desk will run here or a token was supplied.
if [[ "$INSTALL_SERVICE" == 1 || -n "$REGISTRY_TOKEN_FILE" ||
  -n "${RINKDESK_REGISTRY_TOKEN:-}${CR_PAT:-}" ]]; then
  ensure_registry_login
fi
if [[ "$INSTALL_NGINX" == 1 ]]; then setup_nginx; fi

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

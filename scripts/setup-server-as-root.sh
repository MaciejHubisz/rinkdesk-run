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
#   sudo scripts/setup-server-as-root.sh maciej --deploy-key
#                                                           # let GitHub CI deploy
#   sudo scripts/setup-server-as-root.sh maciej --deploy-key-file deploy.pub
#                                                           # ...from a key you have
#
# Three phases, clearly split by privilege:
#   Phase 1 (root):    prerequisites, Homebrew, subuid range, userns, a
#                      'rinkdesk' shell alias, lingering, an optional CI deploy key.
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

# --- Presentation -----------------------------------------------------------
# The setup is long and package managers are noisy. Each step prints one header
# and one result line; the command output only appears when a step fails.
STEP=0
step() {
  STEP=$((STEP + 1))
  say ""
  say "${BOLD}[${STEP}] $*${RESET}"
}
step_ok() { say "  ${GREEN}ok${RESET}  $*"; }
step_info() { say "  ${DIM}$*${RESET}"; }

# Run a command quietly, printing its output only when it fails. Set
# RINKDESK_SETUP_LOG to also keep the full output in a file.
run_quiet() {
  local log status=0
  log="$(mktemp)"
  "$@" >"$log" 2>&1 || status=$?
  if [[ "$status" -eq 0 ]]; then
    rm -f "$log"
    return 0
  fi
  warn "command failed: $*"
  sed 's/^/    /' "$log" >&2
  if [[ -n "${RINKDESK_SETUP_LOG:-}" ]]; then
    cat "$log" >>"$RINKDESK_SETUP_LOG"
  fi
  rm -f "$log"
  return "$status"
}

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
# Operator-owned registry credentials (written by ensure_registry_login).
REGISTRY_ENV="$ROOT/registry.env"

usage() {
  cat <<EOF
${BOLD}RinkDesk server setup${RESET} (run as root)

  sudo $0 [USER]                     prepare the server only (Phase 1)
  sudo $0 [USER] --install-service   prepare the server + run the desk on boot
  sudo $0 [USER] --install-nginx     also install nginx + TLS (Phase 1b)

  USER defaults to \$SUDO_USER.

  Phase 1 (root):  prerequisites, Homebrew, subuid range, user namespaces,
                   a 'rinkdesk' shell alias, and lingering for USER.
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

  Continuous deployment (GitHub Actions over SSH):
    --deploy-key                generate a key pair here, authorize the public
                                half, and print the private half once for the
                                DEPLOY_SSH_KEY secret
    --deploy-key-file FILE      authorize an SSH public key you already have
    --deploy-key-options OPTS   authorized_keys options for the deploy key,
                                e.g. 'from="…",command="…"' (optional)
                                (see rinkdesk/docs/deploy.md)

  The images are private, so the operator logs in once. With --install-service
  the script logs in using the token from registry.env, the environment, or
  --registry-token-file; if none is present it asks for one and saves it to
  registry.env (mode 600). Re-running is safe — an existing login is left
  alone.

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
# Public key authorized for the operator so the Deploy workflow can SSH in.
DEPLOY_KEY_FILE="${RINKDESK_DEPLOY_KEY_FILE:-}"
# Generate a fresh key pair on the host instead of using a provided public key.
GENERATE_DEPLOY_KEY=0
# Extra authorized_keys options for the deploy key (e.g. from=,command=).
DEPLOY_KEY_OPTIONS="${RINKDESK_DEPLOY_KEY_OPTIONS:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help | help) usage; exit 0 ;;
    --install-service) INSTALL_SERVICE=1; shift ;;
    --install-nginx) INSTALL_NGINX=1; shift ;;
    --deploy-key) GENERATE_DEPLOY_KEY=1; shift ;;
    --deploy-key-options)
      [[ $# -ge 2 ]] || die "$1 needs options"
      DEPLOY_KEY_OPTIONS="$2"; shift 2 ;;
    --deploy-key-file)
      [[ $# -ge 2 ]] || die "$1 needs a path"
      DEPLOY_KEY_FILE="$2"; shift 2 ;;
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
# pull. Idempotent: skips when a credential is already present. The token comes
# from registry.env, the environment, or --registry-token-file; if none is
# found it prompts and saves the answer to registry.env for next time. The
# token is always piped over stdin, never passed on a command line.
ensure_registry_login() {
  local host token user env_args=() prompted=0
  host="$(registry_host)"
  user="$REGISTRY_USER"
  step "Private image registry (${host})"

  if run_as_operator bash "$ROOT/start.sh" --login --check >/dev/null 2>&1; then
    step_ok "already logged in as ${TARGET_USER}"
    return 0
  fi

  if [[ -n "$REGISTRY_TOKEN_FILE" ]]; then
    [[ -r "$REGISTRY_TOKEN_FILE" ]] || die "cannot read token file: $REGISTRY_TOKEN_FILE"
    token="$(tr -d '\r\n' <"$REGISTRY_TOKEN_FILE")"
  else
    token="${RINKDESK_REGISTRY_TOKEN:-${CR_PAT:-}}"
    # Ignore the untouched placeholder from registry.env.example.
    [[ "$token" == "ghp_replace_me" ]] && token=""
  fi

  if [[ -z "$token" ]]; then
    if [[ ! -t 0 ]]; then
      warn "not logged in to ${host} and no token available; skipping registry login"
      return 0
    fi
    say ""
    say "  Create a token with the read:packages scope:"
    say "    ${BOLD}https://github.com/settings/tokens/new?scopes=read:packages${RESET}"
    say ""
    [[ -n "$user" ]] || user="$(registry_owner)"
    local answer=""
    printf '  GitHub username [%s]: ' "$user"
    IFS= read -r answer || true
    user="${answer:-$user}"
    printf '  GitHub token (read:packages): '
    IFS= read -r -s token || true
    printf '\n'
    if [[ -z "$token" ]]; then
      warn "no token entered; skipping registry login.
  Re-run this script when you have one, or run as ${TARGET_USER}:
    cd ${ROOT} && ./start.sh --login"
      return 0
    fi
    prompted=1
  fi

  [[ -n "$user" ]] || die "a registry username is required with the token:
  pass --registry-user USER (or set RINKDESK_REGISTRY_USER)"
  env_args=(env "RINKDESK_REGISTRY_USER=$user")

  local log
  log="$(mktemp)"
  if ! printf '%s' "$token" | run_as_operator "${env_args[@]}" bash "$ROOT/start.sh" --login >"$log" 2>&1; then
    warn "registry login failed; output:"
    sed 's/^/    /' "$log" >&2
    rm -f "$log"
    die "registry login failed for ${TARGET_USER}.
  Check that the token has the read:packages scope and was pasted without
  whitespace, then try again."
  fi
  rm -f "$log"
  step_ok "logged in as ${user}"

  # Save the credential so start.sh --start/--update log in on their own.
  if [[ "$prompted" == 1 || ! -f "$REGISTRY_ENV" ]]; then
    {
      printf '# Written by setup-server-as-root.sh. Keep it private (chmod 600).\n'
      printf 'RINKDESK_REGISTRY_USER=%s\n' "$user"
      printf 'RINKDESK_REGISTRY_TOKEN=%s\n' "$token"
    } >"$REGISTRY_ENV"
    chown "$TARGET_USER" "$REGISTRY_ENV"
    chmod 600 "$REGISTRY_ENV"
    step_ok "saved ${REGISTRY_ENV} (mode 600, ${TARGET_USER})"
  fi
}

say "${BOLD}RinkDesk server setup${RESET}  ${DIM}(run as root)${RESET}"
say "  operator : ${BOLD}${TARGET_USER}${RESET}"
say "  host     : $(hostname)"
say "  root     : ${ROOT}"

install_prereqs() {
  step "Prerequisites (build tools, curl, file, git, python3, uidmap, fuse3)"
  if have apt-get; then
    run_quiet apt-get update -y || die "apt-get update failed"
    run_quiet apt-get install -y build-essential procps curl file git python3 uidmap fuse3 ||
      die "installing prerequisites failed"
  elif have dnf; then
    run_quiet dnf install -y @development-tools procps-ng curl file git python3 shadow-utils fuse3 ||
      die "installing prerequisites failed"
  elif have yum; then
    run_quiet yum install -y gcc gcc-c++ make procps-ng curl file git python3 shadow-utils fuse3 ||
      die "installing prerequisites failed"
  elif have pacman; then
    run_quiet pacman -S --noconfirm base-devel procps-ng curl file git python3 shadow fuse3 ||
      die "installing prerequisites failed"
  elif have zypper; then
    run_quiet zypper --non-interactive install -t pattern devel_basis ||
      die "installing prerequisites failed"
    run_quiet zypper --non-interactive install procps curl file git python3 shadow fuse3 ||
      die "installing prerequisites failed"
  else
    warn "unknown package manager — install build tools, curl, file, git, python3, uidmap, fuse3 manually"
    return 0
  fi
  step_ok "installed"
}

# Rootless containers need a subordinate UID/GID range for the operator.
ensure_subids() {
  step "Subordinate UID/GID range for ${TARGET_USER}"
  if grep -qE "^(${TARGET_USER}|$(id -u "$TARGET_USER")):" /etc/subuid 2>/dev/null &&
    grep -qE "^(${TARGET_USER}|$(id -u "$TARGET_USER")):" /etc/subgid 2>/dev/null; then
    step_ok "already configured"
    return 0
  fi
  if have usermod; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$TARGET_USER" &&
      step_ok "added 100000-165535"
  else
    warn "no subuid/subgid range for ${TARGET_USER}; rootless Podman may fail"
  fi
}

# Ubuntu restricts unprivileged user namespaces with AppArmor, which breaks
# rootless Podman. Grant it for the Homebrew Podman binary (fall back to
# relaxing the sysctl if the profile cannot be loaded).
setup_userns() {
  step "Unprivileged user namespaces (Ubuntu AppArmor)"
  local sysctl=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  if [[ ! -e "$sysctl" || "$(cat "$sysctl" 2>/dev/null)" != 1 ]]; then
    step_ok "not restricted"
    return 0
  fi
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
    step_ok "allowed Homebrew Podman via AppArmor"
    return 0
  fi
  warn "could not load the AppArmor profile — relaxing the userns sysctl instead"
  printf 'kernel.apparmor_restrict_unprivileged_userns=0\n' \
    >/etc/sysctl.d/99-rinkdesk-userns.conf
  have sysctl && sysctl --system >/dev/null 2>&1 || true
  step_ok "relaxed kernel.apparmor_restrict_unprivileged_userns"
}

# Install Homebrew into the supported prefix (owned by the operator) without
# sudo, then make the shell pick it up on the next login.
install_homebrew() {
  step "Homebrew (${BREW_PREFIX})"
  mkdir -p "$(dirname "$BREW_PREFIX")"
  chown "$TARGET_USER" "$(dirname "$BREW_PREFIX")"
  if [[ -x "$BREW_PREFIX/bin/brew" ]]; then
    step_ok "already installed"
  else
    step_info "cloning Homebrew…"
    mkdir -p "$BREW_PREFIX"
    chown "$TARGET_USER" "$BREW_PREFIX"
    as_user git clone --depth=1 https://github.com/Homebrew/brew "$BREW_PREFIX/Homebrew" ||
      die "could not clone Homebrew into ${BREW_PREFIX}"
    as_user mkdir -p "$BREW_PREFIX/bin"
    as_user ln -sfn ../Homebrew/bin/brew "$BREW_PREFIX/bin/brew"
    step_ok "installed"
  fi

  local rc="$TARGET_HOME/.bashrc"
  if grep -qs 'linuxbrew/bin/brew shellenv' "$rc" 2>/dev/null; then
    step_ok "shell environment already in ${rc}"
  else
    {
      printf '\n# Homebrew (RinkDesk host setup)\n'
      printf 'eval "$(%s/bin/brew shellenv)"\n' "$BREW_PREFIX"
    } >>"$rc"
    chown "$TARGET_USER" "$rc"
    step_ok "shell environment added to ${rc}"
  fi
}

# Add a `rinkdesk` alias to the operator's shell so the desk is one word away
# from anywhere on the host. The alias is just this checkout's start.sh, so it
# takes the same flags (rinkdesk --update, rinkdesk --status, …).
install_alias() {
  step "'rinkdesk' shell alias"
  local rc="$TARGET_HOME/.bashrc"
  local alias_line
  alias_line="$(printf 'alias rinkdesk=%q' "$ROOT/start.sh")"
  if grep -qs 'alias rinkdesk=' "$rc" 2>/dev/null; then
    step_ok "already present in ${rc}"
  else
    {
      printf '\n# RinkDesk (host setup)\n'
      printf '%s\n' "$alias_line"
    } >>"$rc"
    chown "$TARGET_USER" "$rc"
    step_ok "added to ${rc}"
  fi
  step_info "${alias_line}"
}

# Let the operator's systemd user manager keep running after logout, so the
# user-level RinkDesk service survives an SSH session ending.
enable_linger() {
  step "Lingering for ${TARGET_USER}"
  if ! have loginctl; then
    step_info "loginctl not available; skipped"
    return 0
  fi
  if loginctl enable-linger "$TARGET_USER" >/dev/null 2>&1; then
    step_ok "user service keeps running after logout"
  else
    warn "could not enable-linger; the user service may stop at logout"
  fi
}

# Authorize a public key so the Deploy GitHub Actions job can SSH in as the
# operator and run ./start.sh --update. Returns 0 when the key was added, 1 when
# it was already there. The private half belongs in the GitHub secret store.
authorize_deploy_key() {
  local key="$1" dir auth line
  dir="$TARGET_HOME/.ssh"
  auth="$dir/authorized_keys"
  line="$key"
  [[ -n "$DEPLOY_KEY_OPTIONS" ]] && line="$DEPLOY_KEY_OPTIONS $key"
  mkdir -p "$dir"
  touch "$auth"
  chown "$TARGET_USER" "$dir" "$auth"
  chmod 700 "$dir"
  chmod 600 "$auth"
  if grep -qF "$key" "$auth" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$line" >>"$auth"
  return 0
}

# Authorize a public key file the admin already has (e.g. generated on their
# laptop). See rinkdesk/docs/deploy.md.
install_deploy_key_file() {
  step "Deploy key for ${TARGET_USER}"
  [[ -r "$DEPLOY_KEY_FILE" ]] || die "cannot read deploy key file: $DEPLOY_KEY_FILE"
  local key
  key="$(tr -d '\r' <"$DEPLOY_KEY_FILE")"
  case "$key" in
    ssh-ed25519\ * | ssh-rsa\ * | ecdsa-sha2-*\ *) ;;
    *) die "$DEPLOY_KEY_FILE does not look like an SSH public key" ;;
  esac
  if authorize_deploy_key "$key"; then
    step_ok "authorized in ${TARGET_HOME}/.ssh/authorized_keys"
  else
    step_ok "already authorized in ${TARGET_HOME}/.ssh/authorized_keys"
  fi
}

# Generate a fresh deploy key on the host, authorize the public half, and print
# the private half once for the DEPLOY_SSH_KEY secret. Nothing private is kept
# on the host: the file is deleted before the step ends.
generate_deploy_key() {
  step "Deploy key for ${TARGET_USER}"
  have ssh-keygen || die "ssh-keygen is required to generate a deploy key"
  local auth="$TARGET_HOME/.ssh/authorized_keys" tmp pub
  # Idempotent: a re-run (e.g. to fix nginx) must not add a second key or print
  # a new private key. The private half only lives in the GitHub secret.
  if [[ -f "$auth" ]] && grep -q ' github-actions$' "$auth"; then
    step_ok "a deploy key is already authorized"
    step_info "remove that line and re-run to issue a new one"
    return 0
  fi
  tmp="$(mktemp -d)"
  chmod 700 "$tmp"
  ssh-keygen -q -t ed25519 -N '' -C 'github-actions' -f "$tmp/rinkdesk-deploy"
  pub="$(cat "$tmp/rinkdesk-deploy.pub")"
  authorize_deploy_key "$pub" || true
  step_ok "generated and authorized"
  say ""
  say "${BOLD}Copy the private key below into the GitHub secret DEPLOY_SSH_KEY${RESET}"
  say "${DIM}(Settings → Secrets and variables → Actions). It is shown once and"
  say "is not stored on this host.${RESET}"
  say ""
  cat "$tmp/rinkdesk-deploy"
  say ""
  rm -rf "$tmp"
}

# --- Phase 1b: nginx reverse proxy + TLS -------------------------------------
# Reads scripts/admin/admin.env (sourced above) and applies
# scripts/admin/nginx-site.conf.template. Distro-aware: Debian-style
# sites-available, or conf.d for Fedora/RHEL/Arch.

install_nginx_pkgs() {
  step "nginx + certbot"
  if have nginx && have certbot; then
    step_ok "already installed"
    return 0
  fi
  if have apt-get; then
    run_quiet apt-get update -y || die "apt-get update failed"
    run_quiet apt-get install -y nginx certbot python3-certbot-nginx ||
      die "installing nginx and certbot failed"
  elif have dnf; then
    run_quiet dnf install -y nginx certbot python3-certbot-nginx ||
      die "installing nginx and certbot failed"
  elif have yum; then
    run_quiet yum install -y nginx certbot python3-certbot-nginx ||
      die "installing nginx and certbot failed"
  elif have pacman; then
    run_quiet pacman -S --noconfirm nginx certbot certbot-nginx ||
      die "installing nginx and certbot failed"
  elif have zypper; then
    run_quiet zypper --non-interactive install nginx certbot python3-certbot-nginx ||
      die "installing nginx and certbot failed"
  else
    die "unknown package manager — install nginx and certbot manually, then re-run"
  fi
  step_ok "installed"
}

write_nginx_site() {
  step "nginx site for ${DOMAIN}:${NGINX_PORT}"
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
  step_ok "wrote ${target}"
}

reload_nginx() {
  step "Reload nginx"
  if ! nginx -t >/dev/null 2>&1; then
    nginx -t
    die "nginx config test failed"
  fi
  if have systemctl; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
  else
    nginx -s reload 2>/dev/null || nginx
  fi
  step_ok "reloaded"
}

open_firewall() {
  step "Firewall"
  if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    step_ok "opened http/https in firewalld"
  else
    step_info "firewalld not active; skipped"
  fi
}

allow_selinux_proxy() {
  step "SELinux proxy permission"
  if have getenforce && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] && have setsebool; then
    if setsebool -P httpd_can_network_connect 1 2>/dev/null; then
      step_ok "allowed nginx to proxy (httpd_can_network_connect)"
      return 0
    fi
    warn "could not set httpd_can_network_connect"
    return 0
  fi
  step_info "not enforcing; skipped"
}

setup_nginx() {
  say ""
  say "${BOLD}nginx reverse proxy + TLS${RESET}"
  [[ -n "$DOMAIN" ]] || die "set RINKDESK_DOMAIN in scripts/admin/admin.env (or pass --domain)"
  install_nginx_pkgs
  write_nginx_site
  allow_selinux_proxy
  open_firewall
  reload_nginx
  step "TLS certificate for ${DOMAIN} (certbot)"
  if [[ "$ENABLE_TLS" != 1 ]]; then
    step_info "disabled — HTTP-only"
    return 0
  fi
  [[ -n "$TLS_EMAIL" ]] || die "set RINKDESK_TLS_EMAIL in scripts/admin/admin.env (or pass --email) for certbot"
  local log
  log="$(mktemp)"
  if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
    -m "$TLS_EMAIL" --redirect --keep-until-expiring >"$log" 2>&1; then
    rm -f "$log"
    step_ok "https://${DOMAIN}/ is live"
    return 0
  fi
  sed 's/^/    /' "$log" >&2
  rm -f "$log"
  warn "certbot could not issue a certificate yet.
  Check that DNS for ${DOMAIN} points here, then run:
    sudo certbot --nginx -d ${DOMAIN} -m ${TLS_EMAIL} --agree-tos --redirect"
}

install_prereqs
ensure_subids
setup_userns
install_homebrew
install_alias
enable_linger
if [[ "$GENERATE_DEPLOY_KEY" == 1 ]]; then
  generate_deploy_key
elif [[ -n "$DEPLOY_KEY_FILE" ]]; then
  install_deploy_key_file
fi
# Log in only when the desk will run here or a real token was supplied.
registry_token="${RINKDESK_REGISTRY_TOKEN:-${CR_PAT:-}}"
[[ "$registry_token" == "ghp_replace_me" ]] && registry_token=""
if [[ "$INSTALL_SERVICE" == 1 || -n "$REGISTRY_TOKEN_FILE" || -n "$registry_token" ]]; then
  ensure_registry_login
fi
if [[ "$INSTALL_NGINX" == 1 ]]; then setup_nginx; fi

say ""
say "${GREEN}Server ready.${RESET}"
say ""
say "  ${BOLD}rinkdesk${RESET}  ->  ${ROOT}/start.sh"
say "  ${DIM}Alias written to ${TARGET_HOME}/.bashrc — open a new shell, or run: source ~/.bashrc${RESET}"

# Phase 2: install the boot service as the operator (never as root), so the
# unit is a user unit that lives in the operator's systemd manager.
install_service() {
  step "Boot service (systemd user unit for ${TARGET_USER})"
  if ! run_as_operator bash "$ROOT/start.sh" --install-service; then
    die "could not install the service as ${TARGET_USER}.
  Log in and run it yourself:
    cd ${ROOT} && ./start.sh --install-service"
  fi
  if run_as_operator systemctl --user is-enabled rinkdesk >/dev/null 2>&1; then
    step_ok "rinkdesk.service enabled — starts on every boot"
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
  say ""
  say "${BOLD}Next — install the boot service as ${TARGET_USER} (no sudo)${RESET}"
  say "  ssh ${TARGET_USER}@$(hostname)"
  say "  cd ${ROOT} && ./start.sh --install-service"
  say "  ${DIM}or re-run this script with --install-service${RESET}"
fi

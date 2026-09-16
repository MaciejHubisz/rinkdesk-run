#!/usr/bin/env bash
# RinkDesk — pull images and run. This is the only start.sh.
#
#   ./start.sh --start
#   ./start.sh --stop
#   ./start.sh --update
#   ./start.sh --force-recreate
#   ./start.sh --start --force-pull
#   ./start.sh --start --export-path /path/to/folder
#   ./start.sh --start --protocols-path /path/to/folder
#
# If a sibling ../rinkdesk source tree is on disk (or RINKDESK_SRC),
# --start, --update and --force-recreate run that repo's ./build.sh
# (build only) first, then run those local images. A machine that only
# has this repo pulls the images published by CI instead.
#
# Linux only. Designed to run unattended over SSH (see --yes, --install-service).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$ROOT/scripts/lib/platform.sh"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
# shellcheck source=scripts/lib/engine.sh
source "$ROOT/scripts/lib/engine.sh"
# shellcheck source=scripts/lib/registry.sh
source "$ROOT/scripts/lib/registry.sh"

load_env "$ROOT/release.env" "$ROOT/.env" "$ROOT/registry.env"

CMD=help
OPEN=1
RECREATE=0
SKIP_BUILD="${RINKDESK_SKIP_BUILD:-0}"
FORCE_PULL="${RINKDESK_FORCE_PULL:-0}"
FORCE_UP="${RINKDESK_FORCE_UP:-0}"
EXPORT_PATH="${RINKDESK_EXPORTS_PATH:-}"
PROTOCOLS_PATH="${RINKDESK_PROTOCOLS_PATH:-}"
LOG_ARGS=()
SERVICE_NAME="rinkdesk"
# --check with --login: report whether a registry credential exists, no side effects.
LOGIN_CHECK=0
# Set to 1 when build.sh built fresh images on this machine; they are then
# used as-is and the registry is not pulled (a pull would overwrite them).
BUILT_LOCAL=0

# Source tree = app + build.sh. Others clone only this repo, so this is empty.
find_source_tree() {
  local cand
  if [[ -n "${RINKDESK_SRC:-}" ]]; then
    cand="${RINKDESK_SRC}"
    if [[ -x "$cand/build.sh" && -d "$cand/app/backend" ]]; then
      (cd "$cand" && pwd)
      return 0
    fi
    die "RINKDESK_SRC=$cand is not a RinkDesk source tree (need build.sh and app/backend)"
  fi
  cand="$(cd "$ROOT/.." && pwd)/rinkdesk"
  if [[ -x "$cand/build.sh" && -d "$cand/app/backend" ]]; then
    printf '%s\n' "$cand"
    return 0
  fi
  return 1
}

# Build fresh images from the source repo. build.sh never pushes; the local
# images are used directly by cmd_start.
maybe_build_from_source() {
  local src
  [[ "$SKIP_BUILD" == 1 ]] && return 0
  src="$(find_source_tree)" || return 0
  say "${BOLD}source${RESET}  ${src}"
  say "Building images locally…"
  # .env sets RINKDESK_IMAGE_TAG=latest for running. Do not leak that into the
  # build, or build.sh would only tag :latest and leave the version tag stale.
  # Without it build.sh tags both VERSION and :latest.
  env -u RINKDESK_IMAGE_TAG bash "$src/build.sh"
  BUILT_LOCAL=1
}

print_usage() {
  local src=""
  src="$(find_source_tree 2>/dev/null || true)"
  cat <<EOF
${BOLD}RinkDesk${RESET} ${APP_VERSION}  rink-clerk desk

  ${GREEN}./start.sh --start${RESET}             start or resume, applying newer images (keep data)
  ${GREEN}./start.sh --force-recreate${RESET}    wipe database, rebuild or pull, start empty
  ${GREEN}./start.sh --update${RESET}            rebuild or pull, recreate app, keep data
  ${GREEN}./start.sh --status${RESET}            show container status
  ${GREEN}./start.sh --login${RESET}             log in to the image registry (private images)
  ${GREEN}./start.sh --logs [SERVICE]${RESET}    follow logs (backend/web/db, all by default)
  ${GREEN}./start.sh --stop${RESET}              stop (data kept)
  ${GREEN}./start.sh --manual${RESET}            how the desk works
  ${GREEN}./start.sh --install-service${RESET}   run on boot via systemd, start now
  ${GREEN}./start.sh --uninstall-service${RESET} remove the systemd unit

  -p, --port PORT                UI port (default ${PORT})
      --export-path DIR          bind snapshot exports to a local folder
      --protocols-path DIR       bind generated protocol PDFs to a local folder
      --paths                    show where JSON, protocols, and logos live
      --force-pull               skip local build; pull from ghcr (fail if pull fails)
      --no-self-update           do not git-pull this checkout before start/update
EOF
  if [[ -n "$src" ]]; then
    cat <<EOF
      --no-build                 skip source build
EOF
  fi
  cat <<EOF
  -y, --yes                      assume yes for prompts (unattended SSH)
  -n, --no-open                  do not open a browser
  -V, --version
  -h, --help
EOF
  if [[ -n "$src" ]]; then
    cat <<EOF
  Source:   ${src}
            --start, --update and --force-recreate build from it first.
EOF
  else
    cat <<EOF
  Images:   pulled, never built here.
EOF
  fi
}

# Named data volumes owned by this stack (see docker-compose.yml).
DATA_VOLUMES=(rinkdesk-pg rinkdesk-exports)
# Image used to empty a volume in place. Same image the stack already runs, so
# it is normally already present.
WIPE_IMAGE="${RINKDESK_WIPE_IMAGE:-docker.io/library/postgres:16-alpine}"

# Empty one named volume without removing it. Needed when a leftover container
# from another project still references the volume: podman/docker then refuse to
# remove it, but mounting it read-write is still allowed.
empty_volume() {
  local vol="$1"
  "$ENGINE" image inspect "$WIPE_IMAGE" >/dev/null 2>&1 ||
    "$ENGINE" pull "$WIPE_IMAGE" >/dev/null 2>&1 || true
  # shellcheck disable=SC2016  # $(ls) must run inside the container, not here.
  "$ENGINE" run --rm -v "${vol}:/wipe${RINKDESK_VOL_OPTS}" "$WIPE_IMAGE" \
    sh -c 'rm -rf /wipe/* /wipe/.[!.]* /wipe/..?*; [ -z "$(ls -A /wipe 2>/dev/null)" ]' \
    >/dev/null 2>&1
}

# Wipe every trace of application data so the desk starts empty: the Postgres
# database, the JSON snapshot volume, generated protocol PDFs, and a
# --export-path host folder when one is in use. Shipped team logos are kept —
# they are app defaults, not tournament data.
wipe_data() {
  local vol proto
  say "Wiping volumes…"
  compose down --remove-orphans -v >/dev/null 2>&1 || true
  "$ENGINE" volume rm -f "${DATA_VOLUMES[@]}" >/dev/null 2>&1 || true
  for vol in "${DATA_VOLUMES[@]}"; do
    if "$ENGINE" volume inspect "$vol" >/dev/null 2>&1; then
      empty_volume "$vol" ||
        die "could not empty volume $vol — stop any other stack using it and retry"
    fi
  done
  if [[ -n "${RINKDESK_EXPORTS_SOURCE:-}" && -d "${RINKDESK_EXPORTS_SOURCE}" ]]; then
    rm -rf "${RINKDESK_EXPORTS_SOURCE:?}/archive" 2>/dev/null || true
    find "$RINKDESK_EXPORTS_SOURCE" -maxdepth 1 -type f -name '*.json' -delete 2>/dev/null || true
  fi
  proto="${RINKDESK_PROTOCOLS_SOURCE:-$ROOT/protocols}"
  if [[ -d "$proto" ]]; then
    find "$proto" -mindepth 1 -delete 2>/dev/null || true
  fi
}

cmd_start() {
  local open_it="$1" recreate="$2"
  ensure_runtime
  [[ -n "$EXPORT_PATH" ]] && apply_export_path "$EXPORT_PATH"
  [[ -n "$PROTOCOLS_PATH" ]] && apply_protocols_path "$PROTOCOLS_PATH"
  maybe_build_from_source
  cd "$ROOT"
  load_env "$ROOT/.env"
  APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || printf '1.0.0')"
  export RINKDESK_PORT="$PORT"
  export RINKDESK_IMAGE_TAG="${RINKDESK_IMAGE_TAG:-latest}"

  local prefix tag before_backend before_web after_backend after_web image_changed=0
  prefix="${RINKDESK_IMAGE_PREFIX:-ghcr.io/maciejhubisz/rinkdesk}"
  tag="${RINKDESK_IMAGE_TAG:-latest}"

  if [[ "$BUILT_LOCAL" == 1 ]]; then
    # Fresh images were just built here; pulling :latest would replace them
    # with the last CI build. Recreate so the containers use the new images.
    image_changed=1
    say "${DIM}Using locally built ${prefix}-{backend,web}:${tag}${RESET}"
  else
    before_backend="$(image_id "${prefix}-backend:${tag}")"
    before_web="$(image_id "${prefix}-web:${tag}")"

    # registry.env (or the environment) can carry a read token; use it once so
    # the pull works without a separate --login.
    if [[ -n "${RINKDESK_REGISTRY_TOKEN:-}${CR_PAT:-}" ]] && ! registry_logged_in; then
      say "${DIM}Logging in to $(registry_host)…${RESET}"
      registry_login >/dev/null || warn "registry login failed — continuing"
    fi

    say "${DIM}Pulling images…${RESET}"
    # Pull through the engine, not `compose pull`: podman-compose skips a tag
    # that already exists locally, so a moved :latest never reaches the host.
    # `podman/docker pull` always re-checks the registry and updates the tag.
    local pull_failed=0
    "$ENGINE" pull "${prefix}-backend:${tag}" || pull_failed=1
    "$ENGINE" pull "${prefix}-web:${tag}" || pull_failed=1
    if [[ "$pull_failed" == 1 ]]; then
      if [[ "$FORCE_PULL" == 1 ]]; then
        die "could not pull images from the registry (--force-pull)"
      fi
      say "${YELLOW}Warning: could not pull images — starting local images if present.${RESET}"
      say "${DIM}  The desk may be stale. Check network and registry login (docker login ghcr.io).${RESET}"
    fi

    # A re-pull can move :latest without the running containers noticing:
    # podman-compose does not recreate a container just because its tag moved.
    # Compare the image ids so --start actually applies a newer build.
    after_backend="$(image_id "${prefix}-backend:${tag}")"
    after_web="$(image_id "${prefix}-web:${tag}")"
    if [[ "$before_backend" != "$after_backend" || "$before_web" != "$after_web" ]]; then
      image_changed=1
    fi
  fi

  if [[ "$recreate" == 1 ]]; then
    # podman-compose's `down -v` only removes volumes labelled with the current
    # compose project, and a volume shared with a leftover container from
    # another project cannot be removed at all. wipe_data() guarantees the data
    # is gone either way, so the desk really starts empty.
    wipe_data
    compose up --force-recreate --no-build -d
  elif [[ "$FORCE_UP" == 1 || "$image_changed" == 1 ]]; then
    if [[ "$image_changed" == 1 ]]; then
      say "${DIM}New images — recreating app containers.${RESET}"
    fi
    # Recreate only the stateless app services; the Postgres volume is kept.
    compose up --force-recreate --no-build -d backend web
  else
    compose up --no-build -d
  fi

  if ! wait_until_up; then
    compose logs --tail 40
    die "desk did not start on ${URL}"
  fi
  printf '%s\n' "${BOLD}RinkDesk${RESET} ${APP_VERSION}  ${GREEN}up${RESET}  ${BOLD}${URL}${RESET}"
  say "${DIM}  Live page    → ${URL}live/   (read-only)${RESET}"
  [[ "$recreate" == 1 ]] && say "Empty desk (database wiped)."
  print_paths
  if [[ "$open_it" == 1 ]]; then open_browser "$URL"; fi
}

# Show the effective + default locations of the JSON snapshots, generated
# protocol PDFs, and team logos. *_SOURCE vars are set by apply_* only when a
# --export-path / --protocols-path override is in effect; otherwise the
# docker-compose default applies.
print_paths() {
  local json protocols logos
  if [[ -n "${RINKDESK_EXPORTS_SOURCE:-}" ]]; then
    json="host    ${RINKDESK_EXPORTS_SOURCE}   (--export-path)"
  else
    json="volume  rinkdesk-exports   (default, not a host folder)"
  fi
  if [[ -n "${RINKDESK_PROTOCOLS_SOURCE:-}" ]]; then
    protocols="host    ${RINKDESK_PROTOCOLS_SOURCE}   (--protocols-path)"
  else
    protocols="host    ${ROOT}/protocols   (default)"
  fi
  logos="${ROOT}/team-logos"
  say "${DIM}  JSON exports → ${json}${RESET}"
  say "${DIM}  Protocols    → ${protocols}${RESET}"
  say "${DIM}  Team logos   → host    ${logos}${RESET}"
}

cmd_paths() {
  [[ -n "$EXPORT_PATH" ]] && apply_export_path "$EXPORT_PATH"
  [[ -n "$PROTOCOLS_PATH" ]] && apply_protocols_path "$PROTOCOLS_PATH"
  print_paths
}

cmd_stop() {
  ensure_runtime
  cd "$ROOT"
  compose down --remove-orphans >/dev/null 2>&1 || true
  say "Stopped RinkDesk ${APP_VERSION} on ${URL}"
}

cmd_status() {
  ensure_runtime
  cd "$ROOT"
  load_env "$ROOT/.env"
  compose ps
}

# Log in to the registry so a private package can be pulled. Reads the token
# from RINKDESK_REGISTRY_TOKEN (or CR_PAT) or from stdin; without one it
# prompts. Idempotent: skips when already logged in.
cmd_login() {
  local host token
  host="$(registry_host)"
  if [[ "$LOGIN_CHECK" == 1 ]]; then
    registry_logged_in
    return $?
  fi
  ensure_runtime
  token="${RINKDESK_REGISTRY_TOKEN:-${CR_PAT:-}}"
  if [[ -z "$token" && ! -t 0 ]]; then
    IFS= read -r token || true
  fi
  if [[ -z "$token" ]]; then
    if registry_logged_in; then
      say "${DIM}already logged in to ${host}${RESET}"
      return 0
    fi
    [[ -t 0 ]] || die "not logged in to ${host} and no token on stdin"
  else
    export RINKDESK_REGISTRY_TOKEN="$token"
  fi
  say "${BOLD}Logging in to ${host}${RESET}"
  registry_login
  say "${GREEN}logged in to ${host}${RESET}"
}

cmd_logs() {
  ensure_runtime
  cd "$ROOT"
  compose logs -f --tail=200 "${LOG_ARGS[@]}"
}

# Rebuild from the local source tree (when present) or pull newer images, then
# recreate the app containers without touching the database. This is the same
# as --force-recreate except the data is kept.
cmd_update() {
  FORCE_UP=1
  cmd_start "$1" 0
}

# Pull this run repo before starting, so an updated start.sh / compose file takes
# effect without a manual `git pull`. Fast-forward only and re-exec once. Soft-
# fails when offline or dirty. Disable with RINKDESK_NO_SELF_UPDATE=1.
self_update() {
  [[ "${RINKDESK_NO_SELF_UPDATE:-0}" == 1 ]] && return 0
  # Guard against a re-exec loop: only the first process may pull.
  [[ "${RINKDESK_SELF_UPDATED:-0}" == 1 ]] && return 0
  # A machine with the source tree builds locally and owns its own git; only a
  # run-only host (no sibling source) auto-updates the checkout.
  [[ -x "$ROOT/../rinkdesk/build.sh" ]] && return 0
  [[ -d "$ROOT/.git" ]] || return 0
  have git || return 0
  # No tracking branch (detached HEAD, tarball clone) → nothing to update from.
  git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || return 0
  say "${DIM}Checking for run-repo updates…${RESET}"
  if ! git -C "$ROOT" fetch --quiet 2>/dev/null; then
    warn "could not reach the git remote — using the current checkout"
    return 0
  fi
  local local_rev remote_rev
  local_rev="$(git -C "$ROOT" rev-parse '@')"
  remote_rev="$(git -C "$ROOT" rev-parse '@{u}')"
  [[ "$local_rev" == "$remote_rev" ]] && return 0
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    warn "local changes in $ROOT — skipping self-update (commit or stash them)"
    return 0
  fi
  say "${BOLD}Updating run repo${RESET} ${local_rev:0:7} → ${remote_rev:0:7}"
  if ! git -C "$ROOT" merge --ff-only --quiet '@{u}' 2>/dev/null; then
    warn "could not fast-forward — run git pull by hand"
    return 0
  fi
  export RINKDESK_SELF_UPDATED=1
  exec "$ROOT/start.sh" "${ORIG_ARGS[@]}"
}

# Install a systemd unit so the desk starts on boot and keeps running after
# the SSH session ends. Root installs a system unit; a regular user installs
# a user unit (no sudo needed; requires lingering, which setup-server-as-root.sh sets).
cmd_install_service() {
  have systemctl || die "systemd is required for --install-service"
  ensure_runtime
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    install_system_unit
  else
    install_user_unit
  fi
}

install_system_unit() {
  say "${BOLD}Installing systemd unit${RESET} /etc/systemd/system/${SERVICE_NAME}.service"
  as_root tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=RinkDesk (rink-clerk desk)
Documentation=file://${ROOT}/README.md
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${ROOT}
User=root
Group=root
ExecStart=${ROOT}/start.sh --start --no-open
ExecStop=${ROOT}/start.sh --stop
TimeoutStartSec=0
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
  as_root systemctl daemon-reload
  as_root systemctl enable --now "${SERVICE_NAME}.service"
  say "${GREEN}${SERVICE_NAME}.service enabled and started${RESET}"
  say "${DIM}  systemctl status ${SERVICE_NAME}${RESET}"
  say "${DIM}  journalctl -u ${SERVICE_NAME} -f${RESET}"
}

install_user_unit() {
  local dir="$HOME/.config/systemd/user"
  mkdir -p "$dir" || die "cannot create $dir"
  say "${BOLD}Installing user systemd unit${RESET} ${dir}/${SERVICE_NAME}.service"
  cat >"$dir/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=RinkDesk (rink-clerk desk)
Documentation=file://${ROOT}/README.md
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${ROOT}
ExecStart=${ROOT}/start.sh --start --no-open
ExecStop=${ROOT}/start.sh --stop
TimeoutStartSec=0
TimeoutStopSec=120

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload || die "systemctl --user is not available in this session"
  systemctl --user enable --now "${SERVICE_NAME}.service"
  say "${GREEN}${SERVICE_NAME}.service enabled and started${RESET}"
  say "${DIM}  systemctl --user status ${SERVICE_NAME}${RESET}"
  say "${DIM}  journalctl --user -u ${SERVICE_NAME} -f${RESET}"
  say "${DIM}  (needs 'loginctl enable-linger $USER' to survive logout — setup-server-as-root.sh does it)${RESET}"
}

cmd_uninstall_service() {
  have systemctl || die "systemd is required for --uninstall-service"
  say "Stopping and removing ${SERVICE_NAME}.service…"
  if [[ -f "$HOME/.config/systemd/user/${SERVICE_NAME}.service" ]]; then
    systemctl --user disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/${SERVICE_NAME}.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] || sudo -n true >/dev/null 2>&1; then
    as_root systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    as_root rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    as_root systemctl daemon-reload
  fi
  say "${GREEN}${SERVICE_NAME}.service removed${RESET}"
}

# Keep the original argv so self_update can re-exec the script unchanged.
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p | --port)
      [[ $# -ge 2 ]] || die "$1 needs a port"
      PORT="$2"; refresh_url; shift 2 ;;
    -H | --host)
      [[ $# -ge 2 ]] || die "$1 needs a host"
      HOST="$2"; refresh_url; shift 2 ;;
    --export-path)
      [[ $# -ge 2 ]] || die "$1 needs a folder"
      EXPORT_PATH="$2"; shift 2 ;;
    --protocols-path)
      [[ $# -ge 2 ]] || die "$1 needs a folder"
      PROTOCOLS_PATH="$2"; shift 2 ;;
    --no-build) SKIP_BUILD=1; shift ;;
    --force-pull | --from-hub)
      FORCE_PULL=1
      SKIP_BUILD=1
      shift ;;
    --no-self-update) export RINKDESK_NO_SELF_UPDATE=1; shift ;;
    -y | --yes) export RINKDESK_ASSUME_YES=1; shift ;;
    -n | --no-open) OPEN=0; shift ;;
    --start | start) CMD=start; shift ;;
    --stop | stop) CMD=stop; shift ;;
    --force-recreate | --reset) CMD=start; RECREATE=1; shift ;;
    --update | update) CMD=update; shift ;;
    --status | status) CMD=status; shift ;;
    --login) CMD=login; shift ;;
    --check) LOGIN_CHECK=1; shift ;;
    --logs | logs) CMD=logs; shift ;;
    --install-service) CMD=install-service; shift ;;
    --uninstall-service) CMD=uninstall-service; shift ;;
    --paths | --where) CMD=paths; shift ;;
    --manual | --data | manual) CMD=manual; shift ;;
    -h | --help | help) CMD=help; shift ;;
    -V | --version) print_version; exit 0 ;;
    *)
      if [[ "$CMD" == logs && "$1" != -* ]]; then
        LOG_ARGS+=("$1"); shift
      else
        die "unknown argument: $1  (try: $0 --help)"
      fi
      ;;
  esac
done

[[ "$FORCE_PULL" == 1 ]] && SKIP_BUILD=1

# Refresh the run repo itself before start/update (see self_update).
case "$CMD" in
  start | update) self_update ;;
esac

case "$CMD" in
  help) print_usage ;;
  manual) cat "$ROOT/scripts/manual.txt" ;;
  start) cmd_start "$OPEN" "$RECREATE" ;;
  update) cmd_update "$OPEN" ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  login) cmd_login ;;
  logs) cmd_logs ;;
  install-service) cmd_install_service ;;
  uninstall-service) cmd_uninstall_service ;;
  paths) cmd_paths ;;
esac

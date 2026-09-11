#!/usr/bin/env bash
# RinkDesk — pull images and run. This is the only start.sh.
#
#   ./start.sh --start
#   ./start.sh --stop
#   ./start.sh --force-recreate
#   ./start.sh --start --force-pull
#   ./start.sh --start --export-path /path/to/folder
#   ./start.sh --start --protocols-path /path/to/folder
#
# If a sibling ../rinkdesk source tree is on disk (or RINKDESK_SRC),
# --start runs that repo's ./build.sh (build + publish) first, then
# pulls and runs here — same as a machine that only has this repo.
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

maybe_reexec_wsl "$@"
load_env "$ROOT/release.env" "$ROOT/.env"

CMD=help
OPEN=1
RECREATE=0
SKIP_BUILD="${RINKDESK_SKIP_BUILD:-0}"
FORCE_PULL="${RINKDESK_FORCE_PULL:-0}"
EXPORT_PATH="${RINKDESK_EXPORTS_PATH:-}"
PROTOCOLS_PATH="${RINKDESK_PROTOCOLS_PATH:-}"
LOG_ARGS=()
SERVICE_NAME="rinkdesk"

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

# Build + publish from the source repo, then this script pulls those images.
maybe_publish_from_source() {
  local src
  [[ "$SKIP_BUILD" == 1 ]] && return 0
  src="$(find_source_tree)" || return 0
  say "${BOLD}source${RESET}  ${src}"
  say "Building and publishing images…"
  bash "$src/build.sh"
}

print_usage() {
  local src=""
  src="$(find_source_tree 2>/dev/null || true)"
  cat <<EOF
${BOLD}RinkDesk${RESET} ${APP_VERSION}  rink-clerk desk

  ${GREEN}./start.sh --start${RESET}             start or resume (keep data)
  ${GREEN}./start.sh --force-recreate${RESET}    wipe database, pull, start empty
  ${GREEN}./start.sh --update${RESET}            pull newer images, keep data
  ${GREEN}./start.sh --status${RESET}            show container status
  ${GREEN}./start.sh --logs [SERVICE]${RESET}    follow logs (backend/web/db, all by default)
  ${GREEN}./start.sh --stop${RESET}              stop (data kept)
  ${GREEN}./start.sh --manual${RESET}            how the desk works
  ${GREEN}./start.sh --install-service${RESET}   run on boot via systemd, start now
  ${GREEN}./start.sh --uninstall-service${RESET} remove the systemd unit
  ${GREEN}./start-funnel.sh${RESET}             share the read-only live page on the internet
                                    (${URL}live/)

  -p, --port PORT                UI port (default ${PORT})
      --export-path DIR          bind snapshot exports to a local folder
      --protocols-path DIR       bind generated protocol PDFs to a local folder
      --paths                    show where JSON, protocols, and logos live
      --force-pull               skip local build; pull from hub (fail if pull fails)
EOF
  if [[ -n "$src" ]]; then
    cat <<EOF
      --no-build                 skip source build + publish
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
            --start builds and publishes, then pulls and runs.
EOF
  else
    cat <<EOF
  Images:   pulled, never built here.
EOF
  fi
}

cmd_start() {
  local open_it="$1" recreate="$2"
  ensure_runtime
  [[ -n "$EXPORT_PATH" ]] && apply_export_path "$EXPORT_PATH"
  [[ -n "$PROTOCOLS_PATH" ]] && apply_protocols_path "$PROTOCOLS_PATH"
  maybe_publish_from_source
  cd "$ROOT"
  load_env "$ROOT/.env"
  APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || printf '1.0.0')"
  export RINKDESK_PORT="$PORT"
  export RINKDESK_VERSION="$APP_VERSION"
  export RINKDESK_IMAGE_TAG="${RINKDESK_IMAGE_TAG:-$APP_VERSION}"
  RINKDESK_RUN_COMMIT="$(git_commit)"
  export RINKDESK_RUN_COMMIT

  say "${DIM}Pulling images…${RESET}"
  if [[ "$FORCE_PULL" == 1 ]]; then
    compose pull || die "could not pull images from the registry (--force-pull)"
  else
    compose pull || say "${DIM}pull failed — using local images if present${RESET}"
  fi

  if [[ "$recreate" == 1 ]]; then
    say "Wiping volumes…"
    compose down --remove-orphans -v >/dev/null 2>&1 || true
    compose up --force-recreate --no-build -d
  else
    compose up --no-build -d
  fi

  if ! wait_until_up; then
    compose logs --tail 40
    die "desk did not start on ${URL}"
  fi
  printf '%s\n' "${BOLD}RinkDesk${RESET} ${APP_VERSION}  ${GREEN}up${RESET}  ${BOLD}${URL}${RESET}"
  say "${DIM}  Live page    → ${URL}live/   (read-only; ./start-funnel.sh to share)${RESET}"
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

cmd_logs() {
  ensure_runtime
  cd "$ROOT"
  compose logs -f --tail=200 "${LOG_ARGS[@]}"
}

# Pull newer images and recreate the containers without touching the database.
cmd_update() {
  FORCE_PULL=1
  SKIP_BUILD=1
  cmd_start "$1" 0
}

# Install a systemd unit so the desk starts on boot and keeps running after
# the SSH session ends. Root installs a system unit; a regular user installs
# a user unit (no sudo needed; requires lingering, which setup-host.sh sets).
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
  say "${DIM}  (needs 'loginctl enable-linger $USER' to survive logout — setup-host.sh does it)${RESET}"
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
    -y | --yes) export RINKDESK_ASSUME_YES=1; shift ;;
    -n | --no-open) OPEN=0; shift ;;
    --start | start) CMD=start; shift ;;
    --stop | stop) CMD=stop; shift ;;
    --force-recreate | --reset) CMD=start; RECREATE=1; shift ;;
    --update | update) CMD=update; shift ;;
    --status | status) CMD=status; shift ;;
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

case "$CMD" in
  help) print_usage ;;
  manual) cat "$ROOT/scripts/manual.txt" ;;
  start) cmd_start "$OPEN" "$RECREATE" ;;
  update) cmd_update "$OPEN" ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  install-service) cmd_install_service ;;
  uninstall-service) cmd_uninstall_service ;;
  paths) cmd_paths ;;
esac

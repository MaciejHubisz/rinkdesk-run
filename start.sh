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
# Windows:  .\scripts\windows.cmd --start --export-path D:\rinkdesk-exports
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"
maybe_reexec_wsl "$@"
if [[ -f "$ROOT/release.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/release.env"
  set +a
fi

CMD=help
OPEN=1
RECREATE=0
SKIP_BUILD="${RINKDESK_SKIP_BUILD:-0}"
FORCE_PULL="${RINKDESK_FORCE_PULL:-0}"
EXPORT_PATH="${RINKDESK_EXPORTS_PATH:-}"
PROTOCOLS_PATH="${RINKDESK_PROTOCOLS_PATH:-}"

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
  ${GREEN}./start.sh --stop${RESET}              stop (data kept)
  ${GREEN}./start.sh --manual${RESET}            how the desk works

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
  -n, --no-open                  do not open a browser
  -V, --version
  -h, --help

  Windows:  .\\scripts\\windows.cmd --start
            .\\scripts\\windows.cmd --start --export-path D:\\rinkdesk-exports
            .\\scripts\\windows.cmd --start --protocols-path D:\\rinkdesk-protocols
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
  if [[ -f "$ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT/.env"
    set +a
  fi
  APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || printf '1.0.0')"
  export RINKDESK_PORT="$PORT"
  export RINKDESK_VERSION="$APP_VERSION"
  export RINKDESK_IMAGE_TAG="${RINKDESK_IMAGE_TAG:-$APP_VERSION}"
  export RINKDESK_RUN_COMMIT="$(git_commit)"

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
  [[ "$recreate" == 1 ]] && say "Empty desk (database wiped)."
  print_paths
  [[ "$open_it" == 1 ]] && open_browser "$URL"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      [[ $# -ge 2 ]] || die "$1 needs a port"
      PORT="$2"; refresh_url; shift 2 ;;
    -H|--host)
      [[ $# -ge 2 ]] || die "$1 needs a host"
      HOST="$2"; refresh_url; shift 2 ;;
    --export-path)
      [[ $# -ge 2 ]] || die "$1 needs a folder"
      EXPORT_PATH="$2"; shift 2 ;;
    --protocols-path)
      [[ $# -ge 2 ]] || die "$1 needs a folder"
      PROTOCOLS_PATH="$2"; shift 2 ;;
    --no-build) SKIP_BUILD=1; shift ;;
    --force-pull|--from-hub)
      FORCE_PULL=1
      SKIP_BUILD=1
      shift ;;
    -n|--no-open) OPEN=0; shift ;;
    --start|start) CMD=start; shift ;;
    --stop|stop) CMD=stop; shift ;;
    --force-recreate|--reset) CMD=start; RECREATE=1; shift ;;
    --paths|--where) CMD=paths; shift ;;
    --manual|--data|manual) CMD=manual; shift ;;
    -h|--help|help) CMD=help; shift ;;
    -V|--version) print_version; exit 0 ;;
    *) die "unknown argument: $1  (try: $0 --help)" ;;
  esac
done

[[ "$FORCE_PULL" == 1 ]] && SKIP_BUILD=1

case "$CMD" in
  help) print_usage ;;
  manual) cat "$ROOT/scripts/manual.txt" ;;
  start) cmd_start "$OPEN" "$RECREATE" ;;
  stop) cmd_stop ;;
  paths) cmd_paths ;;
esac

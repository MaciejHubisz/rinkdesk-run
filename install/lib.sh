# RinkDesk — shared helpers. Sourced by ./start.sh, not executed.
# Expects ROOT (repository root). Sets INSTALL, PORT, HOST, URL, APP_VERSION.

: "${ROOT:?ROOT must be set to the repository root}"

INSTALL="${INSTALL:-$ROOT/install}"
PORT="${RINKDESK_PORT:-8765}"
HOST="${RINKDESK_HOST:-127.0.0.1}"
URL="http://${HOST}:${PORT}/"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || printf '1.0.0')"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  ICE=$'\033[38;5;75m'
  GOLD=$'\033[38;5;178m'
  RED=$'\033[38;5;203m'
  GREEN=$'\033[38;5;114m'
  RESET=$'\033[0m'
else
  BOLD="" DIM="" ICE="" GOLD="" RED="" GREEN="" RESET=""
fi

hr() {
  printf '%s\n' "${DIM}────────────────────────────────────────────────────────${RESET}"
}

say() {
  printf '%s\n' "$*"
}

die() {
  printf '%s\n' "${RED}error:${RESET} $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

git_commit() {
  git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf 'dev'
}

print_version() {
  printf '%s\n' "RinkDesk ${APP_VERSION} ($(git_commit))"
}

refresh_url() {
  URL="http://${HOST}:${PORT}/"
}

# Source a file from install/. Fails if the file is missing.
load() {
  local f="$INSTALL/$1"
  [[ -f "$f" ]] || die "missing $f"
  # shellcheck disable=SC1090
  source "$f"
}

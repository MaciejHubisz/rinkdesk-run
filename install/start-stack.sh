# RinkDesk — start or recreate the Compose stack (pre-built images).
# Sourced by ./start.sh. Requires engine.sh.

wipe_volumes() {
  cd "$ROOT"
  say "Stopping services and deleting Postgres volumes…"
  compose down --remove-orphans -v >/dev/null 2>&1 || true
  if [[ -n "${ENGINE:-}" ]]; then
    "$ENGINE" volume rm rinkdesk-pg rinkdesk-exports >/dev/null 2>&1 || true
  fi
}

open_browser() {
  local target="$1"
  if is_macos && have open; then
    open "$target" >/dev/null 2>&1 || true
  elif is_wsl; then
    if have wslview; then
      wslview "$target" >/dev/null 2>&1 || true
    elif have explorer.exe; then
      explorer.exe "$target" >/dev/null 2>&1 || true
    elif [[ -x /mnt/c/Windows/explorer.exe ]]; then
      /mnt/c/Windows/explorer.exe "$target" >/dev/null 2>&1 || true
    elif have xdg-open; then
      xdg-open "$target" >/dev/null 2>&1 || true
    else
      say "${DIM}Open ${target} in a browser.${RESET}"
    fi
  elif have xdg-open; then
    xdg-open "$target" >/dev/null 2>&1 || true
  elif have gio; then
    gio open "$target" >/dev/null 2>&1 || true
  elif have firefox; then
    firefox "$target" >/dev/null 2>&1 || true
  elif have google-chrome; then
    google-chrome "$target" >/dev/null 2>&1 || true
  else
    say "${DIM}Open ${target} in a browser.${RESET}"
  fi
}

wait_until_up() {
  local i
  say "${DIM}Waiting for ${URL} (first start may pull images)…${RESET}"
  for i in $(seq 1 300); do
    if python3 - "$HOST" "$PORT" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect((host, port))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
    then
      return 0
    fi
    if (( i % 15 == 0 )); then
      say "${DIM}  still waiting (${i}s)…${RESET}"
    fi
    sleep 1
  done
  return 1
}

print_banner() {
  cat <<EOF

$(hr)
  ${BOLD}Clerk path${RESET}
    licenses → teams → match → both lineups approved → protocol → table

  ${BOLD}Book${RESET}     $0
$(hr)
EOF
}

# $1 = 1 to open a browser, 0 to skip
# $2 = 1 to wipe Postgres and pull images, 0 to resume
start_stack() {
  local open_it="${1:-1}"
  local recreate="${2:-0}"
  local commit
  commit="$(git_commit)"
  ensure_runtime
  cd "$ROOT"
  export RINKDESK_PORT="$PORT"
  export RINKDESK_VERSION="$APP_VERSION"
  export RINKDESK_COMMIT="${RINKDESK_COMMIT:-$commit}"
  export RINKDESK_IMAGE_TAG="${RINKDESK_IMAGE_TAG:-$APP_VERSION}"

  say "${DIM}Pulling images…${RESET}"
  if ! compose pull; then
    compose logs --tail 5 >/dev/null 2>&1 || true
    die "could not pull images (check .env registry, docker login, and that packages are Public).
  Expected:
    \${RINKDESK_IMAGE_PREFIX}-backend:\${RINKDESK_IMAGE_TAG}
    \${RINKDESK_IMAGE_PREFIX}-web:\${RINKDESK_IMAGE_TAG}"
  fi

  if [[ "$recreate" == 1 ]]; then
    wipe_volumes
    compose up --force-recreate --no-build -d
  else
    compose up --no-build -d
  fi

  if ! wait_until_up; then
    compose logs --tail 40
    die "desk did not start on ${URL}"
  fi

  printf '%s\n' "${BOLD}${ICE}RinkDesk${RESET} ${APP_VERSION} (${commit})  ${GREEN}up${RESET}"
  printf '%s\n' "  ${BOLD}${URL}${RESET}"
  if [[ "$recreate" == 1 ]]; then
    printf '%s\n' "  Empty desk (Postgres wiped). Import a snapshot in Settings if you need data."
  else
    printf '%s\n' "  Current Postgres data kept."
  fi
  print_banner
  [[ "$open_it" == 1 ]] && open_browser "$URL"
  printf '%s\n' "${DIM}Stop with: $0 --stop${RESET}"
}

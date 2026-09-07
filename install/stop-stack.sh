# RinkDesk — stop the Compose stack (Postgres data is kept).
# Sourced by ./start.sh. Requires engine.sh.

stop_stack() {
  cd "$ROOT"
  compose down --remove-orphans >/dev/null 2>&1 || true
  printf '%s\n' "Stopped RinkDesk ${APP_VERSION} on ${URL}"
}

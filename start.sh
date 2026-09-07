#!/usr/bin/env bash
# RinkDesk — amateur rink-clerk desk (ice 5-on-5 + roller 4-on-4)
# Public copy: pulls pre-built images. No source tree in this folder.
#
#   ./start.sh                     technical commands
#   ./start.sh --start             start or resume (keep Postgres data)
#   ./start.sh --force-recreate    wipe Postgres, pull images, start empty
#   ./start.sh --stop              stop the stack (data kept)
#   ./start.sh --manual            data manual
#
# Implementation lives in install/. This file only parses flags and dispatches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$ROOT/install"

# shellcheck source=install/lib.sh
source "$INSTALL/lib.sh"
load platform.sh
setup_platform
load wsl.sh

if is_windows && [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  reexec_via_wsl "$@"
fi

CMD="help"
OPEN=1
FORCE_RECREATE=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--port)
        [[ $# -ge 2 ]] || die "$1 needs a port"
        PORT="$2"
        refresh_url
        shift 2
        ;;
      -H|--host)
        [[ $# -ge 2 ]] || die "$1 needs a host"
        HOST="$2"
        refresh_url
        shift 2
        ;;
      -n|--no-open)
        OPEN=0
        shift
        ;;
      --start|start)
        CMD="start"
        shift
        ;;
      --force-recreate)
        CMD="start"
        FORCE_RECREATE=1
        shift
        ;;
      --setup)
        CMD="setup"
        shift
        ;;
      --stop|stop)
        CMD="stop"
        shift
        ;;
      --manual|--data|manual|man|data)
        CMD="manual"
        shift
        ;;
      -h|--help|help)
        CMD="help"
        shift
        ;;
      -V|--version)
        print_version
        exit 0
        ;;
      seed|fresh|reset|status|test|push|--push)
        die "removed '$1' — use $0 --start or $0 --force-recreate  (see --help)"
        ;;
      *)
        die "unknown argument: $1  (try: $0 --help)"
        ;;
    esac
  done
}

dispatch() {
  case "$CMD" in
    help)
      load print-manual.sh
      print_usage
      ;;
    manual)
      load print-manual.sh
      print_manual
      ;;
    start)
      load engine.sh
      load start-stack.sh
      start_stack "$OPEN" "$FORCE_RECREATE"
      ;;
    stop)
      load engine.sh
      load stop-stack.sh
      stop_stack
      ;;
    setup)
      load setup-completion.sh
      run_setup
      ;;
    *)
      die "unknown command: $CMD"
      ;;
  esac
}

parse_args "$@"
dispatch

#!/usr/bin/env bash
# Double-click this file in Finder to stop RinkDesk (data is kept).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$ROOT/start.sh" --stop "$@"
status=$?
if [[ -t 0 ]]; then
  printf '\nPress Return to close…'
  read -r _ || true
fi
exit "$status"

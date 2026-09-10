#!/usr/bin/env bash
# Double-click this file in Finder to start RinkDesk (or run it in Terminal).
# The window stays open so you can read the result.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$ROOT/start.sh" --start "$@"
status=$?
if [[ -t 0 ]]; then
  printf '\nPress Return to close…'
  read -r _ || true
fi
exit "$status"

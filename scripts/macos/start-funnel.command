#!/usr/bin/env bash
# Double-click this file in Finder to share the read-only live page on the
# internet with Tailscale Funnel. It installs Tailscale if needed and asks you
# to log in once in the browser.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$ROOT/start-funnel.sh" "$@"
status=$?
if [[ -t 0 ]]; then
  printf '\nPress Return to close…'
  read -r _ || true
fi
exit "$status"

#!/usr/bin/env bash
# Ensure the common/ submodule is checked out. It is a private repo, so a
# GitHub token is needed: from the environment, registry.env, or a prompt.
# Idempotent; the token is stored in the operator's git config so later
# `git pull` and submodule updates keep working.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/common/ops/start.sh"

# As root, do the checkout as the operator so the files stay owned by them.
if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
  home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$SUDO_USER" -- env HOME="$home" USER="$SUDO_USER" LOGNAME="$SUDO_USER" \
      APP_RUN_ROOT="$ROOT" APP_CONFIG="${APP_CONFIG:-$ROOT/app.conf}" bash "$0" "$@"
  fi
  exec su -s /bin/bash "$SUDO_USER" -c \
    "HOME=$(printf '%q' "$home") APP_RUN_ROOT=$(printf '%q' "$ROOT") APP_CONFIG=$(printf '%q' "${APP_CONFIG:-$ROOT/app.conf}") $(printf '%q ' "$0" "$@")"
fi

APP_CONFIG="${APP_CONFIG:-$ROOT/app.conf}"
# shellcheck disable=SC1090
[[ -f "$APP_CONFIG" ]] && source "$APP_CONFIG"
PREFIX="${APP_ENV_PREFIX:-APP}"
ENV_FILE="$ROOT/registry.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

say() { printf '%s\n' "$*" >&2; }

read_token() {
  local var="${PREFIX}_GITHUB_TOKEN" token
  token="${!var:-}"
  token="${token:-${GITHUB_TOKEN:-${GH_TOKEN:-${CR_PAT:-}}}}"
  [[ -n "$token" ]] || {
    var="${PREFIX}_REGISTRY_TOKEN"
    token="${!var:-}"
  }
  [[ "$token" == "ghp_replace_me" ]] && token=""
  printf '%s' "$token"
}

git_use_token() {
  local token="$1" key
  while IFS= read -r key; do
    git config --global --unset-all "$key" 2>/dev/null || true
  done < <(git config --global --get-regexp '^url\.https://x-access-token:.*\.insteadof$' 2>/dev/null | awk '{print $1}')
  git config --global "url.https://x-access-token:${token}@github.com/.insteadOf" "git@github.com:"
}

token="$(read_token)"
if [[ -f "$ENTRY" ]]; then
  # Already checked out: keep git auth configured and the submodule on the
  # pinned commit. No network when it is already current.
  if command -v git >/dev/null 2>&1; then
    [[ -n "$token" ]] && git_use_token "$token" || true
    git -C "$ROOT" submodule update --init --recursive 2>/dev/null || true
  fi
  exit 0
fi

command -v git >/dev/null 2>&1 || {
  say "git is required to initialize common/"
  exit 1
}

say "Initializing common/ submodule…"
if git -C "$ROOT" submodule update --init --recursive 2>/dev/null && [[ -f "$ENTRY" ]]; then
  exit 0
fi

if [[ -z "$token" && -t 0 ]]; then
  say "The common/ submodule is a private repo. Create a token with the"
  say "repo and read:packages scopes:"
  say "  https://github.com/settings/tokens/new?scopes=repo,read:packages"
  printf 'GitHub token: ' >&2
  IFS= read -r -s token || true
  printf '\n' >&2
fi
if [[ -z "$token" ]]; then
  say "cannot initialize common/: no GitHub token"
  say "set ${PREFIX}_GITHUB_TOKEN (or run this in a terminal to be asked)"
  exit 1
fi

git_use_token "$token"
if ! git -C "$ROOT" submodule update --init --recursive; then
  say "could not initialize common/ submodule"
  exit 1
fi
[[ -f "$ENTRY" ]] || {
  say "common/ops/start.sh still missing after submodule update"
  exit 1
}

if ! grep -qs "^${PREFIX}_GITHUB_TOKEN=" "$ENV_FILE" 2>/dev/null; then
  umask 077
  printf '%s_GITHUB_TOKEN=%s\n' "$PREFIX" "$token" >>"$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
fi

# shellcheck shell=bash
# Registry login helpers, shared by start.sh and setup-server-as-root.sh.
# Requires common.sh (say/warn/die/have). Uses ENGINE when already detected,
# otherwise finds docker/podman itself.
#
# The image package is private, so a machine that only pulls must authenticate
# once with a token that can read packages.

# Registry host of the configured image prefix, e.g. "ghcr.io".
registry_host() {
  local prefix="${RINKDESK_REGISTRY:-${RINKDESK_IMAGE_PREFIX:-ghcr.io/maciejhubisz/rinkdesk}}"
  printf '%s\n' "${prefix%%/*}"
}

# Namespace that owns the package, e.g. "maciejhubisz". Used as the default
# registry username.
registry_owner() {
  local prefix="${RINKDESK_REGISTRY:-${RINKDESK_IMAGE_PREFIX:-ghcr.io/maciejhubisz/rinkdesk}}"
  prefix="${prefix#*/}"
  printf '%s\n' "${prefix%%/*}"
}

# Engine to use: the already-detected one, else docker, else podman.
registry_engine() {
  if [[ -n "${ENGINE:-}" ]]; then
    printf '%s\n' "$ENGINE"
    return 0
  fi
  local bin
  for bin in docker podman; do
    have "$bin" && {
      printf '%s\n' "$bin"
      return 0
    }
  done
  return 1
}

# Persistent auth file for rootless podman. Its default lives under
# $XDG_RUNTIME_DIR (tmpfs) and is lost on reboot; podman also reads this
# ~/.config fallback on pull, so writing here makes the login stick.
registry_authfile() {
  printf '%s\n' "${RINKDESK_AUTHFILE:-$HOME/.config/containers/auth.json}"
}

# True when the current user already has a credential for the registry.
registry_logged_in() {
  local engine host
  engine="$(registry_engine)" || return 1
  host="$(registry_host)"
  if [[ "$engine" == podman ]]; then
    "$engine" login --get-login "$host" --authfile "$(registry_authfile)" >/dev/null 2>&1
  else
    local cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    [[ -f "$cfg" ]] && grep -q "\"$host\"" "$cfg" 2>/dev/null
  fi
}

# Log in. Reads the token from RINKDESK_REGISTRY_TOKEN (or CR_PAT); without a
# token it prompts. RINKDESK_REGISTRY_USER is the registry username.
registry_login() {
  local engine host user token
  engine="$(registry_engine)" || die "no docker or podman found for registry login"
  host="$(registry_host)"
  user="${RINKDESK_REGISTRY_USER:-${GITHUB_ACTOR:-}}"
  token="${RINKDESK_REGISTRY_TOKEN:-${CR_PAT:-}}"
  local args=()
  if [[ "$engine" == podman ]]; then
    local authfile
    authfile="$(registry_authfile)"
    mkdir -p "$(dirname "$authfile")"
    args+=(--authfile "$authfile")
  fi
  if [[ -n "$token" ]]; then
    [[ -n "$user" ]] || die "RINKDESK_REGISTRY_USER is required with a registry token (see registry.env.example)"
    args+=(-u "$user")
  fi
  if [[ -n "$token" ]]; then
    printf '%s' "$token" | "$engine" login "$host" "${args[@]}" --password-stdin
  else
    [[ -n "$user" ]] && args+=(-u "$user")
    "$engine" login "$host" "${args[@]}"
  fi
}

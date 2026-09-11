# shellcheck shell=bash
# OS detection and everything that differs between Linux, macOS and Windows.
# Sourcing this file detects the platform once (OS / WSL).

OS=""
WSL=0

detect_os() {
  WSL=0
  case "$(uname -s 2>/dev/null)" in
    Darwin) OS=macos ;;
    MINGW* | MSYS* | CYGWIN*) OS=windows ;;
    *)
      OS=linux
      if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] ||
        { [[ -r /proc/version ]] && grep -qi microsoft /proc/version; }; then
        WSL=1
      fi
      ;;
  esac
}

is_macos() { [[ "$OS" == macos ]]; }
is_linux() { [[ "$OS" == linux ]]; }
is_windows() { [[ "$OS" == windows ]]; }
is_wsl() { [[ "$WSL" == 1 ]]; }

# Docker bind-mount relabel suffix. Linux (SELinux) wants :z; Docker Desktop
# on macOS/Windows rejects it. Windows reaches this only inside WSL.
volume_opts() { if is_linux; then printf ':z'; fi; }
# Same, for read-only mounts where the mode is a comma list (`:ro,z`).
volume_opts_ro() { if is_linux; then printf ',z'; fi; }

# `seq` is missing on some minimal macOS/BSD setups; jot is always there.
if ! command -v seq >/dev/null 2>&1 && command -v jot >/dev/null 2>&1; then
  seq() {
    local first=1 last step=1
    if [[ $# -eq 1 ]]; then
      last=$1
    else
      first=$1 last=$2
      [[ $# -ge 3 ]] && step=$3
    fi
    jot - "$first" "$last" "$step"
  }
fi

# Homebrew is the only package manager we use on macOS. Check it early so a
# noob gets one clear message instead of a random "command not found".
ensure_brew() {
  is_macos || return 0
  have brew && return 0
  die "Homebrew is required on macOS. Install it from https://brew.sh and re-run."
}

# Install Homebrew formulae, asking first. RINKDESK_ASSUME_YES=1 skips the
# prompt. Already-present formulae are ignored.
brew_ensure() {
  [[ $# -gt 0 ]] || return 0
  ensure_brew
  local missing=() p
  for p in "$@"; do
    have "$p" || missing+=("$p")
  done
  [[ ${#missing[@]} -gt 0 ]] || return 0
  if ! confirm "Install with Homebrew: ${missing[*]}?"; then
    die "missing: ${missing[*]} — install with:  brew install ${missing[*]}"
  fi
  say "${BOLD}Installing with Homebrew:${RESET} ${missing[*]}"
  brew install "${missing[@]}" || die "brew install failed: ${missing[*]}"
}

# Host path Docker can bind-mount. Windows drive letters become WSL paths.
resolve_host_path() {
  local raw="$1" unix=""
  raw="${raw%$'\r'}"
  [[ -n "$raw" ]] || die "a folder path is required"

  if [[ "$raw" =~ ^[A-Za-z]:[\\/] ]] || [[ "$raw" == \\\\* ]]; then
    if have wslpath; then
      unix="$(wslpath -a "$raw" | tr -d '\r')"
    elif have wsl.exe; then
      unix="$(wsl.exe wslpath -a "$raw" | tr -d '\r')"
    fi
    [[ -n "$unix" ]] || die "could not map Windows path into Linux: $raw"
    raw="$unix"
  elif [[ "$raw" != /* ]]; then
    raw="$(pwd)/$raw"
  fi

  mkdir -p "$raw" || die "cannot create folder: $raw"
  (cd "$raw" && pwd)
}

# Git Bash on Windows cannot talk to Docker Desktop reliably — jump into WSL.
maybe_reexec_wsl() {
  detect_os
  [[ "$OS" == windows ]] || return 0
  local wslbin="" distro unix
  if have wsl.exe; then wslbin=wsl.exe
  elif have wsl; then wslbin=wsl
  else
    die "Windows needs WSL. In Administrator PowerShell: wsl --install
Then:  .\\scripts\\windows\\windows.cmd --start"
  fi
  distro="$(
    "$wslbin" --list --quiet --utf8 2>/dev/null || "$wslbin" --list --quiet 2>/dev/null | tr -d '\0'
  )"
  distro="$(printf '%s\n' "$distro" | while IFS= read -r n; do
    n="${n//$'\r'/}"
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    case "$n" in '' | docker-desktop | docker-desktop-data | rancher-desktop) continue ;; esac
    printf '%s\n' "$n"
    break
  done)"
  [[ -n "$distro" ]] || die "No WSL Linux distro (docker-desktop is not enough). wsl --install -d Ubuntu"
  local self="$0"
  [[ "$self" == /* ]] || self="$PWD/$self"
  unix="$("$wslbin" -d "$distro" wslpath -a "$self" 2>/dev/null | tr -d '\r')"
  [[ -n "$unix" ]] || die "could not map $self into WSL ($distro)"
  say "${DIM}Windows → WSL (${distro})${RESET}"
  exec "$wslbin" -d "$distro" -e bash "$unix" "$@"
}

open_browser() {
  local target="$1"
  if is_macos && have open; then
    open "$target" >/dev/null 2>&1 || true
  elif is_wsl; then
    if have wslview; then wslview "$target" >/dev/null 2>&1 || true
    elif have explorer.exe; then explorer.exe "$target" >/dev/null 2>&1 || true
    elif [[ -x /mnt/c/Windows/explorer.exe ]]; then /mnt/c/Windows/explorer.exe "$target" >/dev/null 2>&1 || true
    elif have xdg-open; then xdg-open "$target" >/dev/null 2>&1 || true
    else say "Open ${target} in a browser."
    fi
  elif have xdg-open; then xdg-open "$target" >/dev/null 2>&1 || true
  elif have open; then open "$target" >/dev/null 2>&1 || true
  else say "Open ${target} in a browser."
  fi
}

detect_os

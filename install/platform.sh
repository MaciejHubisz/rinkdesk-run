# RinkDesk platform helpers — Linux, macOS, and Windows-via-WSL.
# Sourced by ./start.sh. Native Windows (PowerShell / Git Bash) re-execs into
# WSL and then uses the Linux path. Homebrew is the installer on macOS,
# Linux, and WSL; rpm-ostree/dnf/apt are a last resort on Linux.
#
# Bash 3.2-safe (macOS ships /bin/bash 3.2).

# OS ---------------------------------------------------------------------
# Sets: OS = "macos" | "linux" | "windows"
#       WSL = 1 when running inside WSL (OS is still "linux" — same path).
platform_detect() {
  WSL=0
  case "$(uname -s 2>/dev/null)" in
    Darwin) OS="macos" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *)
      OS="linux"
      if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]]; then
        WSL=1
      elif [[ -r /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        WSL=1
      fi
      ;;
  esac
}

is_macos() {
  [[ "${OS:-}" == macos ]]
}

is_windows() {
  [[ "${OS:-}" == windows ]]
}

is_wsl() {
  [[ "${WSL:-0}" == 1 ]]
}

# Homebrew --------------------------------------------------------------
BREW_PREFIX=""

# find_brew: locates an existing Homebrew (linuxbrew under /home/linuxbrew,
# including WSL; macOS under /opt/homebrew on Apple Silicon or /usr/local
# on Intel). Sets BREW_PREFIX. Returns 0 when found.
find_brew() {
  local c
  if have brew; then
    BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
    [[ -n "$BREW_PREFIX" ]] && return 0
  fi
  for c in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew; do
    if [[ -x "$c/bin/brew" ]]; then
      BREW_PREFIX="$c"
      return 0
    fi
  done
  return 1
}

# ensure_brew: installs Homebrew when missing (official script, both OSes).
ensure_brew() {
  if find_brew; then
    return 0
  fi
  say "Homebrew not found — installing it…"
  if ! have curl; then
    die "curl is required to install Homebrew. Install curl first, then rerun."
  fi
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if ! find_brew; then
    die "Homebrew install failed. Install it manually from https://brew.sh and rerun."
  fi
  return 0
}

# PATH -------------------------------------------------------------------
# setup_platform: puts every possible Homebrew prefix and common tool dirs
# on PATH (Bazzite and brew both keep tools off the default login PATH).
# System /usr/bin stays first, brew dirs follow.
setup_platform() {
  platform_detect
  local extra=""
  if find_brew; then
    extra="${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin"
  fi
  [[ -d "/usr/local/bin" ]] && extra="${extra:+${extra}:}/usr/local/bin"
  [[ -d "$HOME/.local/bin" ]] && extra="${extra:+${extra}:}${HOME}/.local/bin"
  local base="/usr/bin:/usr/sbin:/bin:/sbin"
  if [[ -n "$extra" ]]; then
    export PATH="${base}:${extra}:${PATH}"
  else
    export PATH="${base}:${PATH}"
  fi
}

# install_packages --------------------------------------------------------
# Homebrew everywhere when available; native managers only on Linux when
# brew is not installed yet.
install_packages() {
  if find_brew; then
    say "${DIM}brew install: $*${RESET}"
    brew install "$@"
    return $?
  fi
  if is_macos; then
    ensure_brew
    brew install "$@"
    return $?
  fi
  if have rpm-ostree; then
    say "${DIM}Installing via rpm-ostree: $*${RESET}"
    sudo rpm-ostree install -A -y "$@"
  elif have dnf; then
    say "${DIM}Installing via dnf: $*${RESET}"
    sudo dnf install -y "$@"
  elif have apt-get; then
    say "${DIM}Installing via apt: $*${RESET}"
    sudo apt-get update -y
    sudo apt-get install -y "$@"
  else
    die "cannot install $*: no Homebrew, and no rpm-ostree/dnf/apt fallback"
  fi
}

# ensure_python -----------------------------------------------------------
# python3 drives the socket checks (Linux path, including WSL).
ensure_python() {
  if have python3; then
    return 0
  fi
  say "python3 not found — installing it via Homebrew."
  ensure_brew
  if have python3; then
    return 0
  fi
  brew install python
  if ! have python3; then
    die "python3 is required — install Python 3 and rerun."
  fi
}

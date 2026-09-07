# RinkDesk — native Windows (Git Bash / MSYS) re-exec into WSL.
# Sourced by ./start.sh. Docker Desktop's WSL distros are skipped.

# First real Linux distro from `wsl --list` (not docker-desktop).
wsl_linux_distro() {
  local bin="$1"
  local n
  while IFS= read -r n; do
    n="${n//$'\r'/}"
    n="${n//$'\0'/}"
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    [[ -z "$n" ]] && continue
    case "$n" in
      docker-desktop|docker-desktop-data|rancher-desktop) continue ;;
    esac
    printf '%s\n' "$n"
    return 0
  done < <("$bin" --list --quiet --utf8 2>/dev/null || "$bin" --list --quiet 2>/dev/null | tr -d '\0')
  return 1
}

reexec_via_wsl() {
  local wslbin=""
  if have wsl.exe; then
    wslbin=wsl.exe
  elif have wsl; then
    wslbin=wsl
  else
    die "Windows needs WSL. In PowerShell as Administrator run: wsl --install
Then from this folder: .\\start.ps1"
  fi
  local distro unix
  distro="$(wsl_linux_distro "$wslbin" || true)"
  if [[ -z "$distro" ]]; then
    die "No WSL Linux distro found (docker-desktop is not enough).
In PowerShell as Administrator: wsl --install -d Ubuntu
Then: .\\start.ps1"
  fi
  unix="$("$wslbin" -d "$distro" wslpath -a "$ROOT" 2>/dev/null | tr -d '\r')"
  [[ -n "$unix" ]] || die "could not map $ROOT into WSL distro $distro"
  say "${DIM}Windows → WSL (${distro}), Linux path${RESET}"
  exec "$wslbin" -d "$distro" -e bash "$unix/start.sh" "$@"
}

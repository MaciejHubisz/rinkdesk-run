# RinkDesk — per-machine tab completion for ./start.sh.
# Sourced by ./start.sh. Already-present files are left alone.

ask_yes_no() {
  local ans
  if [[ ! -t 0 ]]; then
    return 1
  fi
  read -r -p "$1 [y/N] " ans || return 1
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

setup_src() {
  printf '%s\n' "$INSTALL/tab-completion.bash"
}

setup_completion_file() {
  printf '%s\n' "${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions/start.sh"
}

setup_hook_file() {
  printf '%s\n' "$HOME/.bash_completion"
}

setup_hook_marker() {
  printf '%s\n' "# RinkDesk start.sh completion"
}

# --setup: install per-machine shell bits. Already present → ignored.
run_setup() {
  local src dest hook marker
  src="$(setup_src)"
  dest="$(setup_completion_file)"
  hook="$(setup_hook_file)"
  marker="$(setup_hook_marker)"
  [[ -f "$src" ]] || die "missing $src"

  say "${BOLD}RinkDesk setup${RESET}  (this machine)"

  if [[ -e "$dest" || -L "$dest" ]]; then
    say "${DIM}ignored${RESET}  tab completion file (already exists): $dest"
  elif [[ ! -t 0 ]]; then
    say "${DIM}ignored${RESET}  tab completion file (no terminal for yes/no)"
  elif ask_yes_no "Add tab completion file ${dest} ?"; then
    mkdir -p "$(dirname "$dest")" || die "cannot create $(dirname "$dest")"
    ln -sfn "$src" "$dest" 2>/dev/null || cp -f "$src" "$dest"
    say "${GREEN}added${RESET}    tab completion file: $dest"
  else
    say "${DIM}ignored${RESET}  tab completion file (no)"
  fi

  if [[ -f "$hook" ]] && grep -qF "$marker" "$hook"; then
    say "${DIM}ignored${RESET}  shell hook (already exists): $hook"
  elif [[ ! -t 0 ]]; then
    say "${DIM}ignored${RESET}  shell hook (no terminal for yes/no)"
  elif ask_yes_no "Add shell hook to ${hook} so new terminals complete ./start.sh ?"; then
    {
      printf '\n%s\n' "$marker"
      printf '[ -f %q ] && . %q\n' "$src" "$src"
    } >> "$hook"
    say "${GREEN}added${RESET}    shell hook: $hook"
  else
    say "${DIM}ignored${RESET}  shell hook (no)"
  fi

  say "This shell: ${GREEN}. $src${RESET}   New terminals pick up the hook after a new login."
}

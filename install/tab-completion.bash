# RinkDesk tab completion for start.sh (bash 3.2+).
# Loaded by bash-completion as "start.sh", or:  . install/tab-completion.bash

_rinkdesk_start() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  local opts='--start --force-recreate --setup --stop --manual --data --help --version --port --no-open --host -p -n -h -V -H'
  local cmds='start stop'

  case "$prev" in
    -p|--port|-H|--host)
      return 0
      ;;
  esac

  if [[ "$cur" == -* ]]; then
    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "$opts" -- "$cur"))
  else
    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
  fi
}

complete -F _rinkdesk_start start.sh 2>/dev/null || true
complete -F _rinkdesk_start ./start.sh 2>/dev/null || true

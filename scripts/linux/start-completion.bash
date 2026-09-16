# Bash tab completion for start.sh
#
# Enable it by sourcing this file from ~/.bashrc:
#
#   source /path/to/rinkdesk-run/scripts/linux/start-completion.bash
#
# Then `./start.sh --for<TAB>` completes to --force-pull/--force-recreate,
# `./start.sh --start --export-path ~/e<TAB>` completes the folder, etc.
# Works for any invocation spelling (start.sh, ./start.sh, /full/path/start.sh).
# compopt needs bash 4+ (Linux); older bash simply skips the hint.

_start_sh_complete() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"

    local opts="--start start --stop stop --force-recreate --reset
        --update update --status status --logs logs
        --install-service --uninstall-service
        --manual --data manual
        --port -p --host -H
        --export-path --protocols-path
        --force-pull --from-hub --no-build --no-self-update
        --yes -y --no-open -n
        --version -V --help -h help"

    case "$prev" in
        --export-path|--protocols-path)
            type compopt >/dev/null 2>&1 && compopt -o dirnames
            COMPREPLY=()
            return 0
            ;;
        --port|-p|--host|-H)
            COMPREPLY=()
            return 0
            ;;
    esac

    COMPREPLY=($(compgen -W "$opts" -- "$cur"))
    type compopt >/dev/null 2>&1 && compopt -o default 2>/dev/null
    return 0
}

complete -F _start_sh_complete start.sh

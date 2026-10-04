# bash completion for nbup (NetBird Upgrade)
# Installed by install.sh to /usr/share/bash-completion/completions/nbup

_nbup() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  local commands="backup upgrade restore status list"
  local opts

  if (( COMP_CWORD == 1 )); then
    COMPREPLY=($(compgen -W "$commands --help --version" -- "$cur"))
    return
  fi

  case ${COMP_WORDS[1]} in
    backup)  opts="--yes --no-certs" ;;
    upgrade) opts="--yes --no-certs --prune" ;;
    restore) opts="--yes --no-certs" ;;
    *)       opts="" ;;
  esac
  # Archive names are not completed: BACKUP_ROOT is readable by root only.
  COMPREPLY=($(compgen -W "$opts" -- "$cur"))
}

complete -F _nbup nbup

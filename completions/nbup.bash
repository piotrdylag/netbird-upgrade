# bash completion for nbup (NetBird Upgrade)
# Installed by install.sh to /usr/share/bash-completion/completions/nbup

_nbup() {
  local cur=${COMP_WORDS[COMP_CWORD]} prev= opt= cmd= i
  local commands="backup upgrade restore status list"
  local path_opts="--netbird-dir= --backup-dir= --config-file="
  local opts

  (( COMP_CWORD > 0 )) && prev=${COMP_WORDS[COMP_CWORD-1]}

  # Value of an option: bash splits "--backup-dir=/va" into "--backup-dir",
  # "=" and "/va", and "--backup-dir /va" into two words.
  if [[ $cur == "=" ]]; then
    opt=$prev cur=
  elif [[ $prev == "=" ]] && (( COMP_CWORD > 1 )); then
    opt=${COMP_WORDS[COMP_CWORD-2]}
  elif [[ $prev == --* ]]; then
    opt=$prev
  fi
  case $opt in
    --netbird-dir|--backup-dir)
      compopt -o filenames 2>/dev/null
      COMPREPLY=($(compgen -d -- "$cur"))
      return ;;
    --config-file)
      compopt -o filenames 2>/dev/null
      COMPREPLY=($(compgen -f -- "$cur"))
      return ;;
    --keep-backups)
      COMPREPLY=()
      return ;;
  esac

  # The command is the first word that is not an option or an option value.
  for (( i = 1; i < COMP_CWORD; i++ )); do
    case ${COMP_WORDS[i]} in
      backup|upgrade|restore|status|list) cmd=${COMP_WORDS[i]}; break ;;
    esac
  done

  case $cmd in
    "")      opts="$commands --help --version $path_opts" ;;
    backup)  opts="--yes --no-certs --keep-backups= $path_opts" ;;
    upgrade) opts="--yes --no-certs --prune --keep-backups= $path_opts" ;;
    restore) opts="--yes --no-certs $path_opts" ;;
    status|list) opts="$path_opts" ;;
  esac
  # Archive names are not completed: BACKUP_ROOT is readable by root only.
  COMPREPLY=($(compgen -W "$opts" -- "$cur"))
  # No space after "--option=", so the value can be typed right away.
  if [[ ${#COMPREPLY[@]} -eq 1 && ${COMPREPLY[0]} == *= ]]; then
    compopt -o nospace 2>/dev/null
  fi
}

complete -F _nbup nbup

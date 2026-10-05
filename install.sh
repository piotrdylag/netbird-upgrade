#!/usr/bin/env bash
#
# install.sh - Install or remove nbup.
#
# Usage: sudo ./install.sh [options]
#
# Options:
#   --user NAME     Allow NAME to run nbup through sudo, limited to
#                   backup, upgrade, status and list. Without this option only
#                   users with full sudo rights can run it.
#   --create-user   Create the --user account if it does not exist yet
#   --uninstall     Remove the command, completion and sudo rule (config, log
#                   and backups are kept)
#   -h, --help      Show this help

set -euo pipefail

# /usr/sbin is in sudo's secure_path on EL 7+ and Debian/Ubuntu alike, and it's
# where the .deb/.rpm packages install nbup too. nbup 1.0.x used /usr/local/sbin,
# which EL's secure_path lacks ("sudo: nbup: command not found").
BIN=/usr/sbin/nbup
OLD_BIN=/usr/local/sbin/nbup
COMPLETION=/usr/share/bash-completion/completions/nbup
CONF=/etc/nbup.conf
SUDOERS=/etc/sudoers.d/nbup
SRC=$(dirname "$(readlink -f "$0")")
MAINT_USER=
CREATE_USER=0
UNINSTALL=0

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die()   { echo "ERROR: $*" >&2; exit 1; }
warn()  { echo "WARNING: $*" >&2; }

while (( $# )); do
  case $1 in
    --user)        [[ $# -ge 2 ]] || die "--user needs a name"; MAINT_USER=$2; shift ;;
    --user=*)      MAINT_USER=${1#*=} ;;
    --create-user) CREATE_USER=1 ;;
    --uninstall)   UNINSTALL=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run with sudo"

if (( UNINSTALL )); then
  rm -f -- "$BIN" "$OLD_BIN" "$COMPLETION" "$SUDOERS"
  echo "Removed $BIN, $COMPLETION and $SUDOERS."
  echo "Kept $CONF, /var/log/nbup.log and your backups - delete them manually if wanted."
  exit 0
fi

if [[ -n $MAINT_USER ]]; then
  [[ $MAINT_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid user name: $MAINT_USER"
  [[ $MAINT_USER != root ]] || die "--user root makes no sense; root can already run the script"
fi
if (( CREATE_USER )) && [[ -z $MAINT_USER ]]; then die "--create-user requires --user NAME"; fi

# ---- Prerequisites ----------------------------------------------------------
for cmd in docker flock tar sha256sum realpath find awk; do
  command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
done
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 ('docker compose') is required"
command -v curl >/dev/null || warn "curl not found - release/version checks will be skipped"

# ---- Script and config ------------------------------------------------------
# Strip Windows line endings while copying, in case the repo was checked out
# on Windows. The script must be root-owned and not writable by anyone else,
# otherwise a sudo user could edit it and run arbitrary code as root.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

sed 's/\r$//' "$SRC/nbup.sh" >"$tmp"
bash -n "$tmp" || die "nbup.sh has syntax errors"
install -o root -g root -m 0755 "$tmp" "$BIN"
echo "Installed $BIN"
if [[ -e $OLD_BIN ]]; then
  rm -f -- "$OLD_BIN"
  echo "Removed the old copy $OLD_BIN"
fi

# Tab completion for bash (loaded automatically by the bash-completion package).
sed 's/\r$//' "$SRC/completions/nbup.bash" >"$tmp"
install -D -o root -g root -m 0644 "$tmp" "$COMPLETION"
echo "Installed $COMPLETION"

if [[ -e $CONF ]]; then
  echo "Kept existing $CONF"
else
  sed 's/\r$//' "$SRC/nbup.conf" >"$tmp"
  install -o root -g root -m 0600 "$tmp" "$CONF"
  echo "Created $CONF - replace its <placeholders> before first use"
fi

# ---- Optional restricted operator account ----------------------------------
if [[ -n $MAINT_USER ]]; then
  if ! id "$MAINT_USER" >/dev/null 2>&1; then
    (( CREATE_USER )) || die "User $MAINT_USER does not exist (create it or add --create-user)"
    useradd --create-home --shell /bin/bash --comment "NetBird Upgrade operator" "$MAINT_USER"
    echo "Created user $MAINT_USER - set a password with: sudo passwd $MAINT_USER"
  fi

  # Docker group membership is equivalent to root and defeats the sudo rule.
  if id -nG "$MAINT_USER" | tr ' ' '\n' | grep -qx docker; then
    warn "$MAINT_USER is in the docker group (root-equivalent). Remove it: sudo gpasswd -d $MAINT_USER docker"
  fi

  command -v visudo >/dev/null || die "sudo/visudo is not installed"
  grep -Eqs '^[#@]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers \
    || warn "/etc/sudoers does not include /etc/sudoers.d - the rule below will be ignored"

  # Exact argument lists only. Restore is intentionally left to full admins.
  cat >"$tmp" <<EOF
# Managed by nbup install.sh
$MAINT_USER ALL=(root) NOPASSWD: $BIN backup, $BIN backup --yes, \\
  $BIN upgrade, $BIN upgrade --yes, $BIN upgrade --prune, $BIN upgrade --yes --prune, \\
  $BIN status, $BIN list
EOF
  visudo -cf "$tmp" >/dev/null || die "Generated sudoers rule is invalid"
  install -o root -g root -m 0440 "$tmp" "$SUDOERS"
  echo "Installed sudo rule $SUDOERS for $MAINT_USER"
elif [[ -e $SUDOERS ]]; then
  if grep -qF "$OLD_BIN" "$SUDOERS"; then
    # Rule from nbup 1.0.x: point it at the new location, same commands.
    sed "s#$OLD_BIN#$BIN#g" "$SUDOERS" >"$tmp"
    visudo -cf "$tmp" >/dev/null || die "Updated sudoers rule is invalid; $SUDOERS left unchanged"
    install -o root -g root -m 0440 "$tmp" "$SUDOERS"
    echo "Updated sudo rule $SUDOERS to $BIN"
  else
    echo "Kept existing sudo rule $SUDOERS"
  fi
fi

cat <<EOF

Done. Next steps:
  1. Edit $CONF and replace the <placeholders> with your own paths:
       NETBIRD_DIR  directory with your NetBird docker-compose.yml
       BACKUP_ROOT  dedicated, root-owned directory for backups
  2. Check the setup:  sudo nbup status
  3. Upgrade NetBird:  sudo nbup upgrade
  (works from any directory; open a new shell to get tab completion)
EOF

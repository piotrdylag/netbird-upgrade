#!/usr/bin/env bash
#
# update.sh - Update an installed nbup from this repository.
#
# Usage: sudo ./update.sh [options]
#
# Pulls the latest version with git, shows the installed and new versions,
# and re-runs install.sh. Your /etc/nbup.conf and sudo rule are kept.
#
# Options:
#   -y, --yes       Do not ask for confirmation
#   --no-pull       Skip 'git pull' and install the files as they are now
#                   (e.g. after downloading a release archive)
#   -h, --help      Show this help

set -euo pipefail

BIN=/usr/sbin/nbup
OLD_BIN=/usr/local/sbin/nbup              # location used by nbup 1.0.x
LOCK_FILE=/run/nbup.lock
SRC=$(dirname "$(readlink -f "$0")")
ASSUME_YES=0
PULL=1

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

while (( $# )); do
  case $1 in
    -y|--yes)  ASSUME_YES=1 ;;
    --no-pull) PULL=0 ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run with sudo"
if [[ -x $BIN ]]; then
  INSTALLED=$BIN
elif [[ -x $OLD_BIN ]]; then
  INSTALLED=$OLD_BIN
else
  die "nbup is not installed yet; run: sudo ./install.sh"
fi

# Same lock as nbup itself, so the script is never replaced during a backup,
# upgrade or restore.
exec 9>"$LOCK_FILE"
flock -n 9 || die "nbup is running right now; try again when it has finished"

source_version() { sed -n 's/^VERSION=\([^[:space:]]*\).*/\1/p' "$SRC/nbup.sh" | head -n1; }

# ---- Pull the latest version ------------------------------------------------
# git runs as the owner of the checkout, not as root: root would hit git's
# "dubious ownership" check and could leave root-owned files in the repo.
if (( PULL )); then
  command -v git >/dev/null || die "git is not installed (or use --no-pull)"
  [[ -d $SRC/.git ]] || die "$SRC is not a git checkout (use --no-pull to install it as it is)"
  owner=$(stat -c %U "$SRC")
  # Runs git in the checkout as its owner. (cd instead of git -C: EL7 has git 1.8.3.)
  repo_git() {
    if [[ $owner == root ]]; then
      (cd "$SRC" && git "$@")
    else
      (cd "$SRC" && sudo -u "$owner" -H -- git "$@")
    fi
  }

  [[ -z $(repo_git status --porcelain --untracked-files=no) ]] \
    || die "$SRC has local changes; commit or discard them first (git status)"

  before=$(repo_git rev-parse HEAD)
  echo "Pulling the latest version as $owner..."
  repo_git pull --ff-only \
    || die "git pull failed; nothing was installed"
  after=$(repo_git rev-parse HEAD)

  if [[ $before != "$after" ]]; then
    echo
    echo "New changes:"
    repo_git --no-pager log --oneline --no-decorate "$before..$after"
  fi
fi

# ---- Compare with the installed version -------------------------------------
installed=$("$INSTALLED" --version 2>/dev/null | awk '{ print $2 }' || true)
new=$(source_version)
[[ -n $new ]] || die "Cannot read VERSION from $SRC/nbup.sh"

if [[ $INSTALLED == "$BIN" ]] && sed 's/\r$//' "$SRC/nbup.sh" | cmp -s - "$BIN"; then
  echo
  echo "nbup ${installed:-?} is already installed and up to date."
  exit 0
fi

echo
if [[ $INSTALLED != "$BIN" ]]; then
  echo "nbup ${installed:-unknown} -> $new (also moves it from $OLD_BIN to $BIN)"
elif [[ $installed == "$new" ]]; then
  echo "nbup $installed: the installed script differs from this checkout and will be replaced."
else
  echo "nbup ${installed:-unknown} -> $new"
fi

if (( ! ASSUME_YES )); then
  [[ -t 0 ]] || die "No terminal available for confirmation; re-run with --yes"
  read -r -p "Install it now? [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || die "Aborted"
fi

# ---- Install ----------------------------------------------------------------
# install.sh keeps /etc/nbup.conf and the existing sudo rule. The lock stays
# held so nbup can't start while its files are being replaced. Warnings from
# install.sh still show (stderr); its "next steps" text is for new installs.
bash "$SRC/install.sh" >/dev/null

echo "Updated: $("$BIN" --version)"

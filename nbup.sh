#!/usr/bin/env bash
#
# nbup (NetBird Upgrade) - Backup, upgrade and restore a self-hosted NetBird
# deployment running under Docker Compose.
#
# Follows the official procedures:
#   https://docs.netbird.io/selfhosted/maintenance/backup
#   https://docs.netbird.io/selfhosted/maintenance/upgrade
#
# Usage: sudo nbup <command> [options]
#
# Commands:
#   backup             Stop services, copy config + data volumes, start, archive
#   upgrade            Back up, pull new images, recreate containers, verify
#                      health; automatically roll back if the upgrade fails
#   restore <archive>  Restore config, data and previous images from a backup
#                      (file name or path inside BACKUP_ROOT)
#   status             Show containers, images, latest releases and versions
#   list               List available backups
#
# Options:
#   -y, --yes             Do not ask for confirmation (required without a TTY)
#   --no-certs            Skip proxy/traefik certificate backup
#   --prune               Remove dangling images after a successful upgrade
#   --netbird-dir=DIR     Directory with NetBird's docker-compose.yml
#   --backup-dir=DIR      Directory for backup archives
#   --keep-backups=N      Number of backup archives to keep
#   --config-file=FILE    Read settings from FILE instead of /etc/nbup.conf
#   -h, --help            Show this help
#   --version             Show the nbup version
#
# Settings come from /etc/nbup.conf (or --config-file), which must be owned by
# root and not group/world-writable. --netbird-dir, --backup-dir and
# --keep-backups override the config file; with both paths given, the config
# file is optional. Nothing is read from environment variables.
#
# Security: the sudo rule created by install.sh lists exact argument lists, so
# a restricted operator account cannot use these options. Never allow
# arbitrary arguments (such as "nbup *") in a sudo rule: pointing nbup at
# another docker-compose.yml gives root.

set -Eeuo pipefail
umask 077
VERSION=1.1.0
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

# ---- Defaults (override in /etc/nbup.conf) ------------------------
NETBIRD_DIR=                        # required: directory with docker-compose.yml
BACKUP_ROOT=                        # required: archive directory (root, 0700)
KEEP_BACKUPS=10                     # number of archives to keep
KEEP_ROLLBACK_IMAGES=3              # old images kept per service for rollback
LOG_FILE=/var/log/nbup.log
HEALTH_TIMEOUT=180                  # seconds to wait for healthy containers
HEALTH_STABLE=20                    # seconds containers must stay healthy
MIN_FREE_MB=1024                    # minimum free space in BACKUP_ROOT
NB_DOMAIN=                          # optional: for management version check
NB_API_TOKEN=                       # optional: PAT / access token for the API

# ---- Internal state --------------------------------------------------------
DEFAULT_CONF=/etc/nbup.conf
CONF_FILE=$DEFAULT_CONF
CLI_CONF_FILE=
CLI_NETBIRD_DIR=
CLI_BACKUP_ROOT=
CLI_KEEP_BACKUPS=
LOCK_FILE=/run/nbup.lock
IMAGES_META=.nbup-images
ASSUME_YES=0
INCLUDE_CERTS=1
PRUNE=0
NO_ROTATE=0
STOPPED=0
RUNNING_SVCS=()
UPGRADE_SVCS=()
SERVICES=
DATA_SVC=
WORK_DIR=
RESTORE_DIR=
PARTIAL=
LAST_BACKUP=
IMAGES_SNAPSHOT=
SNAP=

ts()   { date '+%F %T'; }
info() { printf '%s [INFO]  %s\n' "$(ts)" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

confirm() {
  if (( ASSUME_YES )); then return 0; fi
  [[ -t 0 ]] || die "No terminal available for confirmation; re-run with --yes"
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

compose() { docker compose "$@"; }

has_service() { grep -qxF -- "$1" <<<"$SERVICES"; }

container_id() { compose ps -aq "$1" 2>/dev/null | head -n1; }

# Where a setting can be changed, for error messages.
setting_hint() {
  local conf=${CONF_FILE:-$DEFAULT_CONF}
  case $1 in
    NETBIRD_DIR)  echo "--netbird-dir or $conf" ;;
    BACKUP_ROOT)  echo "--backup-dir or $conf" ;;
    KEEP_BACKUPS) echo "--keep-backups or $conf" ;;
    *)            echo "$conf" ;;
  esac
}

# Order: command-line options, then the config file, then the defaults above.
load_config() {
  if [[ -n $CLI_CONF_FILE ]]; then
    CONF_FILE=$(realpath -e -- "$CLI_CONF_FILE" 2>/dev/null) \
      || die "Config file $CLI_CONF_FILE not found"
  elif [[ ! -e $CONF_FILE ]]; then
    [[ -n $CLI_NETBIRD_DIR && -n $CLI_BACKUP_ROOT ]] \
      || die "$CONF_FILE not found; run install.sh first, or pass both --netbird-dir and --backup-dir"
    CONF_FILE=
  fi

  if [[ -n $CONF_FILE ]]; then
    local owner mode bad
    [[ -f $CONF_FILE ]] || die "$CONF_FILE is not a regular file"
    owner=$(stat -L -c %u "$CONF_FILE")
    mode=$(stat -L -c %a "$CONF_FILE")
    [[ $owner == 0 ]] || die "$CONF_FILE must be owned by root"
    (( (8#$mode & 8#022) == 0 )) || die "$CONF_FILE must not be group/world-writable"
    # Whoever can write to a parent directory could swap the file.
    bad=$(first_unsafe_dir "$(dirname "$(realpath -- "$CONF_FILE")")")
    [[ -z $bad ]] || die "$bad must be owned by root and not group/world-writable (it holds $CONF_FILE)"
    # shellcheck source=/dev/null
    . "$CONF_FILE"
  fi

  # Relative paths on the command line are taken from the current directory,
  # e.g. "cd /opt/netbird && sudo nbup upgrade --netbird-dir=.".
  if [[ -n $CLI_NETBIRD_DIR ]];  then NETBIRD_DIR=$(realpath -m -- "$CLI_NETBIRD_DIR"); fi
  if [[ -n $CLI_BACKUP_ROOT ]];  then BACKUP_ROOT=$(realpath -m -- "$CLI_BACKUP_ROOT"); fi
  if [[ -n $CLI_KEEP_BACKUPS ]]; then KEEP_BACKUPS=$CLI_KEEP_BACKUPS; fi
}

# Rejects unset paths and <placeholders> left over from the example config,
# before anything is created on disk.
validate_config() {
  local name value
  for name in NETBIRD_DIR BACKUP_ROOT LOG_FILE NB_DOMAIN NB_API_TOKEN; do
    value=${!name}
    [[ $value != *[\<\>]* ]] \
      || die "$name=\"$value\" is still a placeholder; set it with $(setting_hint "$name")"
  done
  for name in NETBIRD_DIR BACKUP_ROOT LOG_FILE; do
    value=${!name}
    [[ -n $value ]] || die "$name is not set; set it with $(setting_hint "$name")"
    [[ $value == /* ]] || die "$name must be an absolute path (got \"$value\")"
  done
  # KEEP_BACKUPS=0 would delete the archive that was just created.
  for name in KEEP_BACKUPS KEEP_ROLLBACK_IMAGES HEALTH_TIMEOUT; do
    [[ ${!name} =~ ^[1-9][0-9]*$ ]] \
      || die "$name must be a whole number of at least 1 (got \"${!name}\"); set it with $(setting_hint "$name")"
  done
  for name in HEALTH_STABLE MIN_FREE_MB; do
    [[ ${!name} =~ ^[0-9]+$ ]] \
      || die "$name must be a whole number (got \"${!name}\"); set it with $(setting_hint "$name")"
  done
  NETBIRD_DIR=$(realpath -m -- "$NETBIRD_DIR")
  BACKUP_ROOT=$(realpath -m -- "$BACKUP_ROOT")
  # BACKUP_ROOT is forced to root:root 0700, so it must be a dedicated directory.
  case $BACKUP_ROOT in
    /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm|/dev/shm/*|/run|/run/*)
      die "BACKUP_ROOT=$BACKUP_ROOT is a temporary directory that is cleared on reboot or by automatic cleanup; use a persistent one such as /var/backups/netbird" ;;
    /|/root|/home|/var|/var/backups|/var/lib|/var/log|/opt|/srv|/mnt|/media|/etc|/etc/*|/usr|/usr/*)
      die "BACKUP_ROOT=$BACKUP_ROOT is a shared directory; use a dedicated one such as /var/backups/netbird" ;;
    /home/*)
      [[ ${BACKUP_ROOT#/home/} == */* ]] \
        || die "BACKUP_ROOT=$BACKUP_ROOT is a home directory; use a dedicated subdirectory" ;;
  esac
  [[ $BACKUP_ROOT != "$NETBIRD_DIR" && $NETBIRD_DIR != "$BACKUP_ROOT"/* ]] \
    || die "BACKUP_ROOT must not be NETBIRD_DIR or one of its parents"
}

# Prints the first path from $1 up to / that is not owned by root or is
# group/world-writable; anyone who can write there can swap what is below it.
first_unsafe_dir() {
  local d=$1 owner mode
  while :; do
    if [[ -e $d ]]; then
      owner=$(stat -c %u "$d")
      mode=$(stat -c %a "$d")
      if [[ $owner != 0 ]] || (( (8#$mode & 8#022) != 0 )); then
        echo "$d"
        return
      fi
    fi
    [[ $d != / ]] || return 0
    d=$(dirname "$d")
  done
}

check_path_ownership() {
  local bad
  bad=$(first_unsafe_dir "$BACKUP_ROOT")
  [[ -z $bad ]] || die "$bad must be owned by root and not group/world-writable (it holds BACKUP_ROOT=$BACKUP_ROOT)"
  bad=$(first_unsafe_dir "$NETBIRD_DIR")
  if [[ -n $bad ]]; then
    warn "$bad is writable by a non-root user, who could change docker-compose.yml and gain root through this script"
  fi
}

preflight() {
  command -v docker >/dev/null || die "docker not found"
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
  docker compose version >/dev/null 2>&1 \
    || die "Docker Compose v2 ('docker compose') is required"
  [[ -d $NETBIRD_DIR ]] || die "NETBIRD_DIR=$NETBIRD_DIR does not exist (set it with $(setting_hint NETBIRD_DIR))"
  cd "$NETBIRD_DIR"
  compose config -q || die "Invalid compose configuration in $NETBIRD_DIR"
  detect_layout
}

# Supports the current combined layout (netbird-server) and the legacy one
# (management/signal/relay as separate containers).
detect_layout() {
  SERVICES=$(compose config --services)
  local candidates s
  if has_service netbird-server; then
    DATA_SVC=netbird-server
    candidates=(netbird-server dashboard proxy)
  elif has_service management; then
    DATA_SVC=management
    candidates=(management dashboard signal relay proxy)
  else
    die "No 'netbird-server' or 'management' service found in $NETBIRD_DIR"
  fi
  UPGRADE_SVCS=()
  for s in "${candidates[@]}"; do
    if has_service "$s"; then UPGRADE_SVCS+=("$s"); fi
  done
  info "Data service: $DATA_SVC; managed services: ${UPGRADE_SVCS[*]}"
}

check_space() {
  local free
  free=$(df -Pm "$BACKUP_ROOT" | awk 'NR == 2 { print $4 }')
  (( free >= MIN_FREE_MB )) || die "Only ${free} MB free in $BACKUP_ROOT (need $MIN_FREE_MB)"
}

# One line per existing container: "<service> <image ref> <image id>"
record_images() {
  local svc cid
  for svc in $SERVICES; do
    cid=$(container_id "$svc")
    if [[ -n $cid ]]; then
      printf '%s %s\n' "$svc" "$(docker inspect -f '{{.Config.Image}} {{.Image}}' "$cid")"
    fi
  done
}

# Tag the currently used images so they survive pulls/prunes and can be used
# for a rollback; keep only the newest KEEP_ROLLBACK_IMAGES per service.
protect_images() {
  local stamp=$1 svc ref id t old
  while read -r svc ref id; do
    [[ -n $svc ]] || continue
    docker image tag "$id" "netbird-rollback/$svc:$stamp"
    mapfile -t old < <(docker image ls "netbird-rollback/$svc" --format '{{.Tag}}' \
      | sort -r | tail -n +$((KEEP_ROLLBACK_IMAGES + 1)))
    for t in "${old[@]}"; do
      docker image rm "netbird-rollback/$svc:$t" >/dev/null || true
    done
  done <<<"$IMAGES_SNAPSHOT"
}

copy_top_level_files() {
  find "$1" -maxdepth 1 -type f ! -name '*.tar.gz' ! -name '*.tgz' \
    ! -name "$IMAGES_META" -exec cp -a {} "$2/" \;
}

rotate_backups() {
  local old f
  mapfile -t old < <(ls -1t "$BACKUP_ROOT"/netbird-backup-*.tar.gz 2>/dev/null \
    | tail -n +$((KEEP_BACKUPS + 1)))
  for f in "${old[@]}"; do
    info "Removing old backup $f"
    rm -f -- "$f" "$f.sha256"
  done
}

do_backup() {
  local stamp archive
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="$BACKUP_ROOT/netbird-backup-$stamp.tar.gz"
  check_space
  [[ -n $(container_id "$DATA_SVC") ]] \
    || die "No '$DATA_SVC' container exists; is NetBird deployed in $NETBIRD_DIR?"

  WORK_DIR=$(mktemp -d "$BACKUP_ROOT/.work-XXXXXX")
  IMAGES_SNAPSHOT=$(record_images)
  printf '%s\n' "$IMAGES_SNAPSHOT" >"$WORK_DIR/$IMAGES_META"
  mapfile -t RUNNING_SVCS < <(compose ps --services --status running)

  info "Stopping NetBird services"
  STOPPED=1
  compose stop

  info "Copying configuration files"
  copy_top_level_files "$NETBIRD_DIR" "$WORK_DIR"
  if [[ -d $NETBIRD_DIR/crowdsec ]]; then
    cp -a "$NETBIRD_DIR/crowdsec" "$WORK_DIR/crowdsec"
  fi

  info "Copying data volume $DATA_SVC:/var/lib/netbird"
  compose cp -a "$DATA_SVC:/var/lib/netbird/" "$WORK_DIR/"

  if has_service crowdsec; then
    info "Copying CrowdSec database"
    compose cp -a crowdsec:/var/lib/crowdsec/data/ "$WORK_DIR/crowdsec_db/"
  fi

  if (( INCLUDE_CERTS )); then
    if has_service proxy; then
      compose cp -a proxy:/certs/ "$WORK_DIR/proxy_certs/" \
        || warn "Could not copy proxy certificates (continuing)"
    fi
    if has_service traefik; then
      compose cp -a traefik:/letsencrypt/ "$WORK_DIR/traefik_letsencrypt/" \
        || warn "Could not copy traefik certificates (continuing)"
    fi
  fi

  info "Starting NetBird services"
  if (( ${#RUNNING_SVCS[@]} )); then compose start "${RUNNING_SVCS[@]}"; fi
  STOPPED=0

  info "Creating archive $archive"
  PARTIAL="$archive.partial"
  tar czf "$PARTIAL" -C "$WORK_DIR" .
  tar tzf "$PARTIAL" >/dev/null
  mv -- "$PARTIAL" "$archive"
  PARTIAL=
  (cd "$BACKUP_ROOT" && sha256sum "${archive##*/}" >"${archive##*/}.sha256")
  rm -rf -- "$WORK_DIR"
  WORK_DIR=

  LAST_BACKUP=$archive
  info "Backup complete: $archive ($(du -h "$archive" | cut -f1))"
  if (( ! NO_ROTATE )); then rotate_backups; fi
}

svc_state() {
  local cid
  cid=$(container_id "$1")
  if [[ -z $cid ]]; then echo "missing||0"; return; fi
  docker inspect -f \
    '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}' "$cid"
}

# Returns 0 when every service is running (and healthy, if it has a
# healthcheck). Leaves a summary in SNAP.
all_up() {
  local s st status health rc=0
  SNAP=
  for s in "$@"; do
    st=$(svc_state "$s")
    SNAP+="$s=$st "
    IFS='|' read -r status health _ <<<"$st"
    if [[ $status != running || ( -n $health && $health != healthy ) ]]; then rc=1; fi
  done
  return $rc
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) first
  info "Waiting up to ${HEALTH_TIMEOUT}s for: $*"
  while (( SECONDS < deadline )); do
    if all_up "$@"; then
      first=$SNAP
      sleep "$HEALTH_STABLE"
      # Same restart counts after the stable window = no crash loop.
      if all_up "$@" && [[ $SNAP == "$first" ]]; then
        info "Healthy: $SNAP"
        return 0
      fi
    fi
    sleep 5
  done
  err "Not healthy after ${HEALTH_TIMEOUT}s: $SNAP"
  return 1
}

latest_release() {
  curl -fsS --max-time 10 "https://api.github.com/repos/netbirdio/$1/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1 || true
}

show_versions() {
  info "Current images:"
  compose images || true
  info "Latest releases: netbird=$(latest_release netbird) dashboard=$(latest_release dashboard)"
  info "Release notes: https://github.com/netbirdio/netbird/releases"
  info "               https://github.com/netbirdio/dashboard/releases"
}

# The docs require Management and the reverse proxy to run the same version.
check_versions() {
  local proxy_v= mgmt_v= scheme=Bearer
  if has_service proxy; then
    proxy_v=$(compose exec -T proxy /go/bin/netbird-proxy --version 2>/dev/null | tail -n1 || true)
    info "Proxy version: ${proxy_v:-unknown}"
  fi
  if [[ -n $NB_DOMAIN && -n $NB_API_TOKEN ]]; then
    if [[ $NB_API_TOKEN == nbp_* ]]; then scheme=Token; fi
    # Header passed via a file descriptor so the token never shows up in ps.
    mgmt_v=$(curl -fsS --max-time 10 "https://$NB_DOMAIN/api/instance/version" \
      -H 'accept: application/json' \
      -H @<(printf 'authorization: %s %s\n' "$scheme" "$NB_API_TOKEN") 2>/dev/null \
      | sed -n 's/.*"management_current_version": *"\([^"]*\)".*/\1/p' || true)
    info "Management version: ${mgmt_v:-unknown}"
    if [[ -n $proxy_v && -n $mgmt_v && $proxy_v != *"$mgmt_v"* ]]; then
      warn "Proxy ($proxy_v) and Management ($mgmt_v) differ - keep them in sync"
    fi
  elif has_service proxy; then
    info "Set NB_DOMAIN and NB_API_TOKEN in $CONF_FILE to compare proxy/management versions"
  fi
}

do_upgrade() {
  local svc ref id new changed=0 matched=0 stamp
  show_versions
  confirm "Back up and upgrade NetBird in $NETBIRD_DIR?" || die "Aborted"

  do_backup

  stamp=$(date +%Y%m%d-%H%M%S)
  protect_images "$stamp"

  info "Pulling images: ${UPGRADE_SVCS[*]}"
  compose pull "${UPGRADE_SVCS[@]}"

  while read -r svc ref id; do
    [[ " ${UPGRADE_SVCS[*]} " == *" $svc "* ]] || continue
    matched=$((matched + 1))
    new=$(docker image inspect -f '{{.Id}}' "$ref")
    if [[ $new != "$id" ]]; then
      info "$svc: new image available for $ref"
      changed=1
    else
      info "$svc: already up to date"
    fi
  done <<<"$IMAGES_SNAPSHOT"
  if (( matched < ${#UPGRADE_SVCS[@]} )); then changed=1; fi

  if (( ! changed )); then
    info "NetBird is already up to date; nothing to recreate."
    return 0
  fi

  info "Recreating: ${UPGRADE_SVCS[*]}"
  if compose up -d --force-recreate "${UPGRADE_SVCS[@]}" && wait_healthy "${UPGRADE_SVCS[@]}"; then
    info "Upgrade successful"
    compose images "${UPGRADE_SVCS[@]}" || true
    check_versions
    if (( PRUNE )); then docker image prune -f; fi
  else
    err "Upgrade failed - rolling back using $LAST_BACKUP"
    compose logs --tail 50 "${UPGRADE_SVCS[@]}" || true
    ASSUME_YES=1
    do_restore "$LAST_BACKUP" 0
    die "Upgrade failed; previous version restored. Check the release notes before retrying."
  fi
}

# Empty the host directory behind a container mount so files created by a
# newer version (e.g. SQLite WAL files) don't mix with the restored data.
wipe_mount() {
  local svc=$1 dest=$2 cid src
  cid=$(container_id "$svc")
  src=$(docker inspect -f \
    "{{range .Mounts}}{{if eq .Destination \"$dest\"}}{{.Source}}{{end}}{{end}}" "$cid")
  if [[ -z $src || $src == / || $src == "$NETBIRD_DIR" || $src == "$BACKUP_ROOT" || ! -d $src ]]; then
    warn "Cannot locate host path of $svc:$dest; restoring on top of existing data"
    return 0
  fi
  info "Clearing $svc:$dest ($src)"
  find "$src" -mindepth 1 -delete
}

do_restore() {
  local archive=$1 pre_backup=${2:-1} svc ref id
  [[ -n $archive ]] || die "Usage: nbup restore <archive>"
  if [[ $archive != */* ]]; then archive="$BACKUP_ROOT/$archive"; fi
  archive=$(realpath -e -- "$archive") || die "Archive not found: $1"
  # Only root-controlled archives: a crafted compose file would mean root access.
  [[ $archive == "$BACKUP_ROOT"/netbird-backup-*.tar.gz ]] \
    || die "Only archives in $BACKUP_ROOT can be restored"
  if [[ -f $archive.sha256 ]]; then
    (cd "$BACKUP_ROOT" && sha256sum -c --quiet "${archive##*/}.sha256") \
      || die "Checksum mismatch for $archive"
  fi

  RESTORE_DIR=$(mktemp -d "$BACKUP_ROOT/.restore-XXXXXX")
  tar xzf "$archive" -C "$RESTORE_DIR"
  [[ -d $RESTORE_DIR/netbird ]] || die "$archive does not look like a NetBird backup"

  confirm "Restore $archive into $NETBIRD_DIR? Current config and data will be REPLACED." \
    || die "Aborted"

  if (( pre_backup )); then
    info "Taking a safety backup of the current state first"
    NO_ROTATE=1
    do_backup
  fi

  info "Removing containers (named volumes are kept)"
  compose down

  info "Restoring configuration files"
  copy_top_level_files "$RESTORE_DIR" "$NETBIRD_DIR"
  if [[ -d $RESTORE_DIR/crowdsec ]]; then
    rm -rf -- "$NETBIRD_DIR/crowdsec"
    cp -a "$RESTORE_DIR/crowdsec" "$NETBIRD_DIR/crowdsec"
  fi

  if [[ -f $RESTORE_DIR/$IMAGES_META ]]; then
    info "Restoring previous image versions"
    while read -r svc ref id; do
      [[ -n $svc && $ref != *@* ]] || continue
      if docker image inspect "$id" >/dev/null 2>&1; then
        docker image tag "$id" "$ref"
        info "$svc: $ref -> ${id:7:12}"
      else
        warn "$svc: image ${id:7:12} is gone; the current $ref will be used"
      fi
    done <"$RESTORE_DIR/$IMAGES_META"
  fi

  detect_layout

  info "Restoring data volume $DATA_SVC:/var/lib/netbird"
  compose create "$DATA_SVC"
  wipe_mount "$DATA_SVC" /var/lib/netbird
  compose cp -a "$RESTORE_DIR/netbird/." "$DATA_SVC:/var/lib/netbird/"

  if [[ -d $RESTORE_DIR/crowdsec_db ]] && has_service crowdsec; then
    compose create crowdsec
    compose cp -a "$RESTORE_DIR/crowdsec_db/." crowdsec:/var/lib/crowdsec/data/
  fi
  if [[ -d $RESTORE_DIR/proxy_certs ]] && has_service proxy; then
    compose create proxy
    compose cp -a "$RESTORE_DIR/proxy_certs/." proxy:/certs/
  fi
  if [[ -d $RESTORE_DIR/traefik_letsencrypt ]] && has_service traefik; then
    compose create traefik
    compose cp -a "$RESTORE_DIR/traefik_letsencrypt/." traefik:/letsencrypt/
  fi

  info "Starting NetBird"
  compose up -d
  rm -rf -- "$RESTORE_DIR"
  RESTORE_DIR=
  wait_healthy "${UPGRADE_SVCS[@]}" || die "Restore finished but services are not healthy"
  info "Restore complete from $archive"
}

list_backups() {
  if compgen -G "$BACKUP_ROOT/netbird-backup-*.tar.gz" >/dev/null; then
    ls -lht "$BACKUP_ROOT"/netbird-backup-*.tar.gz
  else
    info "No backups in $BACKUP_ROOT"
  fi
}

on_exit() {
  local rc=$?
  if (( STOPPED )); then
    warn "Restarting services that were stopped for the backup"
    if (( ${#RUNNING_SVCS[@]} )); then compose start "${RUNNING_SVCS[@]}" || true; fi
  fi
  if [[ -n $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi
  if [[ -n $PARTIAL ]]; then rm -f -- "$PARTIAL"; fi
  if [[ -n $RESTORE_DIR ]]; then
    rm -rf -- "$RESTORE_DIR"
    if (( rc )); then
      err "Restore was interrupted; NetBird may be down. Re-run the restore or 'docker compose up -d' in $NETBIRD_DIR"
    fi
  fi
  if (( rc )); then err "nbup failed (exit $rc); log: $LOG_FILE"; fi
  exit "$rc"
}

main() {
  local cmd= arg= opt val
  while (( $# )); do
    opt=$1 val=
    # Options with a value accept both --opt=value and --opt value.
    case $opt in
      --netbird-dir=*|--backup-dir=*|--keep-backups=*|--config-file=*)
        val=${opt#*=} opt=${opt%%=*} ;;
      --netbird-dir|--backup-dir|--keep-backups|--config-file)
        (( $# >= 2 )) || die "$opt needs a value"
        val=$2; shift ;;
    esac
    case $opt in
      --netbird-dir|--backup-dir|--keep-backups|--config-file)
        [[ -n $val ]] || die "$opt needs a value" ;;
    esac
    case $opt in
      -y|--yes)       ASSUME_YES=1 ;;
      --no-certs)     INCLUDE_CERTS=0 ;;
      --prune)        PRUNE=1 ;;
      --netbird-dir)  CLI_NETBIRD_DIR=$val ;;
      --backup-dir)   CLI_BACKUP_ROOT=$val ;;
      --keep-backups) CLI_KEEP_BACKUPS=$val ;;
      --config-file)  CLI_CONF_FILE=$val ;;
      -h|--help)      usage; exit 0 ;;
      --version)      echo "nbup $VERSION"; exit 0 ;;
      -*)             die "Unknown option: $opt (see --help)" ;;
      *)
        if [[ -z $cmd ]]; then cmd=$opt
        elif [[ -z $arg ]]; then arg=$opt
        else die "Unexpected argument: $opt"
        fi ;;
    esac
    shift
  done
  case $cmd in
    ""|help) usage; exit 0 ;;
    backup|upgrade|restore|status|list) ;;
    *) die "Unknown command: $cmd (see --help)" ;;
  esac
  [[ -z $arg || $cmd == restore ]] || die "Unexpected argument: $arg"

  [[ $EUID -eq 0 ]] || die "Must be run as root: sudo nbup $cmd"
  load_config
  validate_config
  [[ -n $(first_unsafe_dir "$(dirname "$BACKUP_ROOT")") ]] \
    || install -d -m 0700 -o root -g root "$BACKUP_ROOT"
  check_path_ownership

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another nbup run is in progress"

  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "=== nbup $VERSION $cmd (invoked by ${SUDO_USER:-root}) ==="

  trap on_exit EXIT
  trap 'err "Command failed (line $LINENO): $BASH_COMMAND"' ERR

  preflight
  case $cmd in
    backup)  do_backup ;;
    upgrade) do_upgrade ;;
    restore) do_restore "$arg" 1 ;;
    status)  show_versions; compose ps; check_versions ;;
    list)    list_backups ;;
  esac
  info "=== done ==="
}

main "$@"

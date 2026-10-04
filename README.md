<p align="center">
  <img src="media/netbird_upgrade.png" alt="NetBird Upgrade logo" width="200">
</p>

<h1 align="center">NetBird Upgrade Tool</h1>

<p align="center">Backup, upgrade and restore for self-hosted NetBird on Docker Compose</p>

A single Bash script to **back up, upgrade and restore a self-hosted [NetBird](https://netbird.io) deployment** running under Docker Compose. It follows the official [backup](https://docs.netbird.io/selfhosted/maintenance/backup) and [upgrade](https://docs.netbird.io/selfhosted/maintenance/upgrade) procedures and adds health checks and an automatic rollback. Once installed, it's the `nbup` command (**N**et**B**ird **UP**grade).

> Community project, not affiliated with or endorsed by NetBird. Always test a restore before relying on any backup tool.

**Docker Compose only.** NetBird Upgrade works with NetBird deployed via Docker Compose, the setup created by the official [getting-started script](https://docs.netbird.io/selfhosted/selfhosted-quickstart). Every action runs through `docker compose` in your NetBird directory. Deployments using plain binaries/systemd, Kubernetes/Helm or other orchestrators aren't supported.

## Features

- **One-command upgrade**: backup, pull, recreate, health check. If the new containers don't come up healthy, the previous images *and* data are restored automatically.
- **Full backup** as described in the docs: all config files from the NetBird directory, the `/var/lib/netbird` data volume, and CrowdSec data and proxy/Traefik certificates when present. Saved as a checksummed `.tar.gz`, with old archives rotated.
- **Restore** of config, data and the exact image versions that were running when the backup was taken.
- Supports the current combined `netbird-server` layout and the legacy `management` / `signal` / `relay` layout.
- After an upgrade, warns if the reverse proxy and Management versions differ (required to match since v0.76.1).
- Built to be run safely by a **non-root operator account** through a narrow sudo rule.

## Requirements

- Linux host running NetBird with **Docker Compose v2** (`docker compose`)
- `bash`, `tar`, `flock`, `sha256sum`, `realpath` (standard on Debian/Ubuntu/RHEL)
- `curl` (optional, for release and version checks)

## Installation

```bash
git clone https://github.com/piotrdylag/netbird-upgrade.git
cd netbird-upgrade
sudo ./install.sh               # admins with full sudo only
# or
sudo ./install.sh --user nbup   # also allow a restricted operator account
```

This installs `nbup` system-wide like any other command, so you can run it from any directory:

| Installed file | Purpose |
|---|---|
| `/usr/local/sbin/nbup` | The command (root-owned) |
| `/etc/nbup.conf` | Your settings (kept on reinstall) |
| `/usr/share/bash-completion/completions/nbup` | Tab completion for commands and options |
| `/etc/sudoers.d/nbup` | Only with `--user`: the operator's sudo rule |

### Set your paths

The installed `/etc/nbup.conf` contains `<placeholders>` instead of guessed paths, because every setup is different. Replace them with your own before the first run (`sudo nano /etc/nbup.conf`):

| Placeholder | Replace with | Example |
|---|---|---|
| `<netbird-compose-dir>` | Directory with NetBird's `docker-compose.yml` (where you ran the getting-started script) | `/opt/netbird` |
| `<backup-dir>` | A **dedicated** directory for backup archives | `/var/backups/netbird` |
| `<netbird-domain>` | *Optional:* your NetBird domain | `netbird.example.com` |
| `<personal-access-token>` | *Optional:* a NetBird personal access token | `nbp_...` |

```bash
NETBIRD_DIR="/opt/netbird"
BACKUP_ROOT="/var/backups/netbird"
```

- **Keep the quotes.** The file is read by Bash, where an unquoted `<` or `>` is a redirection.
- To find your NetBird directory: `docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' $(docker ps -q --filter name=netbird | head -n1)`
- `BACKUP_ROOT` is created if missing and forced to `root:root 0700`. It and all its parent directories must be owned by root and not group/world-writable. So `/home/<user>/backups` or a shared directory like `/var/backups` itself won't be accepted.

The script refuses to run while a placeholder is left in place, a path isn't absolute, or `BACKUP_ROOT` isn't safe. Check that it can see your deployment:

```bash
sudo nbup status
```

### install.sh options

| Option | Description |
|---|---|
| `--user NAME` | Lets `NAME` run `backup`, `upgrade`, `status` and `list` through sudo, without a password |
| `--create-user` | Creates the `--user` account if it doesn't exist |
| `--uninstall` | Removes the command, tab completion and sudo rule (config, log and backups are kept) |

## Usage

`nbup` always needs root, so run it with `sudo`. Only admins with sudo rights, or the operator account through its limited sudo rule, can use it.

```bash
sudo nbup upgrade            # backup + upgrade, rollback on failure
sudo nbup backup             # backup only
sudo nbup status             # containers, images, latest releases
sudo nbup list               # available backups
sudo nbup restore <archive>  # admins only (file name in BACKUP_ROOT)
```

| Option | Description |
|---|---|
| `-y`, `--yes` | Don't ask for confirmation (needed when there is no terminal) |
| `--no-certs` | Skip the proxy/Traefik certificate backup |
| `--prune` | Remove dangling images after a successful upgrade |

Read the release notes before upgrading: [netbird](https://github.com/netbirdio/netbird/releases), [dashboard](https://github.com/netbirdio/dashboard/releases).

## How an upgrade works

1. Shows the current images and the latest GitHub releases, then asks for confirmation.
2. Stops the services, takes a full backup, then starts the services again.
3. Tags the currently used images as `netbird-rollback/<service>:<timestamp>` so they can't be lost.
4. Runs `docker compose pull` for the NetBird services. If no image changed, it stops here.
5. Runs `docker compose up -d --force-recreate`, then waits until every container is running and healthy with no restarts for `HEALTH_STABLE` seconds.
6. If that fails, it puts back the previous images, restores the data from the backup taken in step 2, and starts everything again.

## Configuration

`/etc/nbup.conf` must be owned by root and not group/world-writable.

| Setting | Default | Description |
|---|---|---|
| `NETBIRD_DIR` | *required* | Directory with NetBird's `docker-compose.yml` |
| `BACKUP_ROOT` | *required* | Dedicated directory for archives (forced to `root:root 0700`) |
| `KEEP_BACKUPS` | `10` | Archives to keep |
| `KEEP_ROLLBACK_IMAGES` | `3` | Previous images kept per service |
| `LOG_FILE` | `/var/log/nbup.log` | Log of every run |
| `HEALTH_TIMEOUT` | `180` | Seconds to wait for healthy containers |
| `HEALTH_STABLE` | `20` | Seconds containers must stay up without restarting |
| `MIN_FREE_MB` | `1024` | Minimum free space required in `BACKUP_ROOT` |
| `NB_DOMAIN`, `NB_API_TOKEN` | empty | Optional; used to compare the proxy and Management versions |

## Security model

- **Never add the operator account to the `docker` group.** Docker group membership is equivalent to root.
- The installed script (`/usr/local/sbin/nbup`) is owned by root and only root can modify it, so the sudo rule can't be used to run anything else.
- Paths come only from the root-owned config file, never from arguments or environment variables. This stops anyone pointing the script at their own `docker-compose.yml`, which would give them root.
- `restore` only accepts archives inside the root-only `BACKUP_ROOT`, and isn't part of the operator's sudo rule. `BACKUP_ROOT` and every parent directory must be root-owned, so no other user can swap in their own archives.
- Keep `NETBIRD_DIR` and its `docker-compose.yml` writable by root only. Anyone who can edit the compose file can get root through this script; it prints a warning if the directory is writable by another user.
- Backups contain your database and encryption keys (`config.yaml`). Store copies off the server and protect them.

## Uninstall

```bash
sudo ./install.sh --uninstall
```

**A native Bash installer for [Nginx Proxy Manager](https://nginxproxymanager.com/) on Debian and Ubuntu -- no Docker required.**

<img width="945" height="767" alt="native-npm-installer" src="https://github.com/user-attachments/assets/a9a28be8-9a37-464f-a889-b8c137efca33" />

## Why this exists

Most Nginx Proxy Manager installation guides assume Docker. The official project ships as a Docker image, and the popular [Proxmox Community Scripts](https://community-scripts.github.io/ProxmoxVE/) LXC installer still pulls a Docker image inside the container. If you want NPM running natively on bare Debian or Ubuntu -- managed by systemd, backed by SQLite, with no container layer -- there was no clean, maintained path to get there.

This script fills that gap.

## What it does

- Installs **Nginx Proxy Manager v2.x** (latest release auto-detected) natively on the host OS
- Manages everything with **systemd** -- auto-starts on boot, restarts on failure
- Uses **SQLite** via `better-sqlite3` -- no external database required
- Builds the frontend from source with **pnpm** (v10 and v11 supported) -- no Docker, no pre-built image
- Supports **Debian 12 (Bookworm)**, **Debian 13 (Trixie)**, **Ubuntu 22.04**, **Ubuntu 24.04**, **Ubuntu 25.10**
- Installs and configures **certbot** in a managed virtualenv for Let's Encrypt SSL certificates
- Provides an interactive **verify mode** with a 30+ check health-check dashboard
- Takes timestamped backups before every destructive step (database, `/etc/letsencrypt`, `/etc/nginx`, systemd unit, prior install) and auto-prunes older copies
- Renders correctly on minimal LXC consoles and POSIX-locale terminals (auto-detects UTF-8, falls back to clean ASCII glyphs)

## Quick start

```bash
wget -O npm-installer.sh https://raw.githubusercontent.com/njordium/npm-native/main/npm-installer.sh
chmod +x npm-installer.sh
sudo bash npm-installer.sh
```

After installation, access the admin panel at **`http://<your-server-ip>:81`**

On first launch you will see the NPM setup wizard; the pre-filled defaults are `admin@example.com` / `changeme` and you will be required to set your own values before reaching the dashboard.

## Requirements

| Requirement | Minimum |
| ----------- | --------------------------- |
| OS | Debian 12+ or Ubuntu 22.04+ |
| RAM | 2 GB for the frontend build (installer offers to auto-create a swap file on hosts with less) |
| Disk free | ~3 GB on `/` and `/opt` during build; ~500 MB after |
| `python3` | required from the very first step (parses the GitHub releases API, patches vite/tsconfig, formats verify output). Ships with every modern Debian and Ubuntu; installer aborts early with an actionable message if missing |
| Root access | required (systemd unit management, binding ports 80/443, certbot) |

## Usage

```
Usage: sudo bash npm-installer.sh [OPTIONS]

Options:
  --fresh          Fresh install -- wipes existing database (clean slate)
  --update         Update/reinstall -- preserves existing database and configuration
  --verify         Run health checks on the current installation
  --verbose        Show all output from every step (default: quiet)
  --quiet          Show main steps only
  --version <x.y.z>  Pin a specific NPM release (default: latest from GitHub)
  --help, -h       Show this help

Examples:
  sudo bash npm-installer.sh                   # Interactive mode
  sudo bash npm-installer.sh --update --quiet  # Quiet update
  sudo bash npm-installer.sh --verify          # Health check dashboard
  sudo bash npm-installer.sh --fresh --verbose # Fresh install, full output
```

### Environment variables

The script honours a handful of environment overrides for non-interactive or constrained environments:

| Variable | Default | Purpose |
| --- | --- | --- |
| `NPM_VERSION` | latest | Pin the NPM release (alternative to `--version`) |
| `NPM_HOME` | `/opt/nginx-proxy-manager` | Install root |
| `NPM_DATA` | `/data` | Runtime data (database, proxy configs, logs) |
| `NPM_USE_UTF8` | `auto` | `true` / `false` / `auto` -- override glyph rendering detection |
| `NPM_KEEP_BACKUPS` | `2` | How many `${NPM_HOME}.bak-<ts>` copies to keep after a successful install |
| `npm_config_fetch_timeout` | `300000` | pnpm registry request timeout in ms (5 min default) |
| `npm_config_fetch_retries` | `5` | pnpm fetch retry count |
| `npm_config_network_concurrency` | `4` | pnpm parallel-fetch limit (lower on thin pipes) |
| `npm_config_registry` | `registry.npmjs.org` | Use a registry mirror -- e.g. `https://registry.npmmirror.com` |

Example: `sudo npm_config_registry=https://registry.npmmirror.com bash npm-installer.sh --update`

### Interactive mode

Running the script without flags presents a menu when an existing install is detected:

```
  1) Fresh install   -- Full reinstall, wipes database (clean slate)
  2) Update/reinstall -- Reinstall NPM, database preserved
  3) Verify install  -- Run health checks on the current installation
  q) Quit
```

Depending on the chosen mode, the script may also ask:

- **System upgrade prompt** (both fresh and update) -- "Run apt update && apt upgrade before installing? [y/N]"
- **Restore from backup** (fresh only, when a prior `database.sqlite.bak.*` exists) -- "Restore this backup instead of a fresh install? [y/N]". Accepting switches the flow to update mode with the restored database in place.
- **Pre-update backup prune** -- if more than 30 days of stale backups are detected, "Prune N backup(s) older than 30 days now? [y/N]"
- **Version-jump menu** -- if `--update` resolves to a different minor/major than the installed version, a three-way prompt offers Proceed / Abort-and-pin / Specify a different version (with `x.y.z` validation)
- **Diagnostic bundle** (verify mode only) -- "Save diagnostic bundle to /var/backups/npm-diag-<ts>.tar.gz? [Y/n]"

---

## What gets installed

| Component | Location |
| -------------------- | ------------------------------------------------- |
| NPM backend | `/opt/nginx-proxy-manager/backend/` |
| NPM frontend (built) | `/opt/nginx-proxy-manager/frontend/` |
| pnpm workspace config | `/opt/nginx-proxy-manager/backend/pnpm-workspace.yaml` |
| Data & config | `/data/` |
| SQLite database | `/data/database.sqlite` |
| nginx config | `/etc/nginx/nginx.conf` |
| systemd service | `/etc/systemd/system/nginx-proxy-manager.service` |
| Certbot virtualenv | `/opt/certbot/` |
| Let's Encrypt config | `/etc/letsencrypt.ini` |
| Certbot work dir | `/tmp/letsencrypt-lib/` |
| ACME webroot | `/data/letsencrypt-acme-challenge/` |
| Logs | `/data/logs/` |

### Backups (created automatically)

Every install / update writes timestamped snapshots so a broken upgrade is recoverable without an external backup:

| Snapshot | Location |
| --- | --- |
| Database | `/data/database.sqlite.bak.<timestamp>` |
| Let's Encrypt state | `/etc/letsencrypt.bak-<timestamp>/` |
| `/etc/nginx` tarball | `/var/backups/etc-nginx.bak-<timestamp>.tar.gz` |
| systemd unit | `/etc/systemd/system/nginx-proxy-manager.service.bak-<timestamp>` |
| Previous install dir | `/opt/nginx-proxy-manager.bak-<timestamp>` (pruned to `NPM_KEEP_BACKUPS`) |
| Failed-build log | `/var/log/npm-build-failed.log` (only on failure) |
| Diagnostic bundle | `/var/backups/npm-diag-<timestamp>.tar.gz` (only via `--verify`) |

Restore `/etc/nginx` with `sudo tar -xzf /var/backups/etc-nginx.bak-<ts>.tar.gz -C /`. Other backups can be moved back into place with `cp` / `mv`.

---

## Verify mode

```bash
sudo bash npm-installer.sh --verify
```

Produces a dashboard similar to (UTF-8 terminal -- ASCII fallback is used automatically on POSIX-locale or minimal consoles):

```
╔══════════════════════════════════════════════════════════════╗
║   Nginx Proxy Manager — Installation Verification            ║
╚══════════════════════════════════════════════════════════════╝
  Host: myserver   IP: 192.168.1.10   2026-06-24 10:00:00
── Services ──
  [PASS] nginx-proxy-manager  active  PID=1234  MEM=132MB
  [PASS] nginx                active  (nginx/1.26.3)
  [PASS] nginx config         syntax OK
── Network & API ──
  [PASS] backend process      port 3000 bound (Node.js backend listening)
  [PASS] backend API          http://127.0.0.1:81/api/ -> {status:OK}
  [PASS] admin UI             http://192.168.1.10:81/ -> HTTP 200
  [PASS] version              current=v2.15.1  latest=v2.15.1  up to date
── Setup State ──
  [PASS] admin account        created — setup wizard complete
── File System ──
  [PASS] backend / frontend / locales / database / data dir / production.json
── Native Modules ──
  [PASS] bcrypt / better-sqlite3 load OK
── Configuration ──
  [PASS] db client / db file / nginx proxy / certbot venv / conf.d/include / nginx -t
── Environment ──
  [PASS] disk / /opt /data /var       (8.4G free)
  [PASS] time sync                    systemd-timesyncd active
  [PASS] database integrity           PRAGMA integrity_check = ok
  [PASS] db contents                  3 proxy hosts, 1 users, 2 certificates
── External ──
  [PASS] Let's Encrypt API            reachable
  [PASS] cert proxy.example.com       87 days until expiry (2026-09-19)
  [WARN] cert old.example.com         expires in 14 days (2026-07-08)
══════════════════════════════════════════════════════════════
  31 passed  0 failed  1 warnings  / 32 total checks
  Save diagnostic bundle to /var/backups/npm-diag-<ts>.tar.gz? [Y/n]:
```

Verify thresholds:

- **Disk free**: `< 100 MB` FAIL, `< 1 GB` WARN, otherwise PASS
- **Cert expiry**: expired or `< 7 days` FAIL, `< 30 days` WARN, otherwise PASS
- **Time sync**: any of chronyd / systemd-timesyncd / ntpd / ntp active → PASS, else WARN
- **SQLite**: `PRAGMA integrity_check == "ok"` → PASS

---

## How it works

The script builds NPM entirely from source:

1. **System packages** -- curl, git, nginx, certbot, build-essential, jq, rsync, sqlite3
2. **Node.js 22 LTS** -- via NodeSource repository (includes npm)
3. **Source clone** -- shallow git clone of the target NPM release tag
4. **Frontend build** -- `pnpm install -> pnpm upgrade -> pnpm build` (React/Vite). pnpm fetch tunables raise the registry timeout to 5 min and retries to 5; install calls are wrapped in a 3-attempt exponential-backoff retry to survive transient ECONNRESET / fetch timeouts.
5. **Backend assembly** -- copies backend to `/opt/nginx-proxy-manager/`, installs production dependencies, rebuilds native addons (bcrypt, better-sqlite3)
6. **nginx config** -- self-contained config with the custom variable maps (`$x_forwarded_scheme`, `$x_forwarded_proto`) that NPM's templates require
7. **systemd service** -- installs and enables `nginx-proxy-manager.service`, starts on boot, polls `/api/` until it returns `{status:OK}` (catches silent knex migration failures)

### Build compatibility patches

The NPM source tree requires several patches to build outside of the Docker CI environment:

| Patch | Reason |
|---|---|
| `react-intl` pinned to `~10.1.0` | upstream v8.x deprecated; v9.x removed |
| Locale JSON stubs generated | Crowdin-managed `lang/*.json` files are absent from git; missing files cause TS2307 errors |
| `vite.config.ts` chunk splitting | Default build produces a single 2 MB chunk; split into parallel-loadable vendor chunks |
| `tsconfig.json` test-file exclusion | `tsc && vite build` compiles `*.test.tsx` which references Node.js globals not typed in the browser tsconfig |
| `pnpm store prune` before install | Prior failed installs leave corrupt entries in the global pnpm store; pruning prevents vite hangs on re-runs |
| `pnpm-workspace.yaml` written (both `allowBuilds` for v11 and `onlyBuiltDependencies` for v10) | pnpm v11 removed the `pnpm` field in `package.json`; without the workspace YAML, postinstall scripts for `@parcel/watcher` / `esbuild` / `bcrypt` are blocked |
| `_listen.conf` http2 directive removed on nginx < 1.25.1 | NPM emits `http2 on;` unconditionally; Debian 12's nginx 1.22.1 rejects it, silently rolling back every proxy host config |
| Stale `http2 on/off` lines stripped from `/data/nginx/**/*.conf` on nginx < 1.25.1 | Migrations from Docker (newer nginx) leave existing proxy configs unusable on the host's older nginx |
| Override pins for `glob` / `rimraf` / `tar` / `uuid` in `pnpm-workspace.yaml` | Replaces deprecated transitive deps so `prebuild-install`, `inflight` etc. no longer appear in the install output |

---

## Backup & recovery

### npm-backup.sh (Lite)

A lightweight companion script for backing up and restoring a native NPM installation.

```bash
sudo bash npm-backup.sh --backup              # archive saved next to the script
sudo bash npm-backup.sh --recover <archive>   # restore from archive
```

What gets backed up: `/data/` (proxy hosts, database, keys), `/etc/letsencrypt/` (SSL certificates), and optionally the certbot virtualenv at `/opt/certbot/` (required if you use DNS challenge certificates).

### npm-backrecov.sh (Full)

A multi-platform backup and recovery tool with an interactive menu. Supports NPM Native, PVE LXC (ej52/proxmox-scripts), and Docker installations -- including migration from Docker to Native.

```bash
sudo bash npm-backrecov.sh
```

Features:

- **Interactive menu** -- guided backup and recovery with pre-flight checks
- **Multi-platform** -- backs up NPM Native, PVE LXC, and Docker installations
- **Docker-to-Native migration** -- restore a Docker backup onto a native install
- **MySQL / PostgreSQL support** -- detects and dumps external databases via `mysqldump` or `pg_dump` (auto-reads credentials from container env vars or `production.json`)
- **Archive browser** -- lists available backups with numbered selection for recovery
- **Archive validation** -- verifies integrity and checks for critical files (keys.json, database) before restoring

Archives created by either script are fully compatible -- `npm-backup.sh` archives can be restored with `npm-backrecov.sh` and vice versa.

---

## Updating NPM

To update to the latest NPM release while preserving your configuration and all proxy hosts:

```bash
sudo bash npm-installer.sh --update
```

This rebuilds the frontend and backend from the latest upstream source without touching `/data/`. The service is kept running through the entire frontend build and only stopped for the final ~3 min install swap (vs ~10 min in older revisions). If the resolved upstream version crosses a minor or major boundary, an interactive prompt shows the release-notes URL and offers to proceed, abort-and-pin, or specify a different version.

To pin a specific upstream version:

```bash
sudo bash npm-installer.sh --update --version 2.15.1
```

---

## Uninstalling

```bash
sudo systemctl stop nginx-proxy-manager nginx
sudo systemctl disable nginx-proxy-manager
sudo rm -f /etc/systemd/system/nginx-proxy-manager.service
sudo systemctl daemon-reload
sudo rm -rf /opt/nginx-proxy-manager
# Optionally remove install backups:
# sudo rm -rf /opt/nginx-proxy-manager.bak-*
# Optionally remove data (proxy hosts, SSL certs, users):
# sudo rm -rf /data
# Optionally remove the auto-created backups:
# sudo rm -rf /etc/letsencrypt.bak-*
# sudo rm -f  /var/backups/etc-nginx.bak-*.tar.gz
# sudo rm -f  /etc/systemd/system/nginx-proxy-manager.service.bak-*
```

---

## Troubleshooting

**NPM web UI not accessible after reboot**
```bash
sudo systemctl status nginx nginx-proxy-manager
sudo systemctl start nginx
sudo systemctl start nginx-proxy-manager
```

**nginx config fails**
```bash
sudo nginx -t
```

**Check NPM backend logs**
```bash
sudo journalctl -u nginx-proxy-manager -n 50 --no-pager
```

**SSL certificate request fails**

Ensure port 80 is open and reachable from the internet for HTTP-01 ACME challenges. Check `/data/logs/` for certbot output. `--verify` will also report whether the host can reach `acme-v02.api.letsencrypt.org`.

**Frontend build failed**

The last build log is preserved at `/var/log/npm-build-failed.log`. Re-run with `--verbose` for live output, or share the file when reporting the issue.

**`pnpm install` fails with `ERR_PNPM_META_FETCH_FAIL` / `ECONNRESET`**

The script raises pnpm's fetch timeout to 5 min and retries to 5, with a 3-attempt outer retry. For persistently slow links, try a mirror: `sudo npm_config_registry=https://registry.npmmirror.com bash npm-installer.sh --update`.

**Output is full of `???` characters**

Your terminal is rendering UTF-8 bytes as question marks (commonly seen on LXC / serial consoles or POSIX-locale SSH sessions). Force the ASCII fallback for one run with `sudo NPM_USE_UTF8=false bash npm-installer.sh --verify`; the script also auto-detects this when `LC_ALL` / `LANG` are not `*.UTF-8`.

**Generate a diagnostic bundle for issue reports**

`sudo bash npm-installer.sh --verify` ends with a prompt offering to save `/var/backups/npm-diag-<ts>.tar.gz` containing service journal tails, `/data/logs/` tails, `production.json`, `package.json`, `nginx -T` output, and a `system-info.txt`. Attach it when opening a GitHub issue.

---

## Contributing

Pull requests are welcome. For significant changes please open an issue first to discuss the approach.

Please test against both Debian and Ubuntu before submitting.

---

## License

[MIT](LICENSE) -- free to use, modify, and distribute. Attribution appreciated but not required.

---

*Giving back to the open source community that makes our work possible.*

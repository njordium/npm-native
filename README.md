**A native Bash installer for [Nginx Proxy Manager](https://nginxproxymanager.com/) on Debian and Ubuntu -- no Docker required.**

<img width="945" height="767" alt="native-npm-installer" src="https://github.com/user-attachments/assets/a9a28be8-9a37-464f-a889-b8c137efca33" />

## Why this exists

Most Nginx Proxy Manager installation guides assume Docker. The official project ships as a Docker image, and the popular [Proxmox Community Scripts](https://community-scripts.github.io/ProxmoxVE/) LXC installer still pulls a Docker image inside the container. If you want NPM running natively on bare Debian or Ubuntu -- managed by systemd, backed by SQLite, with no container layer -- there was no clean, maintained path to get there.

This script fills that gap.

## What it does

- Installs **Nginx Proxy Manager v2.x** (latest release auto-detected) natively on the host OS
- Manages everything with **systemd** -- auto-starts on boot, restarts on failure
- Uses **SQLite** via `better-sqlite3` -- no external database required
- Builds the frontend from source with **pnpm** -- no Docker, no pre-built image
- Supports **Debian 12 (Bookworm)**, **Debian 13 (Trixie)**, **Ubuntu 22.04**, **Ubuntu 24.04**
- Installs and configures **certbot** for Let's Encrypt SSL certificates
- Provides an interactive **verify mode** with a full health-check dashboard

## Quick start

```bash
wget -O npm-installer.sh https://github.com/njordium/npm-native/blob/main/npm-installer.sh
chmod +x npm-installer.sh
sudo bash npm-installer.sh
```

After installation, access the admin panel at **`http://<your-server-ip>:81`**

Default credentials on first run: `admin@example.com` / `changeme` (you will be prompted to change these immediately).

## Requirements

| Requirement | Minimum |
| ----------- | --------------------------- |
| OS | Debian 12+ or Ubuntu 22.04+ |
| RAM | 2 GB (required for frontend build) |

## Usage

```
Usage: sudo bash npm-installer.sh [OPTIONS]

Options:
  --fresh          Fresh install -- wipes existing database (clean slate)
  --update         Update/reinstall -- preserves existing database and configuration
  --verify         Run health checks on the current installation
  --verbose        Show all output from every step (default: quiet)
  --quiet          Show main steps only
  --version <x.y.z>  Pin a specific NPM release (default: latest)
  --help, -h       Show this help

Examples:
  sudo bash npm-installer.sh                   # Interactive mode
  sudo bash npm-installer.sh --update --quiet  # Quiet update
  sudo bash npm-installer.sh --verify          # Health check dashboard
  sudo bash npm-installer.sh --fresh --verbose # Fresh install, full output
```

### Interactive mode

Running the script without flags presents a menu:

```
  1) Fresh install   -- Full reinstall, wipes database (clean slate)
  2) Update/reinstall -- Reinstall NPM, database preserved
  3) Verify install  -- Run health checks on the current installation
  q) Quit
```

---

## What gets installed

| Component | Location |
| -------------------- | ------------------------------------------------- |
| NPM backend | `/opt/nginx-proxy-manager/backend/` |
| NPM frontend (built) | `/opt/nginx-proxy-manager/frontend/` |
| Data & config | `/data/` |
| SQLite database | `/data/database.sqlite` |
| nginx config | `/etc/nginx/nginx.conf` |
| systemd service | `/etc/systemd/system/nginx-proxy-manager.service` |
| Let's Encrypt config | `/etc/letsencrypt.ini` |
| Certbot work dir | `/tmp/letsencrypt-lib/` |
| ACME webroot | `/data/letsencrypt-acme-challenge/` |
| Logs | `/data/logs/` |

---

## Verify mode

```bash
sudo bash npm-installer.sh --verify
```

Produces a dashboard similar to:

```
+--------------------------------------------------------------+
|   Nginx Proxy Manager -- Installation Verification            |
+--------------------------------------------------------------+
  Host: myserver   IP: 192.168.1.10   2026-03-30 10:00:00
-- Services --
  [PASS] nginx-proxy-manager  active  PID=1234  MEM=132MB
  [PASS] nginx-proxy-manager  enabled (auto-starts on reboot)
  [PASS] nginx               active  (nginx/1.26.3)
  [PASS] nginx config        syntax OK
-- Network & API --
  [PASS] backend process     port 3000 bound (Node.js backend listening)
  [PASS] backend API         http://127.0.0.1:81/api/ -> {status:OK}
  [PASS] admin UI            http://192.168.1.10:81/ -> HTTP 200
  [PASS] admin UI            serving HTML (React SPA)
```

---

## How it works

The script builds NPM entirely from source:

1. **System packages** -- curl, git, nginx, certbot, build-essential, jq, rsync
2. **Node.js 22 LTS** -- via NodeSource repository (includes npm)
3. **Source clone** -- shallow git clone of the target NPM release tag
4. **Frontend build** -- `pnpm install -> pnpm upgrade -> pnpm build` (React/Vite)
5. **Backend assembly** -- copies backend to `/opt/nginx-proxy-manager/`, installs production dependencies, rebuilds native addons (bcrypt, better-sqlite3)
6. **nginx config** -- self-contained config with the custom variable maps (`$x_forwarded_scheme`, `$x_forwarded_proto`) that NPM's templates require
7. **systemd service** -- installs and enables `nginx-proxy-manager.service`, starts on boot

### Build compatibility patches

The NPM source tree requires several patches to build outside of the Docker CI environment:

| Patch | Reason |
|---|---|
| `react-intl` pinned to `^10.0.0` | v8.x deprecated; v9.x broken/removed |
| Locale JSON stubs generated | Crowdin-managed `lang/*.json` files are absent from git; missing files cause TS2307 errors |
| `vite.config.ts` chunk splitting | Default build produces a single 2 MB chunk; split into parallel-loadable vendor chunks |
| `tsconfig.json` test-file exclusion | `tsc && vite build` compiles `*.test.tsx` which references Node.js globals not typed in the browser tsconfig |
| pnpm store prune before install | Prior failed installs leave corrupt entries in the global pnpm store; pruning prevents vite hangs on re-runs |

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

This rebuilds the frontend and backend from the latest upstream source without touching `/data/`.

---

## Uninstalling

```bash
sudo systemctl stop nginx-proxy-manager nginx
sudo systemctl disable nginx-proxy-manager
sudo rm -f /etc/systemd/system/nginx-proxy-manager.service
sudo systemctl daemon-reload
sudo rm -rf /opt/nginx-proxy-manager
# Optionally remove data (proxy hosts, SSL certs, users):
# sudo rm -rf /data
```

---

## Verifying your installation

After installing, use the built-in verify mode to confirm everything is working:

```bash
sudo bash npm-installer.sh --verify
```

This produces a full health-check dashboard covering services, network, API, SSL, configuration, and more -- no separate tool needed.

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

Ensure port 80 is open and reachable from the internet for HTTP-01 ACME challenges. Check `/data/logs/` for certbot output.

---

## Contributing

Pull requests are welcome. For significant changes please open an issue first to discuss the approach.

Please test against both Debian and Ubuntu before submitting.

---

## License

[MIT](LICENSE) -- free to use, modify, and distribute. Attribution appreciated but not required.

---

*Giving back to the open source community that makes our work possible.*

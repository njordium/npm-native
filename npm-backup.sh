#!/usr/bin/env bash
# =============================================================================
#  npm-backup.sh — Nginx Proxy Manager Native Backup & Recovery (Lite)
#  NPM Native only  |  SQLite  |  Systemd  |  Team Njordium
#  Authors: Kim Haverblad & Tommy Jansson
#
#  Usage:
#    sudo bash npm-backup.sh --backup            Create backup in script directory
#    sudo bash npm-backup.sh --recover <file>    Restore from archive
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# NPM Native paths
# ---------------------------------------------------------------------------
NATIVE_DATA_DIR="/data"
NATIVE_LETSENCRYPT_DIR="/etc/letsencrypt"
NATIVE_CERTBOT_VENV_DIR="/opt/certbot"
NATIVE_SERVICE="nginx-proxy-manager"
NATIVE_NGINX_SERVICE="nginx"

MANIFEST_FILE="manifest.txt"
DATA_SUBDIR="data"
LETSENCRYPT_SUBDIR="letsencrypt"
CERTBOT_VENV_SUBDIR="certbot-venv"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'

_pok()   { echo -e "  ${GREEN}[PASS]${NC} $*"; }
_pdone() { echo -e "  ${GREEN}[DONE]${NC} $*"; }
_pfail() { echo -e "  ${RED}[FAIL]${NC} $*"; }
_pwarn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
_pskip() { echo -e "  ${DIM}[SKIP]${NC} $*"; }
_pinfo() { echo -e "  ${CYAN}[INFO]${NC} $*"; }
_sep()   { echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"; }
die()    { echo -e "\n  ${RED}✗ ERROR:${NC} $*\n" >&2; exit 1; }
section(){ echo -e "\n${BOLD}── $* ──${NC}"; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && die "This script must be run as root."

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
timestamp()     { date '+%Y-%m-%d-%H%M%S'; }
datestamp()     { date '+%Y-%m-%d %H:%M:%S'; }
native_is_running() { systemctl is-active --quiet "${NATIVE_SERVICE}" 2>/dev/null; }

# Global cleanup path — set by do_backup/do_recover, used by EXIT trap
_CLEANUP_DIR=""
_cleanup() { [[ -n "${_CLEANUP_DIR}" ]] && rm -rf "${_CLEANUP_DIR}"; }
trap _cleanup EXIT

copy_dir() {
    local src="$1" dst="$2"
    if command -v rsync &>/dev/null; then
        rsync -a "${src}/" "${dst}/"
    else
        mkdir -p "${dst}"
        cp -a "${src}/." "${dst}/"
    fi
}

write_manifest() {
    local type="$1" staging_dir="$2"
    local npm_ver="unknown"
    if [[ -f "${NATIVE_DATA_DIR}/database.sqlite" ]]; then
        npm_ver=$(strings "${NATIVE_DATA_DIR}/database.sqlite" 2>/dev/null \
            | grep -oP 'nginx-proxy-manager@\K[\d.]+' | head -1 || echo "unknown")
    fi
    cat > "${staging_dir}/${MANIFEST_FILE}" << MANIFEST
npm-backrecov manifest
======================
Script version : ${SCRIPT_VERSION}
Backup type    : ${type}
Created        : $(datestamp)
Hostname       : $(hostname)
OS             : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
NPM version    : ${npm_ver}
Keys.json      : INCLUDED — keep this file secret; without it the database cannot be decrypted
MANIFEST
}

extract_archive() {
    local archive="$1"
    [[ -f "${archive}" ]] || die "Archive not found: ${archive}"
    [[ "${archive}" == *.tar.gz ]] || die "Expected a .tar.gz archive"
    local staging
    staging=$(mktemp -d /tmp/npm-restore-staging.XXXXXX)
    _pinfo "Extracting archive..." >&2
    tar -xzf "${archive}" -C "${staging}" || die "Failed to extract archive — file may be corrupt"
    local inner
    inner=$(find "${staging}" -mindepth 1 -maxdepth 1 -type d | head -1)
    [[ -d "${inner}" ]] || die "Archive structure unexpected — no subdirectory found inside"
    echo "${inner}"
}

# ---------------------------------------------------------------------------
# --backup
# ---------------------------------------------------------------------------
do_backup() {
    section "Backup — NPM Native"

    local archive="${SCRIPT_DIR}/npm-backup-$(timestamp).tar.gz"

    # Pre-flight
    echo ""
    echo -e "  ${BOLD}Pre-flight checks${NC}"
    _sep
    local pass=0 fail=0 warn=0

    if [[ -d "${NATIVE_DATA_DIR}" ]] && [[ -n "$(ls -A "${NATIVE_DATA_DIR}" 2>/dev/null)" ]]; then
        _pok  "/data/ exists and contains data"; (( pass++ )) || true
    else
        _pfail "/data/ not found or empty — nothing to back up"; (( fail++ )) || true
    fi

    if [[ -f "${NATIVE_DATA_DIR}/keys.json" ]]; then
        _pok  "keys.json present"; (( pass++ )) || true
    else
        _pfail "keys.json not found — backup will be unusable without it"; (( fail++ )) || true
    fi

    if [[ -f "${NATIVE_DATA_DIR}/database.sqlite" ]]; then
        local db_size; db_size=$(du -h "${NATIVE_DATA_DIR}/database.sqlite" | cut -f1)
        _pok  "database.sqlite present (${db_size})"; (( pass++ )) || true
    else
        _pwarn "database.sqlite not found (may use external DB)"; (( warn++ )) || true
    fi

    if native_is_running; then
        _pwarn "NPM is running — backup safe (SQLite WAL) but stop for full consistency"
        (( warn++ )) || true
    else
        _pok  "NPM service stopped — clean consistent backup"; (( pass++ )) || true
    fi

    command -v tar &>/dev/null && { _pok "tar available"; (( pass++ )) || true; } \
        || { _pfail "tar not found"; (( fail++ )) || true; }

    _sep
    echo -e "  ${BOLD}Checks:${NC}  ${GREEN}${pass} passed${NC}  ${RED}${fail} failed${NC}  ${YELLOW}${warn} warnings${NC}"
    echo ""
    [[ ${fail} -eq 0 ]] || die "Pre-flight checks failed."

    _pinfo "Output: ${archive}"
    echo ""

    local staging
    staging=$(mktemp -d /tmp/npm-backup-staging.XXXXXX)
    _CLEANUP_DIR="${staging}"

    # Step 1: Manifest
    echo -e "  ${BOLD}Step 1/5 — Manifest${NC}"
    write_manifest "NATIVE" "${staging}"
    _pdone "Manifest written"

    # Step 2: /data/
    echo ""
    echo -e "  ${BOLD}Step 2/5 — Backing up /data/${NC}"
    mkdir -p "${staging}/${DATA_SUBDIR}"
    if command -v rsync &>/dev/null; then
        rsync -a --exclude="*.log" --exclude="*.log.*" \
            "${NATIVE_DATA_DIR}/" "${staging}/${DATA_SUBDIR}/"
    else
        cp -a "${NATIVE_DATA_DIR}/." "${staging}/${DATA_SUBDIR}/"
        find "${staging}/${DATA_SUBDIR}" -name "*.log" -delete 2>/dev/null || true
    fi
    local data_size; data_size=$(du -sh "${staging}/${DATA_SUBDIR}" | cut -f1)
    _pdone "/data/ copied (${data_size})"
    [[ -f "${staging}/${DATA_SUBDIR}/keys.json" ]]       && _pok "keys.json verified"
    [[ -f "${staging}/${DATA_SUBDIR}/database.sqlite" ]] && _pok "database.sqlite verified"

    # Step 3: /etc/letsencrypt/
    echo ""
    echo -e "  ${BOLD}Step 3/5 — Backing up /etc/letsencrypt/${NC}"
    if [[ -d "${NATIVE_LETSENCRYPT_DIR}" ]]; then
        mkdir -p "${staging}/${LETSENCRYPT_SUBDIR}"
        copy_dir "${NATIVE_LETSENCRYPT_DIR}" "${staging}/${LETSENCRYPT_SUBDIR}"
        local le_size cert_count
        le_size=$(du -sh "${staging}/${LETSENCRYPT_SUBDIR}" | cut -f1)
        cert_count=$(find "${staging}/${LETSENCRYPT_SUBDIR}/live" -name "fullchain.pem" 2>/dev/null | wc -l)
        _pdone "/etc/letsencrypt/ copied (${le_size}, ${cert_count} cert(s))"
    else
        _pskip "/etc/letsencrypt/ not found — skipped"
    fi

    # Step 4: certbot venv (DNS challenge plugins)
    # The certbot virtualenv at /opt/certbot/ contains certbot plus any DNS provider
    # plugins (e.g. certbot-dns-cloudflare). Without it DNS-01 challenges cannot renew
    # on a new/restored server. HTTP-01 certs (port 80) work without it.
    echo ""
    echo -e "  ${BOLD}Step 4/5 — certbot venv (DNS challenge plugins)${NC}"
    if [[ -d "${NATIVE_CERTBOT_VENV_DIR}" ]]; then
        local venv_size
        venv_size=$(du -sh "${NATIVE_CERTBOT_VENV_DIR}" 2>/dev/null | cut -f1)
        _pinfo "certbot venv found (${venv_size}) — contains certbot + any DNS plugins"
        echo ""
        local include_venv
        printf "  ${CYAN}?${NC} Include certbot venv in backup? [y/N]: " >&2
        IFS= read -r include_venv </dev/tty || include_venv=""
        if [[ "${include_venv,,}" == "y" || "${include_venv,,}" == "yes" ]]; then
            mkdir -p "${staging}/${CERTBOT_VENV_SUBDIR}"
            copy_dir "${NATIVE_CERTBOT_VENV_DIR}" "${staging}/${CERTBOT_VENV_SUBDIR}"
            _pdone "certbot venv included (${venv_size})"
        else
            _pskip "certbot venv excluded — DNS plugins must be reinstalled manually after recovery"
        fi
    else
        _pskip "certbot venv not found (/opt/certbot/) — skipped"
    fi

    # Step 5: Archive
    echo ""
    echo -e "  ${BOLD}Step 5/5 — Creating archive${NC}"
    if tar -czf "${archive}" -C "$(dirname "${staging}")" "$(basename "${staging}")" 2>/dev/null; then
        local arc_size; arc_size=$(du -sh "${archive}" | cut -f1)
        _pdone "Archive created (${arc_size}): $(basename "${archive}")"
    else
        _pfail "tar failed — archive not created"
        exit 1
    fi

    # Verify
    if tar -tzf "${archive}" &>/dev/null; then
        _pok  "Archive integrity verified"
        local arc_list; arc_list=$(tar -tzf "${archive}" 2>/dev/null)
        local missing_critical=false
        echo "${arc_list}" | grep -q "manifest.txt" \
            && _pok "manifest.txt present" \
            || { _pfail "manifest.txt MISSING — deleting corrupt archive"; missing_critical=true; }
        echo "${arc_list}" | grep -q "data/keys.json" \
            && _pok "keys.json present" \
            || { _pfail "keys.json MISSING — deleting corrupt archive"; missing_critical=true; }
        if ${missing_critical}; then
            rm -f "${archive}"
            die "Archive is incomplete — backup aborted. Check that /data/ exists and is populated."
        fi
    else
        _pfail "Archive integrity check failed"
        rm -f "${archive}"
        exit 1
    fi

    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  SECURITY NOTICE${NC}"
    echo -e "  ${YELLOW}keys.json is included — store this backup securely.${NC}"
    echo ""
    _pdone "Backup complete: ${archive}"
}

# ---------------------------------------------------------------------------
# --recover <archive>
# ---------------------------------------------------------------------------
do_recover() {
    local archive="$1"
    [[ -n "${archive}" ]] || die "Usage: sudo bash npm-backup.sh --recover <archive.tar.gz>"
    # If not absolute path, look relative to script dir first
    if [[ "${archive}" != /* ]]; then
        [[ -f "${SCRIPT_DIR}/${archive}" ]] && archive="${SCRIPT_DIR}/${archive}"
    fi
    [[ -f "${archive}" ]] || die "Archive not found: ${archive}"

    section "Recovery — NPM Native"

    local staging
    staging=$(extract_archive "${archive}")
    local staging_root; staging_root=$(dirname "${staging}")
    _CLEANUP_DIR="${staging_root}"

    # Show manifest
    if [[ -f "${staging}/${MANIFEST_FILE}" ]]; then
        echo ""
        echo -e "${DIM}$(cat "${staging}/${MANIFEST_FILE}")${NC}"
        echo ""
    else
        _pwarn "No manifest in archive — may be from a failed or incomplete backup run"
    fi

    # Pre-flight
    echo -e "  ${BOLD}Pre-flight checks${NC}"
    _sep
    local pass=0 fail=0 warn=0

    [[ -f "${staging}/${MANIFEST_FILE}" ]] \
        && { _pok "manifest.txt found"; (( pass++ )) || true; } \
        || { _pwarn "No manifest — archive origin unknown"; (( warn++ )) || true; }

    if [[ -d "${staging}/${DATA_SUBDIR}" ]]; then
        _pok  "data/ present in archive"; (( pass++ )) || true
    else
        _pfail "data/ missing — this archive appears to be from a failed backup run"; (( fail++ )) || true
    fi

    if [[ -f "${staging}/${DATA_SUBDIR}/keys.json" ]]; then
        _pok  "keys.json present in archive"; (( pass++ )) || true
    else
        _pfail "keys.json missing — restored NPM cannot decrypt the database"; (( fail++ )) || true
    fi

    if [[ -f "${staging}/${DATA_SUBDIR}/database.sqlite" ]]; then
        local db_size; db_size=$(du -h "${staging}/${DATA_SUBDIR}/database.sqlite" | cut -f1)
        _pok  "database.sqlite present (${db_size})"; (( pass++ )) || true
    else
        _pwarn "database.sqlite not in archive (may use external DB)"; (( warn++ )) || true
    fi

    if [[ -d "${staging}/${LETSENCRYPT_SUBDIR}" ]]; then
        local cert_count
        cert_count=$(find "${staging}/${LETSENCRYPT_SUBDIR}/live" -name "fullchain.pem" 2>/dev/null | wc -l)
        _pok  "letsencrypt/ present (${cert_count} cert(s))"; (( pass++ )) || true
    else
        _pwarn "letsencrypt/ not in archive — SSL certs will not be restored"; (( warn++ )) || true
    fi

    if [[ -f "/opt/nginx-proxy-manager/backend/package.json" ]]; then
        _pok  "NPM native installation detected"; (( pass++ )) || true
    else
        _pwarn "NPM native install not detected — run npm-installer.sh first"; (( warn++ )) || true
    fi

    _sep
    echo -e "  ${BOLD}Checks:${NC}  ${GREEN}${pass} passed${NC}  ${RED}${fail} failed${NC}  ${YELLOW}${warn} warnings${NC}"
    echo ""
    [[ ${fail} -eq 0 ]] || die "Pre-flight checks failed. Archive appears incomplete or corrupt."

    echo -e "  ${YELLOW}${BOLD}⚠  SECURITY NOTICE${NC}"
    echo -e "  ${YELLOW}Restoring will replace the current encryption key (keys.json).${NC}"
    echo ""

    # Confirm
    local answer
    printf "  ${CYAN}?${NC} Proceed with recovery? [y/N]: " >&2
    IFS= read -r answer </dev/tty || answer=""
    case "${answer,,}" in
        y|yes) ;;
        *) echo ""; _pinfo "Recovery cancelled."; exit 0 ;;
    esac

    # Stop services
    echo ""
    echo -e "  ${BOLD}Stopping services${NC}"
    local was_running=false
    if native_is_running; then
        systemctl stop "${NATIVE_SERVICE}"  2>/dev/null || true
        systemctl stop "${NATIVE_NGINX_SERVICE}" 2>/dev/null || true
        was_running=true
        _pdone "Services stopped"
    else
        _pskip "Services not running"
    fi

    # Step 1: /data/
    echo ""
    echo -e "  ${BOLD}Step 1/4 — Restoring /data/${NC}"
    if [[ -d "${NATIVE_DATA_DIR}" ]] && [[ -n "$(ls -A "${NATIVE_DATA_DIR}" 2>/dev/null)" ]]; then
        _pwarn "Existing /data/ will be overwritten"
    fi
    mkdir -p "${NATIVE_DATA_DIR}"
    if command -v rsync &>/dev/null; then
        rsync -a --delete "${staging}/${DATA_SUBDIR}/" "${NATIVE_DATA_DIR}/"
    else
        # Clean target first to match rsync --delete (remove stale files)
        rm -rf "${NATIVE_DATA_DIR:?}/"*
        cp -a "${staging}/${DATA_SUBDIR}/." "${NATIVE_DATA_DIR}/"
    fi
    _pdone "/data/ restored"
    [[ -f "${NATIVE_DATA_DIR}/keys.json" ]]       && _pok "keys.json in place"
    [[ -f "${NATIVE_DATA_DIR}/database.sqlite" ]] && _pok "database.sqlite in place"

    # Step 2: /etc/letsencrypt/
    echo ""
    echo -e "  ${BOLD}Step 2/4 — Restoring /etc/letsencrypt/${NC}"
    if [[ -d "${staging}/${LETSENCRYPT_SUBDIR}" ]]; then
        mkdir -p "${NATIVE_LETSENCRYPT_DIR}"
        if command -v rsync &>/dev/null; then
            rsync -a --delete "${staging}/${LETSENCRYPT_SUBDIR}/" "${NATIVE_LETSENCRYPT_DIR}/"
        else
            rm -rf "${NATIVE_LETSENCRYPT_DIR:?}/"*
            cp -a "${staging}/${LETSENCRYPT_SUBDIR}/." "${NATIVE_LETSENCRYPT_DIR}/"
        fi
        local cert_count
        cert_count=$(find "${NATIVE_LETSENCRYPT_DIR}/live" -name "fullchain.pem" 2>/dev/null | wc -l)
        _pdone "/etc/letsencrypt/ restored (${cert_count} cert(s))"
    else
        _pskip "letsencrypt/ not in archive — skipped"
    fi

    # Step 3: certbot venv
    echo ""
    echo -e "  ${BOLD}Step 3/4 — Restoring certbot venv${NC}"
    if [[ -d "${staging}/${CERTBOT_VENV_SUBDIR}" ]]; then
        mkdir -p "${NATIVE_CERTBOT_VENV_DIR}"
        if command -v rsync &>/dev/null; then
            rsync -a --delete "${staging}/${CERTBOT_VENV_SUBDIR}/" "${NATIVE_CERTBOT_VENV_DIR}/"
        else
            rm -rf "${NATIVE_CERTBOT_VENV_DIR:?}/"*
            cp -a "${staging}/${CERTBOT_VENV_SUBDIR}/." "${NATIVE_CERTBOT_VENV_DIR}/"
        fi
        _pdone "certbot venv restored (DNS challenge plugins ready)"
    else
        _pskip "certbot venv not in archive — DNS challenge plugins must be reinstalled if needed"
    fi

    # Step 4: Restart services
    echo ""
    echo -e "  ${BOLD}Step 4/4 — Starting services${NC}"
    systemctl daemon-reload 2>/dev/null || true
    systemctl start "${NATIVE_NGINX_SERVICE}" 2>/dev/null || true
    systemctl start "${NATIVE_SERVICE}" 2>/dev/null || true
    sleep 3
    if native_is_running; then
        _pdone "NPM service started"
        _pok  "NPM is running"
    else
        _pfail "NPM did not start — run: systemctl status ${NATIVE_SERVICE}"
    fi
    if systemctl is-active --quiet "${NATIVE_NGINX_SERVICE}" 2>/dev/null; then
        _pok  "nginx is running"
    else
        _pfail "nginx did not start — run: systemctl start ${NATIVE_NGINX_SERVICE}"
    fi

    echo ""
    _pdone "Recovery complete"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    --backup)
        do_backup
        ;;
    --recover)
        do_recover "${2:-}"
        ;;
    --help|-h)
        echo ""
        echo -e "  ${BOLD}npm-backup.sh v${SCRIPT_VERSION}${NC} — NPM Native Backup & Recovery (Lite)"
        echo ""
        echo "  Usage:"
        echo "    sudo bash npm-backup.sh --backup              Create backup in script directory"
        echo "    sudo bash npm-backup.sh --recover <archive>   Restore from archive"
        echo ""
        echo "  Examples:"
        echo "    sudo bash npm-backup.sh --backup"
        echo "    sudo bash npm-backup.sh --recover npm-backup-2026-04-01-120000.tar.gz"
        echo "    sudo bash npm-backup.sh --recover /opt/npm-backups/npm-backup-2026-04-01-120000.tar.gz"
        echo ""
        ;;
    *)
        echo ""
        echo -e "  ${BOLD}npm-backup.sh${NC} — NPM Native Backup & Recovery (Lite)"
        echo ""
        echo "  Usage: sudo bash npm-backup.sh [--backup | --recover <archive>]"
        echo "  Run with --help for details."
        echo ""
        exit 1
        ;;
esac

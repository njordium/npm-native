#!/usr/bin/env bash
# =============================================================================
#  npm-backrecov.sh — Nginx Proxy Manager Backup & Recovery Tool v1.0.0
#  Supports NPM Native and NPM Docker installations
#  Enables migration from NPM Docker → NPM Native
#  No Docker  |  SQLite  |  Systemd  |  Team Njordium
#  Authors: Kim Haverblad & Tommy Jansson
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Script version & constants
# ---------------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
DEFAULT_BACKUP_DIR="/opt/npm-backups"

NATIVE_DATA_DIR="/data"
NATIVE_LETSENCRYPT_DIR="/etc/letsencrypt"
NATIVE_CERTBOT_VENV_DIR="/opt/certbot"
NATIVE_SERVICE="nginx-proxy-manager"
NATIVE_NGINX_SERVICE="nginx"

# PVE LXC (ej52/proxmox-scripts) — data paths identical to native,
# but uses OpenResty and service name is 'npm'
LXC_APP_DIR="/app"
LXC_DATA_DIR="/data"
LXC_LETSENCRYPT_DIR="/etc/letsencrypt"
LXC_CERTBOT_VENV_DIR="/opt/certbot"
LXC_SERVICE="npm"
LXC_OPENRESTY_SERVICE="openresty"

DOCKER_DATA_DIR=""
DOCKER_LETSENCRYPT_DIR=""
DOCKER_CONTAINER_NAME=""

MANIFEST_FILE="manifest.txt"
DATA_SUBDIR="data"
LETSENCRYPT_SUBDIR="letsencrypt"
CERTBOT_VENV_SUBDIR="certbot-venv"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'

# Output helpers
_pok()   { echo -e "  ${GREEN}[PASS]${NC} $*"; }
_pdone() { echo -e "  ${GREEN}[DONE]${NC} $*"; }
_pfail() { echo -e "  ${RED}[FAIL]${NC} $*"; }
_pwarn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
_pskip() { echo -e "  ${DIM}[SKIP]${NC} $*"; }
_pinfo() { echo -e "  ${CYAN}[INFO]${NC} $*"; }

die()     { echo -e "\n  ${RED}✗ ERROR:${NC} $*\n" >&2; exit 1; }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

# Ask helper — printf the prompt so ANSI codes render correctly,
# then read the answer on the same line.
ask() {
    local prompt="$1" default="${2:-}" answer
    if [[ -t 0 ]]; then
        # printf MUST go to stderr — ask() is always called inside $()
        # which captures stdout. Without >&2 the prompt is swallowed into
        # the variable instead of being displayed on the terminal.
        printf "  ${CYAN}?${NC} %s%s: " "${prompt}" "${default:+ [${default}]}" >&2
        IFS= read -r answer </dev/tty || answer=""
    else
        answer="${default}"
    fi
    echo "${answer:-${default}}"
}

# Yes/no confirm
confirm() {
    local prompt="$1" answer
    while true; do
        answer=$(ask "${prompt} [y/N]" "n")
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no|"") return 1 ;;
            *) _pwarn "Please answer y or n." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && die "This script must be run as root."

# Global cleanup path — set by backup/recover functions, used by EXIT trap
_CLEANUP_DIR=""
_cleanup() { [[ -n "${_CLEANUP_DIR}" ]] && rm -rf "${_CLEANUP_DIR}"; }
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Splash screen
# ---------------------------------------------------------------------------
show_splash() {
    clear
    echo -e "${BOLD}${CYAN}"
    printf "    _   ____  __  ___\n"
    printf "   / | / / /_  __/  |/ /___ _____  ____ _____ __________\n"
    printf "  /  |/ / __ \\/ // /|_/ / __ \`/ __ \\/ __ \`/ __ \`/ _ \\/ ___/\n"
    printf " / /|  / /_/ / // /  / / /_/ / / / / /_/ / /_/ /  __/ /\n"
    printf "/_/ |_/\\_, /_//_/  /_/\\__,_/_/ /_/\\__,_/\\__, /\\___/_/\n"
    printf "       /___/                            /____/  v%s\n" "${SCRIPT_VERSION}"
    echo -e "${NC}"
    echo -e "  ${BOLD}${GREEN}Nginx Proxy Manager${NC}${BOLD} — Backup & Recovery Tool${NC}"
    echo -e "  ${DIM}No Docker · SQLite · Systemd · Team Njordium${NC}"
    echo -e "  ${DIM}---------------------------------------------${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Timestamp helpers
# ---------------------------------------------------------------------------
timestamp() { date '+%Y-%m-%d-%H%M%S'; }
datestamp()  { date '+%Y-%m-%d %H:%M:%S'; }

# ---------------------------------------------------------------------------
# Pre-check helpers
# ---------------------------------------------------------------------------

# Separator line
_sep() { echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"; }

# Print pre-check section header
precheck_header() {
    echo ""
    echo -e "  ${BOLD}Pre-flight checks${NC}"
    _sep
}

# Print pre-check summary
precheck_summary() {
    local pass="$1" fail="$2" warn="$3"
    _sep
    echo -e "  ${BOLD}Checks:${NC}  ${GREEN}${pass} passed${NC}  ${RED}${fail} failed${NC}  ${YELLOW}${warn} warnings${NC}"
    echo ""
}

# Run all pre-checks for a native backup
prechecks_backup_native() {
    local pass=0 fail=0 warn=0

    precheck_header

    # /data/ exists and is not empty
    if [[ -d "${NATIVE_DATA_DIR}" ]] && [[ -n "$(ls -A "${NATIVE_DATA_DIR}" 2>/dev/null)" ]]; then
        _pok  "/data/ exists and contains data"
        (( pass++ )) || true
    else
        _pfail "/data/ not found or empty — nothing to back up"
        (( fail++ )) || true
    fi

    # database.sqlite — warn if missing but don't hard-fail (external DB is valid)
    if [[ -f "${NATIVE_DATA_DIR}/database.sqlite" ]]; then
        local db_size
        db_size=$(du -h "${NATIVE_DATA_DIR}/database.sqlite" | cut -f1)
        _pok  "database.sqlite present (${db_size})"
        (( pass++ )) || true
    else
        _pwarn "database.sqlite not found — native install normally uses SQLite; verify this is expected"
        (( warn++ )) || true
    fi

    # keys.json exists
    if [[ -f "${NATIVE_DATA_DIR}/keys.json" ]]; then
        _pok  "keys.json present (encryption key included in backup)"
        (( pass++ )) || true
    else
        _pfail "keys.json not found — backup will be unusable without it"
        (( fail++ )) || true
    fi

    # /etc/letsencrypt/ has live certs
    if [[ -d "${NATIVE_LETSENCRYPT_DIR}/live" ]] && \
       [[ -n "$(ls -A "${NATIVE_LETSENCRYPT_DIR}/live" 2>/dev/null)" ]]; then
        local cert_count
        cert_count=$(find "${NATIVE_LETSENCRYPT_DIR}/live" -name "fullchain.pem" 2>/dev/null || true | wc -l)
        _pok  "/etc/letsencrypt/live/ found (${cert_count} certificate(s))"
        (( pass++ )) || true
    elif [[ -d "${NATIVE_LETSENCRYPT_DIR}" ]]; then
        _pwarn "/etc/letsencrypt/ exists but no live certs found (no SSL certs to back up)"
        (( warn++ )) || true
    else
        _pwarn "/etc/letsencrypt/ not found — SSL certs will not be included"
        (( warn++ )) || true
    fi

    # certbot venv
    if [[ -f "${NATIVE_CERTBOT_VENV_DIR}/bin/activate" ]]; then
        local cb_ver
        cb_ver=$("${NATIVE_CERTBOT_VENV_DIR}/bin/certbot" --version 2>&1 | grep -oP '[\d.]+' | head -1 || echo "?")
        _pok  "/opt/certbot venv present (certbot v${cb_ver})"
        (( pass++ )) || true
    else
        _pwarn "/opt/certbot venv not found — DNS plugin state will not be backed up"
        (( warn++ )) || true
    fi

    # NPM service state
    if systemctl is-active --quiet "${NATIVE_SERVICE}" 2>/dev/null; then
        _pwarn "NPM service is running — backup safe (SQLite WAL) but stop for full consistency"
        (( warn++ )) || true
    else
        _pok  "NPM service is stopped — clean consistent backup"
        (( pass++ )) || true
    fi

    # rsync or cp required for file operations
    if command -v rsync &>/dev/null; then
        _pok  "rsync available"
        (( pass++ )) || true
    elif command -v cp &>/dev/null; then
        _pok  "cp available — rsync not installed, will use cp -a"
        (( pass++ )) || true
    else
        _pfail "neither rsync nor cp found — cannot back up files"
        (( fail++ )) || true
    fi

    # tar and gzip — required for archive creation
    if command -v tar &>/dev/null; then
        _pok  "tar available ($(tar --version 2>&1 | head -1))"
        (( pass++ )) || true
    else
        _pfail "tar not found — install with: apt-get install tar"
        (( fail++ )) || true
    fi
    if command -v gzip &>/dev/null; then
        _pok  "gzip available ($(gzip --version 2>&1 | head -1))"
        (( pass++ )) || true
    else
        _pfail "gzip not found — install with: apt-get install gzip"
        (( fail++ )) || true
    fi

    # Verify backup destination is writable
    if [[ -w "$(dirname "${DEFAULT_BACKUP_DIR}")" ]] || [[ -w "${DEFAULT_BACKUP_DIR}" ]] 2>/dev/null; then
        _pok  "Backup destination parent directory is writable"
        (( pass++ )) || true
    fi

    precheck_summary "${pass}" "${fail}" "${warn}"
    [[ ${fail} -eq 0 ]] || die "Pre-flight checks failed. Fix the issues above before backing up."
    return 0
}

# ---------------------------------------------------------------------------
# Merged pre-flight checks for LXC and PVE LXC backups
# Usage: _prechecks_backup_lxc_pve "lxc" | "pve"
# ---------------------------------------------------------------------------
_prechecks_backup_lxc_pve() {
    local _type="$1"
    local pass=0 fail=0 warn=0

    precheck_header

    # LXC-only: detect LXC installation first
    if [[ "${_type}" == "lxc" ]]; then
        if lxc_is_installed; then
            _pok  "PVE LXC installation detected (/app/config/production.json)"
            (( pass++ )) || true
        else
            _pwarn "PVE LXC installation not detected at ${LXC_APP_DIR} — may be a non-standard path"
            (( warn++ )) || true
        fi
    fi

    # /data/ exists and is not empty
    if [[ -d "${LXC_DATA_DIR}" ]] && [[ -n "$(ls -A "${LXC_DATA_DIR}" 2>/dev/null)" ]]; then
        _pok  "/data/ exists and contains data"
        (( pass++ )) || true
    else
        _pfail "/data/ not found or empty — nothing to back up"
        (( fail++ )) || true
    fi

    # Database — read production.json, then sqlite file check, then ask interactively
    if [[ "${_type}" == "lxc" ]]; then
        # LXC: single config path
        if [[ -f "${LXC_APP_DIR}/config/production.json" ]]; then
            _pinfo "Reading DB config from: ${LXC_APP_DIR}/config/production.json"
            read_db_from_json "${LXC_APP_DIR}/config/production.json"
        fi
    else
        # PVE: search two config paths in order of precedence
        local pve_prod_json=""
        for _cfg in \
            "${LXC_APP_DIR}/config/production.json" \
            "/opt/nginxproxymanager/backend/config/production.json"; do
            [[ -f "${_cfg}" ]] && { pve_prod_json="${_cfg}"; break; }
        done
        if [[ -n "${pve_prod_json}" ]]; then
            _pinfo "Reading DB config from: ${pve_prod_json}"
            read_db_from_json "${pve_prod_json}"
        fi
    fi

    if [[ "${DB_ENGINE}" == "mysql" || "${DB_ENGINE}" == "postgres" ]]; then
        _pok  "Database engine: ${DB_ENGINE} — ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
        (( pass++ )) || true
        if [[ "${DB_ENGINE}" == "mysql" ]]; then
            command -v mysqldump &>/dev/null \
                && { _pok "mysqldump available"; (( pass++ )) || true; } \
                || { _pfail "mysqldump not found — install: apt-get install mariadb-client"; (( fail++ )) || true; }
        else
            command -v pg_dump &>/dev/null \
                && { _pok "pg_dump available"; (( pass++ )) || true; } \
                || { _pfail "pg_dump not found — install: apt-get install postgresql-client"; (( fail++ )) || true; }
        fi
    elif [[ -f "${LXC_DATA_DIR}/database.sqlite" ]]; then
        local db_size
        db_size=$(du -h "${LXC_DATA_DIR}/database.sqlite" | cut -f1)
        _pok  "Database engine: SQLite — database.sqlite present (${db_size})"
        DB_ENGINE="sqlite"
        (( pass++ )) || true
    else
        _pwarn "database.sqlite not found — specify the database type:"
        ask_db_type "${LXC_DATA_DIR}"
        local _ask_rc=$?
        if   [[ ${_ask_rc} -eq 0 ]]; then (( pass++ )) || true
        elif [[ ${_ask_rc} -eq 1 ]]; then (( fail++ )) || true
        else                               (( warn++ )) || true
        fi
    fi

    # keys.json
    if [[ -f "${LXC_DATA_DIR}/keys.json" ]]; then
        _pok  "keys.json present (encryption key included in backup)"
        (( pass++ )) || true
    else
        _pfail "keys.json not found — backup will be unusable without it"
        (( fail++ )) || true
    fi

    # /etc/letsencrypt/ live certs
    if [[ -d "${LXC_LETSENCRYPT_DIR}/live" ]] && \
       [[ -n "$(ls -A "${LXC_LETSENCRYPT_DIR}/live" 2>/dev/null)" ]]; then
        local cert_count
        cert_count=$(find "${LXC_LETSENCRYPT_DIR}/live" -name "fullchain.pem" 2>/dev/null || true | wc -l)
        _pok  "/etc/letsencrypt/live/ found (${cert_count} certificate(s))"
        (( pass++ )) || true
    elif [[ -d "${LXC_LETSENCRYPT_DIR}" ]]; then
        if [[ "${_type}" == "lxc" ]]; then
            _pwarn "/etc/letsencrypt/ exists but no live certs — no SSL certs to back up"
        else
            _pwarn "/etc/letsencrypt/ present but no live certs — no SSL certs to back up"
        fi
        (( warn++ )) || true
    else
        if [[ "${_type}" == "lxc" ]]; then
            _pwarn "/etc/letsencrypt/ not found — SSL certs will not be included"
        else
            _pwarn "/etc/letsencrypt/ not found — SSL certs not included"
        fi
        (( warn++ )) || true
    fi

    # certbot venv
    if [[ -f "${LXC_CERTBOT_VENV_DIR}/bin/activate" ]]; then
        local cb_ver
        cb_ver=$("${LXC_CERTBOT_VENV_DIR}/bin/certbot" --version 2>&1 | grep -oP '[\d.]+' | head -1 || echo "?")
        _pok  "/opt/certbot venv present (certbot v${cb_ver})"
        (( pass++ )) || true
    else
        if [[ "${_type}" == "lxc" ]]; then
            _pwarn "/opt/certbot venv not found — DNS plugin state will not be backed up"
        else
            _pwarn "/opt/certbot venv not found"
        fi
        (( warn++ )) || true
    fi

    # PVE-only: app directory check
    if [[ "${_type}" == "pve" ]]; then
        if [[ -f "${LXC_APP_DIR}/config/production.json" ]] || \
           [[ -f "${LXC_APP_DIR}/package.json" ]]; then
            _pok  "PVE LXC installation confirmed (/app present)"
            (( pass++ )) || true
        else
            _pwarn "PVE LXC app directory (/app) not found — may not be a PVE LXC install"
            (( warn++ )) || true
        fi
    fi

    # Service state
    if [[ "${_type}" == "lxc" ]]; then
        if lxc_is_running; then
            _pwarn "NPM (LXC) is running — backup is safe (SQLite WAL mode) but stopping ensures full consistency"
            (( warn++ )) || true
        else
            _pok  "NPM (LXC) service is stopped — clean consistent backup"
            (( pass++ )) || true
        fi
    else
        if systemctl is-active --quiet "${LXC_SERVICE}" 2>/dev/null; then
            _pwarn "NPM (${LXC_SERVICE}) is running — backup safe (SQLite WAL) but stop for full consistency"
            (( warn++ )) || true
        else
            _pok  "NPM service (${LXC_SERVICE}) is stopped — clean consistent backup"
            (( pass++ )) || true
        fi
    fi

    # LXC-only: OpenResty/nginx check
    if [[ "${_type}" == "lxc" ]]; then
        if command -v openresty &>/dev/null || command -v nginx &>/dev/null; then
            _pok  "Web server (OpenResty/nginx) present"
            (( pass++ )) || true
        else
            _pwarn "openresty/nginx not found — web server may not be running"
            (( warn++ )) || true
        fi
    fi

    # copy tool
    if command -v rsync &>/dev/null; then
        _pok  "rsync available"
        (( pass++ )) || true
    elif command -v cp &>/dev/null; then
        if [[ "${_type}" == "lxc" ]]; then
            _pok  "cp available (rsync not installed — cp -a will be used)"
        else
            _pok  "cp available — will use cp -a (rsync not installed)"
        fi
        (( pass++ )) || true
    else
        _pfail "neither rsync nor cp found"
        (( fail++ )) || true
    fi

    # tar and gzip
    if command -v tar &>/dev/null && command -v gzip &>/dev/null; then
        _pok  "tar and gzip available"
        (( pass++ )) || true
    else
        _pfail "tar or gzip not found — install with: apt-get install tar gzip"
        (( fail++ )) || true
    fi

    precheck_summary "${pass}" "${fail}" "${warn}"
    [[ ${fail} -eq 0 ]] || die "Pre-flight checks failed. Fix the issues above before backing up."
    return 0
}

prechecks_backup_lxc() { _prechecks_backup_lxc_pve "lxc"; }


# Run all pre-checks for a native recovery
prechecks_recover_native() {
    local staging="$1"
    local pass=0 fail=0 warn=0

    precheck_header

    # manifest present
    if [[ -f "${staging}/${MANIFEST_FILE}" ]]; then
        local bdate btype
        bdate=$(grep "^Created" "${staging}/${MANIFEST_FILE}" | cut -d: -f2- | xargs)
        btype=$(grep "^Backup type" "${staging}/${MANIFEST_FILE}" | cut -d: -f2 | xargs)
        _pok  "Manifest found — type: ${btype}, created: ${bdate}"
        (( pass++ )) || true
    else
        _pwarn "No manifest found in archive — archive may be from a failed backup run"
        (( warn++ )) || true
    fi

    # data/ subdir in archive
    if [[ -d "${staging}/${DATA_SUBDIR}" ]]; then
        _pok  "data/ directory present in archive"
        (( pass++ )) || true
    else
        _pfail "data/ directory missing from archive — this archive appears to be from a failed or incomplete backup run"
        (( fail++ )) || true
    fi

    # database — either sqlite file (SQLite engine) or db-dump/ dir (MySQL/Postgres)
    if [[ -f "${staging}/${DATA_SUBDIR}/database.sqlite" ]]; then
        local db_size
        db_size=$(du -h "${staging}/${DATA_SUBDIR}/database.sqlite" | cut -f1)
        _pok  "Database: SQLite — database.sqlite present (${db_size})"
        (( pass++ )) || true
    elif [[ -d "${staging}/db-dump" ]] && \\
         find "${staging}/db-dump" -name "*.sql" -maxdepth 1 | grep -q .; then
        local dump_file
        dump_file=$(find "${staging}/db-dump" -name "*.sql" -maxdepth 1 | head -1)
        local dump_size
        dump_size=$(du -h "${dump_file}" | cut -f1)
        _pok  "Database: MySQL/Postgres dump found in db-dump/ ($(basename "${dump_file}"), ${dump_size})"
        (( pass++ )) || true
    else
        _pfail "No database found in archive (no database.sqlite and no db-dump/) — backup may be incomplete"
        (( fail++ )) || true
    fi

    # keys.json in archive
    if [[ -f "${staging}/${DATA_SUBDIR}/keys.json" ]]; then
        _pok  "keys.json in archive (encryption key present)"
        (( pass++ )) || true
    else
        _pfail "keys.json missing from archive — restored NPM will not be able to decrypt the database"
        (( fail++ )) || true
    fi

    # letsencrypt/ in archive
    if [[ -d "${staging}/${LETSENCRYPT_SUBDIR}" ]]; then
        local cert_count
        cert_count=$(find "${staging}/${LETSENCRYPT_SUBDIR}/live" -name "fullchain.pem" 2>/dev/null || true | wc -l)
        _pok  "letsencrypt/ directory in archive (${cert_count} certificate(s))"
        (( pass++ )) || true
    else
        _pwarn "letsencrypt/ not in archive — SSL certs will not be restored"
        (( warn++ )) || true
    fi

    # target system has NPM installed (native recovery only)
    if [[ -f "/opt/nginx-proxy-manager/backend/package.json" ]]; then
        _pok  "NPM native installation detected on this system"
        (( pass++ )) || true
    else
        _pwarn "NPM native installation not detected — ensure npm-installer.sh has been run first"
        (( warn++ )) || true
    fi

    # rsync or cp required for file restoration
    if command -v rsync &>/dev/null; then
        _pok  "rsync available"
        (( pass++ )) || true
    elif command -v cp &>/dev/null; then
        _pok  "cp available — rsync not installed, will use cp -a"
        (( pass++ )) || true
    else
        _pfail "neither rsync nor cp found — cannot restore files"
        (( fail++ )) || true
    fi

    precheck_summary "${pass}" "${fail}" "${warn}"
    [[ ${fail} -eq 0 ]] || die "Pre-flight checks failed. Fix the issues above before recovering."
    return 0
}

# Pre-checks for Docker backup
prechecks_backup_docker() {
    local pass=0 fail=0 warn=0

    precheck_header

    # docker command available
    if command -v docker &>/dev/null; then
        _pok  "docker command available ($(docker --version 2>/dev/null | head -1))"
        (( pass++ )) || true
    else
        _pwarn "docker command not found — container management will be skipped"
        (( warn++ )) || true
    fi

    # data dir
    if [[ -d "${DOCKER_DATA_DIR}" ]] && [[ -n "$(ls -A "${DOCKER_DATA_DIR}" 2>/dev/null)" ]]; then
        _pok  "Data volume exists: ${DOCKER_DATA_DIR}"
        (( pass++ )) || true
    else
        _pfail "Data volume not found or empty: ${DOCKER_DATA_DIR}"
        (( fail++ )) || true
    fi

    # Detect DB engine from container env vars
    if [[ -n "${DOCKER_CONTAINER_NAME}" ]]; then
        detect_db_config "${DOCKER_CONTAINER_NAME}"
        case "${DB_ENGINE}" in
            mysql)
                _pok  "Database engine: MySQL/MariaDB (${DB_HOST}:${DB_PORT}/${DB_NAME})"
                (( pass++ )) || true
                # Check mysqldump available
                if command -v mysqldump &>/dev/null; then
                    _pok  "mysqldump available"
                    (( pass++ )) || true
                else
                    _pfail "mysqldump not found — install: apt-get install mariadb-client"
                    (( fail++ )) || true
                fi
                ;;
            postgres)
                _pok  "Database engine: PostgreSQL (${DB_HOST}:${DB_PORT}/${DB_NAME})"
                (( pass++ )) || true
                if command -v pg_dump &>/dev/null; then
                    _pok  "pg_dump available"
                    (( pass++ )) || true
                else
                    _pfail "pg_dump not found — install: apt-get install postgresql-client"
                    (( fail++ )) || true
                fi
                ;;
            *)
                # SQLite — check file exists; if missing offer interactive override
                if [[ -f "${DOCKER_DATA_DIR}/database.sqlite" ]]; then
                    local db_size
                    db_size=$(du -h "${DOCKER_DATA_DIR}/database.sqlite" | cut -f1)
                    _pok  "Database engine: SQLite — database.sqlite present (${db_size})"
                    (( pass++ )) || true
                else
                    _pwarn "database.sqlite not found — specify the database type:"
                    ask_db_type "${DOCKER_DATA_DIR}"
                    local _ask_rc=$?
                    if   [[ ${_ask_rc} -eq 0 ]]; then (( pass++ )) || true
                    elif [[ ${_ask_rc} -eq 1 ]]; then (( fail++ )) || true
                    else                               (( warn++ )) || true
                    fi
                fi
                ;;
        esac
    else
        # No container name — try sqlite as fallback
        if [[ -f "${DOCKER_DATA_DIR}/database.sqlite" ]]; then
            local db_size
            db_size=$(du -h "${DOCKER_DATA_DIR}/database.sqlite" | cut -f1)
            _pok  "database.sqlite present (${db_size})"
            (( pass++ )) || true
        else
            _pwarn "database.sqlite not found and no container name given to detect DB engine"
            (( warn++ )) || true
        fi
    fi

    # keys.json — always required regardless of DB engine
    if [[ -f "${DOCKER_DATA_DIR}/keys.json" ]]; then
        _pok  "keys.json present"
        (( pass++ )) || true
    else
        _pfail "keys.json not found — backup will be unusable without it"
        (( fail++ )) || true
    fi

    # letsencrypt dir
    if [[ -n "${DOCKER_LETSENCRYPT_DIR}" ]] && [[ -d "${DOCKER_LETSENCRYPT_DIR}" ]]; then
        local cert_count
        cert_count=$(find "${DOCKER_LETSENCRYPT_DIR}/live" -name "fullchain.pem" 2>/dev/null || true | wc -l)
        _pok  "Let's Encrypt volume exists: ${DOCKER_LETSENCRYPT_DIR} (${cert_count} cert(s))"
        (( pass++ )) || true
    else
        _pwarn "Let's Encrypt volume not found — SSL certs will not be backed up"
        (( warn++ )) || true
    fi

    # cp is always available (coreutils); rsync is preferred but not required
    if command -v rsync &>/dev/null; then
        _pok  "rsync available (preferred copy tool)"
        (( pass++ )) || true
    elif command -v cp &>/dev/null; then
        _pok  "cp available — rsync not installed, will use cp -a (functionally equivalent for backup)"
        (( pass++ )) || true
    else
        _pfail "neither rsync nor cp found — cannot copy files"
        (( fail++ )) || true
    fi

    # tar and gzip
    if command -v tar &>/dev/null && command -v gzip &>/dev/null; then
        _pok  "tar and gzip available"
        (( pass++ )) || true
    else
        _pfail "tar or gzip not found — install with: apt-get install tar gzip"
        (( fail++ )) || true
    fi

    precheck_summary "${pass}" "${fail}" "${warn}"
    [[ ${fail} -eq 0 ]] || die "Pre-flight checks failed. Fix the issues above before backing up."
    return 0
}

# ---------------------------------------------------------------------------
# Detect running NPM native service
# ---------------------------------------------------------------------------
native_is_running() {
    systemctl is-active --quiet "${NATIVE_SERVICE}" 2>/dev/null
}


lxc_is_running() {
    # PVE LXC uses either systemd or openrc depending on base distro
    systemctl is-active --quiet "${LXC_SERVICE}" 2>/dev/null ||     (command -v rc-service &>/dev/null && rc-service "${LXC_SERVICE}" status &>/dev/null)
}

# Alias for PVE LXC — backup_pve() uses this name
pve_is_running() { lxc_is_running; }

lxc_is_installed() {
    # Detect PVE LXC install by presence of /app/config/production.json
    [[ -f "${LXC_APP_DIR}/config/production.json" ]]
}

# ---------------------------------------------------------------------------
# read_db_from_json — parse a production.json file and populate DB_* globals.
# Sets DB_ENGINE to "mysql", "postgres", or "sqlite". All fields populated.
# ---------------------------------------------------------------------------
read_db_from_json() {
    local cfg="$1"
    [[ -f "${cfg}" ]] || return 1

    # Single Python invocation — avoids 5 separate process spawns and
    # passes the file path via sys.argv to prevent code injection.
    local _db_fields
    _db_fields=$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    db=d.get('database',{})
    e=db.get('engine','')
    engine='mysql' if 'mysql' in e else ('postgres' if 'pg' in e else 'sqlite')
    print(engine)
    print(db.get('host',''))
    print(db.get('port','3306'))
    print(db.get('user',''))
    print(db.get('name',''))
    print(db.get('password',''))
except Exception:
    print('sqlite')
" "${cfg}" 2>/dev/null) || { DB_ENGINE="sqlite"; return 0; }

    local engine
    engine=$(sed -n '1p' <<< "${_db_fields}")

    if [[ "${engine}" == "mysql" || "${engine}" == "postgres" ]]; then
        DB_ENGINE="${engine}"
        DB_HOST=$(sed -n '2p' <<< "${_db_fields}")
        DB_PORT=$(sed -n '3p' <<< "${_db_fields}")
        DB_USER=$(sed -n '4p' <<< "${_db_fields}")
        DB_NAME=$(sed -n '5p' <<< "${_db_fields}")
        DB_PASS=$(sed -n '6p' <<< "${_db_fields}")
        return 0
    fi
    DB_ENGINE="sqlite"
    return 0
}

# ---------------------------------------------------------------------------
# ask_db_type — interactive fallback when DB auto-detection fails.
# Sets DB_ENGINE and DB_* globals.
# Returns: 0=configured, 1=config failed, 2=skipped by user.
# ---------------------------------------------------------------------------
ask_db_type() {
    local data_dir="${1:-/data}"
    echo ""
    echo -e "  ${BOLD}  Select database type:${NC}"
    echo -e "    ${CYAN}1)${NC} MySQL / MariaDB"
    echo -e "    ${CYAN}2)${NC} PostgreSQL"
    echo -e "    ${CYAN}3)${NC} SQLite at custom path"
    echo -e "    ${CYAN}s)${NC} Skip — continue without database backup"
    echo ""
    local choice
    choice=$(ask "Database type [1/2/3/s]" "s")
    case "${choice}" in
        1)
            DB_ENGINE="mysql"
            DB_HOST=$(ask "MySQL host"          "localhost")
            DB_PORT=$(ask "MySQL port"          "3306")
            DB_USER=$(ask "MySQL user"          "npm")
            DB_NAME=$(ask "MySQL database name" "npm")
            DB_PASS=$(ask "MySQL password"      "")
            _pok "MySQL/MariaDB configured: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
            if command -v mysqldump &>/dev/null; then
                _pok "mysqldump available"; return 0
            else
                _pfail "mysqldump not found — install: apt-get install mariadb-client"; return 1
            fi
            ;;
        2)
            DB_ENGINE="postgres"
            DB_HOST=$(ask "PostgreSQL host"          "localhost")
            DB_PORT=$(ask "PostgreSQL port"          "5432")
            DB_USER=$(ask "PostgreSQL user"          "npm")
            DB_NAME=$(ask "PostgreSQL database name" "npm")
            DB_PASS=$(ask "PostgreSQL password"      "")
            _pok "PostgreSQL configured: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
            if command -v pg_dump &>/dev/null; then
                _pok "pg_dump available"; return 0
            else
                _pfail "pg_dump not found — install: apt-get install postgresql-client"; return 1
            fi
            ;;
        3)
            local custom_path
            custom_path=$(ask "Full path to database.sqlite" "${data_dir}/database.sqlite")
            if [[ -f "${custom_path}" ]]; then
                DB_SQLITE_PATH="${custom_path}"; DB_ENGINE="sqlite"
                _pok "SQLite found at: ${custom_path}"; return 0
            else
                _pfail "SQLite not found at: ${custom_path}"; return 1
            fi
            ;;
        s|S|"")
            _pwarn "Database backup skipped — archive will not contain a database dump"
            DB_ENGINE="none"; return 2
            ;;
        *)
            _pwarn "Unknown choice '${choice}' — skipping database backup"
            DB_ENGINE="none"; return 2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Detect Docker NPM container
# ---------------------------------------------------------------------------
detect_docker_npm() {
    if command -v docker &>/dev/null; then
        local containers
        containers=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
            | grep -i "nginx-proxy-manager\|jc21/nginx-proxy-manager" | head -1 || true)
        if [[ -n "${containers}" ]]; then
            DOCKER_CONTAINER_NAME=$(echo "${containers}" | awk '{print $1}')
            return 0
        fi
    fi
    return 1
}

# Ask user for Docker data paths
ask_docker_paths() {
    echo ""
    _pwarn "Could not auto-detect a running NPM Docker container."
    _pinfo "Please provide the Docker volume paths manually."
    echo ""
    local default_data="/opt/nginx-proxy-manager/data"
    DOCKER_DATA_DIR=$(ask "Path to NPM data volume on host" "${default_data}")
    [[ -d "${DOCKER_DATA_DIR}" ]] || die "Data directory not found: ${DOCKER_DATA_DIR}"
    local default_le="/opt/nginx-proxy-manager/letsencrypt"
    DOCKER_LETSENCRYPT_DIR=$(ask "Path to Let's Encrypt volume on host (leave blank to skip)" "${default_le}")
    DOCKER_CONTAINER_NAME=$(ask "Docker container name (leave blank to skip service management)" "")
}

# ---------------------------------------------------------------------------
# Build archive name
# ---------------------------------------------------------------------------
make_archive_name() {
    local type="$1" dest="$2"
    echo "${dest}/npm-backup-${type}-$(timestamp).tar.gz"
}

# ---------------------------------------------------------------------------
# Write manifest
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Extract archive — returns staging inner path via echo.
# Handles two archive layouts:
#   New (v1.0.0+): single wrapper subdir — tar -C /tmp basename/
#     └── npm-backup-staging.XXX/
#         ├── manifest.txt
#         ├── data/
#         └── letsencrypt/
#   Old (pre-v1.0.0): flat root — tar -C staging .
#     ├── manifest.txt
#     ├── data/
#     └── letsencrypt/
# ---------------------------------------------------------------------------
extract_archive() {
    local archive="$1"
    [[ -f "${archive}" ]] || die "Archive not found: ${archive}"
    [[ "${archive}" == *.tar.gz ]] || die "Expected a .tar.gz archive"

    local staging
    staging=$(mktemp -d /tmp/npm-restore-staging.XXXXXX)

    # All status messages go to stderr — this function is called inside $()
    # and only the inner path must be captured on stdout
    echo -e "  \033[0;36m[INFO]\033[0m Extracting archive..." >&2
    # Security: check for path traversal entries before extracting
    if tar -tzf "${archive}" 2>/dev/null | grep -qE '^\.\./|/\.\./'; then
        rm -rf "${staging}"
        die "Archive contains path traversal entries (../) — refusing to extract"
    fi
    tar --no-same-owner -xzf "${archive}" -C "${staging}" || die "Failed to extract archive — file may be corrupt"
    chmod -R go= "${staging}"

    # Detect archive layout:
    # New style (v1.0.0+): single wrapper subdir → tar -C /tmp basename/
    # Old style (pre-v1.0.0): flat root       → tar -C staging .
    local inner candidates n_dirs
    candidates=$(find "${staging}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    n_dirs=$(echo "${candidates}" | grep -c . 2>/dev/null || echo 0)

    if [[ "${n_dirs}" -eq 1 ]]; then
        inner=$(echo "${candidates}")
        if [[ -f "${inner}/manifest.txt" || -d "${inner}/data" ]]; then
            echo "${inner}"; return 0
        fi
    fi

    # Old style — manifest.txt and data/ sit directly in the extract root
    if [[ -f "${staging}/manifest.txt" || -d "${staging}/data" ]]; then
        echo -e "  \033[0;36m[INFO]\033[0m Archive uses flat layout (created by an older version of this tool)" >&2
        echo "${staging}"; return 0
    fi

    # Last resort: pick the first subdir found
    if [[ -n "${candidates}" ]]; then
        inner=$(echo "${candidates}" | head -1)
        echo -e "  \033[1;33m[WARN]\033[0m Non-standard archive layout — attempting recovery from: $(basename "${inner}")" >&2
        echo "${inner}"; return 0
    fi

    die "Archive structure unrecognised — no usable content found after extraction"
}


# Show manifest
show_manifest() {
    local staging="$1"
    if [[ -f "${staging}/${MANIFEST_FILE}" ]]; then
        echo ""
        echo -e "${DIM}$(cat "${staging}/${MANIFEST_FILE}")${NC}"
        echo ""
    else
        _pwarn "No manifest in archive — this archive may be from a failed backup run; verify before restoring"
    fi
}

# Check for existing data and prompt before overwrite
check_existing_data() {
    local target_dir="$1" label="$2"
    if [[ -d "${target_dir}" ]] && [[ -n "$(ls -A "${target_dir}" 2>/dev/null)" ]]; then
        echo ""
        _pwarn "Target already contains data: ${target_dir}"
        echo -e "  ${YELLOW}Restoring will overwrite existing ${label} data.${NC}"
        confirm "Continue and overwrite?" || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# detect_db_config — inspect a running Docker container's env vars and
# extract the database engine + credentials into global vars:
#   DB_ENGINE  : "sqlite" | "mysql" | "postgres"
#   DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAME  (MySQL/Postgres only)
#   DB_SQLITE_PATH  (SQLite only)
# ---------------------------------------------------------------------------
DB_ENGINE=""
DB_HOST=""; DB_PORT=""; DB_USER=""; DB_PASS=""; DB_NAME=""
DB_SQLITE_PATH="/data/database.sqlite"

detect_db_config() {
    local container="$1"
    DB_ENGINE=""   # reset before each detection

    [[ -z "${container}" ]] && { DB_ENGINE="sqlite"; return 0; }

    if ! command -v docker &>/dev/null; then
        _pwarn "docker not found — cannot inspect container; assuming SQLite"
        DB_ENGINE="sqlite"; return 0
    fi

    # Verify the container exists
    if ! docker inspect "${container}" &>/dev/null 2>&1; then
        _pwarn "Container '${container}' not found — cannot read DB config; assuming SQLite"
        DB_ENGINE="sqlite"; return 0
    fi

    # Extract all env vars from the container (works for running and stopped containers)
    local envvars
    envvars=$(docker inspect "${container}" \
        --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)

    # ── MySQL / MariaDB ───────────────────────────────────────────────────
    local mysql_host mysql_user mysql_name mysql_pass mysql_port
    mysql_host=$(echo "${envvars}" | grep '^DB_MYSQL_HOST='     | cut -d= -f2- | tr -d '\r')
    mysql_user=$(echo "${envvars}" | grep '^DB_MYSQL_USER='     | cut -d= -f2- | tr -d '\r')
    mysql_name=$(echo "${envvars}" | grep '^DB_MYSQL_NAME='     | cut -d= -f2- | tr -d '\r')
    mysql_pass=$(echo "${envvars}" | grep '^DB_MYSQL_PASSWORD=' | cut -d= -f2- | tr -d '\r')
    mysql_port=$(echo "${envvars}" | grep '^DB_MYSQL_PORT='     | cut -d= -f2- | tr -d '\r')

    if [[ -n "${mysql_host}" && -n "${mysql_user}" && -n "${mysql_name}" ]]; then
        DB_ENGINE="mysql"
        DB_HOST="${mysql_host}"; DB_PORT="${mysql_port:-3306}"
        DB_USER="${mysql_user}"; DB_PASS="${mysql_pass}"; DB_NAME="${mysql_name}"
        return 0
    fi

    # ── PostgreSQL ────────────────────────────────────────────────────────
    local pg_host pg_user pg_name pg_pass pg_port
    pg_host=$(echo "${envvars}" | grep '^DB_POSTGRES_HOST='     | cut -d= -f2- | tr -d '\r')
    pg_user=$(echo "${envvars}" | grep '^DB_POSTGRES_USER='     | cut -d= -f2- | tr -d '\r')
    pg_name=$(echo "${envvars}" | grep '^DB_POSTGRES_NAME='     | cut -d= -f2- | tr -d '\r')
    pg_pass=$(echo "${envvars}" | grep '^DB_POSTGRES_PASSWORD=' | cut -d= -f2- | tr -d '\r')
    pg_port=$(echo "${envvars}" | grep '^DB_POSTGRES_PORT='     | cut -d= -f2- | tr -d '\r')

    if [[ -n "${pg_host}" && -n "${pg_user}" && -n "${pg_name}" ]]; then
        DB_ENGINE="postgres"
        DB_HOST="${pg_host}"; DB_PORT="${pg_port:-5432}"
        DB_USER="${pg_user}"; DB_PASS="${pg_pass}"; DB_NAME="${pg_name}"
        return 0
    fi

    # ── Custom SQLite path ────────────────────────────────────────────────
    local sqlite_file
    sqlite_file=$(echo "${envvars}" | grep '^DB_SQLITE_FILE=' | cut -d= -f2- | tr -d '\r')
    [[ -n "${sqlite_file}" ]] && DB_SQLITE_PATH="${sqlite_file}"

    # ── Fallback: check for mounted NPM config file ───────────────────────
    # NPM also supports a JSON file at /app/config/production.json as an
    # alternative to env vars. Check if it is mounted from the host.
    local config_mount
    config_mount=$(docker inspect "${container}" \
        --format '{{range .Mounts}}{{if eq .Destination "/app/config"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null | tr -d '\r' || true)

    if [[ -n "${config_mount}" && -f "${config_mount}/production.json" ]]; then
        local cfg_engine
        cfg_engine=$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    e=d.get('database',{}).get('engine','')
    print('mysql' if 'mysql' in e else ('postgres' if 'pg' in e else 'sqlite'))
except Exception: print('sqlite')
" "${config_mount}/production.json" 2>/dev/null || echo "sqlite")
        if [[ "${cfg_engine}" == "mysql" || "${cfg_engine}" == "postgres" ]]; then
            read_db_from_json "${config_mount}/production.json"
            _pinfo "DB config read from mounted config file: ${config_mount}/production.json"
            return 0
        fi
    fi

    DB_ENGINE="sqlite"
    return 0
}


# ---------------------------------------------------------------------------
# backup_database — dump the database into staging/db-dump/ based on engine
# Returns 0 on success, 1 on failure
# ---------------------------------------------------------------------------
backup_database() {
    local staging="$1" container="${2:-}"

    echo ""
    echo -e "  ${BOLD}Database backup${NC}"

    if [[ "${DB_ENGINE}" == "mysql" ]]; then
        _pinfo "Database engine: MySQL/MariaDB (${DB_HOST}:${DB_PORT}/${DB_NAME})"

        # Verify mysqldump available
        if ! command -v mysqldump &>/dev/null; then
            _pfail "mysqldump not found — install with: apt-get install mariadb-client"
            return 1
        fi

        # Test connectivity before dumping
        local conn_test
        if MYSQL_PWD="${DB_PASS}" mysqladmin                 --host="${DB_HOST}" --port="${DB_PORT}"                 --user="${DB_USER}" ping --connect-timeout=5 &>/dev/null 2>&1; then
            _pok  "MySQL/MariaDB connection verified (${DB_HOST}:${DB_PORT})"
        else
            _pfail "Cannot connect to MySQL/MariaDB at ${DB_HOST}:${DB_PORT} — check credentials and network"
            return 1
        fi

        mkdir -p "${staging}/db-dump"
        local dump_file="${staging}/db-dump/${DB_NAME}.sql"
        if MYSQL_PWD="${DB_PASS}" mysqldump                 --host="${DB_HOST}" --port="${DB_PORT}"                 --user="${DB_USER}"                 --single-transaction --routines --triggers                 "${DB_NAME}" > "${dump_file}" 2>/dev/null; then
            local dump_size
            dump_size=$(du -sh "${dump_file}" | cut -f1)
            _pdone "mysqldump complete: ${DB_NAME}.sql (${dump_size})"
            _pok  "Dump file: ${staging}/db-dump/${DB_NAME}.sql"
            # Write engine metadata
            echo "DB_ENGINE=mysql"   >  "${staging}/db-dump/db-meta.txt"
            echo "DB_NAME=${DB_NAME}" >> "${staging}/db-dump/db-meta.txt"
            echo "DB_HOST=${DB_HOST}" >> "${staging}/db-dump/db-meta.txt"
            echo "DB_PORT=${DB_PORT}" >> "${staging}/db-dump/db-meta.txt"
            echo "DB_USER=${DB_USER}" >> "${staging}/db-dump/db-meta.txt"
            return 0
        else
            _pfail "mysqldump failed — check credentials and database name"
            return 1
        fi

    elif [[ "${DB_ENGINE}" == "postgres" ]]; then
        _pinfo "Database engine: PostgreSQL (${DB_HOST}:${DB_PORT}/${DB_NAME})"

        if ! command -v pg_dump &>/dev/null; then
            _pfail "pg_dump not found — install with: apt-get install postgresql-client"
            return 1
        fi

        mkdir -p "${staging}/db-dump"
        local dump_file="${staging}/db-dump/${DB_NAME}.sql"
        if PGPASSWORD="${DB_PASS}" pg_dump                 --host="${DB_HOST}" --port="${DB_PORT}"                 --username="${DB_USER}" --no-password                 "${DB_NAME}" > "${dump_file}" 2>/dev/null; then
            local dump_size
            dump_size=$(du -sh "${dump_file}" | cut -f1)
            _pdone "pg_dump complete: ${DB_NAME}.sql (${dump_size})"
            echo "DB_ENGINE=postgres"  >  "${staging}/db-dump/db-meta.txt"
            echo "DB_NAME=${DB_NAME}"  >> "${staging}/db-dump/db-meta.txt"
            echo "DB_HOST=${DB_HOST}"  >> "${staging}/db-dump/db-meta.txt"
            echo "DB_PORT=${DB_PORT}"  >> "${staging}/db-dump/db-meta.txt"
            echo "DB_USER=${DB_USER}"  >> "${staging}/db-dump/db-meta.txt"
            return 0
        else
            _pfail "pg_dump failed"
            return 1
        fi

    else
        # SQLite — copy the file
        _pinfo "Database engine: SQLite (${DB_SQLITE_PATH})"
        local sqlite_src="${DOCKER_DATA_DIR}/${DB_SQLITE_PATH##*/}"
        # Also try the raw path in case it's mounted differently
        [[ ! -f "${sqlite_src}" ]] && sqlite_src="${DB_SQLITE_PATH}"
        if [[ -f "${sqlite_src}" ]]; then
            mkdir -p "${staging}/${DATA_SUBDIR}"
            cp -p "${sqlite_src}" "${staging}/${DATA_SUBDIR}/database.sqlite"
            _pdone "database.sqlite copied"
            return 0
        else
            _pfail "database.sqlite not found at ${sqlite_src}"
            _pinfo "If using a custom path, set DB_SQLITE_FILE in your docker-compose.yml"
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# restore_database — restore a database dump from staging/db-dump/
# ---------------------------------------------------------------------------
restore_database() {
    local staging="$1"
    local db_meta="${staging}/db-dump/db-meta.txt"

    echo ""
    echo -e "  ${BOLD}Database restore${NC}"

    if [[ ! -d "${staging}/db-dump" ]]; then
        _pskip "No db-dump/ in archive — database was SQLite (included in data/)"
        return 0
    fi

    [[ -f "${db_meta}" ]] || { _pfail "db-meta.txt missing from archive"; return 1; }

    local engine name
    engine=$(grep '^DB_ENGINE=' "${db_meta}" | cut -d= -f2)
    name=$(grep '^DB_NAME=' "${db_meta}" | cut -d= -f2)

    if [[ "${engine}" == "mysql" ]]; then
        local host port user
        host=$(grep '^DB_HOST=' "${db_meta}" | cut -d= -f2)
        port=$(grep '^DB_PORT=' "${db_meta}" | cut -d= -f2)
        user=$(grep '^DB_USER=' "${db_meta}" | cut -d= -f2)

        local db_pass
        db_pass=$(ask "MySQL password for ${user}@${host}:${port}/${name}" "")

        _pinfo "Restoring MySQL database: ${name} on ${host}:${port}"
        if ! command -v mysql &>/dev/null; then
            _pfail "mysql client not found — install with: apt-get install mariadb-client"
            return 1
        fi

        local dump_file="${staging}/db-dump/${name}.sql"
        if MYSQL_PWD="${db_pass}" mysql                 --host="${host}" --port="${port}"                 --user="${user}" "${name}" < "${dump_file}" 2>/dev/null; then
            _pdone "MySQL database restored: ${name}"
            return 0
        else
            _pfail "MySQL restore failed — check credentials and that database '${name}' exists"
            return 1
        fi

    elif [[ "${engine}" == "postgres" ]]; then
        local host port user
        host=$(grep '^DB_HOST=' "${db_meta}" | cut -d= -f2)
        port=$(grep '^DB_PORT=' "${db_meta}" | cut -d= -f2)
        user=$(grep '^DB_USER=' "${db_meta}" | cut -d= -f2)

        local db_pass
        db_pass=$(ask "PostgreSQL password for ${user}@${host}:${port}/${name}" "")

        _pinfo "Restoring PostgreSQL database: ${name} on ${host}:${port}"
        if ! command -v psql &>/dev/null; then
            _pfail "psql not found — install with: apt-get install postgresql-client"
            return 1
        fi

        local dump_file="${staging}/db-dump/${name}.sql"
        if PGPASSWORD="${db_pass}" psql                 --host="${host}" --port="${port}"                 --username="${user}" --no-password                 "${name}" < "${dump_file}" 2>/dev/null; then
            _pdone "PostgreSQL database restored: ${name}"
            return 0
        else
            _pfail "PostgreSQL restore failed"
            return 1
        fi
    else
        _pskip "SQLite — database is in data/ directory, no separate restore needed"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# copy_dir — copy src/ to dst/ using rsync if available, otherwise cp -a
# This avoids a hard dependency on rsync for Docker backups where cp -a
# is functionally identical (always copying into a fresh staging directory).
# ---------------------------------------------------------------------------
copy_dir() {
    local src="$1" dst="$2"
    if command -v rsync &>/dev/null; then
        rsync -a "${src}/" "${dst}/"
    else
        mkdir -p "${dst}"
        cp -a "${src}/." "${dst}/"
    fi
}

# ---------------------------------------------------------------------------
# BACKUP — NPM Native
# ---------------------------------------------------------------------------
backup_native() {
    section "Backup — NPM Native"

    local backup_dir
    backup_dir=$(ask "Backup destination directory" "${DEFAULT_BACKUP_DIR}")
    mkdir -p "${backup_dir}" || die "Cannot create backup directory: ${backup_dir}"

    local archive
    archive=$(make_archive_name "NATIVE" "${backup_dir}")

    # Pre-flight checks
    prechecks_backup_native

    echo ""
    _pinfo "Archive       : $(basename "${archive}")"
    _pinfo "Destination   : ${backup_dir}"
    echo ""
    confirm "Proceed with backup?" || { _pinfo "Backup cancelled."; return; }

    # ── Service management before backup ─────────────────────────────────
    local stopped_native=false
    echo ""
    if native_is_running; then
        _pwarn "NPM is running — backup is safe (SQLite WAL mode) but stopping ensures full consistency"
        if confirm "Stop NPM service during backup?"; then
            echo ""
            echo -e "  ${BOLD}Stopping services${NC}"
            systemctl stop "${NATIVE_SERVICE}" 2>/dev/null || true
            systemctl stop "${NATIVE_NGINX_SERVICE}" 2>/dev/null || true
            sleep 1
            if ! native_is_running; then
                _pdone "NPM service stopped"
                stopped_native=true
            else
                _pfail "NPM service did not stop — continuing with live backup"
            fi
        else
            _pinfo "Continuing with live backup (SQLite WAL mode)"
        fi
    fi

    local staging
    staging=$(mktemp -d /tmp/npm-backup-staging.XXXXXX)
    _CLEANUP_DIR="${staging}"

    # ── Step 1: Manifest ──────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 1/4 — Manifest${NC}"
    write_manifest "NATIVE" "${staging}"
    _pdone "Manifest written"

    # ── Step 2: /data/ ────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 2/4 — Backing up /data/${NC}"
    if [[ -d "${NATIVE_DATA_DIR}" ]]; then
        mkdir -p "${staging}/${DATA_SUBDIR}"
        if command -v rsync &>/dev/null; then
            rsync -a --info=progress2 \
                --exclude="*.log" --exclude="*.log.*" \
                "${NATIVE_DATA_DIR}/" "${staging}/${DATA_SUBDIR}/" 2>/dev/null \
                || rsync -a --exclude="*.log" --exclude="*.log.*" \
                "${NATIVE_DATA_DIR}/" "${staging}/${DATA_SUBDIR}/"
        else
            cp -a "${NATIVE_DATA_DIR}/." "${staging}/${DATA_SUBDIR}/"
            find "${staging}/${DATA_SUBDIR}" -name "*.log" -delete 2>/dev/null || true
            find "${staging}/${DATA_SUBDIR}" -name "*.log.*" -delete 2>/dev/null || true
        fi
        local data_size
        data_size=$(du -sh "${staging}/${DATA_SUBDIR}" | cut -f1)
        _pdone "/data/ copied (${data_size})"
        [[ -f "${staging}/${DATA_SUBDIR}/keys.json" ]] && \
            _pok  "keys.json verified in archive"
    else
        _pskip "/data/ not found — skipped"
    fi

    # ── Database dump (skips if SQLite — file already copied in data/) ────
    if [[ "${DB_ENGINE}" == "mysql" || "${DB_ENGINE}" == "postgres" ]]; then
        backup_database "${staging}" || \
            _pwarn "Database backup failed — archive will not contain a database dump"
    elif [[ -f "${staging}/${DATA_SUBDIR}/database.sqlite" ]]; then
        _pok  "database.sqlite included (SQLite)"
    else
        _pwarn "No database found to back up (no SQLite file and no external DB configured)"
    fi


    # ── Step 3: /etc/letsencrypt/ ─────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 3/4 — Backing up /etc/letsencrypt/${NC}"
    if [[ -d "${NATIVE_LETSENCRYPT_DIR}" ]]; then
        mkdir -p "${staging}/${LETSENCRYPT_SUBDIR}"
        copy_dir "${NATIVE_LETSENCRYPT_DIR}" "${staging}/${LETSENCRYPT_SUBDIR}"
        local le_size cert_count
        le_size=$(du -sh "${staging}/${LETSENCRYPT_SUBDIR}" | cut -f1)
        cert_count=$(find "${staging}/${LETSENCRYPT_SUBDIR}/live" -name "fullchain.pem" 2>/dev/null || true | wc -l)
        _pdone "/etc/letsencrypt/ copied (${le_size})"
        _pok  "${cert_count} certificate(s) verified in archive"
    else
        _pskip "/etc/letsencrypt/ not found — skipped"
    fi

    # ── Step 4: Archive ───────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 4/4 — Creating archive${NC}"
    if [[ -d "${NATIVE_CERTBOT_VENV_DIR}" ]]; then
        local venv_size
        venv_size=$(du -sh "${NATIVE_CERTBOT_VENV_DIR}" 2>/dev/null | cut -f1)
        _pinfo "certbot venv found (${venv_size}) — includes installed DNS plugins"
        if confirm "Include certbot venv in backup? (recommended for full migration, adds ${venv_size})"; then
            mkdir -p "${staging}/${CERTBOT_VENV_SUBDIR}"
            copy_dir "${NATIVE_CERTBOT_VENV_DIR}" "${staging}/${CERTBOT_VENV_SUBDIR}"
            _pok  "certbot venv included"
        else
            _pskip "certbot venv excluded — DNS plugins will be re-installed automatically on first renewal"
        fi
    fi
    local tar_ok=false
    if tar -czf "${archive}" -C "$(dirname "${staging}")" "$(basename "${staging}")" 2>/dev/null; then
        local arc_size
        arc_size=$(du -sh "${archive}" | cut -f1)
        _pdone "Archive created (${arc_size}): $(basename "${archive}")"
        tar_ok=true
    else
        _pfail "tar -czf FAILED — archive was not created"
        _pinfo "Check: disk space (df -h), permissions on ${archive%/*}, tar/gzip installed"
    fi

    # Verify archive integrity if creation succeeded
    if ${tar_ok}; then
        if tar -tzf "${archive}" &>/dev/null; then
            _pok  "Archive integrity verified (tar -t OK)"
            # Verify key files are present inside the archive
            local _arc_list
            _arc_list=$(tar -tzf "${archive}" 2>/dev/null)
            local _missing_critical=false
            if echo "${_arc_list}" | grep -q "manifest.txt"; then
                _pok  "manifest.txt present in archive"
            else
                _pfail "manifest.txt MISSING from archive"
                _missing_critical=true
            fi
            if echo "${_arc_list}" | grep -q "data/keys.json\|/data/keys.json"; then
                _pok  "keys.json present in archive"
            else
                _pfail "keys.json MISSING from archive — restored NPM cannot decrypt database"
                _missing_critical=true
            fi
            echo "${_arc_list}" | grep -q "data/database.sqlite\|/data/database.sqlite" \
                && _pok  "database.sqlite present in archive" \
                || _pwarn "database.sqlite not found in archive data/ (may use external DB)"
            unset _arc_list
            # Abort if critical files are missing — delete the corrupt archive
            if ${_missing_critical}; then
                _pfail "Archive is missing critical files — deleting corrupt backup"
                rm -f "${archive}"
                tar_ok=false
            fi
            unset _missing_critical
        else
            _pfail "Archive integrity check FAILED — archive may be corrupt"
            tar_ok=false
        fi
    fi

    # ── Restart services if we stopped them ───────────────────────────────
    if ${stopped_native}; then
        echo ""
        echo -e "  ${BOLD}Restarting services${NC}"
        systemctl start "${NATIVE_NGINX_SERVICE}" 2>/dev/null || true
        systemctl start "${NATIVE_SERVICE}" 2>/dev/null || true
        sleep 3
        if native_is_running; then
            _pdone "NPM service restarted successfully"
            _pok  "NPM is running and accepting connections"
        else
            _pfail "NPM service did not restart — run: systemctl start ${NATIVE_SERVICE}"
        fi
        if systemctl is-active --quiet "${NATIVE_NGINX_SERVICE}" 2>/dev/null; then
            _pok  "nginx is running"
        else
            _pfail "nginx did not restart — run: systemctl start ${NATIVE_NGINX_SERVICE}"
        fi
    fi

    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  SECURITY NOTICE${NC}"
    echo -e "  ${YELLOW}keys.json is included — this is the encryption key for the NPM database.${NC}"
    echo -e "  ${YELLOW}Store this backup securely. Anyone with it can access your NPM configuration.${NC}"
    echo ""
    _pdone "Backup complete: ${archive}"
}

# ---------------------------------------------------------------------------
# Merged backup function for LXC and PVE LXC
# Usage: _backup_lxc_or_pve "lxc" | "pve"
# ---------------------------------------------------------------------------
_backup_lxc_or_pve() {
    local _type="$1"

    # Archive name prefix and manifest type
    local _archive_prefix="LXC"
    local _manifest_type="LXC"
    if [[ "${_type}" == "pve" ]]; then
        _archive_prefix="PVE-LXC"
        _manifest_type="PVE-LXC"
    fi

    section "Backup — NPM PVE LXC"

    local backup_dir
    backup_dir=$(ask "Backup destination directory" "${DEFAULT_BACKUP_DIR}")
    mkdir -p "${backup_dir}" || die "Cannot create backup directory: ${backup_dir}"

    local archive
    archive=$(make_archive_name "${_archive_prefix}" "${backup_dir}")

    # Pre-flight checks
    if [[ "${_type}" == "lxc" ]]; then
        prechecks_backup_lxc
    else
        prechecks_backup_pve
    fi

    echo ""
    _pinfo "Archive       : $(basename "${archive}")"
    _pinfo "Destination   : ${backup_dir}"
    echo ""
    confirm "Proceed with backup?" || { _pinfo "Backup cancelled."; return; }

    # ── Service management ────────────────────────────────────────────────
    local stopped_svc=false
    echo ""

    # Check if running: lxc uses lxc_is_running, pve uses pve_is_running
    local _is_running=false
    if [[ "${_type}" == "lxc" ]]; then
        lxc_is_running && _is_running=true
    else
        pve_is_running && _is_running=true
    fi

    if ${_is_running}; then
        if [[ "${_type}" == "lxc" ]]; then
            _pwarn "NPM (LXC) is running — backup is safe (SQLite WAL mode) but stopping ensures full consistency"
        else
            _pwarn "NPM (${LXC_SERVICE}) is running — backup is safe (SQLite WAL) but stopping ensures full consistency"
        fi
        if confirm "Stop NPM service during backup?"; then
            echo ""
            echo -e "  ${BOLD}Stopping services${NC}"
            if [[ "${_type}" == "lxc" ]]; then
                # LXC: try systemctl first, fall back to rc-service
                if command -v systemctl &>/dev/null; then
                    systemctl stop "${LXC_SERVICE}" 2>/dev/null || true
                    systemctl stop "${LXC_OPENRESTY_SERVICE}" 2>/dev/null || true
                elif command -v rc-service &>/dev/null; then
                    rc-service "${LXC_SERVICE}" stop 2>/dev/null || true
                    rc-service "${LXC_OPENRESTY_SERVICE}" stop 2>/dev/null || true
                fi
            else
                # PVE: systemctl only
                systemctl stop "${LXC_SERVICE}" 2>/dev/null || true
                systemctl stop "${LXC_OPENRESTY_SERVICE}" 2>/dev/null || true
            fi
            sleep 1

            # Check if stopped
            local _still_running=false
            if [[ "${_type}" == "lxc" ]]; then
                lxc_is_running && _still_running=true
            else
                pve_is_running && _still_running=true
            fi

            if ! ${_still_running}; then
                if [[ "${_type}" == "lxc" ]]; then
                    _pdone "NPM service stopped"
                else
                    _pdone "NPM (${LXC_SERVICE}) stopped"
                    _pdone "OpenResty (${LXC_OPENRESTY_SERVICE}) stopped"
                fi
                stopped_svc=true
            else
                if [[ "${_type}" == "lxc" ]]; then
                    _pfail "NPM service did not stop — continuing with live backup"
                else
                    _pfail "Service did not stop — continuing with live backup"
                fi
            fi
        else
            _pinfo "Continuing with live backup (SQLite WAL mode)"
        fi
    fi

    local staging
    staging=$(mktemp -d /tmp/npm-backup-staging.XXXXXX)
    _CLEANUP_DIR="${staging}"

    # ── Step 1: Manifest ──────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 1/4 — Manifest${NC}"
    write_manifest "${_manifest_type}" "${staging}"
    _pdone "Manifest written"

    # ── Step 2: /data/ ────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 2/4 — Backing up /data/${NC}"
    if [[ -d "${LXC_DATA_DIR}" ]]; then
        mkdir -p "${staging}/${DATA_SUBDIR}"
        if command -v rsync &>/dev/null; then
            rsync -a --info=progress2 \
                --exclude="*.log" --exclude="*.log.*" \
                "${LXC_DATA_DIR}/" "${staging}/${DATA_SUBDIR}/" 2>/dev/null \
                || rsync -a --exclude="*.log" --exclude="*.log.*" \
                    "${LXC_DATA_DIR}/" "${staging}/${DATA_SUBDIR}/"
        else
            cp -a "${LXC_DATA_DIR}/." "${staging}/${DATA_SUBDIR}/"
            find "${staging}/${DATA_SUBDIR}" -name "*.log" -delete 2>/dev/null || true
            find "${staging}/${DATA_SUBDIR}" -name "*.log.*" -delete 2>/dev/null || true
        fi
        local data_size
        data_size=$(du -sh "${staging}/${DATA_SUBDIR}" | cut -f1)
        _pdone "/data/ copied (${data_size})"
        if [[ "${_type}" == "lxc" ]]; then
            [[ -f "${staging}/${DATA_SUBDIR}/database.sqlite" ]] && _pok "database.sqlite verified in archive"
            [[ -f "${staging}/${DATA_SUBDIR}/keys.json" ]]       && _pok "keys.json verified in archive"
        else
            [[ -f "${staging}/${DATA_SUBDIR}/keys.json" ]] && _pok  "keys.json verified"
        fi
    else
        _pskip "/data/ not found — skipped"
    fi

    # ── Database dump (PVE: mysql/postgres dump; LXC: skipped for SQLite) ─
    if [[ "${_type}" == "pve" ]]; then
        if [[ "${DB_ENGINE}" == "mysql" || "${DB_ENGINE}" == "postgres" ]]; then
            backup_database "${staging}" || \
                _pwarn "Database backup failed — archive will not contain a database dump"
        elif [[ -f "${staging}/${DATA_SUBDIR}/database.sqlite" ]]; then
            _pok  "database.sqlite included (SQLite)"
        else
            _pwarn "No database found to back up (no SQLite file and no external DB configured)"
        fi
    fi

    # ── Step 3: /etc/letsencrypt/ ─────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 3/4 — Backing up /etc/letsencrypt/${NC}"
    if [[ -d "${LXC_LETSENCRYPT_DIR}" ]]; then
        mkdir -p "${staging}/${LETSENCRYPT_SUBDIR}"
        copy_dir "${LXC_LETSENCRYPT_DIR}" "${staging}/${LETSENCRYPT_SUBDIR}"
        local le_size cert_count
        le_size=$(du -sh "${staging}/${LETSENCRYPT_SUBDIR}" | cut -f1)
        cert_count=$(find "${staging}/${LETSENCRYPT_SUBDIR}/live" -name "fullchain.pem" 2>/dev/null || true | wc -l)
        _pdone "/etc/letsencrypt/ copied (${le_size})"
        if [[ "${_type}" == "lxc" ]]; then
            _pok  "${cert_count} certificate(s) verified in archive"
        else
            _pok  "${cert_count} certificate(s) verified"
        fi
    else
        _pskip "/etc/letsencrypt/ not found — skipped"
    fi

    # ── Step 4: Archive ───────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 4/4 — Creating archive${NC}"
    if [[ -d "${LXC_CERTBOT_VENV_DIR}" ]]; then
        local venv_size
        venv_size=$(du -sh "${LXC_CERTBOT_VENV_DIR}" 2>/dev/null | cut -f1)
        if [[ "${_type}" == "lxc" ]]; then
            _pinfo "certbot venv found (${venv_size}) — includes installed DNS plugins"
            if confirm "Include certbot venv in backup? (recommended for full migration, adds ${venv_size})"; then
                mkdir -p "${staging}/${CERTBOT_VENV_SUBDIR}"
                copy_dir "${LXC_CERTBOT_VENV_DIR}" "${staging}/${CERTBOT_VENV_SUBDIR}"
                _pok  "certbot venv included"
            else
                _pskip "certbot venv excluded — DNS plugins will be re-installed automatically on first renewal"
            fi
        else
            _pinfo "certbot venv found (${venv_size})"
            if confirm "Include certbot venv? (recommended, adds ${venv_size})"; then
                mkdir -p "${staging}/${CERTBOT_VENV_SUBDIR}"
                copy_dir "${LXC_CERTBOT_VENV_DIR}" "${staging}/${CERTBOT_VENV_SUBDIR}"
                _pok  "certbot venv included"
            else
                _pskip "certbot venv excluded — DNS plugins auto-installed on first renewal"
            fi
        fi
    fi

    local tar_ok=false
    if tar -czf "${archive}" -C "$(dirname "${staging}")" "$(basename "${staging}")" 2>/dev/null; then
        local arc_size
        arc_size=$(du -sh "${archive}" | cut -f1)
        _pdone "Archive created (${arc_size}): $(basename "${archive}")"
        tar_ok=true
    else
        _pfail "tar -czf FAILED — archive was not created"
        if [[ "${_type}" == "lxc" ]]; then
            _pinfo "Check: disk space (df -h), permissions on ${archive%/*}, tar/gzip installed"
        else
            _pinfo "Check: disk space (df -h), permissions on ${archive%/*}"
        fi
    fi

    # Archive verification
    if [[ "${_type}" == "lxc" ]]; then
        # LXC: simple integrity check
        if ${tar_ok} && tar -tzf "${archive}" &>/dev/null; then
            _pok  "Archive integrity verified (tar -t OK)"
        elif ${tar_ok}; then
            _pfail "Archive integrity check FAILED — archive may be corrupt"
        fi
    else
        # PVE: detailed archive content verification
        if ${tar_ok}; then
            if tar -tzf "${archive}" &>/dev/null; then
                _pok  "Archive integrity verified (tar -t OK)"
                local _arc_list
                _arc_list=$(tar -tzf "${archive}" 2>/dev/null)
                echo "${_arc_list}" | grep -q "manifest.txt" \
                    && _pok  "manifest.txt present in archive" \
                    || _pfail "manifest.txt MISSING from archive"
                echo "${_arc_list}" | grep -q "keys.json" \
                    && _pok  "keys.json present in archive" \
                    || _pfail "keys.json MISSING from archive"
                unset _arc_list
            else
                _pfail "Archive integrity check FAILED — archive may be corrupt"
            fi
        fi
    fi

    # ── Restart services if stopped ───────────────────────────────────────
    if ${stopped_svc}; then
        echo ""
        echo -e "  ${BOLD}Restarting services${NC}"
        if [[ "${_type}" == "lxc" ]]; then
            # LXC: try systemctl first, fall back to rc-service
            if command -v systemctl &>/dev/null; then
                systemctl start "${LXC_OPENRESTY_SERVICE}" 2>/dev/null || true
                systemctl start "${LXC_SERVICE}" 2>/dev/null || true
            elif command -v rc-service &>/dev/null; then
                rc-service "${LXC_OPENRESTY_SERVICE}" start 2>/dev/null || true
                rc-service "${LXC_SERVICE}" start 2>/dev/null || true
            fi
        else
            # PVE: systemctl only
            systemctl start "${LXC_OPENRESTY_SERVICE}" 2>/dev/null || true
            systemctl start "${LXC_SERVICE}" 2>/dev/null || true
        fi
        sleep 3

        if [[ "${_type}" == "lxc" ]]; then
            if lxc_is_running; then
                _pdone "NPM service restarted successfully"
                _pok  "NPM (LXC) is running and accepting connections"
            else
                _pfail "NPM service did not restart — run: systemctl start ${LXC_SERVICE}"
            fi
            if command -v systemctl &>/dev/null && systemctl is-active --quiet "${LXC_OPENRESTY_SERVICE}" 2>/dev/null; then
                _pok  "OpenResty is running"
            fi
        else
            if pve_is_running; then
                _pdone "NPM (${LXC_SERVICE}) restarted successfully"
                _pok  "NPM is running and accepting connections"
            else
                _pfail "NPM did not restart — run: systemctl start ${LXC_SERVICE}"
            fi
            if systemctl is-active --quiet "${LXC_OPENRESTY_SERVICE}" 2>/dev/null; then
                _pok  "OpenResty (${LXC_OPENRESTY_SERVICE}) is running"
            else
                _pfail "OpenResty did not restart — run: systemctl start ${LXC_OPENRESTY_SERVICE}"
            fi
        fi
    fi

    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  SECURITY NOTICE${NC}"
    echo -e "  ${YELLOW}keys.json is included — store this backup securely.${NC}"
    echo ""
    _pdone "Backup complete: ${archive}"
}

backup_lxc() { _backup_lxc_or_pve "lxc"; }

prechecks_backup_pve() { _prechecks_backup_lxc_pve "pve"; }

backup_pve() { _backup_lxc_or_pve "pve"; }

# ---------------------------------------------------------------------------
# BACKUP — NPM Docker
# ---------------------------------------------------------------------------
backup_docker() {
    section "Backup — NPM Docker"

    # Detect or ask for Docker paths
    if detect_docker_npm; then
        _pinfo "Detected NPM container: ${DOCKER_CONTAINER_NAME}"

        local data_mount le_mount
        data_mount=$(docker inspect "${DOCKER_CONTAINER_NAME}" 2>/dev/null \
            | python3 -c "
import json,sys
mounts=json.load(sys.stdin)[0].get('Mounts',[])
[print(m.get('Source','')) for m in mounts if m.get('Destination','')=='/data']
" 2>/dev/null | head -1 || true)

        le_mount=$(docker inspect "${DOCKER_CONTAINER_NAME}" 2>/dev/null \
            | python3 -c "
import json,sys
mounts=json.load(sys.stdin)[0].get('Mounts',[])
[print(m.get('Source','')) for m in mounts if m.get('Destination','')=='/etc/letsencrypt']
" 2>/dev/null | head -1 || true)

        [[ -n "${data_mount}" ]]  && { DOCKER_DATA_DIR="${data_mount}";       _pinfo "Auto-detected data volume: ${DOCKER_DATA_DIR}"; }
        [[ -n "${le_mount}" ]]    && { DOCKER_LETSENCRYPT_DIR="${le_mount}";  _pinfo "Auto-detected letsencrypt volume: ${DOCKER_LETSENCRYPT_DIR}"; }

        if [[ -n "${DOCKER_DATA_DIR}" ]]; then
            confirm "Use auto-detected paths? (n to enter manually)" || ask_docker_paths
        else
            _pwarn "Could not auto-detect volume paths — entering manually"
            ask_docker_paths
        fi
    else
        ask_docker_paths
    fi

    [[ -d "${DOCKER_DATA_DIR}" ]] || die "Docker data directory not found: ${DOCKER_DATA_DIR}"

    local backup_dir
    backup_dir=$(ask "Backup destination directory" "${DEFAULT_BACKUP_DIR}")
    mkdir -p "${backup_dir}" || die "Cannot create backup directory: ${backup_dir}"

    local archive
    archive=$(make_archive_name "DOCKER" "${backup_dir}")

    # Pre-flight checks
    prechecks_backup_docker

    echo ""
    _pinfo "Archive     : $(basename "${archive}")"
    _pinfo "Destination : ${backup_dir}"
    echo ""
    confirm "Proceed with backup?" || { _pinfo "Backup cancelled."; return; }

    local staging
    staging=$(mktemp -d /tmp/npm-backup-staging.XXXXXX)
    _CLEANUP_DIR="${staging}"

    # Optionally stop container
    local stopped_container=false
    if [[ -n "${DOCKER_CONTAINER_NAME}" ]]; then
        echo ""
        if confirm "Stop container '${DOCKER_CONTAINER_NAME}' for consistent backup?"; then
            _pinfo "Stopping container..."
            docker stop "${DOCKER_CONTAINER_NAME}" &>/dev/null
            stopped_container=true
            _pdone "Container stopped"
        else
            _pwarn "Backing up live container (SQLite WAL mode should be safe)"
        fi
    fi

    # ── Step 1: Manifest ──────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 1/3 — Manifest${NC}"
    write_manifest "DOCKER" "${staging}"
    _pdone "Manifest written"


    # ── Step 2: Data volume + database ───────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 2/3 — Backing up data volume${NC}"
    mkdir -p "${staging}/${DATA_SUBDIR}"
    if command -v rsync &>/dev/null; then
        rsync -a --exclude="*.log" --exclude="*.log.*" \
            --exclude="database.sqlite" \
            "${DOCKER_DATA_DIR}/" "${staging}/${DATA_SUBDIR}/"
    else
        cp -a "${DOCKER_DATA_DIR}/." "${staging}/${DATA_SUBDIR}/"
        find "${staging}/${DATA_SUBDIR}" -name "*.log"    -delete 2>/dev/null || true
        find "${staging}/${DATA_SUBDIR}" -name "*.log.*"  -delete 2>/dev/null || true
        rm -f "${staging}/${DATA_SUBDIR}/database.sqlite" 2>/dev/null || true
    fi
    local data_size
    data_size=$(du -sh "${staging}/${DATA_SUBDIR}" | cut -f1)
    _pdone "Data volume (configs, access lists, SSL) copied (${data_size})"
    [[ -f "${staging}/${DATA_SUBDIR}/keys.json" ]] && _pok "keys.json verified"

    # Detect DB engine and dump database separately
    detect_db_config "${DOCKER_CONTAINER_NAME}"
    backup_database "${staging}" "${DOCKER_CONTAINER_NAME}" || \
        _pwarn "Database backup failed — archive will not contain a database dump"

    if [[ -n "${DOCKER_LETSENCRYPT_DIR}" && -d "${DOCKER_LETSENCRYPT_DIR}" ]]; then
        mkdir -p "${staging}/${LETSENCRYPT_SUBDIR}"
        copy_dir "${DOCKER_LETSENCRYPT_DIR}" "${staging}/${LETSENCRYPT_SUBDIR}"
        local le_size cert_count
        le_size=$(du -sh "${staging}/${LETSENCRYPT_SUBDIR}" | cut -f1)
        cert_count=$(find "${staging}/${LETSENCRYPT_SUBDIR}/live" -name "fullchain.pem" 2>/dev/null || true | wc -l)
        _pdone "Let's Encrypt volume copied (${le_size}, ${cert_count} cert(s))"
        _pok  "Certificate files verified"
    else
        _pskip "Let's Encrypt volume not found — skipped"
    fi

    # ── Step 3: Archive ───────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 3/3 — Creating archive${NC}"
    local tar_ok=false
    if tar -czf "${archive}" -C "$(dirname "${staging}")" "$(basename "${staging}")" 2>/dev/null; then
        local arc_size
        arc_size=$(du -sh "${archive}" | cut -f1)
        _pdone "Archive created (${arc_size}): $(basename "${archive}")"
        tar_ok=true
    else
        _pfail "tar -czf FAILED — archive was not created"
        _pinfo "Check: disk space (df -h), permissions on ${archive%/*}"
    fi

    if ${tar_ok}; then
        if tar -tzf "${archive}" &>/dev/null; then
            _pok  "Archive integrity verified (tar -t OK)"
            local _arc_list
            _arc_list=$(tar -tzf "${archive}" 2>/dev/null)
            echo "${_arc_list}" | grep -q "manifest.txt" \
                && _pok  "manifest.txt present in archive" \
                || _pfail "manifest.txt MISSING from archive"
            echo "${_arc_list}" | grep -q "keys.json" \
                && _pok  "keys.json present in archive" \
                || _pfail "keys.json MISSING from archive"
            unset _arc_list
        else
            _pfail "Archive integrity check FAILED — archive may be corrupt"
        fi
    fi

    # Restart container if stopped
    if ${stopped_container}; then
        echo ""
        _pinfo "Restarting container '${DOCKER_CONTAINER_NAME}'..."
        docker start "${DOCKER_CONTAINER_NAME}" &>/dev/null
        sleep 2
        if docker ps -q -f name="${DOCKER_CONTAINER_NAME}" | grep -q .; then
            _pdone "Container restarted"
        else
            _pfail "Container did not restart — run: docker start ${DOCKER_CONTAINER_NAME}"
        fi
    fi

    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  SECURITY NOTICE${NC}"
    echo -e "  ${YELLOW}keys.json is included — store this backup securely.${NC}"
    echo ""
    _pdone "Backup complete: ${archive}"
}

# ---------------------------------------------------------------------------
# ask_archive_path — ask for backup directory then filename separately,
# listing available archives so the user doesn't need to remember the name.
# Sets global ARCHIVE_PATH to the validated full path.
# ---------------------------------------------------------------------------
ARCHIVE_PATH=""
ask_archive_path() {
    local backup_dir

    # Step 1: ask for directory (default: /opt/npm-backups)
    backup_dir=$(ask "Backup directory" "${DEFAULT_BACKUP_DIR}")
    backup_dir="${backup_dir%/}"   # strip trailing slash

    if [[ ! -d "${backup_dir}" ]]; then
        _pwarn "Directory not found: ${backup_dir}"
        ARCHIVE_PATH=""; return 1
    fi

    # Step 2: list available archives in that directory
    local archives=()
    while IFS= read -r f; do
        archives+=("${f}")
    done < <(find "${backup_dir}" -maxdepth 1 -name "*.tar.gz" -type f | sort -r)

    local filename default_file=""
    if [[ ${#archives[@]} -eq 0 ]]; then
        _pwarn "No .tar.gz archives found in ${backup_dir}"
    else
        default_file=$(basename "${archives[0]}")
        echo ""
        echo -e "  ${BOLD}Available backups (newest first):${NC}"
        echo ""
        local i=1
        for a in "${archives[@]}"; do
            printf "   ${CYAN}%d)${NC} %s\n" "${i}" "$(basename "${a}")"
            (( i++ )) || true
        done
        echo ""
    fi

    # Step 3: ask for selection — number or filename, default is newest
    local raw
    if [[ ${#archives[@]} -gt 0 ]]; then
        raw=$(ask "Select archive [number or filename]" "${default_file}")
        if [[ "${raw}" =~ ^[0-9]+$ ]] && [[ "${raw}" -ge 1 && "${raw}" -le ${#archives[@]} ]]; then
            filename=$(basename "${archives[$(( raw - 1 ))]}")
        else
            filename="${raw}"
        fi
    else
        filename=$(ask "Archive filename")
    fi

    # Strip any accidental trailing whitespace or carriage returns
    filename="${filename%$'\r'}"
    filename="${filename#"${filename%%[![:space:]]*}"}"
    filename="${filename%"${filename##*[![:space:]]}"}"

    # If user typed a full path, use it directly
    if [[ "${filename}" == /* ]]; then
        ARCHIVE_PATH="${filename}"
    else
        ARCHIVE_PATH="${backup_dir}/${filename}"
    fi

    if [[ ! -f "${ARCHIVE_PATH}" ]]; then
        _pfail "Archive not found: ${ARCHIVE_PATH}"
        ARCHIVE_PATH=""; return 1
    fi
    _pok "Archive: ${ARCHIVE_PATH}"
    return 0
}

# ---------------------------------------------------------------------------
# RECOVERY — NPM Native  (also handles Docker → Native migration)
# ---------------------------------------------------------------------------
recover_native() {
    local migration="${1:-false}"
    local mode_label="Recovery — NPM Native"
    ${migration} && mode_label="Migration — NPM Docker → NPM Native"
    section "${mode_label}"

    ask_archive_path || die "No valid archive selected"
    local archive="${ARCHIVE_PATH}"

    # Extract
    local staging
    staging=$(extract_archive "${archive}")
    local staging_root
    staging_root=$(dirname "${staging}")
    _CLEANUP_DIR="${staging_root}"

    show_manifest "${staging}"

    # Migration type check
    if ${migration}; then
        local btype
        btype=$(grep "^Backup type" "${staging}/${MANIFEST_FILE}" 2>/dev/null \
            | cut -d: -f2 | xargs || echo "")
        if [[ "${btype}" != "DOCKER" ]]; then
            _pwarn "Archive type is '${btype}' — expected DOCKER for migration"
            confirm "Continue anyway?" || return
        fi
    fi

    # Pre-flight checks
    prechecks_recover_native "${staging}"

    echo ""
    echo -e "  ${BOLD}Will restore:${NC}"
    [[ -d "${staging}/${DATA_SUBDIR}" ]] && \
        _pinfo "data/           → ${NATIVE_DATA_DIR}/"
    [[ -d "${staging}/${LETSENCRYPT_SUBDIR}" ]] && \
        _pinfo "letsencrypt/    → ${NATIVE_LETSENCRYPT_DIR}/"
    [[ -d "${staging}/${CERTBOT_VENV_SUBDIR}" ]] && ! ${migration} && \
        _pinfo "certbot-venv/   → ${NATIVE_CERTBOT_VENV_DIR}/"
    echo ""

    echo -e "  ${YELLOW}${BOLD}⚠  SECURITY NOTICE${NC}"
    echo -e "  ${YELLOW}This archive contains keys.json — restoring will replace the current encryption key.${NC}"
    echo ""
    confirm "Proceed with restore?" || { _pinfo "Recovery cancelled."; return; }

    # Stop services
    local was_running=false
    echo ""
    echo -e "  ${BOLD}Step 0/3 — Stopping services${NC}"
    if native_is_running; then
        systemctl stop "${NATIVE_SERVICE}" 2>/dev/null || true
        systemctl stop "${NATIVE_NGINX_SERVICE}" 2>/dev/null || true
        was_running=true
        _pdone "NPM and nginx services stopped"
    else
        _pskip "Services not running — no need to stop"
    fi

    # ── Step 1: /data/ ────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 1/3 — Restoring /data/${NC}"
    if [[ -d "${staging}/${DATA_SUBDIR}" ]]; then
        check_existing_data "${NATIVE_DATA_DIR}" "NPM" || {
            ${was_running} && systemctl start "${NATIVE_SERVICE}" 2>/dev/null || true
            return
        }
        mkdir -p "${NATIVE_DATA_DIR}"
        if command -v rsync &>/dev/null; then
            rsync -a --delete "${staging}/${DATA_SUBDIR}/" "${NATIVE_DATA_DIR}/"
        else
            find "${NATIVE_DATA_DIR:?}" -mindepth 1 -delete
            cp -a "${staging}/${DATA_SUBDIR}/." "${NATIVE_DATA_DIR}/"
        fi
        _pdone "/data/ restored"
        [[ -f "${NATIVE_DATA_DIR}/database.sqlite" ]] && _pok  "database.sqlite present"
        [[ -f "${NATIVE_DATA_DIR}/keys.json" ]]       && _pok  "keys.json present"
    else
        _pskip "data/ not in archive — skipped"
    fi

    # ── Step 2: /etc/letsencrypt/ ─────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 2/3 — Restoring /etc/letsencrypt/${NC}"
    if [[ -d "${staging}/${LETSENCRYPT_SUBDIR}" ]]; then
        check_existing_data "${NATIVE_LETSENCRYPT_DIR}" "Let's Encrypt" || true
        mkdir -p "${NATIVE_LETSENCRYPT_DIR}"
        if command -v rsync &>/dev/null; then
            rsync -a --delete "${staging}/${LETSENCRYPT_SUBDIR}/" "${NATIVE_LETSENCRYPT_DIR}/"
        else
            find "${NATIVE_LETSENCRYPT_DIR:?}" -mindepth 1 -delete
            cp -a "${staging}/${LETSENCRYPT_SUBDIR}/." "${NATIVE_LETSENCRYPT_DIR}/"
        fi
        local cert_count
        cert_count=$(find "${NATIVE_LETSENCRYPT_DIR}/live" -name "fullchain.pem" 2>/dev/null | wc -l)
        _pdone "/etc/letsencrypt/ restored"
        _pok  "${cert_count} certificate(s) restored"
    else
        _pskip "letsencrypt/ not in archive — skipped"
    fi

    # ── Step 3: certbot venv (native→native only) ─────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 3/3 — Certbot venv${NC}"
    if [[ -d "${staging}/${CERTBOT_VENV_SUBDIR}" ]] && ! ${migration}; then
        mkdir -p "${NATIVE_CERTBOT_VENV_DIR}"
        if command -v rsync &>/dev/null; then
            rsync -a --delete "${staging}/${CERTBOT_VENV_SUBDIR}/" "${NATIVE_CERTBOT_VENV_DIR}/"
        else
            find "${NATIVE_CERTBOT_VENV_DIR:?}" -mindepth 1 -delete
            cp -a "${staging}/${CERTBOT_VENV_SUBDIR}/." "${NATIVE_CERTBOT_VENV_DIR}/"
        fi
        _pdone "/opt/certbot/ restored"
    elif ${migration}; then
        _pskip "Migration mode — certbot venv not restored (target system venv is correct)"
        _pinfo "DNS plugins will be auto-installed by NPM on first certificate renewal"
    else
        _pskip "certbot-venv/ not in archive — skipped"
    fi

    # Restart services
    echo ""
    echo -e "  ${BOLD}Starting services${NC}"
    if ${was_running} || true; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl start "${NATIVE_NGINX_SERVICE}" 2>/dev/null || true
        systemctl start "${NATIVE_SERVICE}" 2>/dev/null || true
        sleep 3
        if native_is_running; then
            _pdone "NPM service started"
            _pok  "nginx service started"
        else
            _pfail "NPM service did not start — run: systemctl status ${NATIVE_SERVICE}"
        fi
    fi

    echo ""
    if ${migration}; then
        _pdone "Migration from Docker to Native complete"
        _pinfo "Access NPM at: http://$(hostname -I | awk '{print $1}'):81"
        _pinfo "All proxy hosts, access lists, certificates and settings restored"
    else
        _pdone "Recovery complete"
    fi
}

# ---------------------------------------------------------------------------
# RECOVERY — NPM Docker
# ---------------------------------------------------------------------------
recover_docker() {
    section "Recovery — NPM Docker"

    ask_archive_path || die "No valid archive selected"
    local archive="${ARCHIVE_PATH}"

    local staging
    staging=$(extract_archive "${archive}")
    local staging_root
    staging_root=$(dirname "${staging}")
    _CLEANUP_DIR="${staging_root}"

    show_manifest "${staging}"

    echo ""
    _pinfo "Provide the host-side paths of your Docker volumes to restore into:"
    local default_data="/opt/nginx-proxy-manager/data"
    DOCKER_DATA_DIR=$(ask "Host path for /data volume" "${default_data}")
    local default_le="/opt/nginx-proxy-manager/letsencrypt"
    DOCKER_LETSENCRYPT_DIR=$(ask "Host path for /etc/letsencrypt volume (leave blank to skip)" "${default_le}")
    DOCKER_CONTAINER_NAME=$(ask "Docker container name (leave blank to skip service management)" "")

    # Pre-flight checks (use archive data dir)
    local pass=0 fail=0 warn=0
    precheck_header
    [[ -f "${staging}/${DATA_SUBDIR}/database.sqlite" ]] && \
        { _pok "database.sqlite in archive"; (( pass++ )) || true; } || \
        { _pfail "database.sqlite missing from archive"; (( fail++ )) || true; }
    [[ -f "${staging}/${DATA_SUBDIR}/keys.json" ]] && \
        { _pok "keys.json in archive"; (( pass++ )) || true; } || \
        { _pfail "keys.json missing from archive"; (( fail++ )) || true; }
    [[ -d "${staging}/${LETSENCRYPT_SUBDIR}" ]] && \
        { _pok "letsencrypt/ in archive"; (( pass++ )) || true; } || \
        { _pwarn "letsencrypt/ not in archive — SSL certs will not be restored"; (( warn++ )) || true; }
    if command -v rsync &>/dev/null; then
        _pok "rsync available"; (( pass++ )) || true
    elif command -v cp &>/dev/null; then
        _pok "cp available — rsync not installed, will use cp -a"; (( pass++ )) || true
    else
        _pfail "neither rsync nor cp found — cannot restore files"; (( fail++ )) || true
    fi
    precheck_summary "${pass}" "${fail}" "${warn}"
    [[ ${fail} -eq 0 ]] || die "Pre-flight checks failed."

    echo ""
    echo -e "  ${BOLD}Will restore:${NC}"
    _pinfo "data/        → ${DOCKER_DATA_DIR}/"
    [[ -n "${DOCKER_LETSENCRYPT_DIR}" ]] && \
        _pinfo "letsencrypt/ → ${DOCKER_LETSENCRYPT_DIR}/"
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  SECURITY NOTICE${NC}"
    echo -e "  ${YELLOW}This archive contains keys.json — restoring will replace the current encryption key.${NC}"
    echo ""
    confirm "Proceed with restore?" || { _pinfo "Recovery cancelled."; return; }

    # Stop container
    local stopped_container=false
    echo ""
    echo -e "  ${BOLD}Step 0/3 — Stopping container${NC}"
    if [[ -n "${DOCKER_CONTAINER_NAME}" ]] && command -v docker &>/dev/null; then
        if docker ps -q -f name="${DOCKER_CONTAINER_NAME}" 2>/dev/null | grep -q .; then
            docker stop "${DOCKER_CONTAINER_NAME}" &>/dev/null
            stopped_container=true
            _pdone "Container '${DOCKER_CONTAINER_NAME}' stopped"
        else
            _pskip "Container not running"
        fi
    else
        _pskip "No container name provided — skipped"
    fi


    # ── Step 1: Data volume ───────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 1/3 — Restoring data volume${NC}"
    check_existing_data "${DOCKER_DATA_DIR}" "NPM" || {
        ${stopped_container} && docker start "${DOCKER_CONTAINER_NAME}" &>/dev/null || true
        return
    }
    mkdir -p "${DOCKER_DATA_DIR}"
    if command -v rsync &>/dev/null; then
        rsync -a --delete "${staging}/${DATA_SUBDIR}/" "${DOCKER_DATA_DIR}/"
    else
        find "${DOCKER_DATA_DIR:?}" -mindepth 1 -delete
        cp -a "${staging}/${DATA_SUBDIR}/." "${DOCKER_DATA_DIR}/"
    fi
    _pdone "Data volume restored"
    [[ -f "${DOCKER_DATA_DIR}/keys.json" ]] && _pok "keys.json present"

    # Restore database (SQLite included in data/, or MySQL/Postgres from db-dump/)
    restore_database "${staging}"

    # ── Step 2: Let's Encrypt volume ──────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 2/3 — Restoring Let's Encrypt volume${NC}"
    if [[ -d "${staging}/${LETSENCRYPT_SUBDIR}" && -n "${DOCKER_LETSENCRYPT_DIR}" ]]; then
        check_existing_data "${DOCKER_LETSENCRYPT_DIR}" "Let's Encrypt" || true
        mkdir -p "${DOCKER_LETSENCRYPT_DIR}"
        if command -v rsync &>/dev/null; then
            rsync -a --delete "${staging}/${LETSENCRYPT_SUBDIR}/" "${DOCKER_LETSENCRYPT_DIR}/"
        else
            find "${DOCKER_LETSENCRYPT_DIR:?}" -mindepth 1 -delete
            cp -a "${staging}/${LETSENCRYPT_SUBDIR}/." "${DOCKER_LETSENCRYPT_DIR}/"
        fi
        local cert_count
        cert_count=$(find "${DOCKER_LETSENCRYPT_DIR}/live" -name "fullchain.pem" 2>/dev/null || true | wc -l)
        _pdone "Let's Encrypt volume restored (${cert_count} cert(s))"
    else
        _pskip "Let's Encrypt not in archive or no target path — skipped"
    fi

    # ── Step 3: Restart container ─────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Step 3/3 — Starting container${NC}"
    if ${stopped_container}; then
        docker start "${DOCKER_CONTAINER_NAME}" &>/dev/null
        sleep 3
        if docker ps -q -f name="${DOCKER_CONTAINER_NAME}" 2>/dev/null | grep -q .; then
            _pdone "Container '${DOCKER_CONTAINER_NAME}' restarted"
        else
            _pfail "Container did not restart — run: docker start ${DOCKER_CONTAINER_NAME}"
        fi
    else
        _pskip "Container management skipped"
    fi

    echo ""
    _pdone "Recovery complete"
}

# ---------------------------------------------------------------------------
# Source type submenu
# ---------------------------------------------------------------------------
source_menu() {
    local action="$1"
    echo ""
    echo -e "  ${BOLD}Select installation type:${NC}"
    echo ""
    echo -e "   ${CYAN}1)${NC} NPM Native  ${DIM}(installed with npm-installer.sh)${NC}"
    echo -e "   ${CYAN}2)${NC} NPM PVE LXC ${DIM}(ej52/proxmox-scripts — OpenResty + service: npm)${NC}"
    echo -e "   ${CYAN}3)${NC} NPM Docker  ${DIM}(official Docker image or docker-compose)${NC}"
    if [[ "${action}" == "recover" ]]; then
        echo -e "   ${CYAN}4)${NC} ${BOLD}Docker → Native${NC}  ${DIM}(migrate from Docker to Native install)${NC}"
    fi
    echo -e "   ${CYAN}q)${NC} Back"
    echo ""
    local choice choice_prompt
    [[ "${action}" == "recover" ]] && choice_prompt="Choice [1/2/3/4/q]" || choice_prompt="Choice [1/2/3/q]"
    choice=$(ask "${choice_prompt}")
    case "${choice}" in
        1) [[ "${action}" == "backup" ]] && backup_native  || recover_native false ;;
        2) [[ "${action}" == "backup" ]] && backup_pve     || recover_native false ;;
        3) [[ "${action}" == "backup" ]] && backup_docker  || recover_docker ;;
        4) [[ "${action}" == "recover" ]] && recover_native true || _pwarn "Invalid choice" ;;
        q|Q|"") return ;;
        *) _pwarn "Invalid choice: ${choice}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        show_splash
        echo -e "  ${BOLD}What would you like to do?${NC}"
        echo ""
        echo -e "   ${CYAN}1)${NC} ${BOLD}Backup${NC}    ${DIM}— Create a backup of NPM data, SSL certs, and configuration${NC}"
        echo -e "   ${CYAN}2)${NC} ${BOLD}Recovery${NC}  ${DIM}— Restore from a backup or migrate Docker → Native${NC}"
        echo -e "   ${CYAN}q)${NC} Quit"
        echo ""
        local choice
        choice=$(ask "Choice [1/2/q]")
        case "${choice}" in
            1) source_menu "backup"  ;;
            2) source_menu "recover" ;;
            q|Q|"") echo ""; _pinfo "Goodbye."; echo ""; exit 0 ;;
            *) _pwarn "Invalid choice: ${choice}" ;;
        esac
        echo ""
        confirm "Return to main menu?" || { _pinfo "Goodbye."; echo ""; exit 0; }
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    --help|-h)
        show_splash
        echo "  Usage: sudo bash npm-backrecov.sh [OPTIONS]"
        echo ""
        echo "  Options:"
        echo "    (none)         Interactive mode — shows menu"
        echo "    --help, -h     Show this help"
        echo ""
        echo "  Interactive menu:"
        echo "    1) Backup   — NPM Native or Docker"
        echo "    2) Recovery — NPM Native, Docker, or Docker → Native migration"
        echo ""
        exit 0
        ;;
    "") main_menu ;;
    *)  die "Unknown option: ${1}. Run with --help for usage." ;;
esac

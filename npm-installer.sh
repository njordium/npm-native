#!/usr/bin/env bash
# =============================================================================
#  Nginx Proxy Manager — Native Linux Installer v1.1.0 (Debian / Ubuntu)
#  No Docker  |  SQLite  |  Systemd  |  Team Njordium
#  Script Authors: Kim Haverblad & Tommy Jansson
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# User-tunable settings
# ---------------------------------------------------------------------------
# NPM_VERSION: auto-resolved to latest GitHub release unless overridden.
# The resolved version is shown in the splash and confirmed before install.
SCRIPT_VERSION="1.1.0"           # installer script version
NPM_VERSION="${NPM_VERSION:-}"   # empty = auto-detect latest
NODE_MAJOR="${NODE_MAJOR:-22}"
NPM_HOME="${NPM_HOME:-/opt/nginx-proxy-manager}"
NPM_DATA="${NPM_DATA:-/data}"
NPM_TMP="/tmp/npm-build"
NPM_SERVICE="nginx-proxy-manager"
ADMIN_PORT=81
INSTALL_MODE=""   # fresh | update | verify  (set by mode selection below)
VERBOSE=false     # true = show all step output, false = quiet (main steps only)

# ---------------------------------------------------------------------------
# ANSI colours
# ---------------------------------------------------------------------------
RED='\033[0;31m';   GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m';  BLUE='\033[0;34m';   MAGENTA='\033[0;35m'
BOLD='\033[1m';     DIM='\033[2m';        NC='\033[0m'

TS()     { date '+%Y-%m-%d %H:%M:%S'; }
log()    { echo -e "${GREEN}[✓]${NC} $(TS) $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $(TS) $*"; }
die()    { echo -e "\n${RED}[✗] FATAL:${NC} $(TS) $*\n" >&2; exit 1; }
banner() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }
# info(): visible only in verbose mode
info()   { ${VERBOSE} && echo -e "${CYAN}[→]${NC} $(TS) $*" || true; }
# step(): always visible — shows top-level progress
step()   { echo -e "${BOLD}${CYAN}[»]${NC} $(TS) ${BOLD}$*${NC}"; }
# vrun(): run a command, suppressing output unless verbose
vrun()   { if ${VERBOSE}; then "$@"; else "$@" &>/dev/null; fi; }
# _infoline(): print one info line in the existing-install summary.
# Deliberately no box/border — clean plain output with emoji bullet.
# label is fixed-width via printf (pure ASCII, locale-safe).
_infoline() {
    # _infoline <status_color> <bullet> <label> <value>
    local _col="$1" _bul="$2" _lbl="$3" _val="$4"
    printf "  %b%s%b  %-10s  %s\n" "${_col}" "${_bul}" "${NC}" "${_lbl}" "${_val}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-v)  NPM_VERSION="$2"; shift 2 ;;
        --fresh)       INSTALL_MODE="fresh";  shift ;;
        --update)      INSTALL_MODE="update"; shift ;;
        --verify)      INSTALL_MODE="verify"; shift ;;
        --verbose)     VERBOSE=true;  shift ;;
        --quiet)       VERBOSE=false; shift ;;
        --help|-h)
            echo "Usage: $0 [--version <x.y.z>] [--fresh|--update|--verify] [--verbose|--quiet]"
            echo "  --fresh    Fresh install (wipes database)"
            echo "  --update   Reinstall/update keeping database"
            echo "  --verify   Run verification tests only"
            echo "  --verbose  Show all step output"
            echo "  --quiet    Show main steps only (default)"
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Auto-detect latest NPM version from GitHub if not specified
# ---------------------------------------------------------------------------
if [[ -z "${NPM_VERSION}" ]]; then
    _LATEST=$(curl -sf --max-time 10         "https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest"         | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))"         2>/dev/null || true)
    if [[ -n "${_LATEST}" ]]; then
        NPM_VERSION="${_LATEST}"
    else
        NPM_VERSION="2.14.0"   # hard fallback if GitHub is unreachable
    fi
fi

# ---------------------------------------------------------------------------
# ASCII splash screen
# ---------------------------------------------------------------------------
clear
echo -e "${BOLD}${CYAN}"
cat << 'SPLASH'
    _   ____  __  ___
   / | / / /_  __/  |/ /___ _____  ____ _____ __________
  /  |/ / __ \/ // /|_/ / __ `/ __ \/ __ `/ __ `/ _ \/ ___/
 / /|  / /_/ / // /  / / /_/ / / / / /_/ / /_/ /  __/ /
/_/ |_/\_, /_//_/  /_/\__,_/_/ /_/\__,_/\__, /\___/_/
SPLASH
printf "${CYAN}       /___/                            /____/  v%s${NC}\n" "${SCRIPT_VERSION}"
echo -e "${NC}"
echo -e "  ${BOLD}${GREEN}Nginx Proxy Manager${NC}${BOLD} — Native Linux Installer${NC}"
echo -e "  ${DIM}No Docker · SQLite · Systemd · Team Njordium${NC}"
echo -e "  ${DIM}---------------------------------------------${NC}"
echo ""
echo -e "  ${CYAN}Version  :${NC} ${BOLD}v${NPM_VERSION}${NC}     ${CYAN}Node.js :${NC} ${BOLD}v${NODE_MAJOR} LTS${NC}"
echo -e "  ${CYAN}Install  :${NC} ${NPM_HOME}"
echo -e "  ${CYAN}Data     :${NC} ${NPM_DATA}"
echo -e "  ${CYAN}Database :${NC} SQLite (${NPM_DATA}/database.sqlite)"
echo -e "  ${CYAN}Service  :${NC} ${NPM_SERVICE}"
echo ""

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && die "This script must be run as root."

# Verify supported OS: Debian or Ubuntu
# CRITICAL: grep exits 1 when the pattern is not found.  Under set -euo pipefail
# that kills the script silently.  All grep calls here MUST have || true so that
# a missing field (e.g. Debian has no ID_LIKE line) is treated as empty, not fatal.
_OS_ID=$(grep -oP '(?<=^ID=)\w+' /etc/os-release 2>/dev/null || true)
_OS_ID=$(echo "${_OS_ID}" | tr '[:upper:]' '[:lower:]')
_OS_LIKE=$(grep -oP '(?<=^ID_LIKE=)[^\n]+' /etc/os-release 2>/dev/null || true)
_OS_LIKE=$(echo "${_OS_LIKE}" | tr '[:upper:]' '[:lower:]')
_OS_CODENAME=$(grep -oP '(?<=VERSION_CODENAME=)\w+' /etc/os-release 2>/dev/null || true)
_OS_PRETTY=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true)

if [[ "${_OS_ID}" == "debian" ]] || [[ "${_OS_ID}" == "ubuntu" ]] ||    [[ "${_OS_LIKE}" == *"debian"* ]]; then
    info "Detected OS: ${_OS_PRETTY:-unknown} (${_OS_CODENAME:-unknown})"
else
    die "Unsupported OS: ${_OS_PRETTY:-unknown}. This script supports Debian and Ubuntu."
fi

# ---------------------------------------------------------------------------
# Installation mode selection
# ---------------------------------------------------------------------------
# Detect whether an existing install is present
_HAS_SERVICE=false
_HAS_HOME=false
_HAS_DB=false
systemctl is-active --quiet "${NPM_SERVICE}" 2>/dev/null && _HAS_SERVICE=true
[[ -d "${NPM_HOME}/backend" ]]            && _HAS_HOME=true
[[ -f "${NPM_DATA}/database.sqlite" ]]    && _HAS_DB=true

if [[ -z "${INSTALL_MODE}" ]]; then
    if ${_HAS_SERVICE} || ${_HAS_HOME}; then
        # ── Existing installation detected ──────────────────────────────────
        echo ""
        echo -e "  ${BOLD}${YELLOW}Existing Nginx Proxy Manager installation detected${NC}"
        echo ""
        if ${_HAS_SERVICE}; then
            _infoline "${GREEN}" "●" "Service"  "running"
        else
            _infoline "${RED}"   "●" "Service"  "stopped"
        fi
        _infoline "${CYAN}" "●" "Home dir" "${NPM_HOME}"
        if ${_HAS_DB}; then
            DB_SIZE=$(du -sh "${NPM_DATA}/database.sqlite" 2>/dev/null | cut -f1)
            _infoline "${CYAN}" "●" "Database" "${NPM_DATA}/database.sqlite (${DB_SIZE})"
        else
            _infoline "${DIM}"  "○" "Database" "not found"
        fi
        echo ""   
        echo ""
        echo -e "  ${BOLD}Select an option:${NC}"
        echo ""
        echo -e "  ${BOLD}${RED}1)${NC} ${BOLD}Fresh install${NC}  — Full reinstall, ${RED}wipes database${NC} (clean slate)"
        echo -e "  ${BOLD}${YELLOW}2)${NC} ${BOLD}Update/reinstall${NC} — Reinstall NPM, ${GREEN}database preserved${NC}"
        echo -e "  ${BOLD}${GREEN}3)${NC} ${BOLD}Verify install${NC}  — Run health checks on the current installation"
        echo -e "  ${BOLD}${DIM}q)${NC} ${DIM}Quit${NC}"
        echo ""
        if [[ -t 0 ]]; then
            read -rp "  Choice [1/2/3/q]: " _CHOICE || true
        else
            _CHOICE=""
            warn "Non-interactive mode with existing install detected — aborting for safety."
            warn "Use --fresh, --update, or --verify flags for non-interactive execution."
            exit 1
        fi
        echo ""
        case "${_CHOICE}" in
            1) INSTALL_MODE="fresh"  ;;
            2) INSTALL_MODE="update" ;;
            3) INSTALL_MODE="verify" ;;
            q|Q|"") info "Aborted."; exit 0 ;;
            *) die "Invalid choice: ${_CHOICE}" ;;
        esac
    else
        # ── No existing installation ─────────────────────────────────────────
        echo -e "  ${GREEN}No existing installation found — proceeding with fresh install.${NC}"
        echo ""
        INSTALL_MODE="fresh"
    fi
fi

info "Mode: ${BOLD}${INSTALL_MODE}${NC}"

# ---------------------------------------------------------------------------
# Verbose mode question (only if not set via CLI flag and not verify mode)
# ---------------------------------------------------------------------------
if [[ "${INSTALL_MODE}" != "verify" ]]; then
    # Skip verbosity prompt when stdin is not a terminal (piped/non-interactive).
    # 'read' returns exit code 1 on EOF which kills the script under set -e.
    if [[ -t 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Output verbosity:${NC}"
        echo -e "  ${BOLD}${GREEN}1)${NC} Quiet ${DIM}(default)${NC}  — Show main steps only"
        echo -e "  ${BOLD}${CYAN}2)${NC} Verbose          — Show all output from every step"
        echo ""
        read -rp "  Verbosity [1/2, default=1]: " _VERB_CHOICE || true
        case "${_VERB_CHOICE}" in
            2) VERBOSE=true;  echo -e "  ${CYAN}Verbose mode enabled.${NC}" ;;
            *) VERBOSE=false; echo -e "  ${DIM}Quiet mode — only main steps will be shown.${NC}" ;;
        esac
        echo ""
    else
        info "Non-interactive mode — using quiet output (pass --verbose to override)."
    fi
fi

# ---------------------------------------------------------------------------
# ── VERIFY mode — full installation health dashboard ────────────────────────
# ---------------------------------------------------------------------------
if [[ "${INSTALL_MODE}" == "verify" ]]; then
    _PASS=0; _FAIL=0; _WARN=0
    _pok()  { echo -e "  ${GREEN}[PASS]${NC} $*"; (( _PASS += 1 )) || true; }
    _pfail(){ echo -e "  ${RED}[FAIL]${NC} $*"; (( _FAIL += 1 )) || true; }
    _pwarn(){ echo -e "  ${YELLOW}[WARN]${NC} $*"; (( _WARN += 1 )) || true; }
    _sect() { echo ""; echo -e "${BOLD}── $* ──${NC}"; }

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   Nginx Proxy Manager — Installation Verification            ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${DIM}Host: $(hostname)   IP: $(hostname -I | awk '{print $1}')   $(date '+%Y-%m-%d %H:%M:%S')${NC}"

    # ── Services ─────────────────────────────────────────────────────────────
    _sect "Services"
    if systemctl is-active --quiet "${NPM_SERVICE}" 2>/dev/null; then
        _NPM_PID=$(systemctl show -p MainPID "${NPM_SERVICE}" 2>/dev/null | cut -d= -f2)
        _NPM_MEM=$(systemctl show -p MemoryCurrent "${NPM_SERVICE}" 2>/dev/null | cut -d= -f2)
        _NPM_MEM_MB=$(( ${_NPM_MEM:-0} / 1024 / 1024 )) 2>/dev/null || _NPM_MEM_MB="?"
        _NPM_UP=$(systemctl show -p ActiveEnterTimestamp "${NPM_SERVICE}" 2>/dev/null | cut -d= -f2)
        _pok  "nginx-proxy-manager  active  PID=${_NPM_PID}  MEM=${_NPM_MEM_MB}MB"
        echo -e "       ${DIM}since: ${_NPM_UP}${NC}"
    else
        _pfail "nginx-proxy-manager  NOT running"
        echo  "       → run: systemctl start ${NPM_SERVICE}"
    fi
    if systemctl is-enabled --quiet "${NPM_SERVICE}" 2>/dev/null; then
        _pok  "nginx-proxy-manager  enabled (auto-starts on reboot)"
    else
        _pwarn "nginx-proxy-manager  NOT enabled — won't start after reboot"
    fi
    if systemctl is-active --quiet nginx 2>/dev/null; then
        _NGINX_V=$(nginx -v 2>&1 | grep -oP 'nginx/[\d.]+' || echo "nginx")
        _pok  "nginx                active  (${_NGINX_V})"
    else
        _pfail "nginx                NOT running"
    fi
    if nginx -t &>/dev/null 2>&1; then
        _pok  "nginx config         syntax OK"
    else
        _pfail "nginx config         FAILED — run: nginx -t"
    fi

    # ── Network ──────────────────────────────────────────────────────────────
    # NOTE: All API checks go through nginx on port ${ADMIN_PORT}, NOT port 3000 directly.
    # nginx: /api/ -> proxy_pass http://127.0.0.1:3000/ (strips /api/ prefix).
    # Hitting 127.0.0.1:3000/api/ sends /api/ to Node which has no such route -> 404.
    _sect "Network & API"

    # Backend process: check port 3000 is bound (ss is reliable, no HTTP path issues)
    if ss -tlnp 2>/dev/null | grep -q ':3000 '; then
        _pok  "backend process      port 3000 bound (Node.js backend listening)"
    else
        _pfail "backend process      port 3000 NOT bound — Node.js backend not running"
    fi

    # API health — try via nginx first, fall back to direct backend check
    _API_RESP=$(curl -sf --max-time 4 "http://127.0.0.1:${ADMIN_PORT}/api/" 2>/dev/null || echo "{}")
    _API_STATUS=$(echo "${_API_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "ERR")
    if [[ "${_API_STATUS}" == "OK" ]]; then
        _pok  "backend API          http://127.0.0.1:${ADMIN_PORT}/api/ -> {status:OK}"
    else
        # nginx may be down — check backend directly on port 3000
        _API_DIRECT=$(curl -sf --max-time 4 "http://127.0.0.1:3000/" 2>/dev/null || echo "{}")
        _API_DIRECT_STATUS=$(echo "${_API_DIRECT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "ERR")
        if [[ "${_API_DIRECT_STATUS}" == "OK" ]]; then
            _pwarn "backend API          responding on :3000 directly but NOT via nginx port ${ADMIN_PORT} — nginx is down"
            echo  "       → run: systemctl start nginx"
        else
            _pfail "backend API          not responding on port ${ADMIN_PORT} or :3000 directly (nginx down + backend issue)"
        fi
    fi

    # Admin UI (nginx serves React SPA)
    _UI_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "http://127.0.0.1:${ADMIN_PORT}/" 2>/dev/null || echo "000")
    _UI_CT=$(curl -s -I --max-time 4 "http://127.0.0.1:${ADMIN_PORT}/" 2>/dev/null | grep -i "^content-type" | tr -d '\r' | head -1)
    if [[ "${_UI_HTTP}" =~ ^[23] ]]; then
        _pok  "admin UI             http://$(hostname -I | awk '{print $1}'):${ADMIN_PORT}/ -> HTTP ${_UI_HTTP}"
    else
        _pfail "admin UI             port ${ADMIN_PORT} not responding (HTTP ${_UI_HTTP})"
    fi
    if echo "${_UI_CT}" | grep -qi "text/html"; then
        _pok  "admin UI             serving HTML (React SPA)"
    else
        _pwarn "admin UI             unexpected content-type: ${_UI_CT}"
    fi

    # Version check via nginx -> backend -> GitHub API
    _VER_RESP=$(curl -sf --max-time 8 "http://127.0.0.1:${ADMIN_PORT}/api/version/check" 2>/dev/null || echo "{}")
    _VER_CURRENT=$(echo "${_VER_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('current','?'))" 2>/dev/null || echo "?")
    _VER_LATEST=$(echo "${_VER_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest','?'))" 2>/dev/null || echo "?")
    _VER_UPDATE=$(echo "${_VER_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('update_available',False))" 2>/dev/null || echo "?")
    if [[ "${_VER_CURRENT}" != "?" && "${_VER_CURRENT}" != "null" && "${_VER_CURRENT}" != "v?" ]]; then
        if [[ "${_VER_UPDATE}" == "False" || "${_VER_UPDATE}" == "false" ]]; then
            _pok  "version              current=${_VER_CURRENT}  latest=${_VER_LATEST}  up to date"
        else
            _pwarn "version              current=${_VER_CURRENT}  latest=${_VER_LATEST}  update available"
        fi
    else
        _pwarn "version              could not reach GitHub API (offline?)"
    fi
    # ── Setup state ──────────────────────────────────────────────────────────
    # API: {"setup": true}  = setup wizard still needed (no admin account yet)
    #      {"setup": false} = setup complete (admin account exists, wizard closed)
    _sect "Setup State"
    _SETUP_RESP=$(curl -sf --max-time 4 "http://127.0.0.1:${ADMIN_PORT}/api/" 2>/dev/null         | python3 -c "import sys,json; d=json.load(sys.stdin); print('setup_done' if d.get('setup') else 'setup_needed')"         2>/dev/null || echo "unknown")
    if [[ "${_SETUP_RESP}" == "setup_done" ]]; then
        _pok  "admin account        created — setup wizard complete"
    elif [[ "${_SETUP_RESP}" == "setup_needed" ]]; then
        _pwarn "admin account        NOT created yet — visit http://$(hostname -I | awk '{print $1}'):${ADMIN_PORT}/ to set up"
    else
        _pwarn "admin account        could not determine setup state"
    fi

    # ── File system ──────────────────────────────────────────────────────────
    _sect "File System"
    [[ -f "${NPM_HOME}/backend/index.js" ]]         && _pok  "backend              ${NPM_HOME}/backend/index.js"         || _pfail "backend              index.js MISSING at ${NPM_HOME}/backend/"
    [[ -f "${NPM_HOME}/frontend/index.html" ]]         && _pok  "frontend             ${NPM_HOME}/frontend/index.html"         || _pfail "frontend             index.html MISSING — UI will not load"
    [[ -d "${NPM_HOME}/frontend/lang" ]]         && { _LANG_COUNT=$(ls "${NPM_HOME}/frontend/lang/"*.json 2>/dev/null | wc -l)
             _pok  "locales              ${NPM_HOME}/frontend/lang/ (${_LANG_COUNT} files)"; }         || _pwarn "locales              lang/ missing — UI may show raw i18n keys"
    if [[ -f "${NPM_DATA}/database.sqlite" ]]; then
        _DB_SIZE=$(du -sh "${NPM_DATA}/database.sqlite" 2>/dev/null | cut -f1)
        _pok  "database             ${NPM_DATA}/database.sqlite (${_DB_SIZE})"
    else
        _pfail "database             ${NPM_DATA}/database.sqlite MISSING"
    fi
    _pok  "data dir             ${NPM_DATA}/logs $(du -sh ${NPM_DATA}/logs 2>/dev/null | cut -f1 || echo '')"
    [[ -f "${NPM_HOME}/backend/config/production.json" ]]         && _pok  "config               production.json present"         || _pfail "config               production.json MISSING"

    # ── Native modules ───────────────────────────────────────────────────────
    _sect "Native Modules"
    if ( cd "${NPM_HOME}/backend" && node -e "require('bcrypt')" &>/dev/null 2>&1 ); then
        _BCRYPT_VER=$(cd "${NPM_HOME}/backend" && node -e "const b=require('bcrypt'); console.log(b.getRounds ? 'ok' : 'ok')" 2>/dev/null || echo "ok")
        _pok  "bcrypt               loads OK (password hashing)"
    else
        _pfail "bcrypt               FAILED to load — backend will crash on login"
    fi
    for _sq in better-sqlite3 sqlite3; do
        if ( cd "${NPM_HOME}/backend" && node -e "require('${_sq}')" &>/dev/null 2>&1 ); then
            _pok  "${_sq}      loads OK (database driver)"; break
        fi
    done || _pfail "sqlite               no SQLite driver loads (better-sqlite3 or sqlite3)"

    # ── Configuration ────────────────────────────────────────────────────────
    _sect "Configuration"
    _PROD="${NPM_HOME}/backend/config/production.json"
    if [[ -f "${_PROD}" ]]; then
        _DB_CLIENT=$(python3 -c "import json; d=json.load(open('${_PROD}')); print(d['database']['knex']['client'])" 2>/dev/null || echo "?")
        _DB_FILE=$(python3 -c "import json; d=json.load(open('${_PROD}')); print(d['database']['knex']['connection']['filename'])" 2>/dev/null || echo "?")
        if [[ "${_DB_CLIENT}" == "better-sqlite3" ]]; then
            _pok  "db client            ${_DB_CLIENT} (isSqlite()=true → uses datetime('now'))"
        else
            _pfail "db client            '${_DB_CLIENT}' — must be 'better-sqlite3' or NOW() errors occur"
        fi
        _pok  "db file              ${_DB_FILE}"
    fi
    grep -q 'proxy_pass.*127.0.0.1:3000' /etc/nginx/nginx.conf 2>/dev/null         && _pok  "nginx proxy          port ${ADMIN_PORT} → :3000 present"         || _pfail "nginx proxy          port ${ADMIN_PORT} → :3000 missing in nginx.conf"

    # Certbot virtualenv — required for DNS challenge certificate requests
    if [[ -f "/opt/certbot/bin/activate" ]]; then
        _CB_VER=$(/opt/certbot/bin/certbot --version 2>&1 | grep -oP '[\d.]+' | head -1)
        _pok  "certbot venv         /opt/certbot (v${_CB_VER}) — DNS plugins will install correctly"
    else
        _pfail "certbot venv         /opt/certbot MISSING — DNS challenge cert requests will fail"
        echo  "       → run: python3 -m venv /opt/certbot && /opt/certbot/bin/pip install certbot"
    fi

    # Check Docker rootfs include files — required for proxy host config generation
    _MISS=0
    for _INC in proxy.conf block-exploits.conf force-ssl.conf ssl-ciphers.conf; do
        [[ ! -f "/etc/nginx/conf.d/include/${_INC}" ]] && {
            _pfail "nginx include /etc/nginx/conf.d/include/${_INC} MISSING — proxy hosts will not write nginx configs"
            _MISS=$(( _MISS + 1 ))
        }
    done
    [[ ${_MISS} -eq 0 ]] && _pok "nginx conf.d/include files present (proxy.conf, block-exploits.conf, etc.)"

    # nginx -t — if this fails, proxy host config creation silently rolls back
    if nginx -t &>/dev/null 2>&1; then
        _pok  "nginx -t syntax OK (proxy host config creation will succeed)"
    else
        _pfail "nginx -t FAILED — proxy host config creation will silently roll back (run: nginx -t)"
    fi

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    _TOTAL=$(( _PASS + _FAIL + _WARN ))
    echo -e "  ${GREEN}${_PASS} passed${NC}  ${RED}${_FAIL} failed${NC}  ${YELLOW}${_WARN} warnings${NC}  / ${_TOTAL} total checks"
    echo ""
    if [[ ${_FAIL} -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}✗  Installation has problems. See FAIL items above.${NC}"
        echo ""
        exit 1
    elif [[ ${_WARN} -gt 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}⚠  Installation OK with warnings.${NC}"
    else
        echo -e "  ${GREEN}${BOLD}✓  All checks passed. NPM is healthy and fully operational.${NC}"
    fi
    HOST_IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "  ${CYAN}Admin Panel :${NC} ${BOLD}http://${HOST_IP}:${ADMIN_PORT}${NC}"
    echo -e "  ${CYAN}Version     :${NC} ${_VER_CURRENT}"
    echo ""
    exit 0
fi
# ---------------------------------------------------------------------------
# Pre-install actions based on mode
# ---------------------------------------------------------------------------
if [[ "${INSTALL_MODE}" == "fresh" ]]; then
    if ${_HAS_DB}; then
        echo -e "${RED}┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}│  WARNING: Fresh install will permanently DELETE the database! │${NC}"
        echo -e "${RED}│  All proxy hosts, SSL certificates, and users will be lost.  │${NC}"
        echo -e "${RED}└──────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        read -rp "  Type YES to confirm database wipe: " _DB_CONFIRM || true
        [[ "${_DB_CONFIRM}" == "YES" ]] || { info "Aborted — database not touched."; exit 0; }
    fi
    # Stop and backup
    systemctl stop "${NPM_SERVICE}" 2>/dev/null || true
    if [[ -f "${NPM_DATA}/database.sqlite" ]]; then
        DB_BACKUP="${NPM_DATA}/database.sqlite.bak.$(date +%Y%m%d%H%M%S)"
        cp "${NPM_DATA}/database.sqlite" "${DB_BACKUP}"
        warn "Database backed up to: ${DB_BACKUP}"
        rm -f "${NPM_DATA}/database.sqlite"
        info "Database wiped — starting fresh."
    fi
elif [[ "${INSTALL_MODE}" == "update" ]]; then
    systemctl stop "${NPM_SERVICE}" 2>/dev/null || true
    if ${_HAS_DB}; then
        DB_BACKUP="${NPM_DATA}/database.sqlite.bak.$(date +%Y%m%d%H%M%S)"
        cp "${NPM_DATA}/database.sqlite" "${DB_BACKUP}"
        log "Database backed up to: ${DB_BACKUP}"
    fi
    info "Database preserved — update mode."
fi
echo ""


# ---------------------------------------------------------------------------
# Step 1 — System dependencies
# ---------------------------------------------------------------------------
step "Step 1/7 — Installing system dependencies"

export DEBIAN_FRONTEND=noninteractive

vrun apt-get update -qq

vrun apt-get install -y --no-install-recommends \
    curl \
    wget \
    gnupg \
    ca-certificates \
    lsb-release \
    apt-transport-https \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    openssl \
    libssl-dev \
    libffi-dev \
    logrotate \
    git \
    sqlite3 \
    apache2-utils \
    jq \
    rsync \
    nginx \
    libnginx-mod-stream \
    certbot \
    python3-certbot-nginx

log "System packages installed."

# ---------------------------------------------------------------------------
# Create /opt/certbot Python virtualenv
# ---------------------------------------------------------------------------
# NPM's DNS plugin installer (lib/certbot.js) always runs:
#   . /opt/certbot/bin/activate && pip install <plugin> && deactivate
# This virtualenv MUST exist or all DNS challenge cert requests fail with
# "No such file or directory: /opt/certbot/bin/activate".
# The venv certbot is also added FIRST in PATH in the systemd unit so that
# when certbot runs DNS challenges it uses /opt/certbot/bin/certbot, which
# can find the DNS plugins installed into the same venv.
step "Creating certbot virtualenv at /opt/certbot"
python3 -m venv /opt/certbot
vrun /opt/certbot/bin/pip install --quiet --upgrade pip
vrun /opt/certbot/bin/pip install --quiet certbot
log "certbot virtualenv ready: $(/opt/certbot/bin/certbot --version 2>&1)" 

# ---------------------------------------------------------------------------
# Step 2 — Node.js (via NodeSource)
# ---------------------------------------------------------------------------
step "Step 2/7 — Installing Node.js ${NODE_MAJOR} LTS"

# Detect existing Node.js and check if it meets the required major version.
# NOTE: Debian Trixie ships nodejs v20 in its own repos but does NOT include
# npm alongside it. We always prefer nodesource to get both node + npm together.
_NEED_NODE=true
if command -v node &>/dev/null; then
    EXISTING_NODE=$(node --version 2>/dev/null | grep -oP '\d+' | head -1)
    if [[ "${EXISTING_NODE}" -ge "${NODE_MAJOR}" ]]; then
        log "Node.js $(node --version) already installed — skipping."
        _NEED_NODE=false
    else
        warn "Node.js $(node --version) is too old (need v${NODE_MAJOR}+). Upgrading..."
        vrun apt-get remove -y nodejs npm 2>/dev/null || true
    fi
fi

if ${_NEED_NODE}; then
    # Run the nodesource setup script — this adds the nodesource APT repo.
    # Double quotes are CRITICAL: they let ${NODE_MAJOR} expand to '22' before
    # being passed to bash. Single quotes would send the literal string
    # '${NODE_MAJOR}' to curl → nodesource returns 404 → silent failure.
    info "Setting up NodeSource repository for Node.js ${NODE_MAJOR}..."
    if bash -c "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -"        &>/dev/null 2>&1; then
        info "NodeSource repo configured."
        vrun apt-get install -y nodejs
    else
        warn "NodeSource setup failed — falling back to system nodejs+npm packages."
        vrun apt-get install -y nodejs npm
    fi

    # Verify we got the right Node.js version
    _INSTALLED=$(node --version 2>/dev/null | grep -oP '\d+' | head -1)
    if [[ -n "${_INSTALLED}" && "${_INSTALLED}" -ge "${NODE_MAJOR}" ]]; then
        log "Node.js $(node --version) installed."
    else
        warn "Node.js ${NODE_MAJOR}+ could not be installed (got: $(node --version 2>/dev/null || echo 'none'))."
        warn "Continuing — pnpm install may fail if node version is too old."
    fi
fi

# Ensure npm is available — nodesource nodejs bundles npm, but Debian's
# nodejs package does NOT. Install separately only if truly missing.
if ! command -v npm &>/dev/null; then
    warn "npm not found — installing npm separately..."
    # Try installing npm that matches the installed Node version via npm itself
    # (corepack is available in Node 22+ and is the preferred approach)
    if command -v corepack &>/dev/null; then
        vrun corepack enable npm
    else
        vrun apt-get install -y npm
    fi
fi

# Final version check — both must be present for pnpm install to succeed
if ! command -v npm &>/dev/null; then
    die "npm is not available after installation. Cannot continue without npm (needed for pnpm install)."
fi

info "node : $(node --version 2>/dev/null || echo not-found)"
info "npm  : $(npm --version 2>/dev/null || echo not-found)"

# ---------------------------------------------------------------------------
# Step 3 — Clone NPM source via git (full working tree, no export-ignore gaps)
# ---------------------------------------------------------------------------
step "Step 3/7 — Cloning NPM v${NPM_VERSION} source"

# WHY git clone instead of the GitHub release tarball:
#
# GitHub tarballs apply .gitattributes export-ignore rules, silently stripping
# directories from the archive. For NPM 2.13.5+, this excludes the entire
# frontend/src/locale/lang/*.json directory — causing TS2307 build failures.
#
# git clone --depth 1 fetches the exact tagged commit's complete working tree,
# bypassing export rules. Shallow clone = no history, fast and lean.
command -v git &>/dev/null || apt-get install -y --no-install-recommends git -qq

# Clean and recreate build workspace
rm -rf "${NPM_TMP}"

GIT_URL="https://github.com/NginxProxyManager/nginx-proxy-manager.git"
info "Cloning v${NPM_VERSION} (shallow, ~60 MB)..."
vrun git clone --depth 1 --branch "v${NPM_VERSION}" "${GIT_URL}" "${NPM_TMP}" --config advice.detachedHead=false
[[ -d "${NPM_TMP}/frontend" ]] || die "Clone incomplete — frontend/ directory missing."

log "Source cloned to ${NPM_TMP}" 

# ---------------------------------------------------------------------------
# Build the frontend
# ---------------------------------------------------------------------------
step "Step 4/7 — Building frontend (this may take a few minutes)"

# Write the vite chunk-splitting patch script to /tmp (used later in this step)
cat > /tmp/_vite_patch.py << 'VITE_PATCH_EOF'
import re, sys
cfg_path = sys.argv[1]
with open(cfg_path) as f:
    src = f.read()

# Safe chunking strategy:
# - Isolate @tabler/icons-react (~800 kB of SVG icon exports) — pure, no React dep
# - Raise the warning limit to 2200 kB so the remaining main bundle doesn't warn
# - DO NOT manually split react/react-intl/tanstack etc. — those packages have
#   circular transitive deps that cause rollup to emit:
#     "Circular chunk: vendor-X -> vendor-react -> vendor-X"
#   followed by collapsing everything into a single vendor-misc chunk anyway,
#   which is LARGER than the original and also broken (load-order undefined).
# Result: two output chunks — vendor-icons (~800 kB) + main bundle (~1,200 kB)
# vs original one chunk at 2,059 kB. Warning eliminated. No load-order bug.
build_section = """
  build: {
    chunkSizeWarningLimit: 2200,
    rollupOptions: {
      output: {
        manualChunks(id) {
          // @tabler/icons-react is pure SVG re-exports with no React peer dep issues
          if (id.includes('@tabler/icons-react')) return 'vendor-icons';
        }
      }
    }
  },"""
patched = re.sub(r'(\}\s*\)\s*;?\s*)$', build_section + r'\1', src, count=1, flags=re.DOTALL)
with open(cfg_path, 'w') as f:
    f.write(patched)
print("vite.config.ts patched: icons split out, warning limit raised")
VITE_PATCH_EOF

cd "${NPM_TMP}/frontend"

# ── Install pnpm ─────────────────────────────────────────────────────────────
# NPM 2.12+ uses pnpm as its package manager. Older releases used npm, but
# they also have known CVEs (CVE-2024-46256, CVE-2024-46257 in 2.11.x).
# The community-proven build sequence for all current NPM releases is:
#   pnpm install → pnpm upgrade → pnpm run build
# 'pnpm upgrade' is essential: it resolves any GitHub-pinned or stale deps
# (resolves any stale, pinned, or incompatible dependencies automatically).
# ---------------------------------------------------------------------------
info "Installing build tools and pnpm..."
# node-gyp is required for bcrypt 6.x and other native C++ addons
if ! command -v node-gyp &>/dev/null; then
    vrun npm install -g node-gyp --quiet
fi
vrun npm install -g pnpm@latest --silent
info "pnpm $(pnpm --version) ready."

# ── Patch react-intl → v10 ───────────────────────────────────────────────────
# NPM 2.14.0 pins "react-intl": "^8.1.3" — deprecated ("Bad version, use v9").
# But v9.0.0 is ALSO deprecated ("Use v10 instead — versioning got out of order")
# and critically broken: it declares "@formatjs/intl@workspace:*" which is a
# monorepo-internal reference that fails on any normal npm/pnpm install.
#
# Version status (verified via npm registry):
#   8.1.4  — not deprecated, last clean v8 release
#   8.2.0  — DEPRECATED ("use v9")
#   9.0.0  — DEPRECATED + BROKEN (workspace:* dep, install fails)
#   10.1.1 — current stable, not deprecated
#
# API audit of NPM 2.14.0 frontend: only uses RawIntlProvider, createIntl,
# and createIntlCache. The v10 upgrade guide confirms the only breaking change
# is removal of the injectIntl HOC — which NPM does not use.
# All three APIs are unchanged in v10. Zero source code changes required.
# Patch BEFORE pnpm install so the resolver picks v10 from the start.
_FRONTEND_PKG="${NPM_TMP}/frontend/package.json"
if grep -q '"react-intl"' "${_FRONTEND_PKG}" 2>/dev/null; then
    jq '.dependencies["react-intl"] = "^10.0.0"' "${_FRONTEND_PKG}"         > "${_FRONTEND_PKG}.tmp" && mv "${_FRONTEND_PKG}.tmp" "${_FRONTEND_PKG}"
    info "react-intl patched: ^8.x → ^10.0.0 (v9 broken/deprecated; v10 API-compatible)"
fi

info "Installing frontend dependencies..."
# --reporter=silent suppresses deprecation WARNs from upstream package.json pins
# (e.g. react-intl@8.x deprecated by upstream). These are informational only
# and don't affect functionality. In verbose mode, full output is shown.
if ${VERBOSE}; then
    pnpm install
else
    pnpm install --reporter=silent 2>/dev/null || pnpm install &>/dev/null
fi

info "Upgrading frontend dependencies to latest compatible versions..."
if ${VERBOSE}; then
    pnpm upgrade
else
    pnpm upgrade --reporter=silent 2>/dev/null || pnpm upgrade &>/dev/null
fi

# ---------------------------------------------------------------------------
# Patch: generate missing locale JSON stubs
#
# Root cause: NPM 2.13.5+ manages translations via Crowdin. The lang/*.json
# files are downloaded during Docker CI builds but are NEVER committed to
# the git repo, so both git clone and tarballs are missing them.
# IntlProvider.tsx imports each locale by name, so TypeScript fails with
# TS2307 before vite even starts.
#
# Fix: scan IntlProvider.tsx for all locale imports, and create {} stub
# files for any that are missing. The UI falls back to English gracefully.
# ---------------------------------------------------------------------------
info "Checking for missing locale JSON stubs (Crowdin-managed, absent from git)..."

LANG_DIR="${NPM_TMP}/frontend/src/locale/lang"
INTL_FILE="${NPM_TMP}/frontend/src/locale/IntlProvider.tsx"
mkdir -p "${LANG_DIR}"

# ---------------------------------------------------------------------------
# Locale population: 3-phase approach
#   1. Fetch canonical English from upstream develop branch (compile to flat)
#   2. Write empty {} stubs for all other locales imported by IntlProvider
#   3. Write lang-list.json for the language picker
# ---------------------------------------------------------------------------
python3 - "${LANG_DIR}" "${INTL_FILE}" "${VERBOSE}" << 'PYEOF'
import sys, re, os, json
try:
    from urllib.request import urlopen
    _urllib_ok = True
except Exception:
    _urllib_ok = False

lang_dir, intl_file = sys.argv[1], sys.argv[2]
verbose = len(sys.argv) > 3 and sys.argv[3] == "true"
def vprint(*a): verbose and print(*a)
if not os.path.isfile(intl_file):
    print("  IntlProvider.tsx not found - skipping"); sys.exit(0)

with open(intl_file) as fh:
    src = fh.read()
imports = re.findall(r'from\s+[\'"]./lang/([^\'"]+\.json)[\'"]', src)

# Phase 1 - English: fetch from upstream and compile to flat format
en_path = os.path.join(lang_dir, "en.json")
en_written = False
if _urllib_ok:
    URL = ("https://raw.githubusercontent.com/NginxProxyManager"
           "/nginx-proxy-manager/develop/frontend/src/locale/src/en.json")
    try:
        with urlopen(URL, timeout=10) as r:
            src_data = json.loads(r.read())
        en_flat = {k: v.get("defaultMessage", "")
                   for k, v in src_data.items() if isinstance(v, dict)}
        with open(en_path, "w") as f:
            json.dump(en_flat, f, indent=2, ensure_ascii=False)
        vprint("  en.json: {} keys from upstream".format(len(en_flat)))
        en_written = True
    except Exception as exc:
        vprint("  en.json: fetch failed ({}) - using stub".format(exc))
if not en_written and not os.path.isfile(en_path):
    with open(en_path, "w") as f: f.write("{}")
    vprint("  en.json: empty stub (offline)")

# Phase 2 - other locales: empty stubs
created = []
for fname in imports:
    if fname in ("en.json", "lang-list.json"):
        continue
    fpath = os.path.join(lang_dir, fname)
    if not os.path.isfile(fpath):
        with open(fpath, "w") as out: out.write("{}")
        created.append(fname)
        vprint("  created stub: {}".format(fname))

# Phase 3 - lang-list.json: locale display names for the picker
ll_path = os.path.join(lang_dir, "lang-list.json")
if not os.path.isfile(ll_path):
    codes = sorted({os.path.splitext(g)[0] for g in imports
                    if g.endswith(".json") and g != "lang-list.json"})
    names = {"en":"English","de":"Deutsch","es":"Espanol","fr":"Francais",
             "ga":"Gaeilge","it":"Italiano","ja":"Japanese","ko":"Korean",
             "nl":"Nederlands","pl":"Polski","pt":"Portugues","ru":"Russian",
             "sk":"Slovenčina","vi":"Vietnamese","zh":"Chinese","bg":"Bulgarian",
             "id":"Indonesian","tr":"Turkce","hu":"Magyar","cs":"Cestina",
             "no":"Norsk","et":"Eesti"}
    ll = {c: names.get(c, c.upper()) for c in codes}
    with open(ll_path, "w") as f:
        json.dump(ll, f, indent=2, ensure_ascii=False)
    vprint("  lang-list.json: {} locales".format(len(ll)))

vprint("  locale setup complete ({} stubs).".format(len(created)))
PYEOF

info "Locale check complete." 


# ── Patch vite.config.ts: split 2 MB main bundle into vendor chunks ─────────
# Vite by default outputs one ~2,059 kB chunk. manualChunks splits it into
# parallel-loadable vendor chunks, eliminating the "> 500 kB" build warning.
_VITE_CFG="${NPM_TMP}/frontend/vite.config.ts"
if [[ -f "${_VITE_CFG}" ]]; then
    python3 /tmp/_vite_patch.py "${_VITE_CFG}" \
        && info "vite.config.ts: manualChunks applied (vendor chunk splitting)" \
        || warn "vite.config.ts patch failed — build continues without chunk split"
fi

info "Running production build..."
if ${VERBOSE}; then pnpm run build; else vrun pnpm run build; fi

log "Frontend build complete."

# ---------------------------------------------------------------------------
# Install backend node_modules (production only)
# ---------------------------------------------------------------------------
step "Step 5/7 → 6/7 — Assembling install directory"

# ---------------------------------------------------------------------------
# Assemble install dir FIRST, then install backend deps in-place
# ---------------------------------------------------------------------------
# WHY: pnpm uses hard-links to a global content-addressable store plus
# symlinks within node_modules/. Installing in the temp dir then copying
# can leave symlinks dangling and native binaries (sqlite3.node) unresolvable.
# Install directly in the final location to guarantee correct resolution.

step "Step 6/7 — Installing backend dependencies and configuring"

# Backup existing install if present
if [[ -d "${NPM_HOME}" ]]; then
    BACKUP="${NPM_HOME}.bak-$(date +%Y%m%d%H%M%S)"
    warn "Existing install found — backing up to ${BACKUP}"
    mv "${NPM_HOME}" "${BACKUP}"
fi

mkdir -p "${NPM_HOME}"

# Copy backend SOURCE files only — exclude node_modules (installing fresh below)
info "Copying backend source files..."
if command -v rsync &>/dev/null; then
    vrun rsync -a --exclude='node_modules' --exclude='pnpm-lock.yaml' "${NPM_TMP}/backend/" "${NPM_HOME}/backend/"
    mkdir -p "${NPM_HOME}/backend"
    # shellcheck disable=SC2046
    cp -r $(find "${NPM_TMP}/backend" -mindepth 1 -maxdepth 1         ! -name 'node_modules' -printf '%p ') "${NPM_HOME}/backend/" 2>/dev/null ||     ( cd "${NPM_TMP}/backend" && find . -mindepth 1 -maxdepth 1         ! -name 'node_modules' -exec cp -r {} "${NPM_HOME}/backend/" \; )
fi

# Also copy the pnpm-lock.yaml for reproducible install
[[ -f "${NPM_TMP}/backend/pnpm-lock.yaml" ]] &&     cp "${NPM_TMP}/backend/pnpm-lock.yaml" "${NPM_HOME}/backend/"

# ---------------------------------------------------------------------------
# Patch backend/package.json version (MUST run before pnpm install)
# ---------------------------------------------------------------------------
# remote-version.js uses ESM static import: import pjson from "../package.json"
# Node.js caches this at process startup — the version is locked for the lifetime
# of the service. Patching here (after rsync, before pnpm install) ensures the
# correct version string is baked in when systemd starts the service.
# Result: footer shows v${NPM_VERSION} and update_available = false.
_PKGJSON="${NPM_HOME}/backend/package.json"
_BEFORE=$(python3 -c "import json; print(json.load(open('${_PKGJSON}'))['version'])" 2>/dev/null || echo "?")
jq --arg v "${NPM_VERSION}" '.version = $v' "${_PKGJSON}" > "${_PKGJSON}.tmp" \
    && mv "${_PKGJSON}.tmp" "${_PKGJSON}"
_AFTER=$(python3 -c "import json; print(json.load(open('${_PKGJSON}'))['version'])" 2>/dev/null || echo "error")
if [[ "${_AFTER}" == "${NPM_VERSION}" ]]; then
    info "Version patched: ${_BEFORE} → v${_AFTER}"
else
    warn "Version patch failed — footer may show wrong version (got ${_AFTER})"
fi

info "Installing backend node_modules in final location..."
cd "${NPM_HOME}/backend"

# ---------------------------------------------------------------------------
# pnpm v10 "approve-builds" security gate
# ---------------------------------------------------------------------------
# pnpm v10 blocks ALL postinstall/build scripts by default. C++ native addons
# MUST run their postinstall to compile their .node binary:
#
#   bcrypt        → bcrypt_lib.node    (password hashing)
#   sqlite3       → node_sqlite3.node  (SQLite driver, used in NPM 2.13.6)
#   better-sqlite3→ better_sqlite3.node(SQLite driver, used in NPM 2.13.7+)
#
# Detect which sqlite package is present dynamically so this works for
# both current (sqlite3) and future (better-sqlite3) versions.
# ---------------------------------------------------------------------------

PKGJSON="${NPM_HOME}/backend/package.json"
ALLOWED_BUILDS='["bcrypt","sqlite3","better-sqlite3","@mapbox/node-pre-gyp","node-pre-gyp","node-gyp"]'

# Single jq pass: set onlyBuiltDependencies, upgrade direct deps with deprecated
# transitive chains, and add pnpm.overrides for fixable subdependencies.
#
# Deprecated subdependency map — 5 of 12 fixable here:
#   glob@7.x/10.x → ^11.0.0  (security-deprecated by maintainer)
#   rimraf@3.x    → ^6.0.0   (deprecated)
#   tar@6.x       → ^7.0.0   (deprecated; sqlite3@6.x also drops this)
#   uuid@3.x      → ^10.0.0  (via node-pre-gyp@0.17.0)
#   sqlite3@5.x   → ^6.0.0   (direct upgrade; v6 uses tar@^7 not tar@^6)
#   knex@3.1.x    → ^3.2.0   (latest bugfix release)
#
# Unfixable — every published version is deprecated, deep in build toolchain:
#   prebuild-install, inflight, npmlog, are-we-there-yet, gauge,
#   querystring, @npmcli/move-file
jq --argjson deps "${ALLOWED_BUILDS}" '
    .pnpm = (.pnpm // {}) |
    .pnpm.onlyBuiltDependencies = $deps |
    .pnpm.overrides = (.pnpm.overrides // {}) |
    .pnpm.overrides.glob   = "^11.0.0" |
    .pnpm.overrides.rimraf = "^6.0.0"  |
    .pnpm.overrides.tar    = "^7.0.0"  |
    .pnpm.overrides.uuid   = "^10.0.0" |
    .dependencies.sqlite3  = "^6.0.0"  |
    .dependencies.knex     = "^3.2.0"
' "${PKGJSON}" > "${PKGJSON}.tmp" && mv "${PKGJSON}.tmp" "${PKGJSON}"
info "pnpm.onlyBuiltDependencies set: bcrypt, sqlite3, better-sqlite3, node-pre-gyp"
info "pnpm.overrides: glob→11.x rimraf→6.x tar→7.x uuid→10.x; sqlite3→6.x knex→3.2.x" 

if ${VERBOSE}; then
    pnpm install --prod
else
    pnpm install --prod --reporter=silent 2>/dev/null || pnpm install --prod &>/dev/null
fi

# ---------------------------------------------------------------------------
# Explicit rebuild — pnpm rebuild forces the postinstall/compile step
# even if pnpm thinks the package is already installed.
# ---------------------------------------------------------------------------
info "Rebuilding native addons (bcrypt + sqlite variants)..."

# Always rebuild bcrypt
# ---------------------------------------------------------------------------
# Rebuild native addons and verify they load correctly
# ---------------------------------------------------------------------------
# Verification strategy: ask Node.js to actually require() each native module.
# This works regardless of bcrypt version (5.x node-pre-gyp vs 6.x node-gyp-build)
# or where the .node binary is stored — if Node can load it, it works.
# ---------------------------------------------------------------------------

# Rebuild all native deps in one shot — pnpm handles the correct rebuild tool
# for each package (node-pre-gyp, node-gyp-build, node-gyp, etc.)
info "Rebuilding native addons..."
vrun pnpm rebuild || true

# ---------------------------------------------------------------------------
# Verify: require() each native module from the install directory
# A successful require() is the definitive test — file path searching is fragile
# ---------------------------------------------------------------------------
info "Verifying native modules load correctly..."
NATIVE_ERRORS=0

# Detect which sqlite package is present
# v2.14.0 uses better-sqlite3 exclusively (isSqlite() checks for this client name)
# Always prefer better-sqlite3; fall back to sqlite3 only if better-sqlite3 not installed
if ( cd "${NPM_HOME}/backend" && node -e "require('better-sqlite3')" &>/dev/null 2>&1 ); then
    SQLITE_PKG="better-sqlite3"
else
    SQLITE_PKG="sqlite3"
fi

# Test each module by requiring it with Node.js from the install directory
_test_module() {
    local label="$1"
    local require_expr="$2"
    if node --input-type=module \
           --experimental-vm-modules \
           <<< "import { createRequire } from 'module';
const req = createRequire('${NPM_HOME}/backend/index.js');
req('${require_expr}');" &>/dev/null 2>&1 || \
       node -e "require('${require_expr}')" \
            --require "${NPM_HOME}/backend/node_modules/.bin/../.." &>/dev/null 2>&1 || \
       ( cd "${NPM_HOME}/backend" && node -e "require('${require_expr}')" &>/dev/null 2>&1 ); then
        log "  ${label} : OK"
    else
        warn "  ${label} : FAILED to load"
        NATIVE_ERRORS=$(( NATIVE_ERRORS + 1 ))
    fi
}

_test_module "bcrypt"        "bcrypt"
_test_module "${SQLITE_PKG}" "${SQLITE_PKG}"

if [[ ${NATIVE_ERRORS} -gt 0 ]]; then
    die "${NATIVE_ERRORS} native module(s) failed to load. Cannot start service."
fi

info "Backend dependencies installed."

# Copy built frontend into the location the backend serves from.
# The backend's express static middleware serves from ../frontend/ relative
# to its __dirname — i.e. ${NPM_HOME}/frontend/. The Vite build output is
# at frontend/dist/. We copy the CONTENTS of dist/ directly into frontend/
# so index.html ends up at ${NPM_HOME}/frontend/index.html, NOT under
# frontend/dist/index.html which the backend would never find.
mkdir -p "${NPM_HOME}/frontend"
cp -r "${NPM_TMP}/frontend/dist/"* "${NPM_HOME}/frontend/"
# app-images (used for favicons etc in NPM 2.12+)
if [[ -d "${NPM_TMP}/frontend/app-images" ]]; then
    mkdir -p "${NPM_HOME}/frontend/images"
    cp -r "${NPM_TMP}/frontend/app-images/"* "${NPM_HOME}/frontend/images/" 2>/dev/null || true
    info "app-images copied."
fi
# Verify the critical index.html is in place
[[ -f "${NPM_HOME}/frontend/index.html" ]]     && log "frontend/index.html : present"     || die "frontend/index.html missing after copy — frontend will not load"

# ---------------------------------------------------------------------------
# Create lang/ directory with locale files
# ---------------------------------------------------------------------------
# NPM 2.13.x fetches /lang/{locale}.json at runtime for i18n. The Vite build
# does NOT include these files (Crowdin-managed, absent from git). We write
# the English strings here using Python to avoid bash heredoc quoting issues.
mkdir -p "${NPM_HOME}/frontend/lang"

python3 << 'PYLOCALE'
import json, os, sys
npm_home = os.environ.get("NPM_HOME", "/opt/nginx-proxy-manager")
lang_dir = os.path.join(npm_home, "frontend", "lang")
os.makedirs(lang_dir, exist_ok=True)

en = {
  "locale-en-US":"English","locale-de-DE":"German","locale-es-ES":"Spanish",
  "locale-ga-IE":"Irish","locale-ja-JP":"Japanese","locale-it-IT":"Italian",
  "locale-nl-NL":"Dutch","locale-pl-PL":"Polish","locale-ru-RU":"Russian",
  "locale-sk-SK":"Slovak","locale-vi-VN":"Vietnamese","locale-zh-CN":"Chinese (Simplified)",
  "locale-ko-KR":"Korean","locale-bg-BG":"Bulgarian","locale-id-ID":"Indonesian",
  "setup.title":"Create Administrator Account",
  "setup.preamble":"Please create your administrator account before continuing.",
  "login.title":"Sign In","login.sign-in":"Sign In",
  "login.invalid":"Email or Password is incorrect!",
  "login.forgot-link":"Forgot your password?","login.forgotten-title":"Password Reset",
  "login.forgotten-email":"Enter your email address",
  "login.forgotten-submit":"Send Reset Link","login.forgotten-back":"Back to Sign In",
  "dashboard.title":"Dashboard","dashboard.proxy-hosts":"Proxy Hosts",
  "dashboard.redirection-hosts":"Redirection Hosts","dashboard.streams":"Streams",
  "dashboard.dead-hosts":"404 Hosts",
  "menu.dashboard":"Dashboard","menu.hosts":"Hosts","menu.proxy-hosts":"Proxy Hosts",
  "menu.redirection-hosts":"Redirection Hosts","menu.streams":"Streams",
  "menu.dead-hosts":"404 Hosts","menu.access-lists":"Access Lists",
  "menu.certificates":"SSL Certificates","menu.users":"Users",
  "menu.audit-log":"Audit Log","menu.settings":"Settings",
  "menu.sign-out":"Sign out","menu.account":"Account",
  "user.title":"Users","user.full-name":"Full Name","user.nickname":"Nickname",
  "user.email":"Email Address","user.roles":"Roles","user.password":"Password",
  "user.new-password":"New Password","user.set-password":"Set Password",
  "user.profile":"Your Profile","user.change-password":"Change Password",
  "user.sign-out":"Sign Out","user.account":"Account",
  "email-address":"Email Address","password":"Password",
  "password.show":"Show Password","password.hide":"Hide Password",
  "save":"Save","cancel":"Cancel","close":"Close","delete":"Delete",
  "edit":"Edit","enable":"Enable","disable":"Disable",
  "enabled":"Enabled","disabled":"Disabled",
  "yes":"Yes","no":"No","loading":"Loading ...","search":"Search",
  "all":"All","unknown":"Unknown","online":"Online","offline":"Offline",
  "select":"Select...","none":"None",
  "object.add":"Add","object.edit":"Edit","object.delete":"Delete",
  "object.view":"View","object.id":"ID","object.created":"Created",
  "object.modified":"Modified",
  "proxy-host.title":"Proxy Hosts","proxy-host.add":"Add Proxy Host",
  "proxy-host.edit":"Edit Proxy Host","proxy-host.delete":"Delete Proxy Host",
  "proxy-host.domain-names":"Domain Names","proxy-host.scheme":"Scheme",
  "proxy-host.forward-hostname":"Forward Hostname / IP","proxy-host.forward-port":"Forward Port",
  "proxy-host.cache-assets":"Cache Assets","proxy-host.websockets-support":"Websockets Support",
  "proxy-host.block-exploits":"Block Common Exploits",
  "proxy-host.custom-locations":"Custom Locations","proxy-host.advanced":"Advanced",
  "proxy-host.nginx-config":"Custom Nginx Configuration",
  "proxy-host.ssl-tab":"SSL","proxy-host.details-tab":"Details",
  "redirection-host.title":"Redirection Hosts","redirection-host.add":"Add Redirection Host",
  "redirection-host.edit":"Edit Redirection Host","redirection-host.delete":"Delete Redirection Host",
  "redirection-host.domain-names":"Domain Names","redirection-host.forward-scheme":"Forward Scheme",
  "redirection-host.forward-domain":"Forward Domain Name",
  "redirection-host.forward-http-code":"HTTP Code","redirection-host.preserve-path":"Preserve Path",
  "dead-host.title":"404 Hosts","dead-host.add":"Add 404 Host",
  "dead-host.edit":"Edit 404 Host","dead-host.delete":"Delete 404 Host",
  "dead-host.domain-names":"Domain Names",
  "stream.title":"Streams","stream.add":"Add Stream",
  "stream.edit":"Edit Stream","stream.delete":"Delete Stream",
  "stream.incoming-port":"Incoming Port","stream.forward-host":"Forward Host",
  "stream.forward-port":"Forward Port",
  "stream.tcp-forwarding":"TCP Forwarding","stream.udp-forwarding":"UDP Forwarding",
  "access-list.title":"Access Lists","access-list.add":"Add Access List",
  "access-list.edit":"Edit Access List","access-list.delete":"Delete Access List",
  "access-list.name":"Name","access-list.satisfy-any":"Satisfy Any",
  "access-list.pass-auth":"Pass Auth to Host","access-list.clients":"Clients",
  "access-list.authorization":"Authorization",
  "access-list.username":"Username","access-list.password":"Password",
  "certificate.title":"SSL Certificates","certificate.add":"Add SSL Certificate",
  "certificate.edit":"Edit SSL Certificate","certificate.delete":"Delete SSL Certificate",
  "certificate.provider":"Provider","certificate.nice-name":"Nickname",
  "certificate.domain-names":"Domain Names",
  "certificate.letsencrypt":"Let's Encrypt","certificate.custom":"Custom",
  "certificate.expires":"Expires","certificate.renew":"Renew Certificate",
  "ssl.tabs.details":"Details","ssl.tabs.advanced":"Advanced",
  "ssl.certificate":"SSL Certificate","ssl.force-ssl":"Force SSL",
  "ssl.hsts-enabled":"HSTS Enabled","ssl.hsts-subdomains":"HSTS Subdomains",
  "ssl.http2-support":"HTTP/2 Support","ssl.dns-challenge":"Use a DNS Challenge",
  "ssl.email-address":"Email Address for Let's Encrypt",
  "ssl.agree":"I agree to the Let's Encrypt Terms of Service",
  "setting.title":"Settings","setting.save":"Save Settings",
  "setting.default-site":"Default Site",
  "setting.default-site-congratulations":"Congratulations Page",
  "setting.default-site-404":"404 Page","setting.default-site-html":"Custom HTML",
  "setting.default-site-redirect":"Redirect",
  "audit-log.title":"Audit Log","audit-log.action":"Action",
  "audit-log.user":"User","audit-log.object":"Object",
  "audit-log.meta":"Meta","audit-log.date":"Date",
  "role.admin":"Administrator","role.standard-user":"Standard User",
  "error.title":"Error","error.something-went-wrong":"Something went wrong!",
  "error.get-token":"Could not generate access token",
  "error.401":"Unauthorized","error.403":"Forbidden",
  "error.404":"Not Found","error.500":"Internal Server Error",
  "confirm.title":"Are you sure?","confirm.ok":"OK","confirm.cancel":"Cancel",
  "hosts.title":"Hosts","expand":"Expand","collapse":"Collapse",
  "dark-mode":"Dark Mode","light-mode":"Light Mode","version":"Version",
  "column.satisfy-any":"Satisfy Any","column.satisfy-all":"Satisfy All",
  "action.enable":"Enable","action.disable":"Disable",
  "pagination.prev":"Previous","pagination.next":"Next",
  "expand-all":"Expand All","collapse-all":"Collapse All"
}

with open(os.path.join(lang_dir, "en.json"), "w") as f:
    json.dump(en, f, indent=2, ensure_ascii=False)

for code in ["de","es","ga","ja","it","nl","pl","ru","sk","vi","zh","ko","bg","id"]:
    stub = os.path.join(lang_dir, f"{code}.json")
    if not os.path.exists(stub):
        with open(stub, "w") as f:
            f.write("{}")

if os.environ.get("VERBOSE","false")=="true": print("  en.json: {} keys written to {}".format(len(en), lang_dir))
PYLOCALE

info "Locale files written."

info "Files assembled at ${NPM_HOME}"

# ---------------------------------------------------------------------------
# Create and seed data directories
# ---------------------------------------------------------------------------
info "Creating data directories under ${NPM_DATA} ..."

mkdir -p \
    "${NPM_DATA}/nginx/proxy_host" \
    "${NPM_DATA}/nginx/redirection_host" \
    "${NPM_DATA}/nginx/dead_host" \
    "${NPM_DATA}/nginx/stream" \
    "${NPM_DATA}/nginx/access" \
    "${NPM_DATA}/nginx/custom" \
    "${NPM_DATA}/nginx/temp" \
    "${NPM_DATA}/logs"
# /data/letsencrypt omitted: certbot writes to /etc/letsencrypt/ directly in native installs.
# /data/ssl-certs   omitted: unreferenced in NPM v2.14.0; custom certs live in /data/custom_ssl/

# Touch required custom-snippet stubs so nginx includes don't fail on first start
for STUB in \
    "${NPM_DATA}/nginx/custom/http_top.conf" \
    "${NPM_DATA}/nginx/custom/server_top.conf" \
    "${NPM_DATA}/nginx/custom/events.conf"; do
    [[ -f "${STUB}" ]] || touch "${STUB}"
done

# ---------------------------------------------------------------------------
# Configure NPM database
# CRITICAL: must use "better-sqlite3" not "sqlite3" as the knex client.
# config.js checks client === 'better-sqlite3' to determine isSqlite().
# If "sqlite3" is used, isSqlite() returns false, NOW() is used instead of
# datetime('now') and every INSERT fails with SQLITE_ERROR: no such function: NOW
# ---------------------------------------------------------------------------
info "Writing NPM database configuration (SQLite)..."

mkdir -p "${NPM_HOME}/backend/config"
cat > "${NPM_HOME}/backend/config/production.json" <<JSON
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "better-sqlite3",
      "connection": {
        "filename": "${NPM_DATA}/database.sqlite"
      },
      "useNullAsDefault": true
    }
  }
}
JSON

info "SQLite config written."

# ---------------------------------------------------------------------------
# Configure nginx for NPM — fully self-contained, no docker/rootfs copies
# ---------------------------------------------------------------------------
# ARCHITECTURE CLARIFICATION (critical for understanding why we do this):
#
#   NPM 2.12+ Node.js backend  →  serves port 81 directly (admin UI + API)
#   nginx                      →  serves ports 80 and 443 only (proxy hosts)
#
# docker/rootfs/etc/nginx/conf.d/production.conf declares a server{} on port 81.
# That file is Docker-specific: in Docker, nginx fronts everything. In a native
# install the Node.js backend owns port 81 directly — so production.conf must
# NOT be included or nginx and Node.js both try to bind port 81 → duplicate error.
#
# Solution: write every nginx config file ourselves. Nothing is copied from
# docker/rootfs. We control exactly what is included and where.
# ---------------------------------------------------------------------------
info "Configuring nginx for NPM (self-contained, no docker/rootfs copies)..."

# Ensure stream module is present
dpkg -l libnginx-mod-stream 2>/dev/null | grep -q '^ii' \
    || vrun apt-get install -y --no-install-recommends libnginx-mod-stream -qq

# ── Full reset — wipe all nginx configs to a known-empty state ──────────────
rm -f  /etc/nginx/sites-enabled/*
rm -f  /etc/nginx/sites-available/*
rm -f  /etc/nginx/conf.d/*.conf
rm -rf /etc/nginx/conf.d/include
rm -rf /etc/nginx/conf.d/stream

# ── Create required directory structure ─────────────────────────────────────
mkdir -p /etc/nginx/conf.d/include
mkdir -p /etc/nginx/conf.d/stream
mkdir -p /etc/nginx/conf
mkdir -p /tmp/nginx/body
mkdir -p /data/logs
mkdir -p /data/letsencrypt-acme-challenge/.well-known/acme-challenge
mkdir -p /tmp/letsencrypt-lib
# Default site directories — REQUIRED for Settings > Default Site to work:
# /data/nginx/default_host/ → generateConfig('default') writes here
# /data/nginx/default_www/  → Custom HTML saves index.html here
# Missing either directory causes: empty 200 responses or Node.js crash (502)
mkdir -p /data/nginx/default_host
mkdir -p /data/nginx/default_www
mkdir -p /var/lib/nginx/cache/public
mkdir -p /var/lib/nginx/cache/private

# ── Write resolvers.conf ─────────────────────────────────────────────────────
RESOLVERS=$(awk 'BEGIN{ORS=" "} $1=="nameserver" {
    print ($2 ~ ":") ? "["$2"]" : $2
}' /etc/resolv.conf)
echo "resolver ${RESOLVERS:-127.0.0.1} valid=30s;" > /etc/nginx/conf.d/include/resolvers.conf
info "resolvers.conf: $(cat /etc/nginx/conf.d/include/resolvers.conf)"

# ── Write nginx.conf ─────────────────────────────────────────────────────────
# ARCHITECTURE (NPM 2.13.x native install):
#
#   Node.js backend → port 3000 (internal API + admin UI)
#   nginx port 81   → reverse proxy to localhost:3000  (admin panel, user-facing)
#   nginx port 80   → NPM-managed proxy hosts (HTTP)
#   nginx port 443  → NPM-managed proxy hosts (HTTPS)
#
# The Node.js backend changed from listening on port 81 directly to port 3000.
# nginx must proxy port 81 → 3000 so the admin UI is reachable on the expected port.
cat > /etc/nginx/nginx.conf << 'NGINX_CONF'
# Nginx Proxy Manager — native nginx.conf
# Node.js backend: port 3000 (internal). nginx proxies :81 → :3000 for admin UI.

user www-data;
worker_processes auto;
pid /run/nginx.pid;

include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 90s;
    server_tokens off;
    client_max_body_size 0;
    proxy_read_timeout 90s;
    proxy_send_timeout 90s;
    proxy_connect_timeout 90s;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 1024;

    client_body_temp_path /tmp/nginx/body 1 2;
    proxy_http_version 1.1;
    proxy_set_header X-Forwarded-Scheme $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Accept-Encoding "";
    proxy_cache off;
    proxy_cache_path /var/lib/nginx/cache/public  levels=1:2 keys_zone=public-cache:30m  max_size=192m;
    proxy_cache_path /var/lib/nginx/cache/private levels=1:2 keys_zone=private-cache:5m  max_size=1024m;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    gzip on;
    gzip_disable "msie6";
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml text/javascript;

    # Log formats used by NPM-generated proxy host configs
    log_format standard '[$time_local] $status - $request_method $scheme $host "$request_uri" [Client $remote_addr] [Length $body_bytes_sent] [Gzip $gzip_ratio] "$http_user_agent" "$http_referer"';
    log_format proxy    '[$time_local] $status - $request_method $scheme $host "$request_uri" [Client $remote_addr] [Length $body_bytes_sent] [Gzip $gzip_ratio] "$http_user_agent" "$http_referer"';

    access_log /data/logs/fallback_access.log standard;
    error_log  /data/logs/fallback_error.log  warn;

    # ── Variables required by NPM's proxy_host.conf template ─────────────────
    # $x_forwarded_proto and $x_forwarded_scheme are NOT built-in nginx variables.
    # They are defined in the Docker nginx.conf via map blocks. Without these,
    # nginx -t fails with "unknown variable" on every proxy host config, causing
    # NPM to silently roll back the config write. proxy_host files never appear.
    map $http_x_forwarded_proto $x_forwarded_proto {
        http    http;
        https   https;
        default $scheme;
    }
    map $http_x_forwarded_scheme $x_forwarded_scheme {
        http    http;
        https   https;
        default $scheme;
    }
    # Default upstream scheme (used by NPM template)
    map $host $forward_scheme {
        default http;
    }

    # ── Real IP — trust local subnets and CDN ranges ───────────────────────────
    set_real_ip_from 10.0.0.0/8;
    set_real_ip_from 172.16.0.0/12;
    set_real_ip_from 192.168.0.0/16;
    include /etc/nginx/conf.d/include/ip_ranges.conf;
    real_ip_header    X-Real-IP;
    real_ip_recursive on;

    # ── Resolvers ─────────────────────────────────────────────────────────────
    include /etc/nginx/conf.d/include/resolvers.conf;

    # ── NPM runtime proxy configs ──────────────────────────────────────────────
    include /data/nginx/default_host/*.conf;
    include /data/nginx/proxy_host/*.conf;
    include /data/nginx/redirection_host/*.conf;
    include /data/nginx/dead_host/*.conf;
    include /data/nginx/temp/*.conf;

    # ── Custom snippets ────────────────────────────────────────────────────────
    include /data/nginx/custom/http_top[.]conf;
    include /data/nginx/custom/http[.]conf;

    # ── Admin UI — port 81 ────────────────────────────────────────────────────
    # NPM 2.13.x ARCHITECTURE:
    #   - Node.js backend: pure API on port 3000 (NO express.static)
    #   - React frontend: static files served by nginx from /opt/nginx-proxy-manager/frontend/
    #   - nginx port 81: serves static files + proxies /api/* to port 3000
    #
    # The backend has no static file serving — nginx owns the entire admin UI.
    server {
        listen 81;
        listen [::]:81;
        server_name _;
        access_log /data/logs/fallback_access.log standard;
        error_log  /data/logs/fallback_error.log  warn;

        # Serve the React SPA static files directly
        root /opt/nginx-proxy-manager/frontend;
        index index.html;

        # API requests → Node.js backend on port 3000
        # CRITICAL: trailing slash on proxy_pass strips the /api/ prefix
        # so the React app's /api/tokens reaches the backend as /tokens
        location /api/ {
            proxy_pass         http://127.0.0.1:3000/;
            proxy_http_version 1.1;
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            proxy_read_timeout 90s;
        }

        # WebSocket upgrade for live updates
        location /socket.io/ {
            proxy_pass         http://127.0.0.1:3000/socket.io/;
            proxy_http_version 1.1;
            proxy_set_header   Upgrade    $http_upgrade;
            proxy_set_header   Connection "upgrade";
            proxy_set_header   Host       $host;
        }

        # React SPA — serve index.html for all non-file routes
        location / {
            try_files $uri $uri/ /index.html;
        }
    }
}

# Stream block for TCP/UDP proxying
stream {
    include /data/nginx/stream/*.conf;
}
NGINX_CONF

# Symlink for tools that expect /etc/nginx/conf/nginx.conf
ln -sf /etc/nginx/nginx.conf /etc/nginx/conf/nginx.conf 2>/dev/null || true

# ── Dummy SSL certs ───────────────────────────────────────────────────────────
# NPM's generated HTTPS server blocks reference these until real certs exist
mkdir -p "${NPM_DATA}/nginx"
if [[ ! -f "${NPM_DATA}/nginx/dummykey.pem" ]]; then
    info "Generating dummy SSL certificate..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/O=Nginx Proxy Manager/OU=Dummy Certificate/CN=localhost" \
        -keyout "${NPM_DATA}/nginx/dummykey.pem" \
        -out    "${NPM_DATA}/nginx/dummycert.pem" \
        2>/dev/null
    info "Dummy SSL cert generated."
fi

# ── Copy Docker rootfs conf.d/include files ──────────────────────────────────
# CRITICAL: The NPM proxy_host.conf template uses relative includes like:
#   include conf.d/include/proxy.conf;
#   include conf.d/include/block-exploits.conf;
#   include conf.d/include/force-ssl.conf; etc.
# These files live in docker/rootfs/etc/nginx/conf.d/include/ in the git repo.
# Without them, nginx -t FAILS when NPM tries to write any proxy host config,
# causing the config to be silently rolled back. The proxy host appears in the
# database but no nginx conf file is written → proxy never works.
if [[ -d "${NPM_TMP}/docker/rootfs/etc/nginx/conf.d/include" ]]; then
    cp "${NPM_TMP}/docker/rootfs/etc/nginx/conf.d/include/"*.conf         /etc/nginx/conf.d/include/ 2>/dev/null || true
    log "Copied nginx include files (proxy.conf, block-exploits.conf, etc.)"
else
    warn "docker/rootfs/etc/nginx/conf.d/include not found — proxy host configs may fail"
fi

# ── Create custom snippet stubs for NPM template includes ─────────────────────
# NPM templates reference these via glob patterns like server_proxy[.]conf
# nginx -t fails if the include directive matches zero files (it's OK if the
# file exists but is empty). Create all stubs at install time.
mkdir -p /data/nginx/custom
for _stub in server_proxy root_top root_end root http_top http events stream; do
    touch "/data/nginx/custom/${_stub}.conf" 2>/dev/null || true
done

# ── Copy letsencrypt.ini ──────────────────────────────────────────────────────
[[ -f "${NPM_TMP}/docker/rootfs/etc/letsencrypt.ini" ]] && \
    cp "${NPM_TMP}/docker/rootfs/etc/letsencrypt.ini" /etc/letsencrypt.ini

# ── Copy default web root (404 pages etc.) ───────────────────────────────────
mkdir -p /var/www/html
[[ -d "${NPM_TMP}/docker/rootfs/var/www/html" ]] && \
    cp -r "${NPM_TMP}/docker/rootfs/var/www/html/"* /var/www/html/ 2>/dev/null || true

# ── Validate and start nginx ──────────────────────────────────────────────────
nginx -t &>/dev/null || die "nginx config test failed — run: nginx -t for details."

# Enable nginx to start on boot and verify the symlink was created
systemctl enable nginx 2>/dev/null || true
systemctl is-enabled nginx &>/dev/null || warn "nginx may not be enabled for autostart — run: systemctl enable nginx"
log "nginx enabled for autostart."  
# Redirect all 3 fds: systemd uses isatty(stdout) to decide whether to stream journal.
# With stdout=/dev/null, isatty() returns false → no journal stream registered.
# Quiet nginx restart — same drop-in trick to stop journald forwarding to terminal
_NGINX_DPD="/etc/systemd/system/nginx.service.d"
_NGINX_DPF="${_NGINX_DPD}/99-install-quiet.conf"
mkdir -p "${_NGINX_DPD}"
printf '[Service]\nStandardOutput=append:/var/log/nginx-install.log\nStandardError=append:/var/log/nginx-install.log\n' > "${_NGINX_DPF}"
systemctl daemon-reload </dev/null >/dev/null 2>&1
systemctl restart nginx </dev/null >/dev/null 2>&1 || true
sleep 1
rm -f "${_NGINX_DPF}" 2>/dev/null || true
rmdir --ignore-fail-on-non-empty "${_NGINX_DPD}" 2>/dev/null || true
systemctl daemon-reload </dev/null >/dev/null 2>&1
# Verify nginx actually started — if not, die with a clear error
if ! systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl start nginx 2>/dev/null || true
    sleep 2
fi
if systemctl is-active --quiet nginx 2>/dev/null; then
    log "nginx configured, enabled, and running."
else
    die "nginx failed to start — run: systemctl status nginx  or: journalctl -u nginx -n 30"
fi

# ---------------------------------------------------------------------------
# Configure logrotate for NPM
# ---------------------------------------------------------------------------
cat > /etc/logrotate.d/nginx-proxy-manager <<'LOGROTATE'
/data/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        nginx -s reopen 2>/dev/null || true
    endscript
}
LOGROTATE

# ---------------------------------------------------------------------------
# Create systemd service
# ---------------------------------------------------------------------------
step "Step 7/7 — Creating systemd service and starting NPM"

cat > "/etc/systemd/system/${NPM_SERVICE}.service" <<SERVICE
[Unit]
Description=Nginx Proxy Manager
Documentation=https://nginxproxymanager.com
After=network.target nginx.service
Wants=nginx.service

[Service]
Type=simple
WorkingDirectory=${NPM_HOME}/backend
# Explicit PATH ensures certbot/nginx are found regardless of how systemd
# initialises the environment (certbot lives at /usr/bin/certbot)
Environment=PATH=/opt/certbot/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=NODE_ENV=production
Environment=SUPPRESS_NO_CONFIG_WARNING=1
Environment=LD_PRELOAD=
# Tell the backend where nginx lives so it can reload configs
Environment=NGINX_BINARY=/usr/sbin/nginx
# Ensure required runtime directories exist before starting
# /tmp/letsencrypt-lib  → certbot --work-dir (REQUIRED: certbot will not create it)
# /data/letsencrypt-acme-challenge → certbot webroot for HTTP-01 ACME challenge
ExecStartPre=-/bin/mkdir -p /tmp/nginx/body /tmp/letsencrypt-lib /data/letsencrypt-acme-challenge/.well-known/acme-challenge /data/nginx/default_host /data/nginx/default_www
# Ensure nginx is running when we start — on reboot nginx may start slightly later
ExecStartPre=-/bin/systemctl start nginx
ExecStart=/usr/bin/node index.js --abort_on_uncaught_exception --max_old_space_size=250
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=npm
User=root
Group=root
NoNewPrivileges=no

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload

# Enable NPM service for autostart on boot — critical: without this the service
# will not start after a reboot.
systemctl enable "${NPM_SERVICE}" 2>/dev/null || true
if systemctl is-enabled "${NPM_SERVICE}" &>/dev/null; then
    log "Service ${NPM_SERVICE} enabled for autostart on boot."
else
    warn "Service ${NPM_SERVICE} may not be enabled — run: systemctl enable ${NPM_SERVICE}"
fi

# ── ROOT CAUSE of journal leak ────────────────────────────────────────────
# The unit has StandardOutput=journal. When npm writes to stdout/stderr,
# journald receives it and forwards it to EVERY active login session's pts
# device via logind session tracking — completely bypassing any fd redirects
# on systemctl. Our </dev/null >/dev/null on systemctl only affects
# systemctl's own output; journald uses /dev/pts/N directly.
#
# FIX: Temporary drop-in overrides StandardOutput to a log file for both
# the NPM service and nginx. No output reaches journald during startup,
# so journald has nothing to forward to the terminal. Drop-ins are removed
# after the service is confirmed running; future restarts log to journal
# as normal.
_DROPIN_DIR="/etc/systemd/system/${NPM_SERVICE}.service.d"
_DROPIN="${_DROPIN_DIR}/99-install-quiet.conf"
_NGINX_DROPIN_DIR="/etc/systemd/system/nginx.service.d"
_NGINX_DROPIN="${_NGINX_DROPIN_DIR}/99-install-quiet.conf"
mkdir -p "${_DROPIN_DIR}" "${_NGINX_DROPIN_DIR}"
printf '[Service]\nStandardOutput=append:/var/log/nginx-proxy-manager.log\nStandardError=append:/var/log/nginx-proxy-manager.log\n'     > "${_DROPIN}"
printf '[Service]\nStandardOutput=append:/var/log/nginx-install.log\nStandardError=append:/var/log/nginx-install.log\n'     > "${_NGINX_DROPIN}"
systemctl daemon-reload </dev/null >/dev/null 2>&1

systemctl start "${NPM_SERVICE}" </dev/null >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Wait for service to be ready — poll only, no journal output
# ---------------------------------------------------------------------------
RETRIES=30
INTERVAL=2
ELAPSED=0

printf "  ${DIM}Starting service...${NC}"
while [[ ${RETRIES} -gt 0 ]]; do
    if curl -sf "http://127.0.0.1:${ADMIN_PORT}/" &>/dev/null; then
        break
    fi
    sleep ${INTERVAL}
    RETRIES=$(( RETRIES - 1 ))
    ELAPSED=$(( ELAPSED + INTERVAL ))
    printf "."
done
echo ""

# Drop-ins served their purpose — remove them so future restarts use journal.
rm -f "${_DROPIN}" "${_NGINX_DROPIN}" 2>/dev/null || true
rmdir --ignore-fail-on-non-empty "${_DROPIN_DIR}" "${_NGINX_DROPIN_DIR}" 2>/dev/null || true
systemctl daemon-reload </dev/null >/dev/null 2>&1

if [[ ${RETRIES} -eq 0 ]]; then
    echo ""
    warn "NPM did not respond within $((30 * INTERVAL))s."
    warn "Check: journalctl -u ${NPM_SERVICE} -n 40 --no-pager"
else
    log "NPM is up and responding."
fi

# ---------------------------------------------------------------------------
# Cleanup build artifacts
# ---------------------------------------------------------------------------
vrun rm -rf "${NPM_TMP}"

# ---------------------------------------------------------------------------
# Final status + summary
# ---------------------------------------------------------------------------
HOST_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║      Nginx Proxy Manager — Installation Complete         ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Admin Panel :${NC} ${BOLD}http://${HOST_IP}:${ADMIN_PORT}${NC}"
echo -e "  ${CYAN}Version     :${NC} v${NPM_VERSION}"
echo -e "  ${CYAN}Service     :${NC} ${NPM_SERVICE}"
echo ""
echo -e "  ${YELLOW}➜  Open the admin panel to create your account.${NC}"
echo ""
# Safety net: close both stdout and stderr after all output is done.
# Any residual journal stream that systemd registered against this TTY will
# receive EBADF on its next write() and terminate.
exec >/dev/null 2>&1

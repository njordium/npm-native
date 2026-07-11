#!/usr/bin/env bash
# =============================================================================
#  Nginx Proxy Manager — Native Linux Installer v1.1.19 (Debian / Ubuntu)
#  No Docker  |  SQLite  |  Systemd  |  Team Njordium
#  Script Authors: Kim Haverblad & Tommy Jansson
#
#  v1.1.20 — persistent client_body_temp_path (fixes post-reboot bug):
#    nginx.conf previously set `client_body_temp_path /tmp/nginx/body`.
#    On modern Debian/Ubuntu /tmp is tmpfs and is wiped on reboot, so
#    the directory disappeared and `nginx -t` failed with `mkdir()
#    "/tmp/nginx/body" failed (2: No such file or directory)`. NPM
#    validates every proxy host save with `nginx -t` internally, so the
#    UI returned a generic "Internal Error" on every save attempt after
#    reboot until the directory was manually recreated. The temp path
#    now lives at /var/lib/nginx/body -- nginx's own state directory,
#    persistent on the root filesystem. Created once at install time
#    with www-data ownership; no longer referenced by the systemd
#    ExecStartPre.
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# ERR trap — point at the line and command that tripped set -e.
# Without this, a `grep` with no match deep inside a heredoc dies silently.
trap 'rc=$?; echo -e "\n[ERR] line ${LINENO}: ${BASH_COMMAND} (rc=${rc})" >&2' ERR

# ---------------------------------------------------------------------------
# User-tunable settings
# ---------------------------------------------------------------------------
# NPM_VERSION: auto-resolved to latest GitHub release unless overridden.
# The resolved version is shown in the splash and confirmed before install.
SCRIPT_VERSION="1.1.20"           # installer script version
NPM_VERSION="${NPM_VERSION:-}"   # empty = auto-detect latest
NODE_MAJOR="${NODE_MAJOR:-22}"
NPM_HOME="${NPM_HOME:-/opt/nginx-proxy-manager}"
NPM_DATA="${NPM_DATA:-/data}"
NPM_TMP="/tmp/npm-build"
# Validate paths — unsafe characters would break sed substitution in nginx.conf
[[ "${NPM_HOME}" =~ [^a-zA-Z0-9/_.-] ]] && { echo "FATAL: NPM_HOME contains unsafe characters: ${NPM_HOME}" >&2; exit 1; }
[[ "${NPM_DATA}" =~ [^a-zA-Z0-9/_.-] ]] && { echo "FATAL: NPM_DATA contains unsafe characters: ${NPM_DATA}" >&2; exit 1; }
NPM_SERVICE="nginx-proxy-manager"
ADMIN_PORT=81
INSTALL_MODE=""   # fresh | update | verify  (set by mode selection below)
VERBOSE=false     # true = show all step output, false = quiet (main steps only)

# Secure temp files — mktemp prevents symlink attacks in /tmp
_VITE_PATCH=$(mktemp /tmp/npm-vite-patch.XXXXXX.py)
_TSCONFIG_PATCH=$(mktemp /tmp/npm-tsconfig-patch.XXXXXX.py)
_BUILD_LOG=$(mktemp /tmp/npm-build-output.XXXXXX.log)
# On failure, copy the build log somewhere durable so the user can inspect it
# after the temp file is wiped. The trailing rm -f always runs.
_tmp_cleanup() {
    local rc=$?
    if [[ ${rc} -ne 0 && -s "${_BUILD_LOG:-}" ]]; then
        cp "${_BUILD_LOG}" /var/log/npm-build-failed.log 2>/dev/null \
            && echo "[!] Full build log preserved at /var/log/npm-build-failed.log" >&2
    fi
    rm -f "${_VITE_PATCH:-}" "${_TSCONFIG_PATCH:-}" "${_BUILD_LOG:-}"
}
trap _tmp_cleanup EXIT

# ---------------------------------------------------------------------------
# Function decomposition (table of contents)
# ---------------------------------------------------------------------------
# The body is sectioned into named functions; each is defined and called
# immediately so the top-to-bottom imperative flow is preserved. Variable
# scope is unchanged — bash functions inherit shell variables unless they
# use `local`. To run just one phase for debugging, comment out the call
# (the line that bare-names the function after its `}` close marker).
#
#   _resolve_npm_version
#   _show_splash_and_preflight
#   _select_install_mode
#   _select_verbosity
#   _run_verify_mode
#   _prepare_for_install
#   _maybe_upgrade_system
#   _step1_install_deps
#   _step1b_certbot_venv
#   _step2_install_node
#   _step3_clone_source
#   _step4_build_frontend
#   _step5_install_backend
#   _step6_seed_data
#   _step6_seed_data_continued_db
#   _step6b_configure_nginx
#   _step6c_logrotate
#   _step7_systemd_service
#   _step7b_wait_for_service
#   _finalize
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ANSI colours
# ---------------------------------------------------------------------------
RED='\033[0;31m';   GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m';  BLUE='\033[0;34m';   MAGENTA='\033[0;35m'
BOLD='\033[1m';     DIM='\033[2m';        NC='\033[0m'

# ---------------------------------------------------------------------------
# UTF-8 / ASCII glyph selection (v1.1.12)
# ---------------------------------------------------------------------------
# Some operators run this script over an SSH session whose remote LANG is
# C or POSIX, or in an LXC / serial console without UTF-8 font support.
# In those terminals Unicode bytes render as `?` and the dashboards are
# unreadable. Two-step fix:
#   1. If a UTF-8 locale is installed, switch LC_ALL to it.
#   2. Detect whether the active locale claims UTF-8 — if not, use ASCII
#      fallbacks for every decorative glyph.
# Override the auto-detection with NPM_USE_UTF8=true|false.
NPM_USE_UTF8="${NPM_USE_UTF8:-auto}"
if [[ "${NPM_USE_UTF8}" == "auto" ]]; then
    # Detect (don't force). If the operator's environment is POSIX/C the
    # terminal almost certainly can't render Unicode either — switching the
    # locale would still leave question marks. Default to ASCII unless the
    # active locale explicitly says UTF-8. Override with NPM_USE_UTF8=true.
    case "${LC_ALL:-${LANG:-}}" in
        *.UTF-8|*.utf-8|*.UTF8|*.utf8) NPM_USE_UTF8=true ;;
        *) NPM_USE_UTF8=false ;;
    esac
fi

if ${NPM_USE_UTF8}; then
    G_DASH="\xe2\x80\x94"  ; G_DOT="\xc2\xb7"      ; G_BULLET="\xe2\x80\xa2"
    G_OK_DOT="\xe2\x97\x8f" ; G_NF_DOT="\xe2\x97\x8b"
    G_ARROW="\xe2\x86\x92"  ; G_STEP="\xc2\xbb"     ; G_ARROW_HEAVY="\xe2\x9e\x9c"
    G_CHECK="\xe2\x9c\x93"  ; G_CROSS="\xe2\x9c\x97" ; G_WARN_SYM="\xe2\x9a\xa0"
    G_HBAR="\xe2\x94\x80"   ; G_HBAR2="\xe2\x95\x90" ; G_HBAR_HEAVY="\xe2\x94\x81"
    G_VBAR1="\xe2\x94\x82"  ; G_VBAR2="\xe2\x95\x91"
    G_TL1="\xe2\x94\x8c"    ; G_TR1="\xe2\x94\x90"
    G_BL1="\xe2\x94\x94"    ; G_BR1="\xe2\x94\x98"
    G_TL2="\xe2\x95\x94"    ; G_TR2="\xe2\x95\x97"
    G_BL2="\xe2\x95\x9a"    ; G_BR2="\xe2\x95\x9d"
    G_SPIN_CHARS='\xe2\xa0\x8b\xe2\xa0\x99\xe2\xa0\xb9\xe2\xa0\xb8\xe2\xa0\xbc\xe2\xa0\xb4\xe2\xa0\xa6\xe2\xa0\xa7\xe2\xa0\x87\xe2\xa0\x8f'
    # Re-interpret the backslash escapes
    G_DASH=$(printf '%b' "${G_DASH}")             ; G_DOT=$(printf '%b' "${G_DOT}")
    G_BULLET=$(printf '%b' "${G_BULLET}")
    G_OK_DOT=$(printf '%b' "${G_OK_DOT}")          ; G_NF_DOT=$(printf '%b' "${G_NF_DOT}")
    G_ARROW=$(printf '%b' "${G_ARROW}")            ; G_STEP=$(printf '%b' "${G_STEP}")
    G_ARROW_HEAVY=$(printf '%b' "${G_ARROW_HEAVY}")
    G_CHECK=$(printf '%b' "${G_CHECK}")            ; G_CROSS=$(printf '%b' "${G_CROSS}")
    G_WARN_SYM=$(printf '%b' "${G_WARN_SYM}")
    G_HBAR=$(printf '%b' "${G_HBAR}")              ; G_HBAR2=$(printf '%b' "${G_HBAR2}")
    G_HBAR_HEAVY=$(printf '%b' "${G_HBAR_HEAVY}")
    G_VBAR1=$(printf '%b' "${G_VBAR1}")            ; G_VBAR2=$(printf '%b' "${G_VBAR2}")
    G_TL1=$(printf '%b' "${G_TL1}")                ; G_TR1=$(printf '%b' "${G_TR1}")
    G_BL1=$(printf '%b' "${G_BL1}")                ; G_BR1=$(printf '%b' "${G_BR1}")
    G_TL2=$(printf '%b' "${G_TL2}")                ; G_TR2=$(printf '%b' "${G_TR2}")
    G_BL2=$(printf '%b' "${G_BL2}")                ; G_BR2=$(printf '%b' "${G_BR2}")
    G_SPIN_CHARS=$(printf '%b' "${G_SPIN_CHARS}")
else
    G_DASH="-"     ; G_DOT="|"     ; G_BULLET="*"
    G_OK_DOT="*"   ; G_NF_DOT="o"
    G_ARROW="->"   ; G_STEP=">"    ; G_ARROW_HEAVY=">"
    G_CHECK="OK"   ; G_CROSS="X"   ; G_WARN_SYM="!"
    G_HBAR="-"     ; G_HBAR2="="   ; G_HBAR_HEAVY="="
    G_VBAR1="|"    ; G_VBAR2="|"
    G_TL1="+"      ; G_TR1="+"     ; G_BL1="+"   ; G_BR1="+"
    G_TL2="+"      ; G_TR2="+"     ; G_BL2="+"   ; G_BR2="+"
    G_SPIN_CHARS='|/-\'
fi

TS()     { date '+%Y-%m-%d %H:%M:%S'; }
log()    { echo -e "${GREEN}[${G_CHECK}]${NC} $(TS) $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $(TS) $*"; }
die()    { echo -e "\n${RED}[${G_CROSS}] FATAL:${NC} $(TS) $*\n" >&2; exit 1; }
banner() { echo -e "\n${BOLD}${CYAN}${G_HBAR_HEAVY}${G_HBAR_HEAVY}${G_HBAR_HEAVY}  $*  ${G_HBAR_HEAVY}${G_HBAR_HEAVY}${G_HBAR_HEAVY}${NC}\n"; }
# info(): visible only in verbose mode
info()   { ${VERBOSE} && echo -e "${CYAN}[${G_ARROW}]${NC} $(TS) $*" || true; }
# step(): always visible — shows top-level progress
step()   { echo -e "${BOLD}${CYAN}[${G_STEP}]${NC} $(TS) ${BOLD}$*${NC}"; }
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

# _pnpm_install_with_retry: wrap pnpm install/upgrade calls with exponential
# backoff retry. A single metadata fetch timeout (e.g. ERR_PNPM_META_FETCH_FAIL)
# on registry.npmjs.org no longer kills the install. 3 attempts, 15s/30s/60s
# backoff. The wrapped command's real exit code is surfaced on final failure.
# NOTE: uses the `cmd || _rc=$?` idiom because `if cmd; then; fi` consumes the
# failing exit code (bash sets $? to 0 after a not-taken if-then branch).
_pnpm_install_with_retry() {
    local _attempts=3
    local _backoff=15
    local _attempt _rc
    for _attempt in $(seq 1 ${_attempts}); do
        _rc=0
        "$@" || _rc=$?
        if [[ ${_rc} -eq 0 ]]; then
            [[ ${_attempt} -gt 1 ]] && log "pnpm install succeeded on retry attempt ${_attempt}"
            return 0
        fi
        if [[ ${_attempt} -lt ${_attempts} ]]; then
            warn "pnpm install failed (attempt ${_attempt}/${_attempts}, rc=${_rc}). Retrying in ${_backoff}s..."
            sleep ${_backoff}
            _backoff=$(( _backoff * 2 ))
        else
            warn "pnpm install exhausted ${_attempts} attempts (rc=${_rc}). Last error above."
            warn "If this persists: check /etc/resolv.conf, try a different registry via npm_config_registry, or re-run with --verbose for full output."
            return ${_rc}
        fi
    done
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

# v1.1.19: auto-swap helper for low-RAM hosts.
# _create_swap <size_mb> [path]
#   - Prefers fallocate; falls back to dd on filesystems that reject it.
#   - chmod 600 before mkswap so swap contents arent world-readable.
#   - Refuses to overwrite an existing file at the target path.
#   - Sets _CREATED_SWAP so _finalize can offer the keep/remove/persist menu.
_create_swap() {
    local size_mb="$1"
    local swap_path="${2:-${NPM_SWAPFILE:-/swapfile}}"

    if [[ -e "${swap_path}" ]]; then
        warn "Swap target ${swap_path} already exists ${G_DASH} refusing to overwrite. Set NPM_SWAPFILE to a different path."
        return 1
    fi

    info "Allocating ${size_mb} MB swap file at ${swap_path}..."
    if fallocate -l "${size_mb}M" "${swap_path}" 2>/dev/null; then
        :
    else
        warn "fallocate failed (filesystem may not support it); falling back to dd..."
        if ! dd if=/dev/zero of="${swap_path}" bs=1M count="${size_mb}" status=none 2>/dev/null; then
            warn "Could not allocate ${size_mb} MB at ${swap_path} ${G_DASH} disk full?"
            rm -f "${swap_path}" 2>/dev/null
            return 1
        fi
    fi

    chmod 600 "${swap_path}"
    if ! mkswap "${swap_path}" &>/dev/null; then
        warn "mkswap failed on ${swap_path}"
        rm -f "${swap_path}"
        return 1
    fi
    if ! swapon "${swap_path}" 2>/dev/null; then
        warn "swapon failed on ${swap_path}"
        rm -f "${swap_path}"
        return 1
    fi
    log "Swap file ${swap_path} (${size_mb} MB) created and activated."
    _CREATED_SWAP="${swap_path}"
    _CREATED_SWAP_SIZE="${size_mb}"
    return 0
}

# ---------------------------------------------------------------------------
# >>> SECTION: _resolve_npm_version >>>
_resolve_npm_version() {
# Auto-detect latest NPM version from GitHub if not specified
# ---------------------------------------------------------------------------
# v1.1.17: track WHERE NPM_VERSION came from so the splash can label it.
#   latest   -- auto-resolved from the GitHub releases API
#   pinned   -- caller passed NPM_VERSION env or --version
#   fallback -- GitHub unreachable, used the hard-coded fallback
if [[ -z "${NPM_VERSION}" ]]; then
    _LATEST=$(curl -sf --max-time 10         "https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest"         | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))"         2>/dev/null || true)
    if [[ -n "${_LATEST}" ]]; then
        NPM_VERSION="${_LATEST}"
        _NPM_VERSION_SOURCE="latest"
    else
        NPM_VERSION="2.14.0"   # hard fallback if GitHub is unreachable
        _NPM_VERSION_SOURCE="fallback"
    fi
else
    _NPM_VERSION_SOURCE="pinned"
fi

# ---------------------------------------------------------------------------
}  # end _resolve_npm_version
_resolve_npm_version

# >>> SECTION: _show_splash_and_preflight >>>
_show_splash_and_preflight() {
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
echo -e "  ${BOLD}${GREEN}Nginx Proxy Manager${NC}${BOLD} ${G_DASH} Native Linux Installer${NC}"
echo -e "  ${DIM}No Docker ${G_DOT} SQLite ${G_DOT} Systemd ${G_DOT} Team Njordium${NC}"
echo -e "  ${DIM}---------------------------------------------${NC}"
echo ""
_TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
# v1.1.17: show the target version with a source-aware label, and append
# an Installed line if a prior install is detected. dpkg --compare-versions
# is Debian/Ubuntu-native and handles semver edge cases (e.g. 2.14.10 > 2.14.2).
_INSTALLED_NPM_VER=""
if [[ -f "${NPM_HOME}/backend/package.json" ]]; then
    _INSTALLED_NPM_VER=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version','?'))" \
        "${NPM_HOME}/backend/package.json" 2>/dev/null || echo "")
    [[ "${_INSTALLED_NPM_VER}" == "?" ]] && _INSTALLED_NPM_VER=""
fi

case "${_NPM_VERSION_SOURCE:-latest}" in
    latest)   _NPM_VER_LABEL="Latest    " ;;
    pinned)   _NPM_VER_LABEL="Target    " ;;
    fallback) _NPM_VER_LABEL="Fallback  " ;;
    *)        _NPM_VER_LABEL="Version   " ;;
esac

_NPM_STATUS_NOTE=""
if [[ -n "${_INSTALLED_NPM_VER}" ]]; then
    if [[ "${_INSTALLED_NPM_VER}" == "${NPM_VERSION}" ]]; then
        _NPM_STATUS_NOTE="${GREEN}(up to date)${NC}"
    elif dpkg --compare-versions "${_INSTALLED_NPM_VER}" lt "${NPM_VERSION}" 2>/dev/null; then
        _NPM_STATUS_NOTE="${YELLOW}(update available)${NC}"
    else
        _NPM_STATUS_NOTE="${YELLOW}(installed is newer)${NC}"
    fi
fi

echo -e "  ${CYAN}${_NPM_VER_LABEL}:${NC} ${BOLD}v${NPM_VERSION}${NC}     ${CYAN}Node.js   :${NC} ${BOLD}v${NODE_MAJOR} LTS${NC}"
if [[ -n "${_INSTALLED_NPM_VER}" ]]; then
    echo -e "  ${CYAN}Installed :${NC} ${BOLD}v${_INSTALLED_NPM_VER}${NC}  ${_NPM_STATUS_NOTE}"
fi
echo -e "  ${CYAN}Install   :${NC} ${NPM_HOME}"
echo -e "  ${CYAN}Data      :${NC} ${NPM_DATA}"
echo -e "  ${CYAN}Database  :${NC} SQLite (${NPM_DATA}/database.sqlite)"
echo -e "  ${CYAN}Service   :${NC} ${NPM_SERVICE}"
echo -e "  ${CYAN}Memory    :${NC} ${_TOTAL_RAM_MB} MB   ${CYAN}Minimum   :${NC} ${BOLD}2048 MB (2 GB)${NC}"
echo ""
if [[ "${_TOTAL_RAM_MB}" -gt 0 && "${_TOTAL_RAM_MB}" -lt 2048 ]]; then
    # v1.1.19: detect existing swap; offer to auto-create more if needed.
    _TOTAL_SWAP_MB=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
    _RAM_GAP=$(( 2048 - _TOTAL_RAM_MB ))
    _SWAP_TARGET=$(( 2048 + 512 - _TOTAL_RAM_MB ))
    [[ ${_SWAP_TARGET} -lt 1024 ]] && _SWAP_TARGET=1024

    echo -e "  ${RED}${BOLD}WARNING: This system has ${_TOTAL_RAM_MB} MB RAM.${NC}"
    echo -e "  ${RED}The frontend build requires at least 2 GB of memory${NC} (RAM + swap)."
    echo -e "  ${DIM}Current swap: ${_TOTAL_SWAP_MB} MB. Gap to 2 GB: ${_RAM_GAP} MB.${NC}"
    echo ""

    NPM_AUTOSWAP="${NPM_AUTOSWAP:-auto}"
    _SHOULD_CREATE_SWAP=false

    case "${NPM_AUTOSWAP}" in
        false)
            : ;;
        true)
            _SHOULD_CREATE_SWAP=true ;;
        auto|*)
            if [[ "${_TOTAL_SWAP_MB}" -ge "${_RAM_GAP}" ]]; then
                info "Existing swap (${_TOTAL_SWAP_MB} MB) already covers the gap ${G_DASH} no extra swap needed."
            elif [[ -t 0 ]]; then
                echo -e "  ${YELLOW}Recommended:${NC} create ${_SWAP_TARGET} MB swap file at ${NPM_SWAPFILE:-/swapfile} (override path with NPM_SWAPFILE)."
                read -rp "  Create swap file now? [Y/n]: " _SWAP_CONFIRM || true
                if [[ ! "${_SWAP_CONFIRM,,}" =~ ^(n|no)$ ]]; then
                    _SHOULD_CREATE_SWAP=true
                fi
            else
                warn "Non-interactive mode: NOT auto-creating swap. Set NPM_AUTOSWAP=true to force."
            fi ;;
    esac

    if ${_SHOULD_CREATE_SWAP}; then
        if ! _create_swap "${_SWAP_TARGET}"; then
            warn "Swap creation failed ${G_DASH} build may run out of memory."
        fi
        echo ""
    fi

    # If we still don't have enough memory after the swap step, ask before proceeding.
    _POST_SWAP_TOTAL=$(( _TOTAL_RAM_MB + $(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0) ))
    if [[ ${_POST_SWAP_TOTAL} -lt 2048 ]]; then
        warn "Total memory after swap step is still ${_POST_SWAP_TOTAL} MB (< 2 GB). Build may OOM."
        if [[ -t 0 ]]; then
            read -rp "  Continue anyway? [y/N]: " _RAM_CONFIRM || true
            [[ "${_RAM_CONFIRM,,}" == "y" || "${_RAM_CONFIRM,,}" == "yes" ]] || { echo ""; echo "  Aborted."; exit 1; }
            echo ""
        fi
    fi
fi

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

# Debian 12 (bookworm) ships nginx 1.22.1, which predates the `http2 on/off`
# directives (introduced in nginx 1.25.1). NPM's _listen.conf template emits
# them unconditionally, so on bookworm we will patch the template later in
# Step 6 to remove the block. Warn the user up front so the change isn't a
# surprise. Reported in #3.
if [[ "${_OS_CODENAME}" == "bookworm" ]]; then
    warn "Debian 12 (bookworm) ships nginx 1.22.1 ${G_DASH} installer will patch NPM's _listen.conf to remove the unsupported http2 on/off directive (HTTP/2 toggle in the UI will be inert)."
fi

# ---------------------------------------------------------------------------
}  # end _show_splash_and_preflight
_show_splash_and_preflight

# >>> SECTION: _select_install_mode >>>
_select_install_mode() {
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
            _infoline "${GREEN}" "${G_OK_DOT}" "Service"  "running"
        else
            _infoline "${RED}"   "${G_OK_DOT}" "Service"  "stopped"
        fi
        _infoline "${CYAN}" "${G_OK_DOT}" "Home dir" "${NPM_HOME}"
        if ${_HAS_DB}; then
            DB_SIZE=$(du -sh "${NPM_DATA}/database.sqlite" 2>/dev/null | cut -f1)
            _infoline "${CYAN}" "${G_OK_DOT}" "Database" "${NPM_DATA}/database.sqlite (${DB_SIZE})"
        else
            _infoline "${DIM}"  "${G_NF_DOT}" "Database" "not found"
        fi
        echo ""   
        echo ""
        echo -e "  ${BOLD}Select an option:${NC}"
        echo ""
        echo -e "  ${BOLD}${RED}1)${NC} ${BOLD}Fresh install${NC}  ${G_DASH} Full reinstall, ${RED}wipes database${NC} (clean slate)"
        echo -e "  ${BOLD}${YELLOW}2)${NC} ${BOLD}Update/reinstall${NC} ${G_DASH} Reinstall NPM, ${GREEN}database preserved${NC}"
        echo -e "  ${BOLD}${GREEN}3)${NC} ${BOLD}Verify install${NC}  ${G_DASH} Run health checks on the current installation"
        echo -e "  ${BOLD}${DIM}q)${NC} ${DIM}Quit${NC}"
        echo ""
        if [[ -t 0 ]]; then
            read -rp "  Choice [1/2/3/q]: " _CHOICE || true
        else
            _CHOICE=""
            warn "Non-interactive mode with existing install detected ${G_DASH} aborting for safety."
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
        echo -e "  ${GREEN}No existing installation found ${G_DASH} proceeding with fresh install.${NC}"
        echo ""
        INSTALL_MODE="fresh"
    fi
fi

info "Mode: ${BOLD}${INSTALL_MODE}${NC}"

# ---------------------------------------------------------------------------
}  # end _select_install_mode
_select_install_mode

# >>> SECTION: _select_verbosity >>>
_select_verbosity() {
# Verbose mode question (only if not set via CLI flag and not verify mode)
# ---------------------------------------------------------------------------
if [[ "${INSTALL_MODE}" != "verify" ]]; then
    # Skip verbosity prompt when stdin is not a terminal (piped/non-interactive).
    # 'read' returns exit code 1 on EOF which kills the script under set -e.
    if [[ -t 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Output verbosity:${NC}"
        echo -e "  ${BOLD}${GREEN}1)${NC} Quiet ${DIM}(default)${NC}  ${G_DASH} Show main steps only"
        echo -e "  ${BOLD}${CYAN}2)${NC} Verbose          ${G_DASH} Show all output from every step"
        echo ""
        read -rp "  Verbosity [1/2, default=1]: " _VERB_CHOICE || true
        case "${_VERB_CHOICE}" in
            2) VERBOSE=true;  echo -e "  ${CYAN}Verbose mode enabled.${NC}" ;;
            *) VERBOSE=false; echo -e "  ${DIM}Quiet mode ${G_DASH} only main steps will be shown.${NC}" ;;
        esac
        echo ""
    else
        info "Non-interactive mode ${G_DASH} using quiet output (pass --verbose to override)."
    fi
fi

# ---------------------------------------------------------------------------
}  # end _select_verbosity
_select_verbosity

# >>> SECTION: _run_verify_mode >>>
_run_verify_mode() {
# ── VERIFY mode — full installation health dashboard ────────────────────────
# ---------------------------------------------------------------------------
if [[ "${INSTALL_MODE}" == "verify" ]]; then
    _PASS=0; _FAIL=0; _WARN=0
    _pok()  { echo -e "  ${GREEN}[PASS]${NC} $*"; (( _PASS += 1 )) || true; }
    _pfail(){ echo -e "  ${RED}[FAIL]${NC} $*"; (( _FAIL += 1 )) || true; }
    _pwarn(){ echo -e "  ${YELLOW}[WARN]${NC} $*"; (( _WARN += 1 )) || true; }
    _sect() { echo ""; echo -e "${BOLD}${G_HBAR}${G_HBAR} $* ${G_HBAR}${G_HBAR}${NC}"; }

    # Cache host IP once for all verify output
    HOST_IP=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${BOLD}${CYAN}${G_TL2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_TR2}${NC}"
    echo -e "${BOLD}${CYAN}${G_VBAR2}   Nginx Proxy Manager ${G_DASH} Installation Verification            ${G_VBAR2}${NC}"
    echo -e "${BOLD}${CYAN}${G_BL2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_BR2}${NC}"
    echo -e "  ${DIM}Host: $(hostname)   IP: ${HOST_IP}   $(date '+%Y-%m-%d %H:%M:%S')${NC}"

    # ── Services ─────────────────────────────────────────────────────────────
    _sect "Services"
    if systemctl is-active --quiet "${NPM_SERVICE}" 2>/dev/null; then
        _NPM_PID=$(systemctl show -p MainPID "${NPM_SERVICE}" 2>/dev/null | cut -d= -f2)
        _NPM_MEM=$(systemctl show -p MemoryCurrent "${NPM_SERVICE}" 2>/dev/null | cut -d= -f2)
        # MemoryCurrent can be empty or non-numeric before the service is fully running.
        # set -e does NOT catch errors inside $(( )) but non-numeric operands DO kill the script.
        if [[ "${_NPM_MEM}" =~ ^[0-9]+$ ]]; then
            _NPM_MEM_MB=$(( _NPM_MEM / 1024 / 1024 ))
        else
            _NPM_MEM_MB="?"
        fi
        _NPM_UP=$(systemctl show -p ActiveEnterTimestamp "${NPM_SERVICE}" 2>/dev/null | cut -d= -f2)
        _pok  "nginx-proxy-manager  active  PID=${_NPM_PID}  MEM=${_NPM_MEM_MB}MB"
        echo -e "       ${DIM}since: ${_NPM_UP}${NC}"
    else
        _pfail "nginx-proxy-manager  NOT running"
        echo  "       ${G_ARROW} run: systemctl start ${NPM_SERVICE}"
    fi
    if systemctl is-enabled --quiet "${NPM_SERVICE}" 2>/dev/null; then
        _pok  "nginx-proxy-manager  enabled (auto-starts on reboot)"
    else
        _pwarn "nginx-proxy-manager  NOT enabled ${G_DASH} won't start after reboot"
    fi
    if systemctl is-active --quiet nginx 2>/dev/null; then
        _NGINX_V=$(nginx -v 2>&1 | grep -oP 'nginx/[\d.]+' || echo "nginx")
        _pok  "nginx                active  (${_NGINX_V})"
    else
        _pfail "nginx                NOT running"
    fi
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        _pok  "nginx                enabled (auto-starts on reboot)"
    else
        _pwarn "nginx                NOT enabled ${G_DASH} won't start after reboot"
        echo  "       ${G_ARROW} run: systemctl enable nginx"
    fi
    if nginx -t &>/dev/null 2>&1; then
        _pok  "nginx config         syntax OK"
    else
        _pfail "nginx config         FAILED ${G_DASH} run: nginx -t"
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
        _pfail "backend process      port 3000 NOT bound ${G_DASH} Node.js backend not running"
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
            _pwarn "backend API          responding on :3000 directly but NOT via nginx port ${ADMIN_PORT} ${G_DASH} nginx is down"
            echo  "       ${G_ARROW} run: systemctl start nginx"
        else
            _pfail "backend API          not responding on port ${ADMIN_PORT} or :3000 directly (nginx down + backend issue)"
        fi
    fi

    # Admin UI (nginx serves React SPA)
    _UI_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "http://127.0.0.1:${ADMIN_PORT}/" 2>/dev/null || echo "000")
    _UI_CT=$(curl -s -I --max-time 4 "http://127.0.0.1:${ADMIN_PORT}/" 2>/dev/null | grep -i "^content-type" | tr -d '\r' | head -1)
    if [[ "${_UI_HTTP}" =~ ^[23] ]]; then
        _pok  "admin UI             http://${HOST_IP}:${ADMIN_PORT}/ -> HTTP ${_UI_HTTP}"
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
        _pok  "admin account        created ${G_DASH} setup wizard complete"
    elif [[ "${_SETUP_RESP}" == "setup_needed" ]]; then
        _pwarn "admin account        NOT created yet ${G_DASH} visit http://${HOST_IP}:${ADMIN_PORT}/ to set up"
    else
        _pwarn "admin account        could not determine setup state"
    fi

    # ── File system ──────────────────────────────────────────────────────────
    _sect "File System"
    [[ -f "${NPM_HOME}/backend/index.js" ]]         && _pok  "backend              ${NPM_HOME}/backend/index.js"         || _pfail "backend              index.js MISSING at ${NPM_HOME}/backend/"
    [[ -f "${NPM_HOME}/frontend/index.html" ]]         && _pok  "frontend             ${NPM_HOME}/frontend/index.html"         || _pfail "frontend             index.html MISSING ${G_DASH} UI will not load"
    [[ -d "${NPM_HOME}/frontend/lang" ]]         && { _LANG_COUNT=$(ls "${NPM_HOME}/frontend/lang/"*.json 2>/dev/null | wc -l)
             _pok  "locales              ${NPM_HOME}/frontend/lang/ (${_LANG_COUNT} files)"; }         || _pwarn "locales              lang/ missing ${G_DASH} UI may show raw i18n keys"
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
    if ( cd "${NPM_HOME}/backend" && node -e "require('bcrypt')" &>/dev/null ); then
        _pok  "bcrypt               loads OK (password hashing)"
    else
        _pfail "bcrypt               FAILED to load ${G_DASH} backend will crash on login"
    fi
    # SQLite driver detection — the original used `for ... done || _pfail`
    # which never fires when the loop runs to completion. Use an explicit flag.
    _SQLITE_OK=false
    for _sq in better-sqlite3 sqlite3; do
        if ( cd "${NPM_HOME}/backend" && node -e "require('${_sq}')" &>/dev/null ); then
            _pok  "${_sq}      loads OK (database driver)"
            _SQLITE_OK=true
            break
        fi
    done
    ${_SQLITE_OK} || _pfail "sqlite               no SQLite driver loads (better-sqlite3 or sqlite3)"

    # ── Configuration ────────────────────────────────────────────────────────
    _sect "Configuration"
    _PROD="${NPM_HOME}/backend/config/production.json"
    if [[ -f "${_PROD}" ]]; then
        _DB_CLIENT=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['database']['knex']['client'])" "${_PROD}" 2>/dev/null || echo "?")
        _DB_FILE=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['database']['knex']['connection']['filename'])" "${_PROD}" 2>/dev/null || echo "?")
        if [[ "${_DB_CLIENT}" == "better-sqlite3" ]]; then
            _pok  "db client            ${_DB_CLIENT} (isSqlite()=true ${G_ARROW} uses datetime('now'))"
        else
            _pfail "db client            '${_DB_CLIENT}' ${G_DASH} must be 'better-sqlite3' or NOW() errors occur"
        fi
        _pok  "db file              ${_DB_FILE}"
    fi
    grep -q 'proxy_pass.*127.0.0.1:3000' /etc/nginx/nginx.conf 2>/dev/null         && _pok  "nginx proxy          port ${ADMIN_PORT} ${G_ARROW} :3000 present"         || _pfail "nginx proxy          port ${ADMIN_PORT} ${G_ARROW} :3000 missing in nginx.conf"

    # Certbot virtualenv — required for DNS challenge certificate requests
    if [[ -f "/opt/certbot/bin/activate" ]]; then
        _CB_VER=$(/opt/certbot/bin/certbot --version 2>&1 | grep -oP '[\d.]+' | head -1)
        _pok  "certbot venv         /opt/certbot (v${_CB_VER}) ${G_DASH} DNS plugins will install correctly"
    else
        _pfail "certbot venv         /opt/certbot MISSING ${G_DASH} DNS challenge cert requests will fail"
        echo  "       ${G_ARROW} run: python3 -m venv /opt/certbot && /opt/certbot/bin/pip install certbot"
    fi

    # Check Docker rootfs include files — required for proxy host config generation
    _MISS=0
    for _INC in proxy.conf block-exploits.conf force-ssl.conf ssl-ciphers.conf; do
        [[ ! -f "/etc/nginx/conf.d/include/${_INC}" ]] && {
            _pfail "nginx include /etc/nginx/conf.d/include/${_INC} MISSING ${G_DASH} proxy hosts will not write nginx configs"
            _MISS=$(( _MISS + 1 ))
        }
    done
    [[ ${_MISS} -eq 0 ]] && _pok "nginx conf.d/include files present (proxy.conf, block-exploits.conf, etc.)"

    # nginx -t — if this fails, proxy host config creation silently rolls back
    if nginx -t &>/dev/null 2>&1; then
        _pok  "nginx -t syntax OK (proxy host config creation will succeed)"
    else
        _pfail "nginx -t FAILED ${G_DASH} proxy host config creation will silently roll back (run: nginx -t)"
    fi

    # ── Environment ──────────────────────────────────────────────────────────
    # v1.1.15: catches "disk full / clock skew / db corrupt" issues that
    # otherwise surface as silent failures days later.
    _sect "Environment"
    # Disk free for each path the installer writes to
    for _path in / /opt "${NPM_DATA}" /var; do
        [[ -d "${_path}" ]] || continue
        _free_kb=$(df -k "${_path}" 2>/dev/null | tail -1 | awk '{print $4}')
        _free_human=$(df -h "${_path}" 2>/dev/null | tail -1 | awk '{print $4}')
        if   [[ ${_free_kb:-0} -lt 102400 ]]; then  _pfail "disk ${_path}        ${_free_human} free (< 100 MB)"
        elif [[ ${_free_kb:-0} -lt 1048576 ]]; then _pwarn "disk ${_path}        ${_free_human} free (< 1 GB)"
        else _pok  "disk ${_path}        ${_free_human} free"
        fi
    done

    # Time sync — cert validation breaks with a skewed clock
    _TIMESYNC_ACTIVE=false
    for _svc in chronyd systemd-timesyncd ntpd ntp; do
        if systemctl is-active --quiet "${_svc}" 2>/dev/null; then
            _pok "time sync           ${_svc} active"
            _TIMESYNC_ACTIVE=true
            break
        fi
    done
    ${_TIMESYNC_ACTIVE} || _pwarn "time sync           no chronyd/systemd-timesyncd/ntpd active ${G_DASH} cert validation may fail"

    # Database integrity + row counts (only if DB exists)
    if [[ -f "${NPM_DATA}/database.sqlite" ]]; then
        _INTEG=$(sqlite3 "${NPM_DATA}/database.sqlite" "PRAGMA integrity_check" 2>/dev/null | head -1)
        if [[ "${_INTEG}" == "ok" ]]; then
            _pok "database integrity  PRAGMA integrity_check = ok"
        else
            _pfail "database integrity  ${_INTEG:-PRAGMA failed (DB locked or unreadable)}"
        fi
        _N_HOSTS=$(sqlite3 "${NPM_DATA}/database.sqlite" "SELECT COUNT(*) FROM proxy_host WHERE is_deleted=0" 2>/dev/null || echo "?")
        _N_USERS=$(sqlite3 "${NPM_DATA}/database.sqlite" "SELECT COUNT(*) FROM user WHERE is_deleted=0" 2>/dev/null || echo "?")
        _N_CERTS=$(sqlite3 "${NPM_DATA}/database.sqlite" "SELECT COUNT(*) FROM certificate WHERE is_deleted=0" 2>/dev/null || echo "?")
        _pok "db contents         ${_N_HOSTS} proxy hosts, ${_N_USERS} users, ${_N_CERTS} certificates"
    fi

    # ── External ─────────────────────────────────────────────────────────────
    # v1.1.15: confirms the host can actually do cert renewal.
    _sect "External"
    # Outbound HTTPS to Let'''s Encrypt API
    if curl -sf --max-time 5 -o /dev/null "https://acme-v02.api.letsencrypt.org/directory" 2>/dev/null; then
        _pok "Let'''s Encrypt API   reachable (cert renewal should succeed)"
    else
        _pwarn "Let'''s Encrypt API   NOT reachable ${G_DASH} check outbound HTTPS / DNS / firewall"
    fi

    # Per-cert expiry inside /etc/letsencrypt/live/<domain>/cert.pem
    if [[ -d /etc/letsencrypt/live ]]; then
        _CERT_FOUND=0
        while IFS= read -r _cert; do
            _CERT_FOUND=$(( _CERT_FOUND + 1 ))
            _domain=$(basename "$(dirname "${_cert}")")
            _expiry=$(openssl x509 -enddate -noout -in "${_cert}" 2>/dev/null | cut -d= -f2)
            if [[ -z "${_expiry}" ]]; then
                _pwarn "cert ${_domain}      could not read expiry (openssl x509 failed)"
                continue
            fi
            _expiry_epoch=$(date -d "${_expiry}" +%s 2>/dev/null || echo 0)
            _now_epoch=$(date +%s)
            _days_left=$(( (_expiry_epoch - _now_epoch) / 86400 ))
            _expiry_human=$(date -d "${_expiry}" '+%Y-%m-%d' 2>/dev/null || echo "${_expiry}")
            if   [[ ${_days_left} -lt 0 ]];   then _pfail "cert ${_domain}      EXPIRED ${_days_left#-} days ago (${_expiry_human}) ${G_DASH} renew now"
            elif [[ ${_days_left} -lt 7 ]];   then _pfail "cert ${_domain}      expires in ${_days_left} days (${_expiry_human})"
            elif [[ ${_days_left} -lt 30 ]];  then _pwarn "cert ${_domain}      expires in ${_days_left} days (${_expiry_human})"
            else _pok  "cert ${_domain}      ${_days_left} days until expiry (${_expiry_human})"
            fi
        done < <(find /etc/letsencrypt/live -name 'cert.pem' 2>/dev/null)
        if [[ ${_CERT_FOUND} -eq 0 ]]; then
            _pwarn "Let'''s Encrypt certs no /etc/letsencrypt/live/*/cert.pem found yet ${G_DASH} expected on a fresh install"
        fi
    fi

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${NC}"
    _TOTAL=$(( _PASS + _FAIL + _WARN ))
    echo -e "  ${GREEN}${_PASS} passed${NC}  ${RED}${_FAIL} failed${NC}  ${YELLOW}${_WARN} warnings${NC}  / ${_TOTAL} total checks"
    echo ""
    if [[ ${_FAIL} -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}${G_CROSS}  Installation has problems. See FAIL items above.${NC}"
        echo ""
        exit 1
    elif [[ ${_WARN} -gt 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}${G_WARN_SYM}  Installation OK with warnings.${NC}"
    else
        echo -e "  ${GREEN}${BOLD}${G_CHECK}  All checks passed. NPM is healthy and fully operational.${NC}"
    fi
    echo ""
    echo -e "  ${CYAN}Admin Panel :${NC} ${BOLD}http://${HOST_IP}:${ADMIN_PORT}${NC}"
    echo -e "  ${CYAN}Version     :${NC} ${_VER_CURRENT}"
    echo ""

    # v1.1.11 (#5): offer a diagnostic bundle for issue submission.
    # Bundle = service journal tails, /data/logs/ tails, production.json,
    # backend package.json, system info. No secrets in any of these on a
    # default install — but printed prominently so the operator can review.
    if [[ -t 0 ]]; then
        read -rp "  Save diagnostic bundle to /var/backups/npm-diag-<ts>.tar.gz? [Y/n]: " _DIAG_CONFIRM || true
        if [[ ! "${_DIAG_CONFIRM,,}" =~ ^(n|no)$ ]]; then
            mkdir -p /var/backups 2>/dev/null || true
            _DIAG_DEST="/var/backups/npm-diag-$(date +%Y%m%d%H%M%S).tar.gz"
            _DIAG_TMP=$(mktemp -d /tmp/npm-diag.XXXXXX)
            mkdir -p "${_DIAG_TMP}"/{journal,logs,config}
            journalctl -u "${NPM_SERVICE}" -n 500 --no-pager 2>/dev/null > "${_DIAG_TMP}/journal/npm-service.log" || true
            journalctl -u nginx -n 200 --no-pager 2>/dev/null > "${_DIAG_TMP}/journal/nginx.log" || true
            for _lg in "${NPM_DATA}"/logs/*.log; do
                [[ -f "${_lg}" ]] && tail -n 1000 "${_lg}" > "${_DIAG_TMP}/logs/$(basename ${_lg})" 2>/dev/null
            done
            [[ -f "${NPM_HOME}/backend/config/production.json" ]] && \
                cp "${NPM_HOME}/backend/config/production.json" "${_DIAG_TMP}/config/production.json"
            [[ -f "${NPM_HOME}/backend/package.json" ]] && \
                cp "${NPM_HOME}/backend/package.json" "${_DIAG_TMP}/config/package.json"
            nginx -T 2>/dev/null > "${_DIAG_TMP}/config/nginx-T.txt" || true
            {
                echo "installer-version: ${SCRIPT_VERSION}"
                echo "npm-version: ${_VER_CURRENT}"
                echo "node: $(node --version 2>/dev/null || echo not-installed)"
                echo "pnpm: $(pnpm --version 2>/dev/null || echo not-installed)"
                echo "nginx: $(nginx -v 2>&1 | head -1)"
                echo "certbot: $(/opt/certbot/bin/certbot --version 2>&1 | head -1)"
                echo "kernel: $(uname -a)"
                echo "os: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '\"')"
                echo "ts: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            } > "${_DIAG_TMP}/system-info.txt"
            if tar -czf "${_DIAG_DEST}" -C "${_DIAG_TMP}" . 2>/dev/null; then
                log "Diagnostic bundle saved: ${_DIAG_DEST}"
                info "Review before sharing ${G_DASH} bundle contains journal tails + nginx -T output."
            else
                warn "Failed to assemble diagnostic bundle."
            fi
            rm -rf "${_DIAG_TMP}"
        fi
        echo ""
    fi
    exit 0
fi
# ---------------------------------------------------------------------------
}  # end _run_verify_mode
_run_verify_mode

# >>> SECTION: _prepare_for_install >>>
_prepare_for_install() {
# Pre-install actions based on mode
# ---------------------------------------------------------------------------
if [[ "${INSTALL_MODE}" == "fresh" ]]; then
    # v1.1.11 (#4): before nuking the DB, look for a previous DB backup.
    # If found, offer to restore — saves anyone who picked "fresh" by mistake.
    # Restore switches the flow to update mode so the new code is installed
    # over the restored database.
    _NEWEST_BAK=""
    if compgen -G "${NPM_DATA}/database.sqlite.bak.*" > /dev/null 2>&1; then
        _NEWEST_BAK=$(ls -1t "${NPM_DATA}"/database.sqlite.bak.* 2>/dev/null | head -1)
    fi
    if [[ -n "${_NEWEST_BAK}" && -t 0 ]]; then
        _BAK_DATE=$(stat -c '%y' "${_NEWEST_BAK}" 2>/dev/null | cut -d. -f1)
        echo ""
        info "Previous database backup detected:"
        info "  ${_NEWEST_BAK}"
        info "  mtime: ${_BAK_DATE}"
        read -rp "  Restore this backup instead of a fresh install? [y/N]: " _RESTORE_CONFIRM || true
        if [[ "${_RESTORE_CONFIRM,,}" == "y" || "${_RESTORE_CONFIRM,,}" == "yes" ]]; then
            cp "${_NEWEST_BAK}" "${NPM_DATA}/database.sqlite" \
                && log "Database restored from ${_NEWEST_BAK}" \
                || die "Restore failed ${G_DASH} refusing to continue"
            INSTALL_MODE="update"
            _HAS_DB=true
            info "Switched to --update flow with the restored database in place."
        fi
    fi
fi

# Re-check INSTALL_MODE in case #4 flipped us from fresh → update
if [[ "${INSTALL_MODE}" == "fresh" ]]; then
    if ${_HAS_DB}; then
        echo -e "${RED}${G_TL1}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_TR1}${NC}"
        echo -e "${RED}${G_VBAR1}  WARNING: Fresh install will permanently DELETE the database! ${G_VBAR1}${NC}"
        echo -e "${RED}${G_VBAR1}  All proxy hosts, SSL certificates, and users will be lost.  ${G_VBAR1}${NC}"
        echo -e "${RED}${G_BL1}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_HBAR}${G_BR1}${NC}"
        echo ""
        read -rp "  Type YES to confirm database wipe: " _DB_CONFIRM || true
        [[ "${_DB_CONFIRM}" == "YES" ]] || { info "Aborted ${G_DASH} database not touched."; exit 0; }
    fi
    # Stop and backup
    systemctl stop "${NPM_SERVICE}" 2>/dev/null || true
    if [[ -f "${NPM_DATA}/database.sqlite" ]]; then
        DB_BACKUP="${NPM_DATA}/database.sqlite.bak.$(date +%Y%m%d%H%M%S)"
        cp "${NPM_DATA}/database.sqlite" "${DB_BACKUP}"
        [[ -f "${DB_BACKUP}" ]] || die "Database backup failed ${G_DASH} refusing to delete original"
        warn "Database backed up to: ${DB_BACKUP}"
        rm -f "${NPM_DATA}/database.sqlite"
        info "Database wiped ${G_DASH} starting fresh."
    fi
elif [[ "${INSTALL_MODE}" == "update" ]]; then
    # v1.1.9: do NOT stop the service here — defer until just before the
    # install swap in _step5_install_backend. The service stays up through
    # the frontend build (the longest phase), shrinking total downtime.
    if ${_HAS_DB}; then
        DB_BACKUP="${NPM_DATA}/database.sqlite.bak.$(date +%Y%m%d%H%M%S)"
        cp "${NPM_DATA}/database.sqlite" "${DB_BACKUP}"
        [[ -f "${DB_BACKUP}" ]] || die "Database backup failed ${G_DASH} refusing to proceed"
        log "Database backed up to: ${DB_BACKUP}"
    fi
    info "Database preserved ${G_DASH} update mode (service still running)."

    # v1.1.10 (#8): warn / prompt on minor or major version jumps.
    # `--update` auto-resolves "latest" from GitHub; a 2.13.x → 2.16.0
    # leap could carry schema or template changes the operator should
    # see before crossing. Read installed version from the package.json
    # we are about to replace.
    if [[ -f "${NPM_HOME}/backend/package.json" ]]; then
        _INSTALLED_VER=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version','?'))" \
            "${NPM_HOME}/backend/package.json" 2>/dev/null || echo "?")
        if [[ "${_INSTALLED_VER}" != "?" && "${_INSTALLED_VER}" != "${NPM_VERSION}" ]]; then
            _IM=$(echo "${_INSTALLED_VER}" | cut -d. -f1-2)
            _NM=$(echo "${NPM_VERSION}"    | cut -d. -f1-2)
            # v1.1.11 (#1 + #6): minor/major jump — show release-notes summary,
            # then offer a three-way menu so the operator can pin/redirect
            # without re-running the script.
            while [[ "${_IM}" != "${_NM}" ]]; do
                echo ""
                warn "Version jump: installed v${_INSTALLED_VER} ${G_ARROW} resolved v${NPM_VERSION} crosses minor/major."
                # v1.1.11 (#1): fetch and show the Changes section from the
                # upstream release notes so the operator decides in-context.
                _REL_URL="https://github.com/NginxProxyManager/nginx-proxy-manager/releases/tag/v${NPM_VERSION}"
                _REL_API="https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/tags/v${NPM_VERSION}"
                _REL_BODY=$(curl -sf --max-time 8 "${_REL_API}" 2>/dev/null || true)
                if [[ -n "${_REL_BODY}" ]]; then
                    echo ""
                    echo -e "  ${BOLD}${CYAN}${G_HBAR}${G_HBAR} Upstream changelog for v${NPM_VERSION} ${G_HBAR}${G_HBAR}${NC}"
                    printf '%s' "${_REL_BODY}" | python3 - << 'PYCHANGE'
import sys, json, re
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
body = data.get("body", "")
body = re.sub(r'<!--.*?-->', '', body, flags=re.DOTALL)
body = re.sub(r'!\[.*?\]\(.*?\)', '', body)
body = re.sub(r'\[!.*?\]', '', body)
lines = [l.rstrip() for l in body.splitlines()]
in_changes = False
out = []
for l in lines:
    if l.startswith('## '):
        in_changes = 'change' in l.lower() or 'highlight' in l.lower() or 'note' in l.lower()
        if in_changes:
            out.append(l)
        elif out:
            break
        continue
    if in_changes and l.strip():
        out.append(l)
    if len(out) >= 12:
        break
for l in out:
    print("    " + l)
if not out:
    print("    (no Changes section found in release body ${G_DASH} see URL below)")
PYCHANGE
                    echo ""
                    echo -e "  ${DIM}Full notes: ${_REL_URL}${NC}"
                else
                    warn "Could not fetch release notes from GitHub. See: ${_REL_URL}"
                fi

                if [[ ! -t 0 ]]; then
                    warn "Non-interactive cross-minor update ${G_DASH} proceeding. Use --version <x.y.z> or NPM_VERSION env to pin."
                    break
                fi

                echo ""
                echo -e "  ${BOLD}Version-jump menu:${NC}"
                echo -e "    ${BOLD}${GREEN}1)${NC} Proceed with resolved v${NPM_VERSION}"
                echo -e "    ${BOLD}${YELLOW}2)${NC} Abort and pin to currently installed v${_INSTALLED_VER}"
                echo -e "    ${BOLD}${CYAN}3)${NC} Specify a different version (x.y.z)"
                echo -e "    ${BOLD}${DIM}q)${NC} Quit without doing anything"
                echo ""
                read -rp "  Choice [1/2/3/q]: " _VER_CHOICE || true
                case "${_VER_CHOICE}" in
                    1)
                        info "Proceeding with v${NPM_VERSION}"
                        break
                        ;;
                    2)
                        info "Aborted. Re-run with --version ${_INSTALLED_VER} to lock the resolver to your installed version."
                        exit 0
                        ;;
                    3)
                        while true; do
                            read -rp "    Enter version (x.y.z, e.g. 2.14.5): " _NEW_VER || true
                            if [[ "${_NEW_VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                                NPM_VERSION="${_NEW_VER}"
                                _NM=$(echo "${NPM_VERSION}" | cut -d. -f1-2)
                                info "Re-resolved to v${NPM_VERSION}"
                                break
                            fi
                            warn "Invalid version format. Use x.y.z (e.g. 2.14.5)"
                        done
                        # Loop continues: if new version is still a jump, prompt again
                        ;;
                    q|Q|"")
                        info "Quit. Nothing was changed."
                        exit 0
                        ;;
                    *)
                        warn "Invalid choice. Please pick 1, 2, 3, or q."
                        ;;
                esac
            done
            if [[ "${_IM}" == "${_NM}" ]]; then
                info "Updating within same minor: v${_INSTALLED_VER} ${G_ARROW} v${NPM_VERSION}"
            fi
        fi
    fi

    # v1.1.11 (#3): scan for prior backups across all locations the installer
    # writes to. Show total size and the oldest entry, then offer to prune
    # backups older than 30 days BEFORE we add another round of them.
    _BAK_PATTERNS=(
        "${NPM_HOME}".bak-*
        "${NPM_DATA}"/database.sqlite.bak.*
        /etc/letsencrypt.bak-*
        /var/backups/etc-nginx.bak-*.tar.gz
        /etc/systemd/system/"${NPM_SERVICE}".service.bak-*
    )
    _FOUND_BAKS=()
    for _p in "${_BAK_PATTERNS[@]}"; do
        if compgen -G "${_p}" > /dev/null 2>&1; then
            while IFS= read -r _m; do _FOUND_BAKS+=("${_m}"); done < <(compgen -G "${_p}")
        fi
    done
    if [[ ${#_FOUND_BAKS[@]} -gt 0 ]]; then
        _TOTAL_BYTES=$(du -bsc "${_FOUND_BAKS[@]}" 2>/dev/null | tail -1 | awk '{print $1}')
        _TOTAL_HUMAN=$(echo "${_TOTAL_BYTES}" | awk '{ s=$1; for(u="";s>=1024 && length(u)<3;u=substr("KMG",length(u)+1,1))s/=1024; printf("%.1f %sB", s, u) }')
        _OLDER_30=$(find "${_FOUND_BAKS[@]}" -maxdepth 0 -mtime +30 2>/dev/null | wc -l)
        _OLDEST=$(find "${_FOUND_BAKS[@]}" -maxdepth 0 -printf '%T@ %p
' 2>/dev/null | sort -n | head -1 | awk '{print $2}')
        _OLDEST_DATE=$(stat -c '%y' "${_OLDEST}" 2>/dev/null | cut -d' ' -f1)
        echo ""
        info "Existing backup inventory:"
        info "  count: ${#_FOUND_BAKS[@]}   total size: ${_TOTAL_HUMAN}   oldest: ${_OLDEST_DATE}"
        info "  candidates older than 30 days: ${_OLDER_30}"
        if [[ "${_OLDER_30}" -gt 0 && -t 0 ]]; then
            read -rp "  Prune ${_OLDER_30} backup(s) older than 30 days now? [y/N]: " _PRUNE_CONFIRM || true
            if [[ "${_PRUNE_CONFIRM,,}" == "y" || "${_PRUNE_CONFIRM,,}" == "yes" ]]; then
                find "${_FOUND_BAKS[@]}" -maxdepth 0 -mtime +30 -exec rm -rf {} + 2>/dev/null
                log "Pruned ${_OLDER_30} old backup(s)."
            fi
        fi
    fi
fi

# v1.1.9 (#3): snapshot /etc/letsencrypt before any certbot venv work so an
# upgrade-broken renewer is recoverable without resorting to npm-backup.
# Runs for both fresh AND update — fresh installs over a previous certbot
# leave behind state worth keeping; update is the obvious case.
if [[ -d /etc/letsencrypt ]]; then
    LE_BACKUP="/etc/letsencrypt.bak-$(date +%Y%m%d%H%M%S)"
    if cp -a /etc/letsencrypt "${LE_BACKUP}" 2>/dev/null; then
        warn "Let's Encrypt state backed up to ${LE_BACKUP}"
    else
        warn "Failed to back up /etc/letsencrypt ${G_DASH} proceeding anyway"
    fi
fi

# v1.1.10 (#4): tarball /etc/nginx before the conf wipe in Step 6b.
# Customisations to nginx.conf (set_real_ip_from for new CDN, custom
# log_format, raised client_max_body_size, extra `include`) live here
# and get wiped wholesale. Tar -C / keeps paths relative to root for
# clean restore: `tar -xzf <file> -C /`.
if [[ -d /etc/nginx ]]; then
    mkdir -p /var/backups 2>/dev/null || true
    NGINX_BACKUP="/var/backups/etc-nginx.bak-$(date +%Y%m%d%H%M%S).tar.gz"
    if tar -czf "${NGINX_BACKUP}" -C / etc/nginx 2>/dev/null; then
        warn "/etc/nginx tarball backed up to ${NGINX_BACKUP}"
    else
        warn "Failed to tar /etc/nginx ${G_DASH} proceeding anyway"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
}  # end _prepare_for_install
_prepare_for_install

# >>> SECTION: _maybe_upgrade_system >>>
_maybe_upgrade_system() {
# Optional: system upgrade (fresh install only)
# ---------------------------------------------------------------------------
# v1.1.11 (#2): offer apt upgrade in update mode too — long-lived hosts
# often have package sets older than the NPM version being installed.
if [[ "${INSTALL_MODE}" != "verify" ]] && [[ -t 0 ]]; then
    echo -e "  ${BOLD}System package upgrade${NC}"
    if [[ "${INSTALL_MODE}" == "update" ]]; then
        echo -e "  ${DIM}Pulling in pending security/maintenance updates before NPM is reinstalled.${NC}"
    else
        echo -e "  ${DIM}Updating system packages ensures a clean foundation for the install.${NC}"
    fi
    echo ""
    read -rp "  Run apt update && apt upgrade now? [y/N]: " _UPG_CHOICE || true
    if [[ "${_UPG_CHOICE,,}" == "y" || "${_UPG_CHOICE,,}" == "yes" ]]; then
        step "Updating system packages (apt update && apt upgrade)"
        export DEBIAN_FRONTEND=noninteractive
        vrun apt-get update -qq
        vrun apt-get upgrade -y -qq
        log "System packages updated."
    else
        echo -e "  ${DIM}Skipped ${G_DASH} continuing with current package versions.${NC}"
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
}  # end _maybe_upgrade_system
_maybe_upgrade_system

# >>> SECTION: _step1_install_deps >>>
_step1_install_deps() {
# Step 1 — System dependencies
# ---------------------------------------------------------------------------
step "Step 1/7 ${G_DASH} Installing system dependencies"

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
}  # end _step1_install_deps
_step1_install_deps

# >>> SECTION: _step1b_certbot_venv >>>
_step1b_certbot_venv() {
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
}  # end _step1b_certbot_venv
_step1b_certbot_venv

# >>> SECTION: _step2_install_node >>>
_step2_install_node() {
# Step 2 — Node.js (via NodeSource)
# ---------------------------------------------------------------------------
step "Step 2/7 ${G_DASH} Installing Node.js ${NODE_MAJOR} LTS"

# Detect existing Node.js and check if it meets the required major version.
# NOTE: Debian Trixie ships nodejs v20 in its own repos but does NOT include
# npm alongside it. We always prefer nodesource to get both node + npm together.
_NEED_NODE=true
if command -v node &>/dev/null; then
    EXISTING_NODE=$(node --version 2>/dev/null | grep -oP '\d+' | head -1)
    if [[ "${EXISTING_NODE}" -ge "${NODE_MAJOR}" ]]; then
        log "Node.js $(node --version) already installed ${G_DASH} skipping."
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
        warn "NodeSource setup failed ${G_DASH} falling back to system nodejs+npm packages."
        vrun apt-get install -y nodejs npm
    fi

    # Verify we got the right Node.js version
    _INSTALLED=$(node --version 2>/dev/null | grep -oP '\d+' | head -1)
    if [[ -n "${_INSTALLED}" && "${_INSTALLED}" -ge "${NODE_MAJOR}" ]]; then
        log "Node.js $(node --version) installed."
    else
        warn "Node.js ${NODE_MAJOR}+ could not be installed (got: $(node --version 2>/dev/null || echo 'none'))."
        warn "Continuing ${G_DASH} pnpm install may fail if node version is too old."
    fi
fi

# Ensure npm is available — nodesource nodejs bundles npm, but Debian's
# nodejs package does NOT. Install separately only if truly missing.
if ! command -v npm &>/dev/null; then
    warn "npm not found ${G_DASH} installing npm separately..."
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
}  # end _step2_install_node
_step2_install_node

# >>> SECTION: _step3_clone_source >>>
_step3_clone_source() {
# Step 3 — Clone NPM source via git (full working tree, no export-ignore gaps)
# ---------------------------------------------------------------------------
step "Step 3/7 ${G_DASH} Cloning NPM v${NPM_VERSION} source"

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
[[ -d "${NPM_TMP}/frontend" ]] || die "Clone incomplete ${G_DASH} frontend/ directory missing."

log "Source cloned to ${NPM_TMP}" 

# ---------------------------------------------------------------------------
}  # end _step3_clone_source
_step3_clone_source

# >>> SECTION: _step4_build_frontend >>>
_step4_build_frontend() {
# Build the frontend
# ---------------------------------------------------------------------------
step "Step 4/7 ${G_DASH} Building frontend (this may take a few minutes)"

# Write the vite chunk-splitting patch script to /tmp (used later in this step)
cat > "${_VITE_PATCH}" << 'VITE_PATCH_EOF'
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
    # Pin to a known-good v10 minor — `^10.0.0` would happily resolve to a
    # future v10.x with breaking changes. `~10.1.0` allows patch updates only.
    jq '.dependencies["react-intl"] = "~10.1.0"' "${_FRONTEND_PKG}" \
        > "${_FRONTEND_PKG}.tmp" && mv "${_FRONTEND_PKG}.tmp" "${_FRONTEND_PKG}"
    info "react-intl patched: ^8.x ${G_ARROW} ~10.1.0 (v9 broken/deprecated; v10 API-compatible)"
fi

# ---------------------------------------------------------------------------
# Patch frontend pnpm.onlyBuiltDependencies (issue #4)
# ---------------------------------------------------------------------------
# pnpm v10+ blocks ALL postinstall scripts by default. The frontend toolchain
# (Vite + its native deps) needs them to compile their bindings — without an
# allow-list, `pnpm install` aborts with ERR_PNPM_IGNORED_BUILDS for packages
# like @parcel/watcher and esbuild. Patch the manifest before pnpm install so
# the resolver sees the allow-list from the very first run.
# v1.1.15: the legacy jq write to .pnpm.onlyBuiltDependencies was removed
# here. pnpm v11 ignored the package.json key (warning loop in install output);
# pnpm v10 reads onlyBuiltDependencies from pnpm-workspace.yaml just fine.
# The YAML below carries the allow-list for both major versions.

# v1.1.14: pnpm v11 removed `onlyBuiltDependencies` from package.json and
# replaced it with `allowBuilds` in pnpm-workspace.yaml. Different schema:
# map of name -> bool, not an array. Write both keys for compatibility.
# The package.json jq patch above is harmless belt-and-suspenders.
cat > "${NPM_TMP}/frontend/pnpm-workspace.yaml" << 'YAML_FE'
# pnpm v11+: allowBuilds (map of package -> bool)
allowBuilds:
  "@parcel/watcher": true
  esbuild: true
  "@swc/core": true
  unrs-resolver: true
  "@biomejs/biome": true
  sass: true

# pnpm v10 compatibility: ignored by v11
onlyBuiltDependencies:
  - "@parcel/watcher"
  - esbuild
  - "@swc/core"
  - unrs-resolver
  - "@biomejs/biome"
  - sass
YAML_FE
info "wrote frontend/pnpm-workspace.yaml (allowBuilds for pnpm v11+, onlyBuiltDependencies for v10)"

# ---------------------------------------------------------------------------
# Clean pnpm store before install
#
# Root cause of vite build hang on re-runs: pnpm uses a global
# content-addressable store (~/.local/share/pnpm/store) that persists across
# installer runs. A previous aborted install can leave partial or corrupted
# package entries in the store. When the new node_modules hard-links to those
# entries, vite hangs mid-transform reading an incomplete module file.
#
# Fix: prune orphaned packages from the store, then verify store integrity.
# This is a no-op on a clean machine (nothing to prune), and automatically
# detects and re-fetches any corrupted entries on a re-run machine.
# ---------------------------------------------------------------------------
info "Pruning pnpm store (removes orphaned packages from previous runs)..."
pnpm store prune --force 2>/dev/null || true
# pnpm store has no `verify` subcommand (only add/path/prune/status). The
# `prune --force` above already removed orphaned and alien entries — that's
# all the integrity protection pnpm itself offers. Previous revision called
# `pnpm store verify`, which always exited non-zero and triggered a misleading
# warning. Reported in #5.
info "pnpm store: pruned"

# v1.1.13: pnpm fetch resilience.
# registry.npmjs.org occasionally serves metadata requests that take longer
# than pnpm's default 60s fetch-timeout (real reports of 75s+). The default
# 2 retries are also light. Bump both via npm_config_* env so they apply to
# every pnpm call below. Operators can override by exporting the same names
# before running the installer.
export npm_config_fetch_timeout="${npm_config_fetch_timeout:-300000}"
export npm_config_fetch_retries="${npm_config_fetch_retries:-5}"
export npm_config_fetch_retry_mintimeout="${npm_config_fetch_retry_mintimeout:-30000}"
export npm_config_fetch_retry_maxtimeout="${npm_config_fetch_retry_maxtimeout:-180000}"
export npm_config_network_concurrency="${npm_config_network_concurrency:-4}"
info "pnpm fetch tunables: timeout=$((npm_config_fetch_timeout/1000))s retries=${npm_config_fetch_retries} concurrency=${npm_config_network_concurrency}"

info "Installing frontend dependencies..."
# --reporter=silent suppresses deprecation WARNs from upstream package.json pins
# (e.g. react-intl@8.x deprecated by upstream). These are informational only
# and don't affect functionality. In verbose mode, full output is shown.
# v1.1.13: wrapped with retry helper to survive transient registry blips.
if ${VERBOSE}; then
    _pnpm_install_with_retry pnpm install
else
    _pnpm_install_with_retry pnpm install --reporter=silent
fi

info "Upgrading frontend dependencies to latest compatible versions..."
if ${VERBOSE}; then
    _pnpm_install_with_retry pnpm upgrade
else
    _pnpm_install_with_retry pnpm upgrade --reporter=silent
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
    python3 "${_VITE_PATCH}" "${_VITE_CFG}" \
        && info "vite.config.ts: manualChunks applied (vendor chunk splitting)" \
        || warn "vite.config.ts patch failed ${G_DASH} build continues without chunk split"
fi

# ── Patch tsconfig.json: exclude test files from production build ─────────────
# Root cause: 'tsc && vite build' compiles ALL .tsx files including *.test.*
# files. Utils.test.tsx uses Node.js globals (global, process) not typed in
# the browser tsconfig, causing TS2304/TS2580 errors that abort the build.
# Two-stage fix:
#   1. Parse tsconfig.json as JSONC (strips // comments AND trailing commas
#      which json.loads rejects) then inject exclude patterns.
#   2. Fallback: if parsing fails, delete the test files from the build tree
#      directly — they have no role in a production build.
# NOTE: written to a temp file so the heredoc sits at column 0.
cat > "${_TSCONFIG_PATCH}" << 'TSCONFIG_PATCH_EOF'
import sys, json, re, os, glob

path = sys.argv[1]
with open(path) as f:
    raw = f.read()

def parse_jsonc(text):
    # Strip // line comments (safe: cannot appear inside string values)
    text = re.sub(r'//[^\n]*', '', text)
    # Remove trailing commas before ] or } (JSONC feature json.loads rejects)
    # NOTE: no /* */ block comment stripping — the regex would corrupt
    # glob patterns like **/*.test.ts (misidentified as block comments)
    text = re.sub(r',(\s*[}\]])', r'\1', text)
    return json.loads(text)

patched = False
try:
    cfg = parse_jsonc(raw)
    exclude = cfg.setdefault('exclude', [])
    to_add = ['**/*.test.ts', '**/*.test.tsx', '**/*.spec.ts', '**/*.spec.tsx']
    added = [e for e in to_add if e not in exclude]
    for e in added:
        exclude.append(e)
    if added:
        with open(path, 'w') as f:
            json.dump(cfg, f, indent=2)
        print('  tsconfig.json patched: excluded ' + ', '.join(added))
    else:
        print('  tsconfig.json: test files already excluded')
    patched = True
except Exception as exc:
    print('  tsconfig.json: parse failed ({}) -- using file-deletion fallback'.format(exc))

if not patched:
    src_dir = os.path.dirname(path)
    deleted = []
    for pat in ['**/*.test.ts', '**/*.test.tsx', '**/*.spec.ts', '**/*.spec.tsx']:
        for fp in glob.glob(os.path.join(src_dir, 'src', pat), recursive=True):
            os.remove(fp)
            deleted.append(os.path.basename(fp))
    if deleted:
        print('  fallback: deleted test files: ' + ', '.join(deleted))
    else:
        print('  fallback: no test files found to delete')
    sys.exit(0)
TSCONFIG_PATCH_EOF

_TSCONFIG="${NPM_TMP}/frontend/tsconfig.json"
if [[ -f "${_TSCONFIG}" ]]; then
    python3 "${_TSCONFIG_PATCH}" "${_TSCONFIG}" \
        && info "tsconfig.json: test files excluded from production build" \
        || warn "tsconfig.json patch failed"
fi
info "Running production build..."
echo ""
echo -e "  ${YELLOW}${BOLD}Building frontend ${G_DASH} this may take 3-5 minutes.${NC}"
echo -e "  ${DIM}Vite transforms ~7000 modules. Please be patient.${NC}"
echo ""

# Vite can hang mid-transform if pnpm store entries are still corrupted.
# Wrap with timeout (10 min): if it hangs, prune the store completely and retry.

# _build_with_progress: run pnpm build in background, show a live spinner
# with elapsed time and the latest transforming count from the build log.
# On failure, dump the last 20 lines of the log so the user sees the error.
_build_with_progress() {
    : > "${_BUILD_LOG}"  # truncate log
    timeout 600 bash -c 'export NODE_OPTIONS="--max-old-space-size=2048"; pnpm run build' > "${_BUILD_LOG}" 2>&1 &
    local _pid=$!
    local _spin="${G_SPIN_CHARS}"
    local _start=${SECONDS}
    local _i=0 _status=0 _elapsed _last_line

    while kill -0 "${_pid}" 2>/dev/null; do
        _elapsed=$(( SECONDS - _start ))
        _last_line=$(grep -oP 'transforming \(\d+\)|built in|error' "${_BUILD_LOG}" 2>/dev/null | tail -1 || true)
        [[ -z "${_last_line}" ]] && _last_line="starting..."
        printf "\r  ${CYAN}%s${NC}  %dm%02ds  %s     " \
            "${_spin:_i++%${#_spin}:1}" \
            $(( _elapsed / 60 )) $(( _elapsed % 60 )) \
            "${_last_line}"
        sleep 0.3
    done
    wait "${_pid}" 2>/dev/null || _status=$?
    printf "\r%80s\r" ""   # clear the spinner line

    if [[ ${_status} -ne 0 ]]; then
        echo ""
        warn "Build failed (exit code ${_status}). Last 20 lines of build output:"
        echo -e "${DIM}"
        tail -20 "${_BUILD_LOG}" 2>/dev/null || true
        echo -e "${NC}"
    fi
    return ${_status}
}

_build_ok=false
for _attempt in 1 2; do
    if ${VERBOSE}; then
        NODE_OPTIONS="--max-old-space-size=2048" timeout 600 pnpm run build && _build_ok=true && break
    else
        _build_with_progress && { _build_ok=true; break; }
    fi
    if [[ ${_attempt} -eq 1 ]]; then
        warn "Build timed out or failed (attempt 1) ${G_DASH} clearing pnpm store and retrying..."
        pnpm store prune --force 2>/dev/null || true
        # Force re-download of all packages to ensure a clean store state.
        # v1.1.13: wrapped with retry helper; failure here is non-fatal so
        # the outer build retry still gets a chance.
        _pnpm_install_with_retry pnpm install --force --reporter=silent || true
    fi
done
${_build_ok} || die "Frontend build failed after retry. Run with --verbose for details."
unset _build_ok _attempt

log "Frontend build complete."

# ---------------------------------------------------------------------------
}  # end _step4_build_frontend
_step4_build_frontend

# >>> SECTION: _step5_install_backend >>>
_step5_install_backend() {
# Install backend node_modules (production only)
# ---------------------------------------------------------------------------
step "Step 5/7 ${G_ARROW} 6/7 ${G_DASH} Assembling install directory"

# ---------------------------------------------------------------------------
# Assemble install dir FIRST, then install backend deps in-place
# ---------------------------------------------------------------------------
# WHY: pnpm uses hard-links to a global content-addressable store plus
# symlinks within node_modules/. Installing in the temp dir then copying
# can leave symlinks dangling and native binaries (sqlite3.node) unresolvable.
# Install directly in the final location to guarantee correct resolution.

step "Step 6/7 ${G_DASH} Installing backend dependencies and configuring"

# v1.1.9 (#2): stop the service NOW, just before the install swap. In
# --update mode the service has been serving traffic through the entire
# frontend build above; this is the start of the unavoidable downtime
# window. Fresh installs are a no-op here (nothing to stop).
if [[ "${INSTALL_MODE}" == "update" ]] && systemctl is-active --quiet "${NPM_SERVICE}" 2>/dev/null; then
    info "Stopping ${NPM_SERVICE} for the install swap..."
    systemctl stop "${NPM_SERVICE}" 2>/dev/null || true
fi

# Backup existing install if present
if [[ -d "${NPM_HOME}" ]]; then
    BACKUP="${NPM_HOME}.bak-$(date +%Y%m%d%H%M%S)"
    warn "Existing install found ${G_DASH} backing up to ${BACKUP}"
    mv "${NPM_HOME}" "${BACKUP}"
fi

mkdir -p "${NPM_HOME}"

# Copy backend SOURCE files only — exclude node_modules (installing fresh below)
info "Copying backend source files..."
if command -v rsync &>/dev/null; then
    vrun rsync -a --exclude='node_modules' --exclude='pnpm-lock.yaml' "${NPM_TMP}/backend/" "${NPM_HOME}/backend/"
else
    mkdir -p "${NPM_HOME}/backend"
    ( cd "${NPM_TMP}/backend" && find . -mindepth 1 -maxdepth 1 \
        ! -name 'node_modules' ! -name 'pnpm-lock.yaml' \
        -exec cp -a {} "${NPM_HOME}/backend/" \; )
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
_BEFORE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "${_PKGJSON}" 2>/dev/null || echo "?")
jq --arg v "${NPM_VERSION}" '.version = $v' "${_PKGJSON}" > "${_PKGJSON}.tmp" \
    && mv "${_PKGJSON}.tmp" "${_PKGJSON}"
_AFTER=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "${_PKGJSON}" 2>/dev/null || echo "error")
if [[ "${_AFTER}" == "${NPM_VERSION}" ]]; then
    info "Version patched: ${_BEFORE} ${G_ARROW} v${_AFTER}"
else
    warn "Version patch failed ${G_DASH} footer may show wrong version (got ${_AFTER})"
fi

# ---------------------------------------------------------------------------
# Patch _listen.conf template for nginx < 1.25.1 (issue #3)
# ---------------------------------------------------------------------------
# nginx < 1.25.1 does not support the `http2 on;` / `http2 off;` directives
# introduced in 2023. Debian 12 (bookworm) ships nginx 1.22.1. NPM's
# _listen.conf template emits the new directive unconditionally, which
# causes every proxy host config to fail `nginx -t` — NPM then silently
# rolls back the config and ports 80/443 never listen.
#
# Strategy: detect nginx < 1.25.1 and strip the http2 Jinja block from the
# template. Proxy hosts then validate; HTTP/2 just won't be enabled (users
# on bookworm who need HTTP/2 should install nginx from nginx.org or from
# bookworm-backports). No-op on nginx 1.25+, idempotent on re-runs.
_NGINX_VER=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
if [[ -n "${_NGINX_VER}" ]] && dpkg --compare-versions "${_NGINX_VER}" lt 1.25.1; then
    _LISTEN_TPL="${NPM_HOME}/backend/templates/_listen.conf"
    if [[ -f "${_LISTEN_TPL}" ]] && grep -q 'http2 on' "${_LISTEN_TPL}"; then
        python3 - "${_LISTEN_TPL}" << 'PYHTTP2'
import re, sys
p = sys.argv[1]
src = open(p).read()
# Match the full {% if http2_support ... %}http2 on;{% else %}http2 off;{% endif %} block,
# tolerating whitespace and indent variations between releases.
pat = re.compile(
    r'\{%\s*if\s+http2_support[^%]*%\}\s*\n?\s*http2\s+on;\s*\n?\s*'
    r'\{%\s*else[^%]*%\}\s*\n?\s*http2\s+off;\s*\n?\s*\{%\s*endif\s*%\}\n?',
    re.MULTILINE
)
new = pat.sub('', src)
if new != src:
    open(p, 'w').write(new)
    print('  _listen.conf: http2 on/off block removed')
else:
    print('  _listen.conf: http2 block not found (template may already be patched)')
PYHTTP2
        log "Patched NPM's _listen.conf for nginx ${_NGINX_VER} (< 1.25.1)"
    fi

    # v1.1.9 (#1): strip stale `http2 on;` / `http2 off;` lines from any
    # proxy host configs that NPM previously generated. Without this an
    # --update from Docker or a system that briefly had nginx 1.25+
    # leaves /data/nginx/proxy_host/*.conf with directives nginx 1.22.1
    # rejects, and the service refuses to start. Anchored regex: only
    # whole-line bare `http2 on;` / `http2 off;` directives are stripped —
    # legacy `listen 443 ssl http2;` syntax is preserved.
    if [[ -d "${NPM_DATA}/nginx" ]]; then
        _STALE_COUNT=$(grep -rlE '^[[:space:]]*http2[[:space:]]+(on|off);[[:space:]]*$' \
            "${NPM_DATA}/nginx" 2>/dev/null | wc -l)
        if [[ "${_STALE_COUNT}" -gt 0 ]]; then
            warn "Stripping bare http2 directives from ${_STALE_COUNT} existing ${NPM_DATA}/nginx/**/*.conf file(s)"
            find "${NPM_DATA}/nginx" -name '*.conf' -exec \
                sed -i '/^[[:space:]]*http2[[:space:]]\+o\(n\|ff\);[[:space:]]*$/d' {} +
            log "Cleaned ${_STALE_COUNT} stale config(s); proxy hosts will validate after nginx restart"
        fi
    fi
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

# v1.1.15: jq now only patches non-pnpm-config keys. pnpm.* moved to
# pnpm-workspace.yaml because pnpm v11 ignores the package.json pnpm field.
#
# Direct dependency pins kept here (real package.json dependencies, not pnpm config):
#   sqlite3   ^5.x -> ^6.0.0 (v6 drops tar@^6, picks up tar@^7)
#   knex      3.1.x -> ^3.2.0 (latest bugfix release)
#
# Override pins for deprecated transitive deps live in pnpm-workspace.yaml below:
#   glob/rimraf/tar/uuid (fixable);  prebuild-install/inflight/npmlog (unfixable)
jq '.dependencies.sqlite3 = "^6.0.0" |
    .dependencies.knex    = "^3.2.0"' \
    "${PKGJSON}" > "${PKGJSON}.tmp" && mv "${PKGJSON}.tmp" "${PKGJSON}"
info "Backend dependencies pinned: sqlite3 ^6.0.0, knex ^3.2.0 (overrides moved to pnpm-workspace.yaml)"

# v1.1.14: pnpm v11 ignores .pnpm.onlyBuiltDependencies in package.json.
# Write the allow-list in pnpm-workspace.yaml as `allowBuilds` (v11 schema)
# AND `onlyBuiltDependencies` (v10 schema). Whichever pnpm version is in
# use picks up its respective key.
cat > "${NPM_HOME}/backend/pnpm-workspace.yaml" << 'YAML_BE'
# pnpm v11+: allowBuilds (map of package -> bool)
allowBuilds:
  bcrypt: true
  sqlite3: true
  better-sqlite3: true
  "@mapbox/node-pre-gyp": true
  node-pre-gyp: true
  node-gyp: true
  "@parcel/watcher": true
  esbuild: true

# pnpm v10 compatibility: ignored by v11
onlyBuiltDependencies:
  - bcrypt
  - sqlite3
  - better-sqlite3
  - "@mapbox/node-pre-gyp"
  - node-pre-gyp
  - node-gyp
  - "@parcel/watcher"
  - esbuild

# v1.1.15: overrides moved from package.json (pnpm v11 ignored the .pnpm field).
# Pins deprecated transitive deps to maintained versions:
#   glob v7/v10  -> v11 (security-deprecated by upstream maintainer)
#   rimraf v3/v4 -> v6  (deprecated)
#   tar v6       -> v7  (deprecated; sqlite3@6 drops the chain naturally)
#   uuid v3/v8   -> v10 (deprecated)
overrides:
  glob: ^11.0.0
  rimraf: ^6.0.0
  tar: ^7.0.0
  uuid: ^10.0.0

# v1.1.16: suppress noise for transitively-pulled deprecated packages with
# no working replacement (they are deep inside the bcrypt / sqlite3 /
# node-pre-gyp native build chain). New deprecations NOT listed here will
# still surface as warnings, which is the right default.
allowedDeprecatedVersions:
  prebuild-install: "*"
  querystring: "*"
  inflight: "*"
  npmlog: "*"
  are-we-there-yet: "*"
  gauge: "*"
  "@npmcli/move-file": "*"
YAML_BE
info "wrote backend/pnpm-workspace.yaml (allowBuilds for pnpm v11+, onlyBuiltDependencies for v10)"

# v1.1.13: backend install wrapped with retry; same fetch tunables apply
# (env vars are inherited from the frontend step's exports above).
if ${VERBOSE}; then
    _pnpm_install_with_retry pnpm install --prod
else
    _pnpm_install_with_retry pnpm install --prod --reporter=silent
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

# Test each module by requiring it with Node.js from the install directory.
# Previous revision OR'd three strategies; the ESM + --require fallbacks were
# dead code (path was a bogus `node_modules/.bin/../..` which Node rejects).
# Only the cd-into-backend require() ever succeeded, so use it directly.
_test_module() {
    local label="$1"
    local require_expr="$2"
    if ( cd "${NPM_HOME}/backend" && node -e "require('${require_expr}')" &>/dev/null ); then
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
[[ -f "${NPM_HOME}/frontend/index.html" ]]     && log "frontend/index.html : present"     || die "frontend/index.html missing after copy ${G_DASH} frontend will not load"

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
}  # end _step5_install_backend
_step5_install_backend

# >>> SECTION: _step6_seed_data >>>
_step6_seed_data() {
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
}  # end _step6_seed_data
_step6_seed_data

# >>> SECTION: _step6_seed_data_continued_db >>>
_step6_seed_data_continued_db() {
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
}  # end _step6_seed_data_continued_db
_step6_seed_data_continued_db

# >>> SECTION: _step6b_configure_nginx >>>
_step6b_configure_nginx() {
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
# v1.1.20: persistent temp path (was /tmp/nginx/body -- wiped on reboot,
# breaking nginx -t and every NPM "save proxy host" call afterwards).
mkdir -p /var/lib/nginx/body
chown www-data:www-data /var/lib/nginx/body 2>/dev/null || true
mkdir -p /data/logs
mkdir -p /data/letsencrypt-acme-challenge/.well-known/acme-challenge
mkdir -p /tmp/letsencrypt-lib
# Default site directories — REQUIRED for Settings > Default Site to work:
# /data/nginx/default_host/ → generateConfig('default') writes here
# /data/nginx/default_www/  → Custom HTML saves index.html here
# Missing either directory causes: empty 200 responses or Node.js crash (502)
mkdir -p /data/nginx/default_host
mkdir -p /data/nginx/default_www
# /data/access/ — htpasswd files written by access-list build();
# missing directory causes 500 Internal Error on every access list save
mkdir -p /data/access
# /data/custom_ssl/ — parent dir for custom SSL cert uploads (npm-<id>/ created on demand);
# writeCustomCert() uses mkdirSync WITHOUT {recursive:true} so parent MUST pre-exist
mkdir -p /data/custom_ssl
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

    client_body_temp_path /var/lib/nginx/body 1 2;
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

    access_log __NPM_DATA__/logs/fallback_access.log standard;
    error_log  __NPM_DATA__/logs/fallback_error.log  warn;

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
    include /etc/nginx/conf.d/include/ip_ranges[.]conf;
    real_ip_header    X-Real-IP;
    real_ip_recursive on;

    # ── Resolvers ─────────────────────────────────────────────────────────────
    include /etc/nginx/conf.d/include/resolvers.conf;

    # ── NPM runtime proxy configs ──────────────────────────────────────────────
    include __NPM_DATA__/nginx/default_host/*.conf;
    include __NPM_DATA__/nginx/proxy_host/*.conf;
    include __NPM_DATA__/nginx/redirection_host/*.conf;
    include __NPM_DATA__/nginx/dead_host/*.conf;
    include __NPM_DATA__/nginx/temp/*.conf;

    # ── Custom snippets ────────────────────────────────────────────────────────
    include __NPM_DATA__/nginx/custom/http_top[.]conf;
    include __NPM_DATA__/nginx/custom/http[.]conf;

    # ── Admin UI — port 81 ────────────────────────────────────────────────────
    # NPM 2.13.x ARCHITECTURE:
    #   - Node.js backend: pure API on port 3000 (NO express.static)
    #   - React frontend: static files served by nginx from __NPM_HOME__/frontend/
    #   - nginx port 81: serves static files + proxies /api/* to port 3000
    #
    # The backend has no static file serving — nginx owns the entire admin UI.
    server {
        listen 81;
        listen [::]:81;
        server_name _;
        access_log __NPM_DATA__/logs/fallback_access.log standard;
        error_log  __NPM_DATA__/logs/fallback_error.log  warn;

        # Serve the React SPA static files directly
        root __NPM_HOME__/frontend;
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
    include __NPM_DATA__/nginx/stream/*.conf;
}
NGINX_CONF

# Replace placeholders with actual paths (keeps heredoc single-quoted to avoid
# escaping dozens of nginx $ variables)
sed -i "s|__NPM_HOME__|${NPM_HOME}|g; s|__NPM_DATA__|${NPM_DATA}|g" /etc/nginx/nginx.conf

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
    warn "docker/rootfs/etc/nginx/conf.d/include not found ${G_DASH} proxy host configs may fail"
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
nginx -t &>/dev/null || die "nginx config test failed ${G_DASH} run: nginx -t for details."

# Enable nginx to start on boot and verify the symlink was created
systemctl enable nginx 2>/dev/null || true
systemctl is-enabled nginx &>/dev/null || warn "nginx may not be enabled for autostart ${G_DASH} run: systemctl enable nginx"
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
    die "nginx failed to start ${G_DASH} run: systemctl status nginx  or: journalctl -u nginx -n 30"
fi

# ---------------------------------------------------------------------------
}  # end _step6b_configure_nginx
_step6b_configure_nginx

# >>> SECTION: _step6c_logrotate >>>
_step6c_logrotate() {
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
}  # end _step6c_logrotate
_step6c_logrotate

# >>> SECTION: _step7_systemd_service >>>
_step7_systemd_service() {
# Create systemd service
# ---------------------------------------------------------------------------
step "Step 7/7 ${G_DASH} Creating systemd service and starting NPM"

# v1.1.10 (#5): back up + warn before replacing the main unit. Drop-ins
# under ${NPM_SERVICE}.service.d/ (added via `systemctl edit`) are
# preserved across the rewrite; lines added directly to the main unit
# (Environment=DEBUG=..., custom ExecStart args) are lost.
if [[ "${INSTALL_MODE}" == "update" ]] && [[ -f "/etc/systemd/system/${NPM_SERVICE}.service" ]]; then
    UNIT_BACKUP="/etc/systemd/system/${NPM_SERVICE}.service.bak-$(date +%Y%m%d%H%M%S)"
    if cp "/etc/systemd/system/${NPM_SERVICE}.service" "${UNIT_BACKUP}" 2>/dev/null; then
        warn "Existing systemd unit backed up to ${UNIT_BACKUP}"
    fi
    warn "Replacing main systemd unit. Drop-ins under ${NPM_SERVICE}.service.d/ are preserved; Environment= / ExecStart= lines added directly to the main unit will be lost."
fi

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
# v1.1.20: /tmp/nginx/body removed from ExecStartPre -- client_body_temp_path
# now lives at /var/lib/nginx/body (persistent), created once at install.
ExecStartPre=-/bin/mkdir -p /tmp/letsencrypt-lib /data/letsencrypt-acme-challenge/.well-known/acme-challenge /data/nginx/default_host /data/nginx/default_www /data/access /data/custom_ssl
# Ensure nginx is running when we start — on reboot nginx may start slightly later
ExecStartPre=-/bin/systemctl start nginx
ExecStart=/usr/bin/node index.js --abort_on_uncaught_exception --max_old_space_size=250
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=npm
# Runs as root: required for certbot privileged operations, nginx reload,
# and binding to ports 80/443. NoNewPrivileges prevents child processes
# from gaining additional privileges via setuid/setgid binaries.
User=root
Group=root
NoNewPrivileges=yes

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
    warn "Service ${NPM_SERVICE} may not be enabled ${G_DASH} run: systemctl enable ${NPM_SERVICE}"
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
}  # end _step7_systemd_service
_step7_systemd_service

# >>> SECTION: _step7b_wait_for_service >>>
_step7b_wait_for_service() {
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
    # v1.1.9 (#6): beyond connectivity — verify the API actually reports OK.
    # Express binds the port the moment Node starts, BEFORE knex migrations
    # finish (or fail). Without this check, a migration failure looks like
    # a successful start. Up to 3 attempts, 2s apart, total <=6s extra.
    _API_HEALTH="?"
    for _attempt in 1 2 3; do
        _API_HEALTH=$(curl -sf --max-time 5 "http://127.0.0.1:${ADMIN_PORT}/api/" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")
        [[ "${_API_HEALTH}" == "OK" ]] && break
        sleep 2
    done
    if [[ "${_API_HEALTH}" == "OK" ]]; then
        log "NPM is up and responding (API health: OK)."
    else
        warn "Service responding on port ${ADMIN_PORT}, but /api/ returned '${_API_HEALTH}' instead of OK."
        warn "Likely cause: knex migration failure. Check: journalctl -u ${NPM_SERVICE} -n 40 --no-pager"
        # v1.1.16: surface the unhealthy API to _finalize so it can print
        # a yellow "completed with warnings" banner instead of green
        # "Installation Complete".
        _INSTALL_HEALTH="api_unhealthy"
    fi
fi

# ---------------------------------------------------------------------------
}  # end _step7b_wait_for_service
_step7b_wait_for_service

# >>> SECTION: _finalize >>>
_finalize() {
# Cleanup build artifacts
# ---------------------------------------------------------------------------
vrun rm -rf "${NPM_TMP}"

# v1.1.19: if we created a swap file at preflight, ask whether to keep,
# persist via /etc/fstab, or remove. Default (pressing Enter or non-tty) =
# keep it active for this boot only.
if [[ -n "${_CREATED_SWAP:-}" ]]; then
    echo ""
    info "Swap file ${_CREATED_SWAP} (${_CREATED_SWAP_SIZE} MB) was created for this install."
    if [[ -t 0 ]]; then
        echo "  Options:"
        echo "    1) Keep permanently (add to /etc/fstab so it survives reboots)"
        echo "    2) Remove now (swapoff + rm)"
        echo "    k) Keep for this boot only (default)"
        echo ""
        read -rp "  Choice [1/2/k]: " _SWAP_CHOICE || true
        case "${_SWAP_CHOICE}" in
            1)
                if grep -qE "^${_CREATED_SWAP}[[:space:]]" /etc/fstab 2>/dev/null; then
                    info "${_CREATED_SWAP} already listed in /etc/fstab"
                else
                    echo "${_CREATED_SWAP} none swap sw 0 0" >> /etc/fstab
                    log "Appended to /etc/fstab ${G_DASH} swap will persist across reboots"
                fi ;;
            2)
                swapoff "${_CREATED_SWAP}" 2>/dev/null && rm -f "${_CREATED_SWAP}" \
                    && log "Swap removed (${_CREATED_SWAP_SIZE} MB freed)"
                ;;
            *)
                info "Swap stays active until next reboot. To remove later:"
                info "  sudo swapoff ${_CREATED_SWAP} && sudo rm ${_CREATED_SWAP}"
                ;;
        esac
    else
        info "Non-interactive mode: swap remains active. Add to /etc/fstab for persistence."
    fi
fi

# v1.1.10 (#7): prune old ${NPM_HOME}.bak-* directories after a successful
# install. Each backup carries node_modules (~400 MB), so unbounded
# accumulation eats /opt. Keeps NPM_KEEP_BACKUPS most recent (default 2).
# Set NPM_KEEP_BACKUPS=0 to wipe all, NPM_KEEP_BACKUPS=999 to keep
# essentially everything.
_KEEP=${NPM_KEEP_BACKUPS:-2}
if [[ "${_KEEP}" =~ ^[0-9]+$ ]]; then
    _STALE=$(ls -1dt "${NPM_HOME}".bak-* 2>/dev/null | tail -n +$(( _KEEP + 1 )))
    if [[ -n "${_STALE}" ]]; then
        _N=$(echo "${_STALE}" | wc -l)
        info "Pruning ${_N} old install backup(s), keeping ${_KEEP} most recent (override via NPM_KEEP_BACKUPS=N)"
        echo "${_STALE}" | xargs -r rm -rf
    fi
fi

# ---------------------------------------------------------------------------
# Final status + summary
# ---------------------------------------------------------------------------
HOST_IP=$(hostname -I | awk '{print $1}')

echo ""
# v1.1.16: banner colour reflects API health detected in _step7b. Green for
# a clean install, yellow if /api/ didn'''t return {status:OK} after start.
_BAR="${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}${G_HBAR2}"
if [[ "${_INSTALL_HEALTH:-ok}" == "ok" ]]; then
    echo -e "${BOLD}${GREEN}${G_TL2}${_BAR}${G_TR2}${NC}"
    echo -e "${BOLD}${GREEN}${G_VBAR2}      Nginx Proxy Manager ${G_DASH} Installation Complete         ${G_VBAR2}${NC}"
    echo -e "${BOLD}${GREEN}${G_BL2}${_BAR}${G_BR2}${NC}"
else
    echo -e "${BOLD}${YELLOW}${G_TL2}${_BAR}${G_TR2}${NC}"
    echo -e "${BOLD}${YELLOW}${G_VBAR2}  Nginx Proxy Manager ${G_DASH} Install completed with warnings  ${G_VBAR2}${NC}"
    echo -e "${BOLD}${YELLOW}${G_BL2}${_BAR}${G_BR2}${NC}"
fi
echo ""
echo -e "  ${CYAN}Admin Panel :${NC} ${BOLD}http://${HOST_IP}:${ADMIN_PORT}${NC}"
echo -e "  ${CYAN}Version     :${NC} v${NPM_VERSION}"
echo -e "  ${CYAN}Service     :${NC} ${NPM_SERVICE}"
echo ""
if [[ "${_INSTALL_HEALTH:-ok}" != "ok" ]]; then
    echo -e "  ${YELLOW}API health   :${NC} ${_INSTALL_HEALTH} ${G_DASH} the service started but /api/ is not returning OK."
    echo -e "  ${DIM}Investigate with:${NC}"
    echo -e "    ${DIM}sudo journalctl -u ${NPM_SERVICE} -n 40 --no-pager${NC}"
    echo -e "    ${DIM}sudo bash $0 --verify${NC}"
    echo ""
fi
echo -e "  ${YELLOW}${G_ARROW_HEAVY}  Open the admin panel to create your account.${NC}"
echo ""
# Safety net: close both stdout and stderr after all output is done.
# Any residual journal stream that systemd registered against this TTY will
# receive EBADF on its next write() and terminate.
exec >/dev/null 2>&1
}  # end _finalize
_finalize

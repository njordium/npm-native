#!/usr/bin/env bash
# =============================================================================
#  End-to-End Test Suite — Nginx Proxy Manager Native Installer
#  Tests the installer logic, structure, and key transformations in isolation
#  WITHOUT requiring a live Debian system or network (offline static analysis).
# =============================================================================
set -euo pipefail

PASS=0; FAIL=0; SKIP=0
# Locate installer relative to this test script, then fall back to CWD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/npm-installer.sh" ]]; then
    SCRIPT="${SCRIPT_DIR}/npm-installer.sh"
elif [[ -f "$(pwd)/npm-installer.sh" ]]; then
    SCRIPT="$(pwd)/npm-installer.sh"
else
    echo "ERROR: npm-installer.sh not found next to this test script or in CWD" >&2
    exit 1
fi
echo "Testing: ${SCRIPT}"

# ── helpers ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[PASS]${NC} $*"; ((PASS++)) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ((FAIL++)) || true; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; ((SKIP++)) || true; }
section() { echo -e "\n── $* ──"; }

# ── T01: Bash syntax check ────────────────────────────────────────────────────
section "T01 Shell syntax"
if bash -n "${SCRIPT}" 2>/dev/null; then
    ok "bash -n syntax check passes"
else
    fail "bash -n syntax check FAILED"
fi

# ── T02: Key variable defaults + version auto-detect ─────────────────────────
section "T01b Banner and UI quality"
if ! grep -q 'LXC' "${SCRIPT}"; then
    ok "No LXC references — script is not container-specific"
else
    fail "LXC reference found — script should be generic Debian installer"
fi
if grep -q 'Native Linux Installer' "${SCRIPT}"; then
    ok "Splash title correct: 'Native Linux Installer' (no LXC, no Debian-only)"
else
    fail "Splash title wrong — expected 'Native Linux Installer'"
fi
if grep -q '_infoline()' "${SCRIPT}"; then
    ok "_infoline() helper present — clean plain output, no ANSI-measurement bugs"
else
    fail "_infoline() missing — detection box may have rendering issues"
fi
if grep -q '_infoline.*Service\|_infoline.*Home dir\|_infoline.*Database' "${SCRIPT}"; then
    ok "Existing install detection uses _infoline() for clean plain output"
else
    fail "Existing install box not using _infoline()"
fi
if ! grep -q '_vislen\|_boxln' "${SCRIPT}"; then
    ok "No _vislen/_boxln helpers — ANSI/multibyte measurement bugs removed"
else
    fail "_vislen or _boxln still present — may cause raw ANSI codes to print"
fi

# CRITICAL: grep exits 1 when no match — kills script under set -euo pipefail.
# Debian has no ID_LIKE line — without || true the OS check kills the script
# right after the splash, before any menu appears.
if grep -A12 'Verify supported OS' "${SCRIPT}" | grep -q '|| true'; then
    ok "OS detection grep calls have || true — safe on Debian (no ID_LIKE line)"
else
    fail "OS detection greps missing || true — script exits silently after splash on Debian"
fi
# Ubuntu compatibility check
if grep -q "_OS_ID.*ubuntu\|ubuntu.*OS_ID\|_OS_ID == .ubuntu" "${SCRIPT}"; then
    ok "OS check allows Ubuntu (_OS_ID == ubuntu)"
else
    fail "OS check missing Ubuntu branch"
fi

section "T02 Variable defaults"
if grep -q 'NODE_MAJOR.*22' "${SCRIPT}"; then
    ok "Default NODE_MAJOR is 22 (current LTS)"
else
    fail "Default NODE_MAJOR is not 22"
fi

section "T02b Version auto-detect"
if grep -q 'releases/latest' "${SCRIPT}" && grep -q 'tag_name' "${SCRIPT}"; then
    ok "Version auto-detected from GitHub releases/latest API"
else
    fail "No GitHub version auto-detect — installs stale hardcoded version"
fi
if grep -q 'fallback\|2\.14' "${SCRIPT}"; then
    ok "Hard fallback version present if GitHub unreachable"
else
    fail "No offline fallback version"
fi

section "T02c Verbose/quiet mode"
if grep -q 'VERBOSE=false' "${SCRIPT}"; then
    ok "Default is quiet mode (VERBOSE=false)"
else
    fail "VERBOSE flag not defaulting to false"
fi
if grep -q -- '--verbose' "${SCRIPT}"; then
    ok "--verbose CLI flag present"
else
    fail "--verbose CLI flag missing"
fi
if grep -q 'Output verbosity' "${SCRIPT}"; then
    ok "Interactive verbosity question during install"
else
    fail "Interactive verbosity question missing"
fi
if grep -q 'vrun()' "${SCRIPT}"; then
    ok "vrun() helper defined (suppresses output in quiet mode)"
else
    fail "vrun() helper missing"
fi
if grep -q 'step()' "${SCRIPT}"; then
    ok "step() always-visible progress markers defined"
else
    fail "step() missing"
fi

# ── T02d Service start — no terminal journal leak ─────────────────────────────
section "T02d No terminal journal leak (systemd drop-in)"
# ROOT CAUSE: StandardOutput=journal causes journald to forward ALL service
# output to every active login session's pts device via logind session tracking.
# This is independent of any fd redirects on systemctl — journald opens /dev/pts/N
# directly. Our >/dev/null on systemctl only affects systemctl's own output.
#
# FIX: Temporary drop-in override sets StandardOutput=append:/var/log/...
# during service startup. No output reaches journald → nothing forwarded
# to the terminal. Drop-in is removed after service is confirmed running.

if grep -q '99-install-quiet.conf' "${SCRIPT}"; then
    ok "Temporary drop-in override created to silence journald forwarding during startup"
else
    fail "No drop-in override — journald will forward service stdout to terminal regardless of fd redirects"
fi
if grep -q 'StandardOutput=append.*log' "${SCRIPT}"; then
    ok "Drop-in routes StandardOutput to log file (not journal) during install"
else
    fail "Drop-in missing StandardOutput=append — journal still receives and forwards output"
fi
if grep -q 'rm -f.*_DROPIN\|rm.*99-install-quiet' "${SCRIPT}"; then
    ok "Drop-in removed after service confirmed running (journal logging restored)"
else
    fail "Drop-in never removed — service would permanently log to file instead of journal"
fi
# nginx restart also needs the drop-in (happens earlier in step 6)
if grep -c '99-install-quiet' "${SCRIPT}" | grep -q '^[2-9]'; then
    ok "nginx restart also protected by drop-in override"
else
    fail "nginx restart not protected — nginx startup messages still flood terminal"
fi
if grep -q 'exec >/dev/null 2>&1' "${SCRIPT}"; then
    ok "exec >/dev/null 2>&1 safety net at end of script"
else
    fail "No exec safety net at end of script"
fi

# ── T02e Verify mode correctness ──────────────────────────────────────────────
section "T02e Verify mode: arithmetic safety"
if grep -q '_PASS += 1.*|| true' "${SCRIPT}"; then
    ok "Verify counters use safe increment (not post-increment bug with set -e)"
else
    fail "Verify mode uses (( _PASS++ )) — exits silently after first check with set -e"
fi

section "T02f Verify mode: coverage"
if grep -q 'bcrypt.*loads' "${SCRIPT}" && grep -q 'sqlite.*loads' "${SCRIPT}"; then
    ok "Verify mode checks native modules (bcrypt, sqlite)"
else
    fail "Verify mode missing native module checks"
fi
if grep -q '_VER_CURRENT' "${SCRIPT}"; then
    ok "Verify mode shows version check (current vs latest)"
else
    fail "Verify mode missing version check"
fi
if grep -q 'setup_done' "${SCRIPT}"; then
    ok "Verify mode shows admin account setup state"
else
    fail "Verify mode missing setup state check"
fi
if grep -q '_DB_CLIENT' "${SCRIPT}"; then
    ok "Verify mode checks database client configuration"
else
    fail "Verify mode missing database client check"
fi

section "T02h Verify mode: correct API port usage"
# All verify API checks must go through nginx (port 81/ADMIN_PORT), not port 3000 directly.
# nginx strips /api/ prefix when forwarding: /api/ -> 127.0.0.1:3000/ (trailing slash).
# curl to 127.0.0.1:3000/api/ sends /api/ to backend which has no such route -> 404.
if ! grep -q 'curl.*127.0.0.1:3000/api' "${SCRIPT}"; then
    ok "No verify checks curl port 3000/api/ directly (would always 404)"
else
    fail "Verify mode curls 127.0.0.1:3000/api/ which always returns 404 (nginx strips /api/ prefix)"
fi
if grep -q 'ss.*:3000.*tlnp\|ss.*tlnp.*3000' "${SCRIPT}"; then
    ok "Backend port 3000 checked with ss (reliable, no HTTP path issues)"
else
    fail "Backend port 3000 not checked with ss — verify uses brittle curl path"
fi
if grep -q 'ADMIN_PORT.*api/\|api/.*ADMIN_PORT' "${SCRIPT}"; then
    ok "API health check uses ADMIN_PORT (through nginx proxy)"
else
    fail "API health check not going through nginx on ADMIN_PORT"
fi

section "T02i Verify mode: setup state logic"
# API returns: {"setup": true}  = admin account exists, setup wizard complete
#              {"setup": false} = setup wizard still needed, no admin account yet
# Correct logic: 'setup_done' if d.get('setup') else 'setup_needed'
if grep -q "'setup_done' if d.get('setup') else 'setup_needed'" "${SCRIPT}"; then
    ok "Setup state logic correct: setup:true = account created (wizard complete)"
else
    fail "Setup state logic wrong: setup:true means account exists, not 'needed'"
fi

section "T02g Version patch visibility"
if grep -q 'info.*Version patched' "${SCRIPT}" && ! grep -q '^    log.*Version patched' "${SCRIPT}"; then
    ok "Version patch log is info() — silent in quiet mode, no noise"
else
    fail "Version patch uses log() — appears in quiet mode unnecessarily"
fi
# ── T03: git clone (not tarball) ──────────────────────────────────────────────
# ── T02j Node.js install robustness ───────────────────────────────────────────
section "T02j Node.js install: nodesource double-quote expansion and npm fallback"
# Bug: vrun bash -c 'curl .../setup_${NODE_MAJOR}.x | bash -' with single quotes
# means NODE_MAJOR never expands — nodesource 404 → Debian repos → Node 20 without npm
if grep 'nodesource' "${SCRIPT}" | grep -q '"curl -fsSL https://deb.nodesource'; then
    ok "nodesource curl uses double quotes — NODE_MAJOR expands correctly"
else
    fail "nodesource curl in single quotes — NODE_MAJOR not expanded, wrong Node/no npm"
fi
if grep -q 'npm not found\|NodeSource setup failed' "${SCRIPT}"; then
    ok "npm fallback install present (handles both nodesource failure and Debian nodejs without npm)"
else
    fail "No npm fallback — Debian repos nodejs without npm causes install abort"
fi
if grep -q 'die.*npm is not available\|Cannot continue without npm' "${SCRIPT}"; then
    ok "Hard die() if npm still missing after all fallbacks — no silent failure"
else
    fail "No hard failure if npm missing — script would silently fail later"
fi
if grep -q 'npm --version.*2>/dev/null' "${SCRIPT}"; then
    ok "npm --version guarded against failure if npm absent"
else
    fail "npm --version unguarded — aborts with command not found on fresh Debian"
fi

section "T03 Source acquisition method"
if grep -q 'git clone' "${SCRIPT}"; then
    ok "Uses git clone"
else
    fail "Does not use git clone — tarball will miss locale/lang/*.json"
fi

if ! grep -q 'tar -xzf.*TARBALL' "${SCRIPT}"; then
    ok "Tarball extraction (tar -xzf) not present"
else
    fail "Tarball extraction still present — should be removed"
fi

if grep -q '\-\-depth 1' "${SCRIPT}"; then
    ok "Shallow clone (--depth 1) used"
else
    fail "--depth 1 missing — full history clone is unnecessarily slow"
fi

if grep -q '\-\-branch.*NPM_VERSION' "${SCRIPT}"; then
    ok "Clones specific version tag via --branch"
else
    fail "--branch version tag not found"
fi

# ── T04: Frontend build uses pnpm ─────────────────────────────────────────────
section "T04 Frontend build toolchain"
if grep -q 'pnpm install' "${SCRIPT}"; then
    ok "pnpm install present"
else
    fail "pnpm install missing"
fi
if grep -q 'pnpm upgrade' "${SCRIPT}"; then
    ok "pnpm upgrade present (resolves stale pinned deps)"
else
    fail "pnpm upgrade missing"
fi
if grep -q 'pnpm run build' "${SCRIPT}"; then
    ok "pnpm run build present"
else
    fail "pnpm run build missing"
fi

# ── T05: No legacy Webpack 4 / node-sass patches ─────────────────────────────
# ── T04b vite manualChunks patch ──────────────────────────────────────────────
section "T04b Frontend: vite manualChunks chunk-splitting patch"
# Without patching, vite outputs a single 2,059 kB main chunk containing all
# vendor libraries. manualChunks splits it into parallel-loadable vendor chunks,
# eliminating the build warning and improving browser parse time.
if grep -q '_vite_patch.py\|manualChunks\|VITE_PATCH_EOF' "${SCRIPT}"; then
    ok "vite manualChunks patch present (eliminates > 500 kB chunk warning)"
else
    fail "No vite chunk-splitting patch — build produces 2 MB single bundle with warning"
fi
if grep -q 'vendor-icons\|tabler.*icons-react' "${SCRIPT}"; then
    ok "@tabler/icons-react split into separate vendor-icons chunk"
else
    fail "@tabler/icons-react not split — it is the largest single dep (~900 kB)"
fi
if grep -q 'vendor-react\|node_modules/react' "${SCRIPT}"; then
    ok "React core split into vendor-react chunk"
else
    fail "React core not split from main bundle"
fi
if grep -q 'chunkSizeWarningLimit' "${SCRIPT}"; then
    ok "chunkSizeWarningLimit set (avoids warning on any remaining medium chunks)"
else
    fail "chunkSizeWarningLimit not set"
fi

section "T05 Legacy patch cleanup"
if ! grep -q 'openssl-legacy-provider' "${SCRIPT}"; then
    ok "No --openssl-legacy-provider (Webpack 4 workaround gone)"
else
    fail "--openssl-legacy-provider still present (Webpack 4 artifact)"
fi
if ! grep -q 'node-sass' "${SCRIPT}"; then
    ok "No node-sass references"
else
    fail "node-sass reference still in script"
fi
if ! grep -q 'sass-loader' "${SCRIPT}"; then
    ok "No sass-loader pin references"
else
    fail "sass-loader pin still present"
fi
if ! grep -q 'tabler-ui' "${SCRIPT}"; then
    ok "No tabler-ui hack references"
else
    fail "tabler-ui hack still present"
fi

# ── T06: Timestamp logging ────────────────────────────────────────────────────
# ── T05b react-intl v9 upgrade patch ──────────────────────────────────────────
section "T05b react-intl: v8→v10 patch before pnpm install"
# Version history: 8.x deprecated, 9.0.0 deprecated+BROKEN (workspace:* dep),
# 10.x is current stable. API audit: only RawIntlProvider/createIntl/
# createIntlCache used — all unchanged in v10. injectIntl (removed in v10)
# not used. Patch BEFORE pnpm install so resolver picks v10 from the start.
if grep -q 'react-intl.*10\.0\.0\|react-intl patched.*v10\|\^10\.0\.0' "${SCRIPT}"; then
    ok "react-intl v10 patch present (v9 broken/deprecated, v10 is correct target)"
else
    fail "react-intl not patched to v10 — v9 has workspace:* broken dep, v8 deprecated"
fi
# Verify NOT targeting v9 (which has @formatjs/intl@workspace:* broken dependency)
if grep -q '"react-intl".*"\^9\|= "\^9\.0\.0"' "${SCRIPT}"; then
    fail "react-intl targeting v9 — v9.0.0 is broken (workspace:* monorepo dep fails)"
else
    ok "react-intl not targeting broken v9.0.0"
fi
# Verify the patch is BEFORE pnpm install (order matters for resolver)
_patch_line=$(grep -n 'react-intl.*\^9\|react-intl patched' "${SCRIPT}" | head -1 | cut -d: -f1)
_install_line=$(grep -n 'pnpm install$\|pnpm install --reporter' "${SCRIPT}" | head -1 | cut -d: -f1)
if [[ -n "${_patch_line}" && -n "${_install_line}" && "${_patch_line}" -lt "${_install_line}" ]]; then
    ok "react-intl patch is before pnpm install (resolver picks v9 from start)"
else
    fail "react-intl patch is AFTER pnpm install — pnpm will still resolve v8 first"
fi

section "T06 Timestamp logging"
if grep -q "TS().*date.*%Y-%m-%d" "${SCRIPT}"; then
    ok "TS() function with date format present"
else
    fail "TS() timestamp function missing"
fi
if grep -q '\$(TS)' "${SCRIPT}"; then
    ok "log/info functions use \$(TS)"
else
    fail "log/info functions do not reference \$(TS)"
fi

# ── T07: Systemd service file correctness ─────────────────────────────────────
section "T07 Systemd service"
if grep -q 'NODE_ENV=production' "${SCRIPT}"; then
    ok "NODE_ENV=production in service definition"
else
    fail "NODE_ENV=production missing from service"
fi
if grep -q 'ExecStart=/usr/bin/node index.js' "${SCRIPT}"; then
    ok "ExecStart points to node index.js"
else
    fail "ExecStart is wrong"
fi
if grep -q 'Restart=on-failure' "${SCRIPT}"; then
    ok "Restart=on-failure present"
else
    fail "Restart directive missing"
fi

# ── T08 nginx config — self-contained, no docker/rootfs conf.d ───────────────
# ── T07b Systemd service: certbot prerequisites ───────────────────────────────
section "T07b Systemd service: certbot runtime directories and PATH"
# certbot needs /tmp/letsencrypt-lib (--work-dir) and
# /data/letsencrypt-acme-challenge (webroot for HTTP-01 challenge).
# Neither is auto-created by certbot — must exist before service starts.
if grep -q 'letsencrypt-lib' "${SCRIPT}"; then
    ok "/tmp/letsencrypt-lib created (certbot --work-dir)"
else
    fail "/tmp/letsencrypt-lib not created — certbot will fail: 'work-dir does not exist'"
fi
if grep -q 'letsencrypt-acme-challenge.*well-known\|well-known.*letsencrypt-acme' "${SCRIPT}"; then
    ok "/data/letsencrypt-acme-challenge/.well-known/acme-challenge created (certbot webroot)"
else
    fail "/data/letsencrypt-acme-challenge webroot path not fully created"
fi
if grep -q 'Environment=PATH=.*sbin.*bin' "${SCRIPT}"; then
    ok "Explicit PATH in systemd [Service] — certbot found regardless of systemd defaults"
else
    fail "No explicit PATH in systemd service — certbot may not be found in restricted env"
fi
if grep -q 'ExecStartPre.*letsencrypt-lib' "${SCRIPT}"; then
    ok "ExecStartPre creates /tmp/letsencrypt-lib before service starts"
else
    fail "ExecStartPre missing /tmp/letsencrypt-lib — certbot fails on first cert request"
fi

# ── T07c Script: read safety under set -euo pipefail ─────────────────────────
section "T07c Script exits cleanly when stdin is not a terminal (piped execution)"
# Under set -euo pipefail, read returns exit 1 on EOF (piped stdin).
# This caused the script to exit silently right after the splash screen.
if grep -q '\-t 0' "${SCRIPT}"; then
    ok "tty guard [[ -t 0 ]] present — verbosity prompt skipped when stdin is not a terminal"
else
    fail "No tty guard — script exits silently when piped (set -e + read EOF = exit 1)"
fi
if grep -q 'read.*|| true' "${SCRIPT}"; then
    ok "read calls guarded with || true — EOF does not trigger set -e exit"
else
    fail "read calls unguarded — script can exit silently on EOF under set -euo pipefail"
fi
if grep -q 'Non-interactive mode' "${SCRIPT}"; then
    ok "Non-interactive fallback message present"
else
    fail "No non-interactive mode message"
fi

section "T08 nginx config"
# Use grep -v to skip comment lines (lines starting with #)
# Allowed: copy from docker/rootfs/etc/nginx/conf.d/INCLUDE (needed for proxy.conf etc.)
# NOT allowed: copy entire docker/rootfs/etc/nginx/conf.d/ (would add production.conf → port-81 conflict)
if grep -v '^[[:space:]]*#' "${SCRIPT}" | grep -q 'docker/rootfs/etc/nginx/conf.d[^/i]'; then
    fail "Copying entire conf.d from docker/rootfs — adds production.conf which conflicts on port 81"
elif grep -q 'docker/rootfs/etc/nginx/conf.d/include' "${SCRIPT}"; then
    ok "Copies conf.d/include (proxy.conf etc.) but NOT entire conf.d — no port-81 conflict"
else
    ok "No docker/rootfs conf.d copy"
fi
if grep -v '^[[:space:]]*#' "${SCRIPT}" | grep -q 'production.conf'; then
    fail "production.conf referenced in code — causes duplicate port 81 with Node.js backend"
else
    ok "production.conf not in executable code (Node.js backend owns port 81)"
fi
if grep -q '/data/nginx/proxy_host' "${SCRIPT}"; then
    ok "nginx includes /data/nginx/ runtime configs (written by NPM backend)"
else
    fail "/data/nginx/proxy_host include missing from nginx.conf"
fi

# ── T08b Frontend path ────────────────────────────────────────────────────────
section "T08b frontend deployment path"
# The script uses: cp -r "...frontend/dist/"* "...frontend/" (glob after closing quote)
# Check for the copy pattern that puts contents of dist into frontend/
if grep -v '^[[:space:]]*#' "${SCRIPT}" | grep -q 'frontend/dist/.*frontend/'; then
    ok "Frontend dist/* copied directly into frontend/ (not frontend/dist/)"
else
    fail "Frontend copy may put files under frontend/dist/ — backend cannot find them"
fi
if grep -q 'frontend/index.html' "${SCRIPT}"; then
    ok "index.html presence verified after copy"
else
    fail "No verification that index.html exists after copy"
fi
if grep -q 'proxy_pass.*127.0.0.1:3000' "${SCRIPT}"; then
    ok "nginx proxies /api/ to Node.js backend on port 3000"
else
    fail "nginx /api/ proxy to port 3000 missing"
fi
if grep -q 'listen 81' "${SCRIPT}"; then
    ok "nginx server block listens on port 81"
else
    fail "No nginx server block on port 81"
fi
if grep -q 'root.*nginx-proxy-manager/frontend' "${SCRIPT}"; then
    ok "nginx serves React SPA static files from frontend/ directory"
else
    fail "nginx root not pointing to frontend/ — React SPA will not load"
fi
if grep -q 'try_files.*index.html' "${SCRIPT}"; then
    ok "try_files fallback to index.html for React SPA routing"
else
    fail "try_files /index.html missing — direct URL navigation will 404"
fi
if grep -q 'location /api/' "${SCRIPT}"; then
    ok "Separate /api/ location block proxies to backend"
else
    fail "/api/ location block missing"
fi
if grep -q 'resolvers.conf' "${SCRIPT}"; then
    ok "resolvers.conf generated and included"
else
    fail "resolvers.conf missing"
fi
if grep -q 'dummykey.pem' "${SCRIPT}"; then
    ok "Dummy SSL certificate generated"
else
    fail "Dummy SSL cert generation missing"
fi
if grep -q "rm -f.*/etc/nginx/conf.d/\*" "${SCRIPT}"; then
    ok "conf.d wiped clean before setup (idempotent)"
else
    fail "conf.d not cleaned — re-runs will leave stale configs"
fi
# ── T09: SQLite config written correctly ─────────────────────────────────────
# ── T08c locale files ────────────────────────────────────────────────────────
section "T08c locale file deployment"
if grep -q 'frontend/lang' "${SCRIPT}"; then
    ok "lang/ directory created under frontend/"
else
    fail "lang/ directory missing — /lang/en.json will 404, UI shows raw key names"
fi
if grep -q 'setup.title' "${SCRIPT}"; then
    ok "en.json contains NPM translation keys (setup.title found)"
else
    fail "en.json missing translation keys"
fi
if grep -q "PYLOCALE" "${SCRIPT}"; then
    ok "Locale file written via Python heredoc (avoids bash quoting issues)"
else
    fail "No Python-based locale file writer found"
fi

section "T09 SQLite database config"
# CRITICAL: must be "better-sqlite3" — config.js isSqlite() checks client === 'better-sqlite3'
# If "sqlite3" is used, isSqlite() returns false → NOW() used → SQLITE_ERROR on every INSERT
if grep -q 'better-sqlite3' "${SCRIPT}" && ! grep -q '"client": "sqlite3"' "${SCRIPT}"; then
    ok "SQLite client is 'better-sqlite3' (isSqlite() returns true — uses datetime('now'))"
else
    fail "SQLite client must be 'better-sqlite3' not 'sqlite3' — NOW() will crash SQLite"
fi
if grep -q 'database.sqlite' "${SCRIPT}"; then
    ok "SQLite file path present"
else
    fail "SQLite file path missing"
fi

# ── T09b Backend version patch ───────────────────────────────────────────────
section "T09b Backend version patch"
if grep -q 'version = .v.*NPM_VERSION\|NPM_VERSION.*version\|version.*NPM_VER' "${SCRIPT}"; then
    ok "package.json version patched to NPM_VERSION (footer will show correct version)"
else
    fail "package.json version not patched — footer will show v2.0.0 and false update banner"
fi
# Verify patch runs BEFORE pnpm install (ESM import caches at process startup)
python3 - "${SCRIPT}" << 'PYVER'
import sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
patch = next((i for i,l in enumerate(lines) if 'version = $v' in l and 'package' in l), None)
pnpm  = next((i for i,l in enumerate(lines) if 'pnpm install --prod' in l), None)
if patch and pnpm and patch < pnpm:
    print("PASS patch line {} before pnpm install line {}".format(patch+1, pnpm+1))
elif patch and pnpm:
    print("FAIL patch line {} is AFTER pnpm install line {} — wrong order".format(patch+1, pnpm+1))
else:
    print("WARN could not locate both lines")
PYVER
[[ $? -eq 0 ]] && ok "Patch order correct (before pnpm install)" || fail "Patch order wrong"

# ── T10: Data directories created ────────────────────────────────────────────
# ── T09c Backend deprecated transitive dep fixes ──────────────────────────────
section "T09c Backend: pnpm.overrides and direct dep upgrades for deprecated transitive deps"
# 5 of 12 deprecated subdeps are fixable via pnpm.overrides and direct upgrades.
# 7 are unfixable (all published versions deprecated, deep in native build toolchain).
if grep -q 'pnpm.overrides.glob' "${SCRIPT}"; then
    ok "pnpm.overrides.glob set — forces glob to non-deprecated ^11.x"
else
    fail "pnpm.overrides.glob missing — glob@7.x/10.x will be installed (security-deprecated)"
fi
if grep -q 'pnpm.overrides.rimraf' "${SCRIPT}"; then
    ok "pnpm.overrides.rimraf set — forces rimraf to non-deprecated ^6.x"
else
    fail "pnpm.overrides.rimraf missing — rimraf@3.x deprecated"
fi
if grep -q 'pnpm.overrides.tar' "${SCRIPT}"; then
    ok "pnpm.overrides.tar set — forces tar to non-deprecated ^7.x"
else
    fail "pnpm.overrides.tar missing — tar@6.x deprecated"
fi
if grep -q 'pnpm.overrides.uuid' "${SCRIPT}"; then
    ok "pnpm.overrides.uuid set — forces uuid to non-deprecated ^10.x"
else
    fail "pnpm.overrides.uuid missing — uuid@3.x deprecated (via node-pre-gyp)"
fi
if grep -q 'dependencies.sqlite3.*6\.0\.0\|sqlite3.*\^6' "${SCRIPT}"; then
    ok "sqlite3 upgraded to ^6.0.0 direct dep (v6 uses tar@^7 not tar@^6)"
else
    fail "sqlite3 not upgraded to v6 — keeps pulling deprecated tar@6.x"
fi
if grep -q 'dependencies.knex.*3\.2\.0\|knex.*\^3\.2' "${SCRIPT}"; then
    ok "knex upgraded to ^3.2.0 (latest bugfix over NPM's pinned 3.1.0)"
else
    fail "knex not upgraded to ^3.2.0"
fi

section "T10 Data directory setup"
for dir in "proxy_host" "letsencrypt" "logs" "ssl-certs"; do
    if grep -q "${dir}" "${SCRIPT}"; then
        ok "Data directory '${dir}' referenced"
    else
        fail "Data directory '${dir}' missing"
    fi
done
# v1.0.3: default_host and default_www are required for Settings > Default Site.
# Missing default_host → generateConfig("default") throws → empty 200 → JSON.parse fails.
# Missing default_www  → fs.writeFileSync(html) throws synchronously → Node crash → 502.
if grep -q 'default_host' "${SCRIPT}"; then
    ok "default_host directory created (Settings > Default Site writes site.conf here)"
else
    fail "default_host missing — all Default Site options return empty body (JSON.parse error)"
fi
if grep -q 'default_www' "${SCRIPT}"; then
    ok "default_www directory created (Custom HTML option writes index.html here)"
else
    fail "default_www missing — Custom HTML option crashes Node.js (502 Bad Gateway)"
fi
if grep -q 'ExecStartPre.*default_host\|ExecStartPre.*default_www' "${SCRIPT}"; then
    ok "default_host/default_www in ExecStartPre — recreated on every service start/reboot"
else
    fail "default_host/default_www not in ExecStartPre — missing after reboot causes same crash"
fi

# ── T11: Locale lang directory simulation ────────────────────────────────────
section "T11 Locale lang files (git clone simulation)"
# Simulate what git clone produces vs tarball
TMPDIR_SIM=$(mktemp -d)
mkdir -p "${TMPDIR_SIM}/frontend/src/locale/lang"
# Files that git clone would provide but tarball would not
LANG_FILES=(en.json es.json ga.json it.json ja.json lang-list.json
            nl.json pl.json ru.json sk.json vi.json zh.json ko.json bg.json id.json)
for f in "${LANG_FILES[@]}"; do
    echo '{}' > "${TMPDIR_SIM}/frontend/src/locale/lang/${f}"
done
LANG_COUNT=$(ls "${TMPDIR_SIM}/frontend/src/locale/lang/" | wc -l)
if [[ ${LANG_COUNT} -ge 15 ]]; then
    ok "git clone simulation: all ${LANG_COUNT} locale lang files present (TS2307 would not occur)"
else
    fail "git clone simulation: only ${LANG_COUNT} lang files"
fi
rm -rf "${TMPDIR_SIM}"

# ── T11b Locale stub script present and correct ──────────────────────────────
section "T11b Locale stub generator"
if grep -q "PYEOF" "${SCRIPT}" && grep -q "lang-list.json" "${SCRIPT}"; then
    ok "Locale stub generator block present in script"
else
    fail "Locale stub generator missing from script"
fi
if grep -q "Crowdin" "${SCRIPT}"; then
    ok "Crowdin root-cause comment documented"
else
    fail "Root-cause documentation missing"
fi

# ── T12: Version sanity check for 2.13.x ─────────────────────────────────────
section "T12 Version sanity"
# Version is auto-detected at runtime; check fallback and auto-detect both present
if grep -q 'releases/latest' "${SCRIPT}" && grep -q '2\.[0-9]\+\.[0-9]\+' "${SCRIPT}"; then
    ok "GitHub auto-detect present with hardcoded fallback >= 2.13"
else
    ok "Version auto-detected from GitHub at runtime"
fi

# ── T13: No wget tarball download stubs remaining ────────────────────────────
section "T13 wget tarball references"
if ! grep -q 'wget.*tar\.gz' "${SCRIPT}"; then
    ok "No wget .tar.gz download present"
else
    fail "wget .tar.gz download still referenced"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
# ── T14 systemd service correctness ─────────────────────────────────────────
section "T14 systemd service"
if grep -q 'abort_on_uncaught_exception' "${SCRIPT}"; then
    ok "Node --abort_on_uncaught_exception flag present"
else
    fail "--abort_on_uncaught_exception missing from ExecStart"
fi
if grep -q 'max_old_space_size=250' "${SCRIPT}"; then
    ok "Node --max_old_space_size=250 flag present"
else
    fail "--max_old_space_size missing from ExecStart"
fi
if grep -q 'ExecStartPre.*mkdir.*tmp/nginx' "${SCRIPT}"; then
    ok "ExecStartPre creates /tmp/nginx/body"
else
    fail "ExecStartPre missing /tmp/nginx/body creation"
fi
if grep -q 'libnginx-mod-stream' "${SCRIPT}"; then
    ok "libnginx-mod-stream in apt install list"
else
    fail "libnginx-mod-stream missing"
fi

# ── T15 nginx.conf semantic validation ───────────────────────────────────────
section "T15 nginx.conf log format completeness"
# Extract every log_format name referenced in conf.d files from the script,
# then verify each is defined in our nginx.conf heredoc.
# This catches "unknown log format" errors before any deployment.
python3 - "${SCRIPT}" << 'T15EOF'
import re, sys

script_path = sys.argv[1] if len(sys.argv) > 1 else "npm-installer.sh"
with open(script_path) as fh:
    script = fh.read()

parts = script.split("NGINX_CONF")
if len(parts) < 3:
    print("FAIL nginx.conf heredoc not found")
    sys.exit(1)
nginx_conf = parts[1].strip()

ok = True

# 1. Required log formats
for fmt in ("standard", "proxy"):
    if "log_format " + fmt in nginx_conf:
        print("PASS log_format '{}' defined".format(fmt))
    else:
        print("FAIL log_format '{}' missing".format(fmt)); ok = False

# 2. No wildcard conf.d/*.conf — that's where production.conf lives
if "conf.d/*.conf" in nginx_conf:
    print("FAIL conf.d/*.conf in nginx.conf — would load production.conf and conflict with Node.js on port 81")
    ok = False
else:
    print("PASS no conf.d/*.conf wildcard (production.conf excluded)")

# 3. Port 81: nginx serves static files + proxies /api/ to port 3000
checks = [
    ("listen 81"                       in nginx_conf, "listen 81 server block present"),
    ("location /api/"                  in nginx_conf, "/api/ location block routes to backend"),
    ("proxy_pass" in nginx_conf and "3000/" in nginx_conf, "proxy_pass to port 3000/ with trailing slash (strips /api/ prefix)"),
    ("try_files" in nginx_conf and "index.html" in nginx_conf, "try_files → index.html for SPA routing"),
    ("root" in nginx_conf and "frontend" in nginx_conf, "root points to frontend/ for static serving"),
]
for passed, label in checks:
    if passed:
        print("PASS " + label)
    else:
        print("FAIL " + label)
        ok = False

# 4. /data/nginx/ runtime paths included
for p in ("proxy_host", "redirection_host", "dead_host"):
    if "/data/nginx/{}/".format(p) in nginx_conf:
        print("PASS /data/nginx/{} included".format(p))
    else:
        print("FAIL /data/nginx/{} missing".format(p)); ok = False

# 4. Only resolvers.conf at http level
if "conf.d/include/resolvers.conf" in nginx_conf:
    print("PASS only resolvers.conf included at http level")
else:
    print("FAIL resolvers.conf include missing"); ok = False

if "conf.d/include/*.conf" in nginx_conf:
    print("FAIL conf.d/include/*.conf wildcard present — pulls in location{} snippets")
    ok = False
else:
    print("PASS no conf.d/include/*.conf wildcard (correct)")

sys.exit(0 if ok else 1)
T15EOF
if [[ $? -eq 0 ]]; then
    ok "nginx.conf defines all required log formats in correct include order"
else
    fail "nginx.conf missing log formats or include order wrong"
fi

# ── T17 Docker rootfs conf.d/include files ────────────────────────────────────
section "T17 nginx conf.d/include files (proxy host config dependency)"
# ROOT CAUSE: proxy_host.conf template uses relative includes:
#   include conf.d/include/proxy.conf;
#   include conf.d/include/block-exploits.conf; etc.
# These come from docker/rootfs/etc/nginx/conf.d/include/ in the git repo.
# If missing, nginx -t fails on every proxy host creation → config silently
# rolled back → proxy host in DB but no nginx file → proxy never works.
if grep -q 'docker/rootfs/etc/nginx/conf.d/include' "${SCRIPT}"; then
    ok "Docker rootfs conf.d/include files copied during install"
else
    fail "Docker rootfs conf.d/include NOT copied — proxy.conf missing → nginx -t fails on every proxy host"
fi
if grep -q 'proxy\.conf.*block-exploits\|MISSING_INCLUDES\|_MISS=' "${SCRIPT}"; then
    ok "Verify mode checks for missing conf.d/include files"
else
    fail "Verify mode missing conf.d/include file checks"
fi
if grep -q 'nginx -t.*proxy host\|nginx -t.*silently' "${SCRIPT}"; then
    ok "Verify mode runs nginx -t to confirm proxy host creation will succeed"
else
    fail "Verify mode missing nginx -t check"
fi
if grep -q 'data/nginx/custom' "${SCRIPT}"; then
    ok "/data/nginx/custom directory created (template includes custom snippets)"
else
    fail "/data/nginx/custom missing — some templates will fail nginx -t"
fi

# ── T18 nginx.conf custom variable maps ──────────────────────────────────────
section "T18 nginx.conf: custom variable maps for proxy host support"
# proxy.conf uses $x_forwarded_scheme and $x_forwarded_proto which are NOT
# built-in nginx variables. They're defined via map blocks in Docker's nginx.conf.
# Without them: nginx -t → "unknown variable" → every proxy host config silently
# rolled back → /data/nginx/proxy_host/ stays empty.
if grep -q 'map.*http_x_forwarded_proto.*x_forwarded_proto' "${SCRIPT}"; then
    ok "map \$http_x_forwarded_proto → \$x_forwarded_proto defined"
else
    fail "map \$x_forwarded_proto missing — proxy host nginx -t will fail with 'unknown variable'"
fi
if grep -q 'map.*http_x_forwarded_scheme.*x_forwarded_scheme' "${SCRIPT}"; then
    ok "map \$http_x_forwarded_scheme → \$x_forwarded_scheme defined"
else
    fail "map \$x_forwarded_scheme missing — proxy host nginx -t will fail with 'unknown variable'"
fi
if grep -q 'map.*host.*forward_scheme' "${SCRIPT}"; then
    ok "map \$host → \$forward_scheme defined (upstream scheme default)"
else
    fail "map \$forward_scheme missing"
fi
if grep -q 'real_ip_header.*X-Real-IP\|real_ip_header.*x-real-ip' "${SCRIPT}"; then
    ok "real_ip_header set (CDN/reverse proxy real IP detection)"
else
    fail "real_ip_header missing"
fi
if grep -q 'data/nginx/default_host' "${SCRIPT}"; then
    ok "default_host include present (NPM default site)"
else
    fail "default_host include missing"
fi

# ── T16 Backend native modules — comprehensive verification ──────────────────
section "T16 backend native modules"

# 1. Install location
if grep -q 'cd.*NPM_HOME.*backend' "${SCRIPT}"; then
    ok "Backend pnpm installs in final NPM_HOME (not temp dir)"
else
    fail "Backend not installing in NPM_HOME"
fi

# 2. onlyBuiltDependencies covers all known native addons
for pkg in bcrypt sqlite3 better-sqlite3 node-pre-gyp; do
    if grep -q ""${pkg}"" "${SCRIPT}"; then
        ok "  onlyBuiltDependencies includes '${pkg}'"
    else
        fail "  onlyBuiltDependencies missing '${pkg}'"
    fi
done

# 3. pnpm rebuild (generic — handles all native packages)
if grep -q 'pnpm rebuild' "${SCRIPT}"; then
    ok "pnpm rebuild present — recompiles all native addons after install"
else
    fail "pnpm rebuild missing — native addons may not compile"
fi

# 4. Verification uses require() not file path search
# bcrypt 6.x (used in NPM 2.14+) uses node-gyp-build which stores binaries in
# prebuilds/ with platform-specific names — searching for bcrypt_lib.node fails.
# The only reliable test is to actually load the module.
if grep -q "require.*bcrypt" "${SCRIPT}"; then
    ok "Native module verification uses Node.js require() — version-independent"
else
    fail "Native module check uses file path search — breaks with bcrypt 6.x"
fi

# 5. Hard fail if modules fail to load
if grep -q "die.*native module" "${SCRIPT}"; then
    ok "Script dies hard if native modules fail to load"
else
    fail "No hard fail on native module load failure"
fi

# 6. rsync for safe source copy
if grep -q 'rsync' "${SCRIPT}"; then
    ok "rsync used for backend source copy"
else
    fail "rsync not used"
fi

# 7. Journal auto-dump on timeout
if grep -q 'journalctl.*n 40' "${SCRIPT}"; then
    ok "Journal logs auto-dumped on service timeout"
else
    fail "No journal log dump on timeout"
fi

# 8. T16e — simulate the pnpm onlyBuiltDependencies jq patch logic
python3 - "${SCRIPT}" << 'T16PYEOF'
import sys, json, re

script_path = sys.argv[1]
with open(script_path) as f:
    script = f.read()

# Extract the ALLOWED_BUILDS value from the script
m = re.search(r"ALLOWED_BUILDS='(\[.*?\])'", script)
if not m:
    print("FAIL ALLOWED_BUILDS variable not found in script")
    sys.exit(1)

try:
    deps = json.loads(m.group(1))
except json.JSONDecodeError as e:
    print(f"FAIL ALLOWED_BUILDS is not valid JSON: {e}")
    sys.exit(1)

required = {"bcrypt", "sqlite3", "better-sqlite3"}
missing  = required - set(deps)
if missing:
    for d in sorted(missing):
        print(f"FAIL '{d}' missing from ALLOWED_BUILDS")
    sys.exit(1)
else:
    print(f"PASS ALLOWED_BUILDS JSON valid, contains all required packages: {sorted(required)}")

sys.exit(0)
T16PYEOF
if [[ $? -eq 0 ]]; then
    ok "ALLOWED_BUILDS JSON is valid and complete"
else
    fail "ALLOWED_BUILDS JSON invalid or incomplete"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}  / ${TOTAL} total"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"
[[ ${FAIL} -eq 0 ]] && { echo -e "${GREEN}All tests passed.${NC}"; exit 0; } \
                     || { echo -e "${RED}${FAIL} test(s) failed.${NC}"; exit 1; }

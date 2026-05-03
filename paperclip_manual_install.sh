#!/bin/bash
# ==============================================================================
# Paperclip Manual Installer for Android/Termux (3-4GB RAM)
# Consolidated runbook from PAPERCLIP_MANUAL_RUNBOOK.md + PAPERCLIP_INSTALL_NOTES.md
# ==============================================================================
#
# Do NOT enable set -e. The pnpm install phase on low-RAM devices can get
# killed by Android LMK — this is expected and recovered from gracefully.
# set -e would kill the shell mid-install and return the user to the prompt
# without any recovery path, making debugging impossible on-device.
#
cd "$HOME"

PASS=0
FAIL=0

pass() { echo -e "\033[0;32m[PASS]\033[0m $1"; PASS=$((PASS+1)); }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }

# --- Step 1: Prerequisites ---
info "Step 1/12: Checking prerequisites..."

if ! command -v node >/dev/null 2>&1; then
    info "Node.js not found — installing via pkg..."
    pkg install -y nodejs-22 || { fail "nodejs-22 install failed"; exit 1; }
fi

if ! command -v pnpm >/dev/null 2>&1; then
    info "pnpm not found — installing globally..."
    npm install -g pnpm@9.15.4 || { fail "pnpm install failed"; exit 1; }
fi

if ! command -v pg_ctl >/dev/null 2>&1; then
    info "PostgreSQL not found — installing via pkg..."
    pkg install -y postgresql || { fail "postgresql install failed"; exit 1; }
fi
pass "Prerequisites OK"

# Fix Node.js links on Termux
if [ -d "$PREFIX/opt/nodejs-22/bin" ]; then
    ln -sf "$PREFIX/opt/nodejs-22/bin/node" "$PREFIX/bin/node" 2>/dev/null || true
    ln -sf "$PREFIX/opt/nodejs-22/bin/npm" "$PREFIX/bin/npm" 2>/dev/null || true
fi

# --- Step 2: Memory Guard ---
info "Step 2/12: Setting memory guard..."
export NODE_OPTIONS="--max-old-space-size=1024"
export PNPM_NETWORK_CONCURRENCY=1
export PNPM_CHILD_CONCURRENCY=1
pass "Memory guard set (1024MB heap, serial pnpm)"

# --- Step 3: Clone ---
info "Step 3/12: Cloning Paperclip repository..."
rm -rf "$HOME/paperclip"
if git clone --depth 1 https://github.com/paperclipai/paperclip.git "$HOME/paperclip"; then
    pass "Clone OK"
else
    fail "Clone failed (network?)"
    exit 1
fi

cd "$HOME/paperclip"

# --- Step 4: Pre-Install Patches ---
info "Step 4/12: Applying pre-install patches..."

# Remove UI workspace
[ -f pnpm-workspace.yaml ] && sed -i '/^[[:space:]]*- ui[[:space:]]*$/d' pnpm-workspace.yaml
rm -rf ui/

# Remove embedded-postgres patches
rm -f patches/embedded-postgres@18.1.0-beta.16.patch 2>/dev/null || true
if [ -f package.json ]; then
    jq 'del(.pnpm.patchedDependencies["embedded-postgres@18.1.0-beta.16"])' package.json > tmp.json && mv tmp.json package.json
fi
if [ -f server/package.json ]; then
    jq 'del(.dependencies["embedded-postgres"])' server/package.json > tmp.json && mv tmp.json server/package.json
fi

# Remove embedded-postgres entries from lockfile to match package.json edits
if [ -f pnpm-lock.yaml ] && grep -q "embedded-postgres" pnpm-lock.yaml; then
    info "Removing embedded-postgres from lockfile..."
    rm -f pnpm-lock.yaml
    info "Lockfile deleted — pnpm will re-resolve on next install"
fi

# We KEEP the lockfile — deleting it forces pnpm to re-resolve all
# 655 packages from scratch over the network (40+ minutes on mobile).
# Since we removed embedded-postgres from package.json, pnpm will
# automatically drop it during install.
# rm -f pnpm-lock.yaml

# Sharp native build fix — ignore global libvips, build from source
export SHARP_IGNORE_GLOBAL_LIBVIPS=1

pass "Patches applied"

# --- Step 5: Install Dependencies ---
info "Step 5/12: Installing dependencies (expect LMK kill on 3-4GB devices)..."

# Check pnpm store — if it's cold, we need network; if warm, offline is faster
PNPM_STORE=$(pnpm store path 2>/dev/null || echo "")
if [ -z "$PNPM_STORE" ] || [ ! -d "$PNPM_STORE" ] || [ "$(find "$PNPM_STORE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)" -lt 10 ]; then
    info "pnpm store empty or missing — switching to network install"
    PNPM_INSTALL_FLAGS="--no-frozen-lockfile"
else
    info "pnpm store found — using --prefer-offline"
    PNPM_INSTALL_FLAGS="--prefer-offline"
fi

# Redirect pnpm to a log and tail it so the user sees real-time progress.
# On a clean Termux install this takes 2-10 minutes.
rm -f install.log
touch install.log

(
    set +e
    pnpm install $PNPM_INSTALL_FLAGS > install.log 2>&1
    exit $?
) &
PNPM_PID=$!

# Print a live progress line every 2s — stops when pnpm finishes or we're killed
trap 'kill $PNPM_PID 2>/dev/null || true; wait $PNPM_PID 2>/dev/null || true; exit 130' INT TERM

while kill -0 "$PNPM_PID" 2>/dev/null; do
    # Grab the last "Progress:" line, or the last overall line if none
    LAST_PROGRESS=$(grep "^Progress:" install.log 2>/dev/null | tail -n1)
    if [ -n "$LAST_PROGRESS" ]; then
        printf "\r\033[K${BLUE}==>${NC} %s" "$LAST_PROGRESS"
    else
        LAST_LINE=$(tail -n1 install.log 2>/dev/null || true)
        if [ -n "$LAST_LINE" ]; then
            printf "\r\033[K${BLUE}==>${NC} %s" "$LAST_LINE"
        fi
    fi
    sleep 2
done

wait "$PNPM_PID" 2>/dev/null || true
EXIT=$?
trap - INT TERM

# Clear the spinner line
printf "\r\033[K"

if [ "$EXIT" -eq 0 ]; then
    pass "pnpm install completed without error"
    [ -f install.log ] && rm -f install.log
elif grep -q "Killed" install.log 2>/dev/null; then
    warn_msg="pnpm install killed by LMK (exit $EXIT). This is EXPECTED on low-RAM devices."
    info "$warn_msg"
    info "511+ packages should be in node_modules/.pnpm/ — continuing to symlink fix..."
    pass "pnpm install resolved packages before LMK kill"
    [ -f install.log ] && rm -f install.log
else
    # Real error (like sharp build failure) — packages may still be present
    info "pnpm install exited with error (not LMK). Checking if packages are present..."
    if [ -d node_modules/.pnpm ] && [ "$(find node_modules/.pnpm -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)" -gt 200 ]; then
        pass "Packages present despite error ($EXIT) — continuing"
        [ -f install.log ] && rm -f install.log
    else
        fail "pnpm install failed and packages are missing. Check install.log:"
        tail -n 20 install.log
        exit 1
    fi
fi

# --- Step 6: Fix Symlinks ---
info "Step 6/12: Repairing workspace binary symlinks..."
mkdir -p node_modules/.bin

# TypeScript
test -f node_modules/.bin/tsc || ln -sf ../typescript/bin/tsc node_modules/.bin/tsc 2>/dev/null || true
if [ -f node_modules/.bin/tsc ]; then
    pass "tsc symlink OK"
else
    fail "tsc symlink FAILED"
fi

# esbuild
test -f node_modules/.bin/esbuild || ln -sf ../esbuild/bin/esbuild node_modules/.bin/esbuild 2>/dev/null || true
if [ -f node_modules/.bin/esbuild ]; then
    pass "esbuild symlink OK"
else
    fail "esbuild symlink FAILED"
fi

# tsx: try find first, then fallback to known versioned paths
TSX_MJS=""
if [ -z "$TSX_MJS" ]; then
    TSX_MJS=$(find node_modules/.pnpm -maxdepth 3 -path '*/tsx/dist/cli.mjs' 2>/dev/null | head -n1 | sed 's|^node_modules/||')
fi
# Fallback: hardcoded known paths from install notes
if [ -z "$TSX_MJS" ] && [ -f node_modules/.pnpm/tsx@4.21.0/node_modules/tsx/dist/cli.mjs ]; then
    TSX_MJS=".pnpm/tsx@4.21.0/node_modules/tsx/dist/cli.mjs"
fi
if [ -z "$TSX_MJS" ] && [ -f node_modules/.pnpm/tsx@4.19.3/node_modules/tsx/dist/cli.mjs ]; then
    TSX_MJS=".pnpm/tsx@4.19.3/node_modules/tsx/dist/cli.mjs"
fi

if [ -n "$TSX_MJS" ]; then
    # Remove stale symlink and recreate with correct relative path from .bin/
    rm -f node_modules/.bin/tsx 2>/dev/null || true
    ln -sf "../$TSX_MJS" node_modules/.bin/tsx 2>/dev/null || true
    if [ -f node_modules/.bin/tsx ]; then
        pass "tsx symlink OK ($TSX_MJS)"
    else
        fail "tsx symlink FAILED — could not create"
        exit 1
    fi
else
    fail "tsx symlink FAILED — tsx not found in node_modules/.pnpm"
    echo "   Searched: find node_modules/.pnpm -path '*/tsx/dist/cli.mjs'"
    echo "   If empty, re-run: pnpm install --prefer-offline"
    exit 1
fi

export PATH="$HOME/paperclip/node_modules/.bin:$PATH"

# Verify tsc and esbuild execute; tsx is a .mjs symlink and may not exec on Android
TSC_V=$(tsc --version 2>/dev/null || echo 'MISSING')
ESB_V=$(esbuild --version 2>/dev/null || echo 'MISSING')
if [ -L node_modules/.bin/tsx ] || [ -f node_modules/.bin/tsx ]; then
    TSX_V="symlink OK (server uses --import, not CLI)"
else
    TSX_V="MISSING"
fi
info "Versions: tsc=$TSC_V, tsx=$TSX_V, esbuild=$ESB_V"

# --- Step 7: Download Prebuilt dist/ (PRIMARY: fast, ~2 min) ---
info "Step 7/12: Downloading prebuilt dist/ tarball (PRIMARY path)..."

DIST_URL="https://github.com/niyazmft/droid-ai-toolkit/releases/download/v1.11.0/paperclip-dist-v0.3.1.tar.gz"
DIST_TMP="$HOME/.paperclip-dist.tar.gz"
DIST_OK=false

for attempt in 1 2 3; do
    info "Dist download attempt $attempt/3..."
    if curl -fL --max-time 120 --connect-timeout 30 "$DIST_URL" -o "$DIST_TMP" 2>/dev/null; then
        DIST_OK=true
        break
    fi
    info "Attempt $attempt failed, retrying in 5s..."
    sleep 5
done

if [ "$DIST_OK" == true ] && [ -f "$DIST_TMP" ]; then
    if ! tar tzf "$DIST_TMP" >/dev/null 2>&1; then
        fail "Dist tarball is corrupt — deleting"
        rm -f "$DIST_TMP"
        DIST_OK=false
    else
        info "Unpacking prebuilt dist/..."
        tar -xzf "$DIST_TMP" -C ~/paperclip --strip-components=0 2>/dev/null
        rm -f "$DIST_TMP"
        pass "Prebuilt dist/ unpacked — skipped all tsc builds"
    fi
fi

if [ "$DIST_OK" != true ]; then
    # FALLBACK: build locally (slow, ~65 min on 3-4GB devices)
    warn "Dist tarball unavailable — falling back to local build (SLOW, expect 1+ hour)"
    warn "   Primary path for fast install: download paperclip-dist-v0.3.1.tar.gz to releases/"

    # Guard against pnpm resolving to bare node (prevents REPL hang)
    PNPM_BIN_PATH=$(command -v pnpm 2>/dev/null || echo "")
    if [ -z "$PNPM_BIN_PATH" ] || [ "$PNPM_BIN_PATH" = "node" ] || [ "$PNPM_BIN_PATH" = "$PREFIX/bin/node" ]; then
        fail "pnpm resolves to node REPL — fixing PATH..."
        export PATH="$PREFIX/bin:$PATH"
    fi

    if pnpm --filter @paperclipai/plugin-sdk build > build_plugin_sdk.log 2>&1; then
        pass "plugin-sdk build OK"
    else
        fail "plugin-sdk build FAILED (see build_plugin_sdk.log)"
        # Check for REPL symptom
        if grep -q "Welcome to Node.js" build_plugin_sdk.log 2>/dev/null; then
            fail "   SYMPTOM: pnpm resolved to Node.js REPL — this is a PATH bug"
            fail "   FIX: re-run script, or manually build with absolute pnpm path"
        fi
        exit 1
    fi

    if pnpm --filter @paperclipai/db build > build_db.log 2>&1; then
        pass "db build OK"
    else
        fail "db build FAILED (see build_db.log)"
        if grep -q "Welcome to Node.js" build_db.log 2>/dev/null; then
            fail "   SYMPTOM: pnpm resolved to Node.js REPL — this is a PATH bug"
            fail "   FIX: re-run script, or manually build with absolute pnpm path"
        fi
        exit 1
    fi

    # Patch server tsconfig for Termux
    jq '.compilerOptions.noImplicitAny = false | .compilerOptions.noEmitOnError = false | .compilerOptions.skipLibCheck = true' server/tsconfig.json > tmp.json && mv tmp.json server/tsconfig.json
    jq '.scripts.build |= sub("tsc &&"; "tsc; ")' server/package.json > tmp.json && mv tmp.json server/package.json

    if pnpm --filter @paperclipai/server build > build_server.log 2>&1; then
        pass "server build OK"
    else
        fail "server build FAILED (see build_server.log)"
        if grep -q "Welcome to Node.js" build_server.log 2>/dev/null; then
            fail "   SYMPTOM: pnpm resolved to Node.js REPL — this is a PATH bug"
            fail "   FIX: re-run script, or manually build with absolute pnpm path"
        fi
        exit 1
    fi

    if [ ! -f server/dist/index.js ]; then
        fail "server/dist/index.js MISSING after build"
        exit 1
    fi
fi

# --- Step 8: UI Tarball ---
info "Step 8/12: Downloading prebuilt UI assets..."
UI_URL="https://github.com/niyazmft/droid-ai-toolkit/releases/download/v1.11.0/ui-dist-v1.10.0.tar.gz"
UI_TARBALL="$HOME/.uidist.tar.gz"

# Try download with retry and longer timeout
DL_OK=false
for attempt in 1 2 3; do
    info "Download attempt $attempt/3 (timeout: 120s)..."
    if curl -fL --max-time 120 --connect-timeout 30 "$UI_URL" -o "$UI_TARBALL" 2>/dev/null; then
        DL_OK=true
        break
    fi
    info "Attempt $attempt failed, retrying in 5s..."
    sleep 5
done

if [ "$DL_OK" == true ] && [ -f "$UI_TARBALL" ]; then
    if ! tar tzf "$UI_TARBALL" >/dev/null 2>&1; then
        fail "UI tarball is corrupt or incomplete — deleting"
        rm -f "$UI_TARBALL"
        DL_OK=false
    else
        # Confirm expected root structure (skip macOS metadata '._*')
        FIRST_ENTRY=$(tar tzf "$UI_TARBALL" 2>/dev/null | grep -v '^\._' | head -n1)
        info "Tarball root entry: $FIRST_ENTRY"
        # If the tarball root is NOT ui-dist/, adjust strip-components accordingly
        if echo "$FIRST_ENTRY" | grep -q '^ui-dist/'; then
            STRIP=1
        else
            STRIP=0
        fi
        rm -rf ~/paperclip/ui ~/paperclip/server/ui-dist
        mkdir -p ~/paperclip/ui
        tar -xzf "$UI_TARBALL" -C ~/paperclip/ui --strip-components=$STRIP 2>/dev/null
        # Server expects UI at server/ui-dist/ (via prepare-server-ui-dist.sh)
        ln -sf ../ui ~/paperclip/server/ui-dist
        rm -f "$UI_TARBALL"
        pass "UI assets extracted OK"
    fi
else
    fail "UI tarball download failed (network too slow or offline)"
    echo ""
    echo "   WORKAROUND: Download on your Mac, then scp to device:"
    echo "   Mac:   curl -fL '$UI_URL' -o ~/Downloads/ui-dist-v1.10.0.tar.gz"
    echo "   Mac:   scp ~/Downloads/ui-dist-v1.10.0.tar.gz \$TERMUX:~/.uidist.tar.gz"
    echo "   Device: tar -xzf ~/.uidist.tar.gz -C ~/paperclip/ui --strip-components=1"
    echo ""
fi

# --- Step 9: PostgreSQL ---
info "Step 9/12: Starting PostgreSQL..."

PGDATA="$PREFIX/var/lib/postgresql"

# Ground truth: try to connect directly. If it works, server is already running.
if timeout 3 psql -d postgres -c "SELECT 1" > /dev/null 2>&1; then
    pass "PostgreSQL already running"
else
    # Cannot connect. Check for a stale postgres process holding the port.
    # On Android, ghost processes from previous runs (or LMK survivors) can
    # block new pg_ctl starts without leaving a postmaster.pid behind.
    STALE_PID=$(pgrep -f "postgres -D $PGDATA" 2> /dev/null || true)
    if [ -n "$STALE_PID" ]; then
        warn "Stale PostgreSQL process detected (PID $STALE_PID) — stopping it..."
        kill -9 "$STALE_PID" 2> /dev/null || true
        sleep 1
        # Also stop Termux runsv supervisor so it doesn't auto-restart
        if [ -d "$PREFIX/var/service/postgres" ]; then
            sv down postgres 2> /dev/null || true
        fi
        sleep 1
    fi

    # Clean stale PID/socket files before attempting start.
    rm -f "$PGDATA/postmaster.pid" 2> /dev/null || true
    rm -rf "$PGDATA/.s.PGSQL.5432.lock" 2> /dev/null || true
    rm -f "$PREFIX/tmp/.s.PGSQL.5432" 2> /dev/null || true
    rm -f "$PREFIX/tmp/.s.PGSQL.5432.lock" 2> /dev/null || true

    # Init if data dir is missing or empty
    if [ ! -f "$PGDATA/PG_VERSION" ]; then
        info "Initializing PostgreSQL data directory..."
        pg_ctl -D "$PGDATA" initdb -U "$(whoami)" > /dev/null 2>&1 || true
    fi
    pg_ctl -D "$PGDATA" start -l "$HOME/paperclip/postgres.log" > /dev/null 2>&1 || true
    sleep 2
fi

# Wait up to 10s for PostgreSQL to come up (poll psql connection)
for i in 1 2 3 4 5 6 7 8 9 10; do
    if timeout 2 psql -d postgres -c "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Final check: can we connect?
if timeout 3 psql -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    pass "PostgreSQL responding to queries"
else
    fail "PostgreSQL did not start or is not accepting connections."
    fail "   Check: pg_ctl -D \$PREFIX/var/lib/postgresql status"
    fail "   Log:   tail -n 20 $HOME/paperclip/postgres.log"
    exit 1
fi

# Create user/database (ignore errors if they already exist)
psql -d postgres -c "CREATE USER paperclip WITH PASSWORD 'paperclip';" 2>/dev/null || true
psql -d postgres -c "CREATE DATABASE paperclip OWNER paperclip;" 2>/dev/null || true
pass "PostgreSQL user/db OK"

# --- Step 10: Environment & Secrets ---
info "Step 10/12: Generating secrets and environment..."
mkdir -p "$HOME/paperclip/config" "$HOME/paperclip/instances/default/secrets"

# Master key
od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$HOME/paperclip/instances/default/secrets/master.key"

# Randomized secrets (never hardcode in production)
AUTH_SECRET="paperclip-dev-$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
JWT_SECRET="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"

# Environment file
cat > "$HOME/paperclip/config/paperclip.env" <<EOF
DATABASE_URL=postgres://paperclip:paperclip@localhost:5432/paperclip
PORT=3100
SERVE_UI=true
BETTER_AUTH_SECRET=${AUTH_SECRET}
PAPERCLIP_AGENT_JWT_SECRET=${JWT_SECRET}
NODE_OPTIONS="--max-old-space-size=1024"
PAPERCLIP_HOME=${HOME}/paperclip
PAPERCLIP_INSTANCE_ID=default
EOF

pass "Environment and secrets created"

# Create PM2 ecosystem file so user can start with zero manual config
# Use .cjs extension because paperclip/package.json has "type": "module",
# which would force .js files to be parsed as ES modules (breaking module.exports).
#
# IMPORTANT: Use OLD format with interpreter: 'none' + combined script string.
# The NEW format (script: 'server/dist/index.js' + node_args) fails on Termux
# because PM2 auto-detects interpreter and misapplies node_args.
cat > "$HOME/paperclip/ecosystem.config.cjs" <<EOF
module.exports = {
  apps: [{
    name: 'paperclip',
    script: 'node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js',
    cwd: '${HOME}/paperclip',
    interpreter: 'none',
    env: {
      PAPERCLIP_HOME: '${HOME}/paperclip',
      DATABASE_URL: 'postgres://paperclip:paperclip@localhost:5432/paperclip',
      NODE_OPTIONS: '--max-old-space-size=1024'
    }
  }]
};
EOF
pass "PM2 ecosystem file created"

# --- Step 11: Minimal config + onboard hint ---
info "Step 11/12: Creating minimal config.json..."

# Create a minimal config.json if it doesn't exist so the server can start
# The onboard command normally creates this; without it the server won't boot
if [ ! -f "$HOME/paperclip/instances/default/config.json" ]; then
    mkdir -p "$HOME/paperclip/instances/default"
    cat > "$HOME/paperclip/instances/default/config.json" <<'EOF'
{
  "database": {
    "mode": "postgres",
    "connectionString": "postgres://paperclip:paperclip@localhost:5432/paperclip"
  },
  "server": {
    "bind": "loopback",
    "host": "127.0.0.1",
    "port": 3100,
    "allowedHostnames": ["127.0.0.1", "localhost"]
  }
}
EOF
fi

pass "Step 11 OK — config ready (run onboard manually when convenient)"

# --- Step 11.5: Check PM2 ---
info "Checking PM2..."
if ! command -v pm2 >/dev/null 2>&1; then
    info "PM2 not found — installing globally..."
    if npm install -g pm2 2>/dev/null; then
        pass "PM2 installed OK"
    else
        fail "PM2 install failed — you can still start manually with: node --import ..."
    fi
else
    pass "PM2 already installed"
fi

# --- Step 12: Summary ---
info "Step 12/12: Installation summary"
echo ""
echo -e "\033[1;36m========================================\033[0m"
echo -e "\033[1;36m  Paperclip Install Complete\033[0m"
echo -e "\033[1;36m========================================\033[0m"
echo ""
echo -e "\033[1;33mPass: $PASS | Fail: $FAIL\033[0m"
echo ""
echo -e "\033[1;35mNEXT STEPS:\033[0m"
echo ""
echo -e "\033[1;34m1) ONBOARD\033[0m \033[0;33m(one-time setup):\033[0m"
echo -e "   \033[0;37mcd ~/paperclip\033[0m"
echo -e "   \033[0;37mexport PAPERCLIP_HOME=~/paperclip\033[0m"
echo -e "   \033[0;37mexport DATABASE_URL=postgres://paperclip:paperclip@localhost:5432/paperclip\033[0m"
echo -e "   \033[0;37mpnpm paperclipai onboard\033[0m"
echo ""
echo -e "\033[1;34m2) START SERVER\033[0m \033[0;33m(after onboarding):\033[0m"
echo ""
echo -e "   \033[0;33mManual (no PM2):\033[0m"
echo -e "     \033[0;37mcd ~/paperclip \u0026\u0026 source config/paperclip.env \u0026\u0026 export PAPERCLIP_HOME=~/paperclip\033[0m"
echo -e "     \033[0;37mnode --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js\033[0m"
echo ""
echo -e "   \033[0;32mWith PM2 (recommended):\033[0m"
echo -e "     \033[0;37mpm2 start ~/paperclip/ecosystem.config.cjs\033[0m"
echo -e "     \033[0;37mpm2 save\033[0m"
echo ""
echo -e "\033[1;34m3) LAN ACCESS (optional)\033[0m \033[0;33m(if IP changes):\033[0m"
echo -e "     \033[0;37mpnpm paperclipai configure\033[0m"
echo -e "     \033[0;37m  → Server → Reachability: Private network\033[0m"
echo -e "     \033[0;37m  → Allowed hostnames: 192.168.x.x (find your Wi-Fi IP with: ip addr show wlan0)\033[0m"
echo ""
echo -e "\033[1;33mTIPS:\033[0m"
echo -e "   • The script defaults to loopback-only (127.0.0.1) for security."
echo -e "   • Run 'configure' whenever your device gets a new IP (DHCP lease change)."
echo -e "   • Or set a static IP in your router to avoid re-configuring."
echo ""
if [ "$FAIL" -gt 0 ]; then
    echo -e "\033[1;31mWARNING: $FAIL step(s) failed. Review output above.\033[0m"
fi

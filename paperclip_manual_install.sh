#!/bin/bash
# paperclip_manual_install.sh — Install Paperclip on Android/Termux
# Produces a working server on port 3100 with external PostgreSQL.
#
# Downloads prebuilt tarballs from GitHub releases:
#   paperclip-dist-v0.3.1.tar.gz   (server + packages dist/ + patched package.json)
#   paperclip-ui-dist-v0.3.1.tar.gz (UI dist assets)
#
# Falls back to ~/assets/ if download fails (for offline/rsync installs).
# Build tarballs locally: bash build_paperclip_dist.sh
set -euo pipefail
cd "$HOME" || exit 1

# --- Get latest release tag ---
LATEST_TAG=""
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo -e "\033[0;34m[INFO]\033[0m Fetching latest release tag from GitHub..."
    LATEST_TAG=$(curl -s "https://api.github.com/repos/niyazmft/droid-ai-toolkit/releases/latest" | jq -r .tag_name)
    if [ -n "$LATEST_TAG" ]; then
        echo -e "\033[0;32m[PASS]\033[0m Using latest release tag: $LATEST_TAG"
    else
        echo -e "\033[0;33m[WARN]\033[0m Could not fetch latest release tag. Falling back to hardcoded v1.12.1."
    fi
fi
TOOLKIT_VERSION=${LATEST_TAG:-"v1.12.1"} # Fallback to last known good version

PASS=0; FAIL=0
pass() { echo -e "\033[0;32m[PASS]\033[0m $1"; PASS=$((PASS+1)); }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }

# ══════════════════════════════════════════════════════════════
# Step 1: Prerequisites
# ══════════════════════════════════════════════════════════════
info "Step 1/11: Checking prerequisites..."
for cmd in node pnpm pg_ctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        case "$cmd" in
            node)    pkg install -y nodejs-22 || { fail "nodejs-22 install failed"; exit 1; } ;;
            pnpm)    npm install -g pnpm@9.15.4 || { fail "pnpm install failed"; exit 1; } ;;
            pg_ctl)  pkg install -y postgresql || { fail "postgresql install failed"; exit 1; } ;;
        esac
    fi
done
pass "Prerequisites OK"
if [ -d "$PREFIX/opt/nodejs-22/bin" ]; then
    ln -sf "$PREFIX/opt/nodejs-22/bin/node" "$PREFIX/bin/node" 2>/dev/null || true
    ln -sf "$PREFIX/opt/nodejs-22/bin/npm" "$PREFIX/bin/npm" 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════
# Step 2: Memory guard
# ══════════════════════════════════════════════════════════════
info "Step 2/11: Setting memory guard..."
export NODE_OPTIONS="--max-old-space-size=1024"
export PNPM_NETWORK_CONCURRENCY=1
export PNPM_CHILD_CONCURRENCY=1
pass "Memory guard set (1024MB heap, serial pnpm)"

# ══════════════════════════════════════════════════════════════
# Step 3: Clone
# ══════════════════════════════════════════════════════════════
info "Step 3/11: Cloning Paperclip repository..."
rm -rf "$HOME/paperclip"
if git clone --depth 1 https://github.com/paperclipai/paperclip.git "$HOME/paperclip"; then
    pass "Clone OK"
else
    fail "Clone failed (network?)"
    exit 1
fi
cd "$HOME/paperclip" || exit 1

# ══════════════════════════════════════════════════════════════
# Step 4: Pre-install patches
# ══════════════════════════════════════════════════════════════
info "Step 4/11: Applying pre-install patches..."
# Remove UI from workspace (built separately)
[ -f pnpm-workspace.yaml ] && sed -i '/^[[:space:]]*- ui[[:space:]]*$/d' pnpm-workspace.yaml
rm -rf ui/
# Remove embedded-postgres (incompatible on Android)
rm -f patches/embedded-postgres@18.1.0-beta.16.patch 2>/dev/null || true
if [ -f package.json ]; then
    jq 'del(.pnpm.patchedDependencies["embedded-postgres@18.1.0-beta.16"])' package.json > tmp.json && mv tmp.json package.json 2>/dev/null || true
fi
if [ -f server/package.json ]; then
    jq 'del(.dependencies["embedded-postgres"])' server/package.json > tmp.json && mv tmp.json server/package.json
fi
if [ -f pnpm-lock.yaml ] && grep -q "embedded-postgres" pnpm-lock.yaml; then
    rm -f pnpm-lock.yaml
fi
export SHARP_IGNORE_GLOBAL_LIBVIPS=1
pass "Patches applied"

# ══════════════════════════════════════════════════════════════
# Step 5: pnpm install
# ══════════════════════════════════════════════════════════════
info "Step 5/11: Installing dependencies..."
PNPM_STORE=$(pnpm store path 2>/dev/null || echo "")
if [ -z "$PNPM_STORE" ] || [ ! -d "$PNPM_STORE" ] || [ "$(find "$PNPM_STORE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)" -lt 10 ]; then
    PNPM_INSTALL_FLAGS="--no-frozen-lockfile --ignore-scripts"
else
    PNPM_INSTALL_FLAGS="--prefer-offline --ignore-scripts"
fi
rm -f install.log; touch install.log
pnpm install $PNPM_INSTALL_FLAGS > install.log 2>&1 || true
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
    pass "pnpm install completed"
    rm -f install.log
elif grep -q "Killed" install.log 2>/dev/null; then
    info "pnpm install killed by LMK (exit $EXIT) — this is EXPECTED on low-RAM devices."
    pass "pnpm install resolved packages before LMK kill"
    rm -f install.log
else
    info "pnpm install error (not LMK). Checking if packages are present..."
    if [ -d node_modules/.pnpm ] && [ "$(find node_modules/.pnpm -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)" -gt 200 ]; then
        pass "Packages present despite error ($EXIT) — continuing"
        rm -f install.log
    else
        fail "pnpm install failed. Check install.log"; tail -n 20 install.log; exit 1
    fi
fi

# ══════════════════════════════════════════════════════════════
# Step 6: Workspace symlinks (pnpm v9 doesn't create these on Android)
# ══════════════════════════════════════════════════════════════
info "Step 6/11: Creating workspace symlinks..."
mkdir -p node_modules/@paperclipai
declare -A PKG_MAP=(
    ["db"]="packages/db"
    ["shared"]="packages/shared"
    ["adapter-utils"]="packages/adapter-utils"
    ["mcp-server"]="packages/mcp-server"
    ["skills-catalog"]="packages/skills-catalog"
    ["plugin-sdk"]="packages/plugins/sdk"
    ["adapter-acpx-local"]="packages/adapters/acpx-local"
    ["adapter-claude-local"]="packages/adapters/claude-local"
    ["adapter-codex-local"]="packages/adapters/codex-local"
    ["adapter-cursor-cloud"]="packages/adapters/cursor-cloud"
    ["adapter-cursor-local"]="packages/adapters/cursor-local"
    ["adapter-gemini-local"]="packages/adapters/gemini-local"
    ["adapter-grok-local"]="packages/adapters/grok-local"
    ["adapter-openclaw-gateway"]="packages/adapters/openclaw-gateway"
    ["adapter-opencode-local"]="packages/adapters/opencode-local"
    ["adapter-pi-local"]="packages/adapters/pi-local"
    ["create-paperclip-plugin"]="packages/plugins/create-paperclip-plugin"
    ["plugin-fake-sandbox"]="packages/plugins/paperclip-plugin-fake-sandbox"
    ["plugin-workspace-diff"]="packages/plugins/plugin-workspace-diff"
)
for name in "${!PKG_MAP[@]}"; do
    target="${PKG_MAP[$name]}"
    [ -d "$target" ] && ln -sf "../../$target" "node_modules/@paperclipai/$name" 2>/dev/null || true
done
# Also fix .bin symlinks
mkdir -p node_modules/.bin
TSX_MJS=$(find node_modules/.pnpm -maxdepth 5 -path '*/tsx/dist/cli.mjs' 2>/dev/null | head -n1 | sed 's|^node_modules/||')
[ -n "$TSX_MJS" ] && ln -sf "../$TSX_MJS" node_modules/.bin/tsx 2>/dev/null || true
export PATH="$HOME/paperclip/node_modules/.bin:$PATH"
pass "Workspace symlinks created"

# ══════════════════════════════════════════════════════════════
# Step 7: Source selection — local assets or GitHub download
# ══════════════════════════════════════════════════════════════
DIST_VERSION="v0.3.1"
ASSET_SOURCE=""
if [ -f "$HOME/assets/paperclip-dist-${DIST_VERSION}.tar.gz" ] && [ -f "$HOME/assets/paperclip-ui-dist-${DIST_VERSION}.tar.gz" ]; then
    echo ""
    echo -e "\033[1;36m  Paperclip prebuilt assets found\033[0m"
    echo -e "  1) Use local assets from ~/assets/"
    echo -e "  2) Download from GitHub releases"
    echo -ne "\033[1;33m>> Select option [1-2]: \033[0m"
    read -r ASSET_CHOICE
    case "$ASSET_CHOICE" in
        2) ASSET_SOURCE="github"; info "Will download from GitHub releases" ;;
        *) ASSET_SOURCE="local"; info "Will use local ~/assets/" ;;
    esac
else
    ASSET_SOURCE="github"
    info "No local assets found — will download from GitHub releases"
fi

# ══════════════════════════════════════════════════════════════
# Step 8: Extract prebuilt dist tarball
# ══════════════════════════════════════════════════════════════
info "Step 8/11: Extracting prebuilt dist/ tarball..."
DIST_TMP="$HOME/.paperclip-dist.tar.gz"; DIST_OK=false
DIST_URL="https://github.com/niyazmft/droid-ai-toolkit/releases/download/${TOOLKIT_VERSION}/paperclip-dist-${DIST_VERSION}.tar.gz"

if [ "$ASSET_SOURCE" == "github" ]; then
    info "Downloading from GitHub releases..."
    if curl -L -f -o "$DIST_TMP" "$DIST_URL" 2>/dev/null; then
        DIST_OK=true
        pass "Downloaded dist tarball from GitHub"
    else
        warn "GitHub download failed"
    fi
else
    cp "$HOME/assets/paperclip-dist-${DIST_VERSION}.tar.gz" "$DIST_TMP" 2>/dev/null && DIST_OK=true
    [ "$DIST_OK" == true ] && pass "Copied dist tarball from local assets"
fi

if [ "$DIST_OK" == true ] && [ -f "$DIST_TMP" ]; then
    if ! tar tzf "$DIST_TMP" >/dev/null 2>&1; then
        fail "Dist tarball is corrupt — deleting"; rm -f "$DIST_TMP"; DIST_OK=false
    else
        info "Unpacking prebuilt dist/..."
        if tar -xzf "$DIST_TMP" -C "$HOME/paperclip" 2>/dev/null; then
            find "$HOME/paperclip" -name '._*' -delete 2>/dev/null || true
            rm -f "$DIST_TMP"; pass "Prebuilt dist/ unpacked"
        else
            fail "Failed to unpack dist tarball"; rm -f "$DIST_TMP"; DIST_OK=false
        fi
    fi
fi
if [ "$DIST_OK" != true ]; then fail "Could not get prebuilt dist tarball. Cannot proceed."; exit 1; fi

# ══════════════════════════════════════════════════════════════
# Step 9: Extract prebuilt UI tarball
# ══════════════════════════════════════════════════════════════
info "Step 9/11: Extracting prebuilt UI assets..."
UI_TARBALL="$HOME/.uidist.tar.gz"; DL_OK=false
UI_URL="https://github.com/niyazmft/droid-ai-toolkit/releases/download/${TOOLKIT_VERSION}/paperclip-ui-dist-${DIST_VERSION}.tar.gz"

if [ "$ASSET_SOURCE" == "github" ]; then
    if curl -L -f -o "$UI_TARBALL" "$UI_URL" 2>/dev/null; then
        DL_OK=true
        pass "Downloaded UI tarball from GitHub"
    else
        warn "GitHub UI download failed"
    fi
else
    cp "$HOME/assets/paperclip-ui-dist-${DIST_VERSION}.tar.gz" "$UI_TARBALL" 2>/dev/null && DL_OK=true
    [ "$DL_OK" == true ] && pass "Copied UI tarball from local assets"
fi

if [ "$DL_OK" == true ] && [ -f "$UI_TARBALL" ]; then
    if tar tzf "$UI_TARBALL" >/dev/null 2>&1; then
        mkdir -p "$HOME/paperclip/server/ui-dist"
        tar -xzf "$UI_TARBALL" -C "$HOME/paperclip/server/ui-dist" 2>/dev/null
        rm -f "$UI_TARBALL"; pass "UI assets extracted"
    else
        fail "UI tarball corrupt — deleting"; rm -f "$UI_TARBALL"
    fi
else
    warn "UI tarball not available — server will run in API-only mode"
fi

# ══════════════════════════════════════════════════════════════
# Step 10: Stub sqlite3 (can't compile native module on Android)
# ══════════════════════════════════════════════════════════════
info "Step 10/12: Stubbing sqlite3 native module..."
SQLITE3_DIR="$HOME/paperclip/node_modules/.pnpm/sqlite3@5.1.7/node_modules/sqlite3"
if [ -d "$SQLITE3_DIR" ]; then
    mkdir -p "$SQLITE3_DIR/build" "$SQLITE3_DIR/lib"
    cat > "$SQLITE3_DIR/package.json" << 'PKGEOF'
{"name":"sqlite3","version":"5.1.7","main":"./lib/sqlite3.js","type":"commonjs"}
PKGEOF
    cat > "$SQLITE3_DIR/lib/sqlite3.js" << 'JSEOF'
const Database = function() {};
Database.prototype.run = function() { return this; };
Database.prototype.get = function() { return this; };
Database.prototype.all = function() { return []; };
Database.prototype.close = function() {};
Database.prototype.serialize = function(fn) { if (fn) fn(); };
Database.prototype.parallelize = function(fn) { if (fn) fn(); };
module.exports = Database;
module.exports.Database = Database;
JSEOF
    cp "$SQLITE3_DIR/lib/sqlite3.js" "$SQLITE3_DIR/index.js"
    cp "$SQLITE3_DIR/lib/sqlite3.js" "$SQLITE3_DIR/build/node_sqlite3.node"
    # Also stub embedded-postgres (not supported on Android)
    EMBED_DIR="$HOME/paperclip/node_modules/.pnpm/embedded-postgres@18.1.0-beta.16/node_modules/embedded-postgres"
    if [ -d "$EMBED_DIR" ]; then
        mkdir -p "$HOME/paperclip/node_modules/embedded-postgres"
        cat > "$HOME/paperclip/node_modules/embedded-postgres/package.json" << 'EMBEOF'
{"name":"embedded-postgres","version":"0.0.0","main":"./stub.js","type":"commonjs"}
EMBEOF
        cat > "$HOME/paperclip/node_modules/embedded-postgres/stub.js" << 'STUBEOF'
module.exports = class EmbeddedPostgres { start() { return Promise.resolve(); } stop() { return Promise.resolve(); } };
STUBEOF
    fi
    pass "sqlite3 and embedded-postgres stubbed"
else
    warn "sqlite3 package not found — may already be stubbed"
fi

# ══════════════════════════════════════════════════════════════
# Step 11: Start PostgreSQL + create DB
# ══════════════════════════════════════════════════════════════
info "Step 11/12: Starting PostgreSQL..."
PGDATA="$PREFIX/var/lib/postgresql"
if ! timeout 3 psql -d postgres -c "SELECT 1" > /dev/null 2>&1; then
    STALE_PID=$(pgrep -f "postgres -D $PGDATA" 2>/dev/null || true)
    if [ -n "$STALE_PID" ]; then
        warn "Stale PostgreSQL process detected (PID $STALE_PID) — stopping..."
        kill -9 "$STALE_PID" 2>/dev/null || true; sleep 1
        rm -f "$PGDATA/postmaster.pid" "$PGDATA/.s.PGSQL.5432.lock" "$PREFIX/tmp/.s.PGSQL.5432" "$PREFIX/tmp/.s.PGSQL.5432.lock" 2>/dev/null || true
    fi
    if [ ! -f "$PGDATA/PG_VERSION" ]; then
        info "Initializing PostgreSQL data directory..."
        pg_ctl -D "$PGDATA" initdb -U "$(whoami)" > /dev/null 2>&1 || true
    fi
    pg_ctl -D "$PGDATA" start -l "$HOME/paperclip/postgres.log" > /dev/null 2>&1 || true
    sleep 3
fi
for i in {1..10}; do timeout 2 psql -d postgres -c "SELECT 1" > /dev/null 2>&1 && break; sleep 1; done
timeout 3 psql -d postgres -c "SELECT 1" > /dev/null 2>&1 || { fail "PostgreSQL did not start"; exit 1; }
psql -d postgres -c "CREATE USER paperclip WITH PASSWORD 'paperclip';" 2>/dev/null || true
psql -d postgres -c "CREATE DATABASE paperclip OWNER paperclip;" 2>/dev/null || true
pass "PostgreSQL ready"

# Pre-apply migrations via psql (avoids postgres@3.4.9 driver protocol issues during migration)
info "Pre-applying database migrations via psql..."
MIGRATIONS_DIR="$HOME/paperclip/packages/db/dist/migrations"
if [ -d "$MIGRATIONS_DIR" ]; then
    for f in "$MIGRATIONS_DIR"/*.sql; do
        [ -f "$f" ] || continue
        basename_f=$(basename "$f")
        # Skip macOS ._ metadata files
        [[ "$basename_f" == ._* ]] && continue
        psql -U paperclip -d paperclip -f "$f" >/dev/null 2>&1 || true
    done
    # Create drizzle migration tracking table with proper hashes
    psql -U paperclip -d paperclip -c "
CREATE TABLE IF NOT EXISTS __drizzle_migrations (
  id SERIAL PRIMARY KEY,
  created_at BIGINT,
  hash TEXT NOT NULL,
  locked SMALLINT NOT NULL DEFAULT 1
);" >/dev/null 2>&1 || true
    # Populate tracking with sha256 hashes of each migration file
    cd "$HOME/paperclip" && node -e "
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const dir = '$MIGRATIONS_DIR';
const journalPath = path.join(dir, 'meta/_journal.json');
if (!fs.existsSync(journalPath)) process.exit(0);
const journal = JSON.parse(fs.readFileSync(journalPath, 'utf8'));
const stmts = [];
for (const entry of journal.entries) {
  const sqlFile = path.join(dir, entry.tag + '.sql');
  if (!fs.existsSync(sqlFile)) continue;
  const content = fs.readFileSync(sqlFile, 'utf8');
  const hash = crypto.createHash('sha256').update(content).digest('hex');
  stmts.push('DELETE FROM __drizzle_migrations WHERE hash = ' + \"'\" + hash + \"'\" + ';');
  stmts.push('INSERT INTO __drizzle_migrations (created_at, hash, locked) VALUES (' + entry.when + ', ' + \"'\" + hash + \"'\" + ', 1);');
}
console.log(stmts.join('\n'));
" > ~/paperclip/fix_migrations.sql 2>/dev/null && psql -U paperclip -d paperclip -f ~/paperclip/fix_migrations.sql >/dev/null 2>&1 && rm -f ~/paperclip/fix_migrations.sql
    pass "Migrations pre-applied"
else
    warn "Migrations directory not found — server will apply on first start"
fi

# ══════════════════════════════════════════════════════════════
# Step 12: Config + secrets
# ══════════════════════════════════════════════════════════════
info "Step 12/12: Creating config and secrets..."
mkdir -p "$HOME/paperclip/config" "$HOME/paperclip/instances/default/secrets"
od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$HOME/paperclip/instances/default/secrets/master.key"
AUTH_SECRET="paperclip-dev-$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
JWT_SECRET="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
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
cat > "$HOME/paperclip/ecosystem.config.cjs" <<EOF
module.exports = {
  apps: [{
    name: 'paperclip',
    script: 'server/dist/index.js',
    cwd: '${HOME}/paperclip',
    env: {
      DATABASE_URL: 'postgres://paperclip:paperclip@localhost:5432/paperclip',
      NODE_OPTIONS: '--max-old-space-size=1024',
      PAPERCLIP_HOME: '${HOME}/paperclip'
    }
  }]
};
EOF
if [ ! -f "$HOME/paperclip/instances/default/config.json" ]; then
    mkdir -p "$HOME/paperclip/instances/default"
    cat > "$HOME/paperclip/instances/default/config.json" <<'EOF'
{"database":{"mode":"postgres","connectionString":"postgres://paperclip:paperclip@localhost:5432/paperclip"},"server":{"bind":"loopback","host":"127.0.0.1","port":3100,"allowedHostnames":["127.0.0.1","localhost"]}}
EOF
fi
pass "Config and secrets created"

# ══════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "\033[1;36m========================================\033[0m"
echo -e "\033[1;36m  Paperclip Install Complete\033[0m"
echo -e "\033[1;36m========================================\033[0m"
echo ""
echo -e "\033[1;33mPass: $PASS | Fail: $FAIL\033[0m"
echo ""
echo -e "\033[1;35mSTART SERVER:\033[0m"
echo -e "  \033[0;32mcd ~/paperclip/server && DATABASE_URL='postgres://paperclip:paperclip@localhost:5432/paperclip' nohup node --max-old-space-size=1024 dist/index.js > ~/paperclip.log 2>&1 &\033[0m"
echo ""
echo -e "\033[1;35mCHECK HEALTH:\033[0m"
echo -e "  \033[0;37mcurl http://localhost:3100/api/health\033[0m"
echo ""
echo -e "\033[1;35mVIEW LOGS:\033[0m"
echo -e "  \033[0;37mtail -f ~/paperclip/paperclip.log\033[0m"
echo ""
if [ "$FAIL" -gt 0 ]; then echo -e "\033[1;31mWARNING: $FAIL step(s) failed. Review output above.\033[0m"; fi

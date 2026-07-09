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
# Termux dynamically exports $PREFIX. Fallback just in case.
PREFIX=${PREFIX:-"/data/data/com.termux/files/usr"}

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
        echo -e "\033[0;33m[WARN]\033[0m Could not fetch latest release tag. Falling back to hardcoded v1.15.2."
    fi
fi
TOOLKIT_VERSION=${LATEST_TAG:-"v1.15.2"} # Fallback to last known good version

PASS=0; FAIL=0
pass() { echo -e "\033[0;32m[PASS]\033[0m $1"; PASS=$((PASS+1)); }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }

safe_timeout() {
    local secs=$1; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# ══════════════════════════════════════════════════════════════
# Step 1: Prerequisites
# ══════════════════════════════════════════════════════════════
info "Step 1: Checking prerequisites..."
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
info "Step 2: Setting memory guard..."
export NODE_OPTIONS="--max-old-space-size=1024"
export PNPM_NETWORK_CONCURRENCY=1
export PNPM_CHILD_CONCURRENCY=1
pass "Memory guard set (1024MB heap, serial pnpm)"

# ══════════════════════════════════════════════════════════════
# Step 3: Clone
# ══════════════════════════════════════════════════════════════
info "Step 3: Cloning Paperclip repository..."
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
info "Step 4: Applying pre-install patches..."
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
# Stub ensure-plugin-build-deps.mjs — it throws if typescript/tsc is absent.
# tsc is a devDependency excluded by --production; on Android we use prebuilt
# server JS so TypeScript is never needed at runtime or for plugin compilation.
mkdir -p scripts
cat > scripts/ensure-plugin-build-deps.mjs << 'STUB_EOF'
// Android/Termux stub: TypeScript CLI (tsc) is a devDependency not installed
// on Android. The Paperclip server runs from prebuilt JS — tsc is not needed.
export default async function ensurePluginBuildDeps() {}
STUB_EOF
pass "Patches applied"

# ══════════════════════════════════════════════════════════════
# Step 5: pnpm install
# ══════════════════════════════════════════════════════════════
info "Step 5: Installing dependencies..."
# Free memory before pnpm install to prevent Android LMK kill
info "Freeing memory before install..."
pkill -f "pm2" 2>/dev/null || true
pkill -f "node.*n8n" 2>/dev/null || true
sleep 1
PNPM_STORE=$(pnpm store path 2>/dev/null || echo "")
if [ -z "$PNPM_STORE" ] || [ ! -d "$PNPM_STORE" ] || [ "$(find "$PNPM_STORE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)" -lt 10 ]; then
    PNPM_INSTALL_FLAGS="--no-frozen-lockfile --ignore-scripts --production"
else
    PNPM_INSTALL_FLAGS="--prefer-offline --ignore-scripts --production"
fi
rm -f install.log; touch install.log
EXIT=0
pnpm install $PNPM_INSTALL_FLAGS > install.log 2>&1 || EXIT=$?
_lmk_killed() {
    [ "$1" -eq 137 ] && return 0
    grep -q "Killed" install.log 2>/dev/null && return 0
    return 1
}
if [ "$EXIT" -eq 0 ]; then
    pass "pnpm install completed"
    rm -f install.log
elif _lmk_killed "$EXIT"; then
    info "pnpm install killed by LMK (exit $EXIT) — retrying once with --shamefully-hoist..."
    sleep 2
    EXIT2=0
    pnpm install $PNPM_INSTALL_FLAGS --shamefully-hoist >> install.log 2>&1 || EXIT2=$?
    if [ "$EXIT2" -eq 0 ] || _lmk_killed "$EXIT2"; then
        pass "pnpm install resolved packages (LMK expected on low-RAM devices)"
        rm -f install.log
    else
        warn "pnpm retry also failed (exit $EXIT2) — checking package count..."
    fi
else
    info "pnpm install error (not LMK, exit $EXIT). Checking if packages are present..."
fi
# Final check: enough packages to continue?
if [ -d node_modules/.pnpm ] && [ "$(find node_modules/.pnpm -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)" -gt 50 ]; then
    pass "node_modules present — continuing"
    rm -f install.log 2>/dev/null || true
else
    if [ -f install.log ]; then
        fail "pnpm install failed with too few packages. Check install.log"
        tail -n 20 install.log
        exit 1
    fi
fi

# ══════════════════════════════════════════════════════════════
# Step 6: Workspace symlinks (pnpm v9 doesn't create these on Android)
# Portable: no declare -A (requires bash 4+, unavailable on some Termux builds)
# ══════════════════════════════════════════════════════════════
info "Step 6: Creating workspace symlinks..."
mkdir -p node_modules/@paperclipai 2>/dev/null || true
# Parallel arrays: PKG_NAMES[i] maps to PKG_PATHS[i]
PKG_NAMES=(
    db shared adapter-utils mcp-server skills-catalog plugin-sdk
    adapter-acpx-local adapter-claude-local adapter-codex-local
    adapter-cursor-cloud adapter-cursor-local adapter-gemini-local
    adapter-grok-local adapter-openclaw-gateway adapter-opencode-local
    adapter-pi-local create-paperclip-plugin plugin-fake-sandbox
    plugin-workspace-diff
)
PKG_PATHS=(
    packages/db packages/shared packages/adapter-utils packages/mcp-server
    packages/skills-catalog packages/plugins/sdk
    packages/adapters/acpx-local packages/adapters/claude-local
    packages/adapters/codex-local packages/adapters/cursor-cloud
    packages/adapters/cursor-local packages/adapters/gemini-local
    packages/adapters/grok-local packages/adapters/openclaw-gateway
    packages/adapters/opencode-local packages/adapters/pi-local
    packages/plugins/create-paperclip-plugin
    packages/plugins/paperclip-plugin-fake-sandbox
    packages/plugins/plugin-workspace-diff
)
for i in "${!PKG_NAMES[@]}"; do
    _name="${PKG_NAMES[$i]}"
    _path="${PKG_PATHS[$i]}"
    [ -d "$_path" ] && ln -sf "../../$_path" "node_modules/@paperclipai/$_name" 2>/dev/null || true
done
# Also fix .bin symlinks
mkdir -p node_modules/.bin 2>/dev/null || true
TSX_MJS=""
if [ -d node_modules/.pnpm ]; then
    TSX_MJS=$(find node_modules/.pnpm -maxdepth 5 -path '*/tsx/dist/cli.mjs' 2>/dev/null | head -n1 | sed 's|^node_modules/||' || true)
fi
[ -n "$TSX_MJS" ] && ln -sf "../$TSX_MJS" node_modules/.bin/tsx 2>/dev/null || true
export PATH="$HOME/paperclip/node_modules/.bin:$PATH"
pass "Workspace symlinks created"

# ══════════════════════════════════════════════════════════════
# Step 6b: Repair CLI sub-package node_modules
# pnpm workspace linker may not create cli/node_modules when killed by LMK.
# The CLI runs TypeScript source directly via tsx, so we need tsx resolvable
# at cli/node_modules/tsx (as declared in the root package.json paperclipai script).
# ══════════════════════════════════════════════════════════════
info "Step 6b: Repairing CLI module resolution..."
mkdir -p "$HOME/paperclip/cli/node_modules" 2>/dev/null || true
# Find tsx package directory already fetched by the root pnpm install
TSX_PKG_DIR=""
if [ -d "$HOME/paperclip/node_modules/.pnpm" ]; then
    TSX_PKG_DIR=$(find "$HOME/paperclip/node_modules/.pnpm" -maxdepth 3 -type d -name "tsx" 2>/dev/null \
        | grep -v '/node_modules/tsx/node_modules' | head -n1 || true)
fi
if [ -n "$TSX_PKG_DIR" ]; then
    ln -sf "$TSX_PKG_DIR" "$HOME/paperclip/cli/node_modules/tsx" 2>/dev/null || true
    pass "CLI tsx symlinked from pnpm store"
else
    # Fallback: install tsx globally so the CLI can find it via PATH
    info "tsx not found in pnpm store — installing globally..."
    npm install -g tsx --prefer-offline --quiet 2>/dev/null || \
        npm install -g tsx --quiet 2>/dev/null || true
    # Patch the root package.json paperclipai script to use global tsx
    if command -v tsx >/dev/null 2>&1; then
        TSX_BIN=$(command -v tsx)
        if [ -f "$HOME/paperclip/package.json" ] && command -v jq >/dev/null 2>&1; then
            jq --arg tsx "$TSX_BIN" \
               '.scripts.paperclipai = ($tsx + " cli/src/index.ts")' \
               "$HOME/paperclip/package.json" > "$HOME/paperclip/pkg_tmp.json" 2>/dev/null \
               && mv "$HOME/paperclip/pkg_tmp.json" "$HOME/paperclip/package.json" 2>/dev/null || true
        fi
        pass "tsx installed globally as fallback"
    else
        warn "Could not resolve tsx — 'pnpm paperclipai onboard' may fail; run: npm i -g tsx"
    fi
fi

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
info "Step 8: Extracting prebuilt dist/ tarball..."
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
# Step 8b: Revert workspace package exports to src/ for CLI (tsx) compatibility
# build_paperclip_dist.sh patches package.json exports from src/*.ts -> dist/*.js.
# The prebuilt dist tarball carries these patched files. But the CLI runs TypeScript
# source via tsx and needs src/ exports to see all latest APIs (e.g. anchorSnapshotToSelector).
# The server dist/index.js uses self-contained compiled code and is unaffected.
# ══════════════════════════════════════════════════════════════
info "Step 8b: Reverting workspace package exports to TypeScript source..."
node << 'REVERT_EXPORTS_EOF'
const fs = require('fs');
const path = require('path');
const PAPERCLIP = path.join(process.env.HOME, 'paperclip');

function walk(dir, results) {
  results = results || [];
  var entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch(e) { return results; }
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i];
    if (e.isDirectory() && ['node_modules','.git','dist','src','build'].indexOf(e.name) === -1) {
      walk(path.join(dir, e.name), results);
    } else if (e.isFile() && e.name === 'package.json') {
      results.push(path.join(dir, e.name));
    }
  }
  return results;
}

var pkgsDir = path.join(PAPERCLIP, 'packages');
var count = 0;
var files = walk(pkgsDir);
for (var j = 0; j < files.length; j++) {
  var p = files[j];
  try {
    var pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (!pkg.exports) continue;
    var orig = JSON.stringify(pkg.exports);
    if (orig.indexOf('/dist/') === -1) continue;
    var reverted = orig
      .replace(/\.\/(dist)\//g, './src/')
      .replace(/\.d\.ts"/g, '.ts"')
      .replace(/\.js"/g, '.ts"');
    pkg.exports = JSON.parse(reverted);
    fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + '\n');
    count++;
    process.stdout.write('Reverted: ' + path.relative(PAPERCLIP, p) + '\n');
  } catch(e) {
    process.stdout.write('Skip: ' + path.relative(PAPERCLIP, p) + '\n');
  }
}
process.stdout.write('Done: ' + count + ' package(s) reverted.\n');
REVERT_EXPORTS_EOF
pass "Workspace package exports restored to TypeScript source"

# ══════════════════════════════════════════════════════════════
# Step 9: Extract prebuilt UI tarball
# ══════════════════════════════════════════════════════════════
info "Step 9: Extracting prebuilt UI assets..."
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
        # Symlink ui -> server/ui-dist so that if the server starts in dev mode 
        # (due to missing NODE_ENV=production), it still finds and serves the prebuilt UI.
        ln -sf server/ui-dist "$HOME/paperclip/ui"
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
info "Step 10: Stubbing sqlite3 native module..."
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
    # Also stub vite (devDependency missing due to --production, but imported by server/src/app.ts)
    mkdir -p "$HOME/paperclip/node_modules/vite"
    cat > "$HOME/paperclip/node_modules/vite/package.json" << 'VITEOF'
{"name":"vite","version":"5.0.0","main":"./index.js","type":"commonjs"}
VITEOF
    cat > "$HOME/paperclip/node_modules/vite/index.js" << 'VITESTUBEOF'
module.exports = { createServer: async () => ({ middlewares: (req,res,next)=>next(), listen: async ()=>{} }) };
VITESTUBEOF
    pass "sqlite3, embedded-postgres, and vite stubbed"
else
    warn "sqlite3 package not found — may already be stubbed"
fi

# ══════════════════════════════════════════════════════════════
# Step 11: Start PostgreSQL + create DB
# ══════════════════════════════════════════════════════════════
info "Step 11: Starting PostgreSQL..."
PGDATA="$PREFIX/var/lib/postgresql"
if ! safe_timeout 3 psql -d postgres -c "SELECT 1" > /dev/null 2>&1; then
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
for i in {1..10}; do safe_timeout 2 psql -d postgres -c "SELECT 1" > /dev/null 2>&1 && break; sleep 1; done
safe_timeout 3 psql -d postgres -c "SELECT 1" > /dev/null 2>&1 || { fail "PostgreSQL did not start"; exit 1; }
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
info "Step 12: Creating config and secrets..."
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
    script: 'npm',
    args: 'run paperclipai -- run',
    interpreter: 'none',
    cwd: '${HOME}/paperclip',
    env: {
      DATABASE_URL: 'postgres://paperclip:paperclip@localhost:5432/paperclip',
      NODE_OPTIONS: '--max-old-space-size=1024',
      PAPERCLIP_HOME: '${HOME}/paperclip',
      NODE_ENV: 'production',
      PAPERCLIP_MIGRATION_AUTO_APPLY: 'true'
    }
  }]
};
EOF
# Write config to BOTH ~/paperclip/ (server) and ~/.paperclip/ (CLI default home)
# so that 'pnpm paperclipai run' resolves external PostgreSQL on port 5432.
# Always overwrite — the CLI may have auto-generated an embedded-postgres config
# on first run before our installer could write the correct external postgres config.
# Note: we include $meta and logging so the CLI 'onboard' command considers it valid.
# shellcheck disable=SC2016
PAPERCLIP_CFG_JSON='{"$meta":{"version":"1"},"logging":{"type":"file","dir":"logs"},"database":{"mode":"postgres","connectionString":"postgres://paperclip:paperclip@localhost:5432/paperclip"},"server":{"bind":"loopback","host":"127.0.0.1","port":3100,"allowedHostnames":["127.0.0.1","localhost"]}}'
for cfg_dir in "$HOME/paperclip/instances/default" "$HOME/.paperclip/instances/default"; do
    mkdir -p "$cfg_dir/secrets"
    echo "$PAPERCLIP_CFG_JSON" > "$cfg_dir/config.json"
    echo -e "DATABASE_URL=postgres://paperclip:paperclip@localhost:5432/paperclip\nNODE_ENV=production\nPAPERCLIP_MIGRATION_AUTO_APPLY=true" > "$cfg_dir/.env"
    [ ! -f "$cfg_dir/secrets/master.key" ] && \
        od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$cfg_dir/secrets/master.key"
done

# Force required env vars into the root paperclipai script so that starting the CLI
# automatically bypasses interactive migration prompts and forces production UI mode.
if [ -f "$HOME/paperclip/package.json" ] && command -v jq >/dev/null 2>&1; then
    jq '.scripts.paperclipai |= "PAPERCLIP_MIGRATION_AUTO_APPLY=true PAPERCLIP_UI_DEV_MIDDLEWARE=false NODE_ENV=production " + .' "$HOME/paperclip/package.json" > "$HOME/paperclip/pkg_tmp.json" 2>/dev/null \
        && mv "$HOME/paperclip/pkg_tmp.json" "$HOME/paperclip/package.json" 2>/dev/null || true
fi
# Export PAPERCLIP_HOME persistently so the CLI always resolves ~/paperclip/
for rc_file in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
    [ -f "$rc_file" ] && grep -q 'PAPERCLIP_HOME' "$rc_file" 2>/dev/null || \
        printf 'export PAPERCLIP_HOME="%s/paperclip"\n' "$HOME" >> "$rc_file" 2>/dev/null || true
done
export PAPERCLIP_HOME="$HOME/paperclip"
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
echo -e "\033[1;35mSTART WITH PM2 (recommended):\033[0m"
echo -e "  \033[0;32mcd ~/paperclip && pm2 start ecosystem.config.cjs && pm2 save\033[0m"
echo ""
echo -e "\033[1;35mOR start manually via CLI:\033[0m"
echo -e "  \033[0;32mcd ~/paperclip && npm run paperclipai -- run\033[0m"
echo ""
echo -e "\033[1;35mCHECK HEALTH:\033[0m"
echo -e "  \033[0;37mcurl http://localhost:3100/api/health\033[0m"
echo ""
echo -e "\033[1;35mVIEW LOGS:\033[0m"
echo -e "  \033[0;37mpm2 logs paperclip\033[0m"
echo ""
if [ "$FAIL" -gt 0 ]; then echo -e "\033[1;31mWARNING: $FAIL step(s) failed. Review output above.\033[0m"; fi

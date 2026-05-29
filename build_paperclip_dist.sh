#!/bin/bash
# build_paperclip_dist.sh — Build working Paperclip tarballs for Android/Termux
# Run this on your local Mac from the droid-ai-toolkit directory.
# Produces: assets/paperclip-dist-v0.3.1.tar.gz (server + packages dist)
#           assets/paperclip-ui-dist-v0.3.1.tar.gz (UI dist)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAPERCLIP_DIR="${PAPERCLIP_DIR:-$HOME/paperclip}"
ASSETS_DIR="$SCRIPT_DIR/assets"
VERSION="0.3.1"

red()   { echo -e "\033[0;31m$*\033[0m"; }
green() { echo -e "\033[0;32m$*\033[0m"; }
blue()  { echo -e "\033[0;34m$*\033[0m"; }

# ─── Step 1: Ensure Paperclip repo exists and is up to date ───
if [ ! -d "$PAPERCLIP_DIR/.git" ]; then
    blue "Cloning Paperclip repo..."
    git clone --depth 1 https://github.com/paperclipai/paperclip.git "$PAPERCLIP_DIR"
else
    blue "Updating Paperclip repo..."
    cd "$PAPERCLIP_DIR" || { red "Cannot cd to $PAPERCLIP_DIR"; exit 1; }
    git pull --ff-only || git reset --hard origin/master
fi
cd "$PAPERCLIP_DIR" || exit 1

# ─── Step 2: Patch all package.json exports (src/*.ts → dist/*.js) ───
blue "Patching package.json exports..."
node -e "
const fs = require('fs');
const path = require('path');

function findPackages(dir) {
    const results = [];
    try {
        for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
            if (!item.isDirectory() || item.name.startsWith('.') || item.name === 'node_modules') continue;
            const full = path.join(dir, item.name);
            const pkgPath = path.join(full, 'package.json');
            if (fs.existsSync(pkgPath)) results.push(full);
            results.push(...findPackages(full));
        }
    } catch {}
    return results;
}

let patched = 0;
for (const pkgDir of findPackages('.')) {
    const pkgPath = path.join(pkgDir, 'package.json');
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
    const exports = pkg.exports || {};
    const hasBad = Object.values(exports).some(v =>
        typeof v === 'string' && v.includes('/src/')
    ) || (exports['.'] && typeof exports['.'] === 'object' && exports['.'].import && exports['.'].import.includes('/src/'));
    if (!hasBad) continue;

    if (pkg.publishConfig?.exports) {
        pkg.exports = pkg.publishConfig.exports;
    } else {
        for (const [key, val] of Object.entries(exports)) {
            if (typeof val === 'string' && val.includes('/src/')) {
                exports[key] = {
                    types: val.replace('/src/', '/dist/').replace(/\.ts$/, '.d.ts'),
                    import: val.replace('/src/', '/dist/').replace(/\.ts$/, '.js')
                };
            }
        }
        pkg.exports = exports;
    }
    fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
    patched++;
}
console.log('Patched ' + patched + ' package.json files');
"

# ─── Step 3: Install deps (skip scripts) and build ───
blue "Installing dependencies (skip scripts)..."
export NODE_OPTIONS="--max-old-space-size=2048"
pnpm install --ignore-scripts --no-frozen-lockfile 2>/dev/null || pnpm install --ignore-scripts

blue "Building TypeScript..."
pnpm -r run build 2>/dev/null || {
    blue "pnpm -r run build failed, trying selective build..."
    for pkg in packages/db packages/shared packages/adapter-utils packages/mcp-server packages/plugins/sdk; do
        [ -d "$pkg" ] && cd "$PAPERCLIP_DIR/$pkg" && pnpm build 2>/dev/null || true
        cd "$PAPERCLIP_DIR"
    done
    for pkg in packages/adapters/*/; do
        [ -d "${pkg}dist" ] || (cd "$PAPERCLIP_DIR/$pkg" && pnpm build 2>/dev/null || true)
        cd "$PAPERCLIP_DIR"
    done
    for pkg in packages/plugins/*/; do
        [ -d "${pkg}dist" ] || (cd "$PAPERCLIP_DIR/$pkg" && pnpm build 2>/dev/null || true)
        cd "$PAPERCLIP_DIR"
    done
    cd "$PAPERCLIP_DIR/server" && pnpm build 2>/dev/null || true
    cd "$PAPERCLIP_DIR"
}

# ─── Step 4: Build UI ───
blue "Building UI..."
if [ -d "$PAPERCLIP_DIR/ui" ]; then
    (cd "$PAPERCLIP_DIR/ui" && pnpm install --ignore-scripts 2>/dev/null && pnpm build 2>/dev/null) || {
        blue "UI build failed — skipping"
    }
fi

# ─── Step 5: Create server dist tarball ───
blue "Creating server dist tarball..."
mkdir -p "$ASSETS_DIR"
DIST_TMP=$(mktemp -d)
trap 'rm -rf "$DIST_TMP"' EXIT

# Copy server dist
cp -R server/dist "$DIST_TMP/server-dist/"
cp server/package.json "$DIST_TMP/server-dist/"

# Copy all package dist folders and their package.json
for pkg in packages/db packages/shared packages/adapter-utils packages/mcp-server packages/plugins/sdk packages/skills-catalog; do
    [ -d "$pkg/dist" ] && { mkdir -p "$DIST_TMP/$(dirname $pkg)"; cp -R "$pkg" "$DIST_TMP/$pkg"; } || true
done
for pkg in packages/adapters/*/; do
    [ -d "${pkg}dist" ] && { mkdir -p "$DIST_TMP/$pkg"; cp -R "${pkg}dist" "$DIST_TMP/${pkg}dist"; cp "$pkg/package.json" "$DIST_TMP/$pkg/"; } || true
done
for pkg in packages/plugins/*/; do
    [ -d "${pkg}dist" ] && { mkdir -p "$DIST_TMP/$pkg"; cp -R "${pkg}dist" "$DIST_TMP/${pkg}dist"; cp "$pkg/package.json" "$DIST_TMP/$pkg/"; } || true
done

# Remove macOS ._ metadata files before creating tarball
find "$DIST_TMP" -name '._*' -delete 2>/dev/null || true

# Create tarball
COPYFILE_DISABLE=1 tar -czf "$ASSETS_DIR/paperclip-dist-v${VERSION}.tar.gz" -C "$DIST_TMP" .
green "Created: $ASSETS_DIR/paperclip-dist-v${VERSION}.tar.gz"

# ─── Step 6: Create UI dist tarball ───
if [ -d ui/dist ]; then
    COPYFILE_DISABLE=1 tar -czf "$ASSETS_DIR/paperclip-ui-dist-v${VERSION}.tar.gz" -C ui/dist .
    green "Created: $ASSETS_DIR/paperclip-ui-dist-v${VERSION}.tar.gz"
else
    blue "No ui/dist found — skipping UI tarball"
fi

# ─── Step 7: Create device setup script ───
blue "Creating device setup script..."
cat > "$ASSETS_DIR/paperclip-device-setup.sh" << 'SETUP_EOF'
#!/bin/bash
# paperclip-device-setup.sh — Run this on the Termux device after extracting tarballs
# Usage: bash paperclip-device-setup.sh
set -euo pipefail

PC_DIR="$HOME/paperclip"

red()   { echo -e "\033[0;31m$*\033[0m"; }
green() { echo -e "\033[0;32m$*\033[0m"; }
blue()  { echo -e "\033[0;34m$*\033[0m"; }

# ─── Prerequisites ───
for cmd in node pnpm pg_ctl; do
    command -v $cmd >/dev/null 2>&1 || { red "Missing: $cmd — install via pkg"; exit 1; }
done

# ─── Create workspace symlinks (pnpm v9 doesn't do this on Android) ───
blue "Creating workspace symlinks..."
mkdir -p "$PC_DIR/node_modules/@paperclipai"

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
    if [ -d "$PC_DIR/$target" ]; then
        ln -sf "../../$target" "$PC_DIR/node_modules/@paperclipai/$name" 2>/dev/null || true
    fi
done
green "Workspace symlinks created"

# ─── Stub sqlite3 (can't compile native module on Android) ───
blue "Stubbing sqlite3 native module..."
SQLITE3_DIR="$PC_DIR/node_modules/.pnpm/sqlite3@5.1.7/node_modules/sqlite3"
mkdir -p "$SQLITE3_DIR/build" "$SQLITE3_DIR/lib"
cat > "$SQLITE3_DIR/package.json" << 'PKGEOF'
{"name":"sqlite3","version":"5.1.7","main":"./lib/sqlite3.js","type":"commonjs"}
PKGEOF
cat > "$SQLITE3_DIR/lib/sqlite3.js" << 'JSEOF'
// Stub: sqlite3 native module (PostgreSQL backend, not needed)
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
green "sqlite3 stub created"

# ─── Ensure embedded-postgres is not loaded ───
EMBED_DIR="$PC_DIR/node_modules/.pnpm/embedded-postgres@18.1.0-beta.16/node_modules/embedded-postgres"
if [ -d "$EMBED_DIR" ]; then
    mkdir -p "$PC_DIR/node_modules/embedded-postgres"
    cat > "$PC_DIR/node_modules/embedded-postgres/package.json" << 'EMBEOF'
{"name":"embedded-postgres","version":"0.0.0","main":"./stub.js","type":"commonjs"}
EMBEOF
    cat > "$PC_DIR/node_modules/embedded-postgres/stub.js" << 'STUBEOF'
// Stub: embedded-postgres not supported on Android
module.exports = class EmbeddedPostgres { start() { return Promise.resolve(); } stop() { return Promise.resolve(); } };
STUBEOF
    green "embedded-postgres stubbed"
fi

# ─── Ensure PostgreSQL is running ───
PGDATA="$PREFIX/var/lib/postgresql"
if ! timeout 3 psql -d postgres -c "SELECT 1" > /dev/null 2>&1; then
    blue "Starting PostgreSQL..."
    if [ ! -f "$PGDATA/PG_VERSION" ]; then
        pg_ctl -D "$PGDATA" initdb -U "$(whoami)" > /dev/null 2>&1 || true
    fi
    pg_ctl -D "$PGDATA" start -l "$HOME/paperclip/postgres.log" > /dev/null 2>&1 || true
    sleep 3
fi
for i in {1..10}; do
    timeout 2 psql -d postgres -c "SELECT 1" > /dev/null 2>&1 && break
    sleep 1
done
timeout 3 psql -d postgres -c "SELECT 1" > /dev/null 2>&1 || { red "PostgreSQL failed to start"; exit 1; }
psql -d postgres -c "CREATE USER paperclip WITH PASSWORD 'paperclip';" 2>/dev/null || true
psql -d postgres -c "CREATE DATABASE paperclip OWNER paperclip;" 2>/dev/null || true
green "PostgreSQL ready"

# ─── Start Paperclip ───
blue "Starting Paperclip server..."
cd "$PC_DIR/server"
export DATABASE_URL="postgresql://localhost:5432/paperclip"
nohup node --max-old-space-size=1024 dist/index.js > "$PC_DIR/paperclip.log" 2>&1 &
echo "PID: $!"
sleep 12

if curl -s http://localhost:3100/api/health > /dev/null 2>&1; then
    green "Paperclip is running on http://localhost:3100"
    curl -s http://localhost:3100/api/health | head -c 200
    echo ""
else
    red "Server may still be starting. Check: cat ~/paperclip/paperclip.log"
fi
SETUP_EOF
chmod +x "$ASSETS_DIR/paperclip-device-setup.sh"
green "Created: $ASSETS_DIR/paperclip-device-setup.sh"

green "=== Build complete ==="
blue "Tarballs ready in: $ASSETS_DIR/"
blue "To deploy to device:"
blue "  1. rsync assets/paperclip-dist-v${VERSION}.tar.gz 8x:~/"
blue "  2. rsync assets/paperclip-ui-dist-v${VERSION}.tar.gz 8x:~/"
blue "  3. rsync assets/paperclip-device-setup.sh 8x:~/"
blue "  4. ssh 8x 'tar -xzf ~/paperclip-dist-v${VERSION}.tar.gz -C ~/paperclip/ && tar -xzf ~/paperclip-ui-dist-v${VERSION}.tar.gz -C ~/paperclip/server/ui-dist/ && bash ~/paperclip-device-setup.sh'"

# ─── Optional: Publish to GitHub release ───
if [ "${1:-}" == "--publish" ]; then
    TAG="${2:-paperclip-${VERSION}}"
    REPO="niyazmft/droid-ai-toolkit"
    if ! command -v gh >/dev/null 2>&1; then
        red "GitHub CLI (gh) not installed. Install: brew install gh"
        exit 1
    fi
    blue "Publishing to GitHub release: $TAG"
    # Create release if it doesn't exist
    gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || \
        gh release create "$TAG" --repo "$REPO" --title "Paperclip ${VERSION}" --notes "Paperclip ${VERSION} prebuilt tarballs for Android/Termux"
    # Upload tarballs
    gh release upload "$TAG" \
        "$ASSETS_DIR/paperclip-dist-v${VERSION}.tar.gz" \
        "$ASSETS_DIR/paperclip-ui-dist-v${VERSION}.tar.gz" \
        --repo "$REPO" --clobber
    green "Published to: https://github.com/$REPO/releases/tag/$TAG"
fi

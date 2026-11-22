#!/bin/bash
# lib/steps/tool_project.sh -- one pnpm project per tool.
#
# Why this exists: in the global layout every tool shares one package.json and one
# node_modules, so installing anything reconciles everything. On 8x that meant
# installing Pi also installed n8n and openclaw (2 192 packages, ~5 min), purged
# node_modules first, and a kill in that window broke every tool at once
# (2026-11-22).
#
# Here each tool gets its own project under <pnpm-home>/tools/<tool>. The content
# store stays shared, so nothing is downloaded twice. Installing Pi touches only
# tools/pi, and a failure costs Pi.
#
# Layout:
#   ~/.local/share/pnpm/store/v3              shared content store
#   ~/.local/share/pnpm/tools/<tool>/         package.json + node_modules (per tool)
#   $PREFIX/bin/<bin>                         exec wrapper -> that tool's binary

tool_root() {
    printf '%s/tools' "${PNPM_TOOL_ROOT:-$HOME/.local/share/pnpm}"
}

tool_dir() {
    printf '%s/%s' "$(tool_root)" "$1"
}

step_pnpm_tool() {
    local step="$1" tool name spec dir current heap rc backup=""
    tool=$(printf '%s' "$step" | jq -r '.args.tool // empty')
    name=$(printf '%s' "$step" | jq -r '.args.name // empty')
    spec=$(printf '%s' "$step" | jq -r '.args.spec // "latest"')

    if [ -z "$tool" ] || [ -z "$name" ]; then
        echo "step_pnpm_tool: args.tool and args.name are required"
        return 1
    fi
    if ! command -v pnpm >/dev/null 2>&1; then
        echo "step_pnpm_tool: pnpm is not on PATH"
        return 2
    fi

    dir=$(tool_dir "$tool")
    mkdir -p "$dir" || return 1
    if [ ! -f "$dir/package.json" ]; then
        printf '{\n  "name": "%s",\n  "private": true\n}\n' "$tool" > "$dir/package.json" || return 1
    fi

    if [ "$spec" = "latest" ] || [ -z "$spec" ]; then
        local resolved
        resolved=$(npm view "$name" version 2>/dev/null | tail -1)
        [ -n "$resolved" ] && spec="^$resolved"
    fi

    current=$(jq -r --arg n "$name" '.dependencies[$n] // empty' "$dir/package.json" 2>/dev/null)
    if [ -n "$current" ] && [ "$current" = "$spec" ] && [ -e "$dir/node_modules/$name" ]; then
        echo "already installed in $dir: $name@$current"
        _pnpm_link_bins "$dir"
        return 0
    fi

    # Record the dependency without touching the tree yet.
    local tmp
    tmp=$(mktemp)
    if jq --arg n "$name" --arg s "$spec" \
        '.dependencies = ((.dependencies // {}) + {($n): $s})' \
        "$dir/package.json" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$dir/package.json"
    else
        rm -f "$tmp"
        echo "step_pnpm_tool: could not update $dir/package.json"
        return 1
    fi

    # Snapshot: pnpm purges node_modules before relinking, so a kill would leave
    # this tool broken. Rename (O(1)) and restore on failure.
    if [ -d "$dir/node_modules" ] && [ -n "$(ls -A "$dir/node_modules" 2>/dev/null)" ]; then
        backup="$dir/.node_modules.snapshot.$$"
        mv "$dir/node_modules" "$backup" 2>/dev/null || backup=""
    fi

    local -a flags=()
    if _fs_supports_hardlink "$dir"; then
        flags+=(--package-import-method=hardlink)
    else
        echo "hardlinks unavailable: copying from the store (slower, ~2x disk)"
    fi

    heap=$(pnpm_heap_limit)
    export NODE_OPTIONS="--dns-result-order=ipv4first --max-old-space-size=$heap"
    echo "tool=$tool dir=$dir heap=${heap}MB MemAvailable=$(awk '/^MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)MB"

    echo "phase 1/2: resolve"
    ( cd "$dir" && pnpm install --lockfile-only --ignore-scripts "${flags[@]}" )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "phase 2/2: install"
        ( cd "$dir" && pnpm install --frozen-lockfile --ignore-scripts \
            --child-concurrency=1 --network-concurrency=1 \
            "${flags[@]}" --config.confirmModulesPurge=false )
        rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        if [ -n "$backup" ]; then
            rm -rf "$dir/node_modules" 2>/dev/null
            mv "$backup" "$dir/node_modules" 2>/dev/null \
                && echo "install failed (rc=$rc) — previous node_modules restored" \
                || echo "install failed (rc=$rc) and restore failed: $backup"
        else
            echo "install failed (rc=$rc) — no snapshot was available"
        fi
        _pnpm_link_bins "$dir"
        return "$rc"
    fi

    [ -n "$backup" ] && ( rm -rf "$backup" >/dev/null 2>&1 & )
    _pnpm_link_bins "$dir"
    echo "installed $name into $dir"
    return 0
}

# step_pm2_stop <step-json> -- stop a service without starting the PM2 daemon.
step_pm2_stop() {
    local step="$1" name
    name=$(printf '%s' "$step" | jq -r '.args.name // empty')
    [ -n "$name" ] || return 0
    command -v pm2 >/dev/null 2>&1 || return 0
    [ -f "$HOME/.pm2/pm2.pid" ] || return 0
    pm2 stop "$name" 2>/dev/null || true
    echo "stopped $name (if it was running)"
}

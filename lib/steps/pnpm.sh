#!/bin/bash
# lib/steps/pnpm.sh -- global pnpm installs, without the TUI.
#
# Two-phase install, for the reason install.sh already documents: one
# `pnpm add -g` resolves, downloads and links in a single process, and on a
# 1.8 GB device that peak is what Android's memory killer takes. Resolve first,
# then install from the lockfile.
#
# A global install is NOT a small operation. `pnpm install` reconciles the whole
# manifest, so adding one tool also installs every other declared dependency
# (on 8x: pi + n8n + openclaw ≈ 2 200 packages, ~5 minutes, and it PURGES
# node_modules before relinking). A kill mid-link therefore leaves the global
# project empty and every tool broken — observed on 8x, 2026-11-22. Hence the
# snapshot/restore below: node_modules is renamed aside (O(1) on the same
# filesystem) and renamed back if the install fails.

# _pnpm_link_bins <global-project-dir>
# Write shims that invoke the binary directly.
#
# pnpm's own global shim resolves its package path from $0 and, on this device's
# isolated layout, it spun at ~50% CPU for 14 minutes on `n8n --version` without
# ever exec'ing node (measured on 8x, 2026-11-22). Invoking the resolved target
# with node directly works and is what `node <realpath>/bin/n8n --version`
# proved. So: resolve .bin/<name> and write an exec wrapper around the target,
# never around the shim.
_pnpm_link_bins() {
    local dir="$1" bin base target dest line
    local -a dests=()

    local gbin
    gbin=$(pnpm bin -g 2>/dev/null | tail -1)
    [ -n "$gbin" ] && [ -d "$gbin" ] && dests+=("$gbin")
    [ -n "${TERMUX_BIN:-}" ] && [ -d "$TERMUX_BIN" ] && dests+=("$TERMUX_BIN")

    for bin in "$dir/node_modules/.bin"/*; do
        [ -e "$bin" ] || continue
        base=$(basename "$bin")
        target=$(readlink -f "$bin" 2>/dev/null) || continue
        [ -n "$target" ] || continue

        case "$target" in
            *.js|*.mjs|*.cjs) line="exec node \"$target\" \"\$@\"" ;;
            *)                line="exec \"$target\" \"\$@\"" ;;
        esac

        for dest in "${dests[@]}"; do
            printf '#!/data/data/com.termux/files/usr/bin/sh\n%s\n' "$line" > "$dest/.toolkit-bin-$$" \
                && chmod +x "$dest/.toolkit-bin-$$" \
                && mv -f "$dest/.toolkit-bin-$$" "$dest/$base" \
                && echo "shim: $dest/$base -> $(basename "$target")"
        done
    done
}

step_pnpm_global() {
    local step="$1"
    local name spec dir current heap rc backup=""
    name=$(printf '%s' "$step" | jq -r '.args.name // empty')
    spec=$(printf '%s' "$step" | jq -r '.args.spec // "latest"')

    if [ -z "$name" ]; then
        echo "step_pnpm_global: missing args.name"
        return 1
    fi
    if ! command -v pnpm >/dev/null 2>&1; then
        echo "step_pnpm_global: pnpm is not on PATH"
        return 2
    fi

    dir=$(pnpm_global_project_dir) || {
        echo "step_pnpm_global: cannot resolve the pnpm global project"
        return 1
    }

    # Turn a moving dist-tag into a concrete version so the manifest records
    # `^1.2.3` instead of `latest` forever.
    if [ "$spec" = "latest" ] || [ -z "$spec" ]; then
        local resolved
        resolved=$(npm view "$name" version 2>/dev/null | tail -1)
        [ -n "$resolved" ] && spec="^$resolved"
    fi

    # Already at the requested spec? A global install costs minutes and purges
    # node_modules; doing it because a button was pressed twice is not acceptable.
    current=$(jq -r --arg n "$name" '.dependencies[$n] // empty' "$dir/package.json" 2>/dev/null)
    if [ -n "$current" ] && [ "$current" = "$spec" ] && [ -e "$dir/node_modules/$name" ]; then
        echo "already installed: $name@$current — skipping the reconcile"
        _pnpm_link_bins "$dir"
        return 0
    fi

    pnpm_set_global_dep "$name" "$spec" || return 1
    pnpm_repair_global_store || true

    # Snapshot before pnpm purges. Rename, not copy: same filesystem, O(1).
    if [ -d "$dir/node_modules" ] && [ -n "$(ls -A "$dir/node_modules" 2>/dev/null)" ]; then
        backup="$dir/.node_modules.snapshot.$$"
        if mv "$dir/node_modules" "$backup" 2>/dev/null; then
            echo "snapshot: node_modules -> $(basename "$backup")"
        else
            backup=""
            echo "warning: could not snapshot node_modules; a failed install will leave it empty"
        fi
    fi

    local -a flags=(--config.virtual-store-dir="$dir/.pnpm")
    if _fs_supports_hardlink "$(pnpm_root_g)"; then
        flags+=(--package-import-method=hardlink)
    else
        echo "hardlinks unavailable: installing by copy (needs ~2x disk, and it is slow)"
    fi

    heap=$(pnpm_heap_limit)
    export NODE_OPTIONS="--dns-result-order=ipv4first --max-old-space-size=$heap"
    echo "heap cap: ${heap}MB, MemAvailable $(awk '/^MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)MB"
    echo "note: a global install reconciles every dependency in $(basename "$dir")/package.json"

    echo "phase 1/2: resolve the dependency graph"
    ( cd "$dir" && pnpm install --lockfile-only --ignore-scripts "${flags[@]}" )
    rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "phase 2/2: install from the lockfile"
        ( cd "$dir" && pnpm install --frozen-lockfile --ignore-scripts \
            --child-concurrency=1 --network-concurrency=1 \
            "${flags[@]}" --config.confirmModulesPurge=false )
        rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        # Leave the device working. A half-linked global project breaks every tool
        # that depends on it, not just the one being installed.
        if [ -n "$backup" ]; then
            rm -rf "$dir/node_modules" 2>/dev/null
            if mv "$backup" "$dir/node_modules" 2>/dev/null; then
                echo "install failed (rc=$rc) — previous node_modules restored"
            else
                echo "install failed (rc=$rc) AND the snapshot could not be restored: $backup"
            fi
        else
            echo "install failed (rc=$rc) — no snapshot was available"
        fi
        _pnpm_link_bins "$dir"
        return "$rc"
    fi

    # Success: drop the snapshot in the background rather than block the action.
    if [ -n "$backup" ]; then
        ( rm -rf "$backup" >/dev/null 2>&1 & )
    fi

    _pnpm_link_bins "$dir"
    echo "installed $name"
    return 0
}

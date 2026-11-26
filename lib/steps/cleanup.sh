#!/bin/bash
# lib/steps/cleanup.sh -- remove the legacy shared pnpm project.

# step_cleanup_global_project -- delete <pnpm-home>/global and the shims that point
# into it, but only once every migrated tool is present under tools/.
#
# Order matters. The global install left thousands of bins in $PREFIX/bin (acorn, axe,
# chroma, …) whose wrappers exec into global/5/node_modules. Removing the project first
# would leave every one of them dangling, so this walks the shims, deletes only those
# that name the legacy path, and only then removes the tree.
step_cleanup_global_project() {
    local g="$HOME/.local/share/pnpm/global"
    local t bin removed=0 mb_before=0 mb_after=0

    # The same guard the spec declares as a predicate, so a direct invocation cannot bypass
    # it. The message names the tool the user has to migrate first.
    if ! pred_tools_migrated; then
        for t in pi n8n openclaw gemini; do
            if [ ! -d "$(tool_dir "$t")/node_modules" ]; then
                echo "refusing: $t is not installed under tools/ — migrate it first"
                break
            fi
        done
        return 1
    fi

    if [ ! -d "$g" ]; then
        echo "nothing to do: $g is already absent"
        _cleanup_report 0 0
        return 0
    fi

    mb_before=$(_cleanup_mb "$g")

    # Never touch a shim the toolkit itself depends on. `pm2` is the load-bearing
    # example: the supervisor restarts services through it, and a cleanup that removed
    # it would take the recovery path down with the thing it was cleaning up after.
    local protected=" pm2 pm2-runtime node npm pnpm npx corepack bash sh sshd ssh git jq curl wget python3 pip3 termux-wake-lock "
    local base
    for bin in "$TERMUX_BIN"/*; do
        [ -f "$bin" ] || continue
        base=$(basename "$bin")
        case "$protected" in *" $base "*) continue ;; esac
        head -c 400 "$bin" 2>/dev/null | grep -q "$HOME/.local/share/pnpm/global/" || continue
        rm -f "$bin" && removed=$((removed + 1))
    done
    echo "removed $removed legacy shim(s)"

    rm -rf "$g" && echo "removed $g"
    mb_after=$(_cleanup_mb "$g")
    _cleanup_report "$((mb_before - mb_after))" "$removed"
    return 0
}

# _cleanup_mb <path> -- size in whole MB, 0 when du cannot answer.
#
# `du -sm` is one process either side of the delete, which is worth it: "Reclaimed 12.9 GB"
# is the only part of this action a user can see, and it is what distinguishes "it worked"
# from "it told me done and nothing changed" (which happened on 8x).
_cleanup_mb() {
    local mb
    mb=$(du -sm "$1" 2>/dev/null | awk '{print $1; exit}')
    case "$mb" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$mb" ;;
    esac
}

# _cleanup_report <reclaimed_mb> <shims> -- the `data` payload for the app.
#
# Kept separate so the "nothing to do" path reports the same shape: a client should not have
# to branch on whether anything was removed before reading the numbers.
_cleanup_report() {
    local reclaimed="${1:-0}" shims="${2:-0}"
    [ -n "${RUNNER_RESULT:-}" ] || return 0
    jq -nc --argjson mb "$reclaimed" --argjson shims "$shims" \
        '{reclaimed_mb: $mb, shims: $shims}' > "$RUNNER_RESULT" 2>/dev/null || true
}

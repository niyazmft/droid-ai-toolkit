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
    local t bin removed=0

    for t in pi n8n openclaw gemini; do
        if [ ! -d "$(tool_dir "$t")/node_modules" ]; then
            echo "refusing: $t is not installed under tools/ — migrate it first"
            return 1
        fi
    done

    if [ ! -d "$g" ]; then
        echo "nothing to do: $g is already absent"
        return 0
    fi

    for bin in "$TERMUX_BIN"/*; do
        [ -f "$bin" ] || continue
        head -c 300 "$bin" 2>/dev/null | grep -q "pnpm/global/" || continue
        rm -f "$bin" && removed=$((removed + 1))
    done
    echo "removed $removed legacy shim(s)"

    rm -rf "$g" && echo "removed $g"
    return 0
}

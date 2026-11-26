#!/bin/bash
# lib/steps/tools.sh -- per-tool steps that are more than a package install.

# step_pi_agents_md -- the Termux context file Pi reads on every run.
# Lifted verbatim from install_pi(): without it, Pi assumes a desktop Linux and
# invents paths that do not exist on Android.
step_pi_agents_md() {
    mkdir -p "$HOME/.pi/agent" || return 1
    cat > "$HOME/.pi/agent/AGENTS.md" <<EOF
# Agent Environment: Termux on Android

## Location
- **OS**: Android (Termux terminal emulator)
- **Home**: $HOME
- **Prefix**: $PREFIX
- **Shared storage**: /storage/emulated/0 (Downloads, Documents, etc.)

## Opening URLs
\`\`\`bash
termux-open-url "https://example.com"
\`\`\`
EOF
    echo "wrote $HOME/.pi/agent/AGENTS.md"
}

# step_gemini_patch -- fs.promises.rename -> copyFile + unlink.
# Gemini's project registry rewrites a file by renaming a temp file over it, which
# throws ENOENT on Android. Prefer the toolkit's own patcher so the two paths
# cannot drift; fall back to the inline form used by install_gemini_cli().
step_gemini_patch() {
    if command -v patch_gemini_cli >/dev/null 2>&1; then
        patch_gemini_cli 1
        return $?
    fi

    local roots root
    local -a list=()
    roots=$(get_global_node_path 2>/dev/null)
    IFS=':' read -ra list <<< "$roots"
    for root in "${list[@]}"; do
        [ -d "$root" ] || continue
        find -L "$root" -maxdepth 6 -type f -name 'projectRegistry.js' \
            -exec sed -i 's|await fs.promises.rename(\([^,]*\), \([^)]*\))|await fs.promises.copyFile(\1, \2); await fs.promises.unlink(\1)|g' {} + 2>/dev/null || true
    done
    echo "applied registry patch (inline)"
}

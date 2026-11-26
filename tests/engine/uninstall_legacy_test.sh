#!/usr/bin/env bash
# tests/engine/uninstall_legacy_test.sh -- uninstalling a tool that lives in the OLD layout.
#
# y6 (2026-11-24) is the case: Pi and Gemini were installed before tools/ existed, so they live
# in the shared `global/<n>/node_modules` tree. `step_uninstall_tool` removed `tools/<tool>` —
# which did not exist — and the shims that point into it — of which there were none. The app said
# "removed", the tool kept running, and `tools.installed` kept reporting it.
#
# This builds that layout in a throwaway HOME and asserts the removal and the verification.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

t_begin "engine: uninstall a legacy-layout tool"
t_init
trap t_cleanup EXIT

# tool_project.sh needs tool_dir (paths), state_dir and TERMUX_BIN.
export TERMUX_BIN="$HOME/bin"
mkdir -p "$TERMUX_BIN" "$HOME/.local/share/pnpm/tools"

# shellcheck source=lib/state.sh
. "$REPO_ROOT/lib/state.sh"
# shellcheck source=lib/steps/tool_project.sh
. "$REPO_ROOT/lib/steps/tool_project.sh"

# ---- the legacy layout, exactly as the old installer left it ---------------------------
LEGACY="$HOME/.local/share/pnpm/global/5/node_modules"
mkdir -p "$LEGACY/@earendil-works/pi-coding-agent" "$LEGACY/@google/gemini-cli"
printf '#!/data/data/com.termux/files/usr/bin/sh\nexec node %s/pi-coding-agent/dist/cli.js "$@"\n' \
    "$LEGACY/@earendil-works" > "$TERMUX_BIN/pi"
printf '#!/data/data/com.termux/files/usr/bin/sh\nexec node %s/gemini-cli/dist/index.js "$@"\n' \
    "$LEGACY/@google" > "$TERMUX_BIN/gemini"
chmod +x "$TERMUX_BIN/pi" "$TERMUX_BIN/gemini"

# jq is needed by the step and lives outside the temp bin; symlink it in so the search path can
# be narrowed. The CI/local host can have its own `pi` on PATH (this one does, in /opt/homebrew),
# and then "still on PATH after removal" fires for the wrong reason.
ln -sf "$(command -v jq)" "$TERMUX_BIN/jq"
export PATH="$TERMUX_BIN:/usr/bin:/bin"

step='{"args":{"tool":"pi"}}' 
if step_uninstall_tool "$step" '{}' '{}' >"$TMP_ROOT/uninstall.out" 2>&1; then
    _ok "the uninstall step completed"
else
    _bad "the uninstall step failed" "$(tail -3 "$TMP_ROOT/uninstall.out")"
fi

t_eq "gone" "$([ -e "$LEGACY/@earendil-works/pi-coding-agent" ] && echo present || echo gone)" \
    "the scoped legacy copy is removed (a name-only lookup would have missed it)"
t_eq "gone" "$([ -e "$TERMUX_BIN/pi" ] && echo present || echo gone)" \
    "its shim is removed"
t_eq "present" "$([ -e "$LEGACY/@google/gemini-cli" ] && echo present)" \
    "another tool's legacy copy is untouched"
t_eq "present" "$([ -e "$LEGACY" ] && echo present)" \
    "the shared legacy tree itself is not deleted (cleanup owns that)"

# ---- verification: "done" must mean "gone" --------------------------------------------
# A shim the removal does not own (no legacy path in it) must not stop the step, but a tool
# still on PATH must fail it. Simulate the second case with a shim the step will not match.
printf '#!/bin/sh\nexit 0\n' > "$TERMUX_BIN/n8n"
chmod +x "$TERMUX_BIN/n8n"
if _uninstall_verify n8n >/dev/null 2>&1; then
    _bad "verification passed with the command still on PATH"
else
    _ok "verification fails when the command still resolves"
fi

t_exit

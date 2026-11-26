#!/usr/bin/env bash
# tests/engine/tui_render_test.sh -- the catalog menu (Phase 7) renders the API stream.
#
# The text menu used to call the legacy functions, so a fix had to land twice. It now lists
# `--api list` and runs `--api run`, which means the renderer is the only new thing in it — and
# the thing worth testing without a terminal.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

t_begin "engine: catalog menu"
t_init
trap t_cleanup EXIT

export TOOLKIT_DIR="$REPO_ROOT"
# shellcheck source=lib/ui/tui.sh
. "$REPO_ROOT/lib/ui/tui.sh"

# ---- the menu lists what the catalog declares -----------------------------------------
actions=$(tui_actions)
t_contains "$actions" "pi.install" "the menu lists the catalog's actions"
t_contains "$actions" "— agents" "the label carries the category" 
t_eq "id<TAB>label" "$(printf '%s\n' "$actions" | head -1 | awk -F'\t' 'NF==2 {print "id<TAB>label"}')" \
    "each line is an id and a label separated by a tab"

# ---- a successful run reads like a story ----------------------------------------------
ok_stream='{"t":"start","schema":1,"action":"pi.install"}
{"t":"preflight","ok":true,"arch":"aarch64","mem_mb":900,"disk_mb":9000}
{"t":"step","id":"install","state":"running","title":"Install Pi","ms":0}
{"t":"step","id":"install","state":"ok","title":"Install Pi","ms":12000}
{"t":"data","kind":"install","payload":{}}
{"t":"done","code":0,"skipped":[]}'
out=$(printf '%s\n' "$ok_stream" | tui_render)
t_contains "$out" "▶ pi.install" "it names the action it is running"
t_contains "$out" "✔ Install Pi (12s)" "a finished step shows its duration"
t_contains "$out" "Done." "a successful run says so"

# ---- a refused run says why, in the app's words ---------------------------------------
bad_stream='{"t":"start","schema":1,"action":"paperclip.install"}
{"t":"preflight","ok":false,"arch":"armv8l","mem_mb":300,"disk_mb":900}
{"t":"log","step":"preflight","line":"refused: unmet: postgres_running"}
{"t":"done","code":3,"skipped":[]}'
out=$(printf '%s\n' "$bad_stream" | tui_render)
t_contains "$out" "does not meet the requirements" "a refusal is stated before the exit code"
t_contains "$out" "postgres_running" "the engine's reason is shown"
t_contains "$out" "Stopped (code 3)." "the exit code is still there, for a bug report"

# ---- nothing but JSON reaches the renderer --------------------------------------------
out=$(printf '%s\n' 'not json' '{"t":"done","code":0}' | tui_render)
t_eq "Done." "$(printf '%s\n' "$out" | tail -1)" "a non-JSON line is ignored, not printed"

t_exit

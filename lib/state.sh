#!/bin/bash
# lib/state.sh -- per-action checkpoint so a killed install resumes instead of
# restarting from zero.
#
# Android's low-memory killer sends SIGKILL: no error text, no partial report,
# and on a 1.8 GB device it hits pnpm/node-gyp regularly. Re-running the whole
# action wastes the work that already succeeded, so completed idempotent steps
# are recorded and skipped on the next run (unless --fresh).

STATE_ROOT="${STATE_ROOT:-$HOME/.droid_ai_toolkit}"

state_dir() {
    mkdir -p "$STATE_ROOT/state" "$STATE_ROOT/log" "$STATE_ROOT/answers" 2>/dev/null
    printf '%s' "$STATE_ROOT"
}

# state_file <action-id>
state_file() {
    printf '%s/state/%s.json' "$(state_dir)" "$1"
}

# state_begin <action-id> <run-id> [params-json]
state_begin() {
    local action="$1" run_id="$2" params="${3:-}"
    [ -n "$params" ] || params='{}'
    local f tmp
    f=$(state_file "$action")
    tmp=$(mktemp)
    if jq -n --arg a "$action" --arg r "$run_id" --argjson p "$params" \
             --arg ts "$(date -u +%FT%TZ)" \
             '{schema:1, action:$a, run_id:$r, started:$ts, finished:null, params:$p, steps:{}}' \
             > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        return 1
    fi
}

# state_mark <action-id> <step-id> <state> [ms]
state_mark() {
    local action="$1" step="$2" st="$3" ms="${4:-0}"
    local f tmp
    f=$(state_file "$action")
    [ -f "$f" ] || return 1
    tmp=$(mktemp)
    if jq --arg id "$step" --arg st "$st" --argjson ms "$ms" \
          '.steps[$id] = {state:$st, ms:$ms}' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        return 1
    fi
}

# state_step_ok <action-id> <step-id> -- true when the step completed successfully
state_step_ok() {
    local f
    f=$(state_file "$1")
    [ -f "$f" ] || return 1
    [ "$(jq -r --arg id "$2" '.steps[$id].state // "none"' "$f" 2>/dev/null)" = "ok" ]
}

# state_finish <action-id>
state_finish() {
    local f tmp
    f=$(state_file "$1")
    [ -f "$f" ] || return 0
    tmp=$(mktemp)
    if jq --arg ts "$(date -u +%FT%TZ)" '.finished = $ts' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
    fi
}

# log_path <action-id> -- full log for this run (the NDJSON stream stays small)
log_path() {
    printf '%s/log/%s-%s.log' "$(state_dir)" "${1:-run}" "$(date +%Y%m%d-%H%M%S)"
}

# answer_get <ask-id> -- prints the answer, or fails when none was provided.
#
# There is deliberately no default branch: an unanswered prompt is an error, not
# an implicit "yes". The current TUI's confirm_action answered YES on EOF, which
# is how a headless run could wipe a device.
answer_get() {
    [ -n "${API_ANSWERS:-}" ] && [ -f "$API_ANSWERS" ] || return 1
    local v
    v=$(jq -r --arg id "$1" '.[$id] // empty' "$API_ANSWERS" 2>/dev/null) || return 1
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

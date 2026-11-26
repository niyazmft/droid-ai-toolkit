#!/bin/bash
# lib/progress.sh -- live step progress for a long run, for the app to read.
#
# Why a file and not stdout
# -------------------------
# A background RUN_COMMAND returns only when the command finishes, so the app sees nothing
# until a 40-minute install is over. The step list it shows afterwards is the *record*; this is
# the live feed: one NDJSON line per step transition, written where both sides can read it.
#
# Where: `~/storage/shared/droid-ai/progress.ndjson`. Termux's home is app-private, so shared
# storage is the only channel. It requires `termux-setup-storage` — one Android permission the
# toolkit cannot grant itself, and the reason this is best-effort:
#
#   * no `~/storage/shared`  -> every function here is a no-op, and the app falls back to the
#     elapsed-time banner it has today (no behaviour change, no error);
#   * the file is truncated at the start of each run, so a reader never sees the previous run's
#     last step as if it were current.
#
# Line shape (the app parses it; keep it stable):
#   {"run":"1795641158-11831","action":"pi.install","index":2,"total":7,
#    "step":"install","title":"Install Pi","state":"running","ts":1795641161000}

# progress_path -- the file to write, or non-zero when shared storage is unavailable.
progress_path() {
    [ -d "$HOME/storage/shared" ] || return 1
    mkdir -p "$HOME/storage/shared/droid-ai" 2>/dev/null || return 1
    printf '%s/droid-ai/progress.ndjson' "$HOME/storage/shared"
}

_progress_emit() {
    local file="$1" index="$2" total="$3" step="$4" title="$5" state="$6"
    local ts
    ts=$(date +%s%3N 2>/dev/null)
    case "$ts" in
        *[!0-9]*) ts=0 ;;
    esac
    printf '{"run":"%s","action":"%s","index":%s,"total":%s,"step":"%s","title":"%s","state":"%s","ts":%s}\n' \
        "${PROGRESS_RUN:-}" "${PROGRESS_ACTION:-}" "${index:-0}" "${total:-0}" \
        "$step" "$title" "$state" "${ts:-0}" >> "$file" 2>/dev/null || true
}

# progress_begin <action-id> <run-id> <step-count> -- start a new run's feed.
progress_begin() {
    local file
    file=$(progress_path) || return 0
    PROGRESS_ACTION="$1"
    PROGRESS_RUN="$2"
    PROGRESS_TOTAL="${3:-0}"
    PROGRESS_INDEX=0
    : > "$file" 2>/dev/null || return 0
    _progress_emit "$file" 0 "$PROGRESS_TOTAL" "" "Starting" "running"
    return 0
}

# progress_step <step-id> <title> <state> -- one transition.
progress_step() {
    local file
    file=$(progress_path) || return 0
    case "${3:-}" in
        running) PROGRESS_INDEX=$(( ${PROGRESS_INDEX:-0} + 1 )) ;;
    esac
    _progress_emit "$file" "${PROGRESS_INDEX:-0}" "${PROGRESS_TOTAL:-0}" "$1" "$2" "$3"
    return 0
}

# progress_end <exit-code> -- say how it finished, so a stale "running" line cannot outlive it.
# The state is `finished`, not `done`: shellcheck reads a bare `done` argument as the keyword.
progress_end() {
    local file
    file=$(progress_path) || return 0
    local word="Failed"
    [ "${1:-0}" -eq 0 ] && word="Finished"
    _progress_emit "$file" "${PROGRESS_INDEX:-0}" "${PROGRESS_TOTAL:-0}" "" "$word" finished
    return 0
}

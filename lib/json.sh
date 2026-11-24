#!/bin/bash
# lib/json.sh -- NDJSON events for the --api interface.
#
# Every event is one JSON object per line on stdout. Nothing else may be written
# to stdout in API mode: the APK parses this stream, so a stray `echo` corrupts
# it. Human-readable progress belongs in the log file (see state.sh).
#
# Values are passed to jq with --arg/--argjson, never interpolated into the
# program text, so a value containing quotes cannot break the stream.

# ev_error <code> <msg>
ev_error() {
    jq -cn --argjson code "${1:-1}" --arg msg "${2:-}" \
        '{t:"error", code:$code, msg:$msg}'
}

# ev_start <action-id> <run-id>
ev_start() {
    jq -cn --arg a "$1" --arg r "$2" \
        '{t:"start", schema:1, action:$a, run_id:$r}'
}

# ev_preflight <ok:true|false> <arch> <mem_mb> <disk_mb> [forced:true|false]
# <ok> is passed as pre-encoded JSON (true/false) so callers do not build JSON.
# `forced` is present only when the caller overrode a capacity gate with --force, so a
# consumer can tell "it fits" apart from "the user insisted".
ev_preflight() {
    local ok="$1" arch="$2" mem="${3:-0}" disk="${4:-0}" forced="${5:-false}"
    local prog='{t:"preflight", ok:$ok, arch:$arch, mem_mb:$mem, disk_mb:$disk}'
    [ "$forced" = "true" ] && prog='{t:"preflight", ok:$ok, arch:$arch, mem_mb:$mem, disk_mb:$disk, forced:true}'
    jq -cn --argjson ok "$ok" --arg arch "$arch" --argjson mem "$mem" --argjson disk "$disk" "$prog"
}

# ev_step <id> <state> <title> [ms]
# state is one of: running | ok | failed | skipped
ev_step() {
    jq -cn --arg id "$1" --arg st "$2" --arg ti "${3:-}" --argjson ms "${4:-0}" \
        '{t:"step", id:$id, state:$st, title:$ti, ms:$ms}'
}

# ev_ask <id> <kind> <title> [default]
# kind is one of: confirm | text | choice
ev_ask() {
    jq -cn --arg id "$1" --arg kind "$2" --arg ti "$3" --arg def "${4:-}" \
        '{t:"ask", id:$id, kind:$kind, title:$ti, default:$def}'
}

# ev_choice <id> <kind> <title> <options-json>
ev_choice() {
    jq -cn --arg id "$1" --arg kind "$2" --arg ti "$3" --argjson opts "${4:-[]}" \
        '{t:"ask", id:$id, kind:$kind, title:$ti, options:$opts}'
}

# ev_log <step-id> <line>
ev_log() {
    jq -cn --arg st "${1:-}" --arg line "$2" \
        '{t:"log", step:$st, line:$line}'
}

# ev_data <kind> <payload-json>
# Structured payload a step produced (device snapshot, health report). Kept
# separate from `log` so the app never has to parse prose.
ev_data() {
    jq -cn --arg kind "$1" --argjson payload "$2" \
        '{t:"data", kind:$kind, payload:$payload}'
}

# ev_done <code> [skipped-json-array]
ev_done() {
    jq -cn --argjson c "${1:-0}" --argjson sk "${2:-[]}" \
        '{t:"done", code:$c, skipped:$sk}'
}

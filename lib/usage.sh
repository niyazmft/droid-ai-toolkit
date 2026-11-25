#!/bin/bash
# lib/usage.sh -- what each engine run actually cost.
#
# Why a ledger and not a feeling
# ------------------------------
# Every Tier-1 change in this branch is about CPU, and CPU is invisible: an app that re-reads
# status on every launch *feels* the same as one that does not, until the battery or the low
# memory killer says otherwise. So each run appends one line to `usage.ndjson` under the
# toolkit's state directory, and `scripts/usage_report.sh` turns that into the before/after
# numbers quoted in TASKS.md.
#
# One line per run, NDJSON, appended — never rewritten, so a killed run cannot corrupt what came
# before it:
#
#   {"ts":1795637342000,"cmd":"status","action":"","fast":1,"wall_ms":6065,
#    "user_s":0.31,"sys_s":0.22,"node_procs":3}
#
# `ts` is epoch **milliseconds** (like `wall_ms`); `scripts/usage_report.sh` reads it that way.
#
# `user_s`/`sys_s` are the shell plus its reaped children, from bash's own `times` builtin: no
# sampling daemon, no extra process, and it keeps counting for a 40-minute install.

USAGE_FILE="${USAGE_FILE:-$(state_dir)/usage.ndjson}"

# usage_now_ms -- epoch milliseconds, or 0 where the shell's date cannot do it.
#
# Termux ships GNU date, so `%3N` works where it matters. BSD/macOS date echoes the literal
# format, so the fallback is whole seconds — a 1 s resolution is fine for a development run and
# never applies on a device.
usage_now_ms() {
    local t
    t=$(date +%s%3N 2>/dev/null)
    case "$t" in
        *[!0-9]*|'')
            t=$(date +%s 2>/dev/null)
            case "$t" in
                *[!0-9]*|'') printf '0' ;;
                *) printf '%s000' "$t" ;;
            esac
            ;;
        *) printf '%s' "$t" ;;
    esac
}

# _usage_ms <NmS.mmms> -- milliseconds for one `times` field.
#
# bash arithmetic is integer-only, so everything is counted in milliseconds and rendered at the
# end. Two details cost a debugging session each and must not be "simplified":
#
#   * `times` prints three decimal places (`0m0.852s` = 852 **milliseconds**, not centiseconds).
#     Reading it as centiseconds recorded 8.5 s for a 0.85 s run.
#   * `10#` forces decimal. "$(( 008 ))" is an *octal* literal in bash and errors on 8 and 9.
_usage_ms() {
    local v="${1:-0m0.000s}" min sec frac
    min=${v%%m*}
    v=${v#*m}
    sec=${v%s}
    frac=${sec#*.}
    [ "$frac" = "$sec" ] && frac=0
    frac="${frac}000"
    frac=${frac:0:3}
    printf '%s' $(( 10#${min:-0} * 60000 + 10#${sec%%.*} * 1000 + 10#${frac} ))
}

# usage_cpu -- set USAGE_U_MS / USAGE_S_MS for this shell and its reaped children.
#
# `times` prints two lines of `NmS.mmms`: line 1 is this shell, line 2 its children. Both count —
# almost all of a status run happens in children (Node, getprop, df).
#
# It must run in the *caller's* shell, which is why it sets variables instead of printing: in a
# command substitution `times` reports the subshell's own times, which are zero, and the ledger
# then records 0.00 for every run.
usage_cpu() {
    local f f1 f2 f3 f4
    USAGE_U_MS=0
    USAGE_S_MS=0
    f=$(mktemp 2>/dev/null) || return 0
    times > "$f" 2>/dev/null
    { read -r f1 f2; read -r f3 f4; } < "$f"
    rm -f "$f"
    USAGE_U_MS=$(( $(_usage_ms "$f1") + $(_usage_ms "$f3") ))
    USAGE_S_MS=$(( $(_usage_ms "$f2") + $(_usage_ms "$f4") ))
}

# _usage_seconds <milliseconds> -- "1.230", for the ledger.
_usage_seconds() {
    local ms="${1:-0}" whole frac
    [ "$ms" -lt 0 ] && ms=0
    whole=$(( ms / 1000 ))
    frac=$(( ms % 1000 ))
    printf '%d.%03d' "$whole" "$frac"
}

# usage_begin -- remember the start of a run.
usage_begin() {
    USAGE_T0_MS=$(usage_now_ms)
    usage_cpu
    USAGE_T0_U="$USAGE_U_MS"
    USAGE_T0_S="$USAGE_S_MS"
}

# usage_end <cmd> <action-id> <fast 0|1> -- append one line for the run that just finished.
#
# Never fails the caller: telemetry that can break an install is worse than no telemetry.
usage_end() {
    local cmd="${1:-}" action="${2:-}" fast="${3:-0}"
    local now_ms wall user_s sys_s nodes
    now_ms=$(usage_now_ms)
    wall=0
    if [ "${USAGE_T0_MS:-0}" -gt 0 ] && [ "$now_ms" -gt 0 ]; then
        wall=$(( now_ms - USAGE_T0_MS ))
    fi
    usage_cpu
    user_s=$(_usage_seconds $(( USAGE_U_MS - ${USAGE_T0_U:-0} )))
    sys_s=$(_usage_seconds $(( USAGE_S_MS - ${USAGE_T0_S:-0} )))
    nodes=0
    if command -v _h_node_procs >/dev/null 2>&1; then
        nodes=$(_h_node_procs)
    fi
    printf '{"ts":%s,"cmd":"%s","action":"%s","fast":%s,"wall_ms":%s,"user_s":%s,"sys_s":%s,"node_procs":%s}\n' \
        "${now_ms:-0}" "$cmd" "$action" "${fast:-0}" "$wall" "$user_s" "$sys_s" \
        "${nodes:-0}" >> "$USAGE_FILE" 2>/dev/null || true
    return 0
}

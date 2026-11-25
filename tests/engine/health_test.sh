#!/usr/bin/env bash
# tests/engine/health_test.sh -- `--api health`, the cheap liveness endpoint.
#
# Why it earns a test: it exists to replace a `pm2 jlist` call (7 s, one Node boot) with a
# filesystem read (<100 ms). Two things can go wrong silently — it can trust a pid file whose
# process is gone (a crashed PM2 leaves the file behind, which is how a dead toolkit looks
# healthy), and it can quietly grow a dependency that makes it expensive again.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

t_begin "engine: --api health"
t_init
trap t_cleanup EXIT

PM2="$HOME/.pm2"
mkdir -p "$PM2/pids"

# ---- nothing installed ----------------------------------------------------------------

engine health
t_eq 0 "$RC" "--api health exits 0"
t_ndjson "$OUT" "--api health is pure NDJSON"
t_field "$OUT" '[.[] | select(.t == "data")][0].kind' "health" "it emits a health payload"
t_field "$OUT" '[.[] | select(.t == "data")][0].payload.pm2.alive' "false" \
    "with no PM2 daemon, alive is false"
t_field "$OUT" '[.[] | select(.t == "data")][0].payload.online' "0" \
    "with no PM2 daemon, nothing is online"
t_field "$OUT" '[.[] | select(.t == "done")][0].code' "0" "a health read reports done 0"

# ---- a live daemon, one live service, one stale pid file --------------------------------

# The test's own shell is a real, live PID — and it is not PM2, which is exactly the point:
# liveness is "/proc/<pid> exists", not "the file says so".
printf '%s\n' "$$" > "$PM2/pm2.pid"
printf '%s\n' "$$" > "$PM2/pids/openclaw-0.pid"
# A pid file from a process that is gone (999999 is above any realistic pid_max here).
printf '%s\n' "999999" > "$PM2/pids/n8n-1.pid"

engine health
PAYLOAD=$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "data")][0].payload')
t_eq "true" "$(printf '%s' "$PAYLOAD" | jq -r '.pm2.alive')" "a live daemon pid reads alive"
t_eq 1 "$(printf '%s' "$PAYLOAD" | jq -r '.online')" "only the live service counts as online"
t_eq 2 "$(printf '%s' "$PAYLOAD" | jq -r '.total')" "both pid files are reported"
t_eq "false" "$(printf '%s' "$PAYLOAD" | jq -r '.services[] | select(.name == "n8n") | .alive')" \
    "a stale pid file is not a running service"
t_eq "true" "$(printf '%s' "$PAYLOAD" | jq -r '.services[] | select(.name == "openclaw") | .alive')" \
    "a live service keeps its name"
t_eq "number" "$(printf '%s' "$PAYLOAD" | jq -r '.node_procs | type')" "node_procs is a number"

# ---- it stays cheap --------------------------------------------------------------------

# The promise is "well under a second, no interpreter". A regression that reaches for jq or pm2
# here would still pass every assertion above, so the cost itself is asserted.
now_ns() {
    if date +%s%N 2>/dev/null | grep -q '^[0-9]\{19\}$'; then
        date +%s%N
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time()*1e9))'
    fi
}
start=$(now_ns)
engine health
end=$(now_ns)
if [ -n "$start" ] && [ -n "$end" ]; then
    ms=$(( (end - start) / 1000000 ))
    if [ "$ms" -lt 1000 ]; then
        _ok "--api health completes in ${ms} ms (promise: under 1 s)"
    else
        _bad "--api health took ${ms} ms" "it must not spawn a runtime; this is a filesystem read"
    fi
else
    printf '  SKIP  timing (no nanosecond clock available)\n'
fi

# No interpreter dependencies: the payload mentions none, and the run log proves the argv.
logfile=$(find "$STATE_ROOT/log" -name "health-*.log" -print 2>/dev/null | sort | tail -1)
if [ -n "$logfile" ]; then
    t_contains "$(cat "$logfile")" "argv: --api health" "the run log records the invocation"
fi

t_exit

#!/bin/bash
# lib/health.sh -- `install.sh --api health`: "how much of the toolkit is alive?", in pure bash.
#
# Why this exists
# ---------------
# `--fast` status still costs ~6 s on y6 / 7.2 s on 8x, and most of that is `pm2 jlist`, which
# boots a Node runtime to print JSON. The supervisor's per-unlock question is much smaller than
# a status document: is the PM2 daemon up, and are its processes still alive? Both answers are
# in the filesystem, so this reads `~/.pm2/pm2.pid`, `~/.pm2/pids/*.pid` and `/proc/<pid>` and
# answers in milliseconds with no interpreter, no `jq` and no `pm2` spawn.
#
# What it deliberately is not
# --------------------------
# Not a status document: no versions, no memory, no catalog. A consumer that needs those keeps
# using `status --fast`. The shape below is stable and documented in docs/CONTRACT.md.
#
# The pid file proves the daemon *existed*; `/proc/<pid>` is what proves it is still there. A
# crashed PM2 leaves a pid file behind (observed on 8x after an LMK kill), so trusting the file
# alone would report a dead toolkit as healthy.

PM2_DIR="${PM2_HOME:-$HOME/.pm2}"

# _h_alive <pid> -- is this PID a live process right now?
_h_alive() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -d "/proc/$1" ] || kill -0 "$1" 2>/dev/null
}

# _h_read_pid <file> -- the first integer in a pid file, or nothing.
_h_read_pid() {
    local pid
    [ -f "$1" ] || return 0
    pid=$(head -c 32 "$1" 2>/dev/null | tr -cd '0-9')
    printf '%s' "$pid"
}

# _h_escape <string> -- make a PM2 process name safe inside a JSON string.
#
# Only the two characters that can break the document are handled, on purpose: PM2 names are
# alphanumeric plus `-._:`, and a full escaper in bash is a bigger risk than it removes.
_h_escape() {
    local s="${1:-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# _h_node_procs -- how many `node` processes exist, read from /proc.
#
# Cheap (a glob and a few hundred readlinks) and useful for exactly one question: "did this
# unlock boot another runtime?" — the number that makes the Tier-1 savings measurable.
#
# Measured on /proc/<pid>/exe rather than /proc/<pid>/comm, because PM2 and its children rewrite
# their *titles*: on y6 the daemon reads `comm=PM2 v6.0.14: Go` and the gateway
# `comm=openclaw-gatewa`, while both resolve to `…/usr/bin/node`. Counting comm names missed
# every process this number exists to count. (Android hides other UIDs' /proc entries; on Termux
# every toolkit process shares one UID, so that restriction costs nothing here.)
_h_node_procs() {
    local n
    # One `readlink` for every pid, not one per pid. Measured on y6: 38 ms versus 757 ms for
    # the same answer in a bash loop, because `exe=$(readlink …)` forks a subshell per process
    # and Android's /proc makes each of those dear. GNU readlink accepts many paths; where it
    # does not, the count is simply 0 rather than wrong.
    n=$(readlink /proc/[0-9]*/exe 2>/dev/null | grep -c '/node$' 2>/dev/null)
    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    printf '%s' "$n"
}

# health_collect -- write the health payload to $1 (a file) and return 0.
#
# JSON is assembled with printf rather than jq: jq itself is a process spawn, and the point of
# this endpoint is that it has none.
health_collect() {
    local out="${1:-/dev/null}"
    local pm2_pid pm2_alive=false
    local services="" online=0 stale=0 f pid name

    pm2_pid=$(_h_read_pid "$PM2_DIR/pm2.pid")
    if [ -n "$pm2_pid" ] && _h_alive "$pm2_pid"; then pm2_alive=true; fi

    # PM2 keeps `pids/<name>-<id>.pid` after a process is deleted or restarted, so on 8x this
    # loop saw thirteen files for two real processes: hermes ×4, ollama ×5, openclaw ×2,
    # paperclip ×2. `services` therefore lists only what is *alive*, and the leftovers are
    # summarised as `stale` — a consumer that asked "what is running" must not be handed a
    # museum, and `total` (online + stale) still tells an operator the difference.
    for f in "$PM2_DIR"/pids/*.pid; do
        [ -f "$f" ] || continue
        pid=$(_h_read_pid "$f")
        # name-<id>.pid -> name. A name may contain dashes, so strip only the trailing id.
        name=$(basename "$f" .pid)
        name=${name%-[0-9]*}
        [ -n "$name" ] || continue
        if [ -n "$pid" ] && _h_alive "$pid"; then
            online=$((online + 1))
            [ -n "$services" ] && services="$services,"
            services="$services{\"name\":\"$(_h_escape "$name")\",\"pid\":$pid}"
        else
            stale=$((stale + 1))
        fi
    done

    printf '{"pm2":{"pid":%s,"alive":%s},"services":[%s],"online":%s,"stale":%s,"total":%s,"node_procs":%s,"checked_at":%s}\n' \
        "${pm2_pid:-0}" "$pm2_alive" "$services" "$online" "$stale" "$((online + stale))" \
        "$(_h_node_procs)" "$(date +%s)" \
        > "$out" 2>/dev/null
}

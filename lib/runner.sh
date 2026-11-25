#!/bin/bash
# lib/runner.sh -- executes an action spec.
#
# Contract for a step primitive (lib/steps/*.sh):
#     step_fn <step-json> <spec-json>
#       $1  the step object from the spec ("id", "title", "args", …)
#       $2  the whole action spec (for "params")
#     returns 0 on success, non-zero on failure; 137 propagates when killed.
#
# Arguments are passed as JSON and parsed by the primitive with jq. They are
# never spliced into an `eval` string: the legacy path built shell commands by
# interpolation, which is both an injection risk and impossible to quote
# correctly once a version string or a path contains a space.

runner_actions_dir() {
    printf '%s/actions' "${TOOLKIT_DIR:-.}"
}

# api_spec_files -- every spec path, as words in FILES.
#
# A bash glob, deliberately: the previous `find … | head -1` + `xargs -0 jq` pipeline returned
# nothing on a clean Termux on Android 16 even though `find` and `jq` both worked by hand — the
# app then rendered "0 of 0 installed" with no way to tell why. Globs cost no processes, remove
# find/xargs as runtime dependencies (a fresh Termux may not have findutils), and cannot die of
# SIGPIPE from `head`.
api_spec_files() {
    local dir f
    FILES=()
    dir=$(runner_actions_dir)
    [ -d "$dir" ] || return 1
    for f in "$dir"/*/*.json "$dir"/*.json; do
        if [ -f "$f" ]; then
            FILES+=("$f")
        fi
    done
    [ ${#FILES[@]} -gt 0 ]
}

# api_catalog -- every spec that declares itself valid, as one JSON document.
# The app renders this; adding a tool must not require an APK release.
api_catalog() {
    if ! api_spec_files; then
        printf '{"schema":1,"actions":[]}\n'
        return 0
    fi
    # One jq for all specs: --slurp reads them in order, and the filter drops anything that is
    # not a v1 spec instead of failing the whole catalog on one bad file.
    jq -cs 'map(select(.schema == 1 and (.id | type) == "string"))
            | {schema: 1, actions: sort_by(.category, .title)}' "${FILES[@]}"
}

# api_find_action <id> -- path to the spec, or non-zero when unknown
api_find_action() {
    local id="$1" f
    api_spec_files || return 1
    for f in "${FILES[@]}"; do
        if [ "$(jq -r '.id // empty' "$f" 2>/dev/null)" = "$id" ]; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 1
}

# runner_preflight <spec> [force] -- emits the preflight event; 0 ok, 3 refused.
#
# `force` (from --force) overrides the *capacity* gates only. Architecture and named
# predicates are hard: no flag makes a 32-bit device run an aarch64-only tool, and
# pretending otherwise would turn a clear refusal into a confusing failure later. The
# event carries `forced:true` so the app can say the user insisted.
runner_preflight() {
    local spec="$1" force="${2:-0}" arch allowed mem disk min_mem min_disk ok=1 short=0
    arch=$(pf_arch)
    mem=$(pf_mem_available_mb)
    disk=$(pf_disk_free_mb)
    min_mem=$(printf '%s' "$spec" | jq -r '.requires.min_mem_mb // 0')
    min_disk=$(printf '%s' "$spec" | jq -r '.requires.min_disk_mb // 0')
    allowed=$(printf '%s' "$spec" | jq -r '(.requires.arch // []) | join(" ")')

    if [ -n "$allowed" ]; then
        # shellcheck disable=SC2086  # word splitting is the point: a list of arches
        pf_arch_allowed $allowed || ok=0
    fi

    # Named preconditions a spec can require (probe.sh predicates). Used for things a
    # numeric threshold cannot express, e.g. "a warm wheel cache exists" — without one,
    # pip would compile cryptography for 30-90 minutes and probably be OOM-killed.
    # `name:arg` is split the same way a step's `when` is, so a predicate that needs an
    # argument (pkg_available:ollama) can be used as a hard precondition.
    local preds p pname parg failed=""
    preds=$(printf '%s' "$spec" | jq -r '(.requires.predicates // []) | join(" ")')
    for p in $preds; do
        case "$p" in
            *:*) pname="${p%%:*}"; parg="${p#*:}" ;;
            *)   pname="$p"; parg="" ;;
        esac
        if ! pred_apply "$pname" "$parg"; then
            failed="$failed $p"
            ok=0
        fi
    done

    # Capacity is advice, not a prohibition: the user can see the numbers and decide.
    [ "${mem:-0}" -lt "${min_mem:-0}" ] && short=1
    [ "${disk:-0}" -lt "${min_disk:-0}" ] && short=1

    if [ "$ok" -eq 1 ] && [ "$short" -eq 1 ] && [ "$force" -eq 1 ]; then
        ev_preflight true "$arch" "${mem:-0}" "${disk:-0}" true
        ev_log preflight "capacity overridden (--force): mem=${mem}MB (need ${min_mem}MB) disk=${disk}MB (need ${min_disk}MB)"
        return 0
    fi
    [ "$short" -eq 1 ] && ok=0

    if [ "$ok" -eq 1 ]; then
        ev_preflight true "$arch" "${mem:-0}" "${disk:-0}"
        return 0
    fi
    ev_preflight false "$arch" "${mem:-0}" "${disk:-0}"
    local hint=""
    [ "$force" -eq 1 ] && hint=" [--force does not override arch or predicates]"
    ev_log preflight "refused: arch=$arch (allowed: ${allowed:-any}) mem=${mem}MB (need ${min_mem}MB) disk=${disk}MB (need ${min_disk}MB)${failed:+ unmet:${failed}}${hint}"
    return 3
}

# runner_replay_tail <step-id> <log> <byte-offset> [max-lines] -- echo the end of one
# step's output into the event stream.
#
# Steps print to their own log file on disk, which the app cannot read: it runs in a
# different UID and Termux's home is app-private. Without this the client could only say
# "Step failed: Install package" while the reason (`E: Unable to locate package ollama`,
# `not on PATH: pi`) sat in a file nobody on the phone would open.
#
# The offset is the log size before the step ran, so a retry does not replay the previous
# attempt. Lines are truncated and ANSI-stripped: apt and pnpm colour their output, and a
# progress bar is 200 characters of carriage returns, not information.
runner_replay_tail() {
    local s_id="$1" file="$2" offset="${3:-1}" max="${4:-12}" out line
    [ -s "$file" ] || return 0
    out=$(tail -c +"$offset" "$file" 2>/dev/null | tail -n "$max" \
        | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' 2>/dev/null)
    [ -n "$out" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        ev_log "$s_id" "$(printf '%.240s' "$line")"
    done <<LOG
$out
LOG
}

# runner_when <when-value> -- evaluate a spec guard (predicate name, optional ":arg")
runner_when() {
    local when="$1" name arg=""
    [ -n "$when" ] || return 0
    case "$when" in
        *:*) name="${when%%:*}"; arg="${when#*:}" ;;
        *)   name="$when" ;;
    esac
    pred_apply "$name" "$arg"
}

# runner_run <action-id> -- execute a spec, emitting NDJSON. Returns the action's
# exit code (0, 1, 3, 5, 137).
runner_run() {
    local id="$1" spec path rc=0 run_id skipped="" log
    path=$(api_find_action "$id") || {
        ev_error 1 "unknown action: $id"
        return 1
    }
    spec=$(cat "$path") || { ev_error 1 "unreadable spec: $path"; return 1; }

    run_id="${API_RUN_ID:-$(date +%s)-$$}"
    ev_start "$id" "$run_id"

    runner_preflight "$spec" "${API_FORCE:-0}" || { ev_done 3 "[]"; return 3; }

    # A destructive spec must be confirmed explicitly. The TUI asks a human; the API
    # has no human, so --yes is the only acceptable proof of intent.
    if [ "$(printf '%s' "$spec" | jq -r '.destructive // false')" = "true" ] \
       && [ "${ASSUME_YES:-0}" -ne 1 ]; then
        ev_error 4 "action '$id' is destructive: re-run with --yes to confirm"
        ev_done 4 "[]"
        return 4
    fi

    state_begin "$id" "$run_id" '{}' >/dev/null 2>&1 || true
    log=$(log_path "$id")
    : >> "$log" 2>/dev/null || true
    # Record how this run was invoked, in the step's own log.
    #
    # The result bundle tells a caller nothing about the flags it used, so "did the app send
    # --fast?" used to be unanswerable from a device that felt slow. One line here makes it a
    # grep, and it is per-run so it cannot be confused with yesterday's invocation.
    {
        printf '=== %s %s (run %s)\n' "$(date -u +%FT%TZ)" "$id" "$run_id"
        printf '=== argv: %s\n' "${ORIGINAL_ARGS[*]:-(none)}"
    } >> "$log" 2>/dev/null || true

    # Steps that produce structured output write it to this file; the runner
    # emits it as a `data` event. A file keeps the NDJSON stream clean, so a
    # primitive can still print freely to its log.
    RUNNER_RESULT=$(mktemp 2>/dev/null) || RUNNER_RESULT=""
    export RUNNER_RESULT

    local step s_id s_title s_run s_when s_optional s_idem s_fp s_retry t0 t1 ms attempt max log_from
    while IFS= read -r step; do
        [ -n "$step" ] || continue
        s_id=$(printf '%s' "$step" | jq -r '.id // empty')
        s_title=$(printf '%s' "$step" | jq -r '.title // .id // ""')
        s_run=$(printf '%s' "$step" | jq -r '.run // empty')
        s_when=$(printf '%s' "$step" | jq -r '.when // empty')
        s_optional=$(printf '%s' "$step" | jq -r '.optional // false')
        s_idem=$(printf '%s' "$step" | jq -r '.idempotent // false')
        # Parameters are part of what the step does, so they belong in the fingerprint:
        # stopping `openclaw` must not count as having stopped `n8n`.
        s_fp=$(state_step_fingerprint "$step ${API_PARAMS:-{}}")
        s_retry=$(printf '%s' "$step" | jq -r '.retry_on_sigkill // 0')

        if ! runner_when "$s_when"; then
            ev_step "$s_id" "skipped" "$s_title (guard: $s_when)" 0
            skipped="$skipped $s_id"
            continue
        fi

        # Skip only steps the spec marks idempotent. A query-like step (status
        # snapshot) must run every time: skipping it produced a stream with no
        # `data` event, and every consumer — including the app's readiness probe —
        # read that as failure. Observed on 8x, 2026-11-22.
        if [ "${s_idem:-false}" = "true" ] && [ "${API_FRESH:-0}" -ne 1 ] \
           && state_step_ok "$id" "$s_id" "$s_fp"; then
            ev_step "$s_id" "skipped" "$s_title (already done)" 0
            skipped="$skipped $s_id"
            continue
        fi

        if ! command -v "$s_run" >/dev/null 2>&1; then
            ev_step "$s_id" "failed" "$s_title — unknown step primitive: $s_run" 0
            ev_done 1 "[]"
            return 1
        fi

        attempt=1
        max=$(( s_retry + 1 ))
        while :; do
            ev_step "$s_id" "running" "$s_title" 0
            [ -n "$RUNNER_RESULT" ] && : > "$RUNNER_RESULT"
            log_from=$(( $(wc -c < "$log" 2>/dev/null || echo 0) + 1 ))
            t0=$(date +%s)
            "$s_run" "$step" "$spec" "${API_PARAMS:-{}}" >> "$log" 2>&1
            rc=$?
            t1=$(date +%s)
            ms=$(( (t1 - t0) * 1000 ))

            if [ "$rc" -eq 0 ]; then
                state_mark "$id" "$s_id" ok "$ms" "$s_fp" >/dev/null 2>&1 || true
                ev_step "$s_id" "ok" "$s_title" "$ms"
                if [ -n "$RUNNER_RESULT" ] && [ -s "$RUNNER_RESULT" ] \
                   && jq -e . "$RUNNER_RESULT" >/dev/null 2>&1; then
                    ev_data "$s_id" "$(cat "$RUNNER_RESULT")"
                fi
                break
            fi

            # 128+n is death by signal n; 137 = SIGKILL, Android's memory killer.
            if [ "$rc" -ge 128 ] && [ "$attempt" -lt "$max" ]; then
                ev_log "$s_id" "killed (signal $((rc - 128))) — attempt $attempt/$max, retrying after the store is warm"
                attempt=$(( attempt + 1 ))
                sleep 15
                continue
            fi

            state_mark "$id" "$s_id" failed "$ms" "$s_fp" >/dev/null 2>&1 || true
            ev_step "$s_id" "failed" "$s_title" "$ms"
            # Why it failed, for a client that cannot read the log file.
            runner_replay_tail "$s_id" "$log" "$log_from" 12
            if [ "$s_optional" = "true" ]; then
                ev_log "$s_id" "optional step failed (code $rc) — continuing"
                break
            fi
            ev_done "$rc" "[]"
            return "$rc"
        done
    done <<EOF
$(printf '%s' "$spec" | jq -c '.steps[]?')
EOF

    state_finish "$id" >/dev/null 2>&1 || true
    rm -f "${RUNNER_RESULT:-}"
    ev_done 0 "$(printf '%s' "$skipped" | jq -Rc 'split(" ") | map(select(length > 0))')"
    return 0
}

# api_dispatch -- entry point for `install.sh --api …`
api_dispatch() {
    case "${API_CMD:-}" in
        list)
            api_catalog
            return 0
            ;;
        status)
            # Read-only, so it is safe to run without Termux (useful for local
            # testing); missing probes simply come back empty.
            runner_run status
            return $?
            ;;
        health)
            # The cheap question the supervisor asks on every unlock: which processes are
            # alive. Pure bash (lib/health.sh) — no Node, no jq, no `pm2 jlist`.
            local _health
            _health=$(mktemp 2>/dev/null) || _health=""
            if [ -z "$_health" ]; then
                ev_error 1 "cannot create a temporary file for the health report"
                return 1
            fi
            ev_start health "${API_RUN_ID:-$(date +%s)-$$}"
            if health_collect "$_health"; then
                ev_data health "$(cat "$_health")"
                rm -f "$_health"
                ev_done 0 "[]"
                return 0
            fi
            rm -f "$_health"
            ev_error 1 "could not read the health of the toolkit"
            return 1
            ;;
        run)
            if [ -z "${API_ACTION:-}" ]; then
                ev_error 2 "missing action id: --api run <action-id>"
                return 2
            fi
            if [ -z "${TERMUX_VERSION:-}" ] && [ ! -d /data/data/com.termux ]; then
                ev_error 3 "not running inside Termux"
                return 3
            fi
            runner_run "$API_ACTION"
            return $?
            ;;
        *)
            ev_error 2 "usage: install.sh --api <list|status|health|run> [--answers FILE] [--fresh] [--yes]"
            return 2
            ;;
    esac
}

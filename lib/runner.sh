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

# api_catalog -- every spec that declares itself valid, as one JSON document.
# The app renders this; adding a tool must not require an APK release.
api_catalog() {
    local dir found
    dir=$(runner_actions_dir)
    if [ -d "$dir" ]; then
        found=$(find "$dir" -type f -name '*.json' 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            find "$dir" -type f -name '*.json' -print0 2>/dev/null \
                | xargs -0 jq -c 'select(.schema == 1 and (.id | type) == "string")' 2>/dev/null \
                | jq -cs '{schema:1, actions: sort_by(.category, .title)}'
            return 0
        fi
    fi
    printf '{"schema":1,"actions":[]}\n'
}

# api_find_action <id> -- path to the spec, or non-zero when unknown
api_find_action() {
    local id="$1" dir f
    dir=$(runner_actions_dir)
    [ -d "$dir" ] || return 1
    while IFS= read -r f; do
        [ "$(jq -r '.id // empty' "$f" 2>/dev/null)" = "$id" ] || continue
        printf '%s' "$f"
        return 0
    done <<EOF
$(find "$dir" -type f -name '*.json' 2>/dev/null)
EOF
    return 1
}

# runner_preflight <spec> -- emits the preflight event; 0 ok, 3 refused.
runner_preflight() {
    local spec="$1" arch allowed mem disk min_mem min_disk ok=1
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
    [ "${mem:-0}" -lt "${min_mem:-0}" ] && ok=0
    [ "${disk:-0}" -lt "${min_disk:-0}" ] && ok=0

    # Named preconditions a spec can require (probe.sh predicates). Used for things a
    # numeric threshold cannot express, e.g. "a warm wheel cache exists" — without one,
    # pip would compile cryptography for 30-90 minutes and probably be OOM-killed.
    local preds p failed=""
    preds=$(printf '%s' "$spec" | jq -r '(.requires.predicates // []) | join(" ")')
    for p in $preds; do
        if ! pred_apply "$p"; then
            failed="$failed $p"
            ok=0
        fi
    done

    if [ "$ok" -eq 1 ]; then
        ev_preflight true "$arch" "${mem:-0}" "${disk:-0}"
        return 0
    fi
    ev_preflight false "$arch" "${mem:-0}" "${disk:-0}"
    ev_log preflight "refused: arch=$arch (allowed: ${allowed:-any}) mem=${mem}MB (need ${min_mem}MB) disk=${disk}MB (need ${min_disk}MB)${failed:+ unmet:${failed}}"
    return 3
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

    runner_preflight "$spec" || { ev_done 3 "[]"; return 3; }

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

    # Steps that produce structured output write it to this file; the runner
    # emits it as a `data` event. A file keeps the NDJSON stream clean, so a
    # primitive can still print freely to its log.
    RUNNER_RESULT=$(mktemp 2>/dev/null) || RUNNER_RESULT=""
    export RUNNER_RESULT

    local step s_id s_title s_run s_when s_optional s_idem s_fp s_retry t0 t1 ms attempt max
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
            ev_error 2 "usage: install.sh --api <list|status|run> [--answers FILE] [--fresh] [--yes]"
            return 2
            ;;
    esac
}

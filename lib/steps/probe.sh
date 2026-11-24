#!/bin/bash
# lib/steps/probe.sh -- predicates usable from a spec's "when" field.
#
# Closed set, on purpose: `when` names one of these functions and nothing else.
# No expressions, no operators, no mini-language. A spec DSL that can compute
# will grow until it needs its own interpreter, which is the thing this refactor
# is trying to remove.

pred_is_termux() {
    [ -d "/data/data/com.termux" ] || [ -n "${TERMUX_VERSION:-}" ]
}

pred_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

pred_pm2_has() {
    command -v pm2 >/dev/null 2>&1 || return 1
    pm2 jlist 2>/dev/null | jq -e --arg n "$1" 'any(.[]; .name == $n)' >/dev/null 2>&1
}

pred_mem_available_gte() {
    local have need="${1:-0}"
    have=$(pf_mem_available_mb)
    [ "${have:-0}" -ge "$need" ]
}

# Hermes and Nanobot cannot work on 32-bit ARM: jiter has no armv7 Android wheel
# and maturin rejects armv8l outright (install.sh::_guard_armv8l).
pred_supports_hermes() {
    case "$(pf_arch)" in
        armv8l|armv7l) return 1 ;;
    esac
    return 0
}

pred_supports_jiter() {
    pred_supports_hermes
}

# A warm pnpm store is what makes a re-install survivable on a low-RAM device;
# from a cold store the same operation is the one that gets SIGKILLed.
pred_has_warm_pnpm_store() {
    local root
    root=$(pnpm root -g 2>/dev/null | sed -n '$p')
    [ -n "$root" ] && [ -d "$root/../.pnpm" ] || [ -n "$(ls -A "$root" 2>/dev/null)" ]
}

# pred_apply <name> [arg] -- evaluate a predicate by name, for spec "when" fields.
# A warm wheel cache is what separates a seconds-long install from a 30-90 minute
# source build for cryptography/jiter on Android.
pred_has_wheel_cache() {
    local cache="${HERMES_WHEEL_CACHE:-$HOME/~}"
    cache="${HERMES_WHEEL_CACHE:-$HOME/.hermes/wheel-cache}"
    [ -d "$cache" ] && [ -n "$(ls -A "$cache" 2>/dev/null)" ]
}

# Is there a jiter wheel built for THIS interpreter's ABI?
#
# "A wheel cache exists" is too weak a gate: on 8x the cache holds jiter cp313 wheels
# while the system python is 3.14, so pip still had to compile — which is the 30-90
# minute build this is meant to prevent. jiter is the binding constraint for anything
# that depends on anthropic (nanobot, hermes).
pred_has_matching_jiter_wheel() {
    local cache mm
    cache="${HERMES_WHEEL_CACHE:-$HOME/.hermes/wheel-cache}"
    [ -d "$cache" ] || return 1
    mm=$(python3 -c 'import sys; print("cp%d%d" % sys.version_info[:2])' 2>/dev/null) || return 1
    local f
    for f in "$cache"/jiter-*-"$mm"-*android*; do
        [ -e "$f" ] && return 0
    done
    return 1
}

pred_apply() {
    local name="$1"; shift
    if [ -z "$name" ]; then
        return 0
    fi
    if ! command -v "pred_$name" >/dev/null 2>&1; then
        # An unknown predicate is a spec bug. Fail closed so a step does not run
        # because its guard could not be understood.
        return 1
    fi
    "pred_$name" "$@"
}

# pred_pkg_available <name> -- does the Termux repo carry this package for THIS cpu?
#
# A missing package is a preflight fact, not a runtime failure: without this the app
# downloads nothing, runs `pkg install`, and reports "Step failed: Install package" with
# the real reason (E: Unable to locate package) buried in a log (y6, 2026-11-24).
#
# Only answers on a device with apt-cache; elsewhere it returns 0 ("do not block"), since
# a non-Termux host is not something this predicate can judge.
pred_pkg_available() {
    local name="${1:-}" candidate
    [ -n "$name" ] || return 1
    command -v apt-cache >/dev/null 2>&1 || return 0
    candidate=$(apt-cache policy "$name" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
    [ -n "$candidate" ] && [ "$candidate" != "(none)" ]
}

# pred_postgres_running -- Paperclip needs PostgreSQL up before it starts; it has no
# way to bring the cluster up itself.
#
# The two halves must not be alternatives. On 8x `pg_isready` exists and reports the
# server down, but the old fallback `pgrep -f postgres` then matched **`runsv postgres`**
# — the Termux service supervisor, not the database — so the gate passed and a ~2 GB
# Paperclip install started against a dead cluster (2026-11-24, with --force overriding
# the memory gate on top). A supervisor says nothing about whether 5432 answers.
pred_postgres_running() {
    if command -v pg_isready >/dev/null 2>&1; then
        pg_isready -q -h 127.0.0.1 -p 5432 2>/dev/null
        return
    fi
    # No pg_isready to ask: accept only a postmaster, never a wrapper around it.
    pgrep -x postgres >/dev/null 2>&1 || pgrep -f "postgres -D" >/dev/null 2>&1
}

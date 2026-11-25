#!/usr/bin/env bash
# tests/lib.sh -- a very small assertion library for the engine tests.
#
# Deliberately not bats: the CI image already has bash and jq, and an extra test
# framework is another dependency to install before a PR can be checked. Each test
# script sources this file, calls `t_*`, and exits with `t_exit`.
#
# Everything the engine might write goes into a throwaway HOME/STATE_ROOT supplied by
# `t_init`, so a test run can never touch the developer's real toolkit state.

set -uo pipefail

TESTS_PASS=0
TESTS_FAIL=0
TESTS_NAME=""

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=""

# t_begin <name> -- announce one test script.
t_begin() {
    TESTS_NAME="$1"
    printf '\n== %s\n' "$TESTS_NAME"
}

# t_init -- a temp HOME + state root, and the engine command.
#
# `install.sh` is invoked exactly the way the app invokes it, so the tests exercise the
# real entry point (argument parsing, the LD_PRELOAD guard, the lib loading order) rather
# than an internal function that could drift from it.
t_init() {
    TMP_ROOT=$(mktemp -d 2>/dev/null) || TMP_ROOT="/tmp/droidai-tests.$$"
    mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/state"
    export HOME="$TMP_ROOT/home"
    export STATE_ROOT="$TMP_ROOT/state"
    # jq is the one hard requirement of the --api interface; say so plainly.
    command -v jq >/dev/null 2>&1 || {
        printf 'FATAL: jq is required to run the engine tests\n' >&2
        exit 2
    }
}

# engine <args...> -- run install.sh --api … and capture stdout/stderr/exit code.
#
# Sets OUT, ERR, RC. Written to a file, not to a variable through command substitution, so
# a non-zero exit can be asserted without `|| true` swallowing the code.
engine() {
    OUT_FILE="$TMP_ROOT/out"
    ERR_FILE="$TMP_ROOT/err"
    ( cd "$REPO_ROOT" && bash install.sh --api "$@" ) >"$OUT_FILE" 2>"$ERR_FILE"
    RC=$?
    OUT=$(cat "$OUT_FILE")
    ERR=$(cat "$ERR_FILE")
}

t_cleanup() {
    [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT"
}

_ok() {
    TESTS_PASS=$((TESTS_PASS + 1))
    printf '  PASS  %s\n' "$1"
}

_bad() {
    TESTS_FAIL=$((TESTS_FAIL + 1))
    printf '  FAIL  %s\n' "$1"
    if [ -n "${2:-}" ]; then
        printf '        %s\n' "$2"
    fi
}

# t_eq <expected> <actual> <label>
t_eq() {
    if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3" "expected [$1], got [$2]"; fi
}

# t_nonzero <rc> <label>
t_nonzero() {
    if [ "${1:-0}" -ne 0 ]; then _ok "$2"; else _bad "$2" "exit code was 0"; fi
}

# t_contains <haystack> <needle> <label>
t_contains() {
    case "$1" in
        *"$2"*) _ok "$3" ;;
        *) _bad "$3" "not found: [$2]" ;;
    esac
}

# t_not_contains <haystack> <needle> <label>
t_not_contains() {
    case "$1" in
        *"$2"*) _bad "$3" "unexpected: [$2]" ;;
        *) _ok "$3" ;;
    esac
}

# t_json <document> <label> -- is this valid JSON at all?
t_json() {
    if printf '%s' "$1" | jq -e . >/dev/null 2>&1; then
        _ok "$2"
    else
        _bad "$2" "not valid JSON: $(printf '%.200s' "$1")"
    fi
}

# t_ndjson <stream> <label> -- every non-empty line is one JSON object.
#
# This is the whole contract with the app: one object per line, nothing else on stdout. A
# stray `echo` in a step primitive corrupts the stream, and the app can only report "the
# answer was not something it understands".
t_ndjson() {
    local line bad=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
            bad="$line"
            break
        fi
    done <<< "$1"
    if [ -z "$bad" ]; then
        _ok "$2"
    else
        _bad "$2" "non-JSON stdout line: $(printf '%.200s' "$bad")"
    fi
}

# t_field <stream> <jq-filter> <expected> <label> -- assert one value inside NDJSON.
t_field() {
    local got
    got=$(printf '%s\n' "$1" | jq -s -r "$2" 2>/dev/null)
    t_eq "$3" "$got" "$4"
}

# t_jq_true <stream> <filter> <label> -- assert a jq expression is true.
#
# Kept in one place because a filter written inline in an `$( )` is where quoting and
# multiline bugs hide; a failed jq *compile* must read as a test failure, not as "empty".
t_jq_true() {
    if printf '%s\n' "$1" | jq -s -e "$2" >/dev/null 2>&1; then
        _ok "$3"
    else
        _bad "$3" "jq filter was false: $2"
    fi
}

t_exit() {
    if [ "$TESTS_FAIL" -eq 0 ]; then
        printf '  %s: %d passed\n' "$TESTS_NAME" "$TESTS_PASS"
        exit 0
    fi
    printf '  %s: %d passed, %d FAILED\n' "$TESTS_NAME" "$TESTS_PASS" "$TESTS_FAIL"
    exit 1
}

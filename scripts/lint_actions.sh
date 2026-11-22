#!/bin/bash
# scripts/lint_actions.sh -- validate every action spec.
#
# Specs are data, and data fails quietly: a typo'd `run` is only discovered when the
# action is executed on a device, and a missing `id` breaks the catalog the app reads.
# This is the cheap check that runs before any of that.

set -u

DIR="${1:-actions}"
[ -d "$DIR" ] || { echo "no such directory: $DIR"; exit 1; }

# Every callable step primitive, from the files the API path sources.
prims=$(grep -hoE '^[a-z_][a-z0-9_]*\(\)' lib/steps/*.sh lib/runner.sh 2>/dev/null \
    | tr -d '()' | sort -u)

fail=0
ids=""

while IFS= read -r f; do
    [ -n "$f" ] || continue

    if ! jq -e . "$f" >/dev/null 2>&1; then
        echo "$f: invalid JSON"
        fail=1
        continue
    fi

    schema=$(jq -r '.schema // empty' "$f")
    [ "$schema" = "1" ] || { echo "$f: schema must be 1 (got '${schema:-none}')"; fail=1; }

    id=$(jq -r '.id // empty' "$f")
    if [ -z "$id" ]; then
        echo "$f: missing id"
        fail=1
    else
        case "$id" in
            *[!a-z0-9.-]*) echo "$f: id '$id' must be lowercase letters, digits, dot or dash"; fail=1 ;;
        esac
        if printf '%s\n' "$ids" | grep -qxF "$id"; then
            echo "$f: duplicate id '$id'"
            fail=1
        fi
        ids="$ids
$id"
    fi

    jq -e '.title and .summary and .category' "$f" >/dev/null 2>&1 \
        || { echo "$f: title, summary and category are required"; fail=1; }

    for key in destructive idempotent; do
        val=$(jq -r --arg k "$key" 'if has($k) then (.[$k] | type) else "absent" end' "$f")
        case "$val" in
            absent|boolean) ;;
            *) echo "$f: $key must be a boolean"; fail=1 ;;
        esac
    done

    n=$(jq -r '.steps | length' "$f" 2>/dev/null)
    if [ "${n:-0}" -eq 0 ]; then
        echo "$f: needs at least one step"
        fail=1
        continue
    fi

    i=0
    while [ "$i" -lt "$n" ]; do
        sid=$(jq -r --argjson i "$i" '.steps[$i].id // empty' "$f")
        run=$(jq -r --argjson i "$i" '.steps[$i].run // empty' "$f")
        [ -n "$sid" ] || { echo "$f: steps[$i] has no id"; fail=1; }
        if [ -z "$run" ]; then
            echo "$f: steps[$i] ('$sid') has no run"
            fail=1
        elif ! printf '%s\n' "$prims" | grep -qxF "$run"; then
            echo "$f: steps[$i] ('$sid') runs '$run', which no lib/steps/*.sh defines"
            fail=1
        fi
        if jq -e --argjson i "$i" '.steps[$i].args | type != "object"' "$f" >/dev/null 2>&1; then
            [ "$(jq -r --argjson i "$i" '.steps[$i].args | type' "$f")" = "null" ] \
                || { echo "$f: steps[$i].args must be an object"; fail=1; }
        fi
        i=$((i + 1))
    done
done <<< "$(find "$DIR" -type f -name '*.json' | sort)"

if [ "$fail" -ne 0 ]; then
    echo "action spec lint: FAILED"
    exit 1
fi

count=$(find "$DIR" -type f -name '*.json' | wc -l | tr -d ' ')
echo "action spec lint: $count spec(s) OK"

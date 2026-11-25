#!/usr/bin/env bash
# tests/run.sh -- run every engine test.
#
# CI runs this (`bash tests/run.sh`); so can a developer, with no device and no Termux.
# The tests treat `install.sh --api …` as a black box: they assert the contract in
# docs/CONTRACT.md, which is what the app depends on.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
ran=0

for t in "$ROOT"/tests/engine/*_test.sh; do
    [ -f "$t" ] || continue
    ran=$((ran + 1))
    if ! bash "$t"; then
        fail=$((fail + 1))
    fi
done

if [ "$ran" -eq 0 ]; then
    printf 'no engine tests found\n' >&2
    exit 2
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
    printf '%d of %d test script(s) FAILED\n' "$fail" "$ran"
    exit 1
fi
printf 'all %d engine test script(s) passed\n' "$ran"

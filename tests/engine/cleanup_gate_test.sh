#!/usr/bin/env bash
# tests/engine/cleanup_gate_test.sh -- the legacy cleanup refuses before the tap (F7).
#
# The action removes the pre-migration shared pnpm folder. It used to be always offered and to
# answer "done" whether it removed 12.9 GB or nothing at all; on a device where a tool still runs
# from that folder it failed *after* the tap with "Step failed: Remove legacy project and shims".
#
# Now the two facts it depends on are declared in the spec, so the engine refuses in preflight
# and the app can show the same reason with the button already disabled.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

t_begin "engine: legacy cleanup gate"
t_init
trap t_cleanup EXIT

# ---- the status document carries the facts the panel needs ------------------------------

engine status --fast
t_eq "false" \
    "$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "data")][0].payload.termux.legacy_global.present')" \
    "status reports whether the legacy folder exists"
t_eq "number" \
    "$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "data")][0].payload.termux.legacy_global.mb | type')" \
    "status reports its size as a number"
t_eq "0" \
    "$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "data")][0].payload.termux.legacy_global.mb')" \
    "--fast does not measure the size (du over a 13 GB tree is not a polling cost)"

# The predicates are evaluated in `checks`, which is what lets the app disable the button.
t_eq "false" \
    "$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "data")][0].payload.checks.legacy_global_present')" \
    "checks carry legacy_global_present"
t_eq "false" \
    "$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "data")][0].payload.checks.tools_migrated')" \
    "checks carry tools_migrated"

# ---- and the action refuses in preflight, naming both ---------------------------------

export TERMUX_VERSION="0.119.0-test"
engine run service.cleanup-legacy --yes
t_eq 3 "$RC" "the cleanup is refused before doing any work"
t_contains "$OUT" "unmet:" "the refusal names the unmet predicates"
t_contains "$OUT" "legacy_global_present" "it names legacy_global_present"
t_contains "$OUT" "tools_migrated" "it names tools_migrated"
t_not_contains "$OUT" '"state":"running"' "no step was started before the refusal"
unset TERMUX_VERSION

# ---- a device that has the folder still reports present=true --------------------------
#
# The CI host has no such tree, so this asserts the branch that matters instead: with the
# directory present, present flips and the size is reported by a full read.

mkdir -p "$HOME/.local/share/pnpm/global/5/node_modules"
engine status
t_eq "true" \
    "$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "data")][0].payload.termux.legacy_global.present')" \
    "an existing legacy folder reads present=true"
t_eq "true" \
    "$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "data")][0].payload.checks.legacy_global_present')" \
    "the predicate agrees with the fact"

t_exit

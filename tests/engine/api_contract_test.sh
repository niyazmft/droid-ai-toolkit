#!/usr/bin/env bash
# tests/engine/api_contract_test.sh -- the `--api` surface the app depends on.
#
# Every assertion here maps to a sentence in docs/CONTRACT.md. When one of these fails,
# the app is either showing something wrong or cannot read the stream at all, and neither
# is visible from a unit test on the Kotlin side.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

t_begin "engine: --api contract"
t_init
trap t_cleanup EXIT

# ---- list ----------------------------------------------------------------------------

engine list
t_eq 0 "$RC" "--api list exits 0"
t_json "$OUT" "--api list emits one JSON document"
t_eq 1 "$(printf '%s' "$OUT" | jq -r '.schema')" "catalog declares schema 1"
t_nonzero "$(printf '%s' "$OUT" | jq -r '.actions | length')" "catalog has actions"

# One spec file, one entry. A catalog that silently drops a tool is how y6 rendered
# "0 of 0 installed" with 40 specs on disk.
spec_files=$(find "$REPO_ROOT/actions" -name '*.json' | wc -l | tr -d ' ')
t_eq "$spec_files" "$(printf '%s' "$OUT" | jq -r '.actions | length')" "every spec file appears in the catalog"

t_eq 0 "$(printf '%s' "$OUT" | jq -r '[.actions[] | select((.id | type) != "string" or (.title | type) != "string" or (.category | type) != "string" or (.steps | type) != "array")] | length')" \
    "every action has a string id, title, category and a steps array"

t_eq 0 "$(printf '%s' "$OUT" | jq -r '[.actions[].id] | length - (unique | length)')" \
    "action ids are unique"

# ---- status --fast -------------------------------------------------------------------

engine status --fast
t_eq 0 "$RC" "--api status --fast exits 0"
t_ndjson "$OUT" "status --fast is pure NDJSON"
t_field "$OUT" '[.[] | select(.t == "start")][0].action' "status" "status opens with a start event"
t_field "$OUT" '[.[] | select(.t == "data")][0].kind' "snapshot" "status emits one snapshot payload"
t_field "$OUT" '[.[] | select(.t == "done")][0].code' "0" "status reports done 0"

# The fields the app reads are present and typed, not merely non-empty.
t_jq_true "$OUT" '
    [.[] | select(.t == "data")][0].payload
    | ((.device.mem_available_mb | type) == "number")
      and ((.device.disk_free_mb | type) == "number")
      and ((.services | type) == "array")
      and ((.tools.installed | type) == "object")
      and ((.checks | type) == "object")
' "snapshot carries device numbers, services, installed flags and checks"

# --fast must leave the expensive version strings blank: they are what the flag exists to
# avoid (each probe starts a Node/Python runtime), and the app must never read a blank
# version as "not installed" — which is what tools.installed is for.
t_eq "" "$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "data")][0].payload.tools.openclaw')" \
    "status --fast leaves tool versions blank"

# The step log records the argv, which is the only way to answer "did the caller actually send
# --fast?" from a device later. (The result bundle carries output, not the invocation.)
logfile=$(find "$STATE_ROOT/log" -name "status-*.log" -print 2>/dev/null | sort | tail -1)
t_contains "$(cat "$logfile" 2>/dev/null)" "argv: --api status --fast" \
    "the run log records the invocation flags"

# ---- errors --------------------------------------------------------------------------

engine nope
t_eq 2 "$RC" "an unknown command exits 2"
t_eq 2 "$(printf '%s\n' "$OUT" | jq -s -r '[.[] | select(.t == "error")][0].code')" \
    "an unknown command explains itself with an error event"

engine run
t_eq 2 "$RC" "--api run without an action id exits 2"

# Somewhere that is not Termux: the engine refuses before touching the device, and says
# so with an error event rather than a bare exit code. The app turns that into a screen.
engine run service.restart
t_eq 3 "$RC" "a mutation outside Termux exits 3"
t_contains "$OUT" "not running inside Termux" "a mutation outside Termux says why"

# Past that guard, an unknown action must fail as "unknown action" (exit 1), which is how
# the app tells "you asked for something this build does not have" from "the device said no".
export TERMUX_VERSION="0.119.0-test"
engine run definitely.not.an.action
t_eq 1 "$RC" "an unknown action id exits 1"
t_contains "$OUT" "unknown action" "an unknown action id names the action"
unset TERMUX_VERSION

# ---- status without --fast -----------------------------------------------------------
#
# Not an expensive run on CI (no tools installed there), but it must stay the same shape:
# the app accepts a full snapshot only from this form, and it is what fills Packages.

engine status
t_eq 0 "$RC" "--api status exits 0"
t_ndjson "$OUT" "a full status is still pure NDJSON"
t_field "$OUT" '[.[] | select(.t == "data")][0].kind' "snapshot" "a full status emits a snapshot"

t_exit

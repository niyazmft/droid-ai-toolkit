#!/usr/bin/env bash
# tests/engine/usage_test.sh -- the ledger that proves the Tier-1 savings.
#
# The point of this file is that the numbers are *true*: two unit mistakes were made while
# writing lib/usage.sh and both produced plausible-looking ledgers — `times` read as
# centiseconds made an 0.85 s run report 8.5 s, and reading `times` inside a command
# substitution made every run report 0.00. A ledger nobody can trust is worse than none, so the
# fields are asserted against what the shell can observe independently.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

t_begin "engine: usage ledger"
t_init
trap t_cleanup EXIT

LEDGER="$STATE_ROOT/usage.ndjson"

# ---- one line per run, with the command it described -----------------------------------

engine health
engine status --fast
engine status
engine list

lines=$(wc -l < "$LEDGER" | tr -d ' ')
t_eq 4 "$lines" "each --api command appends exactly one ledger line"
t_ndjson "$(cat "$LEDGER")" "the ledger is NDJSON"

t_eq "health,status,status,list" \
    "$(jq -r '.cmd' "$LEDGER" | paste -sd, -)" \
    "the ledger records each command in order"
t_eq "0,1,0,0" \
    "$(jq -r '.fast' "$LEDGER" | paste -sd, -)" \
    "only the --fast status is marked fast"

# ---- the numbers are not zeros, and the wall time is real -------------------------------

t_eq "0" "$(jq -r 'map(select(.user_s <= 0 or .sys_s <= 0)) | length' -s "$LEDGER")" \
    "every run recorded CPU (the times-in-a-subshell bug reports 0.00)"

t_eq "0" "$(jq -r 'map(select(.wall_ms < 0)) | length' -s "$LEDGER")" \
    "wall_ms is never negative"

t_eq "0" "$(jq -r 'map(select(.ts <= 0)) | length' -s "$LEDGER")" \
    "every run carries a timestamp"

t_eq "number" "$(jq -r -s '.[0].node_procs | type' "$LEDGER")" \
    "node_procs is a number (the 'did this unlock boot a runtime' counter)"

# A status read is the expensive one; health is the cheap one. If a future change made health
# cost as much as status, this is where it would show up as a *number* rather than a feeling.
t_eq "true" "$(jq -r -s 'map(select(.cmd == "health")) | .[0].wall_ms <= (map(select(.cmd == "status")) | .[0].wall_ms + 1)' "$LEDGER")" \
    "health is no slower than a status read"

# ---- the report reads it -----------------------------------------------------------------

REPORT="$REPO_ROOT/scripts/usage_report.sh"
if command -v column >/dev/null 2>&1; then
    out=$(USAGE_FILE="$LEDGER" bash "$REPORT" 2>&1)
    t_contains "$out" "health" "the report has a health column"
    t_contains "$out" "4 line(s)" "the report counts the ledger lines"
    # A row for today, not 1970: the ledger is milliseconds and the report has to agree.
    today=$(date -u +%Y-%m-%d)
    t_contains "$out" "$today" "the report dates the rows from the millisecond timestamp"
else
    printf '  SKIP  report (column(1) not available)\n'
fi

t_exit

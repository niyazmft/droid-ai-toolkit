#!/usr/bin/env bash
# scripts/usage_report.sh -- what the engine actually costs, from its own ledger.
#
# Every `install.sh --api …` run appends one line to `~/.droid_ai_toolkit/usage.ndjson`
# (lib/usage.sh). This summarises it, locally or on a device over SSH:
#
#   scripts/usage_report.sh            # this machine's ledger
#   scripts/usage_report.sh my-phone   # a device (ssh my-phone …)
#
# Why it exists: the Tier-1 work in TASKS.md is invisible — an app that re-reads status on
# launch feels identical to one that does not, until the battery or the low-memory killer says
# otherwise. This is the "before/after" evidence, and it costs one `cat`.

set -uo pipefail

HOST="${1:-}"
DAYS="${DAYS:-7}"
REMOTE_FILE="${REMOTE_FILE:-~/.droid_ai_toolkit/usage.ndjson}"

command -v jq >/dev/null 2>&1 || {
    printf 'jq is required (the ledger is NDJSON)\n' >&2
    exit 2
}

tmp=$(mktemp) || exit 2
trap 'rm -f "$tmp"' EXIT

if [ -n "$HOST" ]; then
    # shellcheck disable=SC2029  # REMOTE_FILE is meant to be expanded by the remote shell
    ssh "$HOST" "cat $REMOTE_FILE" > "$tmp" 2>/dev/null || {
        printf 'could not read %s on %s\n' "$REMOTE_FILE" "$HOST" >&2
        exit 2
    }
    printf 'Usage ledger on %s (%s)\n\n' "$HOST" "$REMOTE_FILE"
else
    cp "${USAGE_FILE:-$HOME/.droid_ai_toolkit/usage.ndjson}" "$tmp" 2>/dev/null || {
        printf 'no ledger yet: run something through install.sh --api first\n' >&2
        exit 2
    }
    printf 'Usage ledger locally\n\n'
fi

TAB=$(printf '\t')

printf 'day\truns\thealth\tstatus fast\tstatus full\tactions\twall avg\tuser CPU\n'

jq -s -r --argjson days "$DAYS" '
    def secs: if . >= 1000 then "\(. / 1000 | floor).\((. % 1000) / 100 | floor)s" else "\(.|floor)ms" end;
    (map(select(.ts > 0)) | sort_by(.ts) | reverse
     | (.[0].ts // 0) as $newest
     | map(select($newest - .ts <= ($days * 86400000)))) as $runs
    | if ($runs | length) == 0 then "no runs in the last \($days) days"
      else
        [ $runs[] | . + {d: (.ts / 1000 | todate[0:10])} ]
        | group_by(.d)
        | sort_by(.[0].d)
        | .[] as $day
        | [ $day[0].d,
            ($day | length | tostring),
            ($day | map(select(.cmd == "health")) | length | tostring),
            ($day | map(select(.cmd == "status" and .fast == 1)) | length | tostring),
            ($day | map(select(.cmd == "status" and (.fast == 1 | not))) | length | tostring),
            ($day | map(select(.cmd == "run")) | length | tostring),
            ((($day | map(.wall_ms) | add) / ($day | length)) | secs),
            (((($day | map(.user_s) | add) * 1000) | floor) | secs) ]
        | @tsv
      end
' "$tmp" | column -t -s "$TAB"

printf '\nLedger: %s line(s)\n' "$(wc -l < "$tmp" | tr -d ' ')"

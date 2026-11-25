#!/usr/bin/env bash
# tests/engine/boot_facts_test.sh -- "will my services come back after a reboot?" (F6).
#
# The Settings row used to answer that with "is the Termux:Boot app installed", which can be
# true while no boot script exists and `pm2 save` never ran — a phone that returns to nothing.
# Three facts, so three checks. These call the primitives directly with a throwaway HOME: no
# device, no pm2, no daemon.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

t_begin "engine: boot facts"
t_init
trap t_cleanup EXIT

# shellcheck source=lib/steps/boot.sh
. "$REPO_ROOT/lib/steps/boot.sh"
# shellcheck source=lib/steps/status.sh
. "$REPO_ROOT/lib/steps/status.sh"

# ---- the boot script must exist AND be executable -------------------------------------
t_eq "false" "$(_st_boot_script)" "no script reads false"
mkdir -p "$HOME/.termux/boot"
printf '#!/bin/sh\n' > "$HOME/.termux/boot/start-pm2.sh"
t_eq "false" "$(_st_boot_script)" "a script without the executable bit reads false"
chmod +x "$HOME/.termux/boot/start-pm2.sh"
t_eq "true" "$(_st_boot_script)" "an executable script reads true"

# ---- the dump must exist AND list something ------------------------------------------
t_eq '{"present":false,"count":0}' "$(_st_pm2_dump)" "no dump reads absent"
mkdir -p "$HOME/.pm2"
printf '[]' > "$HOME/.pm2/dump.pm2"
t_eq '{"present":true,"count":0}' "$(_st_pm2_dump)" "an empty dump is present with zero entries"
printf '[{"name":"openclaw"},{"name":"n8n"}]' > "$HOME/.pm2/dump.pm2"
t_eq '{"present":true,"count":2}' "$(_st_pm2_dump)" "a dump lists what resurrect would restore"
printf 'not json' > "$HOME/.pm2/dump.pm2"
t_eq '{"present":true,"count":0}' "$(_st_pm2_dump)" "an unreadable dump counts zero rather than guessing"

# ---- the action exists and its steps are the three facts -----------------------------
engine list
t_eq 1 "$(printf '%s' "$OUT" | jq -r '[.actions[] | select(.id == "service.boot")] | length')" \
    "the catalog offers service.boot"
t_eq "boot_write,boot_save,boot_verify" \
    "$(printf '%s' "$OUT" | jq -r '.actions[] | select(.id == "service.boot") | [.steps[].id] | join(",")')" \
    "its steps write, save, then verify"
t_eq "false" \
    "$(printf '%s' "$OUT" | jq -r '.actions[] | select(.id == "service.boot") | .destructive')" \
    "setting up after reboot is not destructive"

# ---- status carries all three facts ---------------------------------------------------
engine status --fast
t_jq_true "$OUT" '
    [.[] | select(.t == "data")][0].payload.termux
    | (.boot_installed | type) == "boolean"
      and (.boot_script | type) == "boolean"
      and ((.pm2_dump | type) == "object")
      and ((.pm2_dump.count | type) == "number")
      and (.doze_whitelisted | type) == "boolean"
' "status reports the app, the script, the dump and the battery exemption"

t_exit

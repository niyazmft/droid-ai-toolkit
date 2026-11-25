#!/bin/bash
# lib/steps/boot.sh -- make services come back after a reboot, and prove what is in place.
#
# Why this is an action and not a fact
# -----------------------------------
# The Settings row used to read "Starts after reboot — set up / not set up", which only proved
# that the Termux:Boot *app* is installed (`pm list packages com.termux.boot`). It could say
# "set up" while no boot script existed and while `pm2 save` had never run — the exact state
# that leaves a phone with nothing running after a restart. Three separate things have to be
# true, so there are three checks and one button that fixes what is missing.
#
# The script itself is written by `setup_pm2_boot()` in install.sh: one template, one owner.
# Duplicating it here would be two sources of truth for a file Termux:Boot executes as root-
# equivalent at boot — the worst possible place to drift.

_boot_script() { printf '%s/start-pm2.sh' "$HOME/.termux/boot"; }

# _boot_dump_json -- {"present":bool,"count":n} for ~/.pm2/dump.pm2.
#
# The count is what makes the fact honest: a dump file that exists but lists nothing restores
# nothing, and "set up" would be a lie.
_boot_dump_json() {
    local dump="$HOME/.pm2/dump.pm2" count=0
    if [ ! -f "$dump" ]; then
        printf '{"present":false,"count":0}'
        return 0
    fi
    count=$(jq 'if type == "array" then length else 0 end' "$dump" 2>/dev/null)
    case "$count" in
        ''|*[!0-9]*) count=0 ;;
    esac
    printf '{"present":true,"count":%s}' "$count"
}

# step_boot_write -- write/replace the boot script (idempotent; the helper skips a no-op).
step_boot_write() {
    if ! command -v setup_pm2_boot >/dev/null 2>&1; then
        echo "setup_pm2_boot is not available in this entry point"
        return 1
    fi
    setup_pm2_boot silent || return 1
    local script
    script=$(_boot_script)
    if [ ! -f "$script" ]; then
        echo "refusing to report success: $script was not written"
        return 1
    fi
    chmod +x "$script" 2>/dev/null || true
    echo "boot script: $script"
    head -3 "$script"
    return 0
}

# step_boot_save -- record the current PM2 process list, which is what resurrect restores.
#
# `pm2 save` is the half that is easy to forget and impossible to see: the boot script runs
# `pm2 resurrect`, and with no dump that is a successful command that restores nothing.
step_boot_save() {
    command -v pm2 >/dev/null 2>&1 || {
        echo "pm2 is not installed, so there is no process list to save"
        return 1
    }
    if ! pm2 save >/dev/null 2>&1; then
        echo "pm2 save failed"
        return 1
    fi
    local dump
    dump=$(_boot_dump_json)
    echo "saved: $dump"
    case "$dump" in
        *'"present":true'*'"count":0'*)
            echo "refusing to report success: the dump lists no processes (start a service first)"
            return 1
            ;;
    esac
    return 0
}

# step_boot_verify -- the three facts, plus a data payload the app can show.
step_boot_verify() {
    local script dump boot_app=false boot_script=false doze=false ok=0
    script=$(_boot_script)
    [ -x "$script" ] && boot_script=true
    dump=$(_boot_dump_json)
    # `_st_boot_installed` lives in lib/steps/status.sh, which is sourced alongside this file.
    if command -v _st_boot_installed >/dev/null 2>&1; then
        [ "$(_st_boot_installed)" = "true" ] && boot_app=true
    fi
    if command -v _st_doze_whitelisted >/dev/null 2>&1; then
        [ "$(_st_doze_whitelisted)" = "true" ] && doze=true
    fi
    [ "$boot_script" = "true" ] && [ "$boot_app" = "true" ] && ok=1
    echo "boot app: $boot_app, script: $boot_script, doze: $doze, dump: $dump"
    if [ -n "${RUNNER_RESULT:-}" ]; then
        jq -nc --argjson app "$boot_app" --argjson script "$boot_script" \
            --argjson doze "$doze" --argjson dump "${dump:-{\}}" \
            '{boot_app: $app, boot_script: $script, doze_whitelisted: $doze, pm2_dump: $dump,
              tested: false}' > "$RUNNER_RESULT" 2>/dev/null || true
    fi
    [ "$ok" -eq 1 ]
}

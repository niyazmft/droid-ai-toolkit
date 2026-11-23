#!/bin/bash
# lib/steps/script.sh -- run an external installer script.

# step_run_script <step-json> -- run a script with a timeout, streaming its tail into
# the step log.
#
# Paperclip's installer is a 1 000-line standalone script (clone, patches, pnpm with
# LMK retries, prebuilt tarballs, PostgreSQL bootstrap). Re-implementing it inside a
# spec would duplicate all of that; calling it keeps one implementation.
step_run_script() {
    local step="$1" script secs
    script=$(printf '%s' "$step" | jq -r '.args.script // empty')
    secs=$(printf '%s' "$step" | jq -r '.args.timeout_s // 3600')

    if [ -z "$script" ]; then
        echo "step_run_script: missing args.script"
        return 1
    fi
    script=${script//\$HOME/$HOME}
    script=${script/#\~/$HOME}

    if [ ! -f "$script" ]; then
        echo "step_run_script: no script at $script"
        return 1
    fi

    echo "running $script (timeout ${secs}s)"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" bash "$script" 2>&1 | tail -40
        return "${PIPESTATUS[0]}"
    fi
    bash "$script" 2>&1 | tail -40
    return "${PIPESTATUS[0]}"
}

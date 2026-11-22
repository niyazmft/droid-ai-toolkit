#!/bin/bash
# lib/steps/service.sh -- service recovery.

# step_pm2_resurrect -- restore the saved process list, then make sure the gateway
# is actually up.
#
# `pm2 resurrect` alone is not enough: the dump only contains what was saved, and a
# gateway that crashed before `pm2 save` is simply absent. So this checks the live
# list afterwards and starts the gateway directly if needed.
step_pm2_resurrect() {
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "pm2 is not installed"
        return 1
    fi

    pm2 resurrect 2>&1 | tail -5 || true

    if pm2 jlist 2>/dev/null \
        | jq -e 'any(.[]; .name == "openclaw" and .pm2_env.status == "online")' >/dev/null 2>&1; then
        echo "gateway already online after resurrect"
        pm2 save >/dev/null 2>&1 || true
        return 0
    fi

    local bin limit opts
    bin=$(command -v openclaw 2>/dev/null) || {
        echo "openclaw is not installed; nothing to start"
        return 0
    }
    limit=$(get_mem_limit)
    opts=$(_oc_node_options "$limit")
    mkdir -p "$HOME/.openclaw/tmp"
    NODE_OPTIONS="$opts" OPENCLAW_TMP="$HOME/.openclaw/tmp" \
        pm2 start "$bin" --name openclaw --interpreter none -- gateway run 2>&1 | tail -3 || true
    pm2 save >/dev/null 2>&1 || true

    sleep 6
    if pm2 jlist 2>/dev/null \
        | jq -e 'any(.[]; .name == "openclaw" and .pm2_env.status == "online")' >/dev/null 2>&1; then
        echo "gateway started"
        return 0
    fi
    echo "gateway did not come up"
    return 1
}

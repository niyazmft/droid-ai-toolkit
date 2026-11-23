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

# step_pm2_service <step-json> <spec-json> <params-json>
#
# Per-service control. The service name comes from --arg service=<name>, not from the
# spec: one action can then act on whichever service the app is showing, instead of
# needing a spec per service.
step_pm2_service() {
    local step="$1" params="${3:-{}}" action name
    action=$(printf '%s' "$step" | jq -r '.args.action // empty')
    name=$(printf '%s' "$params" | jq -r '.service // empty')

    if [ -z "$name" ]; then
        echo "no service named: pass --arg service=<name>"
        return 1
    fi
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "pm2 is not installed"
        return 1
    fi
    if [ ! -f "$HOME/.pm2/pm2.pid" ]; then
        echo "the pm2 daemon is not running"
        return 1
    fi

    case "$action" in
        start|restart) pm2 restart "$name" 2>&1 | tail -3 ;;
        stop)          pm2 stop "$name" 2>&1 | tail -3 ;;
        *) echo "step_pm2_service: unknown action '$action'"; return 1 ;;
    esac
    pm2 save >/dev/null 2>&1 || true

    sleep 4
    local status
    status=$(pm2 jlist 2>/dev/null | jq -r --arg n "$name" '.[] | select(.name == $n) | .pm2_env.status' 2>/dev/null | head -1)
    echo "$name is now: ${status:-unknown}"
    return 0
}

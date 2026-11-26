#!/bin/bash
# lib/steps/n8n.sh -- n8n's non-package steps.
#
# n8n needs two native addons and a sourced env file. Its startup check is not
# `command -v n8n` (the shim survives) and not `n8n --version` (the launcher
# short-circuits before opening the database): it is
# `require("sqlite3")` resolved the way n8n itself resolves it.

step_n8n_native() {
    local step="$1" jobs
    jobs=$(printf '%s' "$step" | jq -r '.args.jobs // 1')

    # sqlite3 is fatal: without it n8n retries its database connection forever and
    # never binds the port.
    if n8n_module_loads sqlite3; then
        echo "sqlite3 already loads"
    else
        echo "sqlite3 does not load as n8n resolves it — building"
        _n8n_build_native sqlite3 "$jobs" || {
            echo "sqlite3 native build failed: n8n cannot start without it"
            return 1
        }
    fi

    # isolated-vm is loaded lazily for expressions; n8n boots without it, so a
    # failure here is a warning, not a failed install.
    if n8n_module_loads isolated-vm; then
        echo "isolated-vm already loads"
    else
        if _n8n_build_native isolated-vm "$jobs"; then
            echo "isolated-vm built"
        else
            echo "warning: isolated-vm build failed — expressions will not work, n8n still starts"
        fi
    fi
    return 0
}

step_n8n_env() {
    local step="$1" ip token env
    env="$HOME/n8n_server/config/n8n.env"

    ip=$(printf '%s' "$step" | jq -r '.args.ip // empty')
    if [ -z "$ip" ]; then
        ip=$(ip route get 1 2>/dev/null | awk '{print $NF; exit}')
    fi
    [ -n "$ip" ] || ip=127.0.0.1

    # Keep an existing runner token: rotating it orphans the runner processes.
    token=""
    if [ -f "$env" ]; then
        token=$(sed -n 's/^N8N_RUNNERS_AUTH_TOKEN="\(.*\)"/\1/p' "$env" | head -1)
    fi
    if [ -z "$token" ]; then
        token=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
    fi

    _n8n_write_env "$ip" "$token" || return 1
    echo "wrote $env (host $ip, port 5678)"
    return 0
}

step_n8n_verify() {
    local out

    if ! n8n_module_loads sqlite3; then
        echo "sqlite3 does not load as n8n resolves it"
        return 1
    fi
    echo "sqlite3 loads"

    n8n_module_loads isolated-vm && echo "isolated-vm loads" || echo "warning: isolated-vm missing (expressions)"

    # Startup is slow on a loaded device; do not turn a slow banner into a failure.
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 90 n8n --version 2>/dev/null | tail -1)
    else
        out=$(n8n --version 2>/dev/null | tail -1)
    fi
    [ -n "$out" ] && echo "n8n $out"
    return 0
}

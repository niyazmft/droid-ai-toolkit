#!/bin/bash
# lib/steps/hermes.sh -- Hermes, via the toolkit's own repair funnel.
#
# Hermes is the one tool whose install is mostly *repair*: a venv whose interpreter
# drifts with `pkg upgrade`, platform shims that must exist before any launch, and
# dependency ownership that pip and the PM store fight over. install.sh already has
# the single funnel for all of that (`_hermes_ensure_termux_deps`), so this calls it
# rather than reimplementing — the same reason step_n8n reuses n8n_module_loads.

step_hermes_repair() {
    local src="$HOME/.hermes/hermes-agent"

    if [ ! -d "$src" ]; then
        echo "no Hermes checkout at $src"
        echo "install it once from the toolkit TUI (AGENTS -> Hermes), then re-run this action"
        return 1
    fi

    # A conflicted checkout is the documented brick: every launch dies on
    # '<<<<<<< Updated upstream'. Reset the one file the toolkit patches, from HEAD.
    if _hermes_checkout_broken "$src"; then
        echo "checkout has conflict markers — resetting hermes_cli/main.py from HEAD"
        ( cd "$src" && git checkout HEAD -- hermes_cli/main.py ) || return 1
    fi

    # Pins the venv interpreter, installs platform shims, installs deps from the wheel
    # cache, adds the honcho plugin when the home asks for it, and discards an
    # abandoned PM store. Its own failures are non-fatal by design; the smoke test is
    # the gate that matters.
    _hermes_ensure_termux_deps
    _hermes_cli_smoke_test
}

# step_hermes_pm2 -- restart the gateway.
#
# `--interpreter bash` is mandatory: the hermes binary is a bash script, and PM2
# defaulting to node produces "SyntaxError: Unexpected identifier" on the next
# automatic restart.
step_hermes_pm2() {
    local bin pid
    bin=$(command -v hermes 2>/dev/null) || { echo "hermes is not on PATH"; return 1; }
    command -v pm2 >/dev/null 2>&1 || { echo "pm2 is not installed"; return 1; }

    # Start the venv interpreter with the entry point as an argument. Handing PM2 the
    # `hermes` shim plus `--interpreter bash` looks right but ended up running the venv
    # entry point (a Python file) under bash:
    #     venv/bin/hermes: line 5: syntax error near unexpected token `('
    # because whatever PM2 resolves to is not the bash shim. Naming python explicitly
    # removes the guesswork: no shebang resolution, no interpreter choice.
    local venv="$HOME/.hermes/hermes-agent/venv/bin"
    if [ ! -x "$venv/python" ] || [ ! -f "$venv/hermes" ]; then
        echo "no venv entry point at $venv/hermes"
        return 1
    fi

    pm2 delete hermes >/dev/null 2>&1 || true
    pm2 start "$venv/python" --name hermes --interpreter none -- "$venv/hermes" gateway 2>&1 | tail -3
    pm2 save >/dev/null 2>&1 || true

    sleep 6
    pid=$(pm2 jlist 2>/dev/null | jq -r '.[] | select(.name == "hermes") | .pid // empty' 2>/dev/null | head -1)
    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        echo "hermes did not get a real pid"
        return 1
    fi
    echo "hermes running: pid=$pid"
}

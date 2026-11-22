#!/bin/bash
# lib/steps/openclaw.sh -- OpenClaw steps that are not a package install.

# step_openclaw_patches -- apply the Android patch suite to the tool project copy.
#
# $OPENCLAW_ROOT must be set AFTER the toolkit is sourced: apply_patches resets it
# to the npm-global path, and every patch_openclaw_* silently no-ops without it.
step_openclaw_patches() {
    local dir root
    dir=$(tool_dir openclaw)
    root="$dir/node_modules/openclaw"

    if [ ! -d "$root" ]; then
        echo "openclaw is not installed at $root"
        return 1
    fi

    OPENCLAW_ROOT="$root"
    export OPENCLAW_ROOT
    echo "patching $OPENCLAW_ROOT"

    # apply_patches is silent-mode aware and reports patches that did not match,
    # rather than claiming success while an Android fix is absent.
    apply_patches "" openclaw
    return 0
}

# step_openclaw_config -- Termux-safe config, then the Android doctor pass.
#
# The jq program is copied from install_openclaw() rather than rewritten: every
# clause in it is a bug that was found on a device (gateway.mode missing after a
# failed doctor run; plugin entries being force-disabled; dmPolicy defaulting to
# "pairing" and silently revoking slash commands; three keys 2026.9.x rejects
# outright). Do not "simplify" it here and leave the other copy alone.
step_openclaw_config() {
    local cfg="$HOME/.openclaw/openclaw.json" tmp
    if [ ! -f "$cfg" ]; then
        echo "no config at $cfg — run the gateway once to generate it, then re-run"
        return 0
    fi
    tmp=$(mktemp) || return 1
    if ! jq '
        .gateway.mode = (.gateway.mode // "local") |
        del(.plugins.entries["kimi-coding"], .plugins.entries["speech-core"], .plugins.entries["image-generation-core"], .plugins.entries["video-generation-core"], .plugins.entries["media-understanding-core"]) |
        .plugins.entries.telegram = ((.plugins.entries.telegram // {}) + {"enabled": true}) |
        .plugins.entries.ollama = ((.plugins.entries.ollama // {}) + {"enabled": true}) |
        if (.plugins.entries["memory-core"] | type) == "object" then . else .plugins.entries["memory-core"] = {"enabled": true} end |
        .plugins.entries = ((.plugins.entries // {}) | with_entries(.value |= (if (type == "object" and (has("enabled") | not)) then . + {"enabled": false} else . end))) |
        del(.channels.telegram.streamMode, .channels.telegram.chunkMode, .channels.telegram.blockStreaming, .channels.telegram.draftChunk, .channels.telegram.blockStreamingCoalesce) |
        .channels.telegram.dmPolicy = (.channels.telegram.dmPolicy // "allowlist") |
        del(.channels.slack.streamMode, .channels.slack.chunkMode, .channels.slack.blockStreaming, .channels.slack.blockStreamingCoalesce, .channels.slack.nativeStreaming) |
        if (.channels.telegram.streaming? | type) != "object" then del(.channels.telegram.streaming) else . end |
        if (.channels.slack.streaming? | type) != "object" then del(.channels.slack.streaming) else . end' \
        "$cfg" > "$tmp"; then
        rm -f "$tmp"
        echo "config rewrite failed — leaving $cfg untouched"
        return 1
    fi
    mv "$tmp" "$cfg"

    # doctor --fix cannot complete service-ownership checks on Android; the external
    # supervisor vars are upstream's documented way to skip them. Output goes to the
    # step log, and a failure is not fatal.
    yes "" | OPENCLAW_SERVICE_REPAIR_POLICY=external OPENCLAW_SUPERVISOR_MODE=external \
        openclaw doctor --fix 2>&1 | tail -5
    echo "configured $cfg"
    return 0
}

# step_openclaw_pm2 -- start the gateway and prove it actually has a PID.
#
# PM2 reports `online` with pid N/A when handed a directory (2026-11-17), so
# "started" is only true if a real pid appears; otherwise every later boot looks
# fine and nothing is serving.
step_openclaw_pm2() {
    local bin limit opts pid
    bin=$(command -v openclaw) || { echo "openclaw is not on PATH"; return 1; }
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "pm2 is not installed"
        return 1
    fi

    limit=$(get_mem_limit)
    opts=$(_oc_node_options "$limit")

    pm2 delete openclaw >/dev/null 2>&1 || true
    _openclaw_clear_stale_gateway_locks || true
    mkdir -p "$HOME/.openclaw/tmp"

    NODE_OPTIONS="$opts" OPENCLAW_TMP="$HOME/.openclaw/tmp" \
        pm2 start "$bin" --name openclaw --interpreter none -- gateway run 2>&1 | tail -5
    pm2 save >/dev/null 2>&1 || true

    sleep 6
    pid=$(pm2 jlist 2>/dev/null | jq -r '.[] | select(.name == "openclaw") | .pid // empty' 2>/dev/null | head -1)
    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        echo "openclaw did not get a real pid — PM2 reports online but nothing is running"
        pm2 jlist 2>/dev/null | jq -c '.[] | select(.name=="openclaw") | {status:.pm2_env.status, restarts:.pm2_env.restart_time}' 2>/dev/null
        return 1
    fi
    echo "openclaw running: pid=$pid NODE_OPTIONS=$opts"
    return 0
}

# step_openclaw_migrate -- 2026.9.x gates gateway startup behind legacy-state
# migrations that upstream normally applies via `doctor --fix`. That command cannot
# finish on Android (it needs a service owner for gateway verification), so the
# toolkit runs the migrations directly. No-op when there is no legacy state.
step_openclaw_migrate() {
    if command -v migrate_openclaw_legacy_state >/dev/null 2>&1; then
        migrate_openclaw_legacy_state
        return $?
    fi
    echo "no legacy-state migrator in this toolkit build; skipping"
    return 0
}

# step_openclaw_boot_hook -- write ~/.termux/boot/start-pm2.sh, which runs
# `sshd` and `pm2 resurrect` on boot. Without it every service stays down after a
# reboot, because Android has no systemd/launchd for `pm2 startup` to hook into.
step_openclaw_boot_hook() {
    if command -v setup_pm2_boot >/dev/null 2>&1; then
        setup_pm2_boot
        return $?
    fi
    echo "no boot-hook writer in this toolkit build; skipping"
    return 0
}

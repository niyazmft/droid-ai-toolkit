#!/bin/bash
# lib/steps/status.sh -- read-only device + service snapshot.
#
# Writes a JSON document to $RUNNER_RESULT, which the runner emits as a `data`
# event. Nothing here changes device state: this is the screen a user opens when
# something is wrong, so it must never be the reason something breaks.
#
# Every probe is time-boxed. A hung `pm2 jlist` or a slow `openclaw --version`
# must not turn "show me status" into a two-minute wait on a phone.

_st_getprop() { getprop "$1" 2>/dev/null || true; }

_st_meminfo_mb() {
    awk -v k="$1:" '$1 == k {printf "%d", $2/1024; f=1} END {if (!f) printf "0"}' /proc/meminfo 2>/dev/null
}

_st_tmo() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# _st_version <bin> [args...] -- first line of --version, or empty when absent.
_st_version() {
    local bin="$1"; shift
    command -v "$bin" >/dev/null 2>&1 || return 0
    _st_tmo 6 "$bin" "$@" 2>/dev/null | head -1
}

_st_allow_external_apps() {
    local f="$HOME/.termux/termux.properties"
    [ -f "$f" ] || { printf 'false'; return 0; }
    if grep -qE '^[[:space:]]*allow-external-apps[[:space:]]*=[[:space:]]*true' "$f" 2>/dev/null; then
        printf 'true'
    else
        printf 'false'
    fi
}

_st_doze_whitelisted() {
    _st_tmo 6 cmd deviceidle whitelist 2>/dev/null \
        | awk -F, '$2 == "com.termux" {found=1} END {print (found ? "true" : "false")}'
}

_st_boot_installed() {
    local out
    out=$(_st_tmo 6 pm list packages com.termux.boot 2>/dev/null)
    case "$out" in
        *package:com.termux.boot*) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

# _st_pm2_running -- is the PM2 daemon already up?
# `pm2 jlist` and `pm2 --version` both START a daemon when none is running, so a
# read-only status probe must check first. Without this, opening the status
# screen on a device with PM2 stopped would spawn one.
_st_pm2_running() {
    local pid
    [ -f "$HOME/.pm2/pm2.pid" ] || return 1
    pid=$(cat "$HOME/.pm2/pm2.pid" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# _st_services -- PM2 snapshot as a JSON array (empty when PM2 is not running).
_st_services() {
    _st_pm2_running || { printf '[]'; return 0; }
    local raw
    raw=$(_st_tmo 8 pm2 jlist 2>/dev/null) || { printf '[]'; return 0; }
    printf '%s' "$raw" | jq -c '
        if type == "array" then
            [ .[] | {
                name: .name,
                status: (.pm2_env.status // "unknown"),
                restarts: (.pm2_env.restart_time // 0),
                mem_mb: ((.monit.memory // 0) / 1048576 | floor),
                node_options: (.pm2_env.NODE_OPTIONS // "")
              } ]
        else [] end' 2>/dev/null || printf '[]'
}

status_collect() {
    local out="${RUNNER_RESULT:-/dev/null}"
    local model android api abi arch
    local mem_total mem_avail swap_total swap_free disk_free
    local termux_ver allow_ext boot_installed doze hl
    local node pnpm py openclaw hermes n8n ollama pm2_inst
    local services

    model=$(_st_getprop ro.product.model)
    android=$(_st_getprop ro.build.version.release)
    api=$(_st_getprop ro.build.version.sdk)
    abi=$(_st_getprop ro.product.cpu.abi)
    arch=$(pf_arch)

    mem_total=$(_st_meminfo_mb MemTotal)
    mem_avail=$(_st_meminfo_mb MemAvailable)
    swap_total=$(_st_meminfo_mb SwapTotal)
    swap_free=$(_st_meminfo_mb SwapFree)
    disk_free=$(pf_disk_free_mb)

    termux_ver="${TERMUX_VERSION:-}"
    allow_ext=$(_st_allow_external_apps)
    boot_installed=$(_st_boot_installed)
    doze=$(_st_doze_whitelisted)
    if pf_supports_hardlinks "$HOME"; then hl=true; else hl=false; fi

    node=$(_st_version node --version)
    pnpm=$(_st_version pnpm --version)
    py=$(_st_version python3 --version)
    if command -v pm2 >/dev/null 2>&1; then pm2_inst=true; else pm2_inst=false; fi
    openclaw=$(_st_version openclaw --version)
    hermes=$(_st_version hermes --version)
    n8n=$(_st_version n8n --version)
    ollama=$(_st_version ollama --version)
    services=$(_st_services)

    jq -n \
        --arg model "$model" --arg android "$android" --arg api "$api" \
        --arg abi "$abi" --arg arch "$arch" \
        --argjson mem_total "${mem_total:-0}" --argjson mem_avail "${mem_avail:-0}" \
        --argjson swap_total "${swap_total:-0}" --argjson swap_free "${swap_free:-0}" \
        --argjson disk_free "${disk_free:-0}" --argjson hardlinks "$hl" \
        --arg termux "$termux_ver" --argjson allow_ext "$allow_ext" \
        --argjson boot "$boot_installed" --argjson doze "$doze" \
        --arg node "$node" --arg pnpm "$pnpm" --arg python "$py" --argjson pm2_installed "$pm2_inst" \
        --arg openclaw "$openclaw" --arg hermes "$hermes" --arg n8n "$n8n" --arg ollama "$ollama" \
        --argjson services "${services:-[]}" \
        '{
            device: {
                model: $model, android: $android, api: ($api | tonumber? // 0),
                abi: $abi, arch: $arch,
                mem_total_mb: $mem_total, mem_available_mb: $mem_avail,
                swap_total_mb: $swap_total, swap_free_mb: $swap_free,
                disk_free_mb: $disk_free, hardlinks: $hardlinks
            },
            termux: {
                version: $termux,
                allow_external_apps: $allow_ext,
                boot_installed: $boot,
                doze_whitelisted: $doze
            },
            tools: {
                node: $node, pnpm: $pnpm, python: $python, pm2_installed: $pm2_installed,
                openclaw: $openclaw, hermes: $hermes, n8n: $n8n, ollama: $ollama
            },
            services: $services
        }' > "$out" 2>/dev/null
}

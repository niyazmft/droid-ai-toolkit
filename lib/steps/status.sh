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

# _st_required_checks -- every predicate name the catalog asks for, one per line.
#
# The catalog already carries `requires.predicates`, but until now nothing evaluated them
# for the client: it offered Install for Paperclip on a phone with no PostgreSQL, and the
# refusal arrived as a bare exit 3. Enumerating the specs keeps the set honest — a new
# action adds its own precondition and the status document grows with it.
_st_required_checks() {
    local dir="${TOOLKIT_DIR:-}"
    [ -n "$dir" ] && [ -d "$dir/actions" ] || return 0
    find "$dir/actions" -name '*.json' -print0 2>/dev/null \
        | xargs -0 jq -r '.requires.predicates[]? // empty' 2>/dev/null \
        | sort -u
}

# _st_checks_json -- { "<predicate>": true|false } for the predicates the catalog names.
#
# `name:arg` is split the same way a step's `when` is. Everything here is a few
# milliseconds except the package probe, which shells out to apt-cache once.
_st_checks_json() {
    local p name arg ok out='{}'
    for p in $(_st_required_checks); do
        case "$p" in
            *:*) name="${p%%:*}"; arg="${p#*:}" ;;
            *)   name="$p"; arg="" ;;
        esac
        if pred_apply "$name" "$arg" >/dev/null 2>&1; then ok=true; else ok=false; fi
        out=$(printf '%s' "$out" | jq -c --arg k "$p" --argjson v "$ok" '. + {($k): $v}' 2>/dev/null) || out='{}'
    done
    printf '%s' "$out"
}

# _st_boot_script -- is the Termux:Boot script present AND executable?
#
# Termux:Boot executes every executable file in ~/.termux/boot/; a file without +x is a file
# that does nothing, which is why both halves are checked.
_st_boot_script() {
    local f="$HOME/.termux/boot/start-pm2.sh"
    if [ -f "$f" ] && [ -x "$f" ]; then printf 'true'; else printf 'false'; fi
}

# _st_pm2_dump -- {"present":bool,"count":n} for ~/.pm2/dump.pm2.
#
# A dump that lists nothing restores nothing, so the count is part of the fact: "set up" must
# not be said about a dump that would leave the phone empty after a reboot.
_st_pm2_dump() {
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

# _st_legacy_global -- the pre-migration shared pnpm project, as {"present":bool,"mb":n}.
#
# The app shows a Cleanup panel only when this exists, and says how big it is — "12.9 GB" is
# the whole reason someone would remove it. The size is time-boxed and skipped under `--fast`:
# `du` over a 13 GB tree of thousands of files takes seconds on a phone, and a status poll has
# no business paying for a number only the Advanced panel displays.
_st_legacy_global() {
    local g="$HOME/.local/share/pnpm/global" mb=0
    if [ ! -d "$g" ]; then
        printf '{"present":false,"mb":0}'
        return 0
    fi
    if [ "${DROIDAI_STATUS_FAST:-0}" != "1" ]; then
        mb=$(_st_tmo 5 du -sm "$g" 2>/dev/null | awk '{print $1; exit}')
    fi
    case "$mb" in
        ''|*[!0-9]*) mb=0 ;;
    esac
    printf '{"present":true,"mb":%s}' "$mb"
}

# _st_installed_json -- presence per catalog tool, as a JSON object of booleans.
#
# Presence is a directory (or a PATH entry), never a version string. `--version` starts a
# whole Node/Python runtime, so a blank version used to mean "not installed" to the app's
# Packages screen — which is how 8x came to report 0 of 8 with four tools sitting on disk.
# A stat costs nothing and keeps working under `--fast`.
#
# _st_legacy_has <bin> <path-under-node_modules>... -- is the tool runnable from the
# pre-migration global project?
#
# Tools used to share `global/5/node_modules`; devices that have not migrated still run
# from there. Statting it (no pnpm spawn) keeps the Packages screen honest: ignoring the
# legacy layout reported every migrated-only tool as "Disappeared — its files are gone"
# while the gateway was serving traffic (y6, 2026-11-24; 8x has no tools/ dir at all).
#
# The bin on PATH is part of the test, not a nicety: uninstalling a migrated tool leaves
# its old copy in the legacy store while deleting the shim, and "directory exists" then
# claims an installed tool that nothing can run. Conversely the shim alone is not evidence
# either (it survives a deleted package), so this requires both.
_st_legacy_has() {
    local bin="${1:-}" rel f
    [ "$#" -gt 0 ] && shift
    [ -n "$bin" ] || return 1
    command -v "$bin" >/dev/null 2>&1 || return 1
    for rel in "$@"; do
        for f in "$HOME"/.local/share/pnpm/global/*/node_modules/"$rel"; do
            [ -e "$f" ] && return 0
        done
    done
    return 1
}

_st_installed_json() {
    local root="$HOME/.local/share/pnpm/tools"
    local openclaw=false pi=false gemini=false n8n=false paperclip=false
    local hermes=false nanobot=false ollama=false
    if [ -d "$root/openclaw" ] || _st_legacy_has openclaw openclaw; then openclaw=true; fi
    if [ -d "$root/pi" ] || _st_legacy_has pi pi @earendil-works/pi-coding-agent; then pi=true; fi
    if [ -d "$root/gemini" ] || _st_legacy_has gemini gemini @google/gemini-cli; then gemini=true; fi
    if [ -d "$root/n8n" ] || _st_legacy_has n8n n8n; then n8n=true; fi
    if [ -d "$root/paperclip" ]; then paperclip=true; fi
    # Hermes keeps its own checkout, and nanobot/ollama are not pnpm tools at all.
    if [ -d "$HOME/.hermes/hermes-agent" ]; then hermes=true; fi
    if command -v nanobot >/dev/null 2>&1; then nanobot=true; fi
    if command -v ollama >/dev/null 2>&1; then ollama=true; fi
    jq -nc \
        --argjson openclaw "$openclaw" --argjson pi "$pi" --argjson gemini "$gemini" \
        --argjson n8n "$n8n" --argjson paperclip "$paperclip" --argjson hermes "$hermes" \
        --argjson nanobot "$nanobot" --argjson ollama "$ollama" \
        '{openclaw: $openclaw, pi: $pi, gemini: $gemini, n8n: $n8n,
          paperclip: $paperclip, hermes: $hermes, nanobot: $nanobot, ollama: $ollama}' 2>/dev/null \
        || printf '{}'
}

status_collect() {
    local out="${RUNNER_RESULT:-/dev/null}"
    local model android api abi arch
    local mem_total mem_avail swap_total swap_free disk_free
    local termux_ver allow_ext boot_installed doze hl
    local node pnpm py openclaw hermes n8n ollama pm2_inst
    local services services_installed checks legacy_global boot_script pm2_dump

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
    py=$(_st_version python3 --version)
    if command -v pm2 >/dev/null 2>&1; then pm2_inst=true; else pm2_inst=false; fi

    # Tool versions are the expensive half of this snapshot: each one starts a whole
    # Node or Python runtime just to print a string. Measured on 8x, the four CLI
    # probes below accounted for most of a 22 s run.
    #
    # --fast exists for the APK's supervisor, which polls this on a timer: it needs
    # services and memory, not version strings, and it can spend 19 s of CPU per poll
    # on nothing. `pnpm` goes too — it is a Node script, and nothing displays it.
    if [ "${DROIDAI_STATUS_FAST:-0}" = "1" ]; then
        pnpm=""
        openclaw=""
        hermes=""
        n8n=""
        ollama=""
    else
        pnpm=$(_st_version pnpm --version)
        openclaw=$(_st_version openclaw --version)
        hermes=$(_st_version hermes --version)
        n8n=$(_st_version n8n --version)
        ollama=$(_st_version ollama --version)
    fi
    services=$(_st_services)
    # Default assigned plainly: `${var:-{}}` lets bash brace expansion append a
    # second `}`, which produced `{...}}` and made jq reject the whole document.
    services_installed=$(_st_installed_json)
    if [ -z "$services_installed" ]; then services_installed='{}'; fi
    checks=$(_st_checks_json)
    if [ -z "$checks" ]; then checks='{}'; fi
    legacy_global=$(_st_legacy_global)
    if [ -z "$legacy_global" ]; then legacy_global='{"present":false,"mb":0}'; fi
    boot_script=$(_st_boot_script)
    pm2_dump=$(_st_pm2_dump)
    if [ -z "$pm2_dump" ]; then pm2_dump='{"present":false,"count":0}'; fi

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
        --argjson installed "$services_installed" \
        --argjson checks "$checks" \
        --argjson legacy "$legacy_global" \
        --argjson boot_script "$boot_script" --argjson pm2_dump "$pm2_dump" \
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
                boot_script: $boot_script,
                pm2_dump: $pm2_dump,
                doze_whitelisted: $doze,
                legacy_global: $legacy
            },
            tools: {
                node: $node, pnpm: $pnpm, python: $python, pm2_installed: $pm2_installed,
                openclaw: $openclaw, hermes: $hermes, n8n: $n8n, ollama: $ollama,
                installed: $installed
            },
            services: $services,
            checks: $checks
        }' > "$out" 2>/dev/null
}

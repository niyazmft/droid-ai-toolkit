#!/bin/bash
# lib/steps/probe.sh -- predicates usable from a spec's "when" field.
#
# Closed set, on purpose: `when` names one of these functions and nothing else.
# No expressions, no operators, no mini-language. A spec DSL that can compute
# will grow until it needs its own interpreter, which is the thing this refactor
# is trying to remove.

pred_is_termux() {
    [ -d "/data/data/com.termux" ] || [ -n "${TERMUX_VERSION:-}" ]
}

pred_cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

pred_pm2_has() {
    command -v pm2 >/dev/null 2>&1 || return 1
    pm2 jlist 2>/dev/null | jq -e --arg n "$1" 'any(.[]; .name == $n)' >/dev/null 2>&1
}

pred_mem_available_gte() {
    local have need="${1:-0}"
    have=$(pf_mem_available_mb)
    [ "${have:-0}" -ge "$need" ]
}

# Hermes and Nanobot cannot work on 32-bit ARM: jiter has no armv7 Android wheel
# and maturin rejects armv8l outright (install.sh::_guard_armv8l).
pred_supports_hermes() {
    case "$(pf_arch)" in
        armv8l|armv7l) return 1 ;;
    esac
    return 0
}

pred_supports_jiter() {
    pred_supports_hermes
}

# A warm pnpm store is what makes a re-install survivable on a low-RAM device;
# from a cold store the same operation is the one that gets SIGKILLed.
pred_has_warm_pnpm_store() {
    local root
    root=$(pnpm root -g 2>/dev/null | sed -n '$p')
    [ -n "$root" ] && [ -d "$root/../.pnpm" ] || [ -n "$(ls -A "$root" 2>/dev/null)" ]
}

# pred_apply <name> [arg] -- evaluate a predicate by name, for spec "when" fields.
pred_apply() {
    local name="$1"; shift
    if [ -z "$name" ]; then
        return 0
    fi
    if ! command -v "pred_$name" >/dev/null 2>&1; then
        # An unknown predicate is a spec bug. Fail closed so a step does not run
        # because its guard could not be understood.
        return 1
    fi
    "pred_$name" "$@"
}

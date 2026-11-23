#!/bin/bash
# lib/steps/verify.sh -- small, reusable step primitives.

# step_verify_cmd <step-json> -- run args.cmd and fail on a non-zero exit.
# This is the check that actually proves an install: `command -v` alone passes
# when the shim survives and the package behind it does not.
step_verify_cmd() {
    local step="$1" line rc=0 out
    local -a argv=()

    while IFS= read -r line; do
        argv+=("$line")
    done < <(printf '%s' "$step" | jq -r '.args.cmd[]?')

    if [ "${#argv[@]}" -eq 0 ]; then
        echo "step_verify_cmd: missing args.cmd"
        return 1
    fi
    if ! command -v "${argv[0]}" >/dev/null 2>&1; then
        echo "not on PATH: ${argv[0]}"
        return 1
    fi

    # A CLI's first start on a loaded phone can take far longer than 25 s: Gemini's
    # `--version` was killed at exactly 25 s on 8x (exit 124 = timeout), which the
    # action reported as a failed install. Callers can raise it per step.
    local secs
    secs=$(printf '%s' "$step" | jq -r '.args.timeout_s // 25')

    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout "$secs" "${argv[@]}" 2>&1); rc=$?
    else
        out=$("${argv[@]}" 2>&1); rc=$?
    fi
    printf '%s\n' "$out" | head -3
    return "$rc"
}

# step_remove_path <step-json> -- delete one file, refusing anything outside Termux.
step_remove_path() {
    local step="$1" path
    path=$(printf '%s' "$step" | jq -r '.args.path // empty')
    if [ -z "$path" ]; then
        echo "step_remove_path: missing args.path"
        return 1
    fi

    # Expand only the two names a spec is allowed to reference. No eval: a spec is
    # data, and data must not become a shell command.
    path=${path//\$PREFIX/$PREFIX}
    path=${path//\$HOME/$HOME}
    path=${path/#\~/$HOME}

    case "$path" in
        "$HOME"/*|"$PREFIX"/*|/data/data/com.termux/*) ;;
        *) echo "refusing to remove outside Termux: $path"; return 1 ;;
    esac

    if [ -e "$path" ]; then
        rm -f -- "$path" && echo "removed $path"
    else
        echo "already absent: $path"
    fi
}

# step_pkg_install <step-json> -- apt packages, non-interactive.
step_pkg_install() {
    local step="$1" pkg
    local -a pkgs=()

    while IFS= read -r pkg; do
        pkgs+=("$pkg")
    done < <(printf '%s' "$step" | jq -r '.args.packages[]?')

    [ "${#pkgs[@]}" -gt 0 ] || return 0
    export DEBIAN_FRONTEND=noninteractive
    echo "pkg install: ${pkgs[*]}"
    pkg install -y "${pkgs[@]}" 2>&1 | tail -5
    return "${PIPESTATUS[0]}"
}

# step_verify_path <step-json> -- fail unless args.path exists.
# Used where the proof is an installed tree rather than a command (Paperclip's server
# bundle), and where `command -v` would be meaningless.
step_verify_path() {
    local step="$1" path
    path=$(printf '%s' "$step" | jq -r '.args.path // empty')
    if [ -z "$path" ]; then
        echo "step_verify_path: missing args.path"
        return 1
    fi
    path=${path//\$PREFIX/$PREFIX}
    path=${path//\$HOME/$HOME}
    path=${path/#\~/$HOME}

    if [ -e "$path" ]; then
        echo "present: $path"
        return 0
    fi
    echo "missing: $path"
    return 1
}

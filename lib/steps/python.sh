#!/bin/bash
# lib/steps/python.sh -- pip installs, with the Termux build environment exported.
#
# Two things make pip on Termux different from pip on a laptop:
#   * `--no-build-isolation` is required for packages that need the Rust toolchain,
#     otherwise pip builds in an isolated env that cannot see cargo/maturin.
#   * The build must be single-job. `-j max` on a 4-core phone with 1.8 GB is how you
#     get SIGKILLed halfway through compiling, and the half-built wheel is then cached.

step_pip_install() {
    local step="$1" spec venv nbi
    spec=$(printf '%s' "$step" | jq -r '.args.spec // empty')
    venv=$(printf '%s' "$step" | jq -r '.args.venv // empty')
    nbi=$(printf '%s' "$step" | jq -r '.args.no_build_isolation // false')

    if [ -z "$spec" ]; then
        echo "step_pip_install: missing args.spec"
        return 1
    fi

    local -a pip_cmd
    if [ -n "$venv" ]; then
        if [ ! -x "$venv/bin/pip" ]; then
            echo "step_pip_install: no pip at $venv/bin/pip"
            return 1
        fi
        pip_cmd=("$venv/bin/pip")
    else
        if ! command -v pip3 >/dev/null 2>&1; then
            echo "step_pip_install: pip3 is not on PATH"
            return 2
        fi
        pip_cmd=(pip3)
    fi

    local -a flags=()
    if [ "$nbi" = "true" ]; then
        flags+=(--no-build-isolation --no-cache-dir)
    fi

    export RUSTFLAGS="${RUSTFLAGS:--C opt-level=2}"
    export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"
    echo "pip install $spec (jobs=$CARGO_BUILD_JOBS, isolation=$([ "$nbi" = true ] && echo off || echo on))"

    "${pip_cmd[@]}" install "$spec" "${flags[@]}" 2>&1 | tail -20
    return "${PIPESTATUS[0]}"
}

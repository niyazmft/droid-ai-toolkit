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

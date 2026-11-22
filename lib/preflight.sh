#!/bin/bash
# lib/preflight.sh -- device gates evaluated before any work starts.
#
# The point is to refuse early and say why, instead of downloading half a
# toolchain and then discovering the device cannot run it. On the 1.8 GB test
# device, pnpm's own heap cap (592 MB) already exceeds free memory at times.
#
# Exit 3 means "preflight refused" (see docs/CONTRACT.md).

# pf_mem_available_mb -- MemAvailable in MB (0 when unreadable).
pf_mem_available_mb() {
    awk '/^MemAvailable:/ {printf "%d", $2/1024; found=1} END {if (!found) printf "0"}' \
        /proc/meminfo 2>/dev/null
}

# pf_mem_total_mb
pf_mem_total_mb() {
    awk '/^MemTotal:/ {printf "%d", $2/1024; found=1} END {if (!found) printf "0"}' \
        /proc/meminfo 2>/dev/null
}

# pf_disk_free_mb [path]
pf_disk_free_mb() {
    df -Pm "${1:-$HOME}" 2>/dev/null | awk 'NR==2 {printf "%d", $4; found=1} END {if (!found) printf "0"}'
}

# pf_arch -- uname -m, the value specs match against
pf_arch() {
    uname -m 2>/dev/null || printf 'unknown'
}

# pf_arch_allowed <allowed...> -- does this device match any allowed arch?
pf_arch_allowed() {
    local a cur
    cur=$(pf_arch)
    for a in "$@"; do
        [ "$a" = "$cur" ] && return 0
    done
    return 1
}

# pf_would_fit <needed_mb> -- is there that much headroom right now?
pf_would_fit() {
    local need="${1:-0}" have
    have=$(pf_mem_available_mb)
    [ "${have:-0}" -ge "$need" ]
}

# pf_supports_hardlinks [dir] -- pnpm imports by copy when this fails, which
# roughly doubles the disk a global install needs.
pf_supports_hardlinks() {
    local dir="${1:-$HOME}" a b
    a="$dir/.toolkit-hl-probe-$$"
    b="$a-b"
    : > "$a" 2>/dev/null || return 1
    if ln "$a" "$b" 2>/dev/null; then
        rm -f "$a" "$b"
        return 0
    fi
    rm -f "$a"
    return 1
}

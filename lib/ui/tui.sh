#!/bin/bash
# lib/ui/tui.sh -- the interactive menu, rendering the same catalog the app does.
#
# Why this exists
# ---------------
# The toolkit had two front-ends that shared no code: the app called `lib/` (declarative
# actions), and the text menu called the legacy functions in install.sh. Every fix had to land
# twice, and when one copy drifted the difference was invisible until a device hit it — the
# per-tool uninstall bug fixed in Phase 4c is exactly that shape.
#
# This is the other half: the menu lists `install.sh --api list`, and runs what you pick by
# calling `install.sh --api run <id>`. One implementation, two front-ends.
#
# It is deliberately additive. The legacy menus stay where they are (they carry prompts and
# hand-holding that the catalog does not model yet), and this is reachable as its own entry so
# the owner can compare before anything is removed.

# Colours come from install.sh, which defines them before sourcing this file. Defaults keep the
# renderer readable if it is ever used on its own.
: "${BLUE:=}" "${GREEN:=}" "${RED:=}" "${YELLOW:=}" "${NC:=}"

# tui_actions -- the catalog, one "id<TAB>label" line per action.
tui_actions() {
    local toolkit="${TOOLKIT_DIR:-$PWD}"
    ( cd "$toolkit" && bash ./install.sh --api list 2>/dev/null ) \
        | jq -r '.actions[] | "\(.id)\t\(.title) — \(.category)"' 2>/dev/null
}

# tui_render -- turn the engine's NDJSON into lines a person reads.
#
# The event stream is the contract with the app, so it is the right thing to render here too:
# if the text output looks wrong, the app is being told something wrong.
tui_render() {
    local line type step title state ms code msg reason=""
    while IFS= read -r line; do
        case "$line" in
            "{"*"}"*) ;;
            *) continue ;;
        esac
        type=$(printf '%s' "$line" | jq -r '.t // empty' 2>/dev/null)
        case "$type" in
            start)
                printf '\n%s▶ %s%s\n' "$BLUE" "$(printf '%s' "$line" | jq -r '.action')" "$NC"
                ;;
            preflight)
                if [ "$(printf '%s' "$line" | jq -r '.ok')" != "true" ]; then
                    printf '%s✖ this device does not meet the requirements%s\n' "$RED" "$NC"
                fi
                ;;
            step)
                step=$(printf '%s' "$line" | jq -r '.title // .id')
                state=$(printf '%s' "$line" | jq -r '.state')
                ms=$(printf '%s' "$line" | jq -r '.ms // 0')
                case "$state" in
                    running) printf '  … %s\n' "$step" ;;
                    ok)
                        if [ "${ms:-0}" -ge 1000 ]; then
                            printf '  %s✔ %s%s (%ss)\n' "$GREEN" "$step" "$NC" "$((ms / 1000))"
                        else
                            printf '  %s✔ %s%s\n' "$GREEN" "$step" "$NC"
                        fi
                        ;;
                    failed) printf '  %s✖ %s%s\n' "$RED" "$step" "$NC" ;;
                    skipped) printf '  %s– %s (not needed)%s\n' "$YELLOW" "$step" "$NC" ;;
                esac
                ;;
            log)
                printf '    %s\n' "$(printf '%s' "$line" | jq -r '.line // empty' | cut -c1-200)"
                ;;
            error)
                msg=$(printf '%s' "$line" | jq -r '.msg // empty')
                [ -n "$msg" ] && printf '%s%s%s\n' "$RED" "$msg" "$NC"
                reason="$msg"
                ;;
            done)
                code=$(printf '%s' "$line" | jq -r '.code // 0')
                if [ "$code" = "0" ]; then
                    printf '%sDone.%s\n' "$GREEN" "$NC"
                else
                    printf '%sStopped (code %s).%s\n' "$RED" "$code" "$NC"
                fi
                return "$code"
                ;;
        esac
    done
    return 0
}

# tui_run_action <id> [extra args...] -- run one action and render it.
tui_run_action() {
    local id="$1"; shift
    local toolkit="${TOOLKIT_DIR:-$PWD}"
    ( cd "$toolkit" && bash ./install.sh --api run "$id" "$@" 2>&1 ) | tui_render
}

# tui_catalog_menu -- pick an action from the catalog and run it.
#
# Uses gum when it is there (the toolkit's normal UI engine) and a plain numbered prompt
# otherwise, so it works in a pipe and over a serial console.
tui_catalog_menu() {
    local list choice id count i
    list=$(tui_actions)
    if [ -z "$list" ]; then
        echo "No actions found — is this a toolkit checkout with actions/*/*.json?"
        return 1
    fi

    count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
    # gum needs a real terminal: over a pipe or a serial console it fails with "could not open
    # TTY", which is not a reason to refuse to run anything. Both ends are checked because the
    # menu draws on stdout and reads the choice from stdin.
    if [ -t 0 ] && [ -t 1 ] && command -v gum >/dev/null 2>&1; then
        choice=$(printf '%s\n' "$list" | cut -f2 | gum choose --height 18 --header "Run an action")
        if [ -n "$choice" ]; then
            id=$(printf '%s\n' "$list" | awk -F'\t' -v want="$choice" '$2 == want {print $1; exit}')
        fi
    fi
    if [ -z "${id:-}" ]; then
        printf '\n' >&2
        i=1
        while IFS=$'\t' read -r _id label; do
            printf '%2d) %s\n' "$i" "$label" >&2
            i=$((i + 1))
        done <<EOF
$list
EOF
        printf 'Number (blank to cancel): ' >&2
        read -r choice || return 0
        case "$choice" in
            ''|*[!0-9]*) return 0 ;;
        esac
        id=$(printf '%s\n' "$list" | sed -n "${choice}p" | cut -f1)
    fi

    if [ -z "${id:-}" ]; then
        echo "Nothing chosen."
        return 0
    fi

    [ -n "$id" ] || return 1

    # Destructive actions are confirmed by the engine (it exits 4 without --yes), which is the
    # same rule the app follows. Asking twice here would be a second, weaker copy of that rule.
    tui_run_action "$id"
}

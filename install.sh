#!/bin/bash

# ==============================================================================
# DROID AI TOOLKIT (Termux)
# Version: 1.15.3
# Purpose: Install and manage AI tools (OpenClaw, Gemini CLI, n8n, Ollama,
#          Hermes, Paperclip) on Android via Termux with kernel patches and path fixes.
# ==============================================================================

# Do NOT enable set -e. This is an interactive installer with deliberate
# fallbacks (e.g. Hermes upstream installer failure → manual pip fallback).
# set -e would kill the shell mid-install and return user to the prompt
# without any error message, making debugging impossible on-device.
# set -o pipefail is also avoided for the same reason.

# --- 1. COLORS & GLOBALS ---
VERSION="1.17.2"
ARCH_TYPE=$(uname -m)
GREEN=$(printf '\033[0;32m')
BLUE=$(printf '\033[0;34m')
YELLOW=$(printf '\033[1;33m')
RED=$(printf '\033[0;31m')
MAGENTA=$(printf '\033[0;35m')
NC=$(printf '\033[0m')
CLEAR_LINE=$(printf '\033[K')

# Termux dynamically exports $PREFIX. Fallback just in case.
PREFIX=${PREFIX:-"/data/data/com.termux/files/usr"}

LOG_FILE="$HOME/droid_ai_toolkit.log"
TOOLKIT_CONFIG="$HOME/.openclaw/.toolkit_config"
OPENCLAW_ROOT="$PREFIX/lib/node_modules/openclaw"
SERVICE_DIR="$PREFIX/var/service/openclaw"
N8N_SERVICE_DIR="$PREFIX/var/service/n8n"
PAPERCLIP_SERVICE_DIR="$PREFIX/var/service/paperclip"
TERMUX_BIN="$PREFIX/bin"

# Force correct npm path and bypass platform checks for LanceDB (Android support)
export npm_execpath="$TERMUX_BIN/npm"
export npm_config_force=true
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

# Cache expensive PATH lookups for the session
_HAS_PNPM=$(command -v pnpm 2>/dev/null || true)
_HAS_PM2=$(command -v pm2 2>/dev/null || true)
_HAS_JQ=$(command -v jq 2>/dev/null || true)

# --- 2. HELPER FUNCTIONS ---

status_msg() { echo -ne "\r${CLEAR_LINE}${BLUE}==>${NC} $1... "; }
error_msg() { echo -e "\n${RED}Error:${NC} $1"; }
success_msg() { echo -e "${GREEN}Done.${NC}"; }
warn_msg() { echo -e "\r${CLEAR_LINE}${YELLOW}Warning:${NC} $1"; }
wait_to_continue() {
    echo -ne "\n${BLUE}>>${NC} Press Enter to continue (or wait 3s)..."
    read -t 3 -r junk 2>/dev/null || true
    echo ""
}

# Returns a runtime indicator string for menu descriptions
_running_indicator() {
    local proc_pattern=$1
    if pgrep -f "$proc_pattern" >/dev/null 2>&1; then
        echo "${GREEN}(running)${NC}"
    else
        echo "${RED}(stopped)${NC}"
    fi
}

ensure_deps() {
    export DEBIAN_FRONTEND=noninteractive
    local pkgs=()
    if [ -z "$_HAS_JQ" ]; then
        pkgs+=(jq)
    fi
    if ! command -v whiptail >/dev/null 2>&1; then
        pkgs+=(whiptail)
    fi
    if ! command -v gum >/dev/null 2>&1; then
        pkgs+=(gum)
    fi
    if [ ${#pkgs[@]} -gt 0 ]; then
        status_msg "Installing required toolkit dependencies (${pkgs[*]})"
        # Skip apt update if lists are fresh (< 1 hour) to avoid network hit on every launch
        local apt_lists_dir="$PREFIX/var/lib/apt/lists"
        local needs_update=1
        if [ -d "$apt_lists_dir" ] && [ -n "$(find "$apt_lists_dir" -maxdepth 0 -mmin -60 2>/dev/null)" ]; then
            needs_update=0
        fi
        if [ "$needs_update" -eq 1 ]; then
            pkg update -y -o Dpkg::Options::=--force-confold >/dev/null 2>&1 || true
        fi
        pkg install -y -o Dpkg::Options::=--force-confold "${pkgs[@]}" >/dev/null 2>&1
        success_msg
    fi
}

# Persistence Helpers
set_config() {
    local key=$1
    local value=$2
    local varname="_CACHED_CONFIG_${key//-/_}"
    eval "$varname=\"\$value\""
    local tmp; tmp=$(mktemp)
    mkdir -p "$(dirname "$TOOLKIT_CONFIG")"
    if [ ! -f "$TOOLKIT_CONFIG" ]; then echo "{}" > "$TOOLKIT_CONFIG"; fi
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$TOOLKIT_CONFIG" > "$tmp" && mv "$tmp" "$TOOLKIT_CONFIG"
}

get_config() {
    local key=$1
    local varname="_CACHED_CONFIG_${key//-/_}"
    local val="${!varname}"
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    if [ -f "$TOOLKIT_CONFIG" ]; then
        val=$(jq -r --arg k "$key" '.[$k] // "null"' "$TOOLKIT_CONFIG")
    else
        val="null"
    fi
    eval "$varname=\"\$val\""
    echo "$val"
}

health_check() {
    local tool_name=$1
    local check_cmd=$2
    status_msg "Verifying ${tool_name} installation"
    if eval "$check_cmd" >/dev/null 2>&1; then
        success_msg
        echo -e "${GREEN}${tool_name} is ready.${NC}"
        return 0
    else
        error_msg "${tool_name} health check failed — it may not be in PATH"
        return 1
    fi
}

get_mem_limit() {
    if [ -n "$_CACHED_MEM_LIMIT" ]; then
        echo "$_CACHED_MEM_LIMIT"
        return
    fi
    local total_ram=$(free -m | awk '/^Mem:/{print $2}')
    # Aim for 75% of total RAM, but cap at 2048MB for stability
    local calculated=$(( total_ram * 75 / 100 ))
    if [ "$calculated" -gt 2048 ]; then
        _CACHED_MEM_LIMIT="2048"
    elif [ "$calculated" -lt 512 ]; then
        _CACHED_MEM_LIMIT="512"
    else
        _CACHED_MEM_LIMIT="$calculated"
    fi
    echo "$_CACHED_MEM_LIMIT"
}

# pnpm (v10+) may print warnings to stdout when npm_config_force=true.
# This helper isolates the actual path by taking the last non-empty line.
pnpm_root_g() {
    if [ -z "$_CACHED_PNPM_ROOT" ]; then
        _CACHED_PNPM_ROOT=$(pnpm root -g 2>/dev/null | sed -n '$p')
    fi
    echo "$_CACHED_PNPM_ROOT"
}

get_global_node_path() {
    local node_path="$PREFIX/lib/node_modules"
    if command -v pnpm >/dev/null 2>&1; then
        local pnpm_root
        pnpm_root=$(pnpm_root_g || true)
        if [ -n "$pnpm_root" ]; then
            node_path="$node_path:$pnpm_root"
        fi
    fi
    echo "$node_path"
}

# Portable timeout wrapper: falls back to direct execution if `timeout` is absent
safe_timeout() {
    local secs=$1; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# jiter has no armv8l wheels and maturin rejects armv8l.
# armv8l is backward-compatible with armv7l ABI, so install the
# manylinux2014_armv7l wheel directly into the target environment.
ensure_jiter_armv8l() {
    local pip_cmd="${1:-$(command -v pip3 || command -v pip || echo "python3 -m pip")}"
    local arch py_tag jiter_ver pypi_json url tmp_wheel whl
    arch="$(uname -m)"
    if [ "$arch" != "armv8l" ] && [ "$arch" != "armv7l" ]; then return 0; fi

    if ! command -v jq >/dev/null 2>&1; then
        warn_msg "jq not available; cannot fetch jiter armv7l wheel URL"
        return 0
    fi

    py_tag="$(python3 -c 'import sys; print(f"cp{sys.version_info.major}{sys.version_info.minor}-cp{sys.version_info.major}{sys.version_info.minor}")' 2>/dev/null || true)"
    if [ -z "$py_tag" ]; then return 0; fi

    # NOTE: Last verified 2025-05. Update this version when jiter releases new wheels.
    jiter_ver="0.14.0"
    whl="jiter-${jiter_ver}-${py_tag}-manylinux_2_17_armv7l.manylinux2014_armv7l.whl"

    status_msg "Fetching jiter armv7l wheel for ${py_tag}"
    pypi_json="$(curl -fsSL "https://pypi.org/pypi/jiter/${jiter_ver}/json" 2>/dev/null || true)"
    if [ -z "$pypi_json" ]; then
        warn_msg "Could not query PyPI for jiter; compilation may fail on armv8l/armv7l"
        return 0
    fi

    url="$(echo "$pypi_json" | jq -r --arg wheel "$whl" '.urls[] | select(.filename == $wheel) | .url' 2>/dev/null || true)"
    if [ -z "$url" ] || [ "$url" = "null" ]; then
        warn_msg "jiter ${jiter_ver} wheel not found on PyPI"
        return 0
    fi

    tmp_wheel="$(mktemp "${TMPDIR:-$PREFIX/tmp}/jiter.XXXXXXXX")"
    if ! curl -fsSL "$url" -o "$tmp_wheel" >/dev/null 2>&1; then
        rm -f "$tmp_wheel"
        warn_msg "Failed to download jiter wheel; compilation may fail"
        return 0
    fi

    rm -f "$tmp_wheel.whl"

    # Pip rejected the wheel (platform-tag mismatch: armv8l vs armv7l).
    # Extract the wheel directly into site-packages to bypass pip entirely.
    # This leaves jiter in a valid state for --no-build-isolation installs.

    py_interp="$("$pip_cmd" --version 2>/dev/null | sed -n 's/.*(python \([0-9.]*\)).*/python\1/p' || true)"
    if [ -z "$py_interp" ] || ! command -v "$py_interp" >/dev/null 2>&1; then
        # Fallback: if pip is a path like /.../bin/pip, python is likely /.../bin/python
        if [ -f "${pip_cmd%/pip}/python" ]; then
            py_interp="${pip_cmd%/pip}/python"
        elif [ -f "${pip_cmd%/pip}/python3" ]; then
            py_interp="${pip_cmd%/pip}/python3"
        else
            py_interp="python3"
        fi
    fi

    site_packages="$("$py_interp" -c "import sysconfig, site; print(site.getsitepackages()[0])" 2>/dev/null || true)"
    if [ -z "$site_packages" ] || [ ! -d "$site_packages" ]; then
        rm -f "$tmp_wheel"
        warn_msg "Could not locate site-packages for ${py_interp}; jiter extraction failed"
        return 0
    fi

    status_msg "Extracting jiter wheel to site-packages (bypassing pip tag check)"
    local extract_dir
    extract_dir="${TMPDIR:-$PREFIX/tmp}/jiter_extract_$$"
    mkdir -p "$extract_dir"
    if ! "$py_interp" -m zipfile -e "$tmp_wheel" "$extract_dir" >> "$LOG_FILE" 2>&1; then
        rm -rf "$extract_dir" "$tmp_wheel"
        warn_msg "Failed to extract jiter wheel"
        return 0
    fi

    # Remove any existing jiter installation to avoid mv conflicts
    rm -rf "$site_packages/jiter" "$site_packages/jiter-"*.dist-info
    if ! mv "$extract_dir"/* "$site_packages/" >> "$LOG_FILE" 2>&1; then
        rm -rf "$extract_dir" "$tmp_wheel"
        warn_msg "Failed to move jiter into site-packages"
        return 0
    fi

    # Fix: the wheel's .so extension is .arm-linux-gnueabihf but Termux Python
    # expects .arm-linux-androideabi. Rename so Python discovers the module.
    local so_gnu
    so_gnu=$(find "$site_packages/jiter" -maxdepth 1 -name '*.cpython-*-arm-linux-gnueabihf.so' -print -quit 2>/dev/null || true)
    if [ -n "$so_gnu" ] && [ -f "$so_gnu" ]; then
        mv "$so_gnu" "${so_gnu/arm-linux-gnueabihf/arm-linux-androideabi}" 2>>"$LOG_FILE" || true
    fi

    rm -rf "$extract_dir" "$tmp_wheel"
    success_msg
    return 0
}

ensure_peer_deps() {
    local pm=$1
    local deps=(
        "@slack/web-api" "@slack/bolt" "grammy" 
        "@grammyjs/runner" "@grammyjs/transformer-throttler" "@grammyjs/types"
        "@aws-sdk/client-bedrock" "@aws-sdk/client-bedrock-runtime"
        "@larksuiteoapi/node-sdk"
        "@buape/carbon"
    )
    
    status_msg "Checking peer dependencies"
    if [ "$pm" == "pnpm" ]; then
        execute "pnpm add -g ${deps[*]} --prefer-offline --ignore-scripts || pnpm add -g ${deps[*]} --ignore-scripts" "Installing missing channel and UI dependencies"
    else
        execute "npm install -g ${deps[*]} --silent" "Installing missing channel and UI dependencies"
    fi
}

ensure_openclaw_runtime_modules() {
    local pm=$1
    local modules=("@larksuiteoapi/node-sdk" "@buape/carbon" "grammy" "@grammyjs/runner" "@slack/web-api")
    local global_root
    global_root=$(npm root -g 2>/dev/null || echo "$PREFIX/lib/node_modules")
    
    # If pnpm, global root is different
    if [ "$pm" == "pnpm" ] && command -v pnpm >/dev/null 2>&1; then
        global_root=$(pnpm_root_g || echo "$global_root")
    fi

    status_msg "Linking runtime modules"
    mkdir -p "$OPENCLAW_ROOT/node_modules"
    
    for mod in "${modules[@]}"; do
        if [ -d "$global_root/$mod" ]; then
            # Handle scoped modules (@scope/pkg)
            if [[ "$mod" == "@"* ]]; then
                mkdir -p "$OPENCLAW_ROOT/node_modules/${mod%/*}"
            fi
            ln -sf "$global_root/$mod" "$OPENCLAW_ROOT/node_modules/$mod"
        fi
    done
    success_msg
}

# Intelligence Helpers
is_installed() {
    local tool_name=$1
    local pm=$(detect_package_manager "$tool_name")
    [[ "$pm" != "none" ]] && return 0
    return 1
}

smart_pkg_install() {
    local pkgs=("$@")
    local to_install=()
    
    # 1. Handle tur-repo priority
    if [[ " ${pkgs[*]} " =~ " tur-repo " ]]; then
        if ! dpkg -s "tur-repo" >/dev/null 2>&1; then
            execute "pkg install -y tur-repo" "Enabling Termux User Repository (TUR)"
            execute "pkg update -y" "Refreshing package database"
        fi
    fi

    # 2. Check remaining packages
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            to_install+=("$pkg")
        fi
    done

    if [ ${#to_install[@]} -gt 0 ]; then
        execute "pkg install -y ${to_install[*]}" "Installing missing system packages (${to_install[*]})"
    else
        status_msg "System packages already up to date"
        success_msg
    fi
}

detect_package_manager() {
    local tool_name=$1
    local config_key="pm_$tool_name"
    local stored_pm=$(get_config "$config_key")

    # 1. Use stored preference if it exists
    if [ "$stored_pm" != "null" ]; then echo "$stored_pm"; return; fi

    # 2. Only auto-detect if the directory actually exists
    if [ -d "$PREFIX/lib/node_modules/$tool_name" ]; then
        set_config "$config_key" "npm"; echo "npm"; return
    fi

    if command -v pnpm >/dev/null 2>&1; then
        if [ -d "$(pnpm_root_g)/$tool_name" ]; then
            set_config "$config_key" "pnpm"; echo "pnpm"; return
        fi
    fi

    echo "none"
}

select_package_manager() {
    local tool_name=$1
    if command -v pnpm >/dev/null 2>&1; then
        echo "pnpm"
    else
        echo "npm"
    fi
}

get_openclaw_root() {
    local pm=$1
    if [ "$pm" == "pnpm" ] && command -v pnpm >/dev/null 2>&1; then
        echo "$(pnpm_root_g)/openclaw"
    else
        echo "$PREFIX/lib/node_modules/openclaw"
    fi
}

confirm_action() {
    read -t 0.1 -n 10000 junk 2>/dev/null || true # Flush buffer
    echo -ne "\n${BLUE}>>${NC} $1? [Y/n]: "
    
    read -r -n1 key
    echo "" # Print newline
    
    # Handle Enter (empty string)
    if [[ -z "$key" ]]; then
        echo -e "${GREEN}Proceeding...${NC}"
        return 0
    fi
    
    # Strictly handle 'y' or 'Y'
    if [[ "$key" == "y" || "$key" == "Y" ]]; then
        echo -e "${GREEN}Proceeding...${NC}"
        return 0
    fi
    
    # Anything else is 'No'
    echo -e "${RED}Returning to menu...${NC}"
    sleep 0.5
    return 1
}

# --- 2.5. TUI HELPERS ---
# Use whiptail for menus; fallback to plain text if unavailable.

# Detect terminal size for whiptail sizing
get_term_size() {
    local rows cols
    if [ -t 0 ]; then
        read -r rows cols < <(stty size 2>/dev/null || echo "24 80")
    else
        rows=24; cols=80
    fi
    # Cap whiptail dimensions with padding
    local whi_rows=$(( rows > 10 ? rows - 4 : rows ))
    local whi_cols=$(( cols > 20 ? cols - 4 : cols ))
    # Minimum safe sizes for whiptail
    [ "$whi_rows" -lt 15 ] && whi_rows=15
    [ "$whi_cols" -lt 50 ] && whi_cols=50
    echo "$whi_rows $whi_cols"
}

WHI_SIZES=$(get_term_size)
WHI_ROWS=$(echo "$WHI_SIZES" | awk '{print $1}')
WHI_COLS=$(echo "$WHI_SIZES" | awk '{print $2}')

# show_menu <title> <items...
# items are passed as tag desc pairs, without dynamic status prefixing.
show_whi_menu() {
    local title="$1"; shift
    local -a items=() tags=() descs=()
    while [ $# -gt 0 ]; do
        items+=("$1" "$2")
        tags+=("$1")
        if [ "$1" = "" ]; then
            descs+=(" ")  # Use blank space for separator
        else
            descs+=("$2")
        fi
        shift 2
    done

    if command -v gum >/dev/null 2>&1; then
        clear >&2
        gum style --border double --margin "1" --padding "1" --border-foreground 212 "Droid AI Toolkit v$VERSION" >&2
        local choice_desc
        choice_desc=$(gum choose --header "$title" --cursor="> " "${descs[@]}") || return 1
        for i in "${!descs[@]}"; do
            if [ "${descs[$i]}" = "$choice_desc" ]; then
                echo "${tags[$i]}"
                return 0
            fi
        done
        return 1
    else
        whiptail --title "Droid AI Toolkit v$VERSION" --nocancel --ok-button "Enter" --menu "$title" "$WHI_ROWS" "$WHI_COLS" $(( ${#items[@]} / 2 )) \
            "${items[@]}" 3>&1 1>&2 2>&3
    fi
}

# yesno <text>
# Standard confirmation dialog: Yes → proceed, No → cancel
# Returns 0 if user confirms (Yes), 1 if user cancels (No)
whiptail_confirm() {
    local text="$1"
    if command -v gum >/dev/null 2>&1; then
        gum confirm "$text"
        return $?
    else
        if ! whiptail --title "Confirm" --yes-button "Yes" --no-button "No" --yesno "$text" 8 "$WHI_COLS" 3>&1 1>&2 2>&3; then
            return 1
        fi
        return 0
    fi
}

# msgbox <text>
whiptail_msg() {
    local text="$1"
    if command -v gum >/dev/null 2>&1; then
        echo ""
        gum style --border normal --border-foreground 212 --padding "1 2" "$text"
        echo -n "Press Enter to continue..."
        read -r
    else
        whiptail --title "Notice" --msgbox "$text" 8 "$WHI_COLS" 3>&1 1>&2 2>&3
    fi
}

ensure_nodejs_links() {
    if [ -d "$PREFIX/opt/nodejs-lts/bin" ]; then
        local node_opt_bin="$PREFIX/opt/nodejs-lts/bin"
        execute "ln -sf '$node_opt_bin/node' '$TERMUX_BIN/node' && ln -sf '$node_opt_bin/npm' '$TERMUX_BIN/npm'" "Verifying Node.js links"
    fi
}

# Execute a command with a loading spinner & localized logs
execute() {
    local cmd="$1"
    local msg="$2"
    local frames='|/-\'
    local tmp_log; tmp_log=$(mktemp)
    
    # Start spinner in background
    (
        while true; do
            for (( i=0; i<${#frames}; i++ )); do
                printf "\r${CLEAR_LINE}${BLUE}==>${NC} %s [%s] " "$msg" "${frames:$i:1}"
                sleep 0.15
            done
        done
    ) &
    local spinner_pid=$!
    
    # Ensure spinner dies if user hits Ctrl+C — print context before aborting
    trap 'echo -e "\n${YELLOW}Interrupted by user.${NC}"; kill $spinner_pid 2>/dev/null; rm -f "$tmp_log"; exit 1' INT TERM
    
    # Run command and capture exit code
    local exit_code=0
    eval "$cmd" > "$tmp_log" 2>&1 || exit_code=$?
    
    # Stop spinner & cleanup trap
    kill $spinner_pid 2>/dev/null || true
    wait $spinner_pid 2>/dev/null || true
    trap - INT TERM
    
    # Append to main log
    cat "$tmp_log" >> "$LOG_FILE"
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}Done.${NC}"
        return 0
    else
        printf "\r${CLEAR_LINE}${BLUE}==>${NC} %s ${RED}Failed!${NC}\n" "$msg"
        echo -e "\n${RED}Error details for this step:${NC}"
        tail -n 15 "$LOG_FILE"
        echo -e "\n${YELLOW}Full log available at: $LOG_FILE${NC}"
        return $exit_code
    fi
}


# Stops app processes, kills PM2, and cleans lock files.
# Usage: prepare_for_install <app_name> [extra_pkill_patterns...]
prepare_for_install() {
    local app="$1"
    shift
    status_msg "Stopping existing tasks & freeing memory"
    pkill -9 -f "$app" 2>/dev/null || true
    for pat in "$@"; do
        pkill -9 -f "$pat" 2>/dev/null || true
    done
    command -v pm2 >/dev/null 2>&1 && pm2 kill >> "$LOG_FILE" 2>&1 || true
    success_msg
}

# Standard install preamble: clear log file, print log path.
begin_install() {
    rm -f "$LOG_FILE"
    echo -e "${YELLOW}Verbose logs: $LOG_FILE${NC}
"
}

# --- 3. TERMUX CHECK ---

check_termux() {
    if [ -z "$TERMUX_VERSION" ] && [ ! -d "/data/data/com.termux" ]; then
        error_msg "This script must be run inside Termux on Android."
        exit 1
    fi
}

# --- 4. INSTALLATION FUNCTIONS ---

install_openclaw() {
    local mode="repair"
    local target_version="latest"

    if is_installed "openclaw"; then
        local choice
        choice=$(show_whi_menu "OpenClaw is already installed  |  Use ↑/↓ and Enter" \
            "REPAIR"    "[R]  Repair Patches (Fast — ~2 seconds)" \
            "UPDATE"    "[U]  Update to Latest (Full re-install)" \
            "VERSION"   "[V]  Install Specific Version (e.g. 2026.6.30)" \
            "ZULIP"     "[Z]  Zulip Plugin" \
            ""          "" \
            "BACK"      "<--  BACK TO AGENTS MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            REPAIR) mode="repair" ;;
            UPDATE) mode="full" ;;
            VERSION)
                mode="full"
                if command -v gum >/dev/null 2>&1; then
                    target_version=$(gum input --placeholder "2026.6.30" --prompt "Enter OpenClaw version: ")
                else
                    echo -ne "${BLUE}Enter OpenClaw version (e.g. 2026.6.30): ${NC}"
                    read -r target_version
                fi
                if [ -z "$target_version" ]; then
                    warn_msg "No version entered — defaulting to latest"
                    target_version="latest"
                fi
                ;;
            ZULIP) manage_zulip_plugin; return 0 ;;
            BACK|*) return 0 ;;
        esac
    else
        local choice
        choice=$(show_whi_menu "Install OpenClaw  |  Use ↑/↓ and Enter" \
            "INSTALL"   "[I]  Install Latest" \
            "VERSION"   "[V]  Install Specific Version (e.g. 2026.6.30)" \
            ""          "" \
            "BACK"      "<--  BACK TO AGENTS MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            INSTALL) mode="full" ;;
            VERSION)
                mode="full"
                if command -v gum >/dev/null 2>&1; then
                    target_version=$(gum input --placeholder "2026.6.30" --prompt "Enter OpenClaw version: ")
                else
                    echo -ne "${BLUE}Enter OpenClaw version (e.g. 2026.6.30): ${NC}"
                    read -r target_version
                fi
                if [ -z "$target_version" ]; then
                    warn_msg "No version entered — defaulting to latest"
                    target_version="latest"
                fi
                ;;
            BACK|*) return 0 ;;
        esac
    fi

    begin_install
    prepare_for_install "openclaw" "n8n"
    rm -f "$HOME/.openclaw/tmp/openclaw.lock" "$HOME/.openclaw/tmp/openclaw-*" "$PREFIX/var/run/crond.pid"

    if [[ "$mode" == "full" ]]; then
        # Batched package installation for performance
        smart_pkg_install tur-repo build-essential libvips openssh git python3 pkg-config cmake tmux binutils termux-services ffmpeg golang nodejs-lts psmisc
    fi

    ensure_nodejs_links

    PKG_MANAGER=$(select_package_manager "openclaw")
    [[ "$PKG_MANAGER" == "back" ]] && return 0
    OPENCLAW_ROOT=$(get_openclaw_root "$PKG_MANAGER")

    if [[ "$mode" == "full" ]]; then
        status_msg "Preparing clean slate"
        rm -rf "$OPENCLAW_ROOT"
        success_msg

        if [ "$PKG_MANAGER" == "npm" ]; then
            execute "npm install -g openclaw@${target_version}" "Installing OpenClaw ${target_version} via npm"
        else
            execute "pnpm add -g openclaw@${target_version} --force --ignore-scripts" "Installing OpenClaw ${target_version} via pnpm"
        fi
    fi

    status_msg "Applying Android patches"
    apply_patches
    success_msg

    # Multi-stage legacy-state migration (2026.9.x gates the gateway on it;
    # 'doctor --fix' cannot run on Android). Runs only when legacy files exist.
    migrate_openclaw_legacy_state

    if [[ "$mode" == "full" ]]; then
        # Configure for Termux
        CONFIG_PATH="$HOME/.openclaw/openclaw.json"
        if [ -f "$CONFIG_PATH" ]; then
            status_msg "Configuring Termux-specific settings"
            local tmp_cfg; tmp_cfg=$(mktemp)
            # Single-pass jq: disable audio/UI, clean unsupported plugins, re-enable core ones,
            # remove legacy streaming keys, set Telegram token.
            jq '
                .channelToken = ((.channelToken // {}) + {"telegram": (.channelToken.telegram // "YOUR_BOT_TOKEN")}) |
                # 2026.9.x: a failed doctor run can leave a fresh config without
                # gateway.mode, which blocks gateway start ("existing config is
                # missing gateway.mode"). Pin local (PM2-managed on this toolkit).
                .gateway.mode = (.gateway.mode // "local") |
                .ui.showSystemPrompt = false |
                .disableAudio = true |
                .plugins.entries = ((.plugins.entries // {}) | with_entries(.value |= . + {"enabled": false})) |
                del(.plugins.entries["kimi-coding"], .plugins.entries["speech-core"], .plugins.entries["image-generation-core"], .plugins.entries["video-generation-core"], .plugins.entries["media-understanding-core"]) |
                .plugins.entries.telegram = {"enabled": true} |
                .plugins.entries.ollama = {"enabled": true} |
                .plugins.entries["memory-core"] = {"enabled": true} |
                del(.channels.telegram.streamMode, .channels.telegram.chunkMode, .channels.telegram.blockStreaming, .channels.telegram.draftChunk, .channels.telegram.blockStreamingCoalesce) |
                # 2026.9.x defaults channels.telegram.dmPolicy to "pairing", which silently
                # revokes command authorization (slash commands reply "No reply was
                # generated") unless the sender is in the pairing store. Explicitly pin
                # "allowlist" so allowFrom keeps governing access; user-set values win.
                .channels.telegram.dmPolicy = (.channels.telegram.dmPolicy // "allowlist") |
                del(.channels.slack.streamMode, .channels.slack.chunkMode, .channels.slack.blockStreaming, .channels.slack.blockStreamingCoalesce, .channels.slack.nativeStreaming) |
                if (.channels.telegram.streaming? | type) != "object" then del(.channels.telegram.streaming) else . end |
                if (.channels.slack.streaming? | type) != "object" then del(.channels.slack.streaming) else . end' "$CONFIG_PATH" > "$tmp_cfg" && mv "$tmp_cfg" "$CONFIG_PATH"
                        # Android: doctor's service-ownership step requires a service
                        # manager; the external-supervisor env vars skip it by upstream
                        # design (gateway is already stopped here — prepare_for_install
                        # killed PM2 apps). Verified on 2026.9.1 / device y6.
                        yes "" | OPENCLAW_SERVICE_REPAIR_POLICY=external OPENCLAW_SUPERVISOR_MODE=external openclaw doctor --fix >> "$LOG_FILE" 2>&1 || true
            success_msg
        fi
        apply_patches "silent"
    fi
    
    echo -e "\n${GREEN}OpenClaw successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed") and patched!${NC}"
    health_check "OpenClaw" "command -v openclaw" || true
    echo -e "\n${YELLOW}NEXT STEPS:${NC}"
    echo -e "1. Run ${GREEN}openclaw onboard${NC} to configure your API keys."
    echo -e "2. Select ${BLUE}SERVICES${NC} -> ${BLUE}PM2${NC} (Recommended) or ${BLUE}Native Services${NC} to configure background services."
    echo -e "\n${RED}DO NOT USE 'openclaw update'${NC}"
    echo -e "   This will break patches. Select ${BLUE}AGENTS${NC} -> ${BLUE}OpenClaw${NC} from the main menu to update."
    wait_to_continue
}

# --- ZULIP PLUGIN MANAGEMENT ---
# Sub-menu for installing/updating/uninstalling the Zulip plugin.
# OpenClaw must already be installed.
manage_zulip_plugin() {
    command -v openclaw >/dev/null 2>&1 || { error_msg "OpenClaw is not installed"; wait_to_continue; return 0; }

    local choice
    choice=$(show_whi_menu "Zulip Plugin  |  Use ↑/↓ and Enter" \
        "INSTALL"   "[I]  Install Latest" \
        "UPDATE"    "[U]  Update to Latest" \
        "VERSION"   "[S]  Install Specific Version" \
        "UNINSTALL" "[X]  Uninstall" \
        ""          "" \
        "BACK"      "<--  BACK TO OPENCLAW MENU") || return 0

    case "$choice" in
        "") return 0 ;;
        INSTALL)
            status_msg "Installing Zulip plugin (latest)"
            openclaw plugins install clawhub:@niyazmft/openclaw-zulip 2>&1 | tee -a "$LOG_FILE"
            success_msg
            ;;
        UPDATE)
            status_msg "Updating Zulip plugin to latest"
            openclaw plugins update zulip 2>&1 | tee -a "$LOG_FILE" || \
                openclaw plugins install clawhub:@niyazmft/openclaw-zulip@latest 2>&1 | tee -a "$LOG_FILE"
            success_msg
            ;;
        VERSION)
            local zulip_ver=""
            if command -v gum >/dev/null 2>&1; then
                zulip_ver=$(gum input --placeholder "2026.7.0" --prompt "Enter Zulip version: ")
            else
                echo -ne "${BLUE}Enter Zulip version (e.g. 2026.7.0): ${NC}"
                read -r zulip_ver
            fi
            if [ -z "$zulip_ver" ]; then
                warn_msg "No version entered — aborting"
                return 0
            fi
            status_msg "Installing Zulip plugin ${zulip_ver}"
            openclaw plugins install "clawhub:@niyazmft/openclaw-zulip@${zulip_ver}" 2>&1 | tee -a "$LOG_FILE"
            success_msg
            ;;
        UNINSTALL)
            confirm_action "Uninstall Zulip plugin" || return 0
            status_msg "Uninstalling Zulip plugin"
            openclaw plugins uninstall zulip 2>&1 | tee -a "$LOG_FILE"
            success_msg
            ;;
        BACK|*) return 0 ;;
    esac

    wait_to_continue
}

# --- 4.1. PATCH ENGINE ---
# Modular patch functions: each handles one tool's Android-specific fixes.
# Called individually or via apply_patches() coordinator.

patch_koffi() {
    local silent=$1
    local KOFFI_SRC="$OPENCLAW_ROOT/node_modules/koffi/lib/native/base/base.cc"
    [ -f "$KOFFI_SRC" ] || return 0

    local K_TRIPLET="android_armsf"
    [[ "$ARCH_TYPE" == "aarch64" ]] && K_TRIPLET="android_arm64"
    local KOFFI_NODE="$OPENCLAW_ROOT/node_modules/koffi/build/koffi/$K_TRIPLET/koffi.node"
    local verbose_flag=""
    [[ "$silent" == "silent" ]] && verbose_flag="-q"

    # Skip rebuild if binary exists and is newer than source (saves 30-60s on ARM)
    if [ -f "$KOFFI_NODE" ] && [ "$KOFFI_NODE" -nt "$KOFFI_SRC" ] && [[ "$silent" != "silent" ]]; then
        status_msg "Koffi binary already built"
        success_msg
        return 0
    fi

    if [[ "$silent" != "silent" ]]; then
        execute "sed -i 's/renameat2(AT_FDCWD, src_filename, AT_FDCWD, dest_filename, RENAME_NOREPLACE)/rename(src_filename, dest_filename)/g' '$KOFFI_SRC'" "Patching Koffi native library"
        execute "cd '$OPENCLAW_ROOT/node_modules/koffi' && JOBS=1 MAKEFLAGS='-j1' node src/cnoke/cnoke.js -p . -d src/koffi --prebuild" "Rebuilding Koffi"
        execute "mkdir -p '$K_TRIPLET' && cp 'build/koffi/$K_TRIPLET/koffi.node' '$K_TRIPLET/'" "Mapping Koffi binary"
    else
        sed -i 's/renameat2(AT_FDCWD, src_filename, AT_FDCWD, dest_filename, RENAME_NOREPLACE)/rename(src_filename, dest_filename)/g' "$KOFFI_SRC"
        (cd "$OPENCLAW_ROOT/node_modules/koffi" && JOBS=1 MAKEFLAGS='-j1' node src/cnoke/cnoke.js -p . -d src/koffi --prebuild $verbose_flag) 2>/dev/null || true
        mkdir -p "$K_TRIPLET" && cp "build/koffi/$K_TRIPLET/koffi.node" "$K_TRIPLET/" 2>/dev/null || true
    fi
}

patch_gemini_cli() {
    local silent=$1
    local _gemini_paths; _gemini_paths="$(get_global_node_path)"
    [ -n "$_gemini_paths" ] || return 0

    if [[ "$silent" != "silent" ]]; then
        status_msg "Patching Gemini CLI for Android"
    fi
    local _gp
    IFS=':' read -ra _gpaths <<< "$_gemini_paths"
    for _gp in "${_gpaths[@]}"; do
        [ -d "$_gp" ] || continue
        find -L "$_gp" -maxdepth 6 -type f -name "projectRegistry.js" -exec sed -i 's|await fs.promises.rename(\([^,]*\), \([^)]*\))|await fs.promises.copyFile(\1, \2); await fs.promises.unlink(\1)|g' {} + 2>/dev/null || true
    done
    if [[ "$silent" != "silent" ]]; then
        success_msg
    fi
}

create_sqlite3_stub() {
    local SQLITE3_DIR="$HOME/paperclip/node_modules/.pnpm/sqlite3@5.1.7/node_modules/sqlite3"
    [ -d "$SQLITE3_DIR" ] || return 0
    [ ! -f "$SQLITE3_DIR/build/node_sqlite3.node" ] || return 0

    mkdir -p "$SQLITE3_DIR/build" "$SQLITE3_DIR/lib"
    cat > "$SQLITE3_DIR/package.json" << 'PKGEOF'
{"name":"sqlite3","version":"5.1.7","main":"./lib/sqlite3.js","type":"commonjs"}
PKGEOF
    cat > "$SQLITE3_DIR/lib/sqlite3.js" << 'JSEOF'
const Database = function() {};
Database.prototype.run = function() { return this; };
Database.prototype.get = function() { return this; };
Database.prototype.all = function() { return []; };
Database.prototype.close = function() {};
Database.prototype.serialize = function(fn) { if (fn) fn(); };
Database.prototype.parallelize = function(fn) { if (fn) fn(); };
module.exports = Database;
module.exports.Database = Database;
JSEOF
    cp "$SQLITE3_DIR/lib/sqlite3.js" "$SQLITE3_DIR/index.js"
    cp "$SQLITE3_DIR/lib/sqlite3.js" "$SQLITE3_DIR/build/node_sqlite3.node"
}

patch_paperclip() {
    local silent=$1
    [ -f "$HOME/paperclip/server/dist/index.js" ] || return 0

    # Path redirection: /tmp -> ~/.tmp, /usr/local/bin -> $PREFIX/bin
    if [[ "$silent" != "silent" ]]; then
        execute "sed -i 's|/tmp/|${HOME}/.tmp/|g; s|/usr/local/bin|${PREFIX}/bin|g' '${HOME}/paperclip/server/dist/index.js'" "Patching Paperclip paths"
    else
        sed -i 's|/tmp/|'"${HOME}"'/.tmp/|g; s|/usr/local/bin|"'"${PREFIX}"'/bin|g' "$HOME/paperclip/server/dist/index.js" 2>/dev/null || true
    fi

    # Repair workspace symlinks (pnpm v9 may not create them on Android)
    if [ -d "$HOME/paperclip/node_modules/.pnpm" ]; then
        find -L "$HOME/paperclip/node_modules/.bin" -type l -delete 2>/dev/null || true
        mkdir -p "$HOME/paperclip/node_modules/@paperclipai"
        local -a PC_NAMES=(
            db shared adapter-utils mcp-server skills-catalog plugin-sdk
            adapter-acpx-local adapter-claude-local adapter-codex-local
            adapter-cursor-cloud adapter-cursor-local adapter-gemini-local
            adapter-grok-local adapter-openclaw-gateway adapter-opencode-local
            adapter-pi-local create-paperclip-plugin plugin-fake-sandbox
            plugin-workspace-diff
        )
        local -a PC_PATHS=(
            packages/db packages/shared packages/adapter-utils packages/mcp-server
            packages/skills-catalog packages/plugins/sdk
            packages/adapters/acpx-local packages/adapters/claude-local
            packages/adapters/codex-local packages/adapters/cursor-cloud
            packages/adapters/cursor-local packages/adapters/gemini-local
            packages/adapters/grok-local packages/adapters/openclaw-gateway
            packages/adapters/opencode-local packages/adapters/pi-local
            packages/plugins/create-paperclip-plugin
            packages/plugins/paperclip-plugin-fake-sandbox
            packages/plugins/plugin-workspace-diff
        )
        local i _name _path
        for i in "${!PC_NAMES[@]}"; do
            _name="${PC_NAMES[$i]}"
            _path="${PC_PATHS[$i]}"
            if [ -d "$HOME/paperclip/$_path" ]; then
                local _dest="$HOME/paperclip/node_modules/@paperclipai/$_name"
                if [ "$(readlink "$_dest" 2>/dev/null)" != "../../$_path" ]; then
                    ln -sf "../../$_path" "$_dest" 2>/dev/null || true
                fi
            fi
        done
    fi

    create_sqlite3_stub
}

patch_openclaw_registerhooks() {
    local silent=$1
    [ -n "$OPENCLAW_ROOT" ] && [ -d "$OPENCLAW_ROOT" ] || return 0

    # Use glob since the cache-buster hash changes between versions
    local TARGET
    TARGET=$(find "$OPENCLAW_ROOT/dist" -maxdepth 1 -name 'plugin-module-loader-cache-*.js' -print -quit 2>/dev/null)
    [ -n "$TARGET" ] && [ -f "$TARGET" ] || return 0

    if [[ "$silent" != "silent" ]]; then
        status_msg "Patching OpenClaw registerHooks for Android/Node 24"
    fi

    # Check if already patched
    command -v python3 >/dev/null 2>&1 || return 0

    # Use glob since the cache-buster hash changes between versions
    local TARGET
    TARGET=$(find "$OPENCLAW_ROOT/dist" -maxdepth 1 -name 'plugin-module-loader-cache-*.js' -print -quit 2>/dev/null)
    [ -n "$TARGET" ] && [ -f "$TARGET" ] || return 0

    # Idempotency: the rename is content-based; a re-run finds nothing to match
    if grep -q 'registerHooksX?.(' "$TARGET" 2>/dev/null; then
        if [[ "$silent" != "silent" ]]; then
            success_msg "Already patched"
        fi
        return 0
    fi

    if [[ "$silent" != "silent" ]]; then
        status_msg "Patching OpenClaw registerHooks for Android/Node 24"
    fi

    cp "$TARGET" "${TARGET}.bak" 2>/dev/null || true

    # Rename registerHooks -> registerHooksX so the optional-chained call
    # short-circuits (the module hooks API deadlocks the Node 24 gateway on
    # Android). NOTE: a sed BRE with \? here can never match
    # ".registerHooks?.(" — GNU \? makes the preceding "s" optional, so the
    # literal "?" in the text is unmatched — use exact-string replacement.
    if python3 - "$TARGET" <<'PYOCR'
import sys

path = sys.argv[1]
data = open(path, encoding="utf-8", errors="replace").read()
old = ".registerHooks?.("
count = data.count(old)
if count == 0:
    sys.exit("registerHooks call sites not found (upstream may have fixed the deadlock)")
data = data.replace(old, ".registerHooksX?.(")
open(path, "w", encoding="utf-8", errors="replace").write(data)
print(f"renamed {count} registerHooks call(s)")
PYOCR
    then
        if [[ "$silent" != "silent" ]]; then
            success_msg
        fi
    else
        # Non-fatal: newer OpenClaw may have fixed the deadlock upstream
        cp "${TARGET}.bak" "$TARGET" 2>/dev/null || true
        if [[ "$silent" != "silent" ]]; then
            warn_msg "registerHooks pattern not matched (upstream changed) — verify gateway startup manually"
        fi
    fi
}

# OpenClaw 2026.9.1+ hardcodes "/tmp" in resolveStateLifecycleRuntimeDirectory()
# on non-Windows. Android/Termux has no /tmp directory.
patch_openclaw_tmp() {
    local silent=$1
    [ -n "$OPENCLAW_ROOT" ] && [ -d "$OPENCLAW_ROOT" ] || return 0

    local patched=0
    # Find all dist JS files that contain the hardcoded "/tmp" fallback
    while IFS= read -r _jsfile; do
        [ -f "$_jsfile" ] || continue
        # Replace:  ... : "/tmp"   with   ... : (process.env.TMPDIR || "/tmp")
        if grep -q ': "/tmp"' "$_jsfile" 2>/dev/null; then
            cp "$_jsfile" "${_jsfile}.bak" 2>/dev/null || true
            sed -i 's#: \"/tmp\"#: (process.env.TMPDIR || \"/tmp\")#g' "$_jsfile" 2>/dev/null || true
            patched=$((patched + 1))
        fi
    done < <(grep -rl ': "/tmp"' "$OPENCLAW_ROOT/dist" 2>/dev/null || true)

    if [[ "$silent" != "silent" ]]; then
        if [ "$patched" -gt 0 ]; then
            status_msg "Patching OpenClaw /tmp paths for Android (patched $patched files)"
            success_msg
        fi
    fi
}

patch_openclaw_links() {
    local silent=$1
    [ -n "$OPENCLAW_ROOT" ] && [ -d "$OPENCLAW_ROOT" ] || return 0

    if [[ "$silent" != "silent" ]]; then
        status_msg "Patching OpenClaw native hardlinks"
    fi
    # Pre-filter with grep -rl (much faster than find -exec sed on every .js in node_modules)
    grep -rlZE 'promises\.link\(|fs\.linkSync\(|[^a-zA-Z0-9_]fs\.link\(' "$OPENCLAW_ROOT" 2>/dev/null | while IFS= read -r _jsfile; do
        sed -i -E 's/promises\.link\(/promises.copyFile(/g; s/fs\.linkSync\(/fs.copyFileSync(/g; s/\bfs\.link\(/fs.copyFile(/g' "$_jsfile" 2>/dev/null || true
    done
    if [[ "$silent" != "silent" ]]; then
        success_msg
    fi
}

# OpenClaw 2026.9.x session-SQLite migration machinery relies on hardlinks
# (fs.link, nlink===2 assertions) which Android/Termux blocks with EACCES.
# Patch the defining module (doctor-session-sqlite-restore-*.js) so the
# migration falls back to a timestamp-preserving copy when link() is refused.
patch_openclaw_sqlite_archive() {
    local silent=$1
    [ -n "$OPENCLAW_ROOT" ] && [ -d "$OPENCLAW_ROOT" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    # Glob since the chunk hash changes between versions
    local TARGET
    TARGET=$(find "$OPENCLAW_ROOT/dist" -maxdepth 1 -name 'doctor-session-sqlite-restore-*.js' -print -quit 2>/dev/null)
    [ -n "$TARGET" ] && [ -f "$TARGET" ] || return 0

    # Idempotency marker embedded by the patch below
    if grep -q 'droid-ai-toolkit: Android hardlink copy fallback' "$TARGET" 2>/dev/null; then
        return 0
    fi

    if [[ "$silent" != "silent" ]]; then
        status_msg "Patching OpenClaw SQLite archive hardlinks for Android"
    fi

    cp "$TARGET" "${TARGET}.bak" 2>/dev/null || true

    if python3 - "$TARGET" <<'PYOCARC'
import sys

path = sys.argv[1]
data = open(path, encoding="utf-8").read()

old1 = ("function sameMigrationArtifact(left, right) {\n"
        "\treturn left.dev === right.dev && left.ino === right.ino && left.mtimeNs === right.mtimeNs && left.size === right.size && left.sha256 === right.sha256;\n"
        "}")
new1 = ("function sameMigrationArtifact(left, right) {\n"
        "\treturn left.size === right.size && left.sha256 === right.sha256;\n"
        "}")

old2 = ("\t\tif (!sameMigrationArtifact(readMigrationArtifactIdentity(sourcePath), expected)) throw new Error(\"artifact changed before publication\");\n"
        "\t\tconst published = await publishFileExclusive({\n"
        "\t\t\tsourcePath,\n"
        "\t\t\ttargetPath,\n"
        "\t\t\texpectedSourceIdentity: {\n"
        "\t\t\t\tdev: BigInt(expected.dev),\n"
        "\t\t\t\tino: BigInt(expected.ino)\n"
        "\t\t\t},\n"
        "\t\t\tstrategy: \"link-required\",\n"
        "\t\t\tonSyncFailure: \"preserve\"\n"
        "\t\t});\n"
        "\t\trequireDirectorySync(published.directorySync, \"Recovery artifact publication\");")
new2 = ("\t\tif (!sameMigrationArtifact(readMigrationArtifactIdentity(sourcePath), expected)) throw new Error(\"artifact changed before publication\");\n"
        "\t\ttry {\n"
        "\t\t\tconst published = await publishFileExclusive({\n"
        "\t\t\t\tsourcePath,\n"
        "\t\t\t\ttargetPath,\n"
        "\t\t\t\texpectedSourceIdentity: {\n"
        "\t\t\t\t\tdev: BigInt(expected.dev),\n"
        "\t\t\t\t\tino: BigInt(expected.ino)\n"
        "\t\t\t\t},\n"
        "\t\t\t\tstrategy: \"link-required\",\n"
        "\t\t\t\tonSyncFailure: \"preserve\"\n"
        "\t\t\t});\n"
        "\t\t\trequireDirectorySync(published.directorySync, \"Recovery artifact publication\");\n"
        "\t\t} catch (publishError) { /* droid-ai-toolkit: Android hardlink copy fallback */\n"
        "\t\t\tif (fs.lstatSync(targetPath, { bigint: true, throwIfNoEntry: false })) {\n"
        "\t\t\t\trequireDirectorySync(await syncDirectory(path.dirname(targetPath)), \"Recovery artifact publication\");\n"
        "\t\t\t} else {\n"
        "\t\t\t\tconst sourceStat = fs.lstatSync(sourcePath, { bigint: true });\n"
        "\t\t\t\tfs.copyFileSync(sourcePath, targetPath);\n"
        "\t\t\t\ttry {\n"
        "\t\t\t\t\tfs.utimesSync(targetPath, new Date(Number(sourceStat.atimeMs)), new Date(Number(sourceStat.mtimeMs)));\n"
        "\t\t\t\t} catch {}\n"
        "\t\t\t\trequireDirectorySync(await syncDirectory(path.dirname(targetPath)), \"Recovery artifact publication\");\n"
        "\t\t\t}\n"
        "\t\t}")

old3 = "\tif (!target.isFile() || !source.isFile() || target.dev !== source.dev || target.ino !== source.ino || source.nlink !== 2n || !sameMigrationArtifact(readMigrationArtifactIdentity(sourcePath, 2n), expected) || !sameMigrationArtifact(readMigrationArtifactIdentity(targetPath, 2n), expected)) throw new Error(\"publication paths changed or have unexpected aliases\");"
new3 = ("\tif (target.dev === source.dev && target.ino === source.ino) {\n"
        "\t\tif (!target.isFile() || source.nlink !== 2n || !sameMigrationArtifact(readMigrationArtifactIdentity(sourcePath, 2n), expected) || !sameMigrationArtifact(readMigrationArtifactIdentity(targetPath, 2n), expected)) throw new Error(\"publication paths changed or have unexpected aliases\");\n"
        "\t} else if (!target.isFile() || !source.isFile() || !sameMigrationArtifact(readMigrationArtifactIdentity(sourcePath, 1n), expected) || !sameMigrationArtifact(readMigrationArtifactIdentity(targetPath, 1n), expected)) throw new Error(\"publication paths changed or have unexpected aliases\");")

for name, old, new in (("sameMigrationArtifact", old1, new1), ("moveMigrationArtifact", old2, new2), ("assertMigrationArtifactPublication", old3, new3)):
    if old not in data or data.count(old) != 1:
        sys.exit("pattern not found or not unique: " + name)
    data = data.replace(old, new)

open(path, "w", encoding="utf-8").write(data)
PYOCARC
    then
        if [[ "$silent" != "silent" ]]; then
            success_msg
        fi
    else
        # Non-fatal: without the patch the session import fails at the archive
        # step on Android; user data is untouched (import validates first).
        cp "${TARGET}.bak" "$TARGET" 2>/dev/null || true
        if [[ "$silent" != "silent" ]]; then
            warn_msg "OpenClaw SQLite archive patch did not match this version — session migration may need manual 'openclaw doctor --session-sqlite import'"
        fi
    fi
}

# Multi-stage legacy-state migration for OpenClaw 2026.9.x on Android/Termux.
# Upstream 'openclaw doctor --fix' cannot run on Android (it requires a
# systemd/launchd service owner), so the stages are run directly:
#   Stage 1: legacy workspace setup state (JSON) -> state DB SQLite row
#   Stage 2: legacy session store (sessions.json) -> agent SQLite via
#            'openclaw doctor --session-sqlite import' (requires the
#            hardlink copy-fallback patch above on Android)
#   Stage 3: legacy exec-approvals config (exec-approvals.json) -> state DB
#            exec_approvals_config row; otherwise gateway channels crash-loop
migrate_openclaw_legacy_state() {
    command -v openclaw >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    local STATE_DIR="$HOME/.openclaw"
    [ -d "$STATE_DIR" ] || return 0

    # Detect work: stage 1 legacy workspace JSONs, stage 2 legacy session stores,
    # stage 3 legacy exec-approvals config
    local need1=0 need2=0 need3=0
    [ -f "$STATE_DIR/workspace/openclaw-workspace-state.json" ] && need1=1
    [ -f "$STATE_DIR/workspace/.openclaw/workspace-state.json" ] && need1=1
    if compgen -G "$STATE_DIR/sessions/sessions.json" >/dev/null 2>&1 \
        || compgen -G "$STATE_DIR/agents/*/sessions/sessions.json" >/dev/null 2>&1; then
        need2=1
    fi
    if [ -f "$STATE_DIR/exec-approvals.json" ] \
        || compgen -G "$STATE_DIR/exec-approvals.json.doctor-importing*" >/dev/null 2>&1; then
        need3=1
    fi
    [ "$need1" -eq 1 ] || [ "$need2" -eq 1 ] || [ "$need3" -eq 1 ] || return 0

    status_msg "Migrating legacy OpenClaw state (gateway will be paused)"

    # Stop the gateway if PM2 is running it (SQLite/file contention)
    local was_running=0
    if command -v pm2 >/dev/null 2>&1 && [ -n "$(pm2 pid openclaw 2>/dev/null)" ]; then
        was_running=1
        pm2 stop openclaw >/dev/null 2>&1 || true
        sleep 1
    fi

    local migrate_ok=1

    if [ "$need1" -eq 1 ]; then
        # Stage 1: workspace setup state. Backs up legacy files instead of
        # deleting; gateway gate only checks the original paths.
        local backup_dir="$STATE_DIR/backup-legacy-state-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$backup_dir"
        if python3 - "$STATE_DIR" "$backup_dir" <<'PYOCWS'
import hashlib, json, os, shutil, sqlite3, sys, time

state_dir, backup_dir = sys.argv[1], sys.argv[2]
ws_path = os.path.join(state_dir, "workspace")
legacy_files = [
    os.path.join(ws_path, "openclaw-workspace-state.json"),
    os.path.join(ws_path, ".openclaw", "workspace-state.json"),
]

payload = None
for legacy in legacy_files:
    if os.path.isfile(legacy):
        with open(legacy, encoding="utf-8") as fh:
            payload = json.load(fh)
        break

if payload:
    db_path = os.path.join(state_dir, "state", "openclaw.sqlite")
    if not os.path.isfile(db_path):
        sys.exit("state database missing; refusing to guess")
    wk = hashlib.sha256(ws_path.encode()).hexdigest()
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM workspace_setup_state WHERE workspace_key = ?", (wk,))
        now_ms = int(time.time() * 1000)
        row = (wk, ws_path, int(payload.get("version") or 1),
               str(payload.get("bootstrapSeededAt") or ""),
               str(payload.get("setupCompletedAt") or ""), now_ms)
        if cur.fetchone():
            cur.execute("""UPDATE workspace_setup_state SET workspace_path=?, version=?,
                bootstrap_seeded_at=?, setup_completed_at=?, updated_at=?
                WHERE workspace_key=?""", row[1:] + (row[0],))
        else:
            cur.execute("""INSERT INTO workspace_setup_state
                (workspace_key, workspace_path, version, bootstrap_seeded_at,
                 setup_completed_at, updated_at) VALUES (?,?,?,?,?,?)""", row)
        conn.commit()
    finally:
        conn.close()
    # Archive legacy files only after a successful commit
    for legacy in legacy_files:
        if os.path.isfile(legacy):
            shutil.move(legacy, os.path.join(backup_dir, os.path.basename(legacy) + "." + os.urandom(3).hex()))
    att_dir = os.path.join(state_dir, "workspace-attestations")
    if os.path.isdir(att_dir):
        for name in os.listdir(att_dir):
            if name.endswith(".attested"):
                shutil.move(os.path.join(att_dir, name), os.path.join(backup_dir, name))
        try:
            os.rmdir(att_dir)
        except OSError:
            pass
print("workspace-state: migrated (backup in " + backup_dir + ")")
PYOCWS
        then
            : # stage 1 done
        else
            migrate_ok=0
            warn_msg "Workspace state migration failed; legacy files kept for manual retry"
        fi
    fi

    if [ "$need2" -eq 1 ] && [ "$migrate_ok" -eq 1 ]; then
        # Stage 2: session store -> agent SQLite (uses the patched archive path)
        if timeout 900 openclaw doctor --session-sqlite import --session-sqlite-all-agents >> "$LOG_FILE" 2>&1; then
            : # import reports details in $LOG_FILE
        else
            warn_msg "Session SQLite import returned non-zero; check ${LOG_FILE}"
        fi
        # Verify the gate is clear
        if compgen -G "$STATE_DIR/sessions/sessions.json" >/dev/null 2>&1 \
            || compgen -G "$STATE_DIR/agents/*/sessions/sessions.json" >/dev/null 2>&1; then
            warn_msg "Legacy sessions.json still present — run 'openclaw doctor --session-sqlite import --session-sqlite-all-agents' manually"
        else
            success_msg "Session store migrated to SQLite"
        fi
    fi

    if [ "$need3" -eq 1 ]; then
        # Stage 3: legacy exec-approvals config -> state DB exec_approvals_config.
        # Without this the gateway's channels crash-loop with
        # "Legacy exec approvals exist ..." until the file is imported+removed.
        local backup_dir3="$STATE_DIR/backup-legacy-state-exec-approvals-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$backup_dir3"
        if python3 - "$STATE_DIR" "$backup_dir3" <<'PYOCEA'
import glob, json, os, shutil, sqlite3, sys, time

state_dir, backup_dir = sys.argv[1], sys.argv[2]
source = os.path.join(state_dir, "exec-approvals.json")

with open(source, encoding="utf-8") as fh:
    doc = json.load(fh)
version = doc.get("version", 1)
defaults = doc.get("defaults") or {}
agents = doc.get("agents") or {}
socket = doc.get("socket") or {}
if not isinstance(defaults, dict) or not isinstance(agents, dict):
    sys.exit("unexpected legacy exec-approvals shape; refusing to migrate")
if version not in (None, 1):
    sys.exit("unsupported legacy exec-approvals version: %r" % (version,))

# Mirrors upstream writeExecApprovalsConfigRow(): raw document plus projection columns
agent_list = list(agents.values())
row = (
    "current",
    json.dumps(doc, indent=2) + "\n",
    socket.get("path"),
    1 if socket.get("token") else 0,
    defaults.get("security"),
    defaults.get("ask"),
    defaults.get("askFallback"),
    None if defaults.get("autoAllowSkills") is None else int(bool(defaults.get("autoAllowSkills"))),
    len(agent_list),
    sum(len(a.get("allowlist") or []) for a in agent_list if isinstance(a, dict)),
    int(time.time() * 1000),
)

db_path = os.path.join(state_dir, "state", "openclaw.sqlite")
conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM exec_approvals_config WHERE config_key = ?", ("current",))
    if cur.fetchone():
        cur.execute(
            "UPDATE exec_approvals_config SET raw_json=?, socket_path=?, has_socket_token=?,"
            " default_security=?, default_ask=?, default_ask_fallback=?, auto_allow_skills=?,"
            " agent_count=?, allowlist_count=?, updated_at_ms=? WHERE config_key=?",
            row[1:] + ("current",),
        )
    else:
        cur.execute(
            "INSERT INTO exec_approvals_config"
            " (config_key, raw_json, socket_path, has_socket_token, default_security,"
            "  default_ask, default_ask_fallback, auto_allow_skills, agent_count,"
            "  allowlist_count, updated_at_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            row,
        )
    conn.commit()
finally:
    conn.close()

# Archive legacy source + claim files only after a successful commit
for legacy in [source] + glob.glob(source + ".doctor-importing*"):
    if os.path.exists(legacy):
        shutil.move(legacy, os.path.join(backup_dir, os.path.basename(legacy) + "." + os.urandom(3).hex()))
print("exec-approvals: migrated to state DB (backup in " + backup_dir + ")")
PYOCEA
        then
            success_msg "Exec approvals migrated to state DB"
        else
            warn_msg "Exec-approvals migration failed; legacy file kept for manual retry"
        fi
    fi

    # Restore gateway
    if [ "$was_running" -eq 1 ]; then
        pm2 restart openclaw >/dev/null 2>&1 || pm2 start openclaw >/dev/null 2>&1 || true
        pm2 save >/dev/null 2>&1 || true
    fi

    if [ "$migrate_ok" -eq 1 ]; then
        success_msg
    else
        warn_msg "OpenClaw state migration incomplete — see log"
    fi
}

# OpenClaw's process-identity helpers (used by the cron durable fence and the
# file-lock manager) guard /proc parsing with `process.platform === "linux"`.
# On Android/Termux process.platform is "android", so getProcessStartTime()
# returns null and cron ticks fail every 2s with "cron run cannot acquire a
# durable fence without process start identity". Accept both platforms.
patch_openclaw_pid_platform() {
    local silent=$1
    [ -n "$OPENCLAW_ROOT" ] && [ -d "$OPENCLAW_ROOT" ] || return 0

    if [[ "$silent" != "silent" ]]; then
        status_msg "Patching OpenClaw process-identity for Android platform"
    fi

    local patched=0

    # worker.mjs (minified runtime; stable file name, minified var names may
    # change between versions — non-fatal if the exact bytes are not found).
    # Single quotes below are intentional: the sed patterns must keep the
    # literal backticks used by upstream's template literals.
    local WM="$OPENCLAW_ROOT/dist/worker/worker.mjs"
    if [ -f "$WM" ]; then
        # shellcheck disable=SC2016
        if grep -q 'process.platform!==`android`' "$WM" 2>/dev/null; then
            : # already patched
        else
            cp "$WM" "${WM}.bak" 2>/dev/null || true
            # shellcheck disable=SC2016
            sed -i 's#function getProcessStartTime(Ot){if(!isValidPid(Ot)||process.platform!==`linux`)return null;#function getProcessStartTime(Ot){if(!isValidPid(Ot)||\(process.platform!==`linux`\&\&process.platform!==`android`\))return null;#; s#function isZombieProcess(Ot){if(process.platform!==`linux`)return!1;#function isZombieProcess(Ot){if(process.platform!==`linux`\&\&process.platform!==`android`)return!1;#' "$WM" 2>/dev/null || true
            # shellcheck disable=SC2016
            if grep -q 'process.platform!==`android`' "$WM" 2>/dev/null; then
                patched=$((patched + 1))
            else
                cp "${WM}.bak" "$WM" 2>/dev/null || true
                if [[ "$silent" != "silent" ]]; then
                    warn_msg "worker.mjs process-identity pattern not matched (upstream changed); cron may tick-fail — re-check patch"
                fi
            fi
        fi
    fi

    # pid-alive-*.js (readable chunk used by the CLI/doctor path; glob hash)
    local PA
    PA=$(find "$OPENCLAW_ROOT/dist" -maxdepth 1 -name 'pid-alive-*.js' -print -quit 2>/dev/null)
    if [ -n "$PA" ] && [ -f "$PA" ] && ! grep -q 'process.platform !== "linux" && process.platform !== "android"' "$PA" 2>/dev/null; then
        cp "$PA" "${PA}.bak" 2>/dev/null || true
        if sed -i 's#if (!isValidPid(pid) || process.platform !== "linux") return null;#if (!isValidPid(pid) || (process.platform !== "linux" \&\& process.platform !== "android")) return null;#; s#if (process.platform !== "linux") return false;#if (process.platform !== "linux" \&\& process.platform !== "android") return false;#' "$PA" 2>/dev/null \
            && grep -q 'process.platform !== "linux" && process.platform !== "android"' "$PA" 2>/dev/null; then
            patched=$((patched + 1))
        else
            cp "${PA}.bak" "$PA" 2>/dev/null || true
        fi
    fi

    if [[ "$silent" != "silent" ]]; then
        if [ "$patched" -gt 0 ]; then
            success_msg "Patched $patched file(s)"
        else
            success_msg "Already patched"
        fi
    fi
}

# PM2's pidusage stats poller warns on every poll on Android:
# /proc/uptime is kernel-blocked (EACCES) for app processes, so pidusage
# falls back to os.uptime() and prints a console.warn per poll — flooding
# `pm2 logs`. pidusage upstream honors PIDUSAGE_SILENT; make the silence
# automatic on the android platform (env-var override still works).
patch_pm2_pidusage() {
    local silent=$1
    command -v pm2 >/dev/null 2>&1 || return 0

    local ROOT
    ROOT=$(npm root -g 2>/dev/null || true)
    [ -n "$ROOT" ] && [ -d "$ROOT/pm2" ] || ROOT="$PREFIX/lib/node_modules"
    [ -d "$ROOT/pm2" ] || return 0

    if [[ "$silent" != "silent" ]]; then
        status_msg "Patching PM2 pidusage stats for Android"
    fi

    local patched=0
    local TARGET
    while IFS= read -r TARGET; do
        [ -f "$TARGET" ] || continue
        if grep -q 'PIDUSAGE_SILENT && process.platform !== "android"' "$TARGET" 2>/dev/null; then
            continue
        fi
        cp "$TARGET" "${TARGET}.bak" 2>/dev/null || true
        if sed -i 's#if (!process\.env\.PIDUSAGE_SILENT) {#if (!process.env.PIDUSAGE_SILENT \u0026\u0026 process.platform !== "android") {#' "$TARGET" 2>/dev/null \
            && grep -q 'PIDUSAGE_SILENT && process.platform !== "android"' "$TARGET" 2>/dev/null; then
            patched=$((patched + 1))
        else
            cp "${TARGET}.bak" "$TARGET" 2>/dev/null || true
        fi
    done < <(find "$ROOT/pm2" -path "*pidusage/lib/helpers/cpu.js" 2>/dev/null)

    if [[ "$silent" != "silent" ]]; then
        if [ "$patched" -gt 0 ]; then
            success_msg "Patched $patched file(s) — run 'pm2 update' to reload the daemon"
        else
            success_msg "Already patched"
        fi
    fi
}

# OpenClaw's workspace bootstrap (onboard/first run) publishes files by
# hardlinking a staging copy into the workspace (fs.linkSync). Android blocks
# hardlinks (EACCES), so onboarding dies with "EACCES: permission denied,
# link ...". Upstream detects the unsupported-hardlink case
# (isHardlinkFallbackError) but deliberately fails instead of degrading —
# patch that branch to publish by copy+unlink instead.
patch_openclaw_workspace_bootstrap() {
    local silent=$1
    [ -n "$OPENCLAW_ROOT" ] && [ -d "$OPENCLAW_ROOT" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    if [[ "$silent" != "silent" ]]; then
        status_msg "Patching OpenClaw workspace bootstrap for Android"
    fi

    local patched=0
    local TARGET
    while IFS= read -r TARGET; do
        [ -f "$TARGET" ] || continue
        grep -q 'fs.linkSync(staging.path, targetPath)' "$TARGET" 2>/dev/null || continue
        grep -q 'droid-ai-toolkit: bootstrap copy fallback' "$TARGET" 2>/dev/null && continue
        cp "$TARGET" "${TARGET}.bak" 2>/dev/null || true
        if python3 - "$TARGET" <<'PYOCBS'
import shutil, sys

path = sys.argv[1]
data = open(path, encoding="utf-8", errors="replace").read()

old = """\t\t\telse if (!linked \u0026\u0026 isHardlinkFallbackError(error)) outcome = {
\t\t\t\tkind: "failed",
\t\t\t\terror: new Error("Workspace filesystem does not support atomic bootstrap publication. Use a workspace on a filesystem with hard-link support.", { cause: error })
\t\t\t};"""
new = """\t\t\telse if (!linked \u0026\u0026 isHardlinkFallbackError(error)) {
\t\t\t\t/* droid-ai-toolkit: bootstrap copy fallback */
\t\t\t\tfs.copyFileSync(staging.path, targetPath);
\t\t\t\tfs.unlinkSync(staging.path);
\t\t\t\tlinked = true;
\t\t\t\toutcome = { kind: "created" };
\t\t\t}"""

count = data.count(old)
if count != 1:
    sys.exit("bootstrap publication pattern not found or not unique (count=%d)" % count)
data = data.replace(old, new)
open(path, "w", encoding="utf-8", errors="replace").write(data)
PYOCBS
        then
            patched=$((patched + 1))
        else
            # Non-fatal: newer OpenClaw may have changed the publication code
            cp "${TARGET}.bak" "$TARGET" 2>/dev/null || true
            if [[ "$silent" != "silent" ]]; then
                warn_msg "workspace bootstrap pattern not matched (upstream changed) — onboarding may fail on Android"
            fi
        fi
    done < <(find "$OPENCLAW_ROOT/dist" -maxdepth 1 -name 'workspace-*.js' 2>/dev/null)

    if [[ "$silent" != "silent" ]]; then
        if [ "$patched" -gt 0 ]; then
            success_msg "Patched $patched file(s)"
        else
            success_msg "Already patched or not applicable"
        fi
    fi
}

# Thin coordinator: invokes all patch modules.
apply_patches() {
    local silent=$1
    patch_koffi "$silent"
    patch_gemini_cli "$silent"
    patch_paperclip "$silent"
    patch_openclaw_tmp "$silent"
    patch_openclaw_registerhooks "$silent"
    patch_openclaw_links "$silent"
    patch_openclaw_sqlite_archive "$silent"
    patch_openclaw_pid_platform "$silent"
    patch_pm2_pidusage "$silent"
    patch_openclaw_workspace_bootstrap "$silent"
}

# --- 5. PI CODING AGENT INSTALLATION ---

install_pi() {
    local mode="full"
    if is_installed "@earendil-works/pi-coding-agent" || is_installed "@mariozechner/pi-coding-agent"; then
        local choice
        choice=$(show_whi_menu "Pi Coding Agent is already installed  |  Use ↑/↓ and Enter" \
            "REPAIR"   "[R]  Repair / Reinstall (regenerate context)" \
            "UPDATE"   "[U]  Update to Latest (full re-install)" \
            ""         "" \
            "BACK"     "<--  BACK TO UTILITIES MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            REPAIR) mode="repair" ;;
            UPDATE) mode="full" ;;
            BACK|*) return 0 ;;
        esac
    else
        confirm_action "Install Pi Coding Agent" || return 0
    fi

    echo -e "\n${BLUE}$([[ "$mode" == "repair" ]] && echo "Repairing" || echo "Setting up") Pi Coding Agent...${NC}"

    # Handle EEXIST conflicts surgically
    if [ -f "$TERMUX_BIN/pi" ]; then
        status_msg "Handling existing 'pi' binary conflict"
        rm -f "$TERMUX_BIN/pi"
        success_msg
    fi

    PKG_MANAGER=$(select_package_manager "pi-coding-agent")

    if [[ "$mode" == "full" ]]; then
        if [ "$PKG_MANAGER" == "npm" ]; then
            execute "npm uninstall -g @mariozechner/pi-coding-agent 2>/dev/null || true; npm install -g @earendil-works/pi-coding-agent@latest" "Installing Pi Coding Agent via npm"
        else
            execute "pnpm remove -g @mariozechner/pi-coding-agent 2>/dev/null || true; pnpm add -g @earendil-works/pi-coding-agent@latest --force --ignore-scripts" "Installing Pi Coding Agent via pnpm"
        fi
    fi

    status_msg "Optimizing Pi environment context"
    mkdir -p "$HOME/.pi/agent"
    cat <<EOF > "$HOME/.pi/agent/AGENTS.md"
# Agent Environment: Termux on Android

## Location
- **OS**: Android (Termux terminal emulator)
- **Home**: $HOME
- **Prefix**: $PREFIX
- **Shared storage**: /storage/emulated/0 (Downloads, Documents, etc.)

## Opening URLs
\`\`\`bash
termux-open-url "https://example.com"
\`\`\`
EOF
    success_msg

    if command -v pi >/dev/null 2>&1; then
        echo -e "\n${GREEN}Pi Coding Agent successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed")!${NC}"
        health_check "Pi Coding Agent" "command -v pi" || true
        echo -e "\n${YELLOW}NEXT STEPS:${NC}"
        echo -e "1. Run interactively: ${BLUE}pi --help${NC}"
    else
        error_msg "Installation finished but 'pi' command not found in PATH."
    fi
    wait_to_continue
}

# --- 6. GEMINI CLI INSTALLATION ---

install_gemini_cli() {
    local mode="full"
    if is_installed "gemini-cli"; then
        local choice
        choice=$(show_whi_menu "Gemini CLI is already installed  |  Use ↑/↓ and Enter" \
            "REPAIR"   "[R]  Repair (re-apply Android patches)" \
            "UPDATE"   "[U]  Update to Latest (full re-install)" \
            ""         "" \
            "BACK"     "<--  BACK TO UTILITIES MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            REPAIR) mode="repair" ;;
            UPDATE) mode="full" ;;
            BACK|*) return 0 ;;
        esac
    else
        confirm_action "Install Gemini CLI" || return 0
    fi

    echo -e "\n${BLUE}Installing Gemini CLI...${NC}"
    smart_pkg_install python make clang pkg-config

    PKG_MANAGER=$(select_package_manager "gemini-cli")
    [[ "$PKG_MANAGER" == "back" ]] && return 0

    if [[ "$mode" == "full" ]]; then
        if [ "$PKG_MANAGER" == "npm" ]; then
            execute "npm install -g @google/gemini-cli@latest" "Installing Gemini CLI via npm"
        else
            execute "pnpm add -g @google/gemini-cli@latest --force --ignore-scripts" "Installing Gemini CLI via pnpm"
        fi
    fi

# Apply patches to prevent ENOENT errors during registry writes
    local gemini_root_paths; gemini_root_paths="$(get_global_node_path)"
    if command -v gemini >/dev/null 2>&1 || [ -d "$gemini_root_paths" ]; then
        status_msg "Patching Gemini CLI for Android"
        IFS=':' read -ra _gemini_roots <<< "$gemini_root_paths"
        for _groot in "${_gemini_roots[@]}"; do
            [ -d "$_groot" ] || continue
            find -L "$_groot" -maxdepth 6 -type f -name 'projectRegistry.js' -exec sed -i 's|await fs.promises.rename(\([^,]*\), \([^)]*\))|await fs.promises.copyFile(\1, \2); await fs.promises.unlink(\1)|g' {} + 2>/dev/null || true
        done
        success_msg

        echo -e "${GREEN}\nGemini CLI successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed")!${NC}"
        health_check "Gemini CLI" "command -v gemini" || true
        echo -e "\n${YELLOW}NEXT STEPS:${NC}"
        echo -e "1. Run interactively: ${BLUE}gemini --help${NC}"
    else
        error_msg "Installation finished but 'gemini' command not found in PATH."
    fi
    wait_to_continue
}

# --- 7. N8N INSTALLATION ---

install_n8n() {
    local mode="full"
    if is_installed "n8n"; then
        local choice
        choice=$(show_whi_menu "n8n is already installed  |  Use ↑/↓ and Enter" \
            "REPAIR"   "[R]  Repair Config/Watchdog (Fast)" \
            "UPDATE"   "[U]  Update to Latest (Full re-install)" \
            ""         "" \
            "BACK"     "<--  BACK TO WORKFLOWS MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            REPAIR) mode="repair" ;;
            UPDATE) mode="full" ;;
            BACK|*) return 0 ;;
        esac
    else
        confirm_action "Install n8n Server" || return 0
    fi

    begin_install
    echo -e "\n${BLUE} $([[ "$mode" == "repair" ]] && echo "Repairing" || echo "Setting up") n8n Android Infrastructure...${NC}"
    prepare_for_install "n8n" "openclaw"

    if [[ "$mode" == "full" ]]; then
        smart_pkg_install nodejs-lts python3 autossh tmux cronie
        
    ensure_nodejs_links
    fi

    PKG_MANAGER=$(select_package_manager "n8n")
    [[ "$PKG_MANAGER" == "back" ]] && return 0

    if [[ "$mode" == "full" ]]; then
        local n8n_root=""
        if [ "$PKG_MANAGER" == "pnpm" ]; then
            n8n_root="$(pnpm_root_g)/n8n"
        else
            n8n_root="$(npm root -g 2>/dev/null)/n8n"
        fi
        
        status_msg "Preparing clean slate"
        rm -rf "$n8n_root"
        success_msg

        if [ "$PKG_MANAGER" == "npm" ]; then
            execute "npm install -g n8n@latest" "Installing n8n globally via npm"
        else
            execute "pnpm add -g n8n@latest --force --ignore-scripts" "Installing n8n globally via pnpm"
        fi
    fi

    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    SAFE_LIMIT=$(get_mem_limit)
    
    echo -e "\n${YELLOW} MEMORY ALLOCATION:${NC}"
    echo -e "Detected Total RAM: ${BLUE}${TOTAL_RAM}MB${NC}"
    echo -e "Applying Safe Limit: ${GREEN}${SAFE_LIMIT}MB${NC}"
    
    status_msg "Creating directories"
    mkdir -p "$HOME/n8n_server/config" "$HOME/n8n_server/scripts" "$HOME/n8n_server/python" "$HOME/.termux/boot"
    success_msg

    if [[ "$mode" == "full" ]] || [ ! -f "$HOME/n8n_server/config/n8n.env" ]; then
        status_msg "Creating n8n configuration"
        cat <<EOF > "$HOME/n8n_server/config/n8n.env"
N8N_RUNNERS_MODE=internal
N8N_RUNNERS_AUTH_TOKEN="$(openssl rand -hex 32)"
N8N_RUNNERS_BROKER_LISTEN_ADDRESS=127.0.0.1
N8N_PYTHON_BINARY=$PREFIX/bin/python3
N8N_NATIVE_PYTHON_RUNNER=false
N8N_BLOCK_COMMAND_EXECUTION=false
N8N_NODES_INCLUDE='["n8n-nodes-base.executeCommand","n8n-nodes-base.manualTrigger"]'
NODE_OPTIONS="--max-old-space-size=$SAFE_LIMIT"
N8N_PROTOCOL=http
N8N_HOST=localhost
EOF
        success_msg
    fi

    if [[ "$mode" == "full" ]] || [ ! -f "$HOME/n8n_server/scripts/n8n-monitor.sh" ]; then
        status_msg "Creating monitoring script"
        cat <<'EOF' > "$HOME/n8n_server/scripts/n8n-monitor.sh"
#!/bin/bash
N8N_SESSION="n8n_server"
TUNNEL_SESSION="n8n_tunnel"
ENV_FILE=~/n8n_server/config/n8n.env
LOG_FILE=~/n8n_monitor.log

N8N_START="set -a; source $ENV_FILE; set +a; n8n start"

if ! pgrep -f "n8n start" > /dev/null; then
    echo "[$(date)]  n8n not found. Restarting..." >> "$LOG_FILE"
    tmux kill-session -t "$N8N_SESSION" 2>/dev/null
    tmux new-session -d -s "$N8N_SESSION" "$N8N_START"
fi

if [ -f ~/n8n_server/config/tunnel.conf ]; then
    source ~/n8n_server/config/tunnel.conf
    if ! pgrep -f "autossh.*-R 5678:localhost:5678" > /dev/null; then
        echo "[$(date)] [TUNNEL] Tunnel not found. Re-establishing..." >> "$LOG_FILE"
        tmux kill-session -t "$TUNNEL_SESSION" 2>/dev/null
        tmux new-session -d -s "$TUNNEL_SESSION" "$TUNNEL_CMD"
    fi
fi
EOF
        chmod +x "$HOME/n8n_server/scripts/n8n-monitor.sh"
        success_msg
    fi

    echo -e "\n${GREEN} n8n successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed")!${NC}"
    health_check "n8n" "command -v n8n" || true
    echo -e "\n${YELLOW}  NEXT STEPS:${NC}"
    echo -e "1. Select ${BLUE}SERVICES${NC} -> ${BLUE}PM2${NC} (Recommended) or ${BLUE}Native Services${NC} to configure background services."
    wait_to_continue
}

# --- 7.1. GCP BRIDGE SETUP ---

setup_n8n_gcp() {
    confirm_action "Configure GCP Bridge" || return 0
    echo -e "\n${BLUE}[GCP] GCP BRIDGE (SSH TUNNEL) CONFIGURATION${NC}"

    local valid_ip=0
    while [ $valid_ip -eq 0 ]; do
        read -p "Enter your GCP VM IP (e.g., 35.192.123.45): " GCP_IP
        if [[ "$GCP_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            local oct1 oct2 oct3 oct4
            IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$GCP_IP"
            # Strip leading zeros to prevent octal interpretation in bash
            oct1=${oct1#0}; oct2=${oct2#0}; oct3=${oct3#0}; oct4=${oct4#0}
            # Use pattern matching to avoid octal issues
            if [[ "$oct1" =~ ^[0-9]+$ ]] && [[ "$oct2" =~ ^[0-9]+$ ]] && [[ "$oct3" =~ ^[0-9]+$ ]] && [[ "$oct4" =~ ^[0-9]+$ ]]; then
                if [ "$oct1" -le 255 ] && [ "$oct2" -le 255 ] && [ "$oct3" -le 255 ] && [ "$oct4" -le 255 ]; then
                    valid_ip=1
                else
                    error_msg "Invalid IP address octets"
                fi
            else
                error_msg "Invalid IP address octets"
            fi
        else
            error_msg "Invalid IP format (use x.x.x.x)"
        fi
    done

    local valid_user=0
    while [ $valid_user -eq 0 ]; do
        read -p "Enter your GCP VM Username (e.g., n8n_admin): " GCP_USER
        if [[ "$GCP_USER" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
            valid_user=1
        else
            error_msg "Invalid username (alphanumeric, dash, underscore only)"
        fi
    done

    status_msg "Creating tunnel configuration"
    cat <<EOF > "$HOME/n8n_server/config/tunnel.conf"
TUNNEL_CMD="autossh -M 0 -o 'ServerAliveInterval 30' -o 'ServerAliveCountMax 3' -o 'StrictHostKeyChecking=no' -i ~/.ssh/gcp_vm -N -R 5678:localhost:5678 ${GCP_USER}@${GCP_IP}"
EOF
    success_msg
    
    echo -e "\n${GREEN}GCP Bridge configured!${NC}"
    echo -e "Ensure your GCP VM firewall allows port 5678 and that you have SSH keys set up."
    echo -e "Test: ${YELLOW}~/n8n_server/scripts/n8n-monitor.sh${NC}"
    wait_to_continue
}

# --- 8. OLLAMA INSTALLATION ---

install_ollama() {
    local mode="install"
    if is_installed "ollama"; then
        local choice
        choice=$(show_whi_menu "Ollama is already installed  |  Use ↑/↓ and Enter" \
            "REINSTALL" "[R]  Reinstall (reset package)" \
            "UPDATE"    "[U]  Update (refresh package list)" \
            ""          "" \
            "BACK"      "<--  BACK TO UTILITIES MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            REINSTALL) mode="reinstall" ;;
            UPDATE) mode="update" ;;
            BACK|*) return 0 ;;
        esac
    else
        confirm_action "Install Ollama" || return 0
    fi

    echo -e "\n${BLUE}${mode^}ing Ollama...${NC}"
    
    smart_pkg_install ollama

    if command -v ollama >/dev/null 2>&1; then
        echo -e "\n${GREEN}Ollama successfully installed!${NC}"
        health_check "Ollama" "command -v ollama" || true
        echo -e "\n${YELLOW}NEXT STEPS:${NC}"
        echo -e "1. Start server: ${BLUE}ollama serve${NC}"
        echo -e "   Or start background service via ${BLUE}SERVICES${NC} -> ${BLUE}PM2${NC} menu."
        echo -e "2. Pull a model: ${BLUE}ollama pull llama3${NC}"
        echo -e "3. Run a model:  ${BLUE}ollama run llama3${NC}"
    else
        error_msg "Ollama installation failed."
    fi
    wait_to_continue
}

# Architecture guard for armv8l/armv7l (shared by Hermes and Nanobot)
_guard_armv8l() {
    local arch; arch="$(uname -m)"
    if [ "$arch" = "armv8l" ] || [ "$arch" = "armv7l" ]; then
        echo -e "\n${YELLOW}ℹ️  $1 is not supported on ${arch}.${NC}"
        echo -e "   Reason: jiter requires Rust compilation via maturin, which${NC}"
        echo -e "   does not support the ${arch} architecture.${NC}"
        echo -e "   Workaround: Run on a device with aarch64 or x86_64.${NC}"
        wait_to_continue
        return 1
    fi
    return 0
}

# Detect Hermes installation state: returns yes, partial, or no
_detect_hermes_state() {
    local hcmd=""
    hcmd=$(type -P hermes 2>/dev/null || true)
    if [ -n "$hcmd" ] || [ -f "$HOME/.hermes/bin/hermes" ]; then
        echo "yes"
    elif grep -q 'hermes' "$HOME/.bashrc" 2>/dev/null || [ -d "$HOME/.hermes" ]; then
        echo "partial"
    else
        echo "no"
    fi
}

# Export Rust/Cargo environment for low-RAM Termux builds
_setup_rust_env() {
    export CARGO_BUILD_JOBS=1
    export CARGO_NET_GIT_FETCH_WITH_CLI=true
    export RUSTFLAGS="-C opt-level=2"
    local android_api_level=$(getprop ro.build.version.sdk 2>/dev/null || echo "34")
    export ANDROID_API_LEVEL=${android_api_level}
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=clang
    echo "$android_api_level"  # Return for caller reuse
}

# Run the official Termux extra install to pull in all tested Android deps.
# The upstream installer's pip step often silently falls back to a base
# (incomplete) install when .[termux-all] fails. We run .[termux] explicitly
# after every install/update to ensure the venv is complete.
# --- Hermes wheel-cache helpers ---
# Compiling cryptography, pydantic-core, jiter, Pillow, etc. from source
# takes 30–90 min on Android. After a successful install we persist pip's
# built wheels to ~/.hermes/wheel-cache. On future reinstalls the
# PIP_FIND_LINKS env var tells pip to use these prebuilt wheels first,
# skipping compilation entirely.
HERMES_WHEEL_CACHE="$HOME/.hermes/wheel-cache"

_hermes_prepare_wheel_cache() {
    mkdir -p "$HERMES_WHEEL_CACHE"
    local count=0
    count=$(find "$HERMES_WHEEL_CACHE" -maxdepth 1 -name "*.whl" 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        status_msg "Found $count cached wheels — compilation will be skipped for cached packages"
        success_msg
    fi
    export PIP_FIND_LINKS="$HERMES_WHEEL_CACHE"

    # Pip on Android reports compatible tags as linux_aarch64, but wheels built
    # on-device via maturin/setuptools have android_29_arm64_v8a tags. Create
    # symlink aliases with linux_aarch64 tags so pip matches them during
    # --find-links resolution. The .so inside is identical; only the platform tag
    # in the filename differs.
    local w alias_name
    find "$HERMES_WHEEL_CACHE" -maxdepth 1 -name "*-android_*_arm64_v8a.whl" 2>/dev/null | while IFS= read -r w; do
        alias_name=$(basename "$w" | sed 's/-android_[0-9]*_arm64_v8a/-linux_aarch64/')
        [ -e "$HERMES_WHEEL_CACHE/$alias_name" ] || ln -sf "$w" "$HERMES_WHEEL_CACHE/$alias_name" 2>/dev/null || true
    done
}

_hermes_save_wheel_cache() {
    local pip_cache_dir count=0
    mkdir -p "$HERMES_WHEEL_CACHE"
    pip_cache_dir=$(python3 -m pip cache dir 2>/dev/null) || return 0
    if [ -d "$pip_cache_dir/wheels" ]; then
        find "$pip_cache_dir/wheels" -maxdepth 4 -name "*.whl" -mmin -120 -exec cp -n {} "$HERMES_WHEEL_CACHE/" \; 2>/dev/null
    fi
    count=$(find "$HERMES_WHEEL_CACHE" -maxdepth 1 -name "*.whl" 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        status_msg "Saved $count prebuilt wheels to cache for fast future reinstalls"
        success_msg
    fi
}

# Apply the Termux fast-version fix to hermes_cli/main.py.
# Handles both the old (v0.18.x) _try_termux_ultrafast_version() and
# the new (v0.20.0+) _try_ultrafast_version() call site.
# Idempotent — safe to call multiple times.
_hermes_apply_termux_fix() {
    local _src_dir="${1:-$HOME/.hermes/hermes-agent}"
    local _main="$_src_dir/hermes_cli/main.py"
    [ -f "$_main" ] || return 0

    # v0.18.x: if _try_termux_ultrafast_version():
    if grep -q '_try_termux_ultrafast_version' "$_main" 2>/dev/null; then
        sed -i 's/if _try_termux_ultrafast_version():/if False:  # Termux fix (upstream PROJECT_ROOT race)/' "$_main" 2>/dev/null || true
    fi
    # v0.20.0+: if _try_ultrafast_version():  (only the call site, not the def)
    if grep -q '^if _try_ultrafast_version():' "$_main" 2>/dev/null; then
        sed -i 's/^if _try_ultrafast_version():/if False:  # Termux fix (upstream PROJECT_ROOT race)/' "$_main" 2>/dev/null || true
    fi
}

_hermes_ensure_termux_deps() {
    local venv_pip="$HOME/.hermes/hermes-agent/venv/bin/pip"
    local src_dir="$HOME/.hermes/hermes-agent"
    [ -x "$venv_pip" ] || return 0
    [ -d "$src_dir" ] || return 0

    # Defensive: ensure Rust build env is exported for maturin builds.
    # Called from UPDATE mode where _setup_rust_env may not have run.
    if [ -z "${ANDROID_API_LEVEL:-}" ]; then
        local _api_lvl
        _api_lvl=$(getprop ro.build.version.sdk 2>/dev/null || echo "34")
        export ANDROID_API_LEVEL="$_api_lvl"
        export CARGO_BUILD_JOBS=1
        export CARGO_NET_GIT_FETCH_WITH_CLI=true
        export RUSTFLAGS="-C opt-level=2"
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=clang
    fi

    # Ensure wheel cache is visible to pip even if caller didn't run
    # _hermes_prepare_wheel_cache in the same shell context.
    if [ -d "$HERMES_WHEEL_CACHE" ]; then
        export PIP_FIND_LINKS="$HERMES_WHEEL_CACHE"
    fi

    # Ensure venv bin is on PATH so pip build subprocesses can find
    # maturin, pybind11, and other build backends installed in the venv.
    local _venv_bin; _venv_bin="$(dirname "$venv_pip")"
    case ":$PATH:" in
        *:"$_venv_bin":*) ;;
        *) export PATH="$_venv_bin:$PATH" ;;
    esac

    status_msg "Installing Termux-tested dependencies"

    # Pre-install build backends that pip's --no-build-isolation subprocess
    # needs on PATH. maturin (for pydantic-core, jiter, cryptography) and
    # pybind11 (for Pillow) are not guaranteed to be in the venv after a
    # git pull that bumps dependency versions. The wheel cache may have
    # linux_aarch64 wheels that work on Android but pip rejects them at
    # metadata-generation time, forcing a source build.
    "$venv_pip" install maturin pybind11 setuptools-rust \
        --no-build-isolation 2>>"$LOG_FILE" || true

    # Force-reinstall editable metadata first so the version mapping stays
    # in sync with whatever git HEAD now points to (prevents stale v0.18.2
    # .pth files after a version bump).
    local _pip_exit=0
    "$venv_pip" install --force-reinstall --no-deps -e "$src_dir" \
        --no-build-isolation 2>>"$LOG_FILE" || _pip_exit=$?

    if [ "$_pip_exit" -eq 0 ] && [ -f "$src_dir/constraints-termux.txt" ]; then
        "$venv_pip" install -e "${src_dir}[termux]" \
            -c "$src_dir/constraints-termux.txt" \
            --no-build-isolation 2>>"$LOG_FILE" || _pip_exit=$?
    fi

    if [ "$_pip_exit" -eq 0 ]; then
        success_msg
    else
        warn_msg "pip install exited with code $_pip_exit — check $LOG_FILE"
    fi
}

# Hermes requires Python 3.11–3.13. Termux's default 'python' package is now
# 3.14, which fails with 'requires a different Python: 3.14.x not in <3.14,>=3.11'.
# The upstream installer's check_python() only verifies >= 3.11, so 3.14 passes
# then pip explodes. We ensure 'python' resolves to a compatible version before
# the upstream installer runs, and check for python3.11/3.12/3.13 from TUR.
_hermes_ensure_compatible_python() {
    local py_ver="" major minor candidate=""

    # Check current 'python' command
    if command -v python >/dev/null 2>&1; then
        py_ver=$(python --version 2>&1 | awk '{print $2}')
        major=$(echo "$py_ver" | cut -d. -f1)
        minor=$(echo "$py_ver" | cut -d. -f2)

        if [ "$major" -eq 3 ] && [ "$minor" -ge 11 ] && [ "$minor" -le 13 ]; then
            # Compatible version already available
            return 0
        fi
    fi

    # Current python is incompatible or missing. Search for python3.11–3.13.
    for v in 11 12 13; do
        if [ -x "$TERMUX_BIN/python3.$v" ]; then
            candidate="python3.$v"
            break
        fi
    done

    if [ -n "$candidate" ]; then
        status_msg "Python ${py_ver:-missing} is incompatible (Hermes requires 3.11–3.13). Using $candidate"
        ln -sf "$TERMUX_BIN/$candidate" "$TERMUX_BIN/python"
        success_msg
        return 0
    fi

    # No compatible python found — cannot proceed
    echo -e "\n${RED} Python version incompatible${NC}"
    echo -e "${YELLOW}Hermes requires Python 3.11–3.13.${NC}"
    if [ -n "$py_ver" ]; then
        echo -e "  Current: ${RED}Python $py_ver${NC} (too new)"
    else
        echo -e "  Current: ${RED}not installed${NC}"
    fi
    echo -e "\n${BLUE}Install Python 3.11 from the Termux User Repository (TUR):${NC}"
    echo -e "  ${YELLOW}pkg install tur-repo${NC}"
    echo -e "  ${YELLOW}pkg install python3.11${NC}"
    echo -e "\n${BLUE}Then re-run this installer.${NC}"
    return 1
}

# --- 9. HERMES INSTALLATION ---

install_hermes() {
    # Architecture guard
    _guard_armv8l "Hermes Agent" || return 0

    local hermes_exists; hermes_exists=$(_detect_hermes_state)

    local mode="install"
    if [ "$hermes_exists" == "yes" ]; then
        local choice
        choice=$(show_whi_menu "Hermes is already installed  |  Use ↑/↓ and Enter" \
            "UPDATE"     "[U]  Update (preserve data, refresh source)" \
            "REINSTALL"  "[R]  Reinstall (backup & clean slate)" \
            ""           "" \
            "BACK"       "<--  BACK TO AGENTS MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            UPDATE) mode="update" ;;
            REINSTALL) mode="reinstall" ;;
            BACK|*) return 0 ;;
        esac
    elif [ "$hermes_exists" == "partial" ]; then
        local choice
        choice=$(show_whi_menu "Hermes appears broken  |  Use ↑/↓ and Enter" \
            "FIX"        "[F]  Fix / Retry Install (keep data)" \
            "REINSTALL"  "[D]  Deep Clean & Reinstall (backup then wipe)" \
            ""           "" \
            "BACK"       "<--  BACK TO AGENTS MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            FIX) mode="fix" ;;
            REINSTALL) mode="reinstall" ;;
            BACK|*) return 0 ;;
        esac
    else
        confirm_action "Install Hermes Agent" || return 0
    fi

    echo -e "\n${BLUE}${mode^}ing Hermes Agent...${NC}"
    echo -e "${YELLOW}NOTE: Hermes requires compiling Rust dependencies which takes${NC}"
    echo -e "${YELLOW}a significant amount of time. This is normal - please be patient.${NC}"

    # ─── UPDATE MODE ────────────────────────────────────────────────
    # NOTE: We intentionally SKIP upstream 'hermes update' on Termux.
    #
    # Upstream PR #39138 (merged) fixed the update path to use
    # 'termux-all' extras instead of 'all', which avoids pulling
    # untested desktop dependencies. However, the MANAGED-UV BOOTSTRAP
    # issue remains explicitly UNFIXED upstream:
    #   https://github.com/NousResearch/hermes-agent/pull/39138
    #   "Out of scope: the secondary failure (managed-uv bootstrap
    #   compiling uv from source when pip install uv finds no aarch64
    #   wheel) is a separate root cause, left for a follow-up."
    #
    # On Termux, 'hermes update' internally:
    #   1. Downloads a glibc-linked 'uv' binary → fails on bionic libc
    #   2. Falls back to 'pip install uv' → no aarch64 wheel exists
    #   3. Compiles uv from source (100K+ lines of Rust) → OOM / hang
    #   4. uv then rejects Android-built wheels anyway
    #
    # Result: a corrupted venv and a frozen device. Manual git pull
    # + pip install is the only reliable Termux path.
    if [ "$mode" == "update" ]; then
        _hermes_prepare_wheel_cache
        status_msg "Preparing Hermes for update"
        pkill -9 -f hermes 2>/dev/null || true
        # pkill -9 leaves stale lock files behind; Hermes will refuse to start
        # if it sees them. Clean them before any restart.
        rm -f "$HOME/.hermes/gateway.lock" "$HOME/.hermes/gateway.pid" \
              "$HOME/.hermes/gateway_state.json"
        # Also clean the upstream update-incomplete marker from a prior
        # interrupted 'hermes update' — otherwise Hermes enters recovery
        # mode on every startup instead of running normally.
        rm -f "$HOME/.hermes/hermes-agent/.update-incomplete" \
              "$HOME/.hermes/hermes-agent/.update-incomplete.lock"
        success_msg

        # Ensure Rust build env is exported before any pip call that might
        # trigger a source build (maturin needs ANDROID_API_LEVEL on Termux).
        _setup_rust_env >/dev/null

        # Stash the Termux fix patch before pulling, so git pull doesn't
        # fail on the local modification to hermes_cli/main.py. The stash
        # is popped and re-applied after the pull completes.
        local _hermes_src="$HOME/.hermes/hermes-agent"
        local _had_termux_fix=false
        if [ -d "$_hermes_src" ]; then
            if (cd "$_hermes_src" && git diff --quiet hermes_cli/main.py 2>/dev/null); then
                : # clean — nothing to stash
            else
                (cd "$_hermes_src" && git stash push -m "termux-fix-pre-update" \
                    hermes_cli/main.py 2>/dev/null) && _had_termux_fix=true
            fi
        fi

        status_msg "Git pulling latest code"
        (cd "$_hermes_src" && git pull origin main) 2>>"$LOG_FILE" || true
        success_msg

        # Re-apply the Termux fix patch if we stashed it earlier.
        if [ "$_had_termux_fix" = true ] && [ -d "$_hermes_src" ]; then
            (cd "$_hermes_src" && git stash pop 2>/dev/null) || true
            # If pop conflicted (upstream changed the same lines), resolve
            # by re-running the patch logic from the post-install step.
            _hermes_apply_termux_fix "$_hermes_src"
        fi

        _hermes_ensure_termux_deps

        # Smoke test: verify the venv can import the current source tree.
        # If editable metadata is stale (e.g. v0.18.2 .pth pointing to v0.19.0
        # source), this will fail with ImportError and we force-reinstall.
        if ! "$HOME/.hermes/hermes-agent/venv/bin/python" \
             -c "import agent.prompt_builder; import agent.system_prompt" 2>/dev/null; then
            warn_msg "Editable metadata stale — forcing reinstall"
            "$HOME/.hermes/hermes-agent/venv/bin/pip" install \
                --force-reinstall --no-deps -e "$HOME/.hermes/hermes-agent" \
                --no-build-isolation 2>>"$LOG_FILE" || true
        fi

        _hermes_save_wheel_cache

        # Restart PM2 with the correct bash interpreter (the hermes binary
        # is a bash script, not a Node.js script). This ensures the PM2 dump
        # is saved with --interpreter bash for future auto-restarts.
        if command -v pm2 >/dev/null 2>&1; then
            pm2 delete hermes 2>/dev/null || true
            pm2 start "$TERMUX_BIN/hermes" --name hermes --interpreter bash -- gateway 2>/dev/null || true
            pm2 save 2>/dev/null || true
        fi

        # Verify
        local hermes_final_path=""
        hermes_final_path=$(type -P hermes 2>/dev/null || true)
        if [ -n "$hermes_final_path" ] && [ -x "$hermes_final_path" ]; then
            echo -e "\n${GREEN} Hermes successfully updated!${NC}"
            health_check "Hermes" "command -v hermes" || true
        else
            error_msg "Hermes update incomplete — check $LOG_FILE"
        fi
        wait_to_continue
        return 0
    fi

    # ─── INSTALL / REINSTALL / FIX MODES ──────────────────────────
    # Pre-install build dependencies that upstream often fails on
    smart_pkg_install python clang rust make pkg-config libffi openssl binutils

    if [ "$mode" == "reinstall" ]; then
        status_msg "Backing up and removing old Hermes installation"
        pkill -9 -f hermes 2>/dev/null || true
        if [ -d "$HOME/.hermes" ]; then
            local backup_dir="$HOME/.hermes.bak.$(date +%Y%m%d%H%M%S)"
            mv "$HOME/.hermes" "$backup_dir"
            echo -e "${BLUE}Backed up old install to $backup_dir${NC}"
        fi
        sed -i '/\.hermes\/bin/d' "$HOME/.bashrc" 2>/dev/null || true
        success_msg
    elif [ "$mode" == "fix" ]; then
        status_msg "Preparing broken Hermes for repair"
        pkill -9 -f hermes 2>/dev/null || true
        # Clean stale update markers that block startup
        rm -f "$HOME/.hermes/hermes-agent/.update-incomplete" \
              "$HOME/.hermes/hermes-agent/.update-incomplete.lock"
        success_msg
    fi

    local android_api_level; android_api_level=$(_setup_rust_env)

    # Guard against Termux Python 3.14+ before upstream installer runs.
    # The upstream check_python() only verifies >= 3.11, so 3.14 passes
    # then pip fails with 'requires a different Python: 3.14 not in <3.14,>=3.11'.
    _hermes_ensure_compatible_python || { wait_to_continue; return 0; }

    _hermes_prepare_wheel_cache

    # Run upstream installer — stream output so user can see progress
    local hermes_tmp_log; hermes_tmp_log=$(mktemp)
    local hermes_exit=0
    status_msg "Running Hermes upstream installer"
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash 2>&1 | tee "$hermes_tmp_log"
    hermes_exit=${PIPESTATUS[1]}
    cat "$hermes_tmp_log" >> "$LOG_FILE"

    # Upstream may return 0 even when pip fails inside it (maturin/jiter error).
    local hermes_bin=""
    hermes_bin=$(type -P hermes 2>/dev/null || true)
    if [ -z "$hermes_bin" ] && [ -f "$HOME/.hermes/bin/hermes" ]; then
        hermes_bin="$HOME/.hermes/bin/hermes"
    fi

    if [ "$hermes_exit" -eq 0 ] && [ -n "$hermes_bin" ] && [ -x "$hermes_bin" ]; then
        success_msg
    else
        printf "\r${CLEAR_LINE}${YELLOW}  Hermes installer exited with warnings.${NC}\n"
        tail -n 20 "$hermes_tmp_log"
    fi
    rm -f "$hermes_tmp_log"

    # If binary is missing entirely, the upstream installer likely failed early.
    # Try to recover by running the Termux extra install from the partial checkout.
    if [ -z "$hermes_bin" ]; then
        _hermes_ensure_termux_deps
    fi

    # Always run the Termux extra install after upstream finishes.
    # The upstream installer silently falls back to a base install when
    # .[termux-all] fails, leaving the venv incomplete (missing yaml, httpx, etc.).
    _hermes_ensure_termux_deps

    _hermes_save_wheel_cache

    # Verify
    [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null || true

    local hermes_final_path=""
    hermes_final_path=$(type -P hermes 2>/dev/null || true)
    if [ -z "$hermes_final_path" ] && [ -f "$HOME/.hermes/bin/hermes" ]; then
        export PATH="$HOME/.hermes/bin:$PATH"
        hermes_final_path="$HOME/.hermes/bin/hermes"
    fi

    if [ -n "$hermes_final_path" ] && [ -x "$hermes_final_path" ]; then
        echo -e "\n${GREEN} Hermes successfully ${mode}ed!${NC}"
        health_check "Hermes" "command -v hermes" || true
        echo -e "Path: ${BLUE}$hermes_final_path${NC}"
        echo -e "Run:  ${BLUE}hermes${NC}"
    else
        echo -e "\n${YELLOW}  Hermes installation incomplete.${NC}"
        echo -e "${BLUE}Debugging steps:${NC}"
        echo -e "  1. Check upstream errors: ${YELLOW}tail -n 50 $LOG_FILE${NC}"
        echo -e "  2. Manual retry: ${BLUE}cd ~/.hermes/hermes-agent && python -m pip install -e '.[termux]' -c constraints-termux.txt --no-build-isolation${NC}"
        echo -e "  3. Ensure Rust works:      ${YELLOW}rustc --version${NC}"
    fi

    # Patch Hermes Termux fast-version bug via the shared helper.
    _hermes_apply_termux_fix "$HOME/.hermes/hermes-agent"

    wait_to_continue
}

# Restore Hermes from a timestamped backup created during [R] Reinstall.
# Offers cherry-pick (configs only) or full restore, then regenerates wrapper.
restore_hermes_backup() {
    local backups
    backups=$(find "$HOME" -maxdepth 1 -type d -name '.hermes.bak.*' | sort)
    if [ -z "$backups" ]; then
        whiptail_msg "${YELLOW}No Hermes backups found.${NC}\n\nBackups are created automatically when you select [R] Reinstall from the Hermes menu."
        return 0
    fi

    # Build menu items from backups
    local -a items=()
    local backup_dir
    while IFS= read -r backup_dir; do
        [ -n "$backup_dir" ] || continue
        local tag
        tag=$(basename "$backup_dir")
        items+=("$tag" "$tag")
    done <<< "$backups"
    items+=("" "" "CANCEL" "Cancel — do nothing")

    local choice
    choice=$(show_whi_menu "Select Hermes Backup to Restore" "${items[@]}") || return 0
    [ "$choice" = "CANCEL" ] || [ -z "$choice" ] && return 0

    local selected_backup="$HOME/.hermes.bak.${choice#*.hermes.bak.}"
    # Handle case where tag is already just the timestamp part
    [ -d "$selected_backup" ] || selected_backup="$HOME/.hermes.bak.$choice"
    if [ ! -d "$selected_backup" ]; then
        error_msg "Backup directory not found: $selected_backup"
        return 1
    fi

    local mode
    mode=$(show_whi_menu "Restore Mode  |  $choice" \
        "CHERRY" "Cherry-pick configs only (safe — keeps new install)" \
        "FULL"   "${RED}Full restore (replaces ~/.hermes with backup)${NC}" \
        ""       "" \
        "CANCEL" "Cancel") || return 0
    [ "$mode" = "CANCEL" ] || [ -z "$mode" ] && return 0

    if [ "$mode" = "FULL" ]; then
        whiptail_confirm "This will REPLACE your current ~/.hermes with the backup. Continue?" || return 0
        status_msg "Restoring full backup"
        if [ -d "$HOME/.hermes" ]; then
            local safety="$HOME/.hermes.fresh.$(date +%Y%m%d%H%M%S)"
            mv "$HOME/.hermes" "$safety"
            echo -e "${BLUE}Current install moved to $safety${NC}"
        fi
        cp -a "$selected_backup" "$HOME/.hermes"
        success_msg
    else
        status_msg "Cherry-picking config files"
        local copied=0
        for f in config .env token.json credentials settings.json; do
            if [ -e "$selected_backup/$f" ]; then
                cp -a "$selected_backup/$f" "$HOME/.hermes/" 2>/dev/null && copied=$((copied + 1))
            fi
        done
        success_msg
        echo -e "${GREEN}Restored $copied config item(s).${NC}"
    fi

    # Always regenerate wrapper with venv Python fix
    status_msg "Regenerating Hermes wrapper"
    local _script="$HOME/.hermes/hermes-agent/hermes"
    local _venv_py="$HOME/.hermes/hermes-agent/venv/bin/python3"
    if [ -f "$_script" ]; then
        if [ -x "$_venv_py" ]; then
            cat > "$TERMUX_BIN/hermes" <<EOF
#!/usr/bin/env bash
unset PYTHONPATH
unset PYTHONHOME
exec "$_venv_py" "$_script" "\$@"
EOF
        else
            cat > "$TERMUX_BIN/hermes" <<EOF
#!/usr/bin/env bash
unset PYTHONPATH
unset PYTHONHOME
[ -f "$HOME/.bashrc" ] \&\& source "$HOME/.bashrc" 2>/dev/null || true
exec "$_script" "\$@"
EOF
        fi
        chmod +x "$TERMUX_BIN/hermes"
        success_msg
    else
        warn_msg "Hermes script not found after restore"
    fi

    # Restart PM2 if running
    if pgrep -f "pm2.*hermes" >/dev/null 2>&1; then
        status_msg "Restarting Hermes in PM2"
        pm2 delete hermes 2>/dev/null || true
        pm2 start "$TERMUX_BIN/hermes" --name hermes --interpreter bash -- gateway
        pm2 save
        success_msg
    fi

    whiptail_msg "${GREEN}Hermes backup restored!${NC}\n\nBackup folder still at:\n${BLUE}$selected_backup${NC}\n\nDelete it when satisfied."
}

# --- 9.1. NANOBOT INSTALLATION ---

install_nanobot() {
    # Architecture guard: armv8l/armv7l cannot build or load jiter (glibc wheels,
    # maturin rejects armv8l). Nanobot depends on anthropic → jiter.
    local arch; arch="$(uname -m)"
    if [ "$arch" = "armv8l" ] || [ "$arch" = "armv7l" ]; then
        echo -e "\n${YELLOW}ℹ️  Nanobot AI is not supported on ${arch}.${NC}"
        echo -e "   Reason: jiter (a dependency of anthropic/nanobot) requires ${NC}"
        echo -e "   Rust compilation via maturin, which does not support the ${NC}"
        echo -e "   ${arch} architecture in upstream wheels.${NC}"
        echo -e "   Workaround: Run Nanobot on a device with aarch64 or x86_64.${NC}"
        wait_to_continue
        return 0
    fi

    local nb_cmd=""
    nb_cmd=$(type -P nanobot 2>/dev/null || true)
    local mode="install"

    if [ -n "$nb_cmd" ]; then
        local choice
        choice=$(show_whi_menu "Nanobot AI is already installed  |  Use ↑/↓ and Enter" \
            "REINSTALL" "[R]  Reinstall (clean slate)" \
            "UPDATE"    "[U]  Update (refresh package)" \
            ""          "" \
            "BACK"      "<--  BACK TO AGENTS MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            REINSTALL) mode="reinstall" ;;
            UPDATE) mode="update" ;;
            BACK|*) return 0 ;;
        esac
    else
        confirm_action "Install Nanobot AI" || return 0
    fi

    echo -e "\n${BLUE}${mode^}ing Nanobot AI...${NC}"
    smart_pkg_install python python-pip

    # Python on Termux does not ship setuptools by default; --no-build-isolation
    # requires it in the host environment. Install via pip, not apt.
    pip3 install setuptools wheel --quiet 2>>"$LOG_FILE" || true

    # Ensure jiter is pre-installed on armv8l/armv7l before any Anthropic-dependent package
    ensure_jiter_armv8l $(command -v pip3 || command -v pip || echo "python3 -m pip")

    if [ "$mode" == "reinstall" ]; then
        status_msg "Removing old Nanobot AI installation"
        pip3 uninstall -y nanobot-ai 2>/dev/null || true
        rm -rf "$HOME/.nanobot" 2>/dev/null || true
        success_msg
    fi

    status_msg "Installing nanobot-ai via pip"
    local mem_limit; mem_limit=$(get_mem_limit)
    # jiter is already extracted into site-packages above so --no-build-isolation
    # prevents pip from trying to compile it in its own isolated environment.
    if ! RUSTFLAGS="-C opt-level=2" CARGO_BUILD_JOBS=1 pip3 install nanobot-ai --no-build-isolation --no-cache-dir >> "$LOG_FILE" 2>&1; then
        warn_msg "pip install failed for nanobot-ai; see ${LOG_FILE}"
    fi
    success_msg

    # Verify
    if command -v nanobot >/dev/null 2>&1; then
        echo -e "\n${GREEN}Nanobot AI successfully ${mode}ed!${NC}"
        health_check "Nanobot" "command -v nanobot" || true
        echo -e "\n${YELLOW}NEXT STEPS:${NC}"
        echo -e "1. Run interactively: ${BLUE}nanobot --help${NC}"
        echo -e "2. Or start background service via ${BLUE}SERVICES${NC} -> ${BLUE}PM2${NC} menu."
    else
        echo -e "\n${YELLOW}Nanobot AI installation may be incomplete.${NC}"
    fi

    wait_to_continue
}

# --- 10. PAPERCLIP INSTALLATION (EXPERIMENTAL) ---
install_paperclip() {
    local mode="install"
    if [ -f "$HOME/paperclip/server/dist/index.js" ]; then
        local choice
        choice=$(show_whi_menu "Paperclip is already installed  |  Use ↑/↓ and Enter" \
            "REPAIR"  "[R]  Repair (restart & re-apply patches)" \
            "UPDATE"  "[U]  Update (preserve configs, re-install)" \
            ""        "" \
            "BACK"    "<--  BACK TO WORKFLOWS MENU") || return 0
        case "$choice" in
            "") return 0 ;;
            REPAIR) mode="repair" ;;
            UPDATE) mode="update" ;;
            BACK|*) return 0 ;;
        esac
    else
        confirm_action "Install Paperclip (EXPERIMENTAL, ~2GB RAM required)" || return 0
    fi

    if [ "$mode" == "repair" ]; then
        echo -e "\n${BLUE}Repairing Paperclip...${NC}"
        status_msg "Re-applying Android patches"
        apply_patches
        success_msg

        status_msg "Checking PostgreSQL"
        if ! safe_timeout 3 psql -d postgres -c "SELECT 1" >/dev/null 2>&1; then
            local stale_pid; stale_pid=$(pgrep -f "postgres -D $PREFIX/var/lib/postgresql" 2>/dev/null || true)
            if [ -n "$stale_pid" ]; then
                kill "$stale_pid" 2>/dev/null || true; sleep 1
            fi
            rm -f "$PREFIX/var/lib/postgresql/postmaster.pid" "$PREFIX/tmp/.s.PGSQL.5432"* 2>/dev/null || true
            pg_ctl -D "$PREFIX/var/lib/postgresql" start -l "$HOME/paperclip/postgres.log" >/dev/null 2>&1 || true
            sleep 2
        fi
        success_msg

        status_msg "Restarting Paperclip in PM2"
        pm2 delete paperclip 2>/dev/null || true
        pkill -f "paperclipai" 2>/dev/null || true
        sleep 1
        cd "$HOME/paperclip" || { error_msg "Cannot cd to ~/paperclip"; return 1; }
        DATABASE_URL='postgres://paperclip:paperclip@localhost:5432/paperclip' NODE_ENV='production' NODE_OPTIONS='--max-old-space-size=1024' PAPERCLIP_MIGRATION_AUTO_APPLY='true' PAPERCLIP_HOME="$HOME/paperclip" pm2 start npm --name paperclip --interpreter none -- run paperclipai -- run && pm2 save
        success_msg

        echo -e "\n${GREEN}Paperclip repaired and restarted!${NC}"
        echo -e "   ${BLUE}pm2 logs paperclip${NC} to view logs."
        wait_to_continue
        return 0
    fi

    # Paperclip installation is delegated entirely to the standalone
    # paperclip_manual_install.sh, which handles: clone, pre-install patches,
    # LMK-resilient pnpm install, prebuilt tarball download, symlink repair,
    # PostgreSQL bootstrap, secret generation, and PM2 ecosystem creation.
    #
    # We search multiple locations for the script (local repo checkout,
    # standalone download, or GitHub raw URL), then execute it.
    local SCRIPT=""
    local CANDIDATES=(
        "$HOME/droid-ai-toolkit/paperclip_manual_install.sh"
        "$HOME/paperclip_manual_install.sh"
        "$HOME/droid-ai-toolkit-main/paperclip_manual_install.sh"
        "$HOME/droid-ai-toolkit/assets/paperclip_manual_install.sh"
    )

    for candidate in "${CANDIDATES[@]}"; do
        if [ -f "$candidate" ]; then
            SCRIPT="$candidate"
            break
        fi
    done

    if [ -z "$SCRIPT" ]; then
        status_msg "Downloading Paperclip standalone installer"
        SCRIPT="$HOME/paperclip_manual_install.sh"
        # Use 'main' branch URL (always available) instead of v${VERSION} tag
        # which may not exist yet at release time.
        if ! curl -fsSL "https://raw.githubusercontent.com/niyazmft/droid-ai-toolkit/main/paperclip_manual_install.sh" -o "$SCRIPT" 2>>"$LOG_FILE"; then
            error_msg "Failed to download paperclip_manual_install.sh"
            echo -e "${YELLOW}Workaround: Manually download the script from:${NC}"
            echo -e "${BLUE}https://raw.githubusercontent.com/niyazmft/droid-ai-toolkit/main/paperclip_manual_install.sh${NC}"
            echo -e "Save it to ${BLUE}~/paperclip_manual_install.sh${NC}, then re-run the toolkit."
            wait_to_continue
            return 1
        fi
        success_msg
    fi

    # Update mode: backup user configs before standalone script wipes them
    if [ "$mode" == "update" ]; then
        local pc_backup="$HOME/.paperclip_backup_$(date +%Y%m%d%H%M%S)"
        mkdir -p "$pc_backup"
        [ -d "$HOME/paperclip/instances/default" ] && cp -r "$HOME/paperclip/instances/default" "$pc_backup/" 2>/dev/null || true
        [ -d "$HOME/paperclip/config" ] && cp -r "$HOME/paperclip/config" "$pc_backup/" 2>/dev/null || true
        [ -f "$HOME/paperclip/ecosystem.config.cjs" ] && cp "$HOME/paperclip/ecosystem.config.cjs" "$pc_backup/" 2>/dev/null || true
        echo -e "${BLUE}Backed up Paperclip configs to $pc_backup${NC}"
    fi

    status_msg "Delegating to standalone Paperclip installer"
    echo -e "${BLUE}   Script: $SCRIPT${NC}"
    success_msg

    bash "$SCRIPT"
    local pc_exit=$?

    # Update mode: restore backed-up configs after standalone script finishes
    if [ "$mode" == "update" ] && [ "$pc_exit" -eq 0 ] && [ -d "$pc_backup" ]; then
        status_msg "Restoring Paperclip user configs"
        [ -d "$pc_backup/default" ] && cp -r "$pc_backup/default" "$HOME/paperclip/instances/" 2>/dev/null || true
        [ -d "$pc_backup/config" ] && cp -r "$pc_backup/config" "$HOME/paperclip/" 2>/dev/null || true
        [ -f "$pc_backup/ecosystem.config.cjs" ] && cp "$pc_backup/ecosystem.config.cjs" "$HOME/paperclip/" 2>/dev/null || true
        rm -rf "$pc_backup"
        success_msg
        echo -e "${GREEN}Paperclip updated! User configs and database preserved.${NC}"
    fi

    return $pc_exit
}

# --- 11. SERVICE MANAGEMENT ---

manage_service() {
    while true; do
        local choice
        choice=$(show_whi_menu "Native Background Services  |  Use ↑/↓ to navigate, Enter to select" \
            "OPENCLAW-SETUP"   "[+]  OpenClaw   — Enable/Setup Service" \
            "OPENCLAW-REMOVE"  "[-]  OpenClaw   — Disable/Remove Service" \
            "N8N-SETUP"        "[+]  n8n        — Enable/Setup Native Service" \
            "N8N-REMOVE"       "[-]  n8n        — Disable/Remove Native Service" \
            ""                 "" \
            "BACK"             "<--  BACK TO SERVICES MENU") || return
        case "$choice" in
            "") continue ;;
            OPENCLAW-SETUP)  whiptail_confirm "Set up OpenClaw background service?" && { setup_service_files; whiptail_msg "OpenClaw service configured."; } ;;
            OPENCLAW-REMOVE) whiptail_confirm "Remove OpenClaw background service?" && { remove_service_files; whiptail_msg "OpenClaw service removed."; } ;;
            N8N-SETUP)       whiptail_confirm "Set up n8n background service?" && { setup_n8n_service_files; whiptail_msg "n8n service configured."; } ;;
            N8N-REMOVE)      whiptail_confirm "Remove n8n background service?" && { remove_n8n_service_files; whiptail_msg "n8n service removed."; } ;;
            BACK|*)           return ;;
        esac
    done
}

setup_service_files() {
    if [ ! -f "$TERMUX_BIN/openclaw" ]; then error_msg "OpenClaw is not installed."; return; fi
    local SAFE_LIMIT=$(get_mem_limit)
    status_msg "Creating OpenClaw service files"
    mkdir -p "$SERVICE_DIR/log" "$HOME/.openclaw/logs"

cat <<EOF > "$SERVICE_DIR/run"
#!/bin/bash
termux-wake-lock
TERMUX_BIN='${TERMUX_BIN}'
HOME='${HOME}'
export PATH="\$TERMUX_BIN:\$HOME/.local/share/pnpm:\$PATH"
export npm_execpath="\$TERMUX_BIN/npm"
export NODE_OPTIONS="--dns-result-order=ipv4first --max-old-space-size=${SAFE_LIMIT}"
export OPENCLAW_TMP="\$HOME/.openclaw/tmp"
PNPM_NODE_PATH=""
if command -v pnpm >/dev/null 2>&1; then
    PNPM_NODE_PATH="\$(pnpm root -g 2>/dev/null)"
fi
export NODE_PATH="${PREFIX}/lib/node_modules\${PNPM_NODE_PATH:+:\$PNPM_NODE_PATH}"
rm -f "\$HOME/.openclaw/tmp/openclaw.lock" "\$PREFIX/var/run/crond.pid"
pkill -9 -f "openclaw gateway run" 2>/dev/null || true
sleep 5
exec openclaw gateway run 2>&1
EOF
    echo -e "#!/bin/bash\nexec svlogd -tt \$HOME/.openclaw/logs" > "$SERVICE_DIR/log/run"
    chmod +x "$SERVICE_DIR/run" "$SERVICE_DIR/log/run"
    success_msg
    echo -e "${GREEN}\nOpenClaw native service configured!${NC} Manage with: sv up/down openclaw"
}

setup_n8n_service_files() {
    if ! command -v n8n >/dev/null 2>&1; then error_msg "n8n is not installed."; return; fi
    status_msg "Creating n8n service files"
    mkdir -p "$N8N_SERVICE_DIR/log" "$HOME/.n8n/logs"

    cat <<EOF > "$N8N_SERVICE_DIR/run"
#!/bin/bash
termux-wake-lock
export TERMUX_BIN='$TERMUX_BIN'
export PATH="\$TERMUX_BIN:\$PATH"
export HOME='$HOME'
[ -f "\$HOME/n8n_server/config/n8n.env" ] && set -a && source "\$HOME/n8n_server/config/n8n.env" && set +a
pkill -9 -f "n8n start" 2>/dev/null || true
sleep 5
exec n8n start 2>&1
EOF
    echo -e "#!/bin/bash\nexec svlogd -tt \$HOME/.n8n/logs" > "$N8N_SERVICE_DIR/log/run"
    chmod +x "$N8N_SERVICE_DIR/run" "$N8N_SERVICE_DIR/log/run"
    success_msg
    echo -e "${GREEN}\nn8n native service configured!${NC} Manage with: sv up/down n8n"
}

remove_service_files() {
    execute "sv down '$SERVICE_DIR' 2>/dev/null || true" "Stopping service"
    execute "rm -rf '$SERVICE_DIR'" "Removing configuration"
}

remove_n8n_service_files() {
    execute "sv down '$N8N_SERVICE_DIR' 2>/dev/null || true" "Stopping n8n service"
    execute "rm -rf '$N8N_SERVICE_DIR'" "Removing n8n service configuration"
}

# Resolve a command path, handling pnpm shim redirection.
# If the command is a pnpm shim, finds the actual JS binary.
_pm2_resolve_bin() {
    local cmd_name="$1"
    local bin_path=""
    bin_path=$(type -P "$cmd_name" 2>/dev/null || true)
    if [[ "$bin_path" == *".local/share/pnpm"* ]]; then
        local pnpm_root
        pnpm_root=$(pnpm_root_g 2>/dev/null)
        [[ -z "$pnpm_root" ]] && pnpm_root="$PREFIX/lib/node_modules"
        echo "$pnpm_root"
    else
        echo "$bin_path"
    fi
}

# Start an app in PM2 with consistent cleanup.
# Usage: _pm2_start_app <name> <binary> [extra_pm2_args...]
_pm2_start_app() {
    local app_name="$1"
    local app_bin="$2"
    shift 2
    pm2 delete "$app_name" 2>/dev/null || true
    local _extra=""
    [ $# -gt 0 ] && _extra=" $*"
    execute "pm2 start '$app_bin' --name '$app_name'$_extra && pm2 save" "Starting $app_name in PM2"
}

manage_pm2() {
    if ! command -v pm2 >/dev/null 2>&1; then
        whiptail_confirm "Install PM2 globally first?" || return 0
        execute "npm install -g pm2" "Installing PM2 Globally"
    fi
    while true; do
        local choice
        choice=$(show_whi_menu "PM2 Management  |  Use ↑/↓ and Enter" \
            "OPENCLAW"  "[+]  Start OpenClaw" \
            "N8N"       "[+]  Start n8n" \
            "HERMES"    "[+]  Start Hermes" \
            "OLLAMA"    "[+]  Start Ollama" \
            "PAPERCLIP" "[+]  Start Paperclip" \
            "NANOBOT"   "[+]  Start Nanobot" \
            ""          "" \
            "LOGS"      "[i]  View Logs (Live)" \
            "STATUS"    "[i]  View Status (Table)" \
            "RESTART"   "[~]  Restart All Apps" \
            "STOP"      "[-]  Stop All Apps" \
            ""          "" \
            "BACK"      "<--  BACK TO SERVICES MENU") || return
        case "$choice" in
            "") continue ;;
            OPENCLAW)
                local openclaw_path; openclaw_path=$(_pm2_resolve_bin "openclaw")
                if [ -n "$openclaw_path" ]; then
                    status_msg "Preparing OpenClaw environment"
                    pm2 stop openclaw 2>/dev/null || true
                    pm2 delete openclaw 2>/dev/null || true
                    rm -f "$HOME/.openclaw/tmp/openclaw.lock"
                    success_msg
                    local PNPM_NODE_PATH; PNPM_NODE_PATH=$(pnpm_root_g || true)
                    local SAFE_LIMIT; SAFE_LIMIT=$(get_mem_limit)
                    local _env="NODE_OPTIONS='--dns-result-order=ipv4first --max-old-space-size=$SAFE_LIMIT' OPENCLAW_TMP='$HOME/.openclaw/tmp' NODE_PATH='$PREFIX/lib/node_modules${PNPM_NODE_PATH:+:$PNPM_NODE_PATH}' npm_execpath='$TERMUX_BIN/npm' PATH='$TERMUX_BIN:\$PATH'"
                    execute "$_env pm2 start '$openclaw_path' --name openclaw --interpreter none -- gateway run && pm2 save" "Starting OpenClaw in PM2"
                else
                    error_msg "OpenClaw is not installed."
                fi
                ;;
            N8N)
                local n8n_path; n8n_path=$(_pm2_resolve_bin "n8n")
                if [ -n "$n8n_path" ]; then
                    local n8n_env=""
                    [ -f "$HOME/n8n_server/config/n8n.env" ] && n8n_env="--env '$HOME/n8n_server/config/n8n.env'"
                    pm2 stop n8n 2>/dev/null || true
                    pm2 delete n8n 2>/dev/null || true
                    execute "pm2 start '$n8n_path' --name n8n --interpreter none $n8n_env && pm2 save" "Starting n8n in PM2"
                else
                    error_msg "n8n is not installed."
                fi
                ;;
            HERMES)
                local hermes_path=""
                hermes_path=$(type -P hermes 2>/dev/null || true)
                if [ -z "$hermes_path" ] && [ -f "$HOME/.hermes/bin/hermes" ]; then
                    hermes_path="$HOME/.hermes/bin/hermes"
                fi
                if [ -n "$hermes_path" ]; then
                    execute "pm2 delete hermes 2>/dev/null || true; pm2 start '$TERMUX_BIN/hermes' --name hermes --interpreter bash -- gateway && pm2 save" "Starting Hermes in PM2"
                else
                    error_msg "Hermes is not installed."
                fi
                ;;
            OLLAMA)
                local ollama_bin=""
                ollama_bin=$(type -P ollama 2>/dev/null || true)
                if [ -n "$ollama_bin" ]; then
                    execute "pm2 delete ollama 2>/dev/null || true; pm2 start '$ollama_bin' --name ollama --interpreter none -- serve && pm2 save" "Starting Ollama in PM2"
                else
                    error_msg "Ollama is not installed."
                fi
                ;;
            PAPERCLIP)
                if [ -f "$HOME/paperclip/server/dist/index.js" ]; then
                    status_msg "Checking PostgreSQL before Paperclip start"
                    if ! safe_timeout 3 psql -d postgres -c "SELECT 1" >/dev/null 2>&1; then
                        STALE_PID=$(pgrep -f "postgres -D $PREFIX/var/lib/postgresql" 2> /dev/null || true)
                        if [ -n "$STALE_PID" ]; then
                            warn_msg "Stale PostgreSQL process detected — stopping it cleanly"
                            kill "$STALE_PID" 2>/dev/null || true
                            sleep 1
                        fi
                        rm -f "$PREFIX/var/lib/postgresql/postmaster.pid" "$PREFIX/tmp/.s.PGSQL.5432"* 2>/dev/null || true
                        pg_ctl -D "$PREFIX/var/lib/postgresql" start -l "$HOME/paperclip/postgres.log" >/dev/null 2>&1 || true
                        sleep 2
                    fi
                    success_msg
                    # Kill any existing Paperclip process
                    pm2 delete paperclip 2>/dev/null || true
                    pkill -f "paperclipai" 2>/dev/null || true
                    sleep 1
                    
                    cd "$HOME/paperclip" || { error_msg "Cannot cd to ~/paperclip"; exit 1; }
                    
                    execute "DATABASE_URL='postgres://paperclip:paperclip@localhost:5432/paperclip' NODE_ENV='production' NODE_OPTIONS='--max-old-space-size=1024' PAPERCLIP_MIGRATION_AUTO_APPLY='true' PAPERCLIP_HOME='$HOME/paperclip' pm2 start npm --name paperclip --interpreter none -- run paperclipai -- run && pm2 save" "Starting Paperclip in PM2"
                else
                    error_msg "Paperclip is not installed."
                fi
                ;;
            NANOBOT)
                local nb_path=""
                nb_path=$(type -P nanobot 2>/dev/null || true)
                if [ -n "$nb_path" ]; then
                    execute "pm2 delete nanobot 2>/dev/null || true; pm2 start '$nb_path' --name nanobot && pm2 save" "Starting Nanobot in PM2"
                else
                    error_msg "Nanobot is not installed."
                fi
                ;;
            LOGS)    pm2 logs ;;
            STATUS)  pm2 status; ;;
            RESTART) execute "pm2 restart all && pm2 save" "Restarting all running PM2 processes" ;;
            STOP)    execute "pm2 stop all && pm2 save" "Stopping all PM2 apps (Daemon remains active)" ;;
            BACK|*)  return ;;
        esac
    done
}

# --- 12. UNINSTALLATION LOGIC ---

uninstall_openclaw() {
    local force_deep=$1
    echo -e "${YELLOW}Cleaning up OpenClaw...${NC}"
    
    # Stop processes
    remove_service_files
    pkill -9 -f "openclaw" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 delete openclaw >> "$LOG_FILE" 2>&1 || true
    
    local pm=$(detect_package_manager "openclaw")
    if [ "$pm" == "pnpm" ]; then
        execute "pnpm remove -g openclaw 2>/dev/null || true" "Uninstalling OpenClaw via pnpm"
    else
        execute "npm uninstall -g openclaw 2>/dev/null || true" "Uninstalling OpenClaw via npm"
    fi

    local choice="1"
    if [[ "$force_deep" != "--deep" ]]; then
        choice=$(show_whi_menu "OpenClaw Data Preservation  |  Select with ↑/↓ and Enter" \
            "SOFT" "Keep plugins, memories, and configuration" \
            "DEEP" "${RED}Wipe everything (irreversible)${NC}" \
            ""      "" \
            "BACK"  "Cancel uninstall") || return 0
        case "$choice" in
            "") return 0 ;;
            SOFT) choice="1" ;;
            DEEP) choice="2" ;;
            BACK|*) return 0 ;;
        esac
    else
        choice="2"
    fi

    if [ "$choice" == "2" ]; then
        execute "rm -rf '$HOME/.openclaw'" "Wiping user data"
    else
        execute "rm -f '$HOME/.openclaw/openclaw.json'" "Removing configuration only"
    fi
    set_config "pm_openclaw" "null"
}

uninstall_gemini() {
    echo -e "${YELLOW}Cleaning up Gemini CLI...${NC}"
    local pm=$(detect_package_manager "gemini-cli")
    if [ "$pm" == "pnpm" ]; then
        execute "pnpm remove -g @google/gemini-cli 2>/dev/null || true" "Uninstalling Gemini CLI via pnpm"
    else
        execute "npm uninstall -g @google/gemini-cli 2>/dev/null || true" "Uninstalling Gemini CLI via npm"
    fi
    set_config "pm_gemini-cli" "null"
}

uninstall_n8n() {
    echo -e "${YELLOW}Cleaning up n8n and GCP Tunnel...${NC}"

    # Stop processes (Surgically target n8n tunnel only)
    remove_n8n_service_files
    pkill -9 -f "n8n" 2>/dev/null || true
    pkill -9 -f "autossh.*-R 5678:localhost:5678" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 delete n8n >> "$LOG_FILE" 2>&1 || true
    
    local pm=$(detect_package_manager "n8n")
    if [ "$pm" == "pnpm" ]; then
        execute "pnpm remove -g n8n 2>/dev/null || true" "Uninstalling n8n via pnpm"
    else
        execute "npm uninstall -g n8n 2>/dev/null || true" "Uninstalling n8n via npm"
    fi
    set_config "pm_n8n" "null"
    rm -rf "$HOME/n8n_server" "$HOME/.n8n"
}

full_cleanup() {
    uninstall_openclaw "--deep"
    uninstall_n8n
    uninstall_gemini
    uninstall_hermes
    uninstall_ollama
    uninstall_pi
    uninstall_paperclip "--deep"
    uninstall_nanobot
    echo -e "\n${GREEN} Toolkit software removed. System dependencies were kept intact.${NC}"
}

uninstall_ollama() {
    echo -e "${YELLOW}Cleaning up Ollama...${NC}"
    command -v pm2 >/dev/null 2>&1 && pm2 delete ollama >> "$LOG_FILE" 2>&1 || true
    pkill -9 -f "ollama" 2>/dev/null || true
    if dpkg -s ollama >/dev/null 2>&1; then
        execute "pkg uninstall -y ollama" "Uninstalling Ollama package"
    else
        echo -e "${YELLOW}Ollama package not installed via pkg — skipping pkg removal.${NC}"
        command -v ollama >/dev/null 2>&1 && echo -e "${RED}Ollama binary still found in PATH. It may have been installed outside pkg — remove it manually.${NC}" || true
    fi
    echo -e "${BLUE}Note:${NC} Downloaded models in ~/.ollama are preserved. Remove manually if desired."
}

uninstall_hermes() {
    echo -e "${YELLOW}Cleaning up Hermes...${NC}"
    pkill -9 -f "hermes" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 delete hermes >> "$LOG_FILE" 2>&1 || true
    if [ -f "$HOME/.hermes/uninstall.sh" ]; then
        execute "bash '$HOME/.hermes/uninstall.sh'" "Running Hermes uninstaller"
    else
        rm -rf "$HOME/.hermes" "$HOME/.local/bin/hermes" 2>/dev/null || true
        echo -e "${YELLOW}Hermes directories removed. Check ~/.bashrc for stale PATH entries.${NC}"
    fi
}

uninstall_nanobot() {
    echo -e "${YELLOW}Cleaning up Nanobot AI...${NC}"
    pkill -9 -f "nanobot" 2>/dev/null || true
    local pm=$(command -v pip3 || command -v pip || true)
    if [ -n "$pm" ]; then
        "$pm" uninstall -y nanobot-ai 2>/dev/null || true
    fi
    rm -rf "$HOME/.nanobot" 2>/dev/null || true
    echo -e "${YELLOW}Nanobot AI removed.${NC}"
}

uninstall_pi() {
    echo -e "${YELLOW}Cleaning up Pi Coding Agent...${NC}"
    pkill -9 -f "pi-coding-agent" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 delete pi >> "$LOG_FILE" 2>&1 || true
    local pm=$(detect_package_manager "@earendil-works/pi-coding-agent")
    [ "$pm" == "none" ] && pm=$(detect_package_manager "@mariozechner/pi-coding-agent")
    if [ "$pm" == "pnpm" ]; then
        execute "pnpm remove -g @earendil-works/pi-coding-agent @mariozechner/pi-coding-agent 2>/dev/null || true" "Uninstalling Pi via pnpm"
    else
        execute "npm uninstall -g @earendil-works/pi-coding-agent @mariozechner/pi-coding-agent 2>/dev/null || true" "Uninstalling Pi via npm"
    fi
    set_config "pm_pi" "null"
    rm -rf "$HOME/.pi" 2>/dev/null || true
    echo -e "${YELLOW}Pi Coding Agent removed.${NC}"
}

uninstall_paperclip() {
    local force_deep=$1
    echo -e "${YELLOW}Cleaning up Paperclip...${NC}"
    # Stop processes
    execute "sv down '$PAPERCLIP_SERVICE_DIR' 2>/dev/null || true" "Stopping Paperclip service"
    pkill -9 -f "node.*server/dist/index.js" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 delete paperclip >> "$LOG_FILE" 2>&1 || true
    # Note: PostgreSQL is a shared system service — we do NOT stop it.
    # Other tools or user data may depend on it.

    # Warn if a stale ghost postgres process is present (no postmaster.pid but port held).
    # This won't block uninstall, but the install script will clean it on next install.
    STALE_PG=$(pgrep -f "postgres -D $PREFIX/var/lib/postgresql" 2>/dev/null || true)
    if [ -n "$STALE_PG" ]; then
        warn_msg "Stale PostgreSQL process detected (PID $STALE_PG) — it will be cleaned automatically on next Paperclip install"
    fi

    local choice="1"
    if [[ "$force_deep" != "--deep" ]]; then
        choice=$(show_whi_menu "Paperclip Data Preservation  |  Select with ↑/↓ and Enter" \
            "SOFT" "Keep source code + PostgreSQL database" \
            "DEEP" "${RED}Wipe source code, PM2 state, and optionally database${NC}" \
            ""      "" \
            "BACK"  "Cancel uninstall") || return 0
        case "$choice" in
            "") return 0 ;;
            SOFT) choice="1" ;;
            DEEP) choice="2" ;;
            BACK|*) return 0 ;;
        esac
    else
        choice="2"
    fi

    if [ "$choice" == "2" ]; then
        execute "rm -f '$HOME/paperclip/ecosystem.config.cjs'" "Removing PM2 ecosystem file"
        execute "rm -rf '$HOME/paperclip'" "Removing Paperclip source code"
        execute "rm -rf '$HOME/.pm2'" "Clearing PM2 state (all saved processes)"

        # In --deep (full wipe) mode, auto-drop database without prompting.
        # In interactive mode, ask user.
        local db_choice="1"
        if [[ "$force_deep" != "--deep" ]]; then
            db_choice=$(show_whi_menu "PostgreSQL Database  |  Select with ↑/↓ and Enter" \
                "KEEP" "Keep PostgreSQL database (for other tools)" \
                "DROP" "${RED}Drop 'paperclip' database and user${NC}" \
                ""      "" \
                "BACK"  "Cancel") || return 0
            case "$db_choice" in
                "") return 0 ;;
                KEEP) db_choice="1" ;;
                DROP) db_choice="2" ;;
                BACK|*) return 0 ;;
            esac
        else
            db_choice="2"
        fi

        if [ "$db_choice" == "2" ]; then
            # Pre-check: verify PostgreSQL is actually responding before attempting DROP.
            # On Android, ghost processes or stale sockets can cause psql to hang.
            if safe_timeout 3 psql -d postgres -c "SELECT 1" >/dev/null 2>&1; then
                psql -d postgres -c "DROP DATABASE IF EXISTS paperclip;" >> "$LOG_FILE" 2>&1 || true
                psql -d postgres -c "DROP USER IF EXISTS paperclip;" >> "$LOG_FILE" 2>&1 || true
                echo -e "${GREEN}Paperclip database and user dropped.${NC}"
            else
                warn_msg "PostgreSQL not responding — cannot drop database. It will be cleaned on next install."
                echo -e "   ${BLUE}pg_ctl -D \$PREFIX/var/lib/postgresql status${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}Paperclip process stopped. Source code and database preserved.${NC}"
        echo -e "   Source: ${BLUE}$HOME/paperclip${NC}"
        echo -e "   Database: ${BLUE}postgres://paperclip:paperclip@localhost:5432/paperclip${NC}"
    fi
    echo -e "   PostgreSQL is still running. Stop manually if no other services need it:"
    echo -e "   ${BLUE}pg_ctl -D \$PREFIX/var/lib/postgresql stop${NC}"
    echo -e "   Remove manually if desired."
}


# --- 13. MENUS ---

menu_agents() {
    local oc_bull="[ ]" hb_bull="[ ]" nb_bull="[ ]" rs_bull="[ ]"
    is_installed "openclaw" && oc_bull="[*]"
    (type -P hermes >/dev/null 2>&1 || [ -f "$HOME/.hermes/bin/hermes" ]) && hb_bull="[*]"
    command -v nanobot >/dev/null 2>&1 && nb_bull="[*]"
    [ -n "$(find "$HOME" -maxdepth 1 -type d -name '.hermes.bak.*' -print -quit 2>/dev/null)" ] && rs_bull="[R]"
    while true; do
        local choice menu_exit=0
        choice=$(show_whi_menu "AI Agents & LLMs  |  Use ↑/↓ to navigate, Enter to select" \
            "OPENCLAW"   "$oc_bull  OpenClaw   — Multi-Channel Agent Gateway" \
            "HERMES"     "$hb_bull  Hermes     — Autonomous Agent (Nous Research)" \
            "NANOBOT"    "$nb_bull  Nanobot    — Lightweight Python Agent (HKUDS)" \
            ""           "" \
            "RESTORE"    "$rs_bull  Restore    — Restore Hermes from Backup" \
            ""           "" \
            "BACK"       "<--  BACK TO MAIN MENU") || menu_exit=$?
        [ $menu_exit -ne 0 ] && return
        case "$choice" in
            "") continue ;;
            OPENCLAW) install_openclaw ;;
            HERMES)   install_hermes ;;
            NANOBOT)  install_nanobot ;;
            RESTORE)  restore_hermes_backup ;;
            BACK|*)    return ;;
        esac
    done
}

menu_workflows() {
    local n8_bull="[ ]" pc_bull="[ ]"
    is_installed "n8n" && n8_bull="[*]"
    [ -f "$HOME/paperclip/server/dist/index.js" ] && pc_bull="[*]"
    while true; do
        local choice
        choice=$(show_whi_menu "Workflows & Automation  |  Use ↑/↓ to navigate, Enter to select" \
            "N8N"       "$n8_bull  n8n         — Automation & Integration Server" \
            "PAPERCLIP" "$pc_bull  Paperclip   — Multi-Agent Virtual Company ([!] 2GB+ RAM)" \
            ""          "" \
            "BACK"      "<--  BACK TO MAIN MENU") || :
        case "$choice" in
            "") continue ;;
            N8N)       install_n8n ;;
            PAPERCLIP) install_paperclip ;;
            BACK|*)    return ;;
        esac
    done
}

menu_utilities() {
    local gm_bull="[ ]" pi_bull="[ ]" ol_bull="[ ]"
    is_installed "gemini-cli" && gm_bull="[*]"
    (is_installed "@earendil-works/pi-coding-agent" || is_installed "@mariozechner/pi-coding-agent") && pi_bull="[*]"
    command -v ollama >/dev/null 2>&1 && ol_bull="[*]"
    while true; do
        local choice
        choice=$(show_whi_menu "Developer Utilities  |  Use ↑/↓ to navigate, Enter to select" \
            "GEMINI"   "$gm_bull  Gemini CLI — Google AI Developer Tool" \
            "PI"       "$pi_bull  Pi         — Minimalist Coding Agent (M. Zechner)" \
            "OLLAMA"   "$ol_bull  Ollama     — Local LLM Runner (ARM)" \
            "GCP"      "[i]  GCP Bridge — SSH Tunnel for n8n" \
            ""         "" \
            "BACK"     "<--  BACK TO MAIN MENU") || return
        case "$choice" in
            "") continue ;;
            GEMINI)   install_gemini_cli ;;
            PI)       install_pi ;;
            OLLAMA)   install_ollama ;;
            GCP)      setup_n8n_gcp ;;
            BACK|*)  return ;;
        esac
    done
}

menu_services() {
    local pm2_bull="[ ]" sv_bull="[ ]"
    [ -n "$_HAS_PM2" ] && pm2_bull="[*]"
    [ -d "$SERVICE_DIR" ] || [ -d "$N8N_SERVICE_DIR" ] && sv_bull="[*]"
    while true; do
        local choice
        choice=$(show_whi_menu "System & Background Services  |  Use ↑/↓ to navigate, Enter to select" \
            "PM2"    "$pm2_bull  PM2         — Process Manager (Recommended)" \
            "NATIVE" "$sv_bull  Native      — Termux Services (sv)" \
            ""       "" \
            "BACK"   "<--  BACK TO MAIN MENU") || return
        case "$choice" in
            "") continue ;;
            PM2)    manage_pm2 ;;
            NATIVE) manage_service ;;
            BACK|*) return ;;
        esac
    done
}

menu_uninstall() {
    while true; do
        local choice
        choice=$(show_whi_menu "Uninstall Software  |  Use ↑/↓ to navigate, Enter to select" \
            "OPENCLAW"   "[-]  OpenClaw   — Remove AI Gateway" \
            "N8N"        "[-]  n8n        — Remove Automation Server" \
            "GEMINI"     "[-]  Gemini CLI — Remove Google AI Tool" \
            "HERMES"     "[-]  Hermes     — Remove Coding Agent" \
            "OLLAMA"     "[-]  Ollama     — Remove Local LLM Runner" \
            "PI"         "[-]  Pi         — Remove Coding Agent" \
            "PAPERCLIP"  "[-]  Paperclip  — Remove Workflow Server" \
            "NANOBOT"    "[-]  Nanobot    — Remove Python AI Agent" \
            ""           "" \
            "WIPE"       "[!]  WIPE ALL   — Reset Software Stack" \
            ""           "" \
            "BACK"       "<--  BACK TO MAIN MENU") || return
        case "$choice" in
            "") continue ;;
            OPENCLAW)
                whiptail_confirm "This will remove the OpenClaw global package and background services." && { uninstall_openclaw; whiptail_msg "OpenClaw removed."; } ;;
            N8N)
                whiptail_confirm "This will remove n8n and its watchdog." && { uninstall_n8n; whiptail_msg "n8n removed."; } ;;
            GEMINI)
                whiptail_confirm "This will remove the Gemini CLI global package." && { uninstall_gemini; whiptail_msg "Gemini CLI removed."; } ;;
            HERMES)
                whiptail_confirm "This will remove the Hermes agent installation." && { uninstall_hermes; whiptail_msg "Hermes removed."; } ;;
            OLLAMA)
                whiptail_confirm "This will remove Ollama and downloaded models." && { uninstall_ollama; whiptail_msg "Ollama removed."; } ;;
            PI)
                whiptail_confirm "This will remove the Pi Coding Agent." && { uninstall_pi; whiptail_msg "Pi removed."; } ;;
            PAPERCLIP)
                whiptail_confirm "Paperclip soft-uninstall preserves source code and database. For deep uninstall (wipe everything), use UNINSTALL -> Wipe Software Stack." && { uninstall_paperclip; whiptail_msg "Paperclip removed (soft)."; } ;;
            NANOBOT)
                whiptail_confirm "This will remove Nanobot AI." && { uninstall_nanobot; whiptail_msg "Nanobot AI removed."; } ;;
            WIPE)
                whiptail_confirm "This will WIPE ALL applications and data. Core system packages are NOT removed." && { full_cleanup; whiptail_msg "All toolkit software removed."; } ;;
            BACK|*) return ;;
        esac
    done
}

menu_help() {
    whiptail_msg "${BLUE}Droid AI Toolkit v${VERSION}${NC}

${GREEN}AGENTS${NC}     — AI gateways and coding agents
  OpenClaw    Multi-channel AI gateway (Telegram, Slack, Discord)
  Hermes      Autonomous agent by Nous Research
  Nanobot     Lightweight Python agent with Claude

${GREEN}WORKFLOWS${NC}  — Automation servers
  n8n         Professional workflow automation
  Paperclip   Multi-agent virtual company (EXPERIMENTAL)

${GREEN}UTILITIES${NC}  — Developer tools
  Gemini CLI  Google's command-line AI assistant
  Pi          Minimalist coding agent by M. Zechner
  Ollama      Local LLM runner for ARM devices
  GCP Bridge  SSH tunnel to expose n8n publicly

${GREEN}SERVICES${NC}   — Background process management
  PM2         Recommended process manager
  Native      Termux native services (sv)

${YELLOW}TIP:${NC} Use [R] Repair to fix patches without re-downloading.
Use [U] Update to get the latest version + re-apply patches.
Never run native update commands (e.g. openclaw update)."
}

check_termux
ensure_deps

while true; do
    choice=$(show_whi_menu "Main Menu  |  Use ↑/↓ to navigate, Enter to select" \
        "AGENTS"     "AI Agents    — OpenClaw, Hermes, Nanobot" \
        "WORKFLOWS"  "Workflows    — n8n, Paperclip" \
        "UTILITIES"  "Developer    — Gemini CLI, Pi, Ollama, GCP Bridge" \
        "SERVICES"   "Background   — PM2, Native Services" \
        ""           "" \
        "UNINSTALL"  "Uninstall    — Remove Tools & Reset" \
        "HELP"       "[?]  Help      — What each tool does" \
        ""           "" \
        "EXIT"       "[X]  EXIT TOOLKIT") || exit 0
    case "$choice" in
        "") continue ;;
        AGENTS)     menu_agents ;;
        WORKFLOWS)  menu_workflows ;;
        UTILITIES)  menu_utilities ;;
        SERVICES)   menu_services ;;
        UNINSTALL)  menu_uninstall ;;
        HELP)       menu_help ;;
        EXIT|*)     exit 0 ;;
    esac
done
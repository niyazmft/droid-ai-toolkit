#!/bin/bash

# ==============================================================================
# DROID AI TOOLKIT (Termux)
# Version: 1.11.0
# Purpose: Install and manage AI tools (OpenClaw, Gemini CLI, n8n, Ollama,
#          Hermes, Paperclip) on Android via Termux with kernel patches and path fixes.
# ==============================================================================

# Do NOT enable set -e. This is an interactive installer with deliberate
# fallbacks (e.g. Hermes upstream installer failure → manual pip fallback).
# set -e would kill the shell mid-install and return user to the prompt
# without any error message, making debugging impossible on-device.
# set -o pipefail is also avoided for the same reason.

# --- 1. COLORS & GLOBALS ---
VERSION="1.11.0"
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

# --- 2. HELPER FUNCTIONS ---

status_msg() { echo -ne "\r${CLEAR_LINE}${BLUE}==>${NC} $1... "; }
error_msg() { echo -e "\r${CLEAR_LINE}${RED}Error:${NC} $1"; }
success_msg() { echo -e "${GREEN}Done.${NC}"; }
warn_msg() { echo -e "\r${CLEAR_LINE}${YELLOW}Warning:${NC} $1"; }
wait_to_continue() { read -p "$(printf "\n${BLUE}>>${NC} Press Enter to continue...")" junk; }

ensure_deps() {
    export DEBIAN_FRONTEND=noninteractive
    local pkgs=()
    if ! command -v jq >/dev/null 2>&1; then
        pkgs+=(jq)
    fi
    if ! command -v whiptail >/dev/null 2>&1; then
        pkgs+=(whiptail)
    fi
    if [ ${#pkgs[@]} -gt 0 ]; then
        status_msg "Installing required toolkit dependencies (${pkgs[*]})"
        pkg update -y -o Dpkg::Options::=--force-confold >/dev/null 2>&1 || true
        pkg install -y -o Dpkg::Options::=--force-confold "${pkgs[@]}" >/dev/null 2>&1
        success_msg
    fi
}

# Persistence Helpers
set_config() {
    local key=$1
    local value=$2
    local tmp; tmp=$(mktemp)
    mkdir -p "$(dirname "$TOOLKIT_CONFIG")"
    if [ ! -f "$TOOLKIT_CONFIG" ]; then echo "{}" > "$TOOLKIT_CONFIG"; fi
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$TOOLKIT_CONFIG" > "$tmp" && mv "$tmp" "$TOOLKIT_CONFIG"
}

get_config() {
    local key=$1
    if [ -f "$TOOLKIT_CONFIG" ]; then
        jq -r --arg k "$key" '.[$k] // "null"' "$TOOLKIT_CONFIG"
    else
        echo "null"
    fi
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
    local total_ram=$(free -m | awk '/^Mem:/{print $2}')
    # Aim for 75% of total RAM, but cap at 2048MB for stability
    local calculated=$(( total_ram * 75 / 100 ))
    if [ "$calculated" -gt 2048 ]; then
        echo "2048"
    elif [ "$calculated" -lt 512 ]; then
        echo "512"
    else
        echo "$calculated"
    fi
}

# pnpm (v10+) may print warnings to stdout when npm_config_force=true.
# This helper isolates the actual path by taking the last non-empty line.
pnpm_root_g() {
    pnpm root -g 2>/dev/null | sed -n '$p'
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
    extract_dir="$TMPDIR/jiter_extract_$$"
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
        execute "pnpm add -g ${deps[*]} --prefer-offline || pnpm add -g ${deps[*]}" "Installing missing channel and UI dependencies"
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
    
    # Ensure spinner dies if user hits Ctrl+C
    trap 'kill $spinner_pid 2>/dev/null; rm -f "$tmp_log"; exit 1' INT TERM
    
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
        exit 1
    fi
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
        echo -e "\n${YELLOW}OpenClaw is already installed.${NC}"
        echo "1) [R] Repair Patches (Fast - 2s)"
        echo "2) [U] Update to Latest (Full - 1m)"
        echo "3) Back"
        read -p "$(printf "${BLUE}>>${NC} Select Option [1-3]: ")" REPAIR_CHOICE
        case $REPAIR_CHOICE in
            1) mode="repair" ;;
            2) mode="full" ;;
            *) return 0 ;;
        esac
    else
        confirm_action "Install OpenClaw" || return 0
        mode="full"
    fi

    rm -f "$LOG_FILE"
    echo -e "${YELLOW}Verbose logs are being written to $LOG_FILE${NC}\n"

    status_msg "Stopping existing tasks & freeing memory"
    pkill -9 -f "openclaw" 2>/dev/null || true
    pkill -9 -f "n8n" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 kill >> "$LOG_FILE" 2>&1 || true
    
    # Surgical lock cleanup
    rm -f "$HOME/.openclaw/tmp/openclaw.lock" "$HOME/.openclaw/tmp/openclaw-*" "$PREFIX/var/run/crond.pid"
    success_msg

    if [[ "$mode" == "full" ]]; then
        # Batched package installation for performance
        smart_pkg_install tur-repo build-essential libvips openssh git python3 pkg-config cmake tmux binutils termux-services ffmpeg golang nodejs-22 psmisc

        if [ -d "$PREFIX/opt/nodejs-22/bin" ]; then
            NODE_OPT_BIN="$PREFIX/opt/nodejs-22/bin"
            execute "ln -sf '$NODE_OPT_BIN/node' '$TERMUX_BIN/node' && ln -sf '$NODE_OPT_BIN/npm' '$TERMUX_BIN/npm'" "Verifying Node.js links"
        fi
    fi

    PKG_MANAGER=$(select_package_manager "openclaw")
    [[ "$PKG_MANAGER" == "back" ]] && return 0
    OPENCLAW_ROOT=$(get_openclaw_root "$PKG_MANAGER")

    if [[ "$mode" == "full" ]]; then
        status_msg "Preparing clean slate"
        rm -rf "$OPENCLAW_ROOT"
        success_msg

        if [ "$PKG_MANAGER" == "npm" ]; then
            execute "npm install -g openclaw@latest" "Installing OpenClaw via npm"
        else
            execute "pnpm add -g openclaw@latest --force" "Installing OpenClaw via pnpm"
        fi
    fi

    status_msg "Applying Android patches"
    apply_patches
    success_msg
    
    # Configure for Termux
    CONFIG_PATH="$HOME/.openclaw/openclaw.json"
    if [ -f "$CONFIG_PATH" ]; then
        status_msg "Configuring Termux-specific settings"
        local tmp_cfg; tmp_cfg=$(mktemp)
        # Apply configuration updates with atomic move
        # 1. Deep merge channel tokens, force disable audio, streaming and UI
        # 2. Clean up channel objects that should not exist on mobile
        # 3. Fix legacy keys and validate schema via doctor
        jq '
            .channelToken = ((.channelToken // {}) + {"telegram": (.channelToken.telegram // "YOUR_BOT_TOKEN")}) |
            .ui.showSystemPrompt = false |
            .disableAudio = true |
            .plugins.entries = ((.plugins.entries // {}) | with_entries(.value |= . + {"enabled": false})) |
            del(.plugins.entries.telegram, .plugins.entries.ollama, .plugins.entries["memory-core"]) |
            .plugins.entries.telegram = {"enabled": true, "path": "builtin:telegram", "description": "Telegram channel"} |
            .plugins.entries.ollama = {"enabled": true, "path": "builtin:ollama", "description": "Ollama plugin"} |
            .plugins.entries["memory-core"] = {"enabled": true, "path": "builtin:memory", "description": "Memory plugin"} |
            del(.plugins.entries.kimi-coding, .plugins.entries.speech-core, .plugins.entries["image-generation-core"], .plugins.entries["video-generation-core"], .plugins.entries["media-understanding-core"]) |
            .plugins.entries = (if (.plugins.entries | type) == "object" then (.plugins.entries) else {} end) |
            .plugins.entries = ((.plugins.entries // {}) | with_entries(.value |= if (.enabled? | type) == "boolean" then . else . + {"enabled": false} end)) |
            .plugins.entries = ((.plugins.entries // {}) | with_entries(.value |= . + {"enabled": false})) |
            del(.plugins.entries.telegram, .plugins.entries.ollama, .plugins.entries["memory-core"]) |
            .plugins.entries.telegram = {"enabled": true} |
            .plugins.entries.ollama = {"enabled": true} |
            .plugins.entries["memory-core"] = {"enabled": true} |
            del(.channels.telegram.streamMode, .channels.telegram.chunkMode, .channels.telegram.blockStreaming, .channels.telegram.draftChunk, .channels.telegram.blockStreamingCoalesce) |
            del(.channels.slack.streamMode, .channels.slack.chunkMode, .channels.slack.blockStreaming, .channels.slack.blockStreamingCoalesce, .channels.slack.nativeStreaming) |
            if (.channels.telegram.streaming? | type) != "object" then del(.channels.telegram.streaming) else . end |
            if (.channels.slack.streaming? | type) != "object" then del(.channels.slack.streaming) else . end' "$CONFIG_PATH" > "$tmp_cfg" && mv "$tmp_cfg" "$CONFIG_PATH"
        
        # 4. Automated Migration: Fix legacy keys and validate schema
        # We ignore failure because doctor --fix tries to install systemd services on Linux, which fails on Android but is not critical.
        yes "" | openclaw doctor --fix >> "$LOG_FILE" 2>&1 || true
        success_msg
    fi
    if [[ "$mode" == "full" ]]; then
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

apply_patches() {
    local silent=$1
    local verbose_flag=""
    [[ "$silent" == "silent" ]] && verbose_flag="-q"
    
    # 1. Koffi Patch
    KOFFI_SRC="$OPENCLAW_ROOT/node_modules/koffi/lib/native/base/base.cc"
    if [ -f "$KOFFI_SRC" ] && [[ "$silent" != "silent" ]]; then
        execute "sed -i 's/renameat2(AT_FDCWD, src_filename, AT_FDCWD, dest_filename, RENAME_NOREPLACE)/rename(src_filename, dest_filename)/g' '$KOFFI_SRC'" "Patching Koffi native library"
        execute "cd '$OPENCLAW_ROOT/node_modules/koffi' && JOBS=1 MAKEFLAGS='-j1' node src/cnoke/cnoke.js -p . -d src/koffi --prebuild" "Rebuilding Koffi"
        
        local K_TRIPLET="android_armsf"
        [[ "$ARCH_TYPE" == "aarch64" ]] && K_TRIPLET="android_arm64"
        execute "mkdir -p '$K_TRIPLET' && cp 'build/koffi/$K_TRIPLET/koffi.node' '$K_TRIPLET/'" "Mapping Koffi binary"
    elif [ -f "$KOFFI_SRC" ]; then
        sed -i 's/renameat2(AT_FDCWD, src_filename, AT_FDCWD, dest_filename, RENAME_NOREPLACE)/rename(src_filename, dest_filename)/g' "$KOFFI_SRC"
        (cd "$OPENCLAW_ROOT/node_modules/koffi" && JOBS=1 MAKEFLAGS='-j1' node src/cnoke/cnoke.js -p . -d src/koffi --prebuild $verbose_flag) 2>/dev/null || true
        [[ "$ARCH_TYPE" == "aarch64" ]] && K_TRIPLET="android_arm64" || K_TRIPLET="android_armsf"
        mkdir -p "$K_TRIPLET" && cp "build/koffi/$K_TRIPLET/koffi.node" "$K_TRIPLET/" 2>/dev/null || true
    fi

    # 2. Gemini CLI Patch: Prevent ENOENT on Android
    GEMINI_ROOT="$(npm root -g 2>/dev/null || echo "$PREFIX/lib/node_modules")"
    if [ -d "$GEMINI_ROOT" ] && [[ "$silent" != "silent" ]]; then
        execute "find -L '$GEMINI_ROOT' -type f -name 'projectRegistry.js' -exec sed -i 's|await fs.promises.rename(\([^,]*\), \([^)]*\))|await fs.promises.copyFile(\1, \2); await fs.promises.unlink(\1)|g' {} + 2>/dev/null || true" "Patching Gemini CLI for Android"
    elif [ -d "$GEMINI_ROOT" ]; then
        # Uses regex to preserve variable names (e.g., tmpPath, registryPath)
        find -L "$GEMINI_ROOT" -type f -name "projectRegistry.js" -exec sed -i 's|await fs.promises.rename(\([^,]*\), \([^)]*\))|await fs.promises.copyFile(\1, \2); await fs.promises.unlink(\1)|g' {} + 2>/dev/null || true
    fi

    # 3. Paperclip Path Patch (if installed)
    if [ -f "$HOME/paperclip/server/dist/index.js" ] && [[ "$silent" != "silent" ]]; then
        execute "sed -i 's|/tmp/|${HOME}/.tmp/|g; s|/usr/local/bin|${PREFIX}/bin|g' '${HOME}/paperclip/server/dist/index.js'" "Patching Paperclip paths"
    fi
}

# --- 4.5. PI CODING AGENT INSTALLATION ---

install_pi() {
    local mode="full"
    if is_installed "@mariozechner/pi-coding-agent"; then
        echo -e "\n${YELLOW}Pi Coding Agent is already installed.${NC}"
        echo "1) [R] Repair / Reinstall"
        echo "2) [U] Update to Latest"
        echo "3) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-3]: ")" REPAIR_CHOICE
        case $REPAIR_CHOICE in
            1) mode="repair" ;;
            2) mode="full" ;;
            *) return 0 ;;
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

    PKG_MANAGER=$(select_package_manager "@mariozechner/pi-coding-agent")
    [[ "$PKG_MANAGER" == "back" ]] && return 0

    if [ "$PKG_MANAGER" == "npm" ]; then
        execute "npm install -g @mariozechner/pi-coding-agent@latest" "Installing Pi Coding Agent via npm"
    else
        execute "pnpm add -g @mariozechner/pi-coding-agent@latest --force" "Installing Pi Coding Agent via pnpm"
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
        echo -e "Run:  ${BLUE}pi --help${NC}"
    else
        error_msg "Installation finished but 'pi' command not found in PATH."
    fi
    wait_to_continue
}

# --- 5. GEMINI CLI INSTALLATION ---

install_gemini_cli() {
    local mode="full"
    if is_installed "gemini-cli"; then
        echo -e "\n${YELLOW}Gemini CLI is already installed.${NC}"
        echo "1) [R] Repair"
        echo "2) [U] Update to Latest"
        echo "3) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-3]: ")" GEM_CHOICE
        case $GEM_CHOICE in
            1) mode="repair" ;;
            2) mode="full" ;;
            *) return 0 ;;
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
            execute "pnpm add -g @google/gemini-cli@latest --force" "Installing Gemini CLI via pnpm"
        fi
    fi

    # Apply patches to prevent ENOENT errors during registry writes
    GEMINI_ROOT="$(get_global_node_path)"
    if [ -d "$GEMINI_ROOT" ]; then
        status_msg "Patching Gemini CLI for Android"
        find -L "$GEMINI_ROOT" -type f -name "projectRegistry.js" -exec sed -i 's|await fs.promises.rename(\([^,]*\), \([^)]*\))|await fs.promises.copyFile(\1, \2); await fs.promises.unlink(\1)|g' {} + 2>/dev/null || true
        success_msg

        echo -e "${GREEN}\nGemini CLI successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed")!${NC}"
        health_check "Gemini CLI" "command -v gemini" || true
        echo -e "You can now run: ${BLUE}gemini --help${NC}"
    else
        error_msg "Installation finished but 'gemini' command not found in PATH."
    fi
    wait_to_continue
}

# --- 6. n8n INSTALLATION ---

install_n8n() {
    local mode="full"
    if is_installed "n8n"; then
        echo -e "\n${YELLOW} n8n is already installed.${NC}"
        echo "1) [R] Repair Config/Watchdog (Fast)"
        echo "2) [U] Update to Latest (Full)"
        echo "3) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-3]: ")" REPAIR_CHOICE
        case $REPAIR_CHOICE in
            1) mode="repair" ;;
            2) mode="full" ;;
            *) return 0 ;;
        esac
    else
        confirm_action "Install n8n Server" || return 0
    fi

    echo -e "\n${BLUE} $([[ "$mode" == "repair" ]] && echo "Repairing" || echo "Setting up") n8n Android Infrastructure...${NC}"

    status_msg "Stopping existing tasks & freeing memory"
    pkill -9 -f "n8n" 2>/dev/null || true
    pkill -9 -f "openclaw" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 kill >> "$LOG_FILE" 2>&1 || true
    success_msg

    if [[ "$mode" == "full" ]]; then
        smart_pkg_install nodejs-22 python3 autossh tmux cronie
        
        if [ -d "$PREFIX/opt/nodejs-22/bin" ]; then
            NODE_OPT_BIN="$PREFIX/opt/nodejs-22/bin"
            execute "ln -sf '$NODE_OPT_BIN/node' '$TERMUX_BIN/node' && ln -sf '$NODE_OPT_BIN/npm' '$TERMUX_BIN/npm'" "Verifying Node.js links"
        fi
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
            execute "pnpm add -g n8n@latest --force" "Installing n8n globally via pnpm"
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
        echo "[$(date)] 🌐 Tunnel not found. Re-establishing..." >> "$LOG_FILE"
        tmux kill-session -t "$TUNNEL_SESSION" 2>/dev/null
        tmux new-session -d -s "$TUNNEL_SESSION" "$TUNNEL_CMD"
    fi
fi
EOF
    chmod +x "$HOME/n8n_server/scripts/n8n-monitor.sh"
    success_msg

    echo -e "\n${GREEN} n8n successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed")!${NC}"
    health_check "n8n" "command -v n8n" || true
    echo -e "\n${YELLOW}  NEXT STEPS:${NC}"
    echo -e "1. Select ${BLUE}SERVICES${NC} -> ${BLUE}PM2${NC} (Recommended) or ${BLUE}Native Services${NC} to configure background services."
    wait_to_continue
}

# --- 6. GCP BRIDGE SETUP ---

setup_n8n_gcp() {
    confirm_action "Configure GCP Bridge" || return 0
    echo -e "\n${BLUE}🌐 GCP BRIDGE (SSH TUNNEL) CONFIGURATION${NC}"
    
    read -p "Enter your GCP VM IP (e.g., 35.192.123.45): " GCP_IP
    read -p "Enter your GCP VM Username (e.g., n8n_admin): " GCP_USER
    
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

# --- 7. OLLAMA INSTALLATION ---

install_ollama() {
    if is_installed "ollama"; then
        echo -e "\n${YELLOW}Ollama is already installed.${NC}"
        echo "1) [R] Reinstall"
        echo "2) [U] Update"
        echo "3) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-3]: ")" REPAIR_CHOICE
        case $REPAIR_CHOICE in
            1) mode="reinstall" ;;
            2) mode="update" ;;
            *) return 0 ;;
        esac
    else
        confirm_action "Install Ollama" || return 0
        mode="install"
    fi

    echo -e "\n${BLUE}${mode^}ing Ollama...${NC}"
    
    smart_pkg_install ollama

    if command -v ollama >/dev/null 2>&1; then
        echo -e "\n${GREEN}Ollama successfully installed!${NC}"
        health_check "Ollama" "command -v ollama" || true
        echo -e "Start the server: ${BLUE}ollama serve${NC}"
        echo -e "Pull a model:      ${BLUE}ollama pull llama3${NC}"
        echo -e "Run a model:       ${BLUE}ollama run llama3${NC}"
    else
        error_msg "Ollama installation failed."
    fi
    wait_to_continue
}

# --- 8. HERMES INSTALLATION ---

install_hermes() {
    # Architecture guard: armv8l/armv7l cannot build or load jiter (glibc wheels,
    # maturin rejects armv8l). Hermes requires jiter transitively through anthropic.
    local arch; arch="$(uname -m)"
    if [ "$arch" = "armv8l" ] || [ "$arch" = "armv7l" ]; then
        echo -e "\n${YELLOW}ℹ️  Hermes Agent is not supported on ${arch}.${NC}"
        echo -e "   Reason: jiter (a dependency of anthropic/hermes) requires ${NC}"
        echo -e "   Rust compilation via maturin, which does not support the ${NC}"
        echo -e "   ${arch} architecture in upstream wheels.${NC}"
        echo -e "   Workaround: Run Hermes on a device with aarch64 or x86_64.${NC}"
        wait_to_continue
        return 0
    fi

    # Detection: check PATH, static binary, or .bashrc entry (install attempted)
    local hermes_cmd=""
    hermes_cmd=$(type -P hermes 2>/dev/null || true)
    local bashrc_has_hermes=$(grep -q 'hermes' "$HOME/.bashrc" 2>/dev/null && echo "yes" || echo "no")
    local hermes_exists="no"
    if [ -n "$hermes_cmd" ] || [ -f "$HOME/.hermes/bin/hermes" ]; then
        hermes_exists="yes"
    elif [ "$bashrc_has_hermes" == "yes" ] || [ -d "$HOME/.hermes" ]; then
        # Partial / broken install
        hermes_exists="partial"
    fi

    local mode="install"
    if [ "$hermes_exists" == "yes" ]; then
        echo -e "\n${YELLOW}Hermes is already installed.${NC}"
        echo "1) [R] Reinstall"
        echo "2) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-2]: ")" HM_CHOICE
        case $HM_CHOICE in
            1) mode="reinstall" ;;
            *) return 0 ;;
        esac
    elif [ "$hermes_exists" == "partial" ]; then
        echo -e "\n${YELLOW}Hermes appears partially installed or broken.${NC}"
        echo "1) [F] Fix / Retry Install"
        echo "2) [D] Deep Clean & Reinstall"
        echo "3) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-3]: ")" HM_CHOICE
        case $HM_CHOICE in
            1) mode="fix" ;;
            2) mode="reinstall" ;;
            *) return 0 ;;
        esac
    else
        confirm_action "Install Hermes Agent" || return 0
    fi

    echo -e "\n${BLUE}${mode^}ing Hermes Agent...${NC}"

    # Pre-install build dependencies that upstream often fails on
    smart_pkg_install python clang rust make pkg-config libffi openssl binutils

    # Handle reinstall / fix — preserve source dir for fallback pip path
    if [ "$mode" == "reinstall" ]; then
        status_msg "Backing up and removing old Hermes installation"
        pkill -9 -f hermes 2>/dev/null || true
        if [ -d "$HOME/.hermes" ]; then
            # Timestamped backup so user can recover if reinstall fails
            local backup_dir="$HOME/.hermes.bak.$(date +%Y%m%d%H%M%S)"
            mv "$HOME/.hermes" "$backup_dir"
            echo -e "${BLUE}Backed up old install to $backup_dir${NC}"
        fi
        # Remove stale PATH entries from .bashrc
        sed -i '/\.hermes\/bin/d' "$HOME/.bashrc" 2>/dev/null || true
        success_msg
    elif [ "$mode" == "fix" ]; then
        status_msg "Preparing broken Hermes for repair"
        pkill -9 -f hermes 2>/dev/null || true
        success_msg
    fi

    # Set Rust/Cargo environment for low-RAM Termux builds
    export CARGO_BUILD_JOBS=1
    export CARGO_NET_GIT_FETCH_WITH_CLI=true
    export RUSTFLAGS="-C opt-level=2"

    # Fix critical: Maturin requires ANDROID_API_LEVEL on Termux
    # https://github.com/termux/termux-packages/issues/20771
    local android_api_level=$(getprop ro.build.version.sdk 2>/dev/null || echo "34")
    export ANDROID_API_LEVEL=${android_api_level}
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=clang

    # Run upstream installer without strict execute wrapper to allow graceful fallback
    local hermes_tmp_log; hermes_tmp_log=$(mktemp)
    local hermes_exit=0
    status_msg "Running Hermes upstream installer"
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash > "$hermes_tmp_log" 2>&1 || hermes_exit=$?
    cat "$hermes_tmp_log" >> "$LOG_FILE"

    # Upstream installer may return 0 even when pip fails inside it (maturin/jiter error).
    # Trust the presence of the binary, not the exit code.
    local hermes_bin=""
    hermes_bin=$(type -P hermes 2>/dev/null || true)
    if [ -z "$hermes_bin" ] && [ -f "$HOME/.hermes/bin/hermes" ]; then
        hermes_bin="$HOME/.hermes/bin/hermes"
    fi

    if [ -n "$hermes_bin" ] && [ -x "$hermes_bin" ] && [ "$hermes_exit" -eq 0 ]; then
        success_msg
    else
        printf "\r${CLEAR_LINE}${YELLOW}  Hermes installer exited with warnings.${NC}\n"
        echo -e "${BLUE}Attempting manual fallback installation...${NC}"
        tail -n 20 "$hermes_tmp_log"
    fi
    rm -f "$hermes_tmp_log"

    # Fallback: try manual pip install if upstream left a partial source checkout
    if [ -d "$HOME/.hermes/hermes-agent" ] && [ -z "$hermes_bin" ]; then
        status_msg "Attempting manual Python package fallback"
        local venv_path="$HOME/.hermes/hermes-agent/venv"
        if [ -f "$venv_path/bin/pip" ]; then
            # Export Termux env vars needed by maturin/Rust builds
            export ANDROID_API_LEVEL=${android_api_level}
            export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=clang
            export CARGO_BUILD_JOBS=1

            "$venv_path/bin/pip" install --upgrade pip wheel setuptools --quiet 2>>"$LOG_FILE" || true
            # Pre-install jiter armv7l wheel on armv8l/armv7l devices (maturin rejects armv8l)
            ensure_jiter_armv8l "$venv_path/bin/pip"
            # Prefer pre-built binary wheels where available to skip Rust compilation
            "$venv_path/bin/pip" install jiter pydantic-core --prefer-binary --no-build-isolation --quiet 2>>"$LOG_FILE" || true
            # Retry with Termux-specific constraints
            if [ -f "$HOME/.hermes/hermes-agent/constraints-termux.txt" ]; then
                "$venv_path/bin/pip" install -e "$HOME/.hermes/hermes-agent[termux]" \
                    -c "$HOME/.hermes/hermes-agent/constraints-termux.txt" --no-build-isolation >> "$LOG_FILE" 2>&1 || true
            fi
        fi
        success_msg
    fi

    # Verify final installation — source .bashrc first because upstream
    # installer appends PATH there; current shell never sees it otherwise
    [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null || true

    local hermes_final_path=""
    hermes_final_path=$(type -P hermes 2>/dev/null || true)
    if [ -z "$hermes_final_path" ] && [ -f "$HOME/.hermes/bin/hermes" ]; then
        # Add to current session PATH if found on disk but not in PATH
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

    wait_to_continue
}

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
        echo -e "\n${YELLOW}Nanobot AI is already installed.${NC}"
        echo "1) [R] Reinstall"
        echo "2) [U] Update"
        echo "3) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-3]: ")" NB_CHOICE
        case ${NB_CHOICE} in
            1) mode="reinstall" ;;
            2) mode="update" ;;
            *) return 0 ;;
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
        echo -e "Run: ${BLUE}nanobot --help${NC}"
    else
        echo -e "\n${YELLOW}Nanobot AI installation may be incomplete.${NC}"
    fi

    wait_to_continue
}

# --- 8.5. PAPERCLIP INSTALLATION (EXPERIMENTAL) ---
install_paperclip() {
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

    status_msg "Delegating to standalone Paperclip installer"
    echo -e "${BLUE}   Script: $SCRIPT${NC}"
    success_msg

    bash "$SCRIPT"
    return $?
}

# --- 9. SERVICE MANAGEMENT ---

manage_service() {
    while true; do
        local choice
        choice=$(show_whi_menu "Native Background Services" \
            "openclaw-setup"   "OpenClaw: Enable/Setup Service" \
            "openclaw-remove"  "OpenClaw: Disable/Remove Service" \
            "n8n-setup"        "n8n: Enable/Setup Native Service" \
            "n8n-remove"       "n8n: Disable/Remove Native Service" \
            "back"             "Back") || return
        case "$choice" in
            openclaw-setup)  whiptail_confirm "Set up OpenClaw background service?" && { setup_service_files; whiptail_msg "OpenClaw service configured."; } ;;
            openclaw-remove) whiptail_confirm "Remove OpenClaw background service?" && { remove_service_files; whiptail_msg "OpenClaw service removed."; } ;;
            n8n-setup)       whiptail_confirm "Set up n8n background service?" && { setup_n8n_service_files; whiptail_msg "n8n service configured."; } ;;
            n8n-remove)      whiptail_confirm "Remove n8n background service?" && { remove_n8n_service_files; whiptail_msg "n8n service removed."; } ;;
            back|*)           return ;;
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
export PATH="\$TERMUX_BIN:\$PATH"
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

manage_pm2() {
    if ! command -v pm2 >/dev/null 2>&1; then
        whiptail_confirm "Install PM2 globally first?" || return 0
        execute "npm install -g pm2" "Installing PM2 Globally"
    fi
    while true; do
        local choice
        choice=$(show_whi_menu "PM2 Process Management" \
            "openclaw"  "Start OpenClaw" \
            "n8n"       "Start n8n" \
            "gemini"    "Start Gemini CLI" \
            "hermes"    "Start Hermes" \
            "ollama"    "Start Ollama" \
            "pi"        "Start Pi" \
            "paperclip" "Start Paperclip" \
            "nanobot"   "Start Nanobot" \
            "logs"      "View Logs (Live)" \
            "status"    "View Status (Table)" \
            "restart"   "Restart All" \
            "stop"      "Stop/Kill PM2" \
            "back"      "Back") || return
        case "$choice" in
            openclaw)
                if command -v openclaw >/dev/null 2>&1; then
                    status_msg "Clearing ports and stale processes"
                    pm2 delete openclaw 2>/dev/null || true
                    pkill -9 -f openclaw 2>/dev/null || true
                    rm -f "$HOME/.openclaw/tmp/openclaw.lock"
                    success_msg
                    PNPM_NODE_PATH=$(pnpm_root_g || true)
                    SAFE_LIMIT=$(get_mem_limit)
                    execute "sleep 5; NODE_OPTIONS='--dns-result-order=ipv4first --max-old-space-size=$SAFE_LIMIT' OPENCLAW_TMP='$HOME/.openclaw/tmp' NODE_PATH='$PREFIX/lib/node_modules${PNPM_NODE_PATH:+:$PNPM_NODE_PATH}' npm_execpath='$TERMUX_BIN/npm' PATH='$TERMUX_BIN:\$PATH' pm2 start \"openclaw gateway run\" --name openclaw --interpreter none && pm2 save" "Starting OpenClaw in PM2 (Clean Start)"
                else
                    error_msg "OpenClaw is not installed."
                fi
                ;;
            n8n)
                if command -v n8n >/dev/null 2>&1; then
                    local n8n_env=""
                    [ -f "$HOME/n8n_server/config/n8n.env" ] && n8n_env="--env '$HOME/n8n_server/config/n8n.env'"
                    execute "pkill -9 -f n8n 2>/dev/null || true; sleep 2; pm2 start n8n --name n8n $n8n_env --interpreter none && pm2 save" "Starting n8n in PM2"
                else
                    error_msg "n8n is not installed."
                fi
                ;;
            gemini)
                local gemini_path=""
                gemini_path=$(type -P gemini 2>/dev/null || true)
                if [ -n "$gemini_path" ]; then
                    execute "pm2 delete gemini 2>/dev/null || true; pm2 start '$gemini_path' --name gemini --interpreter none && pm2 save" "Starting Gemini CLI in PM2"
                else
                    error_msg "Gemini CLI is not installed."
                fi
                ;;
            hermes)
                local hermes_path=""
                hermes_path=$(type -P hermes 2>/dev/null || true)
                if [ -z "$hermes_path" ] && [ -f "$HOME/.hermes/bin/hermes" ]; then
                    hermes_path="$HOME/.hermes/bin/hermes"
                fi
                if [ -n "$hermes_path" ]; then
                    execute "pm2 delete hermes 2>/dev/null || true; pm2 start '$hermes_path' --name hermes --interpreter none && pm2 save" "Starting Hermes in PM2"
                else
                    error_msg "Hermes is not installed."
                fi
                ;;
            ollama)
                if command -v ollama >/dev/null 2>&1; then
                    execute "pm2 delete ollama 2>/dev/null || true; pm2 start ollama serve --name ollama --interpreter none && pm2 save" "Starting Ollama in PM2"
                else
                    error_msg "Ollama is not installed."
                fi
                ;;
            pi)
                local pi_path=""
                pi_path=$(type -P pi 2>/dev/null || true)
                if [ -n "$pi_path" ]; then
                    execute "pm2 delete pi 2>/dev/null || true; pm2 start '$pi_path' --name pi --interpreter none && pm2 save" "Starting Pi in PM2"
                else
                    error_msg "Pi is not installed."
                fi
                ;;
            paperclip)
                if [ -f "$HOME/paperclip/server/dist/index.js" ]; then
                    status_msg "Checking PostgreSQL before Paperclip start"
                    if ! timeout 3 psql -d postgres -c "SELECT 1" >/dev/null 2>&1; then
                        # Stale ghost process detection (no postmaster.pid but port held)
                        STALE_PID=$(pgrep -f "postgres -D $PREFIX/var/lib/postgresql" 2> /dev/null || true)
                        if [ -n "$STALE_PID" ]; then
                            warn_msg "Stale PostgreSQL process detected (PID $STALE_PID) — stopping it"
                            kill -9 "$STALE_PID" 2> /dev/null || true
                            sleep 1
                        fi
                        rm -f "$PREFIX/var/lib/postgresql/postmaster.pid" "$PREFIX/tmp/.s.PGSQL.5432"* 2>/dev/null || true
                        pg_ctl -D "$PREFIX/var/lib/postgresql" start -l "$HOME/paperclip/postgres.log" >/dev/null 2>&1 || true
                        sleep 2
                    fi
                    success_msg
                    execute "pm2 delete paperclip 2>/dev/null || true; cd $HOME/paperclip; pm2 start ecosystem.config.cjs && pm2 save" "Starting Paperclip in PM2"
                else
                    error_msg "Paperclip is not installed. Select WORKFLOWS -> Paperclip from the main menu to install."
                fi
                ;;
            nanobot)
                local nb_path=""
                nb_path=$(type -P nanobot 2>/dev/null || true)
                if [ -n "$nb_path" ]; then
                    execute "pm2 delete nanobot 2>/dev/null || true; pm2 start '$nb_path' --name nanobot --interpreter none && pm2 save" "Starting Nanobot in PM2"
                else
                    error_msg "Nanobot is not installed."
                fi
                ;;
            logs)    pm2 logs ;;
            status)  pm2 status; ;;
            restart) execute "pm2 stop all; pkill -9 -f 'openclaw|n8n|gemini|hermes|ollama|pi|paperclip|nanobot' 2>/dev/null || true; sleep 2; pm2 start all && pm2 save" "Restarting all processes safely" ;;
            stop)    execute "pm2 kill" "Stopping PM2" ;;
            back|*)  return ;;
        esac
    done
}

# --- 10. UNINSTALLATION LOGIC ---

uninstall_openclaw() {
    local force_deep=$1
    echo -e "${YELLOW}Cleaning up OpenClaw...${NC}"
    
    # Stop processes
    remove_service_files
    pkill -9 -f "openclaw" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 delete openclaw >> "$LOG_FILE" 2>&1 || true
    
    local pm=$(detect_package_manager "openclaw")
    if [ "$pm" == "pnpm" ]; then
        execute "pnpm remove -g openclaw" "Uninstalling OpenClaw via pnpm"
    else
        execute "npm uninstall -g openclaw" "Uninstalling OpenClaw via npm"
    fi

    local choice="1"
    if [[ "$force_deep" != "--deep" ]]; then
        echo -ne "\n${YELLOW}  DATA PRESERVATION:${NC}\n1) Soft Uninstall (Keep plugins/memory)\n2) Deep Uninstall (Wipe everything)\n"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-2]: ")" choice
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
        execute "pnpm remove -g @google/gemini-cli" "Uninstalling Gemini CLI via pnpm"
    else
        execute "npm uninstall -g @google/gemini-cli" "Uninstalling Gemini CLI via npm"
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
        execute "pnpm remove -g n8n" "Uninstalling n8n via pnpm"
    else
        execute "npm uninstall -g n8n" "Uninstalling n8n via npm"
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
    local pm=$(detect_package_manager "@mariozechner/pi-coding-agent")
    if [ "$pm" == "pnpm" ]; then
        execute "pnpm remove -g @mariozechner/pi-coding-agent" "Uninstalling Pi via pnpm"
    else
        execute "npm uninstall -g @mariozechner/pi-coding-agent" "Uninstalling Pi via npm"
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
    pkill -9 -f "paperclip" 2>/dev/null || true
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
        echo -ne "\n${YELLOW}  DATA PRESERVATION:${NC}\n1) Soft Uninstall (Keep source code + database)\n2) Deep Uninstall (Wipe source code, PM2 state, and optionally database)\n"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-2]: ")" choice
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
            echo -ne "\n${YELLOW}  DATABASE:${NC}\n1) Keep PostgreSQL database (for other tools)\n2) Drop 'paperclip' database and user\n"
            read -p "$(printf "${BLUE}>>${NC} Select option [1-2]: ")" db_choice
        else
            db_choice="2"
        fi

        if [ "$db_choice" == "2" ]; then
            # Pre-check: verify PostgreSQL is actually responding before attempting DROP.
            # On Android, ghost processes or stale sockets can cause psql to hang.
            if timeout 3 psql -d postgres -c "SELECT 1" >/dev/null 2>&1; then
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

# --- TUI Helpers ---
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

menu_item() {
    local tag="$1" desc="$2"
    printf '%s\n%s\n' "$tag" "$desc"
}

# show_menu <title> <items...>
# items are passed as tag desc pairs, without dynamic status prefixing.
show_whi_menu() {
    local title="$1"; shift
    local items=()
    while [ $# -gt 0 ]; do
        items+=("$1" "$2")
        shift 2
    done
    whiptail --title "Droid AI Toolkit v$VERSION" --menu "$title" $WHI_ROWS $WHI_COLS $(( ${#items[@]} / 2 )) \
        "${items[@]}" 3>&1 1>&2 2>&3
}

# yesno <text>
whiptail_confirm() {
    local text="$1"
    whiptail --title "Confirm" --yesno "$text" 8 $WHI_COLS 3>&1 1>&2 2>&3
}

# msgbox <text>
whiptail_msg() {
    local text="$1"
    whiptail --title "Droid AI Toolkit" --msgbox "$text" 12 $WHI_COLS 3>&1 1>&2 2>&3
}

# --- Sub-Menus ---

menu_agents() {
    while true; do
        local oc_bull="○" hb_bull="○" nb_bull="○" ol_bull="○"
        is_installed "openclaw" && oc_bull="●"
        (type -P hermes >/dev/null 2>&1 || [ -f "$HOME/.hermes/bin/hermes" ]) && hb_bull="●"
        command -v nanobot >/dev/null 2>&1 && nb_bull="●"
        command -v ollama >/dev/null 2>&1 && ol_bull="●"
        local choice menu_exit=0
        choice=$(show_whi_menu "AI Agents & LLMs" \
            "openclaw"   "$oc_bull OpenClaw — AI Gateway (Node.js)" \
            "hermes"     "$hb_bull Hermes — Coding Agent (Rust/Python)" \
            "nanobot"    "$nb_bull Nanobot — Python AI Agent" \
            "ollama"     "$ol_bull Ollama — Local LLM Runner (ARM)" \
            "back"       "← Back to Main Menu") || menu_exit=$?
        [ $menu_exit -ne 0 ] && return
        case "$choice" in
            openclaw) install_openclaw ;;
            hermes)   install_hermes ;;
            nanobot)  install_nanobot ;;
            ollama)   install_ollama ;;
            back|*)    return ;;
        esac
    done
}

menu_workflows() {
    while true; do
        local n8_bull="○" pc_bull="○"
        is_installed "n8n" && n8_bull="●"
        [ -f "$HOME/paperclip/server/dist/index.js" ] && pc_bull="●"
        local choice
        choice=$(show_whi_menu "Workflows & Automation" \
            "n8n"       "$n8_bull n8n — Automation Server" \
            "paperclip" "$pc_bull Paperclip — Workflow Server (⚠️ 2GB+ RAM)" \
            "gcp"       "☁ GCP Bridge (SSH Tunnel for n8n)" \
            "back"      "← Back to Main Menu") || :
        case "$choice" in
            n8n)       install_n8n ;;
            paperclip) install_paperclip ;;
            gcp)       setup_n8n_gcp ;;
            back|*)    return ;;
        esac
    done
}

menu_utilities() {
    while true; do
        local gm_bull="○" pi_bull="○"
        is_installed "gemini-cli" && gm_bull="●"
        is_installed "@mariozechner/pi-coding-agent" && pi_bull="●"
        local choice
        choice=$(show_whi_menu "Developer Utilities" \
            "gemini" "$gm_bull Gemini CLI (Google AI)" \
            "pi"     "$pi_bull Pi — Coding Agent by Mario Zechner (Recommended)" \
            "back"   "← Back to Main Menu") || return
        case "$choice" in
            gemini) install_gemini_cli ;;
            pi)     install_pi ;;
            back|*)  return ;;
        esac
    done
}

menu_services() {
    while true; do
        local pm2_bull="○" sv_bull="○"
        command -v pm2 >/dev/null 2>&1 && pm2_bull="●"
        [ -d "$SERVICE_DIR" ] && sv_bull="●"
        local choice
        choice=$(show_whi_menu "System & Background Services" \
            "pm2"    "$pm2_bull PM2 Process Management" \
            "native" "$sv_bull Native Background Services" \
            "back"   "← Back to Main Menu") || return
        case "$choice" in
            pm2)    manage_pm2 ;;
            native) manage_service ;;
            back|*) return ;;
        esac
    done
}

menu_uninstall() {
    while true; do
        local choice
        choice=$(show_whi_menu "Uninstall Software" \
            "openclaw" "Remove OpenClaw" \
            "n8n"      "Remove n8n" \
            "gemini"   "Remove Gemini CLI" \
            "hermes"   "Remove Hermes" \
            "ollama"   "Remove Ollama" \
            "pi"       "Remove Pi" \
            "paperclip" "Remove Paperclip" \
            "nanobot"  "Remove Nanobot" \
            "wipe"     "Wipe Software Stack (Reset)" \
            "back"     "Back to Main Menu") || return
        case "$choice" in
            openclaw)
                whiptail_confirm "This will remove the OpenClaw global package and background services." && { uninstall_openclaw; whiptail_msg "OpenClaw removed."; } ;;
            n8n)
                whiptail_confirm "This will remove n8n and its watchdog." && { uninstall_n8n; whiptail_msg "n8n removed."; } ;;
            gemini)
                whiptail_confirm "This will remove the Gemini CLI global package." && { uninstall_gemini; whiptail_msg "Gemini CLI removed."; } ;;
            hermes)
                whiptail_confirm "This will remove the Hermes agent installation." && { uninstall_hermes; whiptail_msg "Hermes removed."; } ;;
            ollama)
                whiptail_confirm "This will remove Ollama and downloaded models." && { uninstall_ollama; whiptail_msg "Ollama removed."; } ;;
            pi)
                whiptail_confirm "This will remove the Pi Coding Agent." && { uninstall_pi; whiptail_msg "Pi removed."; } ;;
            paperclip)
                whiptail_confirm "Paperclip soft-uninstall preserves source code and database. For deep uninstall (wipe everything), use UNINSTALL -> Wipe Software Stack." && { uninstall_paperclip; whiptail_msg "Paperclip removed (soft)."; } ;;
            nanobot)
                whiptail_confirm "This will remove Nanobot AI." && { uninstall_nanobot; whiptail_msg "Nanobot AI removed."; } ;;
            wipe)
                whiptail_confirm "This will WIPE ALL applications and data. Core system packages are NOT removed." && { full_cleanup; whiptail_msg "All toolkit software removed."; } ;;
            back|*) return ;;
        esac
    done
}

check_termux
ensure_deps

while true; do
    choice=$(show_whi_menu "Main Menu" \
        "AGENTS"     "🤖 AI Agents & LLMs" \
        "WORKFLOWS"  "⚙️ Workflows & Automation" \
        "UTILITIES"  "🛠 Developer Utilities" \
        "SERVICES"   "🔧 System & Background Services" \
        "UNINSTALL"  "🗑  Uninstall Software") || exit 0
    case "$choice" in
        AGENTS)     menu_agents ;;
        WORKFLOWS)  menu_workflows ;;
        UTILITIES)  menu_utilities ;;
        SERVICES)   menu_services ;;
        UNINSTALL)  menu_uninstall ;;
        *)          exit 0 ;;
    esac
done
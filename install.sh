#!/bin/bash

# ==============================================================================
# 🦞 OPENCLAW ANDROID TOOLKIT (Termux)
# Version: 1.8.1
# Purpose: Dynamic memory guarding and latest version support.
# ==============================================================================

set -e

# --- 1. COLORS & GLOBALS ---
VERSION="1.8.1"
ARCH_TYPE=$(uname -m)
GREEN=$(printf '\033[0;32m')
BLUE=$(printf '\033[0;34m')
YELLOW=$(printf '\033[1;33m')
RED=$(printf '\033[0;31m')
NC=$(printf '\033[0m')
CLEAR_LINE=$(printf '\033[K')

# Termux dynamically exports $PREFIX. Fallback just in case.
PREFIX=${PREFIX:-"/data/data/com.termux/files/usr"}

LOG_FILE="$HOME/openclaw_install.log"
TOOLKIT_CONFIG="$HOME/.openclaw/.toolkit_config"
OPENCLAW_ROOT="$PREFIX/lib/node_modules/openclaw"
SERVICE_DIR="$PREFIX/var/service/openclaw"
N8N_SERVICE_DIR="$PREFIX/var/service/n8n"
TERMUX_BIN="$PREFIX/bin"

# Force correct npm path for the current session
export npm_execpath="$TERMUX_BIN/npm"

# --- 2. HELPER FUNCTIONS ---

status_msg() { echo -ne "\r${CLEAR_LINE}${BLUE}==>${NC} $1... "; }
error_msg() { echo -e "\r${CLEAR_LINE}${RED}Error:${NC} $1"; }
success_msg() { echo -e "${GREEN}Done.${NC}"; }
wait_to_continue() { read -p "$(printf "\n${BLUE}>>${NC} Press Enter to continue...")" junk; }

ensure_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        status_msg "Installing required toolkit dependencies (jq)"
        pkg update -y >/dev/null 2>&1 || true
        pkg install -y jq >/dev/null 2>&1
        success_msg
    fi
}

# Persistence Helpers
set_config() {
    local key=$1
    local value=$2
    mkdir -p "$(dirname "$TOOLKIT_CONFIG")"
    if [ ! -f "$TOOLKIT_CONFIG" ]; then echo "{}" > "$TOOLKIT_CONFIG"; fi
    local tmp=$(mktemp)
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

get_global_node_path() {
    local node_path="$PREFIX/lib/node_modules"
    if command -v pnpm >/dev/null 2>&1; then
        local pnpm_root
        pnpm_root=$(pnpm root -g 2>/dev/null || true)
        if [ -n "$pnpm_root" ]; then
            node_path="$node_path:$pnpm_root"
        fi
    fi
    echo "$node_path"
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
        global_root=$(pnpm root -g 2>/dev/null || echo "$global_root")
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
        if [ -d "$(pnpm root -g 2>/dev/null)/$tool_name" ]; then
            set_config "$config_key" "pnpm"; echo "pnpm"; return
        fi
    fi

    echo "none"
}

select_package_manager() {
    local tool_name=$1
    local detected=$(detect_package_manager "$tool_name")

    if [ "$detected" != "none" ]; then echo "$detected"; return; fi

    echo -e "\n${BLUE}Select Package Manager for $tool_name:${NC}" >&2
    echo "1) npm (Standard)" >&2
    echo "2) pnpm (Fast/Efficient)" >&2
    echo "3) Back" >&2
    read -p "$(printf "${BLUE}>>${NC} Select Option [1-3]: ")" PM_CHOICE

    case $PM_CHOICE in
        1) set_config "pm_$tool_name" "npm"; echo "npm" ;;
        2) 
            if ! command -v pnpm >/dev/null 2>&1; then
                execute "npm install -g pnpm" "Installing pnpm"
            fi
            set_config "pm_$tool_name" "pnpm"; echo "pnpm" 
            ;;
        *) echo "back" ;;
    esac
}

get_openclaw_root() {
    local pm=$1
    if [ "$pm" == "pnpm" ] && command -v pnpm >/dev/null 2>&1; then
        echo "$(pnpm root -g)/openclaw"
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
    local tmp_log=$(mktemp)
    
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
        printf "\r${CLEAR_LINE}${BLUE}==>${NC} %s %s\n" "$msg" "${GREEN}Done.${NC}"
    else
        printf "\r${CLEAR_LINE}${BLUE}==>${NC} %s %s\n" "$msg" "${RED}Failed!${NC}"
        echo -e "\n${RED}Error details for this step:${NC}"
        tail -n 15 "$tmp_log"
        echo -e "\n${YELLOW}Full log available at: $LOG_FILE${NC}"
        rm -f "$tmp_log"
        exit 1
    fi
    rm -f "$tmp_log"
}

check_termux() {
    if ! command -v termux-setup-storage >/dev/null 2>&1; then
        error_msg "This script must be run inside Termux on Android."
        exit 1
    fi
}

# --- 3. OPENCLAW INSTALLATION ---

install_openclaw() {
    local mode="repair"
    local target_version="latest"

    if is_installed "openclaw"; then
        echo -e "\n${YELLOW}🦞 OpenClaw is already installed.${NC}"
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
        smart_pkg_install tur-repo build-essential libvips openssh git python3 pkg-config tmux binutils termux-services ffmpeg golang nodejs-22 psmisc

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
            execute "NODE_LLAMA_CPP_SKIP_DOWNLOAD=true npm install -g openclaw@$target_version --unsafe-perm --ignore-scripts --silent" "Installing OpenClaw v$target_version via npm"
        else
            execute "NODE_LLAMA_CPP_SKIP_DOWNLOAD=true pnpm add -g openclaw@$target_version --ignore-scripts --force" "Installing OpenClaw v$target_version via pnpm"
        fi
    fi

    ensure_peer_deps "$PKG_MANAGER"
    ensure_openclaw_runtime_modules "$PKG_MANAGER"
    apply_patches
    
    CONFIG_PATH="$HOME/.openclaw/openclaw.json"
    status_msg "Initializing environment"
    mkdir -p "$HOME/.openclaw/workspace/memory" "$HOME/.openclaw/workspace/skills"
    
    if [ ! -f "$CONFIG_PATH" ]; then
        yes "" | openclaw doctor >> "$LOG_FILE" 2>&1 || true
    fi

    if [ -f "$CONFIG_PATH" ]; then
        status_msg "Optimizing plugin configuration"
        tmp_cfg=$(mktemp)
        # 1. Enable standard channels
        # 2. Set Termux environment and performance flags
        # 3. PURGE conflicting local installs/paths
        # 4. Remove schema-invalid and legacy keys before doctor --fix
        jq '.plugins.entries.telegram.enabled = true | 
            .plugins.entries.whatsapp.enabled = true | 
            .plugins.entries.slack.enabled = true |
            .env.PATH = "'"$PREFIX"'/bin:/bin" |
            .env.NODE_OPTIONS = "--dns-result-order=ipv4first" |
            .env.OPENCLAW_TMP = "'"$HOME"'/.openclaw/tmp" |
            del(.sidecars, .paths) |
            del(.plugins.installs[]? | select(. == "telegram" or . == "whatsapp" or . == "slack")) |
            (.plugins.load.paths // []) |= map(select(test("/extensions/(telegram|whatsapp|slack)$") | not)) |
            del(.channels.telegram.streamMode, .channels.telegram.chunkMode, .channels.telegram.blockStreaming, .channels.telegram.draftChunk, .channels.telegram.blockStreamingCoalesce) |
            del(.channels.slack.streamMode, .channels.slack.chunkMode, .channels.slack.blockStreaming, .channels.slack.blockStreamingCoalesce, .channels.slack.nativeStreaming) |
            if (.channels.telegram.streaming? | type) != "object" then del(.channels.telegram.streaming) else . end |
            if (.channels.slack.streaming? | type) != "object" then del(.channels.slack.streaming) else . end' "$CONFIG_PATH" > "$tmp_cfg" && mv "$tmp_cfg" "$CONFIG_PATH"
        
        # 4. Automated Migration: Fix legacy keys and validate schema
        yes "" | openclaw doctor --fix >> "$LOG_FILE" 2>&1 || true
        success_msg
    fi
    if [[ "$mode" == "full" ]]; then
        apply_patches "silent"
    fi
    
    echo -e "\n${GREEN}✅ OpenClaw successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed") and patched!${NC}"
    echo -e "\n${YELLOW}⚠️  NEXT STEPS:${NC}"
    echo -e "1. Run ${GREEN}openclaw onboard${NC} to configure your API keys."
    echo -e "2. Use ${BLUE}Option 5${NC} (Recommended) or ${BLUE}Option 6${NC} to configure background services."
    echo -e "\n${RED}🛑 DO NOT USE 'openclaw update'${NC}"
    echo -e "   This will break patches. Use Option 1 of this script to update."
    wait_to_continue
}

apply_patches() {
    local silent=$1
    [[ "$silent" != "silent" ]] && echo -e "\n${BLUE}🩹 Applying Android compatibility patches:${NC}"

    # 1. Koffi Patch
    KOFFI_SRC="$OPENCLAW_ROOT/node_modules/koffi/lib/native/base/base.cc"
    if [ -f "$KOFFI_SRC" ] && [[ "$silent" != "silent" ]]; then
        execute "sed -i 's/renameat2(AT_FDCWD, src_filename, AT_FDCWD, dest_filename, RENAME_NOREPLACE)/rename(src_filename, dest_filename)/g' '$KOFFI_SRC'" "Patching Koffi native library"
        execute "cd '$OPENCLAW_ROOT/node_modules/koffi' && JOBS=1 MAKEFLAGS='-j1' node src/cnoke/cnoke.js -p . -d src/koffi --prebuild" "Rebuilding Koffi"
        
        K_TRIPLET="android_armsf"
        [[ "$ARCH_TYPE" == "aarch64" ]] && K_TRIPLET="android_arm64"
        execute "mkdir -p '$K_TRIPLET' && cp 'build/koffi/$K_TRIPLET/koffi.node' '$K_TRIPLET/'" "Mapping Koffi binary"
    fi

    # 2. Path & System Redirection (Combined optimized grep + sed)
    local msg="Optimizing internal paths"
    [[ "$silent" == "silent" ]] && msg="Finalizing environment paths"
    execute "grep -rlE '/tmp/openclaw|/usr/bin/npm|/bin/npm|/usr/bin/node|/bin/node' '$OPENCLAW_ROOT' '$HOME/.openclaw' 2>/dev/null | xargs -I {} sed -i 's|/tmp/openclaw|$HOME/.openclaw/tmp|g; s|/usr/bin/npm|$TERMUX_BIN/npm|g; s|/bin/npm|$TERMUX_BIN/npm|g; s|/usr/bin/node|$TERMUX_BIN/node|g; s|/bin/node|$TERMUX_BIN/node|g' {} || true" "$msg"
}

# --- 4. GEMINI CLI INSTALLATION ---

install_gemini_cli() {
    local mode="full"
    if is_installed "@google/gemini-cli"; then
        echo -e "\n${YELLOW}✨ Gemini CLI is already installed.${NC}"
        echo "1) [R] Repair Environment (Fast)"
        echo "2) [U] Update to Latest (Full)"
        echo "3) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-3]: ")" REPAIR_CHOICE
        case $REPAIR_CHOICE in
            1) mode="repair" ;;
            2) mode="full" ;;
            *) return 0 ;;
        esac
    else
        confirm_action "Setup Gemini CLI" || return 0
    fi

    echo -e "\n${BLUE}✨ $([[ "$mode" == "repair" ]] && echo "Repairing" || echo "Setting up") Gemini CLI...${NC}"

    status_msg "Stopping existing tasks & freeing memory"
    command -v pm2 >/dev/null 2>&1 && pm2 kill >> "$LOG_FILE" 2>&1 || true
    success_msg

    if [[ "$mode" == "full" ]]; then
        smart_pkg_install python make clang pkg-config
    fi

    PKG_MANAGER=$(select_package_manager "@google/gemini-cli")
    [[ "$PKG_MANAGER" == "back" ]] && return 0
    
    status_msg "Setting NDK environment"
    export npm_config_android_ndk_path=$PREFIX
    export ANDROID_NDK_HOME=$PREFIX
    export ANDROID_NDK_ROOT=$PREFIX
    success_msg

    if [[ "$mode" == "full" ]]; then
        local gemini_root=""
        if [ "$PKG_MANAGER" == "pnpm" ]; then
            gemini_root="$(pnpm root -g 2>/dev/null)/@google/gemini-cli"
        else
            gemini_root="$(npm root -g 2>/dev/null)/@google/gemini-cli"
        fi
        
        status_msg "Preparing clean slate"
        rm -rf "$gemini_root"
        success_msg

        if [ "$PKG_MANAGER" == "npm" ]; then
            execute "npm i -g @google/gemini-cli@latest" "Installing @google/gemini-cli via npm"
        else
            execute "pnpm add -g @google/gemini-cli@latest --force" "Installing @google/gemini-cli via pnpm"
        fi
    fi
    
    if command -v gemini >/dev/null 2>&1 || command -v gemini-cli >/dev/null 2>&1; then
        status_msg "Initializing Gemini environment"
        mkdir -p "$HOME/.gemini"
        
        # Patch for Android rename bug (ENOENT during projects.json save)
        local gemini_root=""
        if [ "$PKG_MANAGER" == "pnpm" ]; then
            gemini_root=$(pnpm root -g 2>/dev/null | sed 's|node_modules$|.pnpm|')
        else
            gemini_root=$(npm root -g 2>/dev/null)
        fi

        if [ -n "$gemini_root" ]; then
            # Surgically find the projectRegistry.js and patch async rename calls
            # Uses regex to preserve variable names (e.g., tmpPath, registryPath)
            find -L "$gemini_root" -type f -name "projectRegistry.js" -exec sed -i 's|await fs.promises.rename(\([^,]*\), \([^)]*\))|await fs.promises.copyFile(\1, \2); await fs.promises.unlink(\1)|g' {} + 2>/dev/null || true
        fi
        success_msg

        echo -e "${GREEN}\n✅ Gemini CLI successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed")!${NC}"
        echo -e "You can now run: ${BLUE}gemini --help${NC}"
    else
        error_msg "Installation finished but 'gemini' command not found in PATH."
    fi
    wait_to_continue
}

# --- 5. N8N INSTALLATION ---

install_n8n() {
    local mode="full"
    if is_installed "n8n"; then
        echo -e "\n${YELLOW}📱 n8n is already installed.${NC}"
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

    echo -e "\n${BLUE}📱 $([[ "$mode" == "repair" ]] && echo "Repairing" || echo "Setting up") n8n Android Infrastructure...${NC}"

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
            n8n_root="$(pnpm root -g 2>/dev/null)/n8n"
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
    
    echo -e "\n${YELLOW}🧠 MEMORY ALLOCATION:${NC}"
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
    echo "[$(date)] 🚀 n8n not found. Restarting..." >> "$LOG_FILE"
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

    echo -e "\n${GREEN}✅ n8n successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed")!${NC}"
    echo -e "\n${YELLOW}⚠️  NEXT STEPS:${NC}"
    echo -e "1. Use ${BLUE}Option 5${NC} (Recommended) or ${BLUE}Option 6${NC} to configure background services."
    wait_to_continue
}

# --- 6. GCP BRIDGE SETUP ---

setup_n8n_gcp() {
    confirm_action "Configure GCP Bridge" || return 0
    echo -e "\n${BLUE}🌐 GCP BRIDGE (SSH TUNNEL) CONFIGURATION${NC}"
    
    while true; do read -p "Enter GCP VM Public IP: " GCP_IP; [[ "$GCP_IP" =~ ^[0-9.]+$ ]] && break; echo "Invalid IP."; done
    while true; do read -p "Enter GCP SSH Username: " GCP_USER; [[ "$GCP_USER" =~ ^[a-z0-9_-]+$ ]] && break; echo "Invalid user."; done
    while true; do read -p "Enter Public Domain: " GCP_DOMAIN; [[ "$GCP_DOMAIN" =~ ^[a-z0-9.-]+$ ]] && break; echo "Invalid domain."; done

    sed -i "s/N8N_PROTOCOL=http/N8N_PROTOCOL=https/g; s|N8N_HOST=.*|N8N_HOST=$GCP_DOMAIN|g" "$HOME/n8n_server/config/n8n.env"
    echo 'TUNNEL_CMD="autossh -M 0 -N -o \"StrictHostKeyChecking=no\" -R 5678:localhost:5678 '"$GCP_USER@$GCP_IP"'"' > "$HOME/n8n_server/config/tunnel.conf"

    if [ ! -f "$HOME/.ssh/id_rsa" ]; then
        status_msg "Generating SSH key"
        ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N "" >/dev/null 2>&1
        success_msg
    fi

    echo -e "\n${YELLOW}1. Copy this key to your GCP VM (~/.ssh/authorized_keys):${NC}"
    cat "$HOME/.ssh/id_rsa.pub"
    echo -e "\n${YELLOW}2. Run the monitor to start the tunnel:${NC} ~/n8n_server/scripts/n8n-monitor.sh"
    wait_to_continue
}

# --- 7. SERVICE MANAGEMENT ---

manage_service() {
    while true; do
        echo -e "\n${BLUE}⚙️  BACKGROUND SERVICE MANAGEMENT${NC}"
        echo "1) OpenClaw: Enable/Setup Service"
        echo "2) OpenClaw: Disable/Remove Service"
        echo "3) n8n: Enable/Setup Native Service"
        echo "4) n8n: Disable/Remove Native Service"
        echo "5) Back to Main Menu"
        read -p "Select option [1-5]: " SVC_CHOICE

        case $SVC_CHOICE in
            1) confirm_action "setup background service" && { setup_service_files; wait_to_continue; } ;;
            2) confirm_action "remove background service" && { remove_service_files; wait_to_continue; } ;;
            3) confirm_action "setup n8n native service" && { setup_n8n_service_files; wait_to_continue; } ;;
            4) confirm_action "remove n8n native service" && { remove_n8n_service_files; wait_to_continue; } ;;
            *) return ;;
        esac
    done
}

setup_service_files() {
    if [ ! -f "$TERMUX_BIN/openclaw" ]; then error_msg "OpenClaw is not installed."; return; fi
    status_msg "Creating OpenClaw service files"
    mkdir -p "$SERVICE_DIR/log" "$HOME/.openclaw/logs"

cat <<EOF > "$SERVICE_DIR/run"
#!/bin/bash
termux-wake-lock
export TERMUX_BIN='$TERMUX_BIN'
export PATH="\$TERMUX_BIN:\$PATH"
export npm_execpath="\$TERMUX_BIN/npm"
PNPM_NODE_PATH=""
if command -v pnpm >/dev/null 2>&1; then
    PNPM_NODE_PATH="\$(pnpm root -g 2>/dev/null)"
fi
export NODE_PATH="$PREFIX/lib/node_modules\${PNPM_NODE_PATH:+:\$PNPM_NODE_PATH}"
export HOME='$HOME'
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
    while true; do
        echo -e "\n${BLUE}🚀 PM2 PROCESS MANAGEMENT${NC}"
        echo "1) Install/Update PM2"
        echo "2) Start OpenClaw with PM2"
        echo "3) Start n8n with PM2"
        echo "4) View Logs (Live)"
        echo "5) View Status (Table)"
        echo "6) Restart/Save All"
        echo "7) Stop/Kill PM2"
        echo "8) Back to Main Menu"
        read -p "Select option [1-8]: " PM2_CHOICE

        case $PM2_CHOICE in
            1) execute "npm install -g pm2" "Installing PM2 Globally" ;;
            2)
                if command -v openclaw >/dev/null 2>&1; then
                    status_msg "Clearing ports and stale processes"
                    pm2 delete openclaw 2>/dev/null || true
                    pkill -9 -f openclaw 2>/dev/null || true
                    rm -f "$HOME/.openclaw/tmp/openclaw.lock"
                    success_msg
                    PNPM_NODE_PATH=$(pnpm root -g 2>/dev/null || true)
                    execute "sleep 5; NODE_PATH=\"$PREFIX/lib/node_modules${PNPM_NODE_PATH:+:$PNPM_NODE_PATH}\" npm_execpath='$TERMUX_BIN/npm' PATH='$TERMUX_BIN:\$PATH' pm2 start \"openclaw gateway run\" --name openclaw --interpreter none && pm2 save" "Starting OpenClaw in PM2 (Clean Start)"
                else
                    error_msg "OpenClaw missing."
                fi
                wait_to_continue ;;

            3) 
                if command -v n8n >/dev/null 2>&1; then
                    local n8n_env=""
                    [ -f "$HOME/n8n_server/config/n8n.env" ] && n8n_env="--env '$HOME/n8n_server/config/n8n.env'"
                    execute "pkill -9 -f n8n 2>/dev/null || true; sleep 2; pm2 start n8n --name n8n $n8n_env --interpreter none && pm2 save" "Starting n8n in PM2"
                else
                    error_msg "n8n missing."
                fi
                wait_to_continue ;;
            4) pm2 logs ;;
            5) pm2 status; wait_to_continue ;;
            6) execute "pm2 stop all; pkill -9 -f 'openclaw|n8n' 2>/dev/null || true; sleep 2; pm2 start all && pm2 save" "Restarting all processes safely" ;;
            7) execute "pm2 kill" "Stopping PM2" ;;
            *) return ;;
        esac
    done
}

# --- 8. UNINSTALLATION LOGIC ---

uninstall_menu() {
    while true; do
        echo -e "\n${RED}⚠️  UNINSTALLATION MENU${NC}"
        echo "1) Remove OpenClaw only"
        echo "2) Remove Gemini CLI only"
        echo "3) Remove n8n only"
        echo "4) Wipe Software Stack (Reset)"
        echo "5) Back to Main Menu"
        read -p "Select option [1-5]: " UN_CHOICE

        case $UN_CHOICE in
            1) 
                echo -e "\n${YELLOW}This will remove:${NC}"
                echo -e "- OpenClaw global package and background services."
                echo -e "- Choice of preserving or wiping memories/skills."
                confirm_action "uninstall OpenClaw" && { uninstall_openclaw; wait_to_continue; } 
                ;;
            2) 
                echo -e "\n${YELLOW}This will remove:${NC}"
                echo -e "- Gemini CLI global package."
                confirm_action "uninstall Gemini CLI" && { uninstall_gemini; wait_to_continue; } 
                ;;
            3) 
                echo -e "\n${YELLOW}This will remove:${NC}"
                echo -e "- n8n global package and background watchdog."
                echo -e "- All n8n configurations and local database files."
                confirm_action "uninstall n8n" && { uninstall_n8n; wait_to_continue; } 
                ;;
            4) 
                echo -e "\n${RED}🔥 RESET: This will wipe all three applications:${NC}"
                echo -e "- OpenClaw, n8n, and Gemini CLI."
                echo -e "- All memories, skills, and configurations."
                echo -e "${BLUE}Note: Core system packages (Node.js, FFmpeg, etc.) are NOT removed.${NC}"
                confirm_action "WIPE ALL SOFTWARE" && { full_cleanup; wait_to_continue; } 
                ;;
            *) return ;;
        esac
    done
}

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
        echo -ne "\n${YELLOW}⚠️  DATA PRESERVATION:${NC}\n1) Soft Uninstall (Keep plugins/memory)\n2) Deep Uninstall (Wipe everything)\n"
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

    
    crontab -l 2>/dev/null | grep -v "n8n-monitor.sh" | crontab - || true
    
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
    uninstall_gemini
    uninstall_n8n
    echo -e "\n${GREEN}✅ Toolkit software removed. System dependencies were kept intact.${NC}"
}

# --- 9. MAIN MENU ---

show_menu() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       🦞 OPENCLAW ANDROID TOOLKIT v$VERSION        ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo -e "1) ${GREEN}Install/Repair${NC} OpenClaw"
    echo -e "2) ${YELLOW}Install/Repair${NC} Gemini CLI"
    echo -e "3) ${BLUE}Install/Repair${NC} n8n Server"
    echo -e "4) ${YELLOW}Configure${NC} GCP Bridge (for n8n)"
    echo -e "5) ${YELLOW}Manage${NC} PM2 Processes (Recommended)"
    echo -e "6) ${BLUE}Manage${NC} Background Services (Native)"
    echo -e "7) ${RED}Uninstall${NC} Software"
    echo -e "8) Exit"
    echo -e "${BLUE}====================================================${NC}"
}

check_termux
ensure_jq

while true; do
    show_menu
    read -p "What would you like to do? [1-8]: " MAIN_CHOICE

    case $MAIN_CHOICE in
        1) install_openclaw ;;
        2) install_gemini_cli ;;
        3) install_n8n ;;
        4) setup_n8n_gcp ;;
        5) manage_pm2 ;;
        6) manage_service ;;
        7) uninstall_menu ;;
        8) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done

#!/bin/bash

# ==============================================================================
# 🤖 DROID AI TOOLKIT (Termux)
# Version: 1.10.0
# Purpose: Install and manage AI tools (OpenClaw, Gemini CLI, n8n, Ollama,
#          Hermes, Paperclip) on Android via Termux with kernel patches and path fixes.
# ==============================================================================

set -e

# --- 1. COLORS & GLOBALS ---
VERSION="1.10.0"
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
        echo -e "\n${YELLOW}🤖 OpenClaw is already installed.${NC}"
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
    
    SAFE_LIMIT=$(get_mem_limit)
    CONFIG_PATH="$HOME/.openclaw/openclaw.json"
    status_msg "Initializing environment (Limit: ${SAFE_LIMIT}MB)"
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
            .env.NODE_OPTIONS = "--dns-result-order=ipv4first --max-old-space-size='"$SAFE_LIMIT"'" |
            .env.OPENCLAW_TMP = "'"$HOME"'/.openclaw/tmp" |
            del(.sidecars, .paths, .plugins.meta) |
            (.plugins.installs // []) |= map(select(. != "telegram" and . != "whatsapp" and . != "slack")) |
            (.plugins.load.paths // []) |= map(select(test("/extensions/(telegram|whatsapp|slack)$") | not)) |
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

# --- 7. OLLAMA INSTALLATION ---

install_ollama() {
    if command -v ollama >/dev/null 2>&1; then
        echo -e "\n${YELLOW}🦙 Ollama is already installed.${NC}"
        echo "1) [R] Reinstall / Repair"
        echo "2) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-2]: ")" OL_CHOICE
        case $OL_CHOICE in
            1) ;;
            *) return 0 ;;
        esac
    else
        confirm_action "Install Ollama" || return 0
    fi

    echo -e "\n${BLUE}🦙 Installing Ollama...${NC}"

    smart_pkg_install ollama

    if command -v ollama >/dev/null 2>&1; then
        echo -e "\n${GREEN}✅ Ollama successfully installed!${NC}"
        echo -e "Start the server: ${BLUE}ollama serve${NC}"
        echo -e "Pull a model:      ${BLUE}ollama pull llama3${NC}"
        echo -e "Run a model:       ${BLUE}ollama run llama3${NC}"
    else
        error_msg "Installation finished but 'ollama' command not found in PATH."
    fi
    wait_to_continue
}

# --- 8. HERMES INSTALLATION ---

install_hermes() {
    local mode="install"
    if command -v hermes >/dev/null 2>&1 || [ -f "$HOME/.hermes/bin/hermes" ]; then
        echo -e "\n${YELLOW}⚡ Hermes is already installed.${NC}"
        echo "1) [R] Reinstall"
        echo "2) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-2]: ")" HM_CHOICE
        case $HM_CHOICE in
            1) mode="reinstall" ;;
            *) return 0 ;;
        esac
    else
        confirm_action "Install Hermes Agent" || return 0
    fi

    echo -e "\n${BLUE}⚡ ${mode^}ing Hermes Agent...${NC}"

    # Pre-install build dependencies that upstream often fails on
    smart_pkg_install python clang rust make pkg-config libffi openssl binutils

    # Deep clean on reinstall to avoid partial/corrupted state
    if [ "$mode" == "reinstall" ]; then
        status_msg "Removing old Hermes installation"
        pkill -9 -f hermes 2>/dev/null || true
        rm -rf "$HOME/.hermes"
        success_msg
    fi

    # Set Rust/Cargo environment for low-RAM Termux builds
    export CARGO_BUILD_JOBS=1
    export CARGO_NET_GIT_FETCH_WITH_CLI=true
    export RUSTFLAGS="-C opt-level=2"

    # Run upstream installer without strict execute wrapper to allow graceful fallback
    local hermes_tmp_log=$(mktemp)
    local hermes_exit=0
    status_msg "Running Hermes upstream installer"
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash > "$hermes_tmp_log" 2>&1 || hermes_exit=$?
    cat "$hermes_tmp_log" >> "$LOG_FILE"

    if [ $hermes_exit -eq 0 ]; then
        success_msg
    else
        printf "\r${CLEAR_LINE}${YELLOW}⚠️  Hermes installer exited with warnings.${NC}\n"
        echo -e "${BLUE}Attempting manual fallback installation...${NC}"
        tail -n 20 "$hermes_tmp_log"
    fi
    rm -f "$hermes_tmp_log"

    # Fallback: try manual pip install if upstream left a partial source checkout
    if [ -d "$HOME/.hermes/hermes-agent" ] && { [ ! -f "$HOME/.hermes/bin/hermes" ] || [ $hermes_exit -ne 0 ]; }; then
        status_msg "Attempting manual Python package fallback"
        local venv_path="$HOME/.hermes/hermes-agent/venv"
        if [ -f "$venv_path/bin/pip" ]; then
            "$venv_path/bin/pip" install --upgrade pip wheel setuptools --quiet 2>>"$LOG_FILE" || true
            # Prefer pre-built binary wheels where available to skip Rust compilation
            "$venv_path/bin/pip" install jiter pydantic-core --prefer-binary --quiet 2>>"$LOG_FILE" || true
            # Retry with Termux-specific constraints
            if [ -f "$HOME/.hermes/hermes-agent/constraints-termux.txt" ]; then
                "$venv_path/bin/pip" install -e "$HOME/.hermes/hermes-agent[termux]" \
                    -c "$HOME/.hermes/hermes-agent/constraints-termux.txt" >> "$LOG_FILE" 2>&1 || true
            fi
        fi
        success_msg
    fi

    # Verify final installation
    local hermes_final_path=""
    hermes_final_path=$(type -P hermes 2>/dev/null || true)
    if [ -z "$hermes_final_path" ] && [ -f "$HOME/.hermes/bin/hermes" ]; then
        hermes_final_path="$HOME/.hermes/bin/hermes"
    fi

    if [ -n "$hermes_final_path" ] && [ -x "$hermes_final_path" ]; then
        echo -e "\n${GREEN}✅ Hermes successfully ${mode}ed!${NC}"
        echo -e "Path: ${BLUE}$hermes_final_path${NC}"
        echo -e "Run:  ${BLUE}hermes${NC}"
    else
        echo -e "\n${YELLOW}⚠️  Hermes installation incomplete.${NC}"
        echo -e "${BLUE}Debugging steps:${NC}"
        echo -e "1. Check upstream errors: ${YELLOW}tail -n 50 $LOG_FILE${NC}"
        echo -e "2. Manual retry: ${BLUE}cd ~/.hermes/hermes-agent \&\& python -m pip install -e '.[termux]' -c constraints-termux.txt${NC}"
        echo -e "3. Ensure Rust works:      ${YELLOW}rustc --version${NC}"
    fi

    wait_to_continue
}

# --- 8.5. PAPERCLIP INSTALLATION (EXPERIMENTAL) ---

install_paperclip() {
    local mode="full"
    if [ -d "$HOME/paperclip" ] && [ -f "$HOME/paperclip/server/dist/index.js" ]; then
        echo -e "\n${YELLOW}📎 Paperclip is already installed.${NC}"
        echo "1) [R] Repair Config / Rebuild (Fast)"
        echo "2) [U] Update to Latest (Full)"
        echo "3) Back"
        read -p "$(printf "${BLUE}>>${NC} Select option [1-3]: ")" REPAIR_CHOICE
        case $REPAIR_CHOICE in
            1) mode="repair" ;;
            2) mode="full" ;;
            *) return 0 ;;
        esac
    else
        echo -e "\n${YELLOW}⚠️  EXPERIMENTAL: Paperclip requires PostgreSQL, pnpm, and ~2GB RAM.${NC}"
        confirm_action "Install Paperclip (server-only, build from source)" || return 0
    fi

    echo -e "\n${BLUE}📎 $([[ "$mode" == "repair" ]] && echo "Repairing" || echo "Setting up") Paperclip...${NC}"

    status_msg "Stopping existing tasks & freeing memory"
    pkill -9 -f "paperclip" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 delete paperclip >> "$LOG_FILE" 2>&1 || true
    success_msg

    if [[ "$mode" == "full" ]]; then
        # Core deps: PostgreSQL is NON-NEGOTIABLE (embedded-postgres has no Android builds)
        smart_pkg_install tur-repo build-essential python3 postgresql libvips git
        
        # Ensure pnpm
        if ! command -v pnpm >/dev/null 2>&1; then
            execute "npm install -g pnpm@9.15.4" "Installing pnpm (required by Paperclip)"
        fi

        # Node.js link fix (same as OpenClaw/n8n)
        if [ -d "$PREFIX/opt/nodejs-22/bin" ]; then
            NODE_OPT_BIN="$PREFIX/opt/nodejs-22/bin"
            execute "ln -sf '$NODE_OPT_BIN/node' '$TERMUX_BIN/node' && ln -sf '$NODE_OPT_BIN/npm' '$TERMUX_BIN/npm'" "Verifying Node.js links"
        fi
    fi

    if [[ "$mode" == "full" ]]; then
        status_msg "Cloning Paperclip repository"
        rm -rf "$HOME/paperclip"
        execute "git clone https://github.com/paperclipai/paperclip.git '$HOME/paperclip'" "Cloning Paperclip from GitHub"
        success_msg
    fi

    # --- Build from source ---
    status_msg "Installing dependencies (this may take several minutes)"
    cd "$HOME/paperclip"
    
    # Prevent embedded-postgres from breaking the install; we use external Postgres
    export PAPERCLIP_DATABASE_URL="postgres://paperclip:paperclip@localhost:5432/paperclip"
    export DATABASE_URL="$PAPERCLIP_DATABASE_URL"
    
    # Sharp build from source on Android
    export SHARP_IGNORE_GLOBAL_LIBVIPS=1
    
    # Patch out embedded-postgres so pnpm install doesn't fail on missing binary
    if [ -f "$HOME/paperclip/patches/embedded-postgres@18.1.0-beta.16.patch" ]; then
        rm -f "$HOME/paperclip/patches/embedded-postgres@18.1.0-beta.16.patch" 2>/dev/null || true
        # Remove the patchedDependency entry from package.json to avoid pnpm error
        jq 'del(.pnpm.patchedDependencies["embedded-postgres@18.1.0-beta.16"])' package.json > tmp.json && mv tmp.json package.json
    fi
    
    # Remove embedded-postgres from server deps so it isn't installed
    if [ -f "$HOME/paperclip/server/package.json" ]; then
        jq 'del(.dependencies["embedded-postgres"])' server/package.json > tmp.json && mv tmp.json server/package.json
    fi
    
    # The lockfile was generated with embedded-postgres patches; deleting it forces a fresh
    # resolution that matches our patched package.json. We do NOT use --frozen-lockfile here.
    execute "rm -f pnpm-lock.yaml && pnpm install" "Installing Paperclip dependencies"
    success_msg

    status_msg "Building workspace dependencies"
    execute "pnpm --filter @paperclipai/plugin-sdk build && pnpm --filter @paperclipai/db build" "Building Paperclip workspace dependencies"
    success_msg

    status_msg "Patching server tsconfig for Termux compatibility"
    if [ -f "$HOME/paperclip/server/tsconfig.json" ]; then
        jq '.compilerOptions.noImplicitAny = false | .compilerOptions.noEmitOnError = false | .compilerOptions.skipLibCheck = true' "$HOME/paperclip/server/tsconfig.json" > tmp.json && mv tmp.json "$HOME/paperclip/server/tsconfig.json"
    fi
    
    # tsc still exits 2 on type errors; patch the build script so && does not abort
    if [ -f "$HOME/paperclip/server/package.json" ]; then
        jq '.scripts.build |= sub("tsc &&"; "tsc; ")' "$HOME/paperclip/server/package.json" > tmp.json && mv tmp.json "$HOME/paperclip/server/package.json"
    fi
    success_msg

    status_msg "Building Paperclip server"
    execute "pnpm --filter @paperclipai/server build" "Building Paperclip server"
    success_msg

    # --- UI setup ---
    # Vite/esbuild requires ~4-6GB transient RSS to bundle 5,000+ React modules; Android devices with
    # 3-4GB total RAM cannot survive it, even with swap. We download a prebuilt ui-dist tarball
    # built from the identical upstream source to keep the install purely portable.
    status_msg "Fetching prebuilt Paperclip UI assets"
    UI_TARBALL_URL="https://github.com/niyazmft/droid-ai-toolkit/releases/download/v${VERSION}/ui-dist-v${VERSION}.tar.gz"
    UI_TARBALL="$HOME/.paperclip_tmp/ui-dist-v${VERSION}.tar.gz"
    mkdir -p "$HOME/.paperclip_tmp"
    
    if curl -fL --max-time 30 "$UI_TARBALL_URL" -o "$UI_TARBALL" 2>> "$LOG_FILE"; then
        execute "rm -rf '$HOME/paperclip/server/ui-dist' && mkdir -p '$HOME/paperclip/server/ui-dist' && tar -xzf '$UI_TARBALL' -C '$HOME/paperclip/server'" "Extracting prebuilt UI assets"
        rm -f "$UI_TARBALL"
        success_msg
        UI_SETUP_OK=true
    else
        status_msg "Prebuilt tarball unavailable (curl failed — see log). Attempting fallback UI build (this will likely fail on low-RAM devices)"
        swapon -a 2>/dev/null || true
        export NODE_OPTIONS="--max-old-space-size=$SAFE_LIMIT"
        
        # Disable minification before the single attempt to give it the best chance
        sed -i 's/minify: "esbuild"/minify: false/' "$HOME/paperclip/ui/vite.config.ts"
        sed -i '/drop:.*\["console"/d; /legalComments:.*"none"/d' "$HOME/paperclip/ui/vite.config.ts"
        rm -rf "$HOME/paperclip/ui/dist"
        
        if pnpm --filter @paperclipai/ui build >> "$LOG_FILE" 2>&1 && pnpm --filter @paperclipai/server exec pnpm run prepare:ui-dist >> "$LOG_FILE" 2>&1; then
            success_msg
            UI_SETUP_OK=true
        else
            error_msg "UI build failed. Paperclip server is installed but the web UI will not be available."
            echo -e "${YELLOW}The API server is functional. You can still use Paperclip via its REST API.${NC}"
            UI_SETUP_OK=false
        fi
    fi
    
    # --- PostgreSQL setup ---
    status_msg "Configuring PostgreSQL database"
    if ! pg_isready -q 2>/dev/null; then
        pg_ctl -D "$PREFIX/var/lib/postgresql" initdb 2>/dev/null || true
        pg_ctl -D "$PREFIX/var/lib/postgresql" start -l "$HOME/paperclip/postgres.log" 2>/dev/null || true
        sleep 3
    fi
    
    # Create user/db if they don't exist
    psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='paperclip'" 2>/dev/null | grep -q 1 || \
        psql postgres -c "CREATE USER paperclip WITH PASSWORD 'paperclip';" 2>/dev/null || true
    psql postgres -tAc "SELECT 1 FROM pg_database WHERE datname='paperclip'" 2>/dev/null | grep -q 1 || \
        psql postgres -c "CREATE DATABASE paperclip OWNER paperclip;" 2>/dev/null || true
    success_msg

    # --- Environment setup ---
    status_msg "Creating Paperclip environment"
    SAFE_LIMIT=$(get_mem_limit)
    mkdir -p "$HOME/paperclip/config"
    
    local auth_secret="paperclip-dev-secret-$(openssl rand -hex 8)"
    # Preserve existing auth secret across repairs to avoid invalidating sessions
    if [ -f "$HOME/paperclip/config/paperclip.env" ]; then
        local existing_secret
        existing_secret=$(grep '^BETTER_AUTH_SECRET=' "$HOME/paperclip/config/paperclip.env" 2>/dev/null | cut -d= -f2-)
        [ -n "$existing_secret" ] && auth_secret="$existing_secret"
    fi
    
    cat <<EOF > "$HOME/paperclip/config/paperclip.env"
DATABASE_URL=postgres://paperclip:paperclip@localhost:5432/paperclip
PORT=3100
SERVE_UI=true
BETTER_AUTH_SECRET=$auth_secret
NODE_OPTIONS="--max-old-space-size=$SAFE_LIMIT"
PAPERCLIP_HOME=$HOME/paperclip
PAPERCLIP_INSTANCE_ID=default
EOF

    # --- Onboard + LAN configuration ---
    # Paperclip's onboard command writes config.json. Without PAPERCLIP_HOME
    # it writes to ~/.paperclip; we force it to our install directory.
    status_msg "Configuring Paperclip (onboard + LAN bind)"
    cd "$HOME/paperclip"
    export PAPERCLIP_HOME="$HOME/paperclip"
    export DATABASE_URL="postgres://paperclip:paperclip@localhost:5432/paperclip"

    if pnpm paperclipai onboard --yes --bind lan >> "$LOG_FILE" 2>&1; then
        # Patch generated config to use external PostgreSQL (embedded-postgres has no Android build)
        local config_path="$HOME/paperclip/instances/default/config.json"
        if [ -f "$config_path" ]; then
            local device_ip
            device_ip=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1)
            [ -z "$device_ip" ] && device_ip=$(ip addr show eth0 2>/dev/null | grep 'inet ' | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1)

            # Build allowedHostnames array: add device IP if found, plus loopback/localhost
            local hostnames_json='["127.0.0.1","localhost"]'
            [ -n "$device_ip" ] && hostnames_json="[\"127.0.0.1\",\"localhost\",\"$device_ip\"]"

            # Patch database mode and add connection string + LAN settings
            jq --arg connStr "$DATABASE_URL" --argjson hosts "$hostnames_json" \
                '.database.mode = "postgres" |
                 .database.connectionString = $connStr |
                 del(.database.embeddedPostgresDataDir) |
                 del(.database.embeddedPostgresPort) |
                 .server.bind = "lan" |
                 .server.host = "0.0.0.0" |
                 .server.allowedHostnames = $hosts' \
                "$config_path" > tmp.json && mv tmp.json "$config_path"

            # Also mirror the config to ~/.paperclip as fallback (server may resolve either path)
            mkdir -p "$HOME/.paperclip/instances/default"
            cp "$config_path" "$HOME/.paperclip/instances/default/config.json"

            # Copy secrets/env so both homes are consistent
            if [ -f "$HOME/paperclip/instances/default/.env" ]; then
                cp "$HOME/paperclip/instances/default/.env" "$HOME/.paperclip/instances/default/.env" 2>/dev/null || true
            fi
            if [ -f "$HOME/paperclip/instances/default/secrets/master.key" ]; then
                mkdir -p "$HOME/.paperclip/instances/default/secrets"
                cp "$HOME/paperclip/instances/default/secrets/master.key" "$HOME/.paperclip/instances/default/secrets/master.key" 2>/dev/null || true
            fi

            success_msg
            [ -n "$device_ip" ] && echo -e "${GREEN}📡 LAN access enabled: http://$device_ip:3100${NC}"
        else
            warn_msg "onboard succeeded but config.json not found — LAN/DB settings may need manual configuration"
        fi
    else
        warn_msg "onboard command failed (see log). You may need to run 'pnpm paperclipai onboard --bind lan' manually."
    fi
    success_msg

    echo -e "\n${GREEN}✅ Paperclip successfully $([[ "$mode" == "repair" ]] && echo "repaired" || echo "installed")!${NC}"
    echo -e "\n${YELLOW}⚠️  NEXT STEPS:${NC}"
    echo -e "1. Start the server: ${BLUE}cd ~/paperclip && pnpm dev:server${NC}"
    echo -e "2. Or start with PM2: ${BLUE}Option 8${NC} (Recommended for background)"
    echo -e "3. Access locally: ${BLUE}http://localhost:3100${NC}"
    echo -e "4. Access from iPad (same Wi-Fi): ${BLUE}http://<android-ip>:3100${NC}"
    echo -e "\n${RED}🛑 IMPORTANT:${NC}"
    if [ "${UI_SETUP_OK:-false}" != true ]; then
        echo -e "   ${YELLOW}⚠️ UI assets are MISSING. The API works, but the web dashboard is not available.${NC}"
        echo -e "   To fix, upload 'ui-dist-v${VERSION}.tar.gz' to the GitHub release and re-run repair."
    fi
    echo -e "   Keep PostgreSQL running: ${BLUE}pg_ctl -D \$PREFIX/var/lib/postgresql start${NC}"
    echo -e "   This is EXPERIMENTAL. Report issues upstream: github.com/paperclipai/paperclip"
    wait_to_continue
    cd - >/dev/null 2>&1 || true
}

# --- 9. SERVICE MANAGEMENT ---

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
    if ! command -v pm2 >/dev/null 2>&1; then
        confirm_action "Install PM2 first" || return 0
        execute "npm install -g pm2" "Installing PM2 Globally"
    fi
    while true; do
        echo -e "\n${BLUE}🚀 PM2 PROCESS MANAGEMENT${NC}"
        echo -e "${BLUE}── Start Services ──────────────${NC}"
        echo "1) Start OpenClaw"
        echo "2) Start n8n"
        echo "3) Start Hermes"
        echo "4) Start Ollama"
        echo "5) Start Paperclip"
        echo -e "${BLUE}── Manage ─────────────────────${NC}"
        echo "6) View Logs (Live)"
        echo "7) View Status (Table)"
        echo "8) Restart All"
        echo "9) Stop/Kill PM2"
        echo "10) Back to Main Menu"
        read -p "Select option [1-10]: " PM2_CHOICE

        case $PM2_CHOICE in
            1)
                if command -v openclaw >/dev/null 2>&1; then
                    status_msg "Clearing ports and stale processes"
                    pm2 delete openclaw 2>/dev/null || true
                    pkill -9 -f openclaw 2>/dev/null || true
                    rm -f "$HOME/.openclaw/tmp/openclaw.lock"
                    success_msg
                    PNPM_NODE_PATH=$(pnpm root -g 2>/dev/null || true)
                    execute "sleep 5; NODE_PATH=\"$PREFIX/lib/node_modules${PNPM_NODE_PATH:+:$PNPM_NODE_PATH}\" npm_execpath='$TERMUX_BIN/npm' PATH='$TERMUX_BIN:\$PATH' pm2 start \"openclaw gateway run\" --name openclaw --interpreter none && pm2 save" "Starting OpenClaw in PM2 (Clean Start)"
                else
                    error_msg "OpenClaw is not installed."
                fi
                wait_to_continue ;;
            2)
                if command -v n8n >/dev/null 2>&1; then
                    local n8n_env=""
                    [ -f "$HOME/n8n_server/config/n8n.env" ] && n8n_env="--env '$HOME/n8n_server/config/n8n.env'"
                    execute "pkill -9 -f n8n 2>/dev/null || true; sleep 2; pm2 start n8n --name n8n $n8n_env --interpreter none && pm2 save" "Starting n8n in PM2"
                else
                    error_msg "n8n is not installed."
                fi
                wait_to_continue ;;
            3)
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
                wait_to_continue ;;
            4)
                if command -v ollama >/dev/null 2>&1; then
                    execute "pm2 delete ollama 2>/dev/null || true; pm2 start ollama serve --name ollama --interpreter none && pm2 save" "Starting Ollama in PM2"
                else
                    error_msg "Ollama is not installed."
                fi
                wait_to_continue ;;
            5)
                if [ -f "$HOME/paperclip/server/dist/index.js" ]; then
                    status_msg "Checking PostgreSQL before Paperclip start"
                    if ! pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
                        pg_ctl -D "$PREFIX/var/lib/postgresql" start -l "$HOME/paperclip/postgres.log" >/dev/null 2>&1 || true
                        sleep 2
                    fi
                    success_msg
                    # PM2 --env does not load .env files; we embed source directly
                    execute "pm2 delete paperclip 2>/dev/null || true; cd $HOME/paperclip; pm2 start 'bash -c \"set -a && source config/paperclip.env && set +a && export PAPERCLIP_HOME=$HOME/paperclip && node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js\"' --name paperclip --interpreter none && pm2 save" "Starting Paperclip in PM2"
                else
                    error_msg "Paperclip is not installed. Use Option 6 in the main menu."
                fi
                wait_to_continue ;;
            6) pm2 logs ;;
            7) pm2 status; wait_to_continue ;;
            8) execute "pm2 stop all; pkill -9 -f 'openclaw|n8n|hermes|ollama|paperclip' 2>/dev/null || true; sleep 2; pm2 start all && pm2 save" "Restarting all processes safely" ;;
            9) execute "pm2 kill" "Stopping PM2" ;;
            *) return ;;
        esac
    done
}

# --- 10. UNINSTALLATION LOGIC ---

uninstall_menu() {
    while true; do
        echo -e "\n${RED}⚠️  UNINSTALLATION MENU${NC}"
        echo "1) Remove OpenClaw"
        echo "2) Remove Gemini CLI"
        echo "3) Remove n8n"
        echo "4) Remove Ollama"
        echo "5) Remove Hermes"
        echo "6) Remove Paperclip"
        echo "7) Wipe Software Stack (Reset)"
        echo "8) Back to Main Menu"
        read -p "Select option [1-8]: " UN_CHOICE

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
                echo -e "\n${YELLOW}This will remove:${NC}"
                echo -e "- Ollama package and downloaded models."
                confirm_action "uninstall Ollama" && { uninstall_ollama; wait_to_continue; }
                ;;
            5)
                echo -e "\n${YELLOW}This will remove:${NC}"
                echo -e "- Hermes agent installation."
                confirm_action "uninstall Hermes" && { uninstall_hermes; wait_to_continue; }
                ;;
            6)
                echo -e "\n${YELLOW}This will remove:${NC}"
                echo -e "- Paperclip process and service config."
                echo -e "- Source code and database are PRESERVED."
                confirm_action "uninstall Paperclip" && { uninstall_paperclip; wait_to_continue; }
                ;;
            7) 
                echo -e "\n${RED}🔥 RESET: This will wipe all applications:${NC}"
                echo -e "- OpenClaw, n8n, Gemini CLI, Ollama, Hermes, and Paperclip."
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

    
    crontab -l 2>/dev/null | grep -v "n8n-monitor.sh" | crontab - 2>/dev/null || true
    
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
    uninstall_ollama
    uninstall_hermes
    uninstall_paperclip
    echo -e "\n${GREEN}✅ Toolkit software removed. System dependencies were kept intact.${NC}"
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
    if [ -f "$HOME/.hermes/uninstall.sh" ]; then
        execute "bash '$HOME/.hermes/uninstall.sh'" "Running Hermes uninstaller"
    else
        rm -rf "$HOME/.hermes" "$HOME/.local/bin/hermes" 2>/dev/null || true
        echo -e "${YELLOW}Hermes directories removed. Check ~/.bashrc for stale PATH entries.${NC}"
    fi
}

uninstall_paperclip() {
    echo -e "${YELLOW}Cleaning up Paperclip...${NC}"
    # Stop processes
    execute "sv down '$PAPERCLIP_SERVICE_DIR' 2>/dev/null || true" "Stopping Paperclip service"
    pkill -9 -f "paperclip" 2>/dev/null || true
    command -v pm2 >/dev/null 2>&1 && pm2 delete paperclip >> "$LOG_FILE" 2>&1 || true
    # Note: PostgreSQL is a shared system service — we do NOT stop it.
    # Other tools or user data may depend on it.

    echo -e "${YELLOW}⚠️  Paperclip process stopped. Source code and database preserved.${NC}"
    echo -e "   Source: ${BLUE}$HOME/paperclip${NC}"
    echo -e "   Database: ${BLUE}postgres://paperclip:paperclip@localhost:5432/paperclip${NC}"
    echo -e "   PostgreSQL is still running. Stop manually if no other services need it:"
    echo -e "   ${BLUE}pg_ctl -D \$PREFIX/var/lib/postgresql stop${NC}"
    echo -e "   Remove manually if desired."
}

# --- 11. MAIN MENU ---

show_menu() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}       🤖 DROID AI TOOLKIT v$VERSION        ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${GREEN}── Install / Repair ──────────────────────────────${NC}"
    echo -e "1) ${YELLOW}Hermes${NC} Agent"
    echo -e "2) ${GREEN}OpenClaw${NC} AI Gateway"
    echo -e "3) ${YELLOW}Gemini CLI${NC}"
    echo -e "4) ${BLUE}n8n${NC} Server"
    echo -e "5) ${GREEN}Ollama${NC} (Local LLMs)"
    echo -e "6) ${MAGENTA}📎 Paperclip${NC} Server ${RED}(EXPERIMENTAL)${NC}"
    echo -e "${BLUE}── Manage ────────────────────────────────────────${NC}"
    echo -e "7) ${BLUE}GCP${NC} Bridge (for n8n)"
    echo -e "8) ${YELLOW}PM2${NC} Processes (Recommended)"
    echo -e "9) ${BLUE}Background Services${NC} (Native)"
    echo -e "10) ${RED}Uninstall${NC} Software"
    echo -e "0) Exit"
    echo -e "${BLUE}====================================================${NC}"
}

check_termux
ensure_jq

while true; do
    show_menu
    read -p "What would you like to do? [0-10]: " MAIN_CHOICE

    case $MAIN_CHOICE in
        1) install_hermes ;;
        2) install_openclaw ;;
        3) install_gemini_cli ;;
        4) install_n8n ;;
        5) install_ollama ;;
        6) install_paperclip ;;
        7) setup_n8n_gcp ;;
        8) manage_pm2 ;;
        9) manage_service ;;
        10) uninstall_menu ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done

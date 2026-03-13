# 🦞 OpenClaw Android: Installation & Patching Workspace

This workspace is dedicated to maintaining the `install.sh` script and associated documentation for running OpenClaw and Gemini CLI on Android (Termux).

## 🎯 Project Goal
Provide a "one-click" reliable installation process for OpenClaw and Gemini CLI on non-rooted Android devices, bypassing kernel restrictions and path limitations. Tested on `armv8l` and `aarch64` architectures (Android 9+).

## 🛠 Core Components
- `install.sh`: The main automation script (v1.3.5).
- `README.md`: Combined documentation with visual setup guides.
- `assets/`: Screenshots and media for documentation.
- `.gitignore`: Standard exclusion list for Android/Termux development.

## 📜 Key Workflows

### 1. Installation Workflow
The script (`install.sh`) provides an interactive menu:
- **Package Manager Selection**: Users can choose between `npm` and `pnpm`. `pnpm` is automatically installed if selected and missing.
- **Install/Repair OpenClaw**: Updates packages, installs Node.js/Go/FFmpeg, applies kernel/path patches, and auto-initializes the plugin registry.
- **Install/Repair Gemini CLI**: Dedicated setup for `@google/gemini-cli` with automated NDK environment configuration.
- **Manage PM2 Processes**: Dedicated menu to install PM2 and start OpenClaw/n8n as persistent background processes (Recommended).
- **Manage Background Service**: Legacy sub-menu for native `termux-services` configuration.
- **Uninstall**: Modular menu with **Soft** (data preservation) or **Deep** (full wipe) uninstallation options.

### 2. Maintenance & Updating
- **Update Policy**: Built-in update commands are forbidden as they break Android-specific patches.
- **Safe Update**: Re-running the `install.sh` "Install/Repair" options is the only supported upgrade path.
- **Memory Guard**: Installation automatically stops PM2/processes and uses `--max-old-space-size=1536` for heavy initialization tasks to prevent OOM on devices like 8x.
- **Path Enforcement**: Explicitly injects the Termux binary path into `openclaw.json` to ensure Skill installation (via NPM/PNPM) works correctly.

### 3. Patching Logic
- **Koffi Kernel Patch**: Replaces `renameat2` with `rename` to prevent crashes on Android kernels.
- **Aggressive Path Redirection**: Patches compiled JS files to use `$HOME/.openclaw/tmp` instead of `/tmp/openclaw` and redirects `/bin/npm` / `/bin/node` to Termux paths.
- **PM2 Integration**: Uses `pm2 start "openclaw gateway run" --name openclaw && pm2 save` for robust process persistence.
- **Process Cleanup**: Forcefully kills PM2 daemon and zombie processes on port 18789 before installation to free up RAM.

## 📂 File Map
- `install.sh`: Automated bash installer.
- `README.md`: Unified documentation for users and developers.
- `GEMINI.md`: Internal context for AI-assisted development.
- `.gitignore`: Git configuration.

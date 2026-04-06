# 🦞 OpenClaw Android: Installation & Patching Workspace

This workspace is dedicated to maintaining the `install.sh` script and associated documentation for running OpenClaw, Gemini CLI, and n8n on Android (Termux).

## 🎯 Project Goal

Provide a "one-click" high-performance installation process for OpenClaw, Gemini CLI, and n8n on non-rooted Android devices. Tested on `armv8l` and `aarch64` architectures (Android 9+).

## 🛠 Core Components

- `install.sh`: The main automation script (v1.7.11).

- `README.md`: Combined documentation with visual setup guides.
- `assets/`: Screenshots and media for documentation.
- `.gitignore`: Standard exclusion list for Android/Termux development.

## 📜 Key Workflows

### 1. Installation & Smart Repair

The script (`install.sh`) provides an intelligent menu:

- **Package Manager Selection**: State-aware selection between `npm` and `pnpm`.
- **Smart Repair**: Detects existing installations. Offers **[R] Repair** (instant patch re-application) or **[U] Update** (full registry download).
- **Automated Dependencies**: Uses `smart_pkg_install` to audit system packages via `dpkg`, skipping slow registry syncs if `nodejs-22`, `ffmpeg`, etc., are already present.
- **n8n Android Infrastructure**: Automated setup with watchdog (cron), memory-optimized environment, and Python 3 bridge.

### 2. Maintenance & Safety

- **Update Policy**: Native update commands (e.g., `openclaw update`) are forbidden as they break Android patches. Re-running the toolkit is the only supported upgrade path.
- **System Integrity**: Uninstallation and "Wipe" operations strictly preserve system packages (`pkg`) to avoid breaking other user apps.
- **Dynamic Pathing**: Uses `$PREFIX` throughout the codebase instead of hardcoded paths to ensure compatibility across different Termux configurations.
- **Memory Guard**: Uses `--max-old-space-size=1536` for heavy tasks and kills PM2 during updates to prevent OOM on mobile devices.

### 3. Patching & Surgical Cleanup

- **Koffi Kernel Patch**: Replaces `renameat2` with `rename` to bypass Android kernel crashes.
- **Optimized Path Redirection**: Uses `grep -rlE` to identify only relevant `.js` files before applying `sed`, minimizing storage I/O.
- **Surgical Process Termination**: Uninstallation logic uses port-specific signatures (e.g., `pkill -f "autossh.*5678"`) to stop only toolkit-related tunnels without affecting unrelated user services.
- **Environment Enforcement**: Injects Termux binary paths into `openclaw.json` and service `run` scripts to ensure Skill installation and execution work correctly.

## 🛡 Quality Standards

This project follows a **"Machine-First"** and **"Zero-Waste"** quality protocol.

### 1. The Lint-First Rule

Linters must be configured for any new framework or tool added to the toolkit. Do not commit un-linted code.

### 2. The Auto-Fix Rule

Always run auto-fixers before manually addressing linting errors.

```bash
pnpm run lint:all
```

### 3. Self-Healing Protocol

For surgical refactors (like removing unused variables), use the automated self-healing script:

```bash
python3 scripts/self_heal.py
```

### 4. Git & CI Safeguards

- **Local Gate**: A pre-commit hook (Husky + lint-staged) automatically fixes staged files.
- **Hard Gate**: GitHub Actions runs a full lint audit on every PR. Commits that fail the audit will be blocked.

## 📂 File Map

- `install.sh`: Automated bash installer.
- `README.md`: Unified documentation for users and developers.
- `GEMINI.md`: Internal context for AI-assisted development.
- `.gitignore`: Git configuration.

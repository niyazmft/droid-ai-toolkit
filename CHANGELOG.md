# Changelog

All notable changes to this project will be documented in this file.

## [v1.13.0] - 2026-05-31

### Changes in v1.13.0

### UI & UX Improvements

- **Modern UI Engine**: Upgraded the core menu system to use `gum` for a premium, color-rich, and touch-friendly interface. It gracefully falls back to `whiptail` if `gum` is unavailable.
- **Visual Separators**: Added unselectable blank visual separators to all menus to group related actions safely.
- **Automatic Dependencies**: `ensure_deps` now automatically installs `gum` during initial setup.

### Performance Optimizations

- **In-Memory Caching**: Implemented aggressive Bash variable caching for `get_config` and `pnpm_root_g`.
- **Zero-Latency Navigation**: Eliminated the ~1-second menu reload delay by preventing redundant spawns of the Node.js engine and `jq` during menu rendering.

---

## [v1.12.1] - 2026-05-30

### Changes in v1.12.1

### Paperclip & OpenClaw Install (PR #38, #39)

- **Enhanced installation script**: Updated `paperclip_manual_install.sh` for better dependency management and improved `.gitignore`.
- **Updated instructions**: Revised installation instructions for Paperclip and OpenClaw in scripts.

### General Improvements & Refactoring (PR #35, #37)

- **Refactoring**: Refactored code structure for improved readability and maintainability.
- **Package managers**: Improved package manager handling in install scripts.

### Pi Coding Agent (PR #33)

- **Installation update**: Switched to using `npm` and `@earendil-works/pi-coding-agent` for Pi.

### Hermes Install (PR #30, #31)

- **Installer source**: Changed to use the official GitHub URL for the Hermes installer.
- **User experience**: Added output streaming and warnings for long installs.

### PM2 Fixes (PR #27, #29)

- **OpenClaw startup**: Resolved `pnpm` shim path to the actual JS binary for OpenClaw.
- **Interpreter configuration**: Changed interpreter from `none` to `bash` and fixed command-wiring issues.

### Code Quality & Documentation (PR #25, #26, #28, #32)

- **Linting**: Added `shellcheck` for bash linting.
- **Code audit**: Addressed code audit findings from v1.11.0, removed dead code, and fixed hardcoded paths.
- **Installer robustness**: Removed `set -e` from standalone installer.
- **Documentation**: Applied audited documentation with operational guidance to `README.md`.

### Install (v1.12.1)

```bash
curl -sSL https://raw.githubusercontent.com/niyazmft/droid-ai-toolkit/main/install.sh | bash
```

---

## [v1.11.0] - 2026-05-25

### Changes in v1.11.0

### Paperclip Install (PR #24)

- **Fixed LMK failure on low-RAM devices**: Replaced the 240-line inline `install_paperclip()` with a delegate to `paperclip_manual_install.sh`
- **Proven resilience**: Tested on armv8l (32-bit) device with 1.8GB RAM — standalone script completed with 16 pass / 0 fail, while inline install was killed at ~90% every time
- **No silent failures**: Script is located via 4 candidate paths, or downloaded from `main` branch with visible error messages (no more swallowed 404s)
- **Prebuilt tarballs**: Download `paperclip-dist-v0.3.1.tar.gz` and `ui-dist-v1.10.0.tar.gz` to skip all tsc builds (~2 min instead of ~65 min)

### Pi Coding Agent (PR #23)

- Integrated Pi Coding Agent by Mario Zechner
- Auto-creates Termux-specific `~/.pi/agent/AGENTS.md` context

### New Files

- `paperclip_manual_install.sh` — standalone LMK-resilient Paperclip installer (repo root)

### Assets

- `paperclip-dist-v0.3.1.tar.gz` — prebuilt server `dist/` (2.3 MB)
- `ui-dist-v1.10.0.tar.gz` — prebuilt UI assets (2.3 MB)

### Install (v1.11.0)

```bash
curl -sSL https://raw.githubusercontent.com/niyazmft/droid-ai-toolkit/main/install.sh | bash
```

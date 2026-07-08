# Changelog

All notable changes to this project will be documented in this file.

## [v1.15.1] - 2026-07-08

### Bug Fixes

- **PM2 Hermes interpreter fix** — PM2 defaults to `interpreter: "node"`, but `$PREFIX/bin/hermes` is a bash wrapper script containing `unset PYTHONPATH`. Added `--interpreter bash` to all `pm2 start` commands for Hermes so the wrapper executes correctly instead of throwing `SyntaxError: Unexpected identifier 'PYTHONPATH'`.

## [v1.15.0] - 2026-07-08

### New Features

- **Hermes Wheel Cache** — After a successful Hermes install, compiled Python wheels (`cryptography`, `Pillow`, `pydantic-core`, `jiter`, `httptools`, `uvloop`, `watchfiles`, etc.) are automatically saved to `~/.hermes/wheel-cache`. Future `[R] Reinstall` or `[U] Update` operations on the same device reuse these prebuilt wheels and skip the 30–90 minute Rust/C compilation phase. Install time drops from ~90 minutes to under 2 minutes.

### Bug Fixes (v1.15.0)

- **Android wheel platform-tag mismatch** — Wheels built on-device via maturin/setuptools are tagged `android_29_arm64_v8a`, but pip's compatible-tags list reports `linux_aarch64`. Added automatic symlink aliases (`linux_aarch64` → real `android_*` wheel) in `_hermes_prepare_wheel_cache()` so pip correctly matches cached wheels during `--find-links` resolution.
- **Hermes Python 3.14 incompatibility** — Termux's default `python` is now 3.14, but Hermes requires `<3.14`. Added `_hermes_ensure_compatible_python()` which detects Python 3.14 and creates a temporary `python` → `python3.11` symlink before the upstream installer runs. Shows graceful TUR install instructions if no compatible Python is found.

### Documentation

- **README.md** — Added Wheel Cache tip to Hermes section and Smart Repair section.
- **AGENTS.md** — Documented wheel cache architecture and device-specific constraints (bionic libc, OpenSSL ABI).

## [v1.14.0] - 2026-07-06

### Bug Fixes (v1.14.0)

- **`execute()` no longer aborts the entire installer** — Fixed critical bug where `execute()` called `exit 1` on failure, killing the interactive shell mid-install. Now returns `$exit_code` so callers can decide whether to abort or retry.
- **`get_global_node_path()` colon-separated paths** — Fixed `find -L` breakage when `pnpm_root_g` appended a colon-delimited path. Now properly iterated with `IFS=':' read -ra`.
- **Bash 3 compatibility** — Replaced `declare -A` associative arrays with parallel indexed arrays in `apply_patches()` and `paperclip_manual_install.sh`, fixing crashes on older Termux builds.
- **Hermes wrapper staleness** — Added reconciliation block that detects stale `$PREFIX/bin/hermes` wrappers pointing to missing venv paths, searches `~/.hermes/` for the actual binary, and rewrites the wrapper automatically after updates.
- **`$PREFIX` fallback in Paperclip standalone script** — Added `PREFIX=${PREFIX:-"/data/data/com.termux/files/usr"}` guard for environments where `$PREFIX` is not exported.

### Performance Optimizations (v1.14.0)

- **Session-level PATH caches** — `_HAS_PNPM`, `_HAS_PM2`, `_HAS_JQ` are evaluated once at startup instead of on every menu render.
- **Memory limit caching** — `get_mem_limit()` result stored in `_CACHED_MEM_LIMIT`, eliminating repeated `free -m` + arithmetic on every install invocation.
- **Conditional `pkg update`** — `ensure_deps()` skips `apt update` if package lists are fresher than 60 minutes, saving 3–10 seconds on every launch.
- **OpenClaw hardlink patch pre-filter** — Replaced `find -exec sed` on every `.js` file with `grep -rlZE` pre-filter, reducing I/O by ~90% on large `node_modules` trees.
- **Koffi rebuild skip** — Skips the 30–60s C++ rebuild if `build/koffi/$TRIPLET/koffi.node` exists and is newer than `base.cc`.
- **Gemini CLI `find` depth limit** — Added `-maxdepth 6` to prevent traversal of deep pnpm content-addressable store paths.
- **Menu state hoisting** — `is_installed` / `command -v` checks moved outside `while true` loops; state refreshes only when re-entering a menu.
- **Extracted `ensure_nodejs_links()`** — Consolidated duplicate Node.js symlink logic used by OpenClaw and n8n into a single helper.

### UI/UX Improvements (v1.14.0)

- **Unified arrow-key menus everywhere** — All inline `read -p "Select [1-3]"` prompts replaced with `show_whi_menu` / `gum` / `whiptail` navigation. No more numeric typing.
- **Persistent error messages** — `error_msg()` now prints with `\n` instead of `\r`, so errors remain visible instead of being erased by the next status spinner.
- **Auto-continue prompts** — `wait_to_continue()` uses `read -t 3`, so users can press Enter or simply wait 3 seconds instead of mandatory tapping.
- **Graceful Ctrl+C in `execute()`** — Trap now prints `"Interrupted by user."` before cleanup instead of silent abort.
- **Severity-colored destructive options** — Deep Uninstall and WIPE ALL options show `${RED}` warnings in menu descriptions.
- **Help menu (`[?] Help`)** — New main-menu entry with one-line descriptions of every tool category and the Repair/Update tip.
- **Install log paths displayed upfront** — Each installer now prints `"Verbose logs: $LOG_FILE"` at the start for easier debugging.

### Code Reorganization (v1.14.0)

- **Modular Patch Engine** — Split 124-line `apply_patches()` god function into focused units:
  - `patch_koffi()` — kernel `renameat2` → `rename` + conditional rebuild
  - `patch_gemini_cli()` — `fs.promises.rename` → `copyFile+unlink`
  - `patch_paperclip()` — path redirection + symlink repair
  - `patch_openclaw_links()` — hardlink → `copyFile`
  - `create_sqlite3_stub()` — standalone sqlite3 no-op stub
  - `apply_patches()` — thin coordinator invoking all five
- **Section numbering unified** — Eliminated duplicate section numbers (two "6.", two "8.", odd "8.5"). Clean sequence: 1 → 2 → 2.5 → 3 → 4 → 4.1 → 5 → 6 → 7 → 7.1 → 8 → 9 → 9.1 → 10 → 11 → 12 → 13.
- **TUI helpers relocated** — `get_term_size`, `show_whi_menu`, `whiptail_confirm`, `whiptail_msg` moved from line ~1909 to Section 2.5, ensuring they are defined before first use.
- **`install_nanobot()` gets own header** — Was incorrectly nested under `# --- 8. HERMES INSTALLATION ---`; now has `# --- 9.1. NANOBOT INSTALLATION ---`.

### Data Preservation (v1.14.0)

- **OpenClaw Repair** — Only reapplies patches; skips `jq` config rewrite and `npm/pnpm` re-install.
- **Pi Repair** — Only regenerates `~/.pi/agent/AGENTS.md`; skips `npm/pnpm` re-install.
- **n8n Repair** — Only regenerates config/watchdog if files are missing; skips `npm/pnpm` re-install.
- **Hermes Update** — Preserves `~/.hermes/` data; runs upstream installer then reconciles wrapper.
- **Paperclip Update** — Backs up `instances/default/`, `config/`, and `ecosystem.config.cjs` before delegating to standalone script, restores after successful install.

### Install (v1.14.0)

```bash
curl -sSL https://raw.githubusercontent.com/niyazmft/droid-ai-toolkit/main/install.sh | bash
```

---

## [v1.13.0] - 2026-05-31

### Changes in v1.13.0

### UI & UX Improvements (v1.13.0)

- **Modern UI Engine**: Upgraded the core menu system to use `gum` for a premium, color-rich, and touch-friendly interface. It gracefully falls back to `whiptail` if `gum` is unavailable.
- **Visual Separators**: Added unselectable blank visual separators to all menus to group related actions safely.
- **Automatic Dependencies**: `ensure_deps` now automatically installs `gum` during initial setup.

### Performance Optimizations (v1.13.0)

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

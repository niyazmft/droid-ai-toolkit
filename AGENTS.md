# Droid AI Toolkit — Agent Instructions

## Project Type

Bash scripting toolkit. Main deliverable is `install.sh`. No app runtime here — `package.json` is lint-only infrastructure.

## Toolchain & Commands

```bash
pnpm install               # Install linter deps (pnpm@10.32.1 enforced via packageManager field)
pnpm run lint:all          # Full lint gate: ESLint → Stylelint → Markdownlint → shellcheck (read-only, does NOT --fix)
python3 scripts/self_heal.py  # Strips unused `catch (err)` params from JS/MJS only
```

- Lint config: `eslint.config.mjs` (flat/v10, Node/browser/jest globals), `.stylelintrc.json` (Tailwind-aware), `.markdownlint.json` (line length & inline HTML allowed), `.shellcheckrc` (bash linting).
- CI (`lint.yml`) runs on Node 22 and blocks PRs to `main`/`master`.

## Quality Gate & Workflow

1. Pre-commit (`npx lint-staged`) auto-fixes staged `*.{js,mjs}`, `*.css`, and `*.md`.
2. Run `pnpm run lint:all` locally before pushing; it is the PR gate.
3. Do **not** assume `lint:all` auto-fixes — it reports only.

## Android / Termux Context

- **Never use native update commands** (`openclaw update`, etc.) — they overwrite Android patches.
- Safe update path: re-run `install.sh`, choose **[R] Repair** (2-second patch-only) or **[U] Update** (latest verified version).
- **UI Engine**: v1.13.0+ uses `gum` (charm.sh) for color-rich, touch-friendly menus with visual separators; falls back to `whiptail` if unavailable. `ensure_deps` auto-installs `gum`.
- Uses `$PREFIX` dynamically; never hardcode `/data/data/com.termux/files/usr`.
- Memory guard: Node.js heap limit is set to `min(2048, max(512, RAM * 0.75))` via `--max-old-space-size`.
- PM2 is killed during updates to prevent OOM on low-RAM devices.
- **Zero-latency navigation**: v1.13.0+ caches Bash variables for `get_config` and `pnpm_root_g`, and eliminates redundant Node.js / `jq` spawns during menu rendering.
- Koffi kernel patch: `renameat2` → `rename` to avoid kernel crashes.
- Gemini CLI patch: `fs.promises.rename` → `copyFile + unlink` to avoid Android `ENOENT`.

## Architecture

- `install.sh`: Single source of truth for toolkit logic and version (v1.16.0). `package.json` version (1.0.0) is stale — ignore it.
- `scripts/self_heal.py`: Lightweight Python refactor; only strips unused catch variables.
- `package.json`: Dev-only. Defines lint scripts, `lint-staged`, and Husky prepare hook.

## Hermes Update Fix (v1.15.7)

The `[U] Update` path for Hermes was rewritten in v1.15.7 to work around upstream bugs:

1. **Upstream `hermes update` uses `uv` internally**, which is broken on Termux:
   - Downloads a glibc-linked `uv` binary → fails on bionic libc
   - Falls back to `pip install uv` → no aarch64 wheel → compiles 100K+ lines of Rust → OOM
   - `uv` then rejects Android-built wheels as "not compatible with Android aarch64"
   - PR #39138 fixed extras group selection (`termux-all` vs `all`) but explicitly left the managed-uv bootstrap unfixed ("out of scope")

2. **Our fix (v1.15.7)** — the toolkit now:
   - Skips `hermes update` entirely on Termux
   - Runs `git pull origin main` manually
   - Calls `_hermes_ensure_termux_deps()` which uses `pip` (not `uv`)
   - Cleans stale `gateway.lock` / `gateway.pid` after `pkill -9`
   - Force-reinstalls editable metadata (`--force-reinstall --no-deps -e .`) to prevent stale `.pth` files
   - Smoke-tests imports (`import agent.prompt_builder`) to verify the venv is coherent
   - Exports Rust build env (`ANDROID_API_LEVEL`, `CARGO_BUILD_JOBS=1`, etc.) before any pip call

## Hermes Update Robustness (v1.16.0)

v1.16.0 adds robustness fixes for the Hermes update path, addressing edge cases discovered in real-world usage:

1. **Stash Termux fix before git pull** — The Termux fix patch (`if False:  # Termux fix` in `hermes_cli/main.py`) is now **stashed before `git pull`** and re-applied after. This prevents merge conflicts when upstream changes the same code region (as happened in Hermes v0.20.0 which renamed `_try_termux_ultrafast_version()` to `_try_ultrafast_version()`).

2. **Clean `.update-incomplete` markers** — Interrupted upstream `hermes update` runs leave a `.update-incomplete` marker file that causes Hermes to enter recovery mode on every startup instead of running normally. The toolkit now cleans this marker in both **update** and **fix** modes.

3. **Pre-install build backends** — When Hermes bumps dependency versions (e.g. `cryptography==48.0.1`, `Pillow==12.3.0`), the new versions may not have prebuilt android-compatible wheels. The toolkit now pre-installs `maturin`, `pybind11`, and `setuptools-rust` in the venv before running `pip install`, so source builds succeed without manual intervention.

4. **Venv bin on PATH** — The venv `bin/` directory is added to `$PATH` before pip operations, ensuring build subprocesses can find `maturin` and other build backends.

5. **PM2 interpreter safeguard** — After an update, PM2 is restarted with `--interpreter bash` (the Hermes binary is a bash script, not a Node.js script) and the process list is saved, preventing "SyntaxError: Unexpected identifier" crashes on subsequent auto-restarts.

6. **Shared patch helper** — The Termux fast-version patch logic is extracted into a reusable `_hermes_apply_termux_fix()` function that handles both the old (v0.18.x `_try_termux_ultrafast_version`) and new (v0.20.0+ `_try_ultrafast_version`) call sites. Used consistently across install, fix, and update modes.

7. **Post-update cryptography check** — Hermes v0.19.0's `setup.py` pins `cryptography==48.0.1`, but the wheel cache may only have `46.0.7`. The toolkit does not force-upgrade cryptography to avoid a 30–90 minute source build. If you need the newer version, run manually:

   ```bash
   export ANDROID_API_LEVEL=$(getprop ro.build.version.sdk)
   ~/.hermes/hermes-agent/venv/bin/pip install cryptography==48.0.1 --no-build-isolation
   ```

## Install Methods Per Tool

| Tool | Method | Architecture Notes |
| --- | --- | --- |
| OpenClaw | npm/pnpm global + koffi kernel patch + path redirection (`/tmp`, `/bin/npm`, etc.) | All architectures |
| Pi Agent | **RECOMMENDED** — npm/pnpm global (`@earendil-works/pi-coding-agent`) + `~/.pi/agent/AGENTS.md` context setup. Legacy `@mariozechner/pi-coding-agent` is detected and migrated. | All architectures |
| Gemini CLI | npm/pnpm global + `rename` → `copyFile+unlink` patch | All architectures |
| n8n | npm/pnpm global + watchdog cron + `NODE_OPTIONS` memory cap + optional GCP bridge | All architectures |
| Ollama | `pkg install ollama` (Termux native) | All architectures |
| Hermes | curl installer from `hermes-agent.nousresearch.com` + automatic wheel-cache (`~/.hermes/wheel-cache`) for fast reinstalls | ❌ Not supported on `armv8l`/`armv7l` (maturin/jiter incompatibility) |
| Nanobot | `pip3 install nanobot-ai` with `--no-build-isolation` | ❌ Not supported on `armv8l`/`armv7l` (maturin/jiter incompatibility) |
| Paperclip | Delegates to `paperclip_manual_install.sh` (clone + pnpm + prebuilt tarballs + PostgreSQL) | All architectures (experimental, ~2GB RAM recommended) |

## OpenClaw Version Selection (v1.15.3+)

The toolkit supports installing a **specific OpenClaw version** (e.g. `2026.6.30`) via the **[V] Install Specific Version** option in the OpenClaw menu. This is useful for:

- Pinning to a known-good release
- Testing older versions before upgrading
- Avoiding breaking changes in `@latest`

## OpenClaw 2026.9.x Multi-Stage Legacy-State Migration (v1.17.0+)

OpenClaw 2026.9.x gates gateway startup behind **legacy-state migrations** that upstream normally applies via `openclaw doctor --fix`. `doctor --fix` **cannot run on Android/Termux** because it requires a systemd/launchd service owner for gateway verification. The toolkit instead runs the migrations directly (`migrate_openclaw_legacy_state`, invoked from `install_openclaw` after `apply_patches`; runs only when legacy files exist):

1. **Stage 1 — Workspace setup state**: legacy `openclaw-workspace-state.json` / `workspace/.openclaw/workspace-state.json` are upserted into the state DB (`~/.openclaw/state/openclaw.sqlite`, table `workspace_setup_state`, key = SHA-256 of the workspace path). Legacy files are **moved** to `~/.openclaw/backup-legacy-state-<timestamp>/` (never deleted) after a successful commit.
2. **Stage 2 — Session store**: legacy `sessions.json` (global `~/.openclaw/sessions/` or per-agent `~/.openclaw/agents/*/sessions/`) is imported into the agent SQLite DB via `openclaw doctor --session-sqlite import --session-sqlite-all-agents` (this subcommand runs before the Android-incompatible `runDoctorHealthFlow`, so it works on Termux).
3. **Stage 3 — Exec approvals**: legacy `~/.openclaw/exec-approvals.json` is upserted into the state DB (`exec_approvals_config`, key `current`, raw document + projection columns mirroring upstream `writeExecApprovalsConfigRow()`); the legacy file and any `.doctor-importing*` claims are archived after commit. Without this stage the gateway's **channels crash-loop** (`[default] channel exited: Legacy exec approvals exist ...`) even though the gateway itself boots.

Supporting patches (both wired into `apply_patches()`):

- `patch_openclaw_sqlite_archive()`: the 2026.9.x migration machinery publishes archived transcripts via **hardlinks** (`fs.link`, `nlink === 2` assertions) which Android blocks with `EACCES`. The patch modifies `dist/doctor-session-sqlite-restore-*.js` to fall back to a **timestamp-preserving copy** (`copyFileSync` + `utimesSync`) and verifies publications by content (`size` + `sha256`) instead of inode identity.
- `patch_openclaw_pid_platform()`: OpenClaw's process-identity helpers guard `/proc` parsing with `process.platform === "linux"`, but on Termux `process.platform` is **`"android"`** — so `getProcessStartTime()` returned null and every cron tick failed with *"cron run cannot acquire a durable fence without process start identity"* (file-lock owner staleness detection was degraded too). The patch makes `getProcessStartTime()` and `isZombieProcess()` accept the `android` platform in both `dist/worker/worker.mjs` (minified, non-fatal on mismatch) and `dist/pid-alive-*.js` (glob-tolerant).

The runner pauses the PM2 `openclaw` process during migration (SQLite/file contention) and restarts it afterwards. Do **not** bypass the migration gates by patching the assertions — run the real migrations; skipping leaves half-migrated state (sessions visible in old format only, gateway retries forever). Do **not** run `openclaw doctor --fix` on Android even when the in-chat agent offers — it fails at gateway service-owner verification, and it may propose re-running migrations it misreads from stale stability bundles. Verified working on device y6 (28 entries, 220 artifacts, exec-approvals row written, gateway ready, Telegram channel polling and delivering, cron ticking without fence errors).

## Zulip Plugin Management (v1.15.3+)

A dedicated sub-menu **[Z] Zulip Plugin** under AGENTS → OpenClaw provides:

- **[I] Install Latest** — `openclaw plugins install clawhub:@niyazmft/openclaw-zulip`
- **[U] Update to Latest** — `openclaw plugins update zulip`
- **[S] Install Specific Version** — `openclaw plugins install clawhub:@niyazmft/openclaw-zulip@2026.7.0`
- **[X] Uninstall** — `openclaw plugins uninstall zulip`

> ⚠️ **Node 24 Compatibility:** The Zulip plugin may fail on Node 24 with an `ERR_REQUIRE_ESM_RACE_CONDITION` due to a worker-thread module loader race in OpenClaw's plugin SDK. This affects both pnpm and npm installs. The only guaranteed fixes are: (1) wait for an OpenClaw upstream patch, or (2) skip Zulip by setting `plugins.allow` in `openclaw.json`.

## Pi Agent Contextualization

- **Path Awareness**: Automatically creates `~/.pi/agent/AGENTS.md` during installation.
- **Environment**: Injects `$HOME`, `$PREFIX`, and Android-specific URL opening commands (`termux-open-url`) to prevent hallucination of standard Linux paths.

## Workflows

- **Smart Repair**: Detects existing installs and offers **[R] Repair** or **[U] Update**.
- **Uninstallation**: Modular menu (UNINSTALL → individual tool or WIPE ALL). Preserves system `pkg` packages. Deep vs Soft uninstalls available.
- **n8n bridge**: Option 7 configures `autossh` tunnel to a GCP VM. Monitor script is at `~/n8n_server/scripts/n8n-monitor.sh`.

## Patching Details

- **Koffi**: `sed` inside compiled `.node` / `.c` sources replaces `renameat2(...)` with `rename(...)`.
- **Hermes/Nanobot armv8l/armv7l limitation**: `jiter` (a dependency of `anthropic`, which both Hermes and Nanobot depend on) requires Rust compilation via `maturin`. The `maturin` build tool hard-codes an architecture check that rejects `armv8l` and `armv7l`. Additionally, pre-built `jiter` wheels are compiled for glibc Linux (manylinux) and require `libgcc_s.so.1` and `ld-linux-armhf.so.3`, which do not exist on Android's bionic libc. The only fix is upstream support from the `jiter`/`maturin` projects. The toolkit now displays a graceful error message and skips installation on these architectures.
- **Hermes wheel cache (v1.15.3+):** After a successful install, compiled Python wheels (`cryptography`, `Pillow`, `pydantic-core`, `jiter`, `httptools`, `uvloop`, `watchfiles`, etc.) are copied from pip's ephemeral cache to `~/.hermes/wheel-cache`. The `PIP_FIND_LINKS` environment variable is set before any Hermes pip operation, so future reinstalls or updates on the same device reuse prebuilt wheels and skip the 30–90 minute Rust/C compilation phase. This cache is device-specific because compiled wheels link against the device's bionic libc, OpenSSL, and Python ABI.
- **Path redirection**: `grep -rlE` finds hardcoded `/tmp/openclaw`, `/usr/bin/npm`, `/bin/node` references in installed JS, then `sed` replaces them with `$HOME/.openclaw/tmp` and `$TERMUX_BIN` paths.
- **Process termination**: uses port-specific signatures (e.g., `pkill -f "autossh.*5678"`).
- **Paperclip install**: The inline Paperclip install in `install.sh` has been **replaced by delegation** to `paperclip_manual_install.sh`. This standalone script handles: clone + pre-install patches (remove `embedded-postgres`, drop `ui` workspace, delete stale lockfile), pnpm install with LMK-kill detection and retry, `.bin` symlink repair (`tsc`, `tsx`, `esbuild`), prebuilt `cli-dist`, `dist/`, and `ui-dist` tarball download from GitHub releases, PostgreSQL bootstrap with stale-process cleanup, randomized secret generation, and PM2 ecosystem file creation. The server and UI are **not built on-device** (Vite/`tsc` requires ~4–6 GB transient RSS and is unreliable). Paperclip installs enforce a per-device heap cap (`--max-old-space-size=1024`), single-concurrency `pnpm install`, and rely on pre-built assets to survive Android Low Memory Killer (LMK). PostgreSQL (`pg_ctl`) must be running before starting Paperclip. **Note:** On some devices, `pm2` may fail to start the server due to a Node.js module resolution bug (`ERR_MODULE_NOT_FOUND`). If this occurs, run the server manually: `cd ~/paperclip && node server/dist/index.js`.

  **Known gotchas with pnpm in Termux**: For Paperclip installation, `pnpm v10` can fail to correctly link workspace dependencies, leading to build failures. It is **strongly recommended to use pnpm v9.x** (`npm i -g pnpm@9.15.4`) before attempting the Paperclip install. The installer manually repairs `.bin` symlinks for `tsc`, `tsx`, and `esbuild`, and ensures `node_modules/.bin` is prepended to `$PATH`. The `sync; sleep 5; node -e "global.gc()"` pattern that was previously used between build steps is **removed entirely** — it was causing LMK kills on loaded systems. The `safe_execute()` helper uses `eval` (no `bash -c` fork) and appends directly to the main log.

## License Note

`ATTRIBUTIONS.md` governs third-party redistribution rules. **n8n** is under the *Sustainable Use License*; commercial resale or embedding as a paid service requires an Enterprise license. Do not remove or alter `ATTRIBUTIONS.md` without legal review.

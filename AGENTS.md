# Droid AI Toolkit — Agent Instructions

## Project Type

Bash scripting toolkit. Main deliverable is `install.sh`. No app runtime here — `package.json` is lint-only infrastructure.

## Toolchain & Commands

```bash
pnpm install               # Install linter deps (pnpm@10.32.1 enforced via packageManager field)
pnpm run lint:all          # Full lint gate: ESLint → Stylelint → Markdownlint (read-only, does NOT --fix)
python3 scripts/self_heal.py  # Strips unused `catch (err)` params from JS/MJS only
```

- Lint config: `eslint.config.mjs` (flat/v10, Node/browser/jest globals), `.stylelintrc.json` (Tailwind-aware), `.markdownlint.json` (line length & inline HTML allowed).
- CI (`lint.yml`) runs on Node 22 and blocks PRs to `main`/`master`.

## Quality Gate & Workflow

1. Pre-commit (`npx lint-staged`) auto-fixes staged `*.{js,mjs}`, `*.css`, and `*.md`.
2. Run `pnpm run lint:all` locally before pushing; it is the PR gate.
3. Do **not** assume `lint:all` auto-fixes — it reports only.

## Android / Termux Context

- **Never use native update commands** (`openclaw update`, etc.) — they overwrite Android patches.
- Safe update path: re-run `install.sh`, choose **[R] Repair** (2-second patch-only) or **[U] Update** (latest verified version).
- Uses `$PREFIX` dynamically; never hardcode `/data/data/com.termux/files/usr`.
- Memory guard: Node.js heap limit is set to `min(2048, max(512, RAM * 0.75))` via `--max-old-space-size`.
- PM2 is killed during updates to prevent OOM on low-RAM devices.
- Koffi kernel patch: `renameat2` → `rename` to avoid kernel crashes.
- Gemini CLI patch: `fs.promises.rename` → `copyFile + unlink` to avoid Android `ENOENT`.

## Architecture

- `install.sh`: Single source of truth for toolkit logic and version (v1.11.0). `package.json` version (1.0.0) is stale — ignore it.
- `scripts/self_heal.py`: Lightweight Python refactor; only strips unused catch variables.
- `package.json`: Dev-only. Defines lint scripts, `lint-staged`, and Husky prepare hook.

## Install Methods Per Tool

| Tool | Method | Architecture Notes |
| --- | --- | --- |
| OpenClaw | npm/pnpm global + koffi kernel patch + path redirection (`/tmp`, `/bin/npm`, etc.) | All architectures |
| Pi Agent | **RECOMMENDED** — npm/pnpm global + `~/.pi/agent/AGENTS.md` context setup | All architectures |
| Gemini CLI | npm/pnpm global + `rename` → `copyFile+unlink` patch | All architectures |
| n8n | npm/pnpm global + watchdog cron + `NODE_OPTIONS` memory cap + optional GCP bridge | All architectures |
| Ollama | `pkg install ollama` (Termux native) | All architectures |
| Hermes | curl installer from `hermes-agent.nousresearch.com` | ❌ Not supported on `armv8l`/`armv7l` (maturin/jiter incompatibility) |
| Nanobot | `pip3 install nanobot-ai` with `--no-build-isolation` | ❌ Not supported on `armv8l`/`armv7l` (maturin/jiter incompatibility) |
| Paperclip | Delegates to `paperclip_manual_install.sh` (clone + pnpm + prebuilt tarballs + PostgreSQL) | All architectures (experimental, ~2GB RAM recommended) |

## Pi Agent Contextualization

- **Path Awareness**: Automatically creates `~/.pi/agent/AGENTS.md` during installation.
- **Environment**: Injects `$HOME`, `$PREFIX`, and Android-specific URL opening commands (`termux-open-url`) to prevent hallucination of standard Linux paths.

## Workflows

- **Smart Repair**: Detects existing installs and offers **[R] Repair** or **[U] Update**.
- **Uninstallation**: Modular menu (Option 10). Preserves system `pkg` packages. Deep vs Soft uninstalls available.
- **n8n bridge**: Option 7 configures `autossh` tunnel to a GCP VM. Monitor script is at `~/n8n_server/scripts/n8n-monitor.sh`.

## Patching Details

- **Koffi**: `sed` inside compiled `.node` / `.c` sources replaces `renameat2(...)` with `rename(...)`.
- **Hermes/Nanobot armv8l/armv7l limitation**: `jiter` (a dependency of `anthropic`, which both Hermes and Nanobot depend on) requires Rust compilation via `maturin`. The `maturin` build tool hard-codes an architecture check that rejects `armv8l` and `armv7l`. Additionally, pre-built `jiter` wheels are compiled for glibc Linux (manylinux) and require `libgcc_s.so.1` and `ld-linux-armhf.so.3`, which do not exist on Android's bionic libc. The only fix is upstream support from the `jiter`/`maturin` projects. The toolkit now displays a graceful error message and skips installation on these architectures.
- **Path redirection**: `grep -rlE` finds hardcoded `/tmp/openclaw`, `/usr/bin/npm`, `/bin/node` references in installed JS, then `sed` replaces them with `$HOME/.openclaw/tmp` and `$TERMUX_BIN` paths.
- **Process termination**: uses port-specific signatures (e.g., `pkill -f "autossh.*5678"`).
- **Paperclip install**: The inline Paperclip install in `install.sh` has been **replaced by delegation** to `paperclip_manual_install.sh`. This standalone script handles: clone + pre-install patches (remove `embedded-postgres`, drop `ui` workspace, delete stale lockfile), pnpm install with LMK-kill detection and retry, `.bin` symlink repair (`tsc`, `tsx`, `esbuild`), prebuilt `dist/` and `ui-dist` tarball download from GitHub releases, PostgreSQL bootstrap with stale-process cleanup, randomized secret generation, and PM2 ecosystem file creation. The UI is **not built on-device** (Vite/esbuild requires ~4–6 GB transient RSS). Paperclip installs enforce a per-device heap cap (`--max-old-space-size=1024` on 3–4 GB devices), single-concurrency `pnpm install`, deleted `ui` workspace, and sequential workspace builds to survive Android Low Memory Killer (LMK). PostgreSQL (`pg_ctl`) must be running before starting Paperclip.

  **Known gotchas with pnpm in Termux**: pnpm v10 with `--no-frozen-lockfile` + workspace patches sometimes fails to create `.bin` symlinks in the root `node_modules/.bin`. The installer manually repairs `tsc` → `typescript/bin/tsc`, `tsx` → `../.pnpm/tsx@*/tsx/dist/cli.mjs`, and `esbuild` → `esbuild/bin/esbuild`, and ensures `node_modules/.bin` is prepended to `$PATH` before workspace builds. The `sync; sleep 5; node -e "global.gc()"` pattern that was previously used between build steps is **removed entirely** — it was causing LMK kills on loaded systems. The `safe_execute()` helper uses `eval` (no `bash -c` fork) and appends directly to the main log.

## License Note

`ATTRIBUTIONS.md` governs third-party redistribution rules. **n8n** is under the *Sustainable Use License*; commercial resale or embedding as a paid service requires an Enterprise license. Do not remove or alter `ATTRIBUTIONS.md` without legal review.

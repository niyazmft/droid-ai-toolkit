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

- `install.sh`: Single source of truth for toolkit logic and version (v1.10.0). `package.json` version (1.0.0) is stale — ignore it.
- `scripts/self_heal.py`: Lightweight Python refactor; only strips unused catch variables.
- `package.json`: Dev-only. Defines lint scripts, `lint-staged`, and Husky prepare hook.

## Install Methods Per Tool

| Tool | Method |
| --- | --- |
| OpenClaw | npm/pnpm global + koffi kernel patch + path redirection (`/tmp`, `/bin/npm`, etc.) |
| Pi Agent | **RECOMMENDED** — npm/pnpm global + `~/.pi/agent/AGENTS.md` context setup |
| Gemini CLI | npm/pnpm global + `rename` → `copyFile+unlink` patch |
| n8n | npm/pnpm global + watchdog cron + `NODE_OPTIONS` memory cap + optional GCP bridge |
| Ollama | `pkg install ollama` (Termux native) |
| Hermes | curl installer from `hermes-agent.nousresearch.com` |
| Paperclip | **EXPERIMENTAL** — build from source (git clone + pnpm) + external PostgreSQL (embedded-postgres has no Android builds) |

## Pi Agent Contextualization

- **Path Awareness**: Automatically creates `~/.pi/agent/AGENTS.md` during installation.
- **Environment**: Injects `$HOME`, `$PREFIX`, and Android-specific URL opening commands (`termux-open-url`) to prevent hallucination of standard Linux paths.

## Workflows

- **Smart Repair**: Detects existing installs and offers **[R] Repair** or **[U] Update**.
- **Uninstallation**: Modular menu (Option 10). Preserves system `pkg` packages. Deep vs Soft uninstalls available.
- **n8n bridge**: Option 7 configures `autossh` tunnel to a GCP VM. Monitor script is at `~/n8n_server/scripts/n8n-monitor.sh`.

## Patching Details

- **Koffi**: `sed` inside compiled `.node` / `.c` sources replaces `renameat2(...)` with `rename(...)`.
- **Path redirection**: `grep -rlE` finds hardcoded `/tmp/openclaw`, `/usr/bin/npm`, `/bin/node` references in installed JS, then `sed` replaces them with `$HOME/.openclaw/tmp` and `$TERMUX_BIN` paths.
- **Process termination**: uses port-specific signatures (e.g., `pkill -f "autossh.*5678"`).
- **Paperclip patches**: `embedded-postgres` is removed from `server/package.json` post-clone (it has no Android builds); external PostgreSQL is installed via `pkg`. `SHARP_IGNORE_GLOBAL_LIBVIPS=1` forces sharp to compile from source against Termux's `libvips`. `pnpm-lock.yaml` is deleted after clone. `@paperclipai/plugin-sdk` is built before the server. `noImplicitAny` and `noEmitOnError` are patched to `false` in `server/tsconfig.json` to suppress upstream type errors and ensure `dist/` is always written. The UI is **not built on-device** (Vite/esbuild requires ~4-6GB transient RSS); instead, a prebuilt `ui-dist.tar.gz` tarball is downloaded from the GitHub release, extracted into `server/ui-dist`. If the download fails, a single fallback build attempt is made with `minify: false` and dropped `console/debugger` stripping. PostgreSQL (`pg_ctl`) must be running before starting Paperclip.

## License Note

`ATTRIBUTIONS.md` governs third-party redistribution rules. **n8n** is under the *Sustainable Use License*; commercial resale or embedding as a paid service requires an Enterprise license. Do not remove or alter `ATTRIBUTIONS.md` without legal review.

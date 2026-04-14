# Droid AI Toolkit - Agent Instructions

## Project Type

Bash scripting toolkit (not a JS/TS app). Main deliverable is `install.sh`. Supports OpenClaw, Gemini CLI, n8n, Ollama, and Hermes on Android (Termux).

## Commands

```bash
pnpm run lint:all          # Full quality audit (JS + CSS + Markdown)
python3 scripts/self_heal.py  # Automated refactor for unused code
```

## Workflow

1. Lint runs automatically on pre-commit (Husky + lint-staged)
2. GitHub Actions blocks PRs that fail `pnpm run lint:all`
3. Always run auto-fixers before manual fixes: `pnpm run lint:all`

## Android/Termux Context

- **Never use native update commands** (`openclaw update`, etc.) - they break Android patches
- Re-run `install.sh` and choose **[R] Repair** to update safely
- Uses `$PREFIX` dynamically instead of hardcoded paths
- Special patches: `renameat2` → `rename` for koffi kernel compatibility
- Memory limit: `--max-old-space-size=1536` for heavy Node.js tasks
- Kills PM2 during updates to prevent OOM on mobile devices

## Architecture

- `install.sh`: Main automation script (v1.9.0)
- `scripts/self_heal.py`: Python refactoring tool
- `package.json`: Lint config only (no app code)

## Install Methods Per Tool

|Tool|Method|
|------|--------|
|OpenClaw|npm/pnpm global install + koffi kernel patch + path redirection|
|Gemini CLI|npm/pnpm global install + `rename` → `copyFile+unlink` patch|
|n8n|npm/pnpm global install + watchdog cron + env config|
|Ollama|`pkg install ollama` (Termux native package)|
|Hermes|curl installer from `hermes-agent.nousresearch.com`|

## Key Workflows

- **Smart Repair**: Detects existing installations, offers **[R] Repair** (instant patch) or **[U] Update** (latest version)
- **Package managers**: Supports both npm and pnpm (state-aware selection) for Node.js tools
- **n8n**: Automated setup with watchdog cron, memory-optimized env, Python 3 bridge
- **Uninstallation**: Preserves system packages (`pkg`) - never breaks other user apps

## Patching Details

- Koffi kernel patch: `renameat2` → `rename`
- Gemini CLI patch: `fs.promises.rename` → `copyFile + unlink` for Android ENOENT
- Path redirection: uses `grep -rlE` to find relevant `.js` files before applying `sed`
- Process termination: port-specific signatures (e.g., `pkill -f "autossh.*5678"`)

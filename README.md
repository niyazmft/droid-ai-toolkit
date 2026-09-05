# 🤖 Droid AI Toolkit (Termux)

<p align="center">
  <img src="./assets/Cover.png" width="100%" alt="Droid AI Toolkit Cover">
</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-1.17.1-blue.svg)](https://github.com/niyazmft/droid-ai-toolkit)
[![Platform](https://img.shields.io/badge/Platform-Android%20(Termux)-green.svg)](https://termux.dev/)

A high-performance, automated toolkit for running AI tools — [OpenClaw](https://github.com/the-claw-team/openclaw), [Gemini CLI](https://github.com/google/gemini-cli), [n8n](https://github.com/n8n-io/n8n), [Ollama](https://ollama.com), [Hermes](https://hermes-agent.nousresearch.com), [Nanobot](https://github.com/nanobot-ai/nanobot), [Pi](https://github.com/earendil-works/pi-coding-agent), and [Paperclip](https://github.com/paperclipai/paperclip) — natively on non-rooted Android devices. This toolkit bypasses kernel restrictions (`renameat2`), patches hardcoded system paths, and optimizes execution for mobile environments.

---

## 📑 Table of Contents

- [Key Features](#-key-features)
- [Compatibility](#-compatibility)
- [Before You Start](#-before-you-start)
- [Quick Start](#-quick-start)
  - [Onboard OpenClaw after install](#4-onboard-openclaw-if-installed)
- [AI Agents](#-ai-agents)
  - [OpenClaw](#openclaw--ai-gateway)
  - [Hermes](#hermes--nous-research-agent)
  - [Nanobot](#nanobot--python-ai-agent)
- [OpenClaw 2026.9.x on Android](#-openclaw-20269x-on-android)
  - [Android Patch Suite](#android-patch-suite)
  - [Automatic Legacy-State Migration](#automatic-legacy-state-migration)
  - [Why the Doctor Repair Flow Is Not Needed](#why-the-doctor-repair-flow-is-not-needed-on-android)
  - [Post-Install Checklist (User Work)](#post-install-checklist-user-work)
  - [Hard Warnings](#hard-warnings)
- [Workflows & Automation](#-workflows--automation)
  - [n8n](#n8n--workflow-automation-server)
  - [Paperclip](#paperclip--ai-orchestration-server-experimental)
- [Developer Utilities](#-developer-utilities)
  - [Gemini CLI](#gemini-cli--googles-command-line-ai-assistant)
  - [Pi Coding Agent](#pi-coding-agent-recommended)
  - [Ollama](#ollama--local-llm-runner)
  - [GCP Bridge](#gcp-bridge-walkthrough-optional)
- [Quick Commands](#-quick-commands)
- [Maintenance](#-maintenance)
- [Troubleshooting](#-troubleshooting)
- [Uninstallation & Reset](#-uninstallation--reset)
- [Code Quality](#-code-quality)
- [License](#-license)

---

## ✨ Key Features

- ⚡ **Zero-Latency Navigation**: In-memory caching for Bash config lookups eliminates ~1-second menu reload delays.
- 🛠 **Smart Repair**: Detects existing installations and provides a 2-second "Repair Only" path to re-apply patches without redundant downloads.
- 🩹 **Zero-Config Patching**: Automatically fixes the `koffi` native bridge and `renameat2` kernel crashes for OpenClaw.
- 🔄 **Automatic State Migrations (v1.17.0+)**: OpenClaw 2026.9.x legacy-state migrations (workspace setup state, session store, exec approvals) run automatically during install/repair — no `openclaw doctor --fix` needed on Android (where it cannot run). Legacy files are archived, never deleted.
- 🔐 **Command Authorization Defaults (v1.17.1+)**: Pins `channels.telegram.dmPolicy` to `allowlist` so slash commands keep working after the 2026.9.x pairing-policy change.
- 📂 **Path Awareness**: Aggressively redirects `/bin/npm`, `/bin/node`, and `/tmp` to Termux-compatible directories using `$PREFIX`.
- 🚀 **PM2 Integration**: Native support for starting, stopping, and monitoring OpenClaw, n8n, Ollama, Paperclip, Pi, and Gemini CLI via PM2 with optimized memory flags.
- 📦 **pnpm Support**: Integrated support for pnpm to speed up installations and save storage space.
- 🧠 **Memory Guard**: Automatically clears memory (PM2 kill) and increases Node.js heap limits (1.5GB+) to prevent crashes on low-RAM devices during updates.
- 🛡 **Surgical Cleanup**: The uninstaller offers **Soft/Deep** options and a **Wipe Stack (Reset)** function that preserves your system packages while cleaning the apps.

---

## 📱 Compatibility

- **OS**: Android 9.0 and above.
- **Architecture**: Tested on `armv8l` (32-bit) and `aarch64` (64-bit) mobile CPUs.
- **Optimization**: Automatically detects system RAM and recommends appropriate memory limits (512MB to 2048MB) for Node.js and n8n workloads.
- **Package Managers**: Supports both **npm** (Standard) and **pnpm** (High Efficiency) for Node.js-based tools.
- **Process Management**: Supports **PM2** (Recommended) and **termux-services** (Native).

> ⚠️ **Architecture Warning**: Tools that depend on Rust-compiled Python extensions (Hermes, Nanobot) are **not supported** on `armv8l`/`armv7l` devices because upstream `maturin` rejects the architecture and pre-built wheels require glibc (not Android's bionic libc).

---

## 📋 Before You Start

- **Close other apps** to free up RAM. The installer auto-detects available memory, but Android's Low Memory Killer may terminate Termux if other apps are running.
- **Connect to Wi-Fi**. Large downloads include Paperclip (~2GB), n8n, and Ollama models. Mobile data plans may be consumed quickly.
- **Ensure free storage**: Paperclip needs ~2GB free; other tools need ~200–500MB each.
- **Dependencies auto-installed**: `jq`, `whiptail`, `gum`, `curl`, `git`, `nodejs`, and `postgresql` are installed automatically by the script if missing.

---

## 🚀 Quick Start

### 1. Environment Setup

Install **Termux** from [F-Droid](https://f-droid.org/en/packages/com.termux/). Do **not** use the Play Store version as it is obsolete.

### 2. Run the Toolkit

Execute the following command to start the interactive toolkit:

```bash
curl -sSL https://raw.githubusercontent.com/niyazmft/droid-ai-toolkit/main/install.sh | bash
```

> 📝 **What happens next:** The script launches an interactive TUI menu (`gum` if available, otherwise `whiptail`). Pick one tool at a time — downloads happen in the terminal. It is safe to re-run the script at any time. Keep Termux open and avoid switching apps during installation, as Android's Low Memory Killer may silently terminate the process. Individual tool installs typically take 2–15 minutes depending on your device and network.
>
> 💡 **Smart Repair (v1.5.0+):** If a tool is already installed, the toolkit offers a **[R] Repair** mode. Use this to fix Android-specific patches in seconds without re-downloading the entire package.
>
> 🔧 **Upgrading OpenClaw to 2026.9.x?** The toolkit automatically runs all required legacy-state migrations (workspace, session store, exec approvals) during **[R] Repair** / **[U] Update** — never run `openclaw doctor --fix` on Android. See [OpenClaw 2026.9.x on Android](#-openclaw-20269x-on-android) for the full patch suite and post-install checklist.

### 3. Choose Your Tools

The toolkit uses a nested **TUI** menu. If `gum` (charm.sh) is installed, you get a premium, color-rich interface with visual separators; otherwise it gracefully falls back to `whiptail`:

| Menu | Tools Available |
| :--- | :--- |
| **🤖 AGENTS** | OpenClaw, Hermes, Nanobot |
| **⚙️ WORKFLOWS** | n8n, Paperclip |
| **🛠 UTILITIES** | Gemini CLI, Pi Coding Agent, Ollama, GCP Bridge |
| **🔧 SERVICES** | PM2 Process Management, Native Background Services (sv) |
| **🗑 UNINSTALL** | Modular uninstall for any installed tool, or WIPE ALL |

### 4. Onboard OpenClaw (If Installed)

Initialize your account and API providers:

```bash
openclaw onboard
```

*Select **QuickStart** and choose an external provider (OpenRouter, OpenAI, etc.).*

### 5. Background Service (Optimized)

To keep tools running even after you close Termux:

1. Run the toolkit and choose **SERVICES → PM2 Process Management**.
2. Select the service you want to start (OpenClaw, n8n, Ollama, Paperclip, etc.).
3. View logs with: `pm2 logs`

---

## 🤖 AI Agents

### OpenClaw — AI Gateway

Multi-channel AI gateway with Telegram, Slack, and Discord support. Automatically patched for Android — see [OpenClaw 2026.9.x on Android](#-openclaw-20269x-on-android) for the complete patch suite and post-install checklist:

- **Koffi patch**: `renameat2` → `rename` to avoid kernel crashes.
- **Path redirection**: `/tmp/openclaw`, `/usr/bin/npm`, `/bin/node` → Termux paths.
- **2026.9.x compatibility**: registerHooks, `/tmp`, SQLite-archive hardlinks, process identity, and Telegram `dmPolicy` are all patched/pinned automatically.
- **Plugin pruning**: Disables 118 stock plugins on install to reduce memory footprint.

| | |
|:---|:---|
| **Install method** | npm/pnpm global |
| **Architecture** | ✅ All architectures supported |
| **Memory** | Varies by plugin load; ~512MB minimum |
| **Critical warning** | Never run `openclaw update` — use toolkit's [R] Repair or [U] Update |

```bash
openclaw onboard          # Configure API keys (run AFTER install)
openclaw gateway status   # Check gateway health
```

> ⚠️ **NEVER** run `openclaw doctor --fix` on Android — it fails at gateway service-owner verification (no systemd) and may hang. Decline if the in-chat agent offers to run it. All of its repairs have automatic or subcommand equivalents — see [Why the Doctor Repair Flow Is Not Needed on Android](#why-the-doctor-repair-flow-is-not-needed-on-android).
>
> 💡 **Version Selection (v1.15.3+):** The toolkit now supports installing a **specific OpenClaw version** (e.g. `2026.6.30`) instead of always pulling `@latest`. Use **[V] Install Specific Version** from the OpenClaw menu.
>
> 💡 **Zulip Plugin (v1.15.3+):** A dedicated sub-menu **[Z] Zulip Plugin** is available under AGENTS → OpenClaw for installing, updating, or uninstalling the Zulip integration (`clawhub:@niyazmft/openclaw-zulip`). You can also pin to a specific plugin version (e.g. `2026.7.0`).

---

### Hermes — Nous Research Agent

AI agent by Nous Research, installed via the official curl installer.

| | |
|:---|:---|
| **Install method** | Upstream curl installer + manual pip fallback |
| **Architecture** | ❌ Not supported on `armv8l`/`armv7l` (maturin/jiter incompatibility) |
| **Memory** | ~512MB RAM minimum |
| **Build deps** | python, clang, rust, make, pkg-config, libffi, openssl, binutils |

```bash
hermes                # Start the agent
```

> **💡 Wheel Cache (v1.15.3+):** After your first successful Hermes install, compiled Python wheels (`cryptography`, `Pillow`, `pydantic-core`, `jiter`, etc.) are automatically saved to `~/.hermes/wheel-cache`. Future **[R] Reinstall** or **[U] Update** operations skip compilation entirely and reuse these cached wheels, dropping install time from ~90 minutes to under 2 minutes on the same device.
>
> **🔧 v1.16.0 Update Fix:** The `[U] Update` path for Hermes now handles upstream code changes gracefully: the Termux fix patch is **stashed before `git pull`** and re-applied after, preventing merge conflicts. Stale `.update-incomplete` markers from interrupted upstream updates are cleaned automatically. Build backends (`maturin`, `pybind11`) are pre-installed so pip can compile new dependency versions from source. PM2 is restarted with `--interpreter bash` to ensure the Hermes bash wrapper runs correctly.
>
> **🔧 v1.15.7 Update Fix:** The `[U] Update` path for Hermes now bypasses upstream `hermes update` on Termux, which internally uses `uv` — a tool that rejects Android-built wheels and attempts to compile itself from source (causing OOM/hang). Instead, the toolkit performs a manual `git pull origin main` followed by `pip install -e .`, ensuring a clean and reliable update. Stale gateway locks are also cleaned automatically after the process kill.

---

### Nanobot — Python AI Agent

General-purpose Python AI agent with Anthropic Claude integration.

| | |
|:---|:---|
| **Install method** | `pip3 install nanobot-ai` |
| **Architecture** | ❌ Not supported on `armv8l`/`armv7l` (maturin/jiter incompatibility) |
| **Memory** | ~512MB RAM minimum |
| **Build deps** | python, pip, setuptools, wheel |

```bash
nanobot --help        # View available commands
nanobot               # Start the interactive agent
```

---

## 🩹 OpenClaw 2026.9.x on Android

OpenClaw 2026.9.x introduced several changes that break Android/Termux installs (module hooks, `/tmp` hardcoding, hardlink-based state migrations, a new Telegram pairing policy). The toolkit handles all of them automatically — this section documents what is patched, what happens during upgrades, and the few steps that need your input.

### Android Patch Suite

All patches are applied by `apply_patches()` on every **[I] Install**, **[R] Repair**, and **[U] Update** — idempotent, with automatic `.bak` backups:

| Patch | Fixes |
|:---|:---|
| **Koffi `renameat2` → `rename`** | Kernel crash on Android when the native bridge calls `renameat2` |
| **`/tmp` → `$TMPDIR`** | Android has no `/tmp`; OpenClaw 2026.9.1 hardcoded it for runtime state |
| **`module.registerHooks` disabled** | Node 24 module-hooks API deadlocks on Android (gateway hangs at startup) |
| **SQLite archive hardlink → copy fallback** | Android blocks `fs.link()` (EACCES); 2026.9.x session migration archives transcripts via hardlinks with `nlink === 2` assertions |
| **Process identity accepts `android` platform** | 2026.9.x guards `/proc/<pid>/stat` parsing with `platform === "linux"` — on Termux it is `"android"`, breaking the cron durable fence (`cron: timer tick failed` every 2s) and file-lock staleness detection |
| **Telegram `dmPolicy` pinned to `allowlist`** | 2026.9.x defaults to `pairing`, which silently revokes slash-command authorization |
| **Path redirection** | `/bin/npm`, `/bin/node`, `/tmp/openclaw` → Termux `$PREFIX`-based paths |
| **Plugin pruning** | Disables 118 stock plugins to reduce memory footprint — only `telegram`, `ollama`, `memory-core` stay enabled; re-enable with `openclaw plugins enable <id>` (see [checklist](#post-install-checklist-user-work)) |

### Automatic Legacy-State Migration

OpenClaw 2026.9.x blocks gateway startup until legacy state is migrated. Upstream normally runs `openclaw doctor --fix` for this — **which cannot run on Android** (it requires a systemd/launchd service owner). The toolkit runs the migrations directly during **[R] Repair** / **[U] Update** whenever legacy files are detected:

| Stage | Migrates | Target |
|:---|:---|:---|
| 1 | Legacy workspace setup state (`openclaw-workspace-state.json`) | `workspace_setup_state` table in `~/.openclaw/state/openclaw.sqlite` |
| 2 | Legacy session store (`sessions.json`, transcripts) | Agent SQLite via `openclaw doctor --session-sqlite import` |
| 3 | Legacy exec-approvals config (`exec-approvals.json`) | `exec_approvals_config` table in the state DB |

- The gateway is paused via PM2 during migration and restarted after.
- **Nothing is deleted** — legacy files and any `.doctor-importing` claims are archived under `~/.openclaw/backup-legacy-state-*`.
- First boot after the migration takes longer than usual (session SQLite import + cron catch-up); this is normal.

### Why the Doctor Repair Flow Is Not Needed on Android

`openclaw doctor --fix` fails on Android **by design**: its first step takes *maintenance ownership* of the gateway — stopping and restarting it through a system service manager (systemd/launchd). Android has neither; the gateway runs under PM2 as an externally managed process, so ownership can never be verified, even when the gateway is already stopped. The result is `Doctor could not enter maintenance ... Gateway service ownership or shutdown could not be verified`, and a hang if the gateway is still running.

That does not leave a functionality gap. Every state-changing repair the doctor performs has an equivalent that is either **automatic** on this toolkit or available through a **doctor subcommand that bypasses the broken maintenance step** (the CLI handles `--session-sqlite` and `--state-sqlite` before it):

| Doctor repair | Android equivalent |
|:---|:---|
| Workspace setup state migration | Automatic — toolkit [R] Repair / [U] Update, Stage 1 |
| Session store migration | Automatic — toolkit Stage 2 (`doctor --session-sqlite import`) |
| Exec-approvals migration | Automatic — toolkit Stage 3 |
| Database schema migrations | Automatic — the gateway applies them at startup |
| Config normalization | Automatic — gateway at load; installer config block |
| Session SQLite repair / compact | `openclaw doctor --session-sqlite dry-run\|import\|compact` — works on Android |
| State SQLite compact | `openclaw doctor --state-sqlite` — works on Android |
| Advisory health notes | Cosmetic — no action required |

If a future OpenClaw release adds a repair the toolkit does not cover yet, prefer its **dedicated subcommand** (e.g. `openclaw doctor --session-sqlite dry-run` to preview) over the full `--fix`, which will still fail at the maintenance step.

### Post-Install Checklist (User Work)

After `openclaw onboard`, complete these steps — the toolkit cannot know your identity:

1. **Configure the model provider and bot token**: `openclaw onboard` (QuickStart with an external provider).
2. **Authorize your Telegram account for commands**: slash commands (`/status`, `/help`, `/commands`, `/goal`) require your **numeric Telegram sender ID** in `commands.ownerAllowFrom` (get it from [@userinfobot](https://t.me/userinfobot)), and `dmPolicy` must be `allowlist`. One snippet covers both:

   ```bash
   cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak
   jq '.channels.telegram.dmPolicy = "allowlist" |
       .commands.ownerAllowFrom = (["YOUR_TELEGRAM_NUMERIC_ID"])' \
       ~/.openclaw/openclaw.json > ~/.openclaw/openclaw.json.tmp && \
       mv ~/.openclaw/openclaw.json.tmp ~/.openclaw/openclaw.json
   pm2 restart openclaw    # or SERVICES -> PM2
   ```

   Channel-prefixed entries for other channels (e.g. `zulip:user@host`) do **not** authorize Telegram commands.
3. **Re-enable the plugins you use**: the installer prunes all stock plugins on **[I] Install** / **[U] Update** to reduce memory footprint (see the [patch suite](#android-patch-suite)) and keeps only `telegram`, `ollama`, and `memory-core` enabled. Any plugin you enabled manually (e.g. `openclaw-honcho`, `brave`, `zulip`) is disabled again by the next full install/update. Re-enable from the CLI:

   ```bash
   openclaw plugins list                 # see what is available and disabled
   openclaw plugins enable <plugin-id>   # e.g. openclaw plugins enable openclaw-honcho
   openclaw plugins doctor               # verify no load issues
   pm2 restart openclaw                  # or SERVICES -> PM2
   ```

   Pruning is intentional — every enabled plugin costs RAM on low-memory devices, so re-enable only what you actually use.
4. **Test from the real channel**: send `/status` in Telegram. Do **not** test via `openclaw gateway call chat.send` — it authenticates as the webchat sender (a `sha256:...` identity) and always shows the empty-reply fallback.

### Hard Warnings

- ❌ **Never run `openclaw update`** — it overwrites the Android patches. Use the toolkit's **[R] Repair** / **[U] Update**.
- ❌ **Never run `openclaw doctor --fix` on Android** — it fails at gateway service-owner verification and may hang. If the in-chat agent offers to run it, decline; the migrations it proposes were already applied by the toolkit. Every repair it performs has an Android equivalent — see [Why the Doctor Repair Flow Is Not Needed on Android](#why-the-doctor-repair-flow-is-not-needed-on-android).
- ❌ **Do not hand-edit the migration gates** — skipping migrations leaves half-migrated state (old sessions invisible, gateway retry loops). Run the toolkit repair instead.

Diagnostic pointers: gateway file log at `$TMPDIR/openclaw-*/openclaw-<date>.log`, PM2 console at `~/.pm2/logs/openclaw-out.log` / `openclaw-error.log`, startup-failure bundles at `~/.openclaw/logs/stability/`.

---

## ⚙ Workflows & Automation

### n8n — Workflow Automation Server

Professional-grade workflow automation with an optional GCP bridge for secure public access.

| | |
|:---|:---|
| **Install method** | npm/pnpm global (`n8n@latest`) |
| **Architecture** | ✅ All architectures supported |
| **Memory** | Auto-capped to `min(2048, max(512, RAM * 0.75))` |
| **Extras** | Watchdog cron, autossh GCP tunnel, tmux session manager |

```bash
n8n start             # Start manually
~/n8n_server/scripts/n8n-monitor.sh   # Watchdog restart
```

Access locally at `http://localhost:5678`.

> ⚠️ **Warning:** The installer forcibly kills running OpenClaw, n8n, and PM2 processes during setup to free memory. If you have active workflows or conversations, save your work before installing or updating n8n.
>
> 📄 **License note:** n8n is under the *Sustainable Use License*. See `ATTRIBUTIONS.md` for redistribution terms.

---

### Paperclip — AI Orchestration Server (EXPERIMENTAL)

Open-source orchestration server for managing teams of AI agents.

| | |
|:---|:---|
| **Install method** | Delegates to `paperclip_manual_install.sh` |
| **Architecture** | ✅ All architectures supported (with caveats) |
| **Memory** | ~2GB free RAM recommended; LMK-resilient install |
| **Requirements** | 2GB+ free storage · pnpm 9.15+ · PostgreSQL running |
| **Database** | External PostgreSQL (`pkg install postgresql`) |
| **Build** | Prebuilt `dist/` tarball (primary) or local tsc build (fallback, ~65 min) |

The standalone installer handles:

1. Cloning, patching (removes `embedded-postgres`, drops `ui` workspace).
2. pnpm install with LMK-kill detection and retry.
3. Symlink repair for `tsc`, `tsx`, `esbuild`.
4. Download of prebuilt `dist/` and `ui-dist` tarballs from GitHub releases.
5. PostgreSQL bootstrap with stale-process cleanup.
6. Secret generation and PM2 ecosystem file creation.

```bash
cd ~/paperclip
export PAPERCLIP_HOME=~/paperclip
export DATABASE_URL=postgres://paperclip:paperclip@localhost:5432/paperclip
pnpm paperclipai onboard       # One-time setup
pnpm paperclipai configure     # Enable LAN access
pm2 start ecosystem.config.cjs # Start server
```

> ⚠️ **Reinstalling Paperclip wipes `config.json` and secrets.** The installer deletes `~/paperclip` and reclones, which removes `instances/default/config.json` and `config/paperclip.env`. **Your database (workflows, users, history) survives** in PostgreSQL, but you must **re-run `pnpm paperclipai onboard`** after reinstall to regenerate config and secrets. Back up `~/paperclip/instances/default/` before reinstalling if you want to preserve settings. UI is pre-built and downloaded as a tarball — never built on-device (Vite/esbuild requires ~4–6 GB transient RSS).

---

## 🛠 Developer Utilities

### Gemini CLI — Google's Command-Line AI Assistant

| | |
|:---|:---|
| **Install method** | npm/pnpm global (`@google/gemini-cli@latest`) |
| **Architecture** | ✅ All architectures supported |
| **Memory** | ~512MB RAM minimum |
| **Build deps** | `python`, `make`, `clang`, `pkg-config` (auto-installed if missing) |
| **Patch** | `fs.promises.rename` → `copyFile+unlink` to prevent Android `ENOENT` |

```bash
gemini --help         # View available commands
gemini                # Start interactive session
```

> 💡 **Smart Repair/Update**: Re-running the toolkit for Gemini CLI offers [R] Repair (re-apply patches) or [U] Update (latest version).

---

### Pi Coding Agent (Recommended)

The high-performance coding agent optimized for the Termux environment.

| | |
|:---|:---|
| **Install method** | npm/pnpm global (`@earendil-works/pi-coding-agent@latest`) |
| **Architecture** | ✅ All architectures supported |
| **Memory** | ~512MB RAM minimum |

```bash
pi --help             # View available commands
pi                    # Start the interactive agent
```

The toolkit automatically creates `~/.pi/agent/AGENTS.md` with Termux-specific paths (`$HOME`, `$PREFIX`, `termux-open-url`) so the agent never hallucinates standard Linux paths. Legacy `@mariozechner/pi-coding-agent` installations are automatically detected and migrated.

> ⚠️ **Warning:** If you already have a command named `pi` on your system, the installer will remove it to avoid conflicts.

---

### Ollama — Local LLM Runner

Run large language models locally. Installed via Termux's native package manager.

| | |
|:---|:---|
| **Install method** | `pkg install ollama` (Termux native) |
| **Architecture** | ✅ All architectures supported |
| **Memory** | ~1GB+ RAM recommended for 7B models |

```bash
ollama serve          # Start the server
ollama pull llama3    # Download a model
ollama run llama3     # Run a model
```

Use **SERVICES → PM2** to keep Ollama running in the background. Downloaded models are stored in `~/.ollama` and preserved during uninstall.

---

### GCP Bridge Walkthrough (Optional)

To expose your n8n instance securely to the internet (`https://yourdomain.com`), follow this walkthrough:

#### Step 1: Prepare the GCP VM

1. **Create Instance**: In GCP Console, create an `e2-micro` VM (Debian/Ubuntu).
2. **Static IP**: Reserve a static external IP for this VM.
3. **Firewall**: Allow **TCP 80** (HTTP), **443** (HTTPS), and **22** (SSH).

#### Step 2: Set up DNS

1. Point your domain (e.g., `n8n.example.com`) to the GCP VM's static IP.

#### Step 3: Configure Nginx (on GCP VM)

1. Install Nginx and Certbot: `sudo apt install nginx certbot python3-certbot-nginx`
2. Create a site config that proxies to `localhost:5678`.
3. Secure it with SSL: `sudo certbot --nginx -d yourdomain.com`

#### Step 4: Establish the Tunnel

1. Run the toolkit on your Android device and choose **SERVICES → Configure GCP Bridge**.
2. Follow the prompts to enter your VM IP and Domain.
3. Copy the generated **SSH Public Key** and paste it into the GCP VM's `~/.ssh/authorized_keys` file.
4. The monitor script will now automatically maintain a secure `autossh` tunnel to the VM.

---

## 📊 Quick Commands

| Tool | Command |
|:---|:---|
| **OpenClaw** | `openclaw` · `openclaw gateway status` · `sv restart openclaw` |
| **Ollama** | `ollama serve` · `ollama pull llama3` · `ollama run llama3` |
| **Hermes** | `hermes` |
| **Nanobot** | `nanobot` |
| **Pi** | `pi` |
| **Paperclip** | `pm2 start ~/paperclip/ecosystem.config.cjs` |
| **n8n** | `n8n start` |
| **Gemini CLI** | `gemini` |
| **PM2** | `pm2 status` · `pm2 logs` · `pm2 restart all` · `pm2 stop all` |
| **Native Services** | `sv up n8n` · `sv down n8n` · `sv status openclaw` |
| **Wake Lock** | `termux-wake-lock` (prevents Android from killing background processes) |

---

## 🔄 Maintenance

### 🛡 Safe Updates & Smart Repair

**⚠️ WARNING:** Never use the built-in `openclaw update` command. It will overwrite the Android patches and break the application.

To update or repair safely, re-run `install.sh`, choose the tool's **Install/Repair** option, then pick the appropriate mode:

| Mode | What it does | Time | Use when... |
|:---|:---|:---|:---|
| **[R] Repair** | Re-applies Android patches, fixes symlinks, restores configs | ~2 seconds | The app broke after a Termux update or system change |
| **[U] Update** | Downloads the latest upstream version + re-applies patches | 1–10 minutes | You want new features or bug fixes |

> 💡 **Hermes Wheel Cache:** Compiled wheels are cached locally after the first install. Reinstalls on the same device use prebuilt wheels and skip Rust/C compilation. See the Hermes section above for details.
> 💡 **Version Pinning:** The toolkit installs the latest available version of each tool by default for maximum compatibility and security. Where offered (OpenClaw), **[V] Install Specific Version** pins an exact release instead.

### 🔋 Battery Optimization

To prevent Android from killing the background process:

```bash
termux-wake-lock
```

---

## 🛠 Troubleshooting

### If an install fails or hangs

1. **Re-run the script**: `curl -sSL https://raw.githubusercontent.com/niyazmft/droid-ai-toolkit/main/install.sh | bash` — it is safe to run again.
2. **Select the same tool** from the menu and choose **[R] Repair**.
3. **Check the log** at `~/droid_ai_toolkit.log` for the exact failure reason.
4. **Free up resources**: Close other apps, ensure Wi-Fi is stable, and verify you have enough free storage.

### Common Issues

- **Telegram Plugin Not Available**: This toolkit attempts to pre-fix this. If it persists, finish onboarding and run: `openclaw channels add --channel telegram`.
- **Homebrew Recommendations**: **Ignore them.** Homebrew is not supported on Android. Use `pkg install <package>` for any missing dependencies.
- **Node.js Errors**: Run the toolkit's **Install/Repair** option to reset environment locks and paths.
- **Ollama Not Found After Install**: Restart Termux or run `source ~/.bashrc` to refresh your PATH.
- **Hermes/Nanobot Fail on armv8l**: Expected — these tools require Rust compilation via maturin, which does not support the `armv8l` architecture. Use an `aarch64` device instead.
- **Paperclip LMK Kill During Install**: Expected on 3–4GB RAM devices. The installer detects the kill, verifies packages are present, and continues. If it fails entirely, ensure you have at least 2GB free RAM before starting.
- **OpenClaw Stuck in Startup Retry Loop** (log shows `Legacy workspace setup state requires migration`, `Legacy session store requires migration`, or `Legacy exec approvals exist`): OpenClaw 2026.9.x blocks startup until legacy state is migrated, and `openclaw doctor --fix` cannot run on Android. **Re-run the toolkit and choose OpenClaw → [R] Repair** — all three migrations run automatically (gateway paused, legacy files archived under `~/.openclaw/backup-legacy-state-*`). Do not hand-migrate or delete the workspace. See [OpenClaw 2026.9.x on Android](#-openclaw-20269x-on-android).
- **OpenClaw Cron Logs `timer tick failed` / `cannot acquire a durable fence`**: Fixed automatically by the toolkit's process-identity patch (Android reports `process.platform = "android"`, not `"linux"`). Re-run **[R] Repair** if you see it after a manual upgrade.
- **OpenClaw Slash Commands Reply "No reply was generated"** (and `/goal` says "You are not authorized"): slash commands are authorization-gated; regular messages are not, so the bot otherwise works. On 2026.9.x `channels.telegram.dmPolicy` defaults to `pairing`, and `commands.ownerAllowFrom` must contain your **numeric** Telegram sender ID (channel-prefixed entries for other channels, e.g. `zulip:user@host`, do not authorize Telegram commands). **Fix:** run the [Post-Install Checklist](#post-install-checklist-user-work) — its snippet pins `dmPolicy = "allowlist"` and sets `commands.ownerAllowFrom` in one step; the installer applies both automatically on fresh installs and repairs. Diagnostic hints live in `~/.pm2/logs/openclaw-error.log` (look for `Invalid allowFrom entry` / `skipped:reply_operation_aborted`).

---

## 🗑 Uninstallation & Reset

Run the toolkit and select **UNINSTALL** to access the modular uninstallation menu. The order mirrors the on-device menu. Each option provides a detailed summary of the impact before you confirm:

- **Remove OpenClaw**: Choice of **Soft Uninstall** (keeps memories/skills) or **Deep Uninstall** (full wipe). Automatically cleans up PM2 and background services.
- **Remove n8n**: Surgically kills the GCP tunnel (port 5678) and removes the watchdog cron.
- **Remove Gemini CLI**: Full removal of application binaries and configurations.
- **Remove Hermes**: Runs the official uninstaller if available, otherwise removes directories manually.
- **Remove Ollama**: Removes the package. Downloaded models in `~/.ollama` are preserved.
- **Remove Pi**: Full removal of global package and configuration.
- **Remove Paperclip**: Stops the PM2 service and preserves the source code and PostgreSQL database.
- **Remove Nanobot**: pip uninstall + directory cleanup.
- **Wipe Software Stack (Reset)**: Batch "Deep Uninstall" of all applications. **Safe Reset**: Cleans all toolkit-specific data but **preserves system packages** (Node.js, Git, Python, etc.) so your other Termux apps don't break.

---

## 🛠 Code Quality

This project implements a "Zero-Waste" and "Self-Healing" quality gate to maintain high standards for all contributions.

### Tools Used

- **ESLint v10**: Modern JavaScript and JSON linting via Flat Config.
- **Stylelint**: Standardized CSS quality checks.
- **Markdownlint**: Documentation consistency enforcement.
- **ShellCheck**: Bash script static analysis.
- **Husky & lint-staged**: Automated pre-commit hooks to auto-fix code.
- **Self-Healing**: Custom Python scripts to safely refactor unused code.

### Usage

Run the full quality audit locally:

```bash
pnpm run lint:all
```

---

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

---

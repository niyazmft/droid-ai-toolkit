# 🤖 Droid AI Toolkit (Termux)

<p align="center">
  <img src="./assets/Cover.png" width="100%" alt="Droid AI Toolkit Cover">
</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-1.11.0-blue.svg)](https://github.com/niyazmft/droid-ai-toolkit)
[![Platform](https://img.shields.io/badge/Platform-Android%20(Termux)-green.svg)](https://termux.dev/)

A high-performance, automated toolkit for running AI tools — [OpenClaw](https://github.com/the-claw-team/openclaw), [Gemini CLI](https://github.com/google/gemini-cli), [n8n](https://github.com/n8n-io/n8n), [Ollama](https://ollama.com), [Hermes](https://hermes-agent.nousresearch.com), [Nanobot](https://github.com/nanobot-ai/nanobot), [Pi](https://github.com/mariozechner/pi-coding-agent), and [Paperclip](https://github.com/paperclipai/paperclip) — natively on non-rooted Android devices. This toolkit bypasses kernel restrictions (`renameat2`), patches hardcoded system paths, and optimizes execution for mobile environments.

---

## 📱 Compatibility

- **OS**: Android 9.0 and above.
- **Architecture**: Tested on `armv8l` (32-bit), `aarch64` (64-bit), and `x86_64` CPUs.
- **Optimization**: Automatically detects system RAM and recommends appropriate memory limits (512MB to 2048MB) for Node.js and n8n workloads.
- **Package Managers**: Supports both **npm** (Standard) and **pnpm** (High Efficiency) for Node.js-based tools.
- **Process Management**: Supports **PM2** (Recommended) and **termux-services** (Native).

> ⚠️ **Architecture Warning**: Tools that depend on Rust-compiled Python extensions (Hermes, Nanobot) are **not supported** on `armv8l`/`armv7l` devices because upstream `maturin` rejects the architecture and pre-built wheels require glibc (not Android's bionic libc).

---

## 📋 Before You Start

- **Close other apps** to free up RAM. The installer auto-detects available memory, but Android's Low Memory Killer may terminate Termux if other apps are running.
- **Connect to Wi-Fi**. Large downloads include Paperclip (~2GB), n8n, and Ollama models. Mobile data plans may be consumed quickly.
- **Ensure free storage**: Paperclip needs ~2GB free; other tools need ~200–500MB each.
- **Install Termux from F-Droid** (not Play Store). The Play Store version is obsolete and lacks required packages.
- **Dependencies auto-installed**: `jq`, `whiptail`, `curl`, `git`, `nodejs`, and `postgresql` are installed automatically by the script if missing.

---

## 🚀 Quick Start

### 1. Environment Setup

Install **Termux** from [F-Droid](https://f-droid.org/en/packages/com.termux/). Do **not** use the Play Store version as it is obsolete.

### 2. Run the Toolkit

Execute the following command to start the interactive toolkit:

```bash
curl -sSL https://raw.githubusercontent.com/niyazmft/droid-ai-toolkit/main/install.sh | bash
```

> 📝 **What happens next:** The script launches a whiptail menu. Pick one tool at a time — downloads happen in the terminal. It is safe to re-run the script at any time. Keep Termux open and avoid switching apps during installation, as Android's Low Memory Killer may silently terminate the process. Individual tool installs typically take 2–15 minutes depending on your device and network.
>
> 💡 **Smart Repair (v1.5.0+):** If a tool is already installed, the toolkit offers a **[R] Repair** mode. Use this to fix Android-specific patches in seconds without re-downloading the entire package.

### 3. Choose Your Tools

The toolkit uses a nested **whiptail TUI** menu:

| Menu | Tools Available |
| :--- | :--- |
| **🤖 AGENTS** | OpenClaw, Hermes, Nanobot, Ollama, Pi Coding Agent |
| **⚙️ WORKFLOWS** | n8n, Paperclip |
| **🛠 UTILITIES** | Gemini CLI |
| **🔧 SERVICES** | PM2 Process Management, Native Background Services, GCP Bridge |
| **🗑 UNINSTALL** | Modular uninstall for any installed tool |

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

## ✨ Key Features

- 🛠 **Smart Repair**: Detects existing installations and provides a 2-second "Repair Only" path to re-apply patches without redundant downloads.
- 🩹 **Zero-Config Patching**: Automatically fixes the `koffi` native bridge and `renameat2` kernel crashes for OpenClaw.
- 📂 **Path Awareness**: Aggressively redirects `/bin/npm`, `/bin/node`, and `/tmp` to Termux-compatible directories using `$PREFIX`.
- 🚀 **PM2 Integration**: Native support for starting, stopping, and monitoring OpenClaw, n8n, Ollama, Paperclip, Pi, and Gemini CLI via PM2 with optimized memory flags.
- 📦 **pnpm Support**: Integrated support for pnpm to speed up installations and save storage space.
- 🧠 **Memory Guard**: Automatically clears memory (PM2 kill) and increases Node.js heap limits (1.5GB+) to prevent crashes on low-RAM devices during updates.
- 🛡 **Surgical Cleanup**: The uninstaller offers **Soft/Deep** options and a **Wipe Stack (Reset)** function that preserves your system packages while cleaning the apps.
- 🧩 **Gemini CLI Support**: Dedicated installer with NDK environment optimizations and `fs.promises.rename` → `copyFile+unlink` patch to prevent Android `ENOENT`.
- 🦙 **Ollama Support**: One-click install via Termux native package (`pkg install ollama`).
- ⚡ **Hermes Support**: One-click install via official curl installer (aarch64/x86_64 only).
- 🤖 **Nanobot Support**: pip install with `--no-build-isolation` for pre-seeded dependencies (aarch64/x86_64 only).
- 🥧 **Pi Coding Agent (Recommended)**: npm/pnpm global install with Termux-specific `AGENTS.md` context.
- 📎 **Paperclip (EXPERIMENTAL)**: Delegates to `paperclip_manual_install.sh` which handles clone, patches, pnpm install, prebuilt tarball download, PostgreSQL bootstrap, and PM2 ecosystem file generation.

---

## 🤖 AI Agents

### OpenClaw — AI Gateway

Multi-channel AI gateway with Telegram, Slack, and Discord support. Automatically patched for Android:

- **Koffi patch**: `renameat2` → `rename` to avoid kernel crashes.
- **Path redirection**: `/tmp/openclaw`, `/usr/bin/npm`, `/bin/node` → Termux paths.
- **Plugin pruning**: Disables 118 stock plugins on install to reduce memory footprint.

| | |
|:---|:---|
| **Install method** | npm/pnpm global |
| **Architecture** | ✅ All architectures supported |
| **Memory** | Varies by plugin load; ~512MB minimum |
| **Critical warning** | Never run `openclaw update` — use toolkit's [R] Repair or [U] Update |

```bash
openclaw onboard          # Configure API keys
openclaw doctor --fix     # Repair schema issues
```

> ⚠️ **NEVER** run `openclaw update` — it overwrites Android patches. Use the toolkit's **[R] Repair** or **[U] Update** instead.

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

> On `armv8l`/`armv7l`, the toolkit will display a graceful error message and skip installation.

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

> On `armv8l`/`armv7l`, the toolkit will display a graceful error message and skip installation.

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

### Pi Coding Agent (Recommended)

The high-performance coding agent by Mario Zechner, optimized for the Termux environment.

| | |
|:---|:---|
| **Install method** | npm/pnpm global (`@mariozechner/pi-coding-agent`) |
| **Architecture** | ✅ All architectures supported |
| **Memory** | ~512MB RAM minimum |

```bash
pi --help             # View available commands
pi                    # Start the interactive agent
```

The toolkit automatically creates `~/.pi/agent/AGENTS.md` with Termux-specific paths (`$HOME`, `$PREFIX`, `termux-open-url`) so the agent never hallucinates standard Linux paths.

> ⚠️ **Warning:** If you already have a command named `pi` on your system, the installer will remove it to avoid conflicts.

---

## ⚙️ Workflows & Automation

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

> ⚠️ **Reinstalling Paperclip wipes `config.json` and secrets.** The installer deletes `~/paperclip` and reclones, which removes `instances/default/config.json` and `config/paperclip.env`. **Your database (workflows, users, history) survives** in PostgreSQL, but you must **re-run `pnpm paperclipai onboard`** after reinstall to regenerate config and secrets. Back up `~/paperclip/instances/default/` before reinstalling if you want to preserve settings. **Requirements:** ~2GB free RAM, 2GB+ storage, pnpm 9.15+, PostgreSQL running. UI is pre-built and downloaded as a tarball — never built on-device (Vite/esbuild requires ~4–6 GB transient RSS).

---

## 🛠 Utilities

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

## 🌐 GCP Bridge Walkthrough (Optional)

To expose your n8n instance securely to the internet (`https://yourdomain.com`), follow this walkthrough:

### Step 1: Prepare the GCP VM

1. **Create Instance**: In GCP Console, create an `e2-micro` VM (Debian/Ubuntu).
2. **Static IP**: Reserve a static external IP for this VM.
3. **Firewall**: Allow **TCP 80** (HTTP), **443** (HTTPS), and **22** (SSH).

### Step 2: Set up DNS

1. Point your domain (e.g., `n8n.example.com`) to the GCP VM's static IP.

### Step 3: Configure Nginx (on GCP VM)

1. Install Nginx and Certbot: `sudo apt install nginx certbot python3-certbot-nginx`
2. Create a site config that proxies to `localhost:5678`.
3. Secure it with SSL: `sudo certbot --nginx -d yourdomain.com`

### Step 4: Establish the Tunnel

1. Run the toolkit on your Android device and choose **SERVICES → Configure GCP Bridge**.
2. Follow the prompts to enter your VM IP and Domain.
3. Copy the generated **SSH Public Key** and paste it into the GCP VM's `~/.ssh/authorized_keys` file.
4. The monitor script will now automatically maintain a secure `autossh` tunnel to the VM.

---

## 🗑 Uninstallation & Reset

Run the toolkit and select **UNINSTALL** to access the modular uninstallation menu. Each option provides a detailed summary of the impact before you confirm:

- **Remove OpenClaw**: Choice of **Soft Uninstall** (keeps memories/skills) or **Deep Uninstall** (full wipe). Automatically cleans up PM2 and background services.
- **Remove Gemini CLI**: Full removal of application binaries and configurations.
- **Remove n8n**: Surgically kills the GCP tunnel (port 5678) and removes the watchdog cron.
- **Remove Ollama**: Removes the package. Downloaded models in `~/.ollama` are preserved.
- **Remove Hermes**: Runs the official uninstaller if available, otherwise removes directories manually.
- **Remove Nanobot**: pip uninstall + directory cleanup.
- **Remove Pi**: Full removal of global package and configuration.
- **Remove Paperclip**: Stops the PM2 service and preserves the source code and PostgreSQL database.
- **Wipe Software Stack (Reset)**: Batch "Deep Uninstall" of all applications. **Safe Reset**: Cleans all toolkit-specific data but **preserves system packages** (Node.js, Git, Python, etc.) so your other Termux apps don't break.

---

## 📊 Management Commands

| Action | Command |
| :--- | :--- |
| **Check Health** | `sv status openclaw` |
| **View Live Logs** | `tail -f ~/.openclaw/logs/current` |
| **Stop Service** | `sv down openclaw` |
| **Restart Gateway** | `sv restart openclaw` |
| **Force Kill (Stray)** | `pkill -9 -f openclaw` |
| **Fix Environment** | `openclaw doctor` |
| **Find Access Token** | `grep "token" ~/.openclaw/openclaw.json` |
| **Ollama: Start Server** | `ollama serve` |
| **Ollama: Pull Model** | `ollama pull llama3` |
| **Ollama: Run Model** | `ollama run llama3` |
| **Hermes: Start** | `hermes` |
| **Nanobot: Start** | `nanobot` |
| **Pi: Start** | `pi` |
| **Paperclip: Start** | `pm2 start ~/paperclip/ecosystem.config.cjs` |
| **n8n: Start** | `n8n start` |
| **Gemini CLI: Start** | `gemini` |
| **PM2: View Logs** | `pm2 logs` |
| **PM2: View Status** | `pm2 status` |
| **PM2: Restart All** | `pm2 restart all` |
| **PM2: Stop All** | `pm2 stop all` |
| **Native Service: Start n8n** | `sv up n8n` |
| **Native Service: Stop n8n** | `sv down n8n` |

---

## 🔄 Maintenance

### 🛡 Safe Updates & Smart Repair

**⚠️ WARNING:** Never use the built-in `openclaw update` command. It will overwrite the Android patches and break the application.

To update or repair safely, re-run `install.sh`, choose the tool's **Install/Repair** option, then pick the appropriate mode:

| Mode | What it does | Time | Use when... |
|:---|:---|:---|:---|
| **[R] Repair** | Re-applies Android patches, fixes symlinks, restores configs | ~2 seconds | The app broke after a Termux update or system change |
| **[U] Update** | Downloads the latest upstream version + re-applies patches | 1–10 minutes | You want new features or bug fixes |

> 💡 **Latest Version:** This toolkit always installs the latest available version of each tool to ensure maximum feature compatibility and security.

### 🔋 Battery Optimization

To prevent Android from killing the background process, run:

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
- **Hermes/Nanobot Fail on armv8l**: Expected — these tools require Rust compilation via maturin, which does not support the `armv8l` architecture. Use an `aarch64` or `x86_64` device instead.
- **Paperclip LMK Kill During Install**: Expected on 3–4GB RAM devices. The installer detects the kill, verifies packages are present, and continues. If it fails entirely, ensure you have at least 2GB free RAM before starting.

---

## 🛠 Code Quality

This project implements a "Zero-Waste" and "Self-Healing" quality gate to maintain high standards for all contributions.

### Tools Used

- **ESLint v10**: Modern JavaScript and JSON linting via Flat Config.
- **Stylelint**: Standardized CSS quality checks.
- **Markdownlint**: Documentation consistency enforcement.
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

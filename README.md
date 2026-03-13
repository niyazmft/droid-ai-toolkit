# 🦞 OpenClaw Android (Termux) Toolkit

<p align="center">
  <img src="./assets/Cover.png" width="100%" alt="OpenClaw Android Cover">
</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-1.3.5-blue.svg)](https://github.com/niyazmft/openclaw-android-toolkit)
[![Platform](https://img.shields.io/badge/Platform-Android%20(Termux)-green.svg)](https://termux.dev/)

A high-performance, automated toolkit for running [OpenClaw](https://github.com/the-claw-team/openclaw), [Gemini CLI](https://github.com/google/gemini-cli), and **n8n Server** natively on non-rooted Android devices. This toolkit bypasses kernel restrictions (`renameat2`), patches hardcoded system paths, and optimizes execution for mobile environments.

---

## 📱 Compatibility

- **OS**: Android 9.0 and above.
- **Architecture**: Tested on `armv8l` (32-bit) and `aarch64` (64-bit) CPUs.
- **Optimization**: Automatically detects system RAM and recommends appropriate memory limits (512MB to 2048MB) for Node.js and n8n workloads.
- **Package Managers**: Supports both **npm** (Standard) and **pnpm** (High Efficiency) for all tools.
- **Process Management**: Supports **PM2** (Recommended) and **termux-services** (Native).

---

## 🚀 Quick Start

### 1. Environment Setup
Install **Termux** from [F-Droid](https://f-droid.org/en/packages/com.termux/). Do **not** use the Play Store version as it is obsolete.

### 2. Run the Toolkit
Execute the following command to start the interactive toolkit:
```bash
curl -sSL https://raw.githubusercontent.com/niyazmft/openclaw-android-toolkit/main/install.sh | bash
```
> 💡 **Note:** Select **Option 1** for OpenClaw, **Option 2** for Gemini CLI, or **Option 3** for n8n. You will be prompted to choose between **npm** or **pnpm**.

### 3. Onboard (For OpenClaw)
Initialize your account and API providers:
```bash
openclaw onboard
```
*Select **QuickStart** and choose an external provider (OpenRouter, OpenAI, etc.).*

### 4. Background Service (Optimized)
To keep OpenClaw running even after you close Termux:
1. Run the toolkit again and choose **Option 6 (Manage PM2 Processes)**.
2. Select **Start OpenClaw with PM2**.
3. View logs with: `pm2 logs openclaw`

---

## ✨ Key Features

- 🛠 **Zero-Config Patching**: Automatically fixes the `koffi` native bridge and `renameat2` kernel crashes for OpenClaw.
- 📂 **Path Awareness**: Aggressively redirects `/bin/npm`, `/bin/node`, and `/tmp` to Termux-compatible directories.
- 🚀 **PM2 Integration**: Native support for starting, stopping, and monitoring OpenClaw and n8n via PM2 with optimized memory flags.
- 📦 **pnpm Support**: Integrated support for pnpm to speed up installations and save storage space.
- 🧠 **Memory Guard**: Automatically clears memory (PM2 kill) and increases Node.js heap limits (1.5GB+) to prevent crashes on low-RAM devices during updates.
- 🛡 **Data Preservation**: The uninstaller now offers a **Soft Uninstall** (retains your memory, skills, and extensions) and a **Deep Uninstall** (full wipe).
- 🧩 **Gemini CLI Support**: Dedicated installer with NDK environment optimizations.

<p align="center">
  <img src="./assets/4-gemini_cli.jpg" width="300" alt="Gemini CLI Interface">
</p>

---

## 📱 n8n Android Infrastructure

This toolkit now includes a professional-grade setup for running **n8n** on Android with an optional GCP bridge for secure public access.

### 1. Installation
Run the toolkit and choose **Option 3 (Install/Repair n8n Server)**. This will:
- Install n8n, Python 3, and process monitors.
- Configure a 5-minute watchdog (Cron) to ensure 24/7 uptime.
- Set up a 2GB memory cap optimized for high-performance workflows.

### 2. Monitoring & Control
- **Manual Restart**: Choice **Option 5** in the toolkit or run `~/n8n_server/scripts/n8n-monitor.sh`.
- **View n8n Dashboard**: If not using a bridge, access locally at `http://localhost:5678`.

---

## 🌐 GCP Bridge Walkthrough (Optional)

To expose your n8n instance securely to the internet (`https://yourdomain.com`), follow this walkthrough:

### Step 1: Prepare the GCP VM
1.  **Create Instance**: In GCP Console, create an `e2-micro` VM (Debian/Ubuntu).
2.  **Static IP**: Reserve a static external IP for this VM.
3.  **Firewall**: Allow **TCP 80** (HTTP), **443** (HTTPS), and **22** (SSH).

### Step 2: Set up DNS
1.  Point your domain (e.g., `n8n.example.com` or a DuckDNS subdomain) to the GCP VM's static IP.

### Step 3: Configure Nginx (on GCP VM)
1.  Install Nginx and Certbot: `sudo apt install nginx certbot python3-certbot-nginx`
2.  Create a site config that proxies to `localhost:5678`.
3.  Secure it with SSL: `sudo certbot --nginx -d yourdomain.com`
4.  (Optional) Add Basic Auth for an extra layer of security.

### Step 4: Establish the Tunnel
1.  Run the toolkit on your Android device and choose **Option 4 (Configure GCP Bridge)**.
2.  Follow the prompts to enter your VM IP and Domain.
3.  Copy the generated **SSH Public Key** and paste it into the GCP VM's `~/.ssh/authorized_keys` file.
4.  The monitor script will now automatically maintain a secure `autossh` tunnel to the VM.

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

---

## 🔄 Maintenance

### 🛡 Safe Updates
**⚠️ WARNING:** Never use the built-in `openclaw update` command. It will overwrite the Android patches and break the application.

To update safely:
1. Run the `install.sh` script.
2. Choose **Option 1 (Install/Repair)**. 
The toolkit will fetch the latest version and re-apply all necessary patches automatically.

### 🔋 Battery Optimization
To prevent Android from killing the background process, run:
```bash
termux-wake-lock
```

---

## 🛠 Troubleshooting

- **Telegram Plugin Not Available**: This toolkit attempts to pre-fix this. If it persists, finish onboarding and run: `openclaw channels add --channel telegram`.
- **Homebrew Recommendations**: **Ignore them.** Homebrew is not supported on Android. Use `pkg install <package>` for any missing dependencies.
- **Node.js Errors**: Run the toolkit's **Install/Repair** option to reset environment locks and paths.

---

## 📄 License
Distributed under the MIT License. See `LICENSE` for more information.

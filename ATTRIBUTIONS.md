# Third-Party Attributions

This project uses several open-source and fair-code components. Below is a list of primary dependencies, their licenses, and links to their source code.

## Primary Components

| Component | License | Source / Repository |
| :--- | :--- | :--- |
| **OpenClaw** | [MIT](https://opensource.org/licenses/MIT) | [github.com/openclaw/openclaw](https://github.com/openclaw/openclaw) |
| **Gemini CLI** | [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) | [github.com/google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli) |
| **Pi Agent** | [MIT](https://opensource.org/licenses/MIT) | [github.com/mariozechner/pi-coding-agent](https://github.com/mariozechner/pi-coding-agent) |
| **n8n** | [Sustainable Use License](https://github.com/n8n-io/n8n/blob/master/LICENSE.md) | [github.com/n8n-io/n8n](https://github.com/n8n-io/n8n) |
| **Paperclip** | [MIT](https://github.com/paperclipai/paperclip/blob/master/LICENSE) | [github.com/paperclipai/paperclip](https://github.com/paperclipai/paperclip) |
| **Koffi** | [MIT](https://opensource.org/licenses/MIT) | [codeberg.org/Koromix/rygel](https://codeberg.org/Koromix/rygel) |
| **termux-services** | [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) | [github.com/termux/termux-services](https://github.com/termux/termux-services) |

## System & Environment Tools

The following tools are installed as part of the Termux environment setup:

- **Node.js**: [MIT](https://github.com/nodejs/node/blob/main/LICENSE)
- **Golang**: [BSD-3-Clause](https://go.dev/LICENSE)
- **FFmpeg**: [LGPL-2.1+](https://ffmpeg.org/legal.html)
- **Python 3**: [PSF License](https://docs.python.org/3/license.html)
- **Git**: [GPL-2.0](https://github.com/git/git/blob/master/COPYING)
- **jq**: [MIT](https://github.com/jqlang/jq/blob/master/COPYING)
- **tmux**: [ISC License](https://github.com/tmux/tmux/blob/master/COPYING)
- **libvips**: [LGPL-2.1+](https://github.com/libvips/libvips/blob/master/COPYING)
- **autossh**: [BSD-style](https://github.com/Luciano-S/autossh/blob/master/LICENSE)
- **cronie**: [BSD-3-Clause / GPL-2.0](https://github.com/cronie-crond/cronie/blob/master/COPYING)

## Compliance & Limitations

- **Commercial Redistribution**: Usage of **n8n** is governed by the *Sustainable Use License*. While free for personal and internal business use, it restricts commercial reselling or embedding n8n as a paid service without an Enterprise license.
- **Copyleft**: Components licensed under **GPL/LGPL** (like FFmpeg, git, termux-services) are used as external tools in the environment. This toolkit's logic (shell scripts) is "merely aggregated" with these tools and is not a derivative work that would trigger copyleft requirements under standard usage.

# Droid AI Toolkit — Agent Instructions

## Project Type

Bash scripting toolkit **and a native Android app**, and the app is now shipped: the APK is
released as a GitHub release asset (**`droid-ai-0.1.0.apk`**, debug-signed, beta). `install.sh`
is the executor and single source of truth for logic; `apk/` is a Kotlin/Compose client that
drives it over `install.sh --api` (see `docs/CONTRACT.md`). `package.json` remains lint-only
infrastructure.

## Toolchain & Commands

```bash
pnpm install               # Install linter deps (pnpm@10.32.1 enforced via packageManager field)
pnpm run lint:all          # Full gate: ESLint → Stylelint → Markdownlint → compat → action specs → shellcheck (read-only)
pnpm run lint:actions      # Validate actions/*.json: schema, ids, step primitives
(cd apk && ./gradlew :app:assembleDebug)          # Build the APK (JDK 17 + Android SDK 34)
(cd apk && ./gradlew :app:testDebugUnitTest)     # 76 JVM tests (pure logic: parsers, policies)
bash tests/run.sh                                # Engine tests: 7 scripts, 89 assertions
ANDROID_SERIAL=<serial> bash scripts/apk-smoke.sh  # 8 device checks against a real phone
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

- `install.sh`: Single source of truth for toolkit logic and version. Also the `--api`
  entry point: a headless spec runner used by the app (no TUI, no TTY).
- `actions/`: declarative action specs (JSON). This is the catalog the app renders, so a
  new tool needs no APK release. `pnpm run lint:actions` validates them.
- `lib/`: the runner plus step primitives (`lib/steps/*.sh`). Sourced only by `--api`;
  the TUI still uses the legacy functions in `install.sh` until the phase-7 cutover.
- `docs/CONTRACT.md`: the app ⇄ engine contract (events, exit codes, safety semantics).
- `apk/`: Kotlin/Compose client. Termux stays the executor; the app never runs Linux
  commands itself.
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

## OpenClaw Command Authorization (`dmPolicy`) — v1.17.1+

OpenClaw 2026.9.x **defaults `channels.telegram.dmPolicy` to `"pairing"`** (`resolveTelegramEffectiveDmPolicy` returns `params.dmPolicy ?? "pairing"`). With the pairing policy, `allowFrom` alone no longer satisfies command authorization (`commandAuthorized` requires the pairing store), so **slash commands** (`/status`, `/help`, `/commands`, `/goal`) fail with "No reply was generated for this message..." or "You are not authorized to use this command." while regular messages keep working. The failing commands are local `defineAuthorizedTextCommand` handlers (no model involved); with `silentUnauthorized: true` the denial is silent and dispatched as empty payloads (`NO_VISIBLE_REPLY_FALLBACK_TEXT`).

`install_openclaw`'s config jq block now pins `.channels.telegram.dmPolicy = (.channels.telegram.dmPolicy // "allowlist")` (user-set values win). `commands.ownerAllowFrom` must contain the user's **numeric** channel sender IDs — channel-prefixed entries for other channels (e.g. `zulip:user@host`) do not authorize Telegram commands and are logged as "Invalid allowFrom entry" by `[telegram/bot-access]`.

Testing gotcha: `openclaw gateway call chat.send` authenticates as the webchat sender (a `sha256:...` identity) which is intentionally not in `allowFrom` — slash-command tests via gateway-call always show the empty-reply fallback even with correct config. Verify from the real channel.

## OpenClaw 2026.9.2/9.3 Notes — RegisterHooks, Bootstrap, Gateway Mode, .mjs Chunks (v1.17.2+)

Three additional fixes from device 8x (aarch64, fresh install of 2026.9.2):

1. **`patch_openclaw_registerhooks` rewritten**: the original sed BRE (`.registerHooks\??.(`) was a silent no-op — GNU `\\?` makes the preceding "s" optional, so the literal `?` in `.registerHooks?.(` is unmatched. It now uses a python exact-string replacement (`.registerHooks?.(` → `.registerHooksX?.(`) with real idempotency (`registerHooksX?.(` grep) and a non-fatal warn on upstream mismatch. Do **not** convert it back to sed.
2. **`patch_openclaw_workspace_bootstrap` (new)**: onboarding's workspace bootstrap publishes files via `fs.linkSync(staging.path, targetPath)` and upstream **deliberately refuses** to fall back on filesystems without hardlinks (`isHardlinkFallbackError` → "Workspace filesystem does not support atomic bootstrap publication"). Patch converts that branch to copy+unlink (`fs.copyFileSync` + `fs.unlinkSync`). Verified: pattern matches 2026.9.2's `workspace-*.js` chunk, replacement is valid JS (`node --check`).
3. **`gateway.mode` pin**: a failed doctor run can leave a fresh config without `gateway.mode`, blocking gateway start ("existing config is missing gateway.mode"). The config jq block pins `.gateway.mode = (.gateway.mode // "local")`.

2026.9.2 upstream changes that affect the patch suite: the `/tmp` hardcoding is **fixed upstream** (native `TMPDIR` usage — the openclaw_tmp patch is a no-op on 9.2); the process-identity `android` fix **stayed applied** (re-verified); the sqlite-archive hardlink pattern **no longer matches** 9.2's chunk (non-fatal warn; only matters for devices migrating legacy state on 9.2 — re-verify pattern before relying on it).

2026.9.3 findings (device y6, updated Sep 10 — same failure class, new targets):

1. **`pid-alive` chunk renamed to `.mjs`**: 2026.9.3 ships `pid-alive-CdYsDTZZ.mjs` (not `.js`) — the pid_platform glob `pid-alive-*.js` missed it, so the CLI/cron path used an unpatched `getProcessStartTime` → the cron fence error ("cron run cannot acquire a durable fence without process start identity") returned even with the worker.mjs patch applied. The glob now matches both extensions.
2. **`managed-handoff-runtime.mjs` (new)**: 2026.9.3 carries its own `getProcessStartTime` copy for the handoff/CLI path — same linux-only guard, same patch applied.
3. **PM2 env resets on every update**: the Sep 10 update reset the PM2 process env to the default formula (`--max-old-space-size=1345` on a 1.8GB device) — the low-RAM heap cap + `--max-memory-restart 600M` applied earlier were wiped, and the Android LMK resumed silently killing the gateway ~50-100s after ready (crash loop, breaker trips, PM2 erasing the entry). After any OpenClaw update, **re-check the PM2 env** (`pm2 env <id> | grep NODE_OPTIONS`) and re-apply the device-appropriate heap cap. (User opted to manage this manually per-device — no install.sh formula change.)

## PM2 Autostart on Boot (v1.17.4+)

**Every PM2-managed service used to stay dead after a reboot.** Termux has no systemd/launchd, so `pm2 startup` cannot generate a working unit — and the toolkit never called it, or `pm2 resurrect`, either. `pm2 save` persists `~/.pm2/dump.pm2`, but nothing restored it, so the OpenClaw gateway (and n8n/Ollama/etc.) silently stayed down until started by hand.

Verified on device y6 after a reboot: no `.pm2`/node processes at all, while `com.termux` and `com.termux.boot` were both running — Termux:Boot *was* firing, there was simply no script for it to run. (`~/.termux/boot/` was created in the n8n section but never populated.)

`setup_pm2_boot()` in `install.sh` now writes `~/.termux/boot/start-pm2.sh`:

```sh
#!/data/data/com.termux/files/usr/bin/sh   # shebang derived from $TERMUX_BIN, never hardcoded
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
export PATH="$TERMUX_BIN:$PATH"
cd "$HOME" 2>/dev/null || true
pm2 resurrect
```

It runs on entry to **SERVICES → PM2** — so the hook exists before any service is started — and via the new **[B] Autostart on Boot** menu item, which prints the file and its requirements. It is idempotent: it rewrites only when the generated template differs, so a tampered file self-heals. Because the toolkit **owns** that file, user customisations belong in a sibling `start-user.sh` — Termux:Boot executes every script in the folder, and `start-pm2.sh` sorts before `start-user.sh`, so PM2 resumes first.

Note what this does and does not do: the script does **not** start Termux (the Termux:Boot app does) and does **not** start OpenClaw by name. It runs `pm2 resurrect`, which restores whatever `~/.pm2/dump.pm2` records — so OpenClaw only returns if `pm2 save` was run while it was registered.

Three conditions must hold for it to fire, and `_pm2_boot_warnings()` detects the first instead of failing silently:

1. The **Termux:Boot** app is installed, opened once, and allowed to start on boot. Without it, nothing in `~/.termux/boot/` is ever executed.
2. **Termux and Termux:Boot are exempt from battery optimisation.** Verified on y6 that `com.termux.boot` was absent from the doze whitelist (`dumpsys deviceidle whitelist`) while `com.termux` was present — `dumpsys deviceidle whitelist +com.termux.boot` fixes it, and the toolkit cannot do this itself because `dumpsys` is not callable from an app UID.
3. `pm2 save` has run while the apps were actually up — that dump is what `resurrect` restores.

On EMUI there is a further gate the toolkit cannot touch: Huawei's own **App launch** (startup manager, under Battery) must allow Termux:Boot to autostart.

Do not replace this with `pm2 startup`; it cannot work on Android. Before v1.17.4, telling a user to "restart the device" silently stopped every tool.

## Boot Script Also Restores SSH (v1.17.5+)

The generated `~/.termux/boot/start-pm2.sh` now brings `sshd` back as well as PM2, guarded so it is a no-op when SSH is not installed:

```sh
command -v sshd >/dev/null 2>&1 && sshd >/dev/null 2>&1
```

Why: on y6 (2026-09-28) the phone answered ping on the LAN while **every** TCP port refused — `sshd` was down, and so were the gateway and the PM2 daemon. A pingable-but-unreachable device is indistinguishable from an offline one, and recovery needed physical access to open Termux by hand. SSH is therefore restored before `pm2 resurrect`.

**The incident was not a reboot, and that is the point.** `uptime` read 11 days 22:58 — the phone never restarted. `sshd`, `crond`, `postgres` and the PM2 daemon had all died at the same instant (~12:58 local) and stayed dead for ~9 hours while the device kept running. That is the signature of Android killing the **Termux app itself** (low-RAM LMK / OEM battery management), not of a reboot.

Consequence: **a boot script cannot fix an in-place kill**, because Termux:Boot never fires. The only remedies for that failure mode are the battery-optimisation exemptions `_pm2_boot_warnings()` already reports (Termux + Termux:Boot) plus holding `termux-wake-lock`. Do not tell a user to "reboot to bring a service back" without first checking `uptime` — if the phone never rebooted, no amount of rebooting advice applies.

Related: the toolkit does not own SSH on a device that already manages it. y6 ran a hand-written `~/.termux/boot/start-pm2` (containing `sv up sshd`) alongside the toolkit's `start-pm2.sh`, because Termux:Boot executes *every* executable file in that folder. The generated script only starts `sshd` when it exists, so it never conflicts with a device without SSH.

## OpenClaw Update Safety (v1.17.5+)

A toolkit-driven OpenClaw update on device y6 (2026-09-28) left the phone with **no working `openclaw`** and a gateway that could not boot. Three independent faults, all in `install.sh`, were found and fixed.

**1. A killed install left nothing behind.** `install_openclaw` deletes the installed package before downloading it again. On a 1.8 GiB device Android's low-memory killer SIGKILLed pnpm mid-download:

```text
install.sh: line 552: 16005 Killed   pnpm add -g openclaw@latest --force --ignore-scripts
```

An LMK kill is not reported as an out-of-memory error — it is an ordinary non-zero exit — so it silently left `$(pnpm root -g)/openclaw` deleted and `openclaw.mjs` missing. The CLI and the gateway both died. The block now snapshots the install first (the pnpm symlink target; a moved-aside directory for npm), verifies the result with `openclaw --version`, and restores the previous version on any failure. **Do not use `command -v openclaw` as the test:** the `$PREFIX/bin/openclaw` shim survives even when the package behind it is gone, which is exactly how this failure looked like success.

**2. The config block wrote keys that 2026.9.x rejects.** The jq block set `.channelToken`, `.ui.showSystemPrompt` and `.disableAudio`. All three are dead in 2026.9.3 — `showSystemPrompt` appears in zero files, `disableAudio` exists only as the unrelated `disableAudioPreflight`, and `channelToken` is not a schema key. Their presence fails validation and blocks startup entirely:

```text
Gateway failed to start: Invalid config at ~/.openclaw/openclaw.json:
openclaw.json:1319 — ui: Unrecognized key: "showSystemPrompt"
<root>: Unrecognized keys: "channelToken", "disableAudio"
```

`.channelToken` was also writing a placeholder (`"YOUR_BOT_TOKEN"`) to a key upstream no longer reads — the live token is `channels.telegram.botToken`. Those lines are removed; **do not reintroduce them.**

**3. The plugin block disabled every plugin.** `.plugins.entries = (... | with_entries(.value |= . + {"enabled": false}))` reset *every* entry, then re-enabled only telegram/ollama/memory-core. On y6 that silently disabled `openclaw-honcho`, `zulip` and `brave`: the gateway came up with `2 plugins` instead of `5`, and the Zulip bot went silent. It now defaults only entries that have no explicit `enabled`, and never overwrites a state the user chose.

Two jq details cost real debugging time and should not be undone:

- **`//` treats `false` as empty.** `.enabled // true` silently re-enables a deliberately disabled plugin, so the `memory-core` default branches on existence (`if (.plugins.entries["memory-core"] | type) == "object"`).
- **No apostrophes inside the `jq '...'` block.** The program is single-quoted for the shell, so a comment containing `user's` terminates the string and breaks the whole script (`syntax error near unexpected token '=='`). `bash -n install.sh` catches it; run it after touching that block.

`memory-core` is now only a default — a device that disabled it because it runs `openclaw-honcho` as the memory slot keeps that choice.

Also worth knowing after any crash loop: a repeatedly-crashing gateway trips the **restart-loop breaker**, which suppresses channel autostart and keeps suppressing it after the underlying fault is fixed. Start the channel by hand:

```bash
openclaw gateway call channels.start --params '{"channel":"zulip"}'
openclaw gateway call channels.start --params '{"channel":"telegram"}'
```

(`health-monitor` logs `channel autostart suppressed; treating as expected stopped` while this is in effect.)

## Hermes venv survives `pkg upgrade` (v1.17.6+)

Device 8x (2026-10-29) ran `pkg upgrade` and then a toolkit Hermes update. The update failed with `ModuleNotFoundError: No module named 'pip'` (and `'yaml'` for every gateway start), and the gateway restart-looped — pm2 showed hundreds of restarts.

**Nothing was corrupt. The venv's interpreter had moved underneath it.** The chain:

1. Termux's `python` package owns an **unversioned** `/usr/bin/python` symlink. `apt full-upgrade` on 2026-10-29 22:54 replaced the `python` package (3.14.6 → 3.14.8) and rewrote that symlink to `python3.14` (dpkg `python.list` mtime matches).
2. Upstream creates the venv with bare `python -m venv`, so the venv records `venv/bin/python -> /usr/bin/python` — the unversioned name.
3. After the flip the venv's interpreter became 3.14 while its 233 packages stayed in `venv/lib/python3.11`. Every import then failed.

Evidence that this is the whole story: re-entering the same venv through a `python3.11` symlink made `import pip, yaml` and `hermes --version` work with **zero** package changes (`Hermes Agent v0.20.0`, `Python: 3.11.17`). So the fix is one symlink, not a reinstall.

**The fix is to pin the venv's interpreter to the versioned binary**, which `pkg upgrade` never rewrites:

- `_hermes_venv_want_minor()` reads the target `X.Y` from the venv's own `pyvenv.cfg` (so 3.12/3.13 venvs work too).
- `_hermes_pin_venv_interpreter()` sets `venv/bin/pythonX.Y -> $PREFIX/bin/pythonX.Y` (absolute) and `venv/bin/python` / `python3 -> pythonX.Y`, then verifies by running the interpreter. If `pip` is genuinely absent it bootstraps with `ensurepip`.
- `_hermes_venv_resolves()` (does it work *now*) and `_hermes_venv_is_pinned()` (can `pkg upgrade` break it) are deliberately separate. A venv that works today through the unversioned chain **passes the first and fails the second** — that is the exact 8x state, and using only the first would have skipped the hardening.

Call sites: the top of `_hermes_ensure_termux_deps()` (the single funnel for every pip call, so it covers install/fix/update), the top of the UPDATE branch, and `[F] Fix` — which now repairs in place and only falls through to the upstream installer if the cheap repair is insufficient. `_detect_hermes_state()` uses the resolve test so a drifted venv is reported as `partial`, offering the user `[F] Fix` instead of an `[U] Update` that cannot succeed.

Verified on-device against a scratch venv in three states (fragile/unpinned, already-broken, healthy): fragile and broken are repaired to the same pinned layout, healthy is a silent no-op, and a second run is silent. Durability was verified by pinning a venv, flipping `/usr/bin/python` to 3.14, and confirming the venv still ran 3.11.17.

Related fix in the same path — **the git index no longer poisons updates.** The old update flow stashed its own patch, pulled, then `git stash pop`ed. A pop that conflicts (upstream edits the same lines) leaves stage-1/2/3 entries in the index, and from then on **both** `git stash push` and `git pull` refuse to run (`Pulling is not possible because you have unmerged files`); 8x had been frozen at the 2026-08-04 commit for ~3 months because of this, and the `2>/dev/null` + `|| true` around the stash call hid it. Now:

- `_hermes_clear_unmerged_index()` resolves any unfinished merge with `git checkout HEAD -- <path>` (which clears index and worktree in one step) and drops **only** stashes tagged `termux-fix-pre-update` — never a stash the user created.
- The update path no longer stashes at all: it discards its own patch with `git checkout HEAD -- hermes_cli/main.py` and re-applies it afterwards, since `_hermes_apply_termux_fix` regenerates it from scratch. This removes the conflict source entirely.
- `git pull` failure is reported (`warn_msg` with the exit code) instead of being followed by an unconditional `success_msg`.

Do not "fix" the venv by re-pointing the system `/usr/bin/python` to 3.11. That is what `_hermes_ensure_compatible_python` does for the upstream installer, and the next `pkg upgrade` reverts it; it also changes the default interpreter for every other tool (3.14 packages such as `python-numpy` are installed alongside). Pin the venv instead.

## Hermes 2026.9.24 on Termux — stash-pop brick, missing `os.link`, dependency ownership (v1.17.7+)

Device 8x (2026-11-05) ran a toolkit update and came back with **no working `hermes`**: every launch died at

```text
File "~/.hermes/hermes-agent/hermes_cli/main.py", line 334
    <<<<<<< Updated upstream
    ^^
SyntaxError: invalid syntax
```

and pm2 restart-looped (32 restarts, `errored`). Three separate faults, one per layer.

**1. The run used a stale copy of the toolkit.** `~/install.sh` (2026-10-07, pre-v1.17.6) was still on disk next to the current `~/droid-ai-toolkit/install.sh`. The old copy still did `git stash push -m termux-fix-pre-update` → `git pull` → `git stash pop`, and upstream had rewritten the same region, so the pop left conflict markers in the worktree and stage 1/2/3 entries in the index. v1.17.6 removed that stash/pop entirely, so the fix for this class was already shipped — the device simply ran the wrong file. **When a Hermes update goes wrong, first check which script ran** (`ls -la ~/install*.sh`); 8x had the old copy at `~/install.sh`, now parked as `~/install.sh.stale-2026-10-07.bak`. **Do not re-add a stash around the pull.**

**2. `os.link` does not exist in this Termux Python build.** 8x runs CPython 3.11.17 built 2026-10-14 where `hasattr(os, "link")` is **False** (`os.symlink` is present). Upstream assumes the POSIX contract — `os.link` raises `OSError` where hardlinks are unsupported — and Android's bionic `link()` does fail with `EACCES` under `/data/data`, which is the exact fallback path upstream already implements. Without the attribute, upstream gets an `AttributeError` it never catches:

```text
hermes: source-update completion failed: module 'os' has no attribute 'link'; running with the previous dependencies
```

raised from `hermes_cli/update_lock.py::_publish_exclusive` (`os.link(tmp, path)`; its `except OSError` fallback never runs). Every other `os.link` call site in the tree has the same shape (`cron/cancellation.py`, `web_routers/local_models.py`, `update_cmd_zip.py`, `hosted_room_peer.py`).

**The fix is a venv-level `sitecustomize.py`**, not a patch to those files: it defines `os.link` through `libc` with `ctypes` when the attribute is missing, so callers get a real `OSError(EACCES)` and their own fallbacks run. Writing it into `venv/lib/pythonX.Y/site-packages/` (rather than the checkout) means `git pull` cannot clobber it, the tree stays clean for the updater's dirty-tree check, and it applies to every interpreter in that venv, including pip subprocesses and pm workers.

**3. Upstream wants to finish the checkout with its own PM store, which this install must not use.** 2026.9.24 completes a git checkout by syncing dependencies through PM: a pinned `uv` (on bionic, a `.deb` from `packages.termux.dev`), a pinned **CPython 3.14**, and `uv.lock` resolution. On a 3.6 GB device that is the same class of path that OOMs (`uv` compiling Rust, glibc wheels), and it would replace the pip-managed 3.11 venv the toolkit pins and fills from the wheel cache. `pm.venv_is_current()` therefore reports **False** forever on a toolkit-managed install — it is not a fault, it is the split of ownership.

The shim sets `HERMES_DISABLE_LAZY_INSTALLS=1` (upstream's documented escape hatch; `venv_sync.prepare_launch` returns immediately) via `os.environ.setdefault`, so an operator can still export `=0` to opt back in. `install.sh` owns Hermes deps on Termux: `git pull` + pip into the venv + wheel cache, never `hermes update` and never the PM tail.

Supporting `install.sh` changes in the same release:

- **`_hermes_checkout_broken`** treats lines starting with `<<<<<<<` or `>>>>>>>` in `hermes_cli/main.py` as a broken install, so `_detect_hermes_state` reports `partial` and offers **[F] Fix** instead of pretending the launcher proves health.
- **[F] Fix** now clears an unmerged index, resets `hermes_cli/main.py` to HEAD, re-applies the Termux fix, re-pins the venv, reinstalls the platform shims, and only claims success after `hermes --version` exits 0.
- **The update path verifies with `hermes --version`**, never with `command -v hermes` (the `$PREFIX/bin` shim survives a deleted package and a conflict-marked checkout — that is exactly how this update reported success on a broken install). Post-pull conflict markers are reset automatically.
- **`snowballstemmer` is installed** with the deps: `pyproject.toml` declares it only for `python_version >= '3.14'` while `tools/tool_search_catalog.py` imports it unconditionally, so a 3.11 venv loses tool search with `Tool search assembly skipped: No module named 'snowballstemmer'`.

### Memory providers left core in 2026.9.24 — install them without PM

2026.9.24 moved `honcho` (plus `hindsight`, `mem0`, `supermemory`, `openviking`, `retaindb`, `byterover`, `holographic`) out of the bundled `plugins/memory/<name>` tree into catalog plugins. The in-tree directory survives as an **empty stub**, so `plugins.memory.find_provider_dir()` returns `None` and every agent init logs:

```text
⚠ Memory provider 'honcho' is not installed, so external memory is off for this session.
  security.allow_lazy_installs is off, so Hermes did not fetch it: run `hermes plugins install honcho`.
```

That is silent memory loss on a home whose `config.yaml` sets `memory.provider: honcho` (8x did). **The printed remedy cannot work on Termux** — `hermes plugins install` builds an isolated runtime and runs `uv lock`, which fails outright:

```text
error: No solution found when resolving dependencies for split
       (markers: python_full_version == '3.14.*' and sys_platform == 'android')
cause: sherpa-onnx-core==1.13.8 has no ... android-compatible wheels
       and hermes-agent[wake] depends on sherpa-onnx-core==1.13.8
```

The plugin's own requirements are only `honcho-ai>=2.2.0,<3` and `httpx` — both already in the venv — so `_hermes_ensure_honcho_memory_plugin` installs it the way `find_provider_dir()` reads it: clone `plastic-labs/honcho` (sparse, subdirectory `hermes-plugin-honcho`) into `~/.hermes/plugins/honcho`. It runs at the end of `_hermes_ensure_termux_deps`, is a no-op unless the home's `memory:` block says `provider: honcho`, and a no-op again once the directory exists. Verified on 8x: `hermes memory status` reports `Provider: honcho / Plugin: installed ✓ / Status: available ✓` and the gateway starts without the warning.

### A half-built PM store hijacks `python` on PATH (v1.17.7+)

Any PM operation that fails partway — `hermes pm install`, or `hermes plugins install <name>`, which 2026.9.24 itself tells the user to run — leaves `~/.hermes/tools/` populated with a downloaded **python 3.14** and **uv**, plus a `facts.json` naming only those two packages. On Termux PM can never finish the job (`uv`: *"No solution found when resolving dependencies for split (markers: python_full_version == '3.14.*' and sys_platform == 'android') … sherpa-onnx-core has no android-compatible wheels"*), so that store is abandoned. Two consequences, and only the first is cosmetic:

1. `pm.install.drift()` compares the lockfile against those facts, so **every** `hermes` command prints `⚠ install out of sync (ffmpeg: not installed or outdated; node: …; npm: …; ripgrep: …) — run hermes pm install` (and the gateway logs it at startup).
2. `pm.install._store_path_dirs()` then resolves the store's `python-3.14.x …/usr/bin` as an installed tool and `pm.install.activate()` **prepends it to `os.environ["PATH"]`** for every `hermes` process. Cron jobs and tool subprocesses that shell out to `python`/`python3` get **3.14** while the venv and the Termux `python` this toolkit pins are 3.11 — the exact ABI mismatch that makes Hermes crash-loop. Verified on 8x: `shutil.which("python3")` returned `~/.hermes/tools/python-3.14.9+…/usr/bin/python3` inside an activated process.

`_hermes_clean_abandoned_pm_store` discards `~/.hermes/tools` when its `facts.json` names no `venv` package (a completed PM install records one, and is left alone). It runs from `_hermes_ensure_termux_deps` and from **[F] Fix**, and it is idempotent. After it ran on 8x, `pm.install.check()` → `[]`, `_store_path_dirs()` → `[]`, and `hermes memory status` printed no warning; 73 MB of dead store reclaimed. **Do not run `hermes pm install`** — clean up instead.

Verified on 8x after the repair: `hermes --version` → `vgit.a53912d (2026.9.24)`, `hermes status` shows the gateway running with Telegram + Zulip, gateway reached `Connected to Telegram (polling mode)` with no tracebacks, `pip check` clean, tree clean, stash list empty, `pm2 save` written. The shim writer is idempotent (identical payload → no rewrite) and refuses to overwrite a `sitecustomize.py` it does not own.

### `hermes --version` does not prove staleness (v1.17.8+)

A successful update on 8x (2026-11-17) looked like a failed one: `hermes --version` still printed `Hermes Agent vgit.707cf0f (2026.9.24) · stable · local 707cf0fde025` … `Up to date`, the same release string as before. Nothing was wrong — the pull was a real fast-forward (`a53912d` 2026-11-05 → `707cf0f` 2026-11-17, per `git reflog`). Four independent reasons the banner cannot show it:

1. **`(2026.9.24)` is a constant.** `hermes_cli/__init__.py` sets `__release_date__ = "2026.9.24"`, last touched 2026-09-24. Upstream stopped bumping it; it is not a code date.
2. **`vgit.<sha>` means "no tags", not "unknown version".** `version_info._git_version_info()` derives a base version from `git tag --merged HEAD --list 'v[0-9]*'` (semver) and falls back to CalVer `v2026.*` via `git describe`. The upstream curl installer leaves a **depth-1 clone with zero tags** (`git rev-parse --is-shallow-repository` → `true`, `git tag | wc -l` → `0`), so both lookups miss and the display degrades to `git.<short7>`.
3. **`· stable · local <sha>` is normal for a channel install.** `format_banner_version_label()` only prints `· upstream <sha>` on the `main` channel; an official clone resolves to `stable` (`update_channel.resolve_update_channel`), which appends the local HEAD instead.
4. **`Up to date` compares against the stable release, not `main`.** Our update path pulls `main`, so the checkout is *ahead* of the newest stable tag (`v0.23.2`, 479 commits at the time) — `check_for_updates(passive=True)` reports `behind == 0`.

So the only trustworthy post-update evidence is the checkout's own identity. **The update path now prints it** right after the pull (`HEAD a53912d -> 707cf0f 2026-11-17`, or `HEAD 707cf0f 2026-11-17 (already current)`), which is exactly the line that distinguishes "pulled fine" from "silently did nothing". Do not add a `--tags`/`--unshallow` fetch to make the banner prettier: `.git` is already 867 MB on that device, and the repo is hundreds of commits past the last tag.

Health check that does not depend on the version string: `git reflog --date=iso -3` (did HEAD move?), `git rev-parse --short origin/main` vs `HEAD`, `git status --porcelain` (clean), `pm2 list` (online, restart count 0), `~/.hermes/hermes-agent/venv/lib/python3.11/site-packages/sitecustomize.py` (the `os.link` shim survived), `venv/bin/python -> python3.11 -> $PREFIX/bin/python3.11` (still pinned), `~/.hermes/tools` empty (no abandoned PM store).

## OpenClaw 2026.11.x Cannot Migrate on Termux — and Two Silent Startup Faults (v1.17.8+)

Device 8x (2026-11-17) went 2026.9.8 → 2026.11.5 via **[L]**. The toolkit printed success and the gateway never ran. Three independent faults, only one of them upstream-shaped.

**1. PM2 was handed a directory.** `_pm2_resolve_bin` mapped a pnpm shim to `pnpm root -g` — i.e. `<pnpm>/global/5/node_modules`:

```text
[PM2] Starting .../.local/share/pnpm/global/5/node_modules in fork_mode
status: online   pid: N/A   mem: 0b   restarts: 0   out/err logs: 0 bytes each
```

PM2 cannot exec a directory but still reports `online`, so nothing surfaced. For pnpm installs the shim (`~/.local/share/pnpm/openclaw`) *is* the executable — it exports `NODE_PATH` for the isolated store and execs the package entry — so `_pm2_resolve_bin` now returns it verbatim.

**2. A Gateway lock from 2026-05-05 blocked boot *and* the migration.** 2026.9.8+ keeps locks in `$PREFIX/tmp/openclaw-<uid>/`, not `~/.openclaw/tmp` (where the update preamble looked):

```text
Legacy Gateway lock .../gateway.b4424d84.lock still has a live or unverified owner (PID 14479)
```

The PID had been dead for six months and upstream still refuses it. `_openclaw_clear_stale_gateway_locks` now removes locks whose owner is gone, from both locations, called by `install_openclaw` and by SERVICES → PM2. The SQLite `gateway-owner` lease is a *different* lock: `openclaw gateway recover-lock` (inspect, then `--confirm <fingerprint>`) is what releases it.

**3. 2026.11.x cannot migrate its own state on Android.** Once booted, the gateway refuses the agent DB:

```text
openclaw-agent.sqlite uses schema version 24; ... upgrade it to schema version 38
```

`doctor --fix` is the only migration path and cannot finish on Termux: the staging-ancestor guard rejects `/data/data` (`0771 root:root`, group-writable), and patching that only exposed the next wall — the pre-repair capture calls `publishFileExclusive(..., strategy: "rename-noreplace")`, which calls `requireNativeBinding("renameNoReplace")`, and that addon is `@openclaw/fs-safe-<target>` chosen from a **baked platform list** (`bundledTarget()`), so `android-arm64` is "Unsupported OS or architecture" and no npm package can supply it. `--force` and `OPENCLAW_FS_SAFE_NATIVE_MODE=off` both still fail with `helper-unavailable`.

Net effect: the state DB migrates (19 → 36) but the agent DB stays at 24, so sessions are unavailable and `memory-core` logs `AgentDatabaseAdmissionError` every ~30 s while RSS climbs past 950 MB.

**The recovery that worked (8x).** The device had been running 2026.9.8, whose data is state 19 / agent 24, and a genuine pre-update backup existed:

1. `pm2 stop openclaw`, then restore `~/.openclaw/state` from the **pre-11.5** backup. Check `PRAGMA user_version` of the backup, not its timestamp — doctor migrates *before* it fails, so a later "pre-doctor" copy is already v36.
2. Pin `dependencies.openclaw` to the exact version (`2026.9.8`, no caret: `^2026.9.8` resolves to the newest 2026.x) and run the two-phase pnpm install (`--lockfile-only`, then `--frozen-lockfile --ignore-scripts --child-concurrency=1`).
3. Re-apply the patch suite — a replaced tree is unpatched. Call `apply_patches "" openclaw` from a sourced lib and set `$OPENCLAW_ROOT` **after** sourcing: the lib resets it to the npm path, and every `patch_openclaw_*` silently no-ops without it.
4. Start PM2 with the shim, the heap cap and `--require $HOME/.openclaw/btime-shim.cjs`.

Verified on 8x: `http server listening (15 plugins …)`, `[telegram] starting provider (@…_bot)`, `isolated polling ingress started`, 0 restarts, Hermes gateway online, `pm2 save` written.

Two operational lessons from the same incident:

- **`prepare_for_install` runs `pm2 kill`**, so *every* PM2 service stops — Hermes included — and only the tool being installed is restarted. After any OpenClaw update, restart Hermes explicitly and re-run `pm2 save`, or the boot dump will not contain it.
- **`openclaw --version` is the install check** (`health_check` now uses it). `command -v openclaw` passes with the package deleted, because the pnpm shim survives.

Related (y6, same day): a config stamped by a *newer* build refuses to start on an older one — `meta.lastTouchedVersion: 2026.9.8` while running 2026.9.3, message "config was last written by a newer OpenClaw". Correct the stamp to the installed version or install the version the data belongs to; never "upgrade" to satisfy a downgrade.

### The birthtime identity guard lives in ~14 bundles (v1.17.9+)

Android reports `ctime` as `birthtime`, so *any* write to a file changes it. OpenClaw's shared-state identity guard compares `birthtimeNs` and is duplicated across many bundles, and `patch_openclaw_sqlite_identity`'s birthtime pass is deliberately slow (~181 MB of bundled JS, minutes on a phone). A pass killed by a timeout leaves some copies unpatched — and then **every CLI write** fails while the gateway itself is healthy:

```text
[openclaw] The CLI command failed.
[openclaw] Reason: Existing shared-state database generation changed: .../state/openclaw.sqlite
```

Measured on 8x (2026-11-18): two interrupted passes left 13 of 14 files unpatched. `openclaw config` (provider selection) and `openclaw models refresh` both died; `openclaw config get` (read-only) worked, the gateway booted and served Telegram normally, and the failure looked like database corruption rather than a half-applied patch. The pass now reports leftover comparisons and points at **[R] Repair**.

Verify after any patch run — empty output means fully neutralised:

```bash
grep -rl --include='*.js' --include='*.mjs' \
  -E '[A-Za-z0-9_$?.]+\.birthtimeNs *[!=]== *[A-Za-z0-9_$?.]+\.birthtimeNs' \
  ~/.local/share/pnpm/global/5/node_modules/openclaw/dist | grep -v '\.bak'
```

Do not shorten that step's timeout; re-run [R] Repair instead. Re-apply the birthtime pass to the remaining files with the same transformation if you need it in a hurry (`.birthtimeNs !==` → `false`, `.birthtimeNs ===` → `true`), writing `*.bak-android-bt` first.

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

## pnpm's global virtual store has TWO layouts — mixing them breaks every install (v1.17.10+)

Device 8x (2026-11-18) could not install n8n at all:

```text
ERR_PNPM_UNEXPECTED_VIRTUAL_STORE  Unexpected virtual store location
The dependencies at ~/.local/share/pnpm/global/5/node_modules are currently symlinked
from ~/.local/share/pnpm/global/5/node_modules/.pnpm, but pnpm now wants
~/.local/share/pnpm/global/5/.pnpm
```

Two pnpm commands disagree about where the virtual store of the **same** global
project (`~/.local/share/pnpm/global/5`) belongs:

| command | virtual store | `.modules.yaml` |
| --- | --- | --- |
| `pnpm add -g <pkg>` | `<global>/5/.pnpm` | `virtualStoreDir: ../.pnpm` |
| `cd <global>/5 && pnpm install` | `<global>/5/node_modules/.pnpm` | `virtualStoreDir: .pnpm` |

Only one can exist at a time, and **neither command repairs the other's layout**. The
second form is what `pnpm_install_frozen` (v1.17.8, the low-RAM two-phase path for
OpenClaw) runs — so after an OpenClaw install that had to recreate `node_modules`,
every later `pnpm add -g` died: n8n, Gemini CLI and Pi, with a message that blames
the store location rather than saying "a previous install used a different command".
`pnpm remove -g` fails the same way, so uninstalls silently did nothing (`|| true`).

Two changes, both needed:

- **Prevention** — `pnpm_install_frozen` passes `--config.virtual-store-dir="$dir/.pnpm"`,
  so a local install writes the `-g` layout from the start. Verified: a fresh global
  dir + the flag produces `virtualStoreDir: ../.pnpm`, and `pnpm add -g` works after it.
- **Repair** — `pnpm_repair_global_store()` converts an already-nested tree: moves
  `node_modules/.pnpm/*` into `<global>/5/.pnpm` (overwriting same-named entries from
  the older store), rewrites the top-level symlinks, and fixes `virtualStoreDir` in
  `node_modules/.modules.yaml`. No package is re-downloaded and nothing is relinked
  from the content store, so it is cheap on a phone. It runs before every global pnpm
  command via the `pnpm_g` wrapper (all `add -g` / `remove -g` go through it) and at the
  top of `pnpm_install_frozen`; a healthy tree is a one-`grep` no-op.

Two details that are easy to get wrong:

- **Both symlink shapes need the extra `../`.** `node_modules/<pkg>` targets `.pnpm/...`
  while `node_modules/@scope/<pkg>` targets `../.pnpm/...`. Handling only the first
  leaves every scoped package dangling, which stays invisible until that package is
  imported (it looks like "the repair worked").
- **`.modules.yaml` must be rewritten with the store.** pnpm validates the on-disk
  layout against the recorded `virtualStoreDir`, so moving the directory alone still
  fails the next command.

On 8x both stores existed simultaneously (`.pnpm` from the Oct 7 `-g` era, `node_modules/.pnpm`
from Nov 17), which is why the repair merges instead of moving: entries are
content-addressed by pnpm (`pkg@ver_<peer-hash>`), so same-named means same content.

## The `[Y/n]` confirmation answered backwards (v1.17.10+)

On 8x, typing `y` at `>> Install n8n Server? [Y/n]:` returned to the previous menu as if
declining, while pressing Enter alone proceeded — the exact opposite of the prompt.
`confirm_action` read a **single character** (`read -n1`) after a 0.1s "flush" read
(`read -t 0.1 -n 10000 junk`) that silently swallowed type-ahead, and any byte that was
not literally `y`/`Y` — a stray `CR` from a soft keyboard, a repeated Enter — fell through
to "anything else is No".

It now reads a whole line (from `/dev/tty` when present, because the documented launch is
`curl … | bash` where stdin is the script), accepts empty/`y`/`Y`/`yes` as yes and
`n`/`N`/`no` as no, strips a trailing `CR`, and **re-asks** on anything else instead of
guessing. The `case` lists the spellings explicitly rather than using `${answer,,}`,
which is bash 4+ and breaks under bash 3.2 (used for local testing).

## n8n "installs" but cannot start: `--ignore-scripts` skips its database driver (v1.17.11+)

8x (2026-11-21) finally got past the pnpm store bug and installed n8n 2.48.7 cleanly — shim present,
`n8n --version` → `2.48.7`, `~/n8n_server/{config,scripts}` written. It still could not run:

```text
Initial database connection attempt 1 failed: SQLite package has not been found installed.
Try to install it: npm install sqlite3 --save. Retrying in 1000ms
```

…forever: no bind on 5678, nothing on the port, `pm2` empty. `require("sqlite3")` from n8n's own module
dir threw, and `sqlite3@5.1.7` in the store had **no `.node` file at all**.

**Cause.** Every global install here passes `--ignore-scripts` (an install hook can fetch binaries or
compile mid-install — slow, and a prime memory-killer target). That also skipped sqlite3's own step,
`prebuild-install -r napi || node-gyp rebuild`, so the package landed with no native binding.
`isolated-vm` (`install: node-gyp-build … || node-gyp rebuild --release -j max`) is skipped the same way;
n8n 2.x loads it lazily for expressions, so that one breaks workflows rather than startup.

**This is invisible to every cheap install check.** `command -v n8n` passes (pnpm shim survives),
`n8n --version` passes (the launcher short-circuits before it opens the database), and even a full
`pnpm add -g` exit 0. The install check now requires `require("sqlite3")` to load *as n8n resolves it*.

**Fix.** Keep `--ignore-scripts` (deliberate), then compile what n8n actually needs:

- `n8n_resolve_module <mod>` resolves from **inside** the n8n package (`readlink -f` the symlink first).
pnpm's isolated layout keeps a package's dependencies *beside* it in `.pnpm/<pkg>@<ver>_<hash>/node_modules`,
never in the package's own `node_modules` — resolving from the symlink's parent just misses them.
- `_n8n_build_native` tries `node-gyp rebuild -j 1` (node-gyp fetches matching headers once into
`~/.cache/node-gyp`), then retries with `--nodedir="$PREFIX"` (Termux's own header tree). One of the two
is what works on-device. `-j 1` deliberately: `isolated-vm`'s own script uses `-j max`, which is how you
get OOM-killed on a phone.
- sqlite3 failure is **fatal** (nothing starts without it); `isolated-vm` failure only warns, because n8n
boots without it and the user keeps a usable install.

Verified on 8x with the real pnpm layout (read-only probe of the shipped functions):
`n8n_install_root` → `…/global/5/node_modules/n8n`, `n8n_resolve_module sqlite3` →
`…/.pnpm/sqlite3@5.1.7/node_modules/sqlite3`, same for `isolated-vm@7.0.2`, and both `n8n_module_loads`
correctly returned false. The compile itself has **not** been run on-device — that needs a real install.

The toolchain is already a toolkit dependency (`python3`, `make`, `clang`, `pkg-config`), so no new
packages are required.

### LAN access: nginx TLS proxy (supersedes the `N8N_SECURE_COOKIE` workaround, v1.17.13+)

**In plain English:** n8n is no longer exposed on the LAN. It listens only on
`127.0.0.1:5678`; nginx is the single LAN entry point, at
`https://<phone-ip>:8443`. First-run owner setup is protected by a one-time
password that is removed automatically once the owner account exists.

Opening the advertised LAN address on 8x — `http://192.168.1.50:5678/` — returns:

```text
Your n8n server is configured to use a secure cookie, however you are either visiting this
via an insecure URL, or using Safari.
```

n8n defaults `N8N_SECURE_COOKIE=true`, so it only sets its session cookie over HTTPS and
refuses the login on any plain-HTTP origin. `localhost` happens to work because browsers
treat it as a secure context — **Safari does not, even for localhost**. Since the toolkit
writes `N8N_PROTOCOL=http`, every non-localhost route (LAN address, and the GCP bridge
before TLS) hits this wall.

`install_n8n` now writes `N8N_SECURE_COOKIE=false` into `~/n8n_server/config/n8n.env`,
with a comment saying to flip it back to `true` once n8n is fronted by TLS. That is the
n8n-documented answer for HTTP deployments, and it is the difference between the editor
rendering and the error above.

**And the env file was not being applied at all.** The PM2 start path passed `--env '<path>'`, but PM2's
`--env` selects a NAMED block from an ecosystem file — it is not a dotenv loader. Observed on 8x:
`/proc/<pid>/environ` had no `N8N_*` variables, while `pm2 jlist` showed stale ones, so
`N8N_SECURE_COOKIE`, `N8N_HOST`, `NODE_OPTIONS` and the runner token were all inert and the LAN login
still hit the secure-cookie wall. The native `sv` run script had always done it correctly
(`set -a && source …`); the PM2 path now does the same, sourcing the file into the shell before
`pm2 start` so the child inherits it and PM2 stores it in the dump. Because PM2 snapshots the
environment at process creation, editing `n8n.env` needs delete+start — `pm2 restart` is not enough.

Separately, the access information itself was undocumented: `install_n8n` finished with
"configure background services" and no URL, so a first-time user had no way to know n8n
serves a web editor on 5678. `_n8n_access_hint` now prints the LAN HTTPS URL (and the one-time setup
password when the owner is missing) at the end of an install and after
**SERVICES → PM2 → n8n** starts it. The hint deliberately **does not** launch a
browser — the toolkit tells the user where to go, it does not drive their device.

**v1.17.13 replaces the plain-HTTP workaround entirely.** n8n now listens on
`127.0.0.1:5678` only; nginx terminates TLS on `0.0.0.0:8443` and proxies to it.
`N8N_SECURE_COOKIE=true`, `N8N_PROTOCOL=https`, `N8N_HOST`, `N8N_EDITOR_BASE_URL`,
`N8N_WEBHOOK_URL`, and `N8N_PROXY_HOPS=1` are generated automatically. During
first-run owner setup, nginx requires a one-time Basic Auth password; the gate is
removed automatically once `/rest/settings` reports
`showSetupOnFirstLoad=false`. The old `N8N_SECURE_COOKIE=false` and
`N8N_NODES_INCLUDE=[executeCommand,manualTrigger]` lines are removed. PM2 env
handling still requires delete+start, not `pm2 restart`.

## Android app release — v0.1.0 beta (GitHub Releases)

The app ships as the release asset **`droid-ai-0.1.0.apk`**. Facts that matter when touching it:

- `applicationId` `dev.droidai.launcher`, `minSdk 28` (Android 9), `targetSdk 34`, `versionName`
  `0.1.0`, `versionCode 1`.
- **The release build is signed with the debug key** (`signingConfig = signingConfigs["debug"]` in
  `apk/app/build.gradle.kts`). A build signed with any other key cannot install over it — a user
  updating between keys must uninstall first. Do not describe the app as Play/F-Droid
  installable, and do not claim silent updates.
- The app is a **client**: it runs `install.sh --api …` inside Termux. It has no root, never
  installs Linux packages itself beyond provisioning `jq`/`git`/`curl`/`tar` and the toolkit
  checkout, and cannot flip `allow-external-apps` (the one manual step a user must do).

### UI map (v0.1.0) — the shape the owner settled on

- **One header on every screen**: `Droid AI`, the device line (`JSN-L22 · 22:44`) and Refresh. The
  page name lives in the content, not in the header.
- **One footer on every screen**: four equal segments — Home, Tools, Device, Settings — same
  icon-over-label shape, accent pill only on the destination you are on (Raw Output keeps
  Settings lit because it is reached from there).
- **No back arrows.** The footer is the visible way to move; the system Back still pops. A back
  arrow was tried and removed as redundant — do not reintroduce one.
- Screens: **Home** (verdict + *Running now* with memory/restarts + *Installed* + recommended
  tool when empty), **Tools** (catalog cards), **Device** (`About this phone`: facts, installed
  software, memory/swap chart), **Settings** (Startup & services → Termux & safety → Diagnostics
  → Appearance → Version), **Raw Output** (under Settings → Diagnostics).
- `Advanced` no longer exists. Its contents were re-homed: services → Home, Termux & safety +
  Diagnostics → Settings, device facts → Device.

### Live progress feed

The engine appends NDJSON to `~/storage/shared/droid-ai/progress.ndjson`
(`lib/progress.sh`: begin/step/end, one line per transition, truncated per run). The app reads the
last line and shows `Step 3 of 7 · Install Pi`. Needs the storage permission and a set-up
`~/storage/shared` (`termux-setup-storage`); when shared storage is absent the engine writes
nothing and the app simply shows no step — never an error.

### Smoke harness — four ways it lies if you are not careful

`scripts/apk-smoke.sh` (8 checks) is the only thing that exercises the real UI. Every one of these
has already produced a false PASS or a false FAIL:

1. **`uiautomator dump` leaves the previous file behind when it fails**, so a check keeps reading
   the last screen it managed to capture — a stale "Settings" survived a force-stop and a
   restart. `dump_ui` deletes the file first and retries six times.
2. **A run repaints once a second** (elapsed + progress), so the window never goes idle and the
   dump fails. `wait_idle` waits for the working banner to clear before tapping.
3. **The selected tab reports `clickable="false"`** (it is a `selectable`), so counting clickable
   nodes shifts every index by one — "tap Tools" landed on Device and the next assertion passed
   for the wrong reason because the device page contains the word "Installed". Count
   `selected="true"` too.
4. **A plugged-in cable raises the system "Use USB to" chooser**, which hides the app from
   uiautomator entirely. `dismiss_usb_chooser` clears it.

Also: a single quote inside the single-quoted `python3 -c` block in the harness ends the shell
string and python receives `clickable=true`; keep those blocks double-quoted-only.

## APK on a 32-bit device: --force, checkpoints, legacy detection

Testing the client end-to-end on y6 (Android 9 / API 28, `armeabi-v7a`,
`uname -m` = **armv8l**, 1.8 GB) found four defects that no earlier 8x pass could see,
because 8x is aarch64 with 3.6 GB and its tools were installed by the *older* engine.

**1. "Install anyway" did nothing.** The capacity dialog dispatched `--api run <id>` with
no flag, and the engine had no override, so the promised bypass ended at
`Command failed (exit 3)` (y6, 2026-11-24: Pi at 344 MB with `min_mem_mb: 384`).

`--force` now exists end-to-end and overrides **capacity only**:

- `runner_preflight <spec> [force]` keeps `requires.arch` and `requires.predicates` hard.
  No intent makes armv8l run an aarch64 build, or makes `pkg install` find a package the
  repo does not carry. A preflight that proceeds under `--force` emits `forced: true`.
- The app sends `--force` from that dialog. Documented in `docs/CONTRACT.md`.
- Verified on y6: Gemini Update (512 MB needed, 430 MB free) → dialog → `Install anyway`
  → `deps/install/patch/verify` all ok, `0.71.1`.

**2. Uninstall did not invalidate the install checkpoint.** `step_uninstall_tool` deleted
`tools/<tool>`, but `state/<tool>.install.json` still said `install: ok` with an unchanged
fingerprint, so the next Install was **skipped in 0 s** and the run died at verify
(`not on PATH: pi`) — twice, before the cause was obvious. Both `step_uninstall_tool` and
`step_hermes_uninstall` now delete `state/<tool>.*.json`. Verified on y6: after Remove,
Install runs `phase 1/2: resolve` … `Done in 23 s`, shim written, verify `1.6.0`.

**3. `ollama.install` claimed `armv8l` but Termux ships no 32-bit package.**
`pkg install -y ollama` → `E: Unable to locate package ollama`, surfaced only as
"Step failed: Install package" (the apt line lives in `~/.droid_ai_toolkit/log/`). The spec
is now `arch: [aarch64, x86_64]` **and** `predicates: [pkg_available:ollama]`; the new
`pred_pkg_available` reads `apt-cache policy` and is a hard preflight gate, so the refusal
happens before any work.

**4. The app ignored `requires.arch`.** It parsed `min_mem_mb`/`min_disk_mb` only, so
Hermes, Nanobot, Paperclip and Ollama offered Install on a CPU that cannot run them, and
the dialog blamed memory. `Protocol.Action.arch` now carries the list, and a row whose arch
excludes this device reads "No build for armv8l" with a disabled "Not on this CPU" pill
(the destructive pill stays usable). Verified on y6 for Hermes, Nanobot and Ollama.

**Detection now means runnable.** `tools.installed` was `tools/<tool>` only, so y6 showed
OpenClaw as "Disappeared — its files are gone" while 2026.9.3 served Telegram from the
legacy `global/5` shim (y6 still has `@earendil-works/pi-coding-agent`,
`@google/gemini-cli` and `openclaw` there; it has no `tools/` for any of them). It is now
`tools/<tool>` **or** (legacy package **and** its bin on PATH). Both halves are
load-bearing: the legacy directory alone still reports a tool after its shim was deleted
(y6, right after Remove), and the shim alone survives a deleted package. Scoped names are
checked too, because the old installer linked the scoped directory. Result: y6 2 of 8.
8x was already migrated on 2026-11-22 (`tools/` only, no `global/`), so it was never
affected by this one — do not cite it as a reproduction.

**5. `postgres_running` accepted a supervisor as a database (8x).** The predicate fell
back to `pgrep -f postgres` when `pg_isready` failed, and on 8x that matched
**`runsv postgres`** — the Termux service wrapper — so Paperclip's gate passed while 5432
answered nothing. With `--force` overriding the memory gate on top, the app started the
full ~2 GB install (the interrupted clone left 61 MB in `~/paperclip`, removed by hand).
`pg_isready` is now authoritative when present, and the fallback accepts only a
postmaster (`pgrep -x postgres` or `postgres -D`). Re-ran on 8x:
`preflight ok:false … unmet: postgres_running [--force does not override arch or
predicates]`, exit 3, no work done.

### What the client now does with that information

The engine grew three things in the same pass, because each failure above was survivable
but *unexplainable* from the phone:

**A post-run refresh.** A finished run used to leave every screen showing the state from
before the tap — removing Pi still listed Pi as installed, which reads as "nothing
happened". The app now sends its own `status` when a user run completes, under a distinct
`REFRESH` origin: not `SYSTEM` (only a full read may fill the screens, the supervisor polls
`--fast`) and not `USER` (it must not overwrite the raw stream, the step list or the
message about the run). A successful refresh must not clear a failure notice — that is a
separate, deliberate line, because the first version of this change erased the banner it
had just shown.

The rule is narrower than "the user asked for it": only a successful **action** clears a
failure. The header Refresh is a `USER` run too, so the first fix still deleted the
explanation whenever somebody tapped it to check whether the tool worked now. Clearing now
requires an `--api run`, the only thing that counts as a retry.

**A pinned failure line with evidence.** The banner used to be a verdict with no reason
("Step failed: Install package"), and it lived *inside* the scroll view, so a user who had
scrolled the list never saw it. It is now pinned under the header (as is the working
banner) and reads in the app's voice — "That step failed: …", "This CPU can't run it",
"Not enough memory right now", "PostgreSQL isn't running", "Android killed it — too little
memory". A **Details** button opens the lines that explain it, in monospace.

**`checks` in the status payload.** `status` evaluates every predicate the catalog names
under `requires.predicates` and reports `{"postgres_running": false, …}`. That is what lets
the Packages screen say "PostgreSQL isn't running" and disable the button *before* the tap,
instead of offering Install and handing back exit 3. Memory and disk stay warnings a user
may override with `--force`; predicates do not.

Two engine additions make the above possible, both documented in `CONTRACT.md`:

- On a failed step the runner replays the last 12 non-empty lines of **that step's own
  output** as `log` events before `done`. Steps write to a log file the app cannot read
  (different UID, app-private home), so this is the only channel.
- A preflight refusal's one-line reason is already a `log` event; the app now shows it
  instead of the exit code.

### The quality gate is green again

`pnpm run lint:all` failed for a long time on this branch: 221 ktlint findings, 194 of them
in `MainActivity.kt`, which made a red gate meaningless. `ktlint --format` plus two merged
KDoc blocks fixed it; the gate now passes end to end, so a failure there is a failure
again.

### APK state model — do not reintroduce composition-local state

The client follows the platform model now, and each rule exists because its absence caused a
real defect. Before adding a screen, read this list:

- **State lives in `HomeViewModel` + `HomeState`, not in `remember`.** `remember` inside a
  composable loses its value on rotation (that is how the step list, raw output and the
  failure banner used to vanish), and `LaunchedEffect(result)` re-ran on the *stale* result,
  queueing a second status run per rotate. `rememberSaveable` is only for view position: tab,
  sub-screen, search query, collapse flags.
- **Results are events: `Runner.completions` (buffered `SharedFlow`).** `Runner.result` stays a
  `StateFlow` **only** for the supervisor's `withTimeoutOrNull { … first() }` await, which
  depends on replay. Routing UI through it again reintroduces conflation (a poll and a tap
  landing together drops one) and cancellation of a half-applied handler.
- **Collect with `collectAsStateWithLifecycle`, and put timers inside
  `repeatOnLifecycle(STARTED)`.** A Composition outlives STOP: the old 30 s "age" ticker kept
  recomposing `Home` in the background, and a foreground-service start from a backgrounded
  composition is not allowed (`runCatching` used to hide that).
- **`Runner.send` is serialised on one lock** and safe from any thread. The check-then-act on
  `_running` could dispatch two RUN_COMMANDs through one `REQUEST_CODE`, losing a result and
  clearing `running` mid-install.
- **`SupervisorService` runs on `Dispatchers.Main.immediate`**, so its fields are
  single-threaded by construction. Do not move it back to `Default` without making them
  atomic.
- **Flags in `Prefs` (`SharedPreferences`), documents in a file.** The last status document is
  `StatusStore` (IO); it used to be a multi-KB JSON string inside the XML that every startup
  parses whole. `Prefs.lastStatusAt` stays a `Long` because `onResume` needs it synchronously.
- **Parse once.** `Protocol.parse(stdout)` returns a `Parsed` holder; deriving snapshot,
  catalogue, steps and failure from it is an O(1) view. Calling the old per-view functions
  re-parses the whole stream each time — five times per result, on the main thread.

### Android 14+ is where the supervisor used to die (verified on API 36)

Neither test device (y6 API 28, 8x API 29) could ever exercise this, so it went unnoticed:
a `foregroundServiceType="dataSync"` declaration with only `FOREGROUND_SERVICE` makes
`startForeground()` throw on **any** Android 14+ phone. Measured A/B on an S22 (Android 16 /
API 36, `SM-S901E`), same APK lineage:

```text
SecurityException: Starting FGS with type dataSync callerApp=… targetSDK=34
  requires permissions: allOf=true [android.permission.FOREGROUND_SERVICE_DATA_SYNC]
```

…and `dumpsys activity services` showed **no** foreground service: the watchdog was dead on
arrival. The fixed build reports `isForeground=true … types=0x40000000`
(`FOREGROUND_SERVICE_TYPE_SPECIAL_USE`) and posts its notification normally.

Two rules follow, both learned the hard way:

- **`specialUse` + `FOREGROUND_SERVICE_SPECIAL_USE`**, not `dataSync`: this service transfers
  nothing, and `dataSync` also carries a 6 h/24 h cap from targetSdk 35.
- **Re-post after a notification grant.** The FGS notification is posted in `onCreate`, which can
  precede `POST_NOTIFICATIONS`; an unchanged status never calls `update()`, so "Allow" looked like
  it did nothing until the next unlock. `onStartCommand` re-posts and the permission callback
  starts the service again (`lastStartId 1 → 2` on the device).

### The app provisions Termux; the user does not (measured on a clean S22)

A clean Termux 0.119.0-beta.3 on Android 16 exposed two first-run blockers, and the first rule
they imply: **the user should never open Termux except for `allow-external-apps`.**

1. **`--api` needs `jq` and nothing installed it.** `install.sh --api` refuses without jq (the
   TUI installs it in `ensure_deps()`; a headless run has no terminal to answer apt with). The
   launcher in `Termux.kt` now installs jq (then git/curl/tar) **before** it execs an existing
   checkout, so a checkout whose jq went missing is repaired instead of failing. It tries `pkg`,
   then `apt update` + `apt` — on that device `pkg` refuses with "No mirror or mirror group
   selected" because its own curl cannot link (`SSL_set_quic_tls_early_data_enabled`), while
   `apt` works. If provisioning still fails the launcher emits
   `{"t":"error","code":6,"msg":"missing-packages: …","hint":"…"}`, which the app turns into a
   screen naming the tool and the exact line — never "something went wrong".
2. **`api_catalog` returned `{"schema":1,"actions":[]}` on that checkout** while 40 valid specs
   sat on disk and `find`/`jq` both worked by hand. The `find … | head -1` probe plus
   `xargs -0 jq` pipeline is gone: `api_spec_files` collects `"$dir"/*/*.json` with a bash glob
   and one `jq -cs` builds the document. No find, no xargs, no SIGPIPE, and nothing that needs
   findutils installed. Symptom to remember: the app faithfully renders "0 of 0 installed"
   because the *catalog it was given* was empty — check `install.sh --api list` first.

`Gate.classify` is now a pure function with unit tests (`GateClassifyTest`), because the mapping
from "jq is required" to a generic error screen is exactly what hid this for a whole session.
Onboarding copy states the split plainly: Setup downloads the toolkit and installs the tools it
needs; the one thing it cannot do is flip `allow-external-apps`, because Android does not let one
app change another app's settings.

- **"Nothing installed" is not "services are down".** The supervisor starts at first launch, so
  `0 online` is the normal state until the user installs something. It used to treat that as a
  fault: it resurrected services that did not exist and, after three attempts, posted
  *"Services are down and restarting did not help"* on a phone with nothing installed. The verdict
  now comes from `SupervisorPolicy.classify(running, installedTools, autoStart)` (tested), which
  reports **"Nothing installed yet"**, resets the attempt counter, and stops polling. The same
  distinction gates the Overview's *Restart services* button and the Metrics empty state.
  Rule of thumb: any sentence about services must be reachable only when a tool is installed.
- **Foreground service types are declared, not guessed.** `specialUse` +
  `FOREGROUND_SERVICE_SPECIAL_USE`, and `POST_NOTIFICATIONS` is requested in context. With
  `dataSync` and no type permission, `startForeground()` throws `SecurityException` on
  Android 14+, and an ungranted notification permission makes the supervisor invisible —
  both silently, which is why neither test device (API 28 / pre-14) ever caught it.

## License Note

`ATTRIBUTIONS.md` governs third-party redistribution rules. **n8n** is under the *Sustainable Use License*; commercial resale or embedding as a paid service requires an Enterprise license. Do not remove or alter `ATTRIBUTIONS.md` without legal review.

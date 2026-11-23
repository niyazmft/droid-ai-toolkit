# APK UX & Functional Audit — device 8x

Audited build: `dev.droidai.launcher` 0.1.0 (versionCode 1)
Device: JSN-L22 (Honor 8X), Android 10 / API 29, 720×1560 @ 320 dpi, aarch64
Method: code review of all 15 Kotlin sources + on-device testing via adb (screens,
`uiautomator` accessibility tree, forced font scale, permission revocation, process
death), with the engine verified independently over SSH (port 8022).

Audience for these findings: **someone who has never opened Termux**, for whom the
happy path must be "install Termux from F-Droid, then never think about it again".

---

## Verdict

The engine is solid; the client was written by and for someone who already knows what
`pm2`, `pnpm` and `aarch64` mean. Three of the findings below are not polish — on a
cold device they make the app **unusable or actively misleading**, and one of them
contradicts the stated happy path outright.

Fixed in this session: 12 findings (marked ✅). The rest are documented with a
recommended fix, because they need engine work or a product decision.

---

## P0 — cold start

### ✅ F1. Every launch opened on a false "broken setup" screen

`Root()` rendered the *failure* gate whenever `Gate.probeOk` was `null` — i.e. during
the first status run, which takes ~8 s on this device. Measured: at t≈2 s and t≈4 s the
screen read **"Enable external commands"** with a shell command to type; at t≈12 s the
same launch showed a healthy Overview. A new user's first impression of the app was an
error page telling them to fix a setting that was already correct.

Fix: `Probe.CHECKING` is now a distinct state with a neutral "Checking your device…"
screen.

### ✅ F2. A cold device was told to fix the wrong thing

The probe test was `exitCode == 0 && stdout contains "\"t\":\"data\""`. Every other
outcome — including "there is no toolkit installed yet" — fell through to the
allow-external-apps screen. So the one screen a brand-new user is guaranteed to see
told them to edit `~/.termux/termux.properties`, which cannot possibly help.

Fix: `Runner.classify()` distinguishes `NO_TOOLKIT`, `DENIED`, `UNREACHABLE` and
`ERROR` by reading the engine's own error code, and each gets its own screen.

### ✅ F3. The app could never bootstrap itself

The launcher looked for `install.sh` + `lib/` under `~/droid-ai-toolkit` and
`~/toolkit-test`, and otherwise emitted `{"t":"error","code":4,"msg":"toolkit not
found"}`. On a fresh device there is nothing to find, so the app was permanently
stuck: it needs the toolkit to install the toolkit.

`install.sh --api` also **refuses to run outside a checkout** (`lib/ not found: --api
must run from the toolkit checkout, not curl|bash`), so the documented
`curl … | bash` bootstrap is not a sufficient answer.

Fix: when no checkout exists the launcher now fetches one (`git clone --depth 1`, with
a tarball fallback for a device without git) and execs it. `$HOME/install.sh` was also
removed as a candidate — it is exactly the stale monolith that broke the Hermes update
on 8x (AGENTS.md v1.17.7).

### ✅ F4. The one unavoidable Termux step was a command to retype

`allow-external-apps` can only be set by Termux itself, so one manual step remains. The
app presented it as two lines of shell in a paragraph, with no copy button, and
required the user to find a "Retry" button after switching back.

Fix: the line is shown in a monospace panel with **Copy the line**, the primary button
copies *and* opens Termux, and returning to the app re-probes automatically
(`onResume`).

---

## P0 — while work is running

### ✅ F5. A 30-second deadline declared failure in the middle of a 40-minute install

`LaunchedEffect(busy)` called `Runner.timeout(30)` for every command. Installing Hermes
or OpenClaw takes 10–40 minutes, so the UI showed a red failure ~30 s in and — worse —
went on accepting taps, so a second install could be started on top of the first, both
writing to one pnpm store.

Fix: ceilings are per caller (probe 25 s, supervisor 90 s, user action 60 min) and
`checkCeiling()` only exists to clear a genuinely wedged run.

### ✅ F6. Tapping Install did nothing, silently

`Runner.send()` returns `false` while another command is in flight, and the supervisor
polls `--api status` through the same single-slot transport every 60 s. Any tap landing
in that window was dropped with no message. The return value was ignored at every call
site.

Fix: `Origin` separates user actions from the supervisor's polls. A user action is
**queued** behind the running command and dispatched when it finishes, with a snackbar
that says so.

### ✅ F7. No sign of life during a long run

A background `RUN_COMMAND` only reports at the end, so the app showed a static spinner
labelled "Installing…" for up to 40 minutes. Nothing distinguished "working" from
"frozen".

Fix: a banner naming the action with a live elapsed timer, and — past 20 s — an
explanation that large tools take 20–40 minutes.

### ✅ F8. No completion feedback off the Overview tab

Finishing an install while on Packages changed nothing visible, and the supervisor's
own status run overwrote the "Last run" list every 60 s, erasing the user's record.

Fix: a snackbar on completion/failure, and `steps`/`raw` are only updated for
`Origin.USER`.

---

## P1 — navigation and state

### ✅ F9. Hardware Back quit the app from Raw Output

Verified: pressing Back on the Raw Output sub-screen returned to the Huawei launcher
(`mResumedActivity` → `unihome.UniHomeLauncher`). Fix: `BackHandler` pops the sub-screen;
re-verified — the activity stays resumed.

### ✅ F10. Rotation or process death reset the UI

`remember` (not `rememberSaveable`) for the tab, the sub-screen flag and the search
query. Fix: `rememberSaveable` for all three.

### ✅ F11. Fact rows lost their own values at the default font size

`maxLines = 1` + `Ellipsis` produced `Command perm…` and `JSN-L22 · Android 10 (…` at
font scale 1.0, and worse at 1.3. Fix: two lines; verified wrap of the long Hermes
version string.

---

## P1 — comprehension

### ✅ F12. "Repair" was offered to devices with nothing installed

The label was `action.id == "hermes.install" -> "Repair"`, unconditional. A fresh device
was told to repair a thing it did not have. Fix: label depends on install state.

### ✅ F13. "Available" was painted in the error colour

`StatusChip(online = row.installed)` reused the error container for *not installed*, so
every uninstalled tool looked broken. Fix: a neutral variant.

### ✅ F14. Every action on a card had the same label

All non-destructive actions rendered "Update"/"Install", so a card with two of them had
two identical buttons — indistinguishable by eye and to TalkBack. Fix: labels derive
from the action.

### ✅ F15. The selected filter chip looked disabled

`enabled = category != c` greyed the *selected* chip, inverting the visual language and
removing it from the TalkBack focus order. Fix: `FilterChip(selected = …)`.

### ✅ F16. "Workflows" wrapped, breaking the chip row

Fix: horizontally scrolling row, one line at any font scale.

### ✅ F17. The Security panel spoke in `adb`

It printed `adb shell pm revoke <pkg> com.termux.permission.RUN_COMMAND` to an audience
that does not have a terminal. Fix: plain sentence first ("If you did not install one of
these, uninstall it from Android Settings → Apps"), command kept as the technical tail.

---

## P1 — accessibility

### ✅ F18. Switch rows were three unlabelled stops

Title, subtitle and an unlabelled `Switch` were separate focus targets, so a
screen-reader user could not tell which setting a toggle belonged to. Fix:
`toggleable(role = Role.Switch)` on the row, `onCheckedChange = null` on the switch —
one stop that announces "…, on, switch".

### ✅ F19. Charts were invisible to screen readers

Both `Canvas` charts exposed no semantics; the Memory panel was silent apart from its
caption. Fix: generated `contentDescription` with low/high values.

### ✅ F20. Step outcomes were a glyph, and failure was colour-only

`✔ Collect device status` was announced as "heavy check mark Collect device status", and
a failure was communicated only by red text. Fix: "Done — …", "Failed — …" plus
`stateDescription`.

### ✅ F21. Nav items announced their label twice

`Icon(contentDescription = t.label)` + `Text(t.label)`. Fix: `contentDescription = null`.

### ✅ F22. Touch targets

Interactive rows and text buttons were 40 dp-ish. Fix: `heightIn(min = 48.dp)` on the
rows and buttons touched here (Material 3 / WCAG 2.5.5 = 48 dp).

### ✅ F23. No announcement when a run finished or failed

Fix: snackbar (announced by TalkBack) plus `liveRegion = Polite` on the failure text.

### Verified good

* Contrast: all text pairs ≥ 4.6:1 (light and dark palettes, computed).
* Content descriptions on all icon-only controls (Refresh, Back, Clear, Copy).
* Bottom nav labels and icons render correctly at font scale 1.3.

---

## Not fixed — recommended next

| # | Finding | Recommendation |
|---|---|---|
| F24 | **No streamed progress.** Background `RUN_COMMAND` returns only at the end, so step names cannot reach the UI. | Have the engine append NDJSON to a file Termux can write *and* the app can read (`~/storage/shared/droid-ai/progress.ndjson`, requires `termux-setup-storage` + `requestLegacyExternalStorage` on API 29), then tail it from the supervisor tick. This is the single largest remaining UX gap for long installs. |
| F25 | **No strings.xml.** All copy is inline Kotlin, so there is no translation and no RTL verification despite `supportsRtl="true"`. | Extract to `strings.xml`; add `values-ar` once content is stable. |
| F26 | **Dark mode unverified.** `cmd uimode night yes` is ignored on EMUI (returns "Night mode: no"), so the dark palette was audited by computation only. | Verify on a device that honours the override, or add a temporary in-app theme toggle for screenshots. |
| F27 | **Jargon still surfaces** in the Device panel (`aarch64`, `PM2`, `v24.22.3`). | Add a plain-language subtitle per fact ("arch — how the phone's processor is built"), or move the technical block under a disclosure on Settings. |
| F28 | **No first-run "what should I install?" guidance.** Overview's empty state says "Nothing is running yet", which does not name the next step. | Promote a single suggested tool on Packages for an empty device, with one-line "what this gives you". |
| F29 | **Supervisor notification is a second, unlabelled surface**: it reports service counts but has no per-service detail, and `Stop` is the only action. | Add "Open" + "Restart" actions and name the affected service. |
| F30 | **`TerminalIcon` and `Placeholder` are dead code.** | Delete, or use `TerminalIcon` for the raw-output entry point. |
| F31 | **Metrics charts have no axes or units** (the swap chart's colour was `tertiary`, which rendered as an alarming maroon line on 8x). | Add y-axis labels and use a non-alarming colour for a healthy series. |

---

## Repeatable smoke test

`scripts/apk-smoke.sh` drives the installed app over adb and asserts the things that
regressed here: no false gate on cold start, Back pops the sub-screen, the tab survives
rotation, and large font does not clip fact values. Run it after any UI change:

```bash
./scripts/apk-smoke.sh            # device must be attached and the app installed
```

---

## Follow-up (same session): cold-start polish, and the Termux notification

### ✅ F32. A warm device still paid ten seconds of ceremony on every launch

The probe is a full `--api status` run (~8 s here), and it gated the first screen, so a
device that had worked for weeks still opened on "Checking your device…" every time.

Fix: a persisted `termux_ready` flag. Once the gates have passed, the app opens straight
onto the Overview while the probe refreshes in the background; `Runner.classify()` clears
the flag if the probe really fails, so a broken device still falls back to the gate during
the same launch. The Overview also shows a "Reading device status…" placeholder for the
window where the snapshot has not arrived, instead of a page with no Device panel.

This also removed a redundant request: Root() owns the startup probe (a status run), and
Home no longer sends a second status of its own, which previously competed for the single
transport slot.

### ✅ F33. The gate copy read like an error, not a safety confirm

The allow-external-apps screen led with "Termux only accepts commands from other apps
when allow-external-apps is true" — accurate, and indistinguishable from "this app is
broken". It now says why the gate exists ("a safety feature protecting your shell — it is
not a fault in this app, and it is the only step it cannot do for you") before asking for
the one paste.

### F34. Termux's rejection notification is sticky, and the supervisor made it spam

`termux_plugin_command_errors_notification_channel` is posted with `flags=0x10`
(`FLAG_ONGOING_EVENT`) and **never cancelled**, including after subsequent commands
succeed. Verified on 8x: the notification was still live hours after the property was
restored and commands were working again.

Worse, the supervisor polls `--api status` once a minute through RUN_COMMAND. While the
gate is closed, every one of those polls is rejected and posts that notification again —
`post_frequency` showed **907 notifications from com.termux in one day**.

Fix: `SupervisorService.tick()` refuses to send RUN_COMMAND while `Gate.probe` is `DENIED`
or `NO_TOOLKIT` (policy-closed), and updates the notification to say setup is unfinished
instead. `UNREACHABLE` still polls on purpose — detecting a dead Termux is the service's
whole job, and an unanswered request posts no notification.

The notification itself belongs to Termux and cannot be cancelled by another app; it
clears when Termux's process restarts or the device reboots. It is cosmetic.

### F35. `termux-reload-settings` is not reliably picked up by RunCommandService

Observed directly: with `allow-external-apps=true` present in the file and
`termux-reload-settings` run, Termux still answered
`RunCommandService requires allow-external-apps property to be set to true` — and later
accepted the same request. The setting is cached per Termux process.

Fix (copy only, since the app cannot read or force that process): the gate now tells the
user that a still-refusing Termux has not reloaded, and to swipe Termux away from recents
before tapping Check again. `uiautomator` confirms the screen renders as intended.

**Consequence for support:** "I ran the command and it still says no" has a known cause
that is not the user's mistake. Do not answer it with a reinstall.

---

## Follow-up: the supervisor's cost, and making it optional

### ✅ F36. The supervisor polled every 60 s at ~19 s of CPU each

Measured on 8x: one `--api status` run costs **22.6 s wall / 18.9 s user CPU**. The
supervisor ran it **every 60 s**, so it held roughly a third of a CPU core permanently, and
re-posted its notification on every tick — `post_frequency … count=163, demoted=163`, i.e.
Android had started demoting the app for chattiness.

This is the answer to "isn't that notification consuming resources": the notification is
nearly free and is *mandatory* for a foreground service, but the polling behind it was the
actual drain.

Three changes:

* **Post only on change.** An unchanged status is not news.
* **Adaptive cadence.** Healthy → 5 min; something wrong → 60 s; nothing at all while
  `PowerManager.isDeviceIdleMode` (a dozing phone should not spend 19 s of CPU to be told
  nothing changed).
* **Timeout 25 s → 45 s.** 25 s against a 22.6 s run was a coin flip, so healthy devices
  occasionally showed "Termux is not responding" because the poll was abandoned a second
  before its answer arrived.

Measured after: **1 notification post in 180 s**, and ~6% of a core instead of ~23%.

### ✅ F37. `status` spent most of its time starting interpreters

The version probes (`openclaw`, `hermes`, `n8n`, `ollama`, `pnpm`) each boot a Node or
Python runtime to print one string. `--api status --fast` skips them and leaves those
fields blank; device facts, Termux readiness and `services` are unchanged.

Measured on 8x, same device, back to back:

| | wall | user CPU |
|---|---|---|
| `status` | 23.1 s | 19.5 s |
| `status --fast` | 7.2 s | 5.3 s |

**3.7× less CPU.** The supervisor uses `--fast`; the app's own refresh keeps the full form,
and a system-origin snapshot is no longer allowed to overwrite a full one — otherwise the
blank versions would wipe OpenClaw/Hermes from the Device panel every five minutes.
`docs/CONTRACT.md` documents the flag and warns consumers not to read a blank version as
"not installed".

What remains in fast mode is mostly `pm2 jlist`, which starts Node too. Replacing it with a
read of the daemon's own files is the next step down, and is an engine change rather than a
cadence tweak.

### ✅ F38. The supervisor is now the user's choice

Settings → Startup & Services → **"Show a status notification"**.

The notification is required by Android for a foreground service, so the only way to remove
it is to stop supervising — which is a real trade: nothing then notices the runtime dying
silently, and nothing restarts services. Default is on, the subtitle states the cost of
turning it off, and the preference persists.

Turning it off calls `stopService` and cancels the notification (not the `ACTION_STOP`
broadcast: sending an action to a stopped service starts it first, flashes a "Starting…"
notification, then stops). Verified on 8x: shade went from *Droid AI · 2 service(s) online*
to just Termux and Android system, `SupervisorService` record gone; turning it back on
restored both.

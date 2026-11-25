# Contract: `install.sh --api` ⇄ the Android app

The APK is a client. Everything it can do goes through this interface, and nothing in
the app should assume more than what is written here.

## Two frontends, one catalog

`bash install.sh` with no flags is the interactive TUI; `--api` is the machine interface.
Both are supported: the TUI needs no companion app and no `RUN_COMMAND` permission, which
matters for anyone who does not want to install the APK. They must agree because both read
`actions/` — behaviour that exists only in the TUI is a bug in the catalog, and vice versa.

## Invocation

```bash
bash install.sh --api list
bash install.sh --api status [--fast]
bash install.sh --api health
bash install.sh --api run <action-id> [--answers FILE] [--fresh] [--yes] [--force]
```

`--api` runs headless: no menu, no TUI, no TTY required. The TUI is a separate frontend
over the same actions.

### `--force`

`--force` lets the caller override the **capacity** gates (`min_mem_mb`, `min_disk_mb`)
after showing the numbers to a human: it is the "install anyway" button, and without it
that button cannot keep its promise. The preflight event then reports `ok: true` with
`forced: true`.

It does **not** override `requires.arch` or `requires.predicates`. No amount of intent
makes a 32-bit device run an aarch64-only tool, or makes `pkg install` find a package the
repo does not carry; those still return exit 3. A caller that disables the button instead
of relying on the refusal is showing the user the truth earlier.

### `--fast`

`status --fast` returns the same document with the tool version strings left blank
(`tools.pnpm`, `tools.openclaw`, `tools.hermes`, `tools.n8n`, `tools.ollama`). Device
facts, Termux readiness and the `services` array are unaffected.

A consumer must not treat a blank version as "not installed". The flag exists because
each version probe starts a whole Node or Python interpreter: measured on 8x, a full
status run costs 22.6 s wall and 18.9 s of user CPU, which is far too much for a timer.
Use `--fast` for polling, and the full form when a screen is about to display versions.

### `health`

The cheapest question the client asks: **is the toolkit alive?** It reads
`~/.pm2/pm2.pid`, `~/.pm2/pids/*.pid` and `/proc/<pid>` in pure bash — no `pm2 jlist`, no
Node, no `jq`, no process spawn — so it answers in tens of milliseconds where
`status --fast` costs ~6 s on y6 / 7.2 s on 8x (measured 90 ms vs 6065 ms on y6,
2026-11-25).

```json
{"t":"data","kind":"health","payload":{
  "pm2":{"pid":12345,"alive":true},
  "services":[{"name":"openclaw","pid":12400,"alive":true}],
  "online":1,"total":1,"node_procs":4,"checked_at":1795637289
}}
```

- `pm2.alive` is **not** "the pid file exists". A crashed or LMK-killed daemon leaves
  `pm2.pid` behind, so liveness is `[ -d /proc/<pid> ]` — and the same rule applies per
  service, because `~/.pm2/pids/*.pid` survives `pm2 stop`.
- `total` counts pid files; `online` counts the live ones. They differ exactly when
  something is wrong, which is the interesting case.
- `node_procs` is a `/proc` count of `node` processes, for measuring how much a refresh
  costs (see the Tier-1 numbers in `TASKS.md`).
- It carries **no versions, memory or catalog**. A caller that needs those uses
  `status --fast`; this endpoint exists so a per-unlock poll does not pay for them.
- Stream shape is the same as every other command: `start`, one `data`, `done`.

## Events (NDJSON, one object per line, stdout)

| `t` | Meaning | Fields |
|---|---|---|
| `start` | run begins | `schema`, `action`, `run_id` |
| `preflight` | device gates evaluated | `ok`, `arch`, `mem_mb`, `disk_mb`, `forced` (only when `--force` overrode a capacity gate) |
| `step` | a step changed state | `id`, `state` (`running`/`ok`/`failed`/`skipped`), `title`, `ms` |
| `ask` | engine needs an answer | `id`, `kind` (`confirm`/`text`/`choice`), `title`, `default`/`options` |
| `log` | a line of detail | `step`, `line` |
| `data` | structured result | `kind`, `payload` |
| `done` | run finished | `code`, `skipped[]` |
| `error` | refused or crashed early | `code`, `msg` |

Only these objects appear on stdout. Everything a step prints goes to its own log file
under `~/.droid_ai_toolkit/log/`.

Two things travel as `log` events because a client cannot read those files (Termux's home
is app-private):

- **A refusal says why.** The `preflight` event carries `ok:false`; the sentence after it
  names the arch, memory and disk numbers and any `unmet:` predicates. A client should
  show that line rather than the exit code.
- **A failed step says why.** Before `done`, the last 12 non-empty, ANSI-stripped lines of
  that step's own output are replayed as `log` events with `step` set to the failing step
  id. Without this the stream can only say "that step failed", and the reason
  (`E: Unable to locate package ollama`, `not on PATH: pi`) is invisible to the app.

## Status payload: `checks`

`status` evaluates every predicate the catalog names in `requires.predicates` and reports
the result:

```json
"checks": { "postgres_running": false, "pkg_available:ollama": true }
```

This is the client-side half of the preflight. Memory and disk are warnings a user may
override with `--force`; an unmet predicate is a refusal, so showing it before the tap is
the difference between a disabled button with a reason and a bare exit 3. A predicate that
cannot be evaluated is reported `false`, which matches the engine's fail-closed behaviour.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | a step failed |
| 2 | usage error |
| 3 | preflight refused (arch, RAM/disk without `--force`, unmet predicate, not Termux) |
| 4 | cancelled — including a destructive action without `--yes` |
| 5 | an `ask` was not answered |
| 137 | a step was SIGKILLed and retries were exhausted |

## Safety semantics

- **Skip only what is idempotent.** A step marked `"idempotent": true` may be skipped
  when its recorded run succeeded **with the same definition** (the state stores a
  fingerprint of the step). Change the spec and the record stops counting.
- **Queries always run.** `status`'s snapshot step is not idempotent, so it re-reads the
  device every time. Skipping it produced a stream with no `data` event, which every
  consumer reads as failure.
- **Uninstalling invalidates the install checkpoint.** A tool's install step is
  idempotent, so its `ok` record would otherwise survive the removal and make the next
  Install a no-op that fails at verify. `step_uninstall_tool` and `step_hermes_uninstall`
  delete `state/<tool>.*.json` for exactly this reason.
- **Presence means either layout.** `tools.installed` is true when the per-tool project
  exists **or** the pre-migration `global/<n>/node_modules/<pkg>` exists *and* the tool's
  bin is on PATH. Devices that never migrated (y6 still serves OpenClaw from `global/5`)
  would otherwise be reported as "Disappeared — its files are gone" while the gateway is
  running; the PATH half is what keeps a removed tool from still counting as installed.
- **Destructive needs `--yes`.** A spec with `"destructive": true` returns exit 4
  without it. The app confirms in a dialog and passes the flag.
- **No answer, no default.** An unanswered `ask` aborts (exit 5). Silence is never
  consent.

## Environment notes the caller must assume

- Termux is the executor: the app cannot touch its files or run its binaries.
- The engine sets `LD_PRELOAD=libtermux-exec.so` and re-execs itself, because Android
  has no `/usr/bin/env` and every shebang script fails without it under `RUN_COMMAND`.
- Results come back through the caller's `PendingIntent` bundle (`result` →
  `stdout`, `stderr`, `exitCode`, `err`, `errmsg`) or a result directory.

## Layout

```text
~/.local/share/pnpm/tools/<tool>/   one pnpm project per tool
~/.local/share/pnpm/store/          shared content store
$PREFIX/bin/<bin>                   exec wrapper into that tool's project
~/.droid_ai_toolkit/state/          per-action checkpoint (step fingerprints)
~/.droid_ai_toolkit/log/            per-run logs
```

## Versioning

`schema` is `1`. A consumer that sees a higher number must refuse rather than guess.
Adding a field is compatible; changing the meaning of an existing one is not.

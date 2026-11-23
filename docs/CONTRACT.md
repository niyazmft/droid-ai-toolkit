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
bash install.sh --api run <action-id> [--answers FILE] [--fresh] [--yes]
```

`--api` runs headless: no menu, no TUI, no TTY required. The TUI is a separate frontend
over the same actions.

### `--fast`

`status --fast` returns the same document with the tool version strings left blank
(`tools.pnpm`, `tools.openclaw`, `tools.hermes`, `tools.n8n`, `tools.ollama`). Device
facts, Termux readiness and the `services` array are unaffected.

A consumer must not treat a blank version as "not installed". The flag exists because
each version probe starts a whole Node or Python interpreter: measured on 8x, a full
status run costs 22.6 s wall and 18.9 s of user CPU, which is far too much for a timer.
Use `--fast` for polling, and the full form when a screen is about to display versions.

## Events (NDJSON, one object per line, stdout)

| `t` | Meaning | Fields |
|---|---|---|
| `start` | run begins | `schema`, `action`, `run_id` |
| `preflight` | device gates evaluated | `ok`, `arch`, `mem_mb`, `disk_mb` |
| `step` | a step changed state | `id`, `state` (`running`/`ok`/`failed`/`skipped`), `title`, `ms` |
| `ask` | engine needs an answer | `id`, `kind` (`confirm`/`text`/`choice`), `title`, `default`/`options` |
| `log` | a line of detail | `step`, `line` |
| `data` | structured result | `kind`, `payload` |
| `done` | run finished | `code`, `skipped[]` |
| `error` | refused or crashed early | `code`, `msg` |

Only these objects appear on stdout. Everything a step prints goes to its own log file
under `~/.droid_ai_toolkit/log/`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | a step failed |
| 2 | usage error |
| 3 | preflight refused (arch, RAM, disk, missing tool, not Termux) |
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

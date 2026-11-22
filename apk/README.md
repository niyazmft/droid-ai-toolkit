# Droid AI launcher (Android app)

Native front end for the toolkit. **Termux is the executor** — the app is UI,
onboarding and (later) supervision. It never runs Linux commands itself and
never touches Termux's private files.

## Build

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew :app:assembleDebug        # → app/build/outputs/apk/debug/app-debug.apk
```

`local.properties` holds the SDK path and is gitignored.

## Install

Copy the APK to the phone and tap it (or `adb install -r app-debug.apk`).
The debug build is signed with the standard debug key.

## First run — three gates, in order

1. **Termux installed.** F-Droid / GitHub release, not the Play Store build.
2. **`com.termux.permission.RUN_COMMAND` granted** (dangerous; appears under
   *Additional permissions*).
3. **`allow-external-apps = true`** in `~/.termux/termux.properties` — the app
   cannot set this itself (the property lives in Termux's private dir, and the
   intent that would set it is the one the property gates). The app probes by
   actually sending a command; failure to produce a result means the gate is
   still closed.

## What it does today (v0.1)

- Runs `install.sh --api status` and shows the raw NDJSON.
- Runs `install.sh --api list` to show the action catalog.

Results arrive through a `PendingIntent` broadcast, because a background
`RUN_COMMAND` has no TTY and no shared filesystem.

## Not yet

- Per-action screens and native mid-run questions (contract supports them).
- Supervisor: foreground service, health check, graceful restart.

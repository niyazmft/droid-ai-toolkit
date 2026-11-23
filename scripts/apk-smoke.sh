#!/usr/bin/env bash
# Smoke test for the Droid AI APK, on a real device over adb.
#
# It asserts the behaviours that actually regressed on 8x, not a screenshot diff:
#
#   1. cold start shows "Checking your device…", never the allow-external-apps page
#   2. a probe that succeeds reaches the Overview
#   3. hardware Back on Raw Output pops the sub-screen instead of quitting the app
#   4. the selected tab survives a rotation
#   5. Settings still renders at font scale 1.3
#
# Usage:  ./scripts/apk-smoke.sh
# Requires: adb with a device attached, and the app installed.
#
# Exit codes: 0 all checks passed, 1 a check failed, 2 the harness could not run.

set -uo pipefail

PKG="dev.droidai.launcher"
ACTIVITY="$PKG/.MainActivity"
SERIAL="${ANDROID_SERIAL:-}"

pass=0
fail=0
original_font_scale=""

say() { printf '%s\n' "$*"; }
ok() {
  pass=$((pass + 1))
  printf '  PASS  %s\n' "$*"
}
bad() {
  fail=$((fail + 1))
  printf '  FAIL  %s\n' "$*"
}

adb_cmd() {
  if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi
}

cleanup() {
  # Always put the device back: a smoke test that changes global display settings
  # and walks away is a bug report waiting to happen.
  if [ -n "$original_font_scale" ]; then
    adb_cmd shell settings put system font_scale "$original_font_scale" >/dev/null 2>&1 || true
  fi
  adb_cmd shell settings put system user_rotation 0 >/dev/null 2>&1 || true
  adb_cmd shell settings put system accelerometer_rotation 1 >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The accessibility tree is the only stable text oracle here: Compose draws text on a
# Canvas, so OCR would be the alternative and that is not reproducible.
dump_ui() {
  adb_cmd shell uiautomator dump /sdcard/smoke.xml >/dev/null 2>&1 || true
  adb_cmd shell cat /sdcard/smoke.xml 2>/dev/null | tr -d '\r'
}

on_screen() { printf '%s' "$1" | grep -Fq -- "$2"; }

resumed_activity() {
  adb_cmd shell dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity
}

# Tap a control by its text, not by a coordinate.
#
# Fixed coordinates were the first version of this script, and they broke the moment the
# font scale changed: the bottom bar grows, so a fixed y stopped hitting the tab.
tap_text() {
  local label="$1" ui coords
  ui=$(dump_ui)
  coords=$(printf '%s' "$ui" | LABEL="$label" python3 -c '
import os, re, sys
label = os.environ["LABEL"]
for m in re.finditer(
    r"text=\"([^\"]*)\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", sys.stdin.read()
):
    if m.group(1).strip() == label:
        print((int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
        break
' 2>/dev/null)
  if [ -z "$coords" ]; then
    return 1
  fi
  # shellcheck disable=SC2086  # two integers by construction
  adb_cmd shell input tap $coords >/dev/null 2>&1
  return 0
}

# --- harness -----------------------------------------------------------------

if ! command -v adb >/dev/null 2>&1; then
  say "adb not found in PATH" >&2
  exit 2
fi

devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}' | wc -l | tr -d ' ')
if [ "$devices" -eq 0 ]; then
  say "no adb device attached" >&2
  exit 2
fi

if ! adb_cmd shell pm list packages 2>/dev/null | grep -q "package:$PKG"; then
  say "$PKG is not installed on the device" >&2
  exit 2
fi

original_font_scale=$(adb_cmd shell settings get system font_scale 2>/dev/null | tr -d '\r')
if [ -z "$original_font_scale" ] || [ "$original_font_scale" = "null" ]; then
  original_font_scale=1.0
fi

# --- 1. cold start must not show a false failure ------------------------------

say "1. cold start"
adb_cmd shell am force-stop "$PKG" >/dev/null 2>&1
adb_cmd shell am start -n "$ACTIVITY" >/dev/null 2>&1
sleep 2
early=$(dump_ui)

if on_screen "$early" 'allow-external-apps'; then
  bad "cold start showed the allow-external-apps instructions while still probing"
else
  ok "cold start does not blame allow-external-apps while probing"
fi

if on_screen "$early" 'Checking your device'; then
  ok "cold start shows a neutral checking state"
elif on_screen "$early" 'Droid AI'; then
  ok "probe finished before the first sample (already on Overview)"
else
  bad "cold start showed neither a checking state nor the Overview"
fi

# --- 2. a successful probe reaches the Overview -------------------------------

say "2. ready state"
ready=0
for _ in $(seq 1 20); do
  sleep 2
  ui=$(dump_ui)
  # Device + Services come from the status payload. "Last run" is deliberately absent
  # until the user runs something: probe/supervisor runs must not fill that panel.
  if on_screen "$ui" 'Device' && on_screen "$ui" 'Model'; then
    ready=1
    break
  fi
  if on_screen "$ui" 'allow-external-apps'; then
    break
  fi
done

if [ "$ready" -eq 1 ]; then
  ok "reached the Overview after the probe"
else
  bad "did not reach the Overview (device not set up, or the probe never answered)"
  if on_screen "$(dump_ui)" 'allow-external-apps'; then
    say "        the app is showing its one-time setup screen; finish it by hand, then re-run"
  fi
fi

# --- 3. Back on the Raw Output sub-screen must not quit -----------------------

say "3. back navigation"
if [ "$ready" -eq 1 ]; then
  for _ in 1 2 3 4; do
    adb_cmd shell input swipe 360 1200 360 300 120 >/dev/null 2>&1
  done
  sleep 1
  if tap_text "Show raw output"; then
    sleep 2
    if on_screen "$(dump_ui)" 'Raw Output'; then
      adb_cmd shell input keyevent KEYCODE_BACK >/dev/null 2>&1
      sleep 2
      if resumed_activity | grep -q "$PKG"; then
        ok "Back on Raw Output returned to the app instead of quitting"
      else
        bad "Back on Raw Output quit the app"
      fi
    else
      bad "could not open the Raw Output screen"
    fi
  else
    bad "could not find the Show raw output button"
  fi
else
  say "  SKIP  back navigation (not on the Overview)"
fi

# --- 4. the tab must survive a rotation ---------------------------------------

say "4. rotation keeps the tab"
if [ "$ready" -eq 1 ]; then
  tap_text "Packages" || bad "could not find the Packages tab"
  sleep 2
  adb_cmd shell settings put system accelerometer_rotation 0 >/dev/null 2>&1
  adb_cmd shell settings put system user_rotation 1 >/dev/null 2>&1
  sleep 3
  if on_screen "$(dump_ui)" 'Packages'; then
    ok "rotation kept the user on Packages"
  else
    bad "rotation reset the screen"
  fi
  adb_cmd shell settings put system user_rotation 0 >/dev/null 2>&1
  adb_cmd shell settings put system accelerometer_rotation 1 >/dev/null 2>&1
  sleep 2
else
  say "  SKIP  rotation (not on the Overview)"
fi

# --- 5. large font must still render Settings ---------------------------------

say "5. large font"
if [ "$ready" -eq 1 ]; then
  adb_cmd shell settings put system font_scale 1.3 >/dev/null 2>&1
  adb_cmd shell am force-stop "$PKG" >/dev/null 2>&1
  adb_cmd shell am start -n "$ACTIVITY" >/dev/null 2>&1
  sleep 18
  tap_text "Settings" || bad "could not find the Settings tab at font scale 1.3"
  sleep 2
  # Assert on a fact near the top of Settings: at 1.3x the Termux panel scrolls below
  # the fold, and uiautomator dumps only what is on screen.
  ui=$(dump_ui)
  if on_screen "$ui" 'Version' && on_screen "$ui" 'Package'; then
    ok "Settings renders at font scale 1.3"
  else
    bad "Settings did not render at font scale 1.3"
  fi
  adb_cmd shell settings put system font_scale "$original_font_scale" >/dev/null 2>&1
else
  say "  SKIP  large font (not on the Overview)"
fi

# --- summary -----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

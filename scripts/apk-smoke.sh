#!/usr/bin/env bash
# Smoke test for the Droid AI APK, on a real device over adb.
#
# It asserts the behaviours that actually regressed on 8x, not a screenshot diff:
#
#   1. cold start shows "Checking your device…", never the allow-external-apps page
#   2. a probe that succeeds reaches Home
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

# node_height <ui-xml> <exact text> -- the pixel height of that text node, or empty.
#
# Used by §5: a fact row that wraps into a paragraph is ~2x the height of one that does not,
# and "did it wrap" is otherwise a judgement call on a screenshot.
node_height() {
  printf '%s' "$1" | TXT="$2" python3 -c '
import os, re, sys
want = os.environ["TXT"]
for m in re.finditer(
    r"text=\"([^\"]*)\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", sys.stdin.read()
):
    if m.group(1).strip() == want:
        print(int(m.group(5)) - int(m.group(3)))
        break
' 2>/dev/null
}

resumed_activity() {
  adb_cmd shell dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity
}

# Tap a control by its text, not by a coordinate.
#
# Fixed coordinates were the first version of this script, and they broke the moment the
# font scale changed: the bottom bar grows, so a fixed y stopped hitting the tab.
tap_text() {
  local label="$1" ui coords try
  for try in 1 2 3; do
    ui=$(dump_ui)
    coords=$(printf '%s' "$ui" | LABEL="$label" python3 -c '
import os, re, sys
label = os.environ["LABEL"]
for m in re.finditer(
    r"text=\"([^\"]*)\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", sys.stdin.read()
):
    if m.group(1).strip() != label:
        continue
    x1, y1, x2, y2 = (int(m.group(i)) for i in (2, 3, 4, 5))
    # An empty frame cannot be tapped, and tapping it silently hits (0,0). A clipped node
    # (the tab bar at font scale 1.3, before the bar was allowed to grow) reports exactly
    # this, so keep looking instead of tapping the corner of the screen.
    if x2 > x1 and y2 > y1:
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
' 2>/dev/null)
    if [ -n "$coords" ]; then
      # shellcheck disable=SC2086  # two integers by construction
      adb_cmd shell input tap $coords >/dev/null 2>&1
      return 0
    fi
    # A dump taken mid-transition (right after Back, or while the app is still drawing the
    # first frame) can be empty or partial. Re-dump instead of failing on the first try.
    sleep 1
  done
  return 1
}

# scroll_to <text> [max swipes] -- scroll down until the text is on screen.
#
# Fixed swipe counts stopped working as the page grew (Settings gained a reboot state block
# and a cleanup panel); a fixed count either stops short or scrolls past the target.
scroll_to() {
  local want="$1" max="${2:-8}" i
  for i in $(seq 1 "$max"); do
    if on_screen "$(dump_ui)" "$want"; then
      return 0
    fi
    adb_cmd shell input swipe 360 1200 360 500 150 >/dev/null 2>&1
    sleep 1
  done
  on_screen "$(dump_ui)" "$want"
}

# Tap a control by its content description (the gear icon has no text).
tap_desc() {
  local desc="$1" ui coords try
  for try in 1 2 3; do
    ui=$(dump_ui)
    coords=$(printf '%s' "$ui" | DESC="$desc" python3 -c '
import os, re, sys
want = os.environ["DESC"]
for m in re.finditer(
    r"content-desc=\"([^\"]*)\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", sys.stdin.read()
):
    if m.group(1).strip() != want:
        continue
    x1, y1, x2, y2 = (int(m.group(i)) for i in (2, 3, 4, 5))
    if x2 > x1 and y2 > y1:
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
' 2>/dev/null)
    if [ -n "$coords" ]; then
      # shellcheck disable=SC2086  # two integers by construction
      adb_cmd shell input tap $coords >/dev/null 2>&1
      return 0
    fi
    sleep 1
  done
  return 1
}

# Tap one of the bottom tabs by position.
#
# The tab's *label* cannot be used: `selectable(role = Tab)` merges its descendants into one
# semantics node, so uiautomator reports the label with an empty frame ([0,0][0,0]) and a
# coordinate tap on it lands in the corner of the screen. The selectable node itself carries
# real bounds but no text, so the tab is identified by its place in the bar — which is fixed
# by the design (four tabs, left to right).
tap_tab() {
  local wanted="$1" ui coords
  ui=$(dump_ui)
  coords=$(printf '%s' "$ui" | WANT="$wanted" python3 -c '
import os, re, sys
names = ["Home", "Tools"]
want = os.environ["WANT"]
if want not in names:
    sys.exit(0)
xml = sys.stdin.read()
screen = re.search(r"bounds=\"\[0,0\]\[(\d+),(\d+)\]\"", xml)
width = int(screen.group(1)) if screen else 0
height = int(screen.group(2)) if screen else 0
if not width or not height:
    sys.exit(0)
# The bar is split into equal segments, so the tab centre is geometry, not a lookup: the
# *selected* tab is reported with clickable=false, so counting clickable nodes cannot tell
# which one is which (and the label nodes have empty frames).
y = None
for m in re.finditer(
    r"clickable=\"true\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", xml
):
    x1, y1, x2, y2 = (int(m.group(i)) for i in (1, 2, 3, 4))
    if y2 > y1 and y1 > height * 0.8 and x2 > x1:
        y = (y1 + y2) // 2
        break
if y is None:
    y = int(height * 0.92)
idx = names.index(want)
print(int((idx + 0.5) * width / len(names)), y)
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
# Sample repeatedly: on y6 the first frame takes ~5 s (splash included), so a single sample
# at 2 s saw neither the app nor its checking state and failed a working cold start.
early=""
saw_app=0
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  early=$(dump_ui)
  if on_screen "$early" 'Droid AI'; then
    saw_app=1
    break
  fi
done

if on_screen "$early" 'allow-external-apps'; then
  bad "cold start showed the allow-external-apps instructions while still probing"
else
  ok "cold start does not blame allow-external-apps while probing"
fi

if on_screen "$early" 'Checking your device'; then
  ok "cold start shows a neutral checking state"
elif [ "$saw_app" -eq 1 ]; then
  ok "cold start reached a real screen (checking state or Home)"
else
  bad "cold start showed neither a checking state nor the Overview"
fi

# --- 2. a successful probe reaches Home --------------------------------------

say "2. ready state"
ready=0
for _ in $(seq 1 20); do
  sleep 2
  ui=$(dump_ui)
  # Home is one sentence and one button now (F3): the device table, the service pills and
  # raw output moved to Settings → Advanced. Reaching it means the payload arrived, because
  # the sentence is derived from the snapshot.
  if on_screen "$ui" 'Home' &&
     { on_screen "$ui" 'tool running' || on_screen "$ui" 'tools running' ||
       on_screen "$ui" 'Nothing installed yet' || on_screen "$ui" 'Nothing is running' ||
       on_screen "$ui" 'Something needs attention'; }; then
    ready=1
    break
  fi
  if on_screen "$ui" 'allow-external-apps'; then
    break
  fi
done

if [ "$ready" -eq 1 ]; then
  ok "reached Home after the probe"
else
  bad "did not reach Home (device not set up, or the probe never answered)"
  if on_screen "$(dump_ui)" 'allow-external-apps'; then
    say "        the app is showing its one-time setup screen; finish it by hand, then re-run"
  fi
fi

# --- 3. Back on the Raw Output sub-screen must not quit -----------------------

say "3. back navigation (raw output is behind Settings -> Advanced)"
if [ "$ready" -eq 1 ]; then
  opened=0
  if tap_desc "Settings"; then
    sleep 2
    if scroll_to "Open Advanced" && tap_text "Open Advanced"; then
      sleep 2
      if scroll_to "Open raw output"; then
        # Two attempts: the page can still be settling (the reboot block and the cleanup size
        # both trigger a refresh on open), and a tap that lands mid-layout hits nothing.
        opened_raw=0
        for _ in 1 2; do
          tap_text "Open raw output" || true
          for _ in 1 2 3 4; do
            sleep 1
            if on_screen "$(dump_ui)" 'Raw Output'; then
              opened_raw=1
              break
            fi
          done
          [ "$opened_raw" -eq 1 ] && break
        done
        if [ "$opened_raw" -eq 1 ]; then
          opened=1
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
      fi
    fi
  fi
  if [ "$opened" -eq 0 ]; then
    bad "could not reach Raw Output through Settings -> Advanced"
  fi
  # Back to Home for the remaining checks. Popped one level at a time and checked, because the
  # number of levels depends on where §3 left the app and one Back too many exits it.
  for _ in 1 2 3 4; do
    ui=$(dump_ui)
    if on_screen "$ui" 'Home' && ! on_screen "$ui" 'Advanced' && ! on_screen "$ui" 'Raw Output'; then
      break
    fi
    adb_cmd shell input keyevent KEYCODE_BACK >/dev/null 2>&1
    sleep 1
  done
  if ! resumed_activity | grep -q "$PKG"; then
    adb_cmd shell am start -n "$ACTIVITY" >/dev/null 2>&1
    sleep 8
  fi
else
  say "  SKIP  back navigation (not on Home)"
fi

# --- 4. the tab must survive a rotation ---------------------------------------

say "4. rotation keeps the tab"
if [ "$ready" -eq 1 ]; then
  tap_tab "Tools" || bad "could not find the Tools tab"
  sleep 2
  adb_cmd shell settings put system accelerometer_rotation 0 >/dev/null 2>&1
  adb_cmd shell settings put system user_rotation 1 >/dev/null 2>&1
  # A tab label is on every screen, so asserting 'Packages' passed even when the tap never
  # landed. The tool cards are only on Tools, and the status sentence only on Home.
  # Polled, because a rotation recreates the activity and the first dump can catch it mid-draw.
  kept=0
  for _ in 1 2 3 4; do
    sleep 2
    rot=$(dump_ui)
    # Tools shows an installed count ("3 of 8 installed"); Home shows one sentence, and the
    # exclusions matter because Home's empty state also contains the word "installed". Group
    # headers are not usable here: in landscape the "Not installed" group is below the fold.
    if on_screen "$rot" 'installed' &&
      ! on_screen "$rot" 'Nothing installed yet' &&
      ! on_screen "$rot" 'Nothing is running' &&
      ! on_screen "$rot" 'tool running' &&
      ! on_screen "$rot" 'tools running'; then
      kept=1
      break
    fi
  done
  if [ "$kept" -eq 1 ]; then
    ok "rotation kept the user on Tools"
  else
    bad "rotation reset the screen"
  fi
  adb_cmd shell settings put system user_rotation 0 >/dev/null 2>&1
  adb_cmd shell settings put system accelerometer_rotation 1 >/dev/null 2>&1
  sleep 2
else
  say "  SKIP  rotation (not on Home)"
fi

# --- 5. large font must still render Settings ---------------------------------

say "5. large font"
if [ "$ready" -eq 1 ]; then
  adb_cmd shell settings put system font_scale 1.3 >/dev/null 2>&1
  adb_cmd shell am force-stop "$PKG" >/dev/null 2>&1
  adb_cmd shell am start -n "$ACTIVITY" >/dev/null 2>&1
  sleep 18
  if ! tap_desc "Settings"; then
    bad "could not find the Settings gear at font scale 1.3"
  fi
  sleep 2
  # Assert on a fact near the top of Settings: at 1.3x the Termux panel scrolls below
  # the fold, and uiautomator dumps only what is on screen.
  ui=$(dump_ui)
  if on_screen "$ui" 'Appearance' && on_screen "$ui" 'Version'; then
    ok "Settings renders at font scale 1.3"
  else
    bad "Settings did not render at font scale 1.3"
  fi

  # F3.3: the Termux & Safety facts must be one line each at 1.3, not a paragraph. A single
  # line of bodySmall at 1.3 is ~19 dp; two lines are ~38 dp, so 28 dp separates them on any
  # density. The panel sits below the fold, hence the scroll.
  for _ in 1 2 3; do
    adb_cmd shell input swipe 360 1200 360 500 200 >/dev/null 2>&1
  done
  sleep 1
  # `wm density` prints more than one line on some devices ("Physical density: 480" /
  # "Override density: 480"); squashing every digit together produced a budget of 84056 px on
  # 8x, which passes any wrapping. Take the first number only.
  density=$(adb_cmd shell wm density 2>/dev/null | sed -n 's/[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1)
  budget=$(( 28 * ${density:-320} / 160 ))
  # A row clipped by the top of the scroll viewport reports a sliver of its height, which would
  # pass the budget for the wrong reason. Nudge until the label is fully on screen.
  minh=$(( 18 * ${density:-320} / 160 ))
  attempt=0
  ui=$(dump_ui)
  while :; do
    h=$(node_height "$ui" "Access")
    if [ -n "$h" ] && [ "$h" -ge "$minh" ]; then
      break
    fi
    [ "$attempt" -ge 4 ] && break
    adb_cmd shell input swipe 360 700 360 900 200 >/dev/null 2>&1
    sleep 1
    attempt=$((attempt + 1))
    ui=$(dump_ui)
  done
  for label in Access Version; do
    h=$(node_height "$ui" "$label")
    if [ -z "$h" ]; then
      bad "could not find the '$label' fact row at font scale 1.3"
    elif [ "$h" -le "$budget" ]; then
      ok "'$label' fact is one line at font scale 1.3 (${h}px <= ${budget}px)"
    else
      bad "'$label' fact wrapped at font scale 1.3 (${h}px > ${budget}px)"
    fi
  done

  adb_cmd shell settings put system font_scale "$original_font_scale" >/dev/null 2>&1
else
  say "  SKIP  large font (not on Home)"
fi

# --- summary -----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

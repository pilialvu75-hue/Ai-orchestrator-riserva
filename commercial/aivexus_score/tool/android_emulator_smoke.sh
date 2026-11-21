#!/usr/bin/env bash
# Isolated Android emulator launch/resume smoke. Never deploys to a real device.
set -euo pipefail
PKG='dev.aivexus.aivexus_score'
ACTIVITY="$PKG/.MainActivity"
APK="$RUNNER_TEMP/aivexus_score/build/app/outputs/flutter-apk/app-release.apk"
test -s "$APK"
adb wait-for-device
adb shell getprop sys.boot_completed | tr -d '\r' | grep -qx '1'
adb install -r "$APK"
adb shell pm path "$PKG" | grep -q '^package:'

launch_and_check() {
  local phase="$1"
  local result
  result="$(adb shell am start -W -n "$ACTIVITY")"
  printf '%s\n' "$result"
  if printf '%s\n' "$result" | grep -q '^Error:'; then
    echo "[SCORE_EMULATOR] $phase=FAIL: activity start error" >&2
    exit 1
  fi
  sleep 9
  if ! adb shell pidof "$PKG" >/dev/null 2>&1; then
    echo "[SCORE_EMULATOR] $phase=FAIL: process not running" >&2
    exit 1
  fi
  if ! adb shell dumpsys activity activities | grep -Fq "$PKG"; then
    echo "[SCORE_EMULATOR] $phase=FAIL: activity not visible to activity manager" >&2
    exit 1
  fi
  if adb logcat -d -b crash | grep -Fq "$PKG"; then
    echo "[SCORE_EMULATOR] $phase=FAIL: package appears in crash buffer" >&2
    exit 1
  fi
  echo "[SCORE_EMULATOR] $phase=PASS"
}
adb logcat -c
launch_and_check cold
adb exec-out screencap -p > "$RUNNER_TEMP/aivexus-score-emulator.png"
test -s "$RUNNER_TEMP/aivexus-score-emulator.png"
adb shell input keyevent KEYCODE_HOME
sleep 1
launch_and_check resume
adb shell am force-stop "$PKG"
launch_and_check force-stop-restart
echo '[SCORE_EMULATOR] smoke PASS (launch/resume/restart only; physical UX pending)'

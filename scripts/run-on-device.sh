#!/usr/bin/env bash
# Build the app and run it on YOUR Android device (this workspace's own device).
set -euo pipefail
DEV="dev-${DEVWORKSPACE_ID:-${DEVWORKSPACE_NAME:-android}}"   # this workspace's device adb Service (unique per workspace)
# Run from the app dir (where pubspec.yaml is)
[ -f pubspec.yaml ] || { [ -d app ] && cd app; }
[ -f pubspec.yaml ] || { echo "No Flutter project here (pubspec.yaml not found)."; exit 1; }

echo ">> building the APK (first build downloads Gradle; be patient)"
flutter build apk --debug

echo ">> connecting to your device ($DEV)"
# `adb connect` exits 0 even when the host is unreachable, and `wait-for-device`
# has NO default timeout — so bound it: on the common "VM still booting"
# case we want the friendly message below, not an indefinite hang.
adb connect "$DEV:5555" >/dev/null 2>&1 || true
if ! timeout 120 adb -s "$DEV:5555" wait-for-device 2>/dev/null; then
  echo "Your device isn't reachable yet (adb timed out after 120s). Run 'device-status' to check it, or 'device-provision' if it's missing."; exit 1
fi
# adb is up before Android has finished booting; installing too early fails. Wait
# for sys.boot_completed=1 (same signal device-status.sh reports), bounded.
echo ">> waiting for Android to finish booting…"
booted=
for _ in $(seq 1 60); do
  [ "$(adb -s "$DEV:5555" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && { booted=1; break; }
  sleep 3
done
[ -n "$booted" ] || { echo "Device connected but Android hasn't finished booting (waited 3m). Try again shortly — 'device-status' shows boot state."; exit 1; }

echo ">> installing + launching"
APK="build/app/outputs/flutter-apk/app-debug.apk"
adb -s "$DEV:5555" install -r "$APK"

# Detect the applicationId from the Kotlin DSL (android/app/build.gradle.kts,
# `applicationId = "..."`), then fall back to reading the package straight from
# the just-built APK with aapt. The project ships only the .kts
# build file, so there's no Groovy fallback. We do NOT fall back to a hardcoded
# package: launching a package that isn't installed would print ">> launched"
# for a no-op, so a detection miss is a hard error instead.
PKG=""
if [ -f android/app/build.gradle.kts ]; then
  PKG=$(sed -n 's/.*applicationId[[:space:]]*=*[[:space:]]*"\([^"]*\)".*/\1/p' android/app/build.gradle.kts | head -1)
fi
if [ -z "$PKG" ] && command -v aapt >/dev/null 2>&1; then
  PKG=$(aapt dump badging "$APK" 2>/dev/null | sed -n "s/.*package: name='\([^']*\)'.*/\1/p" | head -1)
fi
if [ -z "$PKG" ]; then
  echo "Could not determine the app's package (applicationId). Tried android/app/build.gradle.kts and 'aapt dump badging $APK'." >&2
  echo "aapt should always succeed on the just-built APK — check that build-tools are on PATH and the APK built." >&2
  exit 1
fi

echo ">> launching $PKG"
# Launch via `am start` on the app's resolved LAUNCHER activity. We used to use
# `monkey -p ... -c LAUNCHER 1`, but on redroid monkey frequently exits non-zero
# WITHOUT actually starting the app (it warns "SYS_KEYS has no physical keys" and
# bails), so the launch silently failed while the script reported an error. Resolving
# the launcher activity and using `am start -n` is deterministic on redroid.
ACT=$(adb -s "$DEV:5555" shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$PKG" 2>/dev/null | tr -d '\r' | tail -1)
case "$ACT" in
  */*) : ;;   # looks like "package/.Activity"
  *) echo "Could not resolve a LAUNCHER activity for '$PKG' (is it installed with a launcher intent?)." >&2; exit 1 ;;
esac
if ! adb -s "$DEV:5555" shell am start -n "$ACT" >/dev/null 2>&1; then
  echo "Launch failed for '$ACT' (is '$PKG' installed? did the build/install step succeed?)." >&2
  exit 1
fi
# Confirm it actually came up (am start can return 0 even if the activity died on start).
sleep 2
if adb -s "$DEV:5555" shell pidof "$PKG" >/dev/null 2>&1; then
  echo ">> launched on your device ($ACT)."
else
  echo ">> started $ACT but no running process yet — run 'device status' to check." >&2
fi
# Surface the live-screen URL right here, so you don't have to run open-screen.sh separately.
SCR="scr-${DEVWORKSPACE_ID:-${DEVWORKSPACE_NAME:-android}}"
NS="${DEVWORKSPACE_NAMESPACE:-$(oc project -q 2>/dev/null)}"
URL=$(oc get route "$SCR" -n "$NS" -o jsonpath='https://{.spec.host}' 2>/dev/null)
if [ -n "$URL" ]; then
  echo ">> Watch it on the live device screen:  $URL"
  echo "   (log in with OpenShift, then pick Broadway.js [Firefox] or WebCodecs [Chrome/Edge])"
else
  echo ">> Open the live device screen with:  device screen"
fi

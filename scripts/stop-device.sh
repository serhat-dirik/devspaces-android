#!/usr/bin/env bash
# Stop (halt) YOUR Android device WITHOUT deleting it — keeps the disk so the next
# wake is fast. Wired to the devfile preStop event, so when Dev Spaces puts your
# workspace to sleep, the device VM is halted AND the ws-scrcpy screen is scaled to
# 0 (both free CPU/RAM). postStart's provision-device.sh starts both again on wake.
set -uo pipefail
DEV="dev-${DEVWORKSPACE_ID:-${DEVWORKSPACE_NAME:-android}}"
SCR="scr-${DEVWORKSPACE_ID:-${DEVWORKSPACE_NAME:-android}}"
echo "Workspace stopping — halting device $DEV + stopping its screen to free cluster resources…"
oc patch vm "$DEV" --type merge -p '{"spec":{"runStrategy":"Halted"}}' >/dev/null 2>&1 \
  && echo "Device halted (disk kept; it'll start again when you reopen the workspace)." \
  || echo "No device to halt (already gone)."
# The ws-scrcpy screen is a separate Deployment — it kept running while the workspace
# slept (wasting the ws-scrcpy + oauth-proxy pods). Scale it to 0; provision-device.sh's
# apply restores replicas:1 on wake.
oc scale deploy "$SCR" --replicas=0 >/dev/null 2>&1 \
  && echo "Screen stopped (it restarts when you reopen the workspace)." || true

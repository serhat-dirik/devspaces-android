#!/usr/bin/env bash
# Restart YOUR Android device (recover a frozen or slept device). Keeps the disk.
set -uo pipefail
WSID="${DEVWORKSPACE_ID:-${DEVWORKSPACE_NAME:-android}}"; DEV="dev-${WSID}"
NS="${DEVWORKSPACE_NAMESPACE:-$(oc project -q 2>/dev/null)}"
[ -n "$NS" ] || { echo "Cannot determine namespace." >&2; exit 1; }

# the previous version only did `oc delete vmi` — but after the normal
# sleep/wake lifecycle stop-device.sh sets runStrategy=Halted, so there's NO vmi
# to delete and the device never comes back. So FIRST make sure the VM is set to
# run again, then force a fresh boot.
echo "Restarting your Android device ($DEV)…"
if ! oc get vm "$DEV" -n "$NS" >/dev/null 2>&1; then
  echo "No device '$DEV' yet — run 'device start' first." ; exit 1
fi
oc patch vm "$DEV" -n "$NS" --type merge -p '{"spec":{"runStrategy":"Always"}}' >/dev/null
# Delete the running instance (if any) so it boots fresh; Always re-creates it.
oc delete vmi "$DEV" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
echo "Rebooting — check 'device-status' in a couple of minutes."

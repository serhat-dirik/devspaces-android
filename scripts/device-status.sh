#!/usr/bin/env bash
# Show the state of YOUR Android device (this workspace's own device).
set -uo pipefail
WS="${DEVWORKSPACE_NAME:-android}"; WSID="${DEVWORKSPACE_ID:-$WS}"; DEV="dev-${WSID}"; SCR="scr-${WSID}"
NS="${DEVWORKSPACE_NAMESPACE:-$(oc project -q 2>/dev/null)}"   # explicit ns
[ -n "$NS" ] || { echo "Cannot determine namespace." >&2; exit 1; }
STATUS_FILE="${DEVICE_PROVISION_STATUS_FILE:-/tmp/device-provision.status}"
echo "Workspace: $WS"
echo "Namespace: $NS"
# Surface the last provisioning result (provision-device.sh writes this file).
if [ -f "$STATUS_FILE" ]; then
  prov="$(cat "$STATUS_FILE" 2>/dev/null)"
  case "$prov" in
    FAILED) echo "provision: FAILED — last 'device start' run did not complete. See /tmp/device-provision.log." ;;
    DONE)   echo "provision: ok" ;;
    *)      echo "provision: ${prov:-unknown}" ;;
  esac
fi
vmstate="$(oc get vm "$DEV" -n "$NS" -o jsonpath='{.status.printableStatus}' 2>/dev/null)"
echo "VM:        ${vmstate:-not provisioned — run 'device start'}"
adb connect "$DEV:5555" >/dev/null 2>&1
adbstate="$(adb -s "$DEV:5555" get-state 2>/dev/null || echo disconnected)"
echo "adb:       $adbstate"
booted="$(adb -s "$DEV:5555" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
if [ "$booted" = "1" ]; then echo "booted:    yes"; else echo "booted:    not yet"; fi
url=$(oc get route "$SCR" -n "$NS" -o jsonpath='https://{.spec.host}' 2>/dev/null)
echo "screen:    ${url:-not deployed}"
# VM up but Android not reachable yet -> that's a boot in progress, not a failure.
# Say so, or "adb: disconnected" reads like something broke.
if [ "$vmstate" = "Running" ] && [ "$booted" != "1" ]; then
  echo
  echo "⏳ VM is up but Android is still starting inside it — normal after 'device start'"
  echo "   (first-ever start: several minutes while the guest sets up; wakes: ~1–2 min)."
  echo "   Follow it live with 'device watch'."
fi

#!/usr/bin/env bash
# Remove YOUR Android device + screen (frees cluster resources). Re-create any
# time with provision-device.sh. Scoped by label to THIS workspace's device only.
set -uo pipefail
WS="${DEVWORKSPACE_NAME:-android}"; WSID="${DEVWORKSPACE_ID:-$WS}"; DEV="dev-${WSID}"
NS="${DEVWORKSPACE_NAMESPACE:-$(oc project -q 2>/dev/null)}"
[ -n "$NS" ] || { echo "Cannot determine namespace." >&2; exit 1; }
echo "Removing device for workspace '$WS' in namespace: $NS"
# Includes the screen's oauth-proxy SA/Secret/serving-cert and the per-workspace
# NetworkPolicies — all label-scoped to this workspace.
oc delete deploy,svc,route,vm,serviceaccount,secret,networkpolicy \
  -l "android.workspace=${WSID}" -n "$NS" --ignore-not-found
oc delete dv "${DEV}-disk" -n "$NS" --ignore-not-found
echo "Removed."

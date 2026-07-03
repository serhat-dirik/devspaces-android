#!/usr/bin/env bash
# Print the URL of YOUR device's live screen (open it in a browser tab).
set -uo pipefail
SCR="scr-${DEVWORKSPACE_ID:-${DEVWORKSPACE_NAME:-android}}"
NS="${DEVWORKSPACE_NAMESPACE:-$(oc project -q 2>/dev/null)}"   # explicit ns
url=$(oc get route "$SCR" -n "$NS" -o jsonpath='https://{.spec.host}' 2>/dev/null)
if [ -n "$url" ]; then
  echo "Your device screen: $url"
  echo "  1. Log in with your OpenShift account when prompted."
  echo "  2. On the device row, pick a video decoder to open the screen:"
  echo "       - WebCodecs   (best quality; Chrome / Edge)"
  echo "       - Broadway.js (works in Firefox and everywhere else)"
  echo "  3. Screen too small? Use the device's  ⋮  menu -> Video Settings -> set the"
  echo "     bounds (e.g. 832x832) and Apply."
else
  echo "Screen not deployed yet — run 'device start' first."
fi

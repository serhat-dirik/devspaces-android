#!/usr/bin/env bash
# Register the sample app in the OpenShift Dev Spaces dashboard catalog.
# It then appears under "Create Workspace" and opens the app's devfile.
#
#   export REPO_URL=https://github.com/<your-org>/<flutter-app-repo>
#   ./samples/register-sample.sh
#
# The app repo must be reachable at a URL Che can fetch: push `devspaces-android-sample-app`
# to your git host first (or use the self-hosted devfile-server path below).
#
# This points the catalog straight at the app repo — the right approach when the
# repo is on a git host Che recognizes (GitHub/GitLab/Bitbucket): Che fetches the
# devfile from the provider's valid raw URL. NO devfile server is needed; the
# platform then has no permanent runtime deployment of its own.
#
# Self-hosted / unrecognized git (e.g. the temporary in-cluster Gitea)? Che can't
# fetch the devfile there (it guesses a raw.<host> URL the wildcard cert doesn't
# cover). In that case serve the devfile instead:
#   oc apply -f samples/devfile-server.yaml -n devspace-android-demo
#   # use samples/served-devfile.yaml — set your repo URL in its projects: clause:
#   oc create configmap mobile-workspace-devfile -n devspace-android-demo \
#     --from-file=devfile.yaml=samples/served-devfile.yaml
#   # then set REPO_URL below to the served URL:
#   #   https://<mobile-workspace-devfile route host>/devfile.yaml   (no devfilePath)
#
# Optional:
#   DEVSPACES_NS=openshift-devspaces   # Dev Spaces namespace (default)
#   DEVFILE=devfile.yaml               # which devfile in the repo the sample opens
set -euo pipefail
: "${REPO_URL:?set REPO_URL, e.g. https://github.com/<your-org>/<flutter-app-repo>}"
NS="${DEVSPACES_NS:-openshift-devspaces}"
DEVFILE="${DEVFILE:-devfile.yaml}"

# icon (base64 PNG) sits next to this script
ICON="$(cat "$(dirname "$0")/icon.b64")"

oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: getting-started-samples-android
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: che.eclipse.org
    app.kubernetes.io/component: getting-started-samples
data:
  android.json: |
    [
      {
        "displayName": "Mobile Dev (Flutter+Android VM)",
        "description": "A Flutter app. Build and run it on your own on-cluster Android device — provisioned automatically with your workspace.",
        "tags": ["Android", "Flutter", "Mobile"],
        "url": "${REPO_URL}?devfilePath=${DEVFILE}",
        "icon": { "base64data": "${ICON}", "mediatype": "image/png" }
      }
    ]
EOF

echo
echo "Registered in namespace '${NS}'."
echo "Open the Dev Spaces dashboard -> Create Workspace -> the sample"
echo "'Mobile Dev (Flutter+Android VM)' appears in the samples list (refresh if needed)."

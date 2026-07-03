#!/usr/bin/env bash
# Build the developer workspace image ON OpenShift and wire the Dev Spaces
# devfile to it. No local podman, no external registry. Run after `oc login`.
#
#   ./openshift/build-and-deploy.sh
#
# Optional env:
#   BUILD_NS   namespace to build in           (default: devspace-android-demo)
#   WS_NS      Dev Spaces workspace namespace   (default: <user>-devspaces)
#   ASSUME_YES set to 1 to auto-answer the Dev Spaces install prompt
set -euo pipefail

IMAGE=mobile-allinone
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

step(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
die(){  printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Dev Spaces is required to open the workspace. If it's missing, ask before
# installing — it's a cluster-scoped change (operator + openshift-devspaces ns).
ensure_devspaces(){
  DS_CSVS="$(oc get csv -A 2>/dev/null)"
  if grep -iq devspaces <<<"$DS_CSVS"; then
    ok "Dev Spaces operator already installed"; return 0
  fi
  warn "Dev Spaces operator is NOT installed (needed to open the workspace)."
  if [ "${ASSUME_YES:-0}" = 1 ]; then
    ans=y
  else
    read -r -p "  Install Dev Spaces now? It's cluster-wide. (y/n) " ans
  fi
  case "$ans" in
    y|Y|yes) ;;
    *) die "Dev Spaces not installed — stopping at your request.";;
  esac
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: devspaces
  namespace: openshift-operators
spec:
  channel: stable
  name: devspaces
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
YAML
  printf '  waiting for the operator to reach Succeeded'
  for _ in $(seq 1 40); do
    DS_CSVS="$(oc get csv -A 2>/dev/null)"
    grep -i devspaces <<<"$DS_CSVS" | grep -q Succeeded && { echo; ok "operator Succeeded"; break; }
    printf '.'; sleep 15
  done
  if [ -z "$(oc get checluster -A -o name 2>/dev/null)" ]; then
    oc get ns openshift-devspaces >/dev/null 2>&1 || oc create namespace openshift-devspaces >/dev/null
    oc apply -n openshift-devspaces -f - <<'YAML'
apiVersion: org.eclipse.che/v2
kind: CheCluster
metadata:
  name: devspaces
spec:
  components: {}
  devEnvironments:
    defaultNamespace:
      template: <username>-devspaces
    # Keep in lockstep with preflight.sh: the built-in edit role is what lets a
    # developer provision their device VM; per-workspace storage keeps one
    # workspace's Gradle cache from starving another's.
    user:
      clusterRoles:
        - edit
    storage:
      pvcStrategy: per-workspace
      perWorkspaceStrategyPvcConfig:
        claimSize: 15Gi
YAML
    ok "CheCluster submitted (takes a few minutes to come up)"
  fi
}

# ---- 0. preconditions ----
command -v oc >/dev/null || die "oc not found in PATH"
oc whoami >/dev/null 2>&1 || die "not logged in — run: oc login <api-url>"
ok "logged in as $(oc whoami) @ $(oc whoami --show-server)"

BUILD_NS="${BUILD_NS:-devspace-android-demo}"
USER_SAFE="$(oc whoami | tr -cd 'a-z0-9-')"
WS_NS="${WS_NS:-${USER_SAFE}-devspaces}"
INTERNAL_REG="image-registry.openshift-image-registry.svc:5000"
IMAGE_REF="${INTERNAL_REG}/${BUILD_NS}/${IMAGE}:latest"
ok "build namespace : ${BUILD_NS}"
ok "workspace ns    : ${WS_NS}"
ok "image ref       : ${IMAGE_REF}"

# ---- 1. dedicated namespace + Dev Spaces readiness ----
step "Namespace + Dev Spaces readiness"
if ! oc get ns "$BUILD_NS" >/dev/null 2>&1; then
  oc create namespace "$BUILD_NS" >/dev/null
  oc label namespace "$BUILD_NS" purpose=devspace-android-demo --overwrite >/dev/null
  ok "created dedicated namespace ${BUILD_NS}"
else
  ok "namespace ${BUILD_NS} exists"
fi
ensure_devspaces

# ---- 2. ImageStream + BuildConfig ----
step "Apply ImageStream + BuildConfig"
oc apply -n "$BUILD_NS" -f "openshift/imagestream.yaml"
oc apply -n "$BUILD_NS" -f "openshift/buildconfig.yaml"
ok "applied"

# ---- 3. binary build from local files (uploads context, streams logs) ----
step "Start build from local files (this is slow on first run)"
oc start-build "${IMAGE}" --from-dir=. --follow -n "$BUILD_NS"

# ---- 4. verify the image landed ----
step "Verify image"
oc get istag "${IMAGE}:latest" -n "$BUILD_NS" >/dev/null \
  && ok "image present: ${IMAGE_REF}" \
  || die "image tag not found after build"

# ---- 5. platform RBAC (two built-in-role bindings, applied once) ----
# No custom roles and no per-developer-namespace step. Developer permissions come
# from Dev Spaces itself: the CheCluster sets user.clusterRoles: ["edit"] (see
# preflight.sh), so Che binds the BUILT-IN edit role — which KubeVirt/CDI aggregate
# into — to each developer in every namespace it provisions. This file only adds
# the screen's auth-delegator + the shared-image puller (both built-in roles).
step "Apply platform RBAC"
oc apply -f openshift/platform-rbac.yaml >/dev/null
ok "applied auth-delegator + image-puller bindings (built-in roles only)"

step "Done"
cat <<EOF
  Workspace image : ${IMAGE_REF}

  Next (one-time platform setup):
    1. Build the device-screen (ws-scrcpy) image:
         oc apply -f openshift/screen/buildconfig.yaml -n ${BUILD_NS}
         oc start-build ws-scrcpy -n ${BUILD_NS}
    2. Register the app in the catalog (point REPO_URL at your Flutter app repo):
         export REPO_URL=https://github.com/serhat-dirik/devspaces-android-sample-app
         ./samples/register-sample.sh

  No custom roles, no per-namespace RBAC step: Dev Spaces itself grants each
  developer the built-in 'edit' role in their namespace (CheCluster
  user.clusterRoles — see preflight.sh). Developers just open the app from the
  dashboard and manage their device with the 'device' command (device start /
  stop / remove); deleting the workspace removes the device automatically.
EOF

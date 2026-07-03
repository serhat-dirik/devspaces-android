#!/usr/bin/env bash
# Cluster readiness check & preparation for the Android Dev Spaces workspace.
#
#   ./preflight.sh            # checks only (read-only)  [default]
#   ./preflight.sh check      # same
#   ./preflight.sh prepare    # checks, then installs Dev Spaces if missing (needs admin)
#
# Checks: logged in? cluster-admin? KVM ready (OpenShift Virtualization +
# a node advertising /dev/kvm)? Dev Spaces present?
set -uo pipefail
MODE="${1:-check}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
hd()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- 0. oc available + logged in ----
hd "Connection"
have oc || { err "oc CLI not found in PATH"; exit 1; }
if ! oc whoami >/dev/null 2>&1; then err "not logged in — run: oc login <api-url>"; exit 1; fi
ok "logged in as $(oc whoami) @ $(oc whoami --show-server 2>/dev/null)"

# ---- 1. cluster-admin? ----
hd "Permissions"
if oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
  ADMIN=yes; ok "cluster-admin: yes"
else
  ADMIN=no;  warn "cluster-admin: NO — operator installs need admin"
fi

# ---- 2. KVM readiness ----
hd "KVM / virtualization"
# Probe the CRDs, not the CSV list: deterministic (a `... | grep -q` pipe under
# `set -o pipefail` false-negatives when grep matches early and the left side
# exits 141 on SIGPIPE), and the CRDs are what the platform actually needs.
VIRT_OK=no
if oc get crd virtualmachines.kubevirt.io >/dev/null 2>&1 \
   && oc get crd datavolumes.cdi.kubevirt.io >/dev/null 2>&1; then
  VIRT_OK=yes; ok "OpenShift Virtualization installed (KubeVirt + CDI CRDs present)"
else
  warn "OpenShift Virtualization not detected (provides the KVM device plugin) — see the README"
fi
KVM_NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.devices\.kubevirt\.io/kvm}{"\n"}{end}' 2>/dev/null | awk -F'\t' '$2!=""{print $1" (kvm="$2")"}')
if [ -n "$KVM_NODES" ]; then
  ok "nodes advertising /dev/kvm:"; echo "$KVM_NODES" | sed 's/^/      /'
else
  warn "no node advertises devices.kubevirt.io/kvm — the redroid device VM will be slow or unschedulable"
fi
ok "no node label needed — KubeVirt schedules device VMs onto KVM-capable nodes automatically"

# ---- 3. Dev Spaces ----
hd "OpenShift Dev Spaces"
DS_PRESENT=no
DS_CSVS="$(oc get csv -A 2>/dev/null)"; DS_SUBS="$(oc get subscription -A 2>/dev/null)"
if grep -iq devspaces <<<"$DS_CSVS" || grep -iq devspaces <<<"$DS_SUBS"; then
  DS_PRESENT=yes; ok "Dev Spaces operator installed"
else
  warn "Dev Spaces operator NOT installed"
fi
CHE_URL=$(oc get checluster -A -o jsonpath='{.items[0].status.cheURL}' 2>/dev/null)
if [ -n "$CHE_URL" ]; then ok "Dev Spaces URL: $CHE_URL"; else warn "no running Dev Spaces instance (CheCluster) found"; fi

# ---- prepare ----
if [ "$MODE" = prepare ]; then
  hd "Prepare"
  if [ "$ADMIN" != yes ]; then err "prepare needs cluster-admin"; exit 1; fi

  if [ "$DS_PRESENT" != yes ]; then
    echo "  installing the Dev Spaces operator..."
    oc apply -f - <<'EOF'
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
EOF
    echo -n "  waiting for the operator to be ready"
    for _ in $(seq 1 20); do
      OP_CSVS="$(oc get csv -n openshift-operators 2>/dev/null)"
      if grep -i devspaces <<<"$OP_CSVS" | grep -q Succeeded; then echo; ok "operator ready"; DS_PRESENT=yes; break; fi
      echo -n "."; sleep 15
    done
    [ "$DS_PRESENT" = yes ] || { echo; warn "operator not Succeeded yet — re-run './preflight.sh check' shortly"; }
  else
    ok "Dev Spaces operator already present"
  fi

  if [ -z "$CHE_URL" ] && [ "$DS_PRESENT" = yes ]; then
    echo "  creating a Dev Spaces instance (CheCluster) in openshift-devspaces..."
    oc create namespace openshift-devspaces 2>/dev/null || true
    oc apply -n openshift-devspaces -f - <<'EOF'
apiVersion: org.eclipse.che/v2
kind: CheCluster
metadata:
  name: devspaces
spec:
  components: {}
  devEnvironments:
    defaultNamespace:
      template: <username>-devspaces
    # Grant each developer the BUILT-IN `edit` role in their own namespace — Dev
    # Spaces' native mechanism (it creates the binding automatically in every
    # namespace it provisions, now and in the future). With OpenShift Virtualization
    # installed, KubeVirt/CDI aggregate into `edit`, so this alone lets a developer
    # provision their device VM: no custom role, no per-namespace admin step.
    user:
      clusterRoles:
        - edit
    # Per-WORKSPACE storage: each workspace gets its OWN PVC, so one workspace's
    # Gradle/build cache can't starve another's. The Dev Spaces default (per-user)
    # shares ONE PVC across all a developer's workspaces — and Flutter/Android builds
    # are disk-heavy (~3Gi Gradle cache each), so a shared 10Gi fills fast and builds
    # fail with "No space left on device". 15Gi per workspace is comfortable headroom.
    storage:
      pvcStrategy: per-workspace
      perWorkspaceStrategyPvcConfig:
        claimSize: 15Gi
EOF
    ok "CheCluster submitted"
  fi

  # Wait for the instance to actually come up — deploying it is not the same as
  # it being usable, and the next steps assume a live dashboard.
  if [ -z "$CHE_URL" ] && [ "$DS_PRESENT" = yes ]; then
    echo -n "  waiting for the Dev Spaces instance to come up (several minutes on first install)"
    for _ in $(seq 1 60); do
      CHE_URL=$(oc get checluster -A -o jsonpath='{.items[0].status.cheURL}' 2>/dev/null)
      [ -n "$CHE_URL" ] && { echo; ok "Dev Spaces is up: $CHE_URL"; break; }
      echo -n "."; sleep 15
    done
    [ -n "$CHE_URL" ] || { echo; warn "instance not ready after 15 min — monitor with './preflight.sh check'"; }
  fi

  echo
  echo "  Note: the redroid device VM also needs OpenShift Virtualization installed and at"
  echo "  least one hardware-virtualization (KVM-capable) node. Installing Virtualization is"
  echo "  left explicit (it depends on your node pool) — see the README. No node label is"
  echo "  needed; KubeVirt schedules the VM onto a KVM-capable node automatically."
fi

hd "Done"
if [ "$VIRT_OK" = yes ] && [ -n "$KVM_NODES" ] && [ "$DS_PRESENT" = yes ] && [ -n "$CHE_URL" ]; then
  ok "all green — continue with the README quickstart (next: ./openshift/build-and-deploy.sh)"
else
  echo "  Re-run './preflight.sh check' until every section above is green, then continue with the README quickstart."
fi

#!/usr/bin/env bash
# Pre-bake the device "golden image" so device provisioning is FAST.
#
# Without this step, EVERY first `device start` pays the full network path inside
# the guest: Ubuntu cloud-image import (~90s), apt install docker + kernel
# modules, and a ~1GB redroid pull from Docker Hub (~4-6 min total). This script
# pays that cost ONCE, platform-side:
#
#   1. imports Ubuntu into a DataVolume in the platform namespace,
#   2. boots a throwaway builder VM whose cloud-init installs docker + the binder
#      module config and pre-pulls BOTH redroid images (Android 13 + 12), then
#      powers itself off,
#   3. deletes the builder VM, keeping its disk as `golden-android-disk` — the
#      clone source every device DataVolume snapshots from.
#
# provision-device.sh auto-detects the golden PVC: if present, devices CSI-clone
# it (seconds on Ceph/ODF) and skip apt + docker pull entirely — a brand-new
# device goes from ~10 min to ~2 min. If absent, provisioning falls back to the
# old full-import path, so this step is RECOMMENDED but not required.
#
# Run once per cluster (idempotent — skips if the golden disk already exists):
#   ./openshift/prepare-golden-image.sh
# Rebuild it (new Ubuntu respin / newer redroid):
#   FORCE=1 ./openshift/prepare-golden-image.sh
set -euo pipefail
PLATFORM_NS="${PLATFORM_NS:-devspace-android-demo}"
GOLDEN_DV="golden-android-disk"
BUILDER_VM="golden-android-builder"
# Keep these in lockstep with the DEVICE_PROFILE table in scripts/provision-device.sh.
REDROID_IMAGES=("redroid/redroid:13.0.0_64only-latest" "redroid/redroid:12.0.0_64only-latest")
UBUNTU_IMG="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
UBUNTU_SHA="sha256:070de108b25df4c9eacc4a297c6afc583bdd58cabf159e61d4152bc6541a6b54"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  → %s\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

oc get ns "$PLATFORM_NS" >/dev/null 2>&1 || fail "platform namespace '$PLATFORM_NS' not found"

if oc get pvc "$GOLDEN_DV" -n "$PLATFORM_NS" >/dev/null 2>&1; then
  if [ "${FORCE:-0}" != "1" ]; then
    ok "golden image already prepared ($PLATFORM_NS/$GOLDEN_DV) — nothing to do (FORCE=1 to rebuild)"
    exit 0
  fi
  info "FORCE=1 — removing the existing golden disk"
  oc delete vm "$BUILDER_VM" -n "$PLATFORM_NS" --ignore-not-found
  oc delete datavolume "$GOLDEN_DV" -n "$PLATFORM_NS" --ignore-not-found
  oc delete pvc "$GOLDEN_DV" -n "$PLATFORM_NS" --ignore-not-found
fi

PULL_CMDS=""
for img in "${REDROID_IMAGES[@]}"; do
  PULL_CMDS="${PULL_CMDS}                - 'docker pull ${img}'
"
done

info "creating the golden DataVolume (Ubuntu import) + builder VM — this is the slow, once-per-cluster part"
oc apply -n "$PLATFORM_NS" -f - <<EOF
# Standalone DataVolume (NOT a dataVolumeTemplate) so it SURVIVES the builder VM.
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${GOLDEN_DV}
  labels: { app: devspaces-android, role: golden-image }
  annotations:
    # Don't GC the DataVolume object after import — devices clone via sourceRef to it.
    cdi.kubevirt.io/storage.deleteAfterCompletion: "false"
spec:
  source:
    http: { url: "${UBUNTU_IMG}", checksum: "${UBUNTU_SHA}" }
  storage: { resources: { requests: { storage: 40Gi } } }
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${BUILDER_VM}
  labels: { app: devspaces-android, role: golden-image-builder }
spec:
  # Once: run to completion; the guest powers itself off when baking is done.
  runStrategy: Once
  template:
    metadata:
      labels: { kubevirt.io/domain: ${BUILDER_VM}, app: devspaces-android }
    spec:
      domain:
        cpu: { cores: 2 }
        memory: { guest: 2Gi }
        devices:
          disks:
            - { name: rootdisk, disk: { bus: virtio } }
            - { name: cloudinitdisk, disk: { bus: virtio } }
          interfaces: [ { name: default, masquerade: {} } ]
        resources: { requests: { memory: 2Gi } }
      networks: [ { name: default, pod: {} } ]
      volumes:
        - { name: rootdisk, dataVolume: { name: ${GOLDEN_DV} } }
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |-
              #cloud-config
              package_update: true
              packages: [ca-certificates, curl, docker.io]
              write_files:
                - { path: /etc/modules-load.d/binder.conf, content: "binder_linux\n" }
                - { path: /etc/modprobe.d/binder.conf, content: "options binder_linux devices=binder,hwbinder,vndbinder\n" }
              runcmd:
                - 'KREL=\$(uname -r); DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-modules-extra-\$KREL"'
                - 'systemctl enable --now docker'
${PULL_CMDS}                - 'apt-get clean'
                - 'rm -rf /var/lib/apt/lists/*'
                # Let cloud-init re-run per-device on the clones (each device gets
                # its own hostname + redroid geometry via its own cloud-init).
                - 'cloud-init clean --logs'
                - 'poweroff'
EOF

info "waiting for the bake to finish (Ubuntu import + apt + redroid pulls; typically 8-15 min)…"
for i in $(seq 1 120); do
  vmstate="$(oc get vm "$BUILDER_VM" -n "$PLATFORM_NS" -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)"
  dvphase="$(oc get datavolume "$GOLDEN_DV" -n "$PLATFORM_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  printf '\r\033[K  [%3dm] DataVolume: %-12s VM: %-14s' $((i/4)) "${dvphase:-?}" "${vmstate:-?}"
  if [ "$vmstate" = "Stopped" ]; then
    printf '\n'
    ok "builder VM powered off — bake complete"
    break
  fi
  [ "$i" = "120" ] && { printf '\n'; fail "timed out after 30 min — check: oc logs -n $PLATFORM_NS \$(oc get pods -n $PLATFORM_NS -o name | grep virt-launcher | head -1) -c guest-console-log"; }
  sleep 15
done

info "removing the builder VM (the golden disk stays)"
oc delete vm "$BUILDER_VM" -n "$PLATFORM_NS"
oc get pvc "$GOLDEN_DV" -n "$PLATFORM_NS" >/dev/null 2>&1 || fail "golden PVC vanished with the VM — it must be a standalone DataVolume"
ok "golden image ready: $PLATFORM_NS/$GOLDEN_DV"
echo
echo "  Devices now CSI-clone this disk and skip apt + redroid pulls entirely."
echo "  A brand-new 'device start' should take ~2 min instead of ~10."
echo "  Rebuild after an Ubuntu respin or redroid update:  FORCE=1 $0"

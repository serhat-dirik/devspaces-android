#!/usr/bin/env bash
# Provision (or wake) THIS workspace's own Android device + screen, in this
# workspace's namespace. Idempotent — postStart runs it on every start/wake.
#
# The device is named after the workspace and owner-referenced to the
# DevWorkspace, so deleting the workspace garbage-collects the device. One device
# per workspace, so a developer's multiple workspaces don't collide.
set -uo pipefail
# provisioning names + owner-refs EVERYTHING by the workspace, so an unset
# DEVWORKSPACE_NAME (which would collapse every device onto "dev-android" and break
# per-workspace isolation) is a hard error, not a silent default. Dev Spaces sets
# this in every workspace container; only a misconfigured manual run hits this.
WS="${DEVWORKSPACE_NAME:-}"
[ -n "$WS" ] || { echo "DEVWORKSPACE_NAME is not set — provisioning needs it to name + own this workspace's device. (Run this from inside a Dev Spaces workspace, or export it.)" >&2; exit 1; }
# WSID is the GUARANTEED-UNIQUE per-workspace id (matches how Dev Spaces names the
# workspace deployment). It names the device/screen RESOURCES + the android.workspace
# label, so a developer's multiple workspaces never collide. WS (the human
# DevWorkspace name) is kept ONLY for things that must reference the real
# DevWorkspace resource: the owner-reference, the --openshift-sar, and the workspace
# pod's controller.devfile.io/devworkspace_name label. Falls back to WS if ID unset.
WSID="${DEVWORKSPACE_ID:-$WS}"
NS="${DEVWORKSPACE_NAMESPACE:-$(oc project -q 2>/dev/null)}"
# empty-but-set NS would target the current context (and roll back there).
# set -u doesn't catch empty-but-set, so guard explicitly.
[ -n "$NS" ] || { echo "Cannot determine namespace (set DEVWORKSPACE_NAMESPACE or 'oc project <ns>')." >&2; exit 1; }
DEV="dev-${WSID}"         # device VM + adb Service name (unique per workspace)
SCR="scr-${WSID}"        # screen (ws-scrcpy) name (unique per workspace)
REG="image-registry.openshift-image-registry.svc:5000"
IMG_NS="${PLATFORM_NS:-devspace-android-demo}"

# --- pinned auth-gate images -------------------------------------
# oauth-proxy is THE component enforcing screen authentication, so it must not
# float on :latest. IMPORTANT: Red Hat does NOT publish per-minor vX.Y tags for
# this image (ose-oauth-proxy:v4.20 returns "manifest unknown" -> ImagePullBackOff
# -> the whole screen stays down). It ships by DIGEST. Pinned below to a digest
# this cluster is ALREADY running (so its pull secret is known-good). To bump,
# find the digest the cluster uses and paste it here:
#   oc get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' | grep ose-oauth-proxy | sort -u
# Overridable by env (OAUTH_PROXY_IMG=...).
OAUTH_PROXY_IMG="${OAUTH_PROXY_IMG:-registry.redhat.io/openshift4/ose-oauth-proxy@sha256:1c66b6800cd2c69885a0508b59aacdfb636fafb35044f48bf16dda1f56bef43d}"

# ws-scrcpy (the screen) — pin the CONSUMED reference to the digest of the image
# we build into ${IMG_NS}, so a rebuild/retag of :latest can't change what a live
# workspace pulls without a deliberate bump here. To bump after rebuilding the
# screen image (openshift/screen/buildconfig.yaml → start-build ws-scrcpy):
#   oc get istag ws-scrcpy:latest -n ${IMG_NS} \
#     -o jsonpath='{.image.dockerImageReference}'
# and paste the @sha256:... below. Overridable by env (e.g. to track :latest in dev).
WS_SCRCPY_IMG="${WS_SCRCPY_IMG:-${REG}/${IMG_NS}/ws-scrcpy@sha256:d8a313f52aefbf6dd8c4dc6cfcb2de5980ea688e18ec5fd51460b3b442c92168}"

# this script is idempotent and re-runs on EVERY postStart. Snapshot
# whether the device already exists at entry, BEFORE any apply. If it pre-existed,
# a non-zero apply is a transient re-provision hiccup (API timeout, webhook) on a
# HEALTHY device — we must NOT roll back and destroy the developer's running VM +
# 40Gi disk. We only roll back resources THIS invocation actually created (i.e.
# when the device did not pre-exist).
PREEXISTING_VM="$(oc get vm "$DEV" -n "$NS" --ignore-not-found -o name 2>/dev/null)"

# Provisioning status file — device-status.sh reports FAILED if this says so.
# Start as IN_PROGRESS; flip to DONE only on a clean apply, FAILED on any error.
STATUS_FILE="${DEVICE_PROVISION_STATUS_FILE:-/tmp/device-provision.status}"
# On a FRESH-creation failure, roll back so a half-applied manifest doesn't
# strand an expensive 4Gi VM + 40Gi DataVolume. Best-effort, label-scoped cleanup.
# Set DEVICE_PROVISION_NO_ROLLBACK=1 to keep partial state for debugging.
fail() {
  echo "FAILED" > "$STATUS_FILE"
  echo "Provisioning FAILED: $*" >&2
  if [ -n "$PREEXISTING_VM" ]; then
    echo "Device pre-existed — NOT rolling back (transient re-provision failure; your device is untouched)." >&2
    exit 1
  fi
  if [ "${DEVICE_PROVISION_NO_ROLLBACK:-0}" != "1" ]; then
    echo "Rolling back resources this provision created for workspace '${WS}' in ${NS}…" >&2
    # vm/deploy/svc/route/netpol are unambiguously device resources → label-scoped.
    oc delete vm,deploy,svc,route,netpol \
      -l "android.workspace=${WSID}" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
    # Secrets/ServiceAccounts/DataVolume by EXPLICIT name — a label-wide
    # delete of secret/sa could sweep an app Secret a developer later labels.
    oc delete secret "${SCR}-oauth" "${SCR}-tls" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
    oc delete serviceaccount "${SCR}" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
    oc delete dv "${DEV}-disk" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
  fi
  exit 1
}
echo "IN_PROGRESS" > "$STATUS_FILE"

# --- Device profile ---------------------------------------------------------
# Pick the redroid image + screen geometry from DEVICE_PROFILE (default "phone").
# Override per-workspace via the devfile env, or from the terminal before running:
#   export DEVICE_PROFILE=tablet; provision-device.sh
# Add a new form factor here — nothing else in this script needs to change.
#
# NOTE: the redroid Android images below use floating Docker Hub
# `*-latest` tags, pulled unauthenticated *inside the disposable KubeVirt guest*
# (not by the cluster). This is a documented demo trade-off: the guest is
# throwaway and the privilege boundary is the VM, not the tag. For production,
# pin each REDROID_IMG by digest (redroid/redroid@sha256:...) or mirror the
# images into an internal registry to avoid tag mutation + Docker Hub rate limits.
DEVICE_PROFILE="${DEVICE_PROFILE:-phone}"
case "$DEVICE_PROFILE" in
  phone)
    REDROID_IMG="redroid/redroid:13.0.0_64only-latest"
    REDROID_WIDTH=1080; REDROID_HEIGHT=1920; REDROID_DPI=320 ;;
  tablet)
    REDROID_IMG="redroid/redroid:13.0.0_64only-latest"
    REDROID_WIDTH=1600; REDROID_HEIGHT=2560; REDROID_DPI=240 ;;
  phone-a12)
    # Older Android (12) for matrix testing.
    REDROID_IMG="redroid/redroid:12.0.0_64only-latest"
    REDROID_WIDTH=1080; REDROID_HEIGHT=1920; REDROID_DPI=320 ;;
  *)
    echo "WARNING: unknown DEVICE_PROFILE='${DEVICE_PROFILE}', falling back to 'phone'." >&2
    DEVICE_PROFILE="phone"
    REDROID_IMG="redroid/redroid:13.0.0_64only-latest"
    REDROID_WIDTH=1080; REDROID_HEIGHT=1920; REDROID_DPI=320 ;;
esac
# Device VM size. Defaults trimmed to 4Gi/4cpu (was 6Gi/4cpu) — enough for redroid
# Android 13 while reserving less per developer. Override if a profile needs more:
#   export VM_MEM=6Gi VM_CPU=4; provision-device.sh
VM_MEM="${VM_MEM:-4Gi}"; VM_CPU="${VM_CPU:-4}"
echo "Device profile: ${DEVICE_PROFILE} → ${REDROID_IMG} ${REDROID_WIDTH}x${REDROID_HEIGHT} @ ${REDROID_DPI}dpi (VM ${VM_MEM}/${VM_CPU}cpu)"

# ---- golden-image fast path -------------------------------------------------
# If the admin ran openshift/prepare-golden-image.sh, a pre-baked disk (Ubuntu +
# docker + binder + redroid images already pulled) exists in the platform
# namespace. Devices then CSI-CLONE it instead of importing Ubuntu over HTTP, and
# cloud-init skips apt + docker pull — a brand-new device boots in ~2 min instead
# of ~10. Without the golden disk we fall back to the full-import path.
GOLDEN_DV="golden-android-disk"
CI_PACKAGES=""
CI_SETUP_CMDS=""
if oc get pvc "$GOLDEN_DV" -n "$IMG_NS" >/dev/null 2>&1; then
  DV_SOURCE="pvc: { namespace: ${IMG_NS}, name: ${GOLDEN_DV} }"
  echo "Golden image found (${IMG_NS}/${GOLDEN_DV}) — fast clone path (no apt, no redroid pull)."
else
  DV_SOURCE="http:
            url: \"https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img\"
            checksum: \"sha256:070de108b25df4c9eacc4a297c6afc583bdd58cabf159e61d4152bc6541a6b54\""
  CI_PACKAGES="              package_update: true
              packages: [ca-certificates, curl, docker.io]"
  CI_SETUP_CMDS="                - 'KREL=\$(uname -r); DEBIAN_FRONTEND=noninteractive apt-get install -y \"linux-modules-extra-\$KREL\"'
                - 'docker pull ${REDROID_IMG}'"
  echo "No golden image — full import path (run openshift/prepare-golden-image.sh once to make this ~5x faster)."
fi

# Owner-reference to the DevWorkspace → device is GC'd when the workspace is deleted.
# this ownerReference IS the whole delete-time-GC story (there's no
# controller). If the UID lookup silently fails (RBAC race on first postStart, a
# transient API hiccup), an empty OREF means the 4Gi VM + 40Gi disk are created
# with NO owner and LEAK on workspace delete. So retry the lookup, and if it still
# can't be resolved, warn LOUDLY (don't fail — a device without GC is better than
# no device, but the operator must know).
OREF=""
WSUID=""
for _ in 1 2 3 4 5; do
  WSUID="$(oc get devworkspace "$WS" -n "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)"
  [ -n "$WSUID" ] && break
  sleep 2
done
if [ -n "$WSUID" ]; then
  OREF="  ownerReferences:
    - apiVersion: workspace.devfile.io/v1alpha2
      kind: DevWorkspace
      name: ${WS}
      uid: ${WSUID}"
else
  echo "WARNING: could not resolve DevWorkspace '${WS}' UID after retries — the device" >&2
  echo "WARNING: will be created WITHOUT an ownerReference and will NOT be garbage-collected" >&2
  echo "WARNING: when the workspace is deleted. Run 'device remove' manually to clean up." >&2
fi

# --- screen auth ----------------------------------------------------
# ws-scrcpy gives full interactive control of the device, so it must NOT be on a
# bare public Route. Front it with an oauth-proxy sidecar that requires an
# OpenShift login — any authenticated cluster user.
#
# We deliberately do NOT gate on the workspace OWNER via --openshift-sar. On
# RH-SSO / OIDC clusters oauth-proxy runs that owner check through the LEGACY
# authorization.openshift.io SubjectAccessReview API against a SYNTHESIZED identity
# (`<user>@cluster.local`, its default email domain) — and that legacy authorizer
# evaluates the user's RBAC differently from the k8s authorizer, so it denies the
# real owner ("403 Invalid Account") even with a matching RoleBinding in place.
# Requiring only authentication is robust across identity providers. The device is a
# throwaway emulator, and the per-workspace NetworkPolicies still block pod-level adb
# access to anyone but the owning workspace. (To restore strict owner-only, re-add
# --openshift-sar below and solve the legacy-SAR identity mapping for your IdP.)
#
# Generate/keep a per-deployment cookie secret (oauth-proxy session signing key).
# Reuse the existing one across re-provisions so live sessions survive a restart.
COOKIE_SECRET="$(oc get secret "${SCR}-oauth" -n "$NS" -o jsonpath='{.data.session_secret}' 2>/dev/null | base64 -d 2>/dev/null)"
if [ -z "$COOKIE_SECRET" ]; then
  # must be EXACTLY 32 chars or oauth-proxy CrashLoopBackOffs. The old
  # `base64 | tr -d '=+/' | cut` could yield <32 after stripping. Draw 32 valid
  # chars directly so length is deterministic.
  COOKIE_SECRET="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  [ "${#COOKIE_SECRET}" -eq 32 ] || fail "could not generate a 32-char cookie secret"
fi
echo "Provisioning device '${DEV}' for workspace '${WS}' in ${NS}…"

# -n "$NS" makes the target namespace explicit instead of relying on the current
# oc context (which is the workspace ns in Dev Spaces, but shouldn't be assumed).
if oc apply -n "$NS" -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${DEV}
  labels:
    app: android-device
    android.workspace: "${WSID}"
${OREF}
spec:
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: ${DEV}-disk
      spec:
        # Golden path: CSI-clone the pre-baked disk from the platform namespace.
        # Fallback: HTTP-import Ubuntu, SHA256-gated (openshift/prepare-golden-image.sh
        # pins the same url+checksum pair — update both together on a rebase).
        source:
          ${DV_SOURCE}
        storage: { resources: { requests: { storage: 40Gi } } }
  template:
    metadata:
      labels: { kubevirt.io/domain: ${DEV}, vm.kubevirt.io/name: ${DEV}, app: android-device }
    spec:
      domain:
        cpu: { cores: ${VM_CPU} }
        memory: { guest: ${VM_MEM} }
        devices:
          disks:
            - { name: rootdisk, disk: { bus: virtio } }
            - { name: cloudinitdisk, disk: { bus: virtio } }
          interfaces: [ { name: default, masquerade: {}, ports: [ { name: adb, port: 5555 } ] } ]
        resources: { requests: { memory: ${VM_MEM} } }
      networks: [ { name: default, pod: {} } ]
      volumes:
        - { name: rootdisk, dataVolume: { name: ${DEV}-disk } }
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |-
              #cloud-config
${CI_PACKAGES}
              write_files:
                - { path: /etc/modules-load.d/binder.conf, content: "binder_linux\n" }
                - { path: /etc/modprobe.d/binder.conf, content: "options binder_linux devices=binder,hwbinder,vndbinder\n" }
                - path: /etc/systemd/system/redroid.service
                  content: |
                    # adb binds 0.0.0.0:5555 inside the VM so the in-cluster adb
                    # Service can reach it via KubeVirt masquerade. adb has no
                    # auth, so cross-pod/cross-namespace access is blocked at the
                    # network layer by the ${DEV}-adb NetworkPolicy — only
                    # the owning workspace pod may connect.
                    [Unit]
                    Description=redroid Android (adb:5555)
                    After=docker.service network-online.target
                    Requires=docker.service
                    [Service]
                    Type=simple
                    Restart=always
                    RestartSec=5
                    TimeoutStartSec=600
                    ExecStartPre=-/usr/bin/docker rm -f redroid
                    ExecStart=/usr/bin/docker run --rm --name redroid --privileged -v /opt/redroid-data:/data -p 0.0.0.0:5555:5555 ${REDROID_IMG} androidboot.redroid_gpu_mode=guest androidboot.use_memfd=1 androidboot.redroid_width=${REDROID_WIDTH} androidboot.redroid_height=${REDROID_HEIGHT} androidboot.redroid_dpi=${REDROID_DPI} androidboot.redroid_fps=30
                    ExecStop=/usr/bin/docker stop -t 15 redroid
                    [Install]
                    WantedBy=multi-user.target
              runcmd:
${CI_SETUP_CMDS}
                - 'modprobe binder_linux devices=binder,hwbinder,vndbinder'
                - 'mkdir -p /opt/redroid-data'
                - 'systemctl enable --now docker'
                - 'systemctl enable --now redroid.service'
---
apiVersion: v1
kind: Service
metadata:
  name: ${DEV}
  labels:
    app: android-device
    android.workspace: "${WSID}"
${OREF}
spec:
  selector: { vm.kubevirt.io/name: ${DEV} }
  ports: [ { name: adb, port: 5555, targetPort: 5555 } ]
---
# Cookie/session-signing secret for the screen's oauth-proxy.
apiVersion: v1
kind: Secret
metadata:
  name: ${SCR}-oauth
  labels:
    app: ws-scrcpy
    android.workspace: "${WSID}"
${OREF}
type: Opaque
stringData:
  session_secret: "${COOKIE_SECRET}"
---
# ServiceAccount the screen runs as, declared as an OpenShift OAuth client via
# the redirect-reference annotation so oauth-proxy can complete the login flow
# against this workspace's screen Route.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SCR}
  labels:
    app: ws-scrcpy
    android.workspace: "${WSID}"
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.screen: '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"${SCR}"}}'
${OREF}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SCR}
  labels:
    app: ws-scrcpy
    android.workspace: "${WSID}"
${OREF}
spec:
  replicas: 1
  selector: { matchLabels: { app: ws-scrcpy, android.workspace: "${WSID}" } }
  template:
    metadata: { labels: { app: ws-scrcpy, android.workspace: "${WSID}" } }
    spec:
      serviceAccountName: ${SCR}
      containers:
        # ws-scrcpy itself — now bound to localhost-only via the proxy; it
        # listens on :8000 but is only reachable through the oauth-proxy sidecar.
        - name: ws-scrcpy
          image: ${WS_SCRCPY_IMG}
          env: [ { name: DEVICE_ADDR, value: "${DEV}:5555" } ]
          ports: [ { containerPort: 8000 } ]
          resources: { requests: { cpu: 100m, memory: 256Mi }, limits: { cpu: "1", memory: 1Gi } }
        # oauth-proxy: terminates TLS (service-serving cert) and requires an
        # OpenShift login. --email-domain=* accepts any authenticated user (no owner
        # SAR — see the "screen auth" note above for why owner-only is unreliable here).
        - name: oauth-proxy
          image: ${OAUTH_PROXY_IMG}
          args:
            - --https-address=:8443
            - --http-address=
            - --provider=openshift
            - --openshift-service-account=${SCR}
            - --upstream=http://localhost:8000
            - --tls-cert=/etc/tls/private/tls.crt
            - --tls-key=/etc/tls/private/tls.key
            - --cookie-secret-file=/etc/proxy/secrets/session_secret
            - --email-domain=*
          ports: [ { name: https, containerPort: 8443 } ]
          volumeMounts:
            - { name: proxy-tls, mountPath: /etc/tls/private }
            - { name: proxy-cookie, mountPath: /etc/proxy/secrets }
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 200m, memory: 256Mi } }
      volumes:
        - name: proxy-tls
          secret: { secretName: ${SCR}-tls }
        - name: proxy-cookie
          secret: { secretName: ${SCR}-oauth }
---
apiVersion: v1
kind: Service
metadata:
  name: ${SCR}
  labels:
    app: ws-scrcpy
    android.workspace: "${WSID}"
  annotations:
    # Mint a service-serving cert into ${SCR}-tls for oauth-proxy's TLS.
    service.beta.openshift.io/serving-cert-secret-name: ${SCR}-tls
${OREF}
spec:
  selector: { app: ws-scrcpy, android.workspace: "${WSID}" }
  ports: [ { name: https, port: 8443, targetPort: 8443 } ]
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${SCR}
  labels:
    app: ws-scrcpy
    android.workspace: "${WSID}"
${OREF}
spec:
  to: { kind: Service, name: ${SCR} }
  port: { targetPort: https }
  # reencrypt: edge router re-encrypts to the oauth-proxy, which holds the
  # auth gate. No unauthenticated path to the screen.
  tls: { termination: reencrypt, insecureEdgeTerminationPolicy: Redirect }
---
# NetworkPolicies — block cross-namespace / other-pod access to the
# adb port and the screen. Owner-referenced like everything else so they GC with
# the workspace.
#
# How the deny baseline works: a NetworkPolicy that SELECTS a pod with
# policyTypes:[Ingress] already makes THAT pod default-deny-except-allowed — the
# allow-list policies below select the device + screen pods, so those pods are
# already deny-by-default. Verified empirically: a pod in an unrelated namespace
# trying nc to dev-<ws>:5555 TIMED OUT (denied), while the owning workspace pod
# was admitted. We do NOT default-deny the *whole namespace* (podSelector:{}),
# because that would also fence the Che workspace pod and break its gateway
# routes — the deny is scoped to the device + screen only.
#
# Belt-and-suspenders: an EXPLICIT default-deny-ingress scoped (by podSelector)
# to just the device + screen pods, so the deny baseline is unambiguous and
# survives even if a future edit loosens the allow-list selectors. This selects
# the same pods as the allows below; NetworkPolicies are additive, so the allows
# punch the only holes through this deny.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${DEV}-default-deny
  labels:
    app: android-device
    android.workspace: "${WSID}"
${OREF}
spec:
  # Device VM pod + screen (ws-scrcpy) pod — NOT the workspace pod.
  podSelector:
    matchExpressions:
      - key: app
        operator: In
        values: [ android-device, ws-scrcpy ]
  policyTypes: [ Ingress ]
  # No ingress rules → deny all ingress to the selected pods by default. The
  # scoped allows below re-admit exactly the owning workspace pod (+ router).
  ingress: []
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${DEV}-adb
  labels:
    app: android-device
    android.workspace: "${WSID}"
${OREF}
spec:
  # Applies to the device VM's virt-launcher pod (exposes adb:5555).
  podSelector:
    matchLabels: { vm.kubevirt.io/name: ${DEV} }
  policyTypes: [ Ingress ]
  ingress:
    # adb:5555 is reachable by (a) the owning workspace pod (run-on-device.sh /
    # device-status.sh) AND (b) THIS workspace's ws-scrcpy SCREEN pod, which must
    # connect to adb to render the device. The two podSelectors are OR'd. Without (b)
    # the screen loads its "Device Tracker" UI but shows NO device.
    - from:
        - podSelector:
            matchLabels: { controller.devfile.io/devworkspace_name: "${WS}" }
        - podSelector:
            matchLabels: { app: ws-scrcpy, android.workspace: "${WSID}" }
      ports: [ { protocol: TCP, port: 5555 } ]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${SCR}-screen
  labels:
    app: ws-scrcpy
    android.workspace: "${WSID}"
${OREF}
spec:
  # Applies to the ws-scrcpy pod (oauth-proxy :8443).
  podSelector:
    matchLabels: { app: ws-scrcpy, android.workspace: "${WSID}" }
  policyTypes: [ Ingress ]
  ingress:
    # The OpenShift router (so the authenticated Route works) ...
    - from:
        - namespaceSelector:
            matchLabels: { policy-group.network.openshift.io/ingress: "" }
      ports: [ { protocol: TCP, port: 8443 } ]
    # ... and the owning workspace pod directly.
    - from:
        - podSelector:
            matchLabels: { controller.devfile.io/devworkspace_name: "${WS}" }
      ports: [ { protocol: TCP, port: 8443 } ]
---
# EGRESS policy on the device pod. The device runs arbitrary third-party
# APKs in a privileged guest, so its outbound deserves limiting. By DEFAULT we
# block only the cloud-metadata endpoint (169.254.169.254 — the highest-value SSRF
# target: instance/cloud credentials) and allow everything else, because the guest
# MUST still reach DNS + Docker Hub to boot redroid (a smoke test confirmed that
# fencing the cluster's internal CIDRs stops the redroid pull and the device never
# boots). For a stricter multi-tenant lockdown, extend the except list with this
# cluster's pod+service CIDRs (oc get network.config cluster) to also deny internal
# services + the API server — and VERIFY the device still boots in your environment
# (the in-guest redroid pull needs internet + working DNS).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${DEV}-egress
  labels:
    app: android-device
    android.workspace: "${WSID}"
${OREF}
spec:
  podSelector:
    matchLabels: { vm.kubevirt.io/name: ${DEV} }
  policyTypes: [ Egress ]
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [ 169.254.169.254/32 ]
EOF
then
  echo "DONE" > "$STATUS_FILE"
else
  fail "oc apply did not complete cleanly (RBAC gap, admission reject, or quota?). See output above."
fi

# The VM manifest declares `runStrategy: Always` and `oc apply` reconciles it
# every run, so the VM is already (re)started by the apply above — no separate
# wake/patch is needed. DONE was written in the success branch above.
echo "Done. Your device is starting (a few minutes the first time)."
echo "The screen is now behind OpenShift login (oauth-proxy) — open it with 'device screen'."
echo "Check it with the 'Device: status' task or:  device status"

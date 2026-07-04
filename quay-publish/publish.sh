#!/usr/bin/env bash
# Publish the quickstart images to quay.io — MAINTAINER tool (see README.md here).
#
# Run from a machine with `oc` logged into a cluster where the platform is fully
# deployed (workspace + screen images built, golden disk baked). Everything heavy
# runs IN-CLUSTER as temporary Jobs — this machine needs oc only; no image bytes
# transit it.
#
#   export QUAY_USER='serhat_dirik+robot'  QUAY_PASSWORD='...'
#   ./quay-publish/publish.sh
#
# Publishes (":latest" + a ":<date>" tag that only exists so old digests are
# never garbage-collected — consumers pin digests):
#   quay.io/serhat_dirik/devspaces:mobile-allinone   (workspace image)
#   quay.io/serhat_dirik/devspaces:ws-scrcpy          (screen image)
#   quay.io/serhat_dirik/devspaces:golden             (golden disk as containerDisk)
# then rewrites the digest pins in the app repo's devfile-quay.yaml and
# quickstart-cache.sh. YOU must commit those — the script reminds you.
set -euo pipefail

# ONE quay repo; the three artifacts are TAGS (quay robots can't create repos,
# so everything lives in the single repo the account owner created).
QUAY_REPO="${QUAY_REPO:-quay.io/serhat_dirik/devspaces}"
PLATFORM_NS="${PLATFORM_NS:-devspace-android-demo}"
DATE_TAG="$(date +%Y%m%d)"
REG=image-registry.openshift-image-registry.svc:5000
APP_REPO="${APP_REPO:-$(cd "$(dirname "$0")/../../devspaces-android-sample-app" 2>/dev/null && pwd || true)}"

ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
info(){ printf '  → %s\n' "$*"; }
fail(){ printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

: "${QUAY_USER:?export QUAY_USER='<quay user or robot>'}"
: "${QUAY_PASSWORD:?export QUAY_PASSWORD='<password/robot token>'}"
command -v oc >/dev/null || fail "oc not found"
oc whoami >/dev/null 2>&1 || fail "not logged in (oc login ...)"
oc get istag mobile-allinone:latest -n "$PLATFORM_NS" >/dev/null 2>&1 || fail "mobile-allinone not built in $PLATFORM_NS"
oc get istag ws-scrcpy:latest       -n "$PLATFORM_NS" >/dev/null 2>&1 || fail "ws-scrcpy not built in $PLATFORM_NS"
oc get pvc golden-android-disk      -n "$PLATFORM_NS" >/dev/null 2>&1 || fail "golden disk not baked (openshift/prepare-golden-image.sh)"

# qemu-img comes from the cluster's own CDI importer image (always present with CNV)
QEMU_IMG_IMAGE="$(oc get deploy cdi-deployment -n openshift-cnv \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="IMPORTER_IMAGE")].value}' 2>/dev/null)"
[ -n "$QEMU_IMG_IMAGE" ] || fail "could not discover the CDI importer image (is OpenShift Virtualization installed?)"

info "quay auth secret (temporary)"
oc create secret docker-registry quay-publish-auth -n "$PLATFORM_NS" \
  --docker-server=quay.io --docker-username="$QUAY_USER" --docker-password="$QUAY_PASSWORD" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null

info "publish SA (temporary; golden job needs a privileged build container)"
oc create sa quay-publish -n "$PLATFORM_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc adm policy add-scc-to-user privileged -z quay-publish -n "$PLATFORM_NS" >/dev/null

# SA token for pulling from the internal registry inside the jobs
SRC_TOKEN="$(oc create token quay-publish -n "$PLATFORM_NS" --duration=2h)"

oc delete job quay-publish-images quay-publish-golden -n "$PLATFORM_NS" --ignore-not-found >/dev/null

info "Job 1: copy workspace + screen images to quay (in-cluster skopeo)"
oc apply -n "$PLATFORM_NS" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata: { name: quay-publish-images }
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: skopeo
          image: quay.io/skopeo/stable:latest
          env: [ { name: SRC_TOKEN, value: "${SRC_TOKEN}" } ]
          volumeMounts: [ { name: quay-auth, mountPath: /auth } ]
          command: ["/bin/bash","-c"]
          args:
            - |
              set -euo pipefail
              for src in mobile-allinone ws-scrcpy; do
                echo "== \${src} -> ${QUAY_REPO}:\${src}"
                skopeo copy --src-tls-verify=false \
                  --src-creds "publisher:\${SRC_TOKEN}" \
                  --dest-authfile /auth/.dockerconfigjson \
                  docker://${REG}/${PLATFORM_NS}/\${src}:latest docker://${QUAY_REPO}:\${src}
                skopeo copy --all --authfile /auth/.dockerconfigjson \
                  docker://${QUAY_REPO}:\${src} docker://${QUAY_REPO}:\${src}-${DATE_TAG}
              done
      volumes:
        - name: quay-auth
          secret: { secretName: quay-publish-auth }
EOF

info "Job 2: golden disk -> qcow2 -> containerDisk -> quay (in-cluster convert + buildah)"
oc apply -n "$PLATFORM_NS" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata: { name: quay-publish-golden }
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: quay-publish
      initContainers:
        # qemu-img lives in the cluster's own CDI importer image
        - name: convert
          image: ${QEMU_IMG_IMAGE}
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              echo "converting block device -> compressed qcow2 (takes a few minutes)"
              qemu-img convert -O qcow2 -c /dev/golden /work/disk.qcow2
              qemu-img info /work/disk.qcow2
          volumeDevices: [ { name: golden, devicePath: /dev/golden } ]
          volumeMounts:   [ { name: work,  mountPath: /work } ]
          securityContext: { privileged: true, runAsUser: 0 }
      containers:
        - name: push
          image: quay.io/buildah/stable:latest
          securityContext: { privileged: true, runAsUser: 0 }
          volumeMounts:
            - { name: work, mountPath: /work }
            - { name: quay-auth, mountPath: /auth }
          command: ["/bin/bash","-c"]
          args:
            - |
              set -euo pipefail
              cd /work
              printf 'FROM scratch\nADD disk.qcow2 /disk/\n' > Containerfile
              buildah --storage-driver vfs bud -t golden:tmp .
              buildah --storage-driver vfs push --authfile /auth/.dockerconfigjson golden:tmp docker://${QUAY_REPO}:golden
              buildah --storage-driver vfs push --authfile /auth/.dockerconfigjson golden:tmp docker://${QUAY_REPO}:golden-${DATE_TAG}
      volumes:
        - name: golden
          persistentVolumeClaim: { claimName: golden-android-disk }
        - name: work
          emptyDir: { sizeLimit: 30Gi }
        - name: quay-auth
          secret: { secretName: quay-publish-auth }
EOF

info "waiting for both jobs (images: minutes; golden: convert + push, up to ~20 min)…"
for j in quay-publish-images quay-publish-golden; do
  if ! oc wait --for=condition=complete "job/$j" -n "$PLATFORM_NS" --timeout=30m 2>/dev/null; then
    echo; echo "---- $j logs (tail) ----"; oc logs "job/$j" -n "$PLATFORM_NS" --all-containers --tail=30 || true
    fail "$j did not complete"
  fi
  ok "$j complete"
done

info "resolving published digests"
digest_of(){ oc image info "$1" -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["digest"])'; }
D_WORKSPACE="$(digest_of "${QUAY_REPO}:mobile-allinone")"
D_SCREEN="$(digest_of "${QUAY_REPO}:ws-scrcpy")"
D_GOLDEN="$(digest_of "${QUAY_REPO}:golden")"
[ -n "$D_WORKSPACE" ] && [ -n "$D_SCREEN" ] && [ -n "$D_GOLDEN" ] || fail "digest resolution failed"
ok "workspace: $D_WORKSPACE"
ok "screen:    $D_SCREEN"
ok "golden:    $D_GOLDEN"

info "cleanup (jobs, secret, SA)"
oc delete job quay-publish-images quay-publish-golden -n "$PLATFORM_NS" --ignore-not-found >/dev/null
oc delete secret quay-publish-auth -n "$PLATFORM_NS" --ignore-not-found >/dev/null
oc adm policy remove-scc-from-user privileged -z quay-publish -n "$PLATFORM_NS" >/dev/null 2>&1 || true
oc delete sa quay-publish -n "$PLATFORM_NS" --ignore-not-found >/dev/null

[ -n "$APP_REPO" ] && [ -f "$APP_REPO/devfile-quay.yaml" ] || fail "app repo not found (set APP_REPO=/path/to/devspaces-android-sample-app)"
info "pinning new digests into the app repo"
python3 - "$APP_REPO" "$QUAY_REPO" "$D_WORKSPACE" "$D_SCREEN" "$D_GOLDEN" <<'PYEOF'
import re, sys
repo, qrepo, dw, dsc, dg = sys.argv[1:6]
def pin(path, tag, digest):
    # matches repo:tag or repo:tag@sha256:... -> repo:tag@<new digest>
    with open(path) as f: s = f.read()
    s2 = re.sub(re.escape(qrepo) + ':' + tag + r'[^\s"\047}]*', f'{qrepo}:{tag}@{digest}', s)
    with open(path, 'w') as f: f.write(s2)
    return s != s2
changed  = pin(f'{repo}/devfile-quay.yaml', 'mobile-allinone', dw)
changed |= pin(f'{repo}/devfile-quay.yaml', 'ws-scrcpy', dsc)
changed |= pin(f'{repo}/quickstart-cache.sh', 'golden', dg)
print('  pins updated' if changed else '  pins already current')
PYEOF

echo
ok "published :latest + :${DATE_TAG} for all three images"
echo
echo "  ⚠️  NOT DONE YET — testers keep getting the previous version until you:"
echo "        cd ${APP_REPO}"
echo "        git diff                       # review the digest pins"
echo "        git commit -am 'chore: quickstart images ${DATE_TAG}' && git push"

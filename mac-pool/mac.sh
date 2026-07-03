#!/usr/bin/env bash
# =============================================================================
# mac.sh — lease / sync / build / run / release a stateless macOS build VM
#          from a Mac pool, for iOS builds driven from an OpenShift Dev Spaces
#          workspace (or any Linux CI step).
#
# MODEL (read this first):
#   * The Mac is an EXTERNAL, STATELESS executor. Nothing persists on it
#     between leases. Source of truth = your workspace PVC + Git.
#   * A "lease" = an ephemeral macOS VM cloned from a pre-baked GOLDEN IMAGE
#     (Xcode + CLI tools + simulators + fastlane + sshd already installed).
#   * Each build: lease-or-reuse -> sync code in -> xcodebuild/fastlane ->
#     copy artifacts back to the PVC -> (optionally) release.
#   * Because every command ensures a lease itself, the workspace can
#     start/stop/sleep/wake freely without breaking iOS builds.
#
# USAGE:
#   ./mac.sh lease            # acquire (or reuse) a Mac, wire SSH
#   ./mac.sh status           # show current lease
#   ./mac.sh sync             # rsync the working tree to the Mac
#   ./mac.sh build            # ensure+sync, then build the .ipa
#   ./mac.sh run              # ensure+sync, boot Simulator + run tests
#   ./mac.sh shell            # interactive ssh to the Mac
#   ./mac.sh release          # return the Mac to the pool
#
# CONFIG: set these as workspace env vars (devfile) or a .env file.
#   POOL_PROVIDER   ec2mac | rest        (which pool backend)
#   POOL_API        https://pool/api     (REST providers: Orka/Orchard/Anka)
#   POOL_TOKEN      <token>              (REST auth)
#   POOL_IMAGE      xcode16-golden       (golden image / template name)
#   MAC_USER        builder              (build user on the golden image)
#   APP_SCHEME      MyApp                (xcodebuild scheme)
#   PROJECT_DIR     ${PROJECT_SOURCE}    (path to your Flutter/iOS project)
#   STATE_DIR       ${PROJECT_SOURCE}/.mac   (lease state, on the PVC)
# =============================================================================
set -euo pipefail

POOL_PROVIDER="${POOL_PROVIDER:-ec2mac}"
POOL_API="${POOL_API:-}"
POOL_TOKEN="${POOL_TOKEN:-}"
POOL_IMAGE="${POOL_IMAGE:-xcode16-golden}"
MAC_USER="${MAC_USER:-builder}"
APP_SCHEME="${APP_SCHEME:-MyApp}"
PROJECT_DIR="${PROJECT_DIR:-${PROJECT_SOURCE:-$PWD}}"
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/.mac}"
KEY="${STATE_DIR}/id_ephemeral"
mkdir -p "${STATE_DIR}"

log(){ printf '\033[1;31m[mac]\033[0m %s\n' "$*"; }   # HINT: red [mac] prefix so it stands out in the IDE terminal

# -- ensure an ephemeral SSH keypair exists (regenerated per lease) -----------
_ensure_key(){
  if [[ ! -f "${KEY}" ]]; then
    ssh-keygen -t ed25519 -N '' -f "${KEY}" -C "devspaces-ephemeral" >/dev/null
  fi
}

# =============================================================================
# LEASE — acquire (or reuse) a Mac VM and wire ~/.ssh/config alias "mac"
# =============================================================================
lease(){
  _ensure_key
  if status >/dev/null 2>&1; then log "reusing lease $(cat "${STATE_DIR}/id")"; return 0; fi

  case "${POOL_PROVIDER}" in
    rest)
      # ---- Generic REST pool (Orka / Orchard / Anka). Endpoints differ; the
      #      shape is identical: create VM -> poll running -> read IP. ----------
      log "leasing from REST pool ${POOL_API}"
      local resp id host
      resp=$(curl -fsS -X POST "${POOL_API}/vms" \
               -H "Authorization: Bearer ${POOL_TOKEN}" -H 'Content-Type: application/json' \
               -d "{\"image\":\"${POOL_IMAGE}\",\"cpu\":6,\"memory\":16,\"sshKey\":\"$(cat "${KEY}.pub")\"}")
      id=$(jq -r '.id' <<<"${resp}")
      # poll until the orchestrator reports the VM running with an IP
      for _ in $(seq 1 60); do
        host=$(curl -fsS "${POOL_API}/vms/${id}" -H "Authorization: Bearer ${POOL_TOKEN}" | jq -r '.ip // empty')
        [[ -n "${host}" ]] && break; sleep 5
      done
      [[ -z "${host}" ]] && { log "timed out waiting for VM"; return 1; }
      echo "${id}" > "${STATE_DIR}/id"; echo "${host}" > "${STATE_DIR}/host"
      ;;
    ec2mac)
      # ---- AWS EC2 Mac. NOTE the 24h-minimum host allocation (Apple SLA): in
      #      practice keep a Dedicated Host warm and lease SESSIONS, not hosts.
      #      Here we run an instance on an existing host pool tagged Role=mac-pool.
      log "leasing EC2 Mac instance"
      local hostid iid host
      hostid=$(aws ec2 describe-hosts --filter "Name=state,Values=available" \
                 "Name=tag:Role,Values=mac-pool" --query 'Hosts[0].HostId' --output text)
      [[ "${hostid}" == "None" || -z "${hostid}" ]] && { log "no free Mac host in pool"; return 1; }
      iid=$(aws ec2 run-instances --instance-type mac2.metal --image-id "${POOL_IMAGE}" \
              --placement "HostId=${hostid},Tenancy=host" \
              --key-name devspaces-ephemeral \
              --query 'Instances[0].InstanceId' --output text)
      aws ec2 wait instance-running --instance-ids "${iid}"
      host=$(aws ec2 describe-instances --instance-ids "${iid}" \
              --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
      echo "${iid}" > "${STATE_DIR}/id"; echo "${host}" > "${STATE_DIR}/host"
      ;;
    *) log "unknown POOL_PROVIDER='${POOL_PROVIDER}'"; return 2 ;;
  esac

  # ---- wire an SSH alias "mac" so every later command is just `ssh mac ...` ---
  local host; host=$(cat "${STATE_DIR}/host")
  touch ~/.ssh/config; chmod 600 ~/.ssh/config
  sed -i '/^Host mac$/,/^$/d' ~/.ssh/config 2>/dev/null || true
  cat >> ~/.ssh/config <<EOF
Host mac
  HostName ${host}
  User ${MAC_USER}
  IdentityFile ${KEY}
  StrictHostKeyChecking accept-new
EOF
  log "leased ${host} -> ssh alias 'mac'"
}

# =============================================================================
status(){ [[ -f "${STATE_DIR}/id" ]] && { echo "lease: $(cat "${STATE_DIR}/id") @ $(cat "${STATE_DIR}/host" 2>/dev/null)"; } || { echo "no lease"; return 1; }; }

# =============================================================================
# SYNC — push the working tree to the Mac.
#   * INNER LOOP  -> rsync (fast, no commit). This is the default.
#   * CI / RELEASE-> use Git instead (the Mac/Azure DevOps agent checks out a
#                   tagged commit). Set SYNC=git to switch.
# =============================================================================
sync(){
  lease
  case "${SYNC:-rsync}" in
    git)  log "git sync (CI mode): the Mac will checkout from origin"
          ssh mac "cd ~/build && git fetch --all && git checkout ${GIT_REF:-HEAD} && git reset --hard ${GIT_REF:-HEAD}" ;;
    *)    log "rsync ${PROJECT_DIR} -> mac:~/build"
          rsync -az --delete --exclude '.git' --exclude 'build/' "${PROJECT_DIR}/" "mac:~/build/" ;;
  esac
}

# =============================================================================
build(){
  sync
  log "xcodebuild (scheme ${APP_SCHEME})"
  # HINT: signing certs/profiles must be injected into an EPHEMERAL keychain at
  #       build time from your vault — NEVER baked into the golden image.
  ssh mac "cd ~/build && fastlane build scheme:${APP_SCHEME}" \
    || ssh mac "cd ~/build && xcodebuild -scheme ${APP_SCHEME} -destination 'generic/platform=iOS' -archivePath build/App.xcarchive archive"
  log "pull artifacts back to the PVC"
  mkdir -p "${PROJECT_DIR}/build/ios"
  rsync -az "mac:~/build/build/" "${PROJECT_DIR}/build/ios/"
}

# =============================================================================
run(){
  sync
  log "boot Simulator + run tests on the Mac"
  ssh mac "cd ~/build && xcrun simctl boot 'iPhone 16' 2>/dev/null; xcodebuild -scheme ${APP_SCHEME} -destination 'platform=iOS Simulator,name=iPhone 16' test"
  log "HINT: to SEE the Simulator, open the VNC URL your pool exposes for this VM in a browser tab."
}

# =============================================================================
shell(){ lease; ssh mac; }

# =============================================================================
# RELEASE — return the Mac. Two policies:
#   * release on every workspace stop (cheapest; next wake gets a fresh clone)
#   * OR keep it and let a pool-side TTL reclaim it (session-stable, costs more,
#     mandatory thinking for EC2 Mac's 24h minimum). Choose in your devfile.
# =============================================================================
release(){
  status >/dev/null 2>&1 || { log "nothing to release"; return 0; }
  local id; id=$(cat "${STATE_DIR}/id")
  case "${POOL_PROVIDER}" in
    rest)   curl -fsS -X DELETE "${POOL_API}/vms/${id}" -H "Authorization: Bearer ${POOL_TOKEN}" || true ;;
    ec2mac) aws ec2 terminate-instances --instance-ids "${id}" >/dev/null || true ;;  # host stays warm in the pool
  esac
  rm -f "${STATE_DIR}/id" "${STATE_DIR}/host"
  log "released ${id}"
}

cmd="${1:-status}"; shift || true; "${cmd}" "$@"

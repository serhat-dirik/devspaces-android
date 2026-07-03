# OpenShift DevSpaces Mobile Development Demo

OpenShift DevSpaces is a great technology for organisation's platform engineering
teams to provide their developers instantly accessible and governed development
environments fully integrated in their DevSecOps lifecycles. Platform Engineers can
curate their developer workspace offerings and development teams can attach developer
environment profiles to their project source repo. A new developer can instantly
have all he needs to start contributing the project.

Mobile app development is a special category and introduces it's own specific
challenges to both development and CI/CD. Applications should be tested on
mobile device emulators. This project demonstrates building mobile apps in a
browser-based, containerized workspace — and run them on a
real Android device, **one per workspace, running on the cluster**. No laptop
toolchain, no local emulator, and no privileged developer container.

Each workspace gets **its own** Android device plus a live, interactive screen in
a browser tab. A developer can run several workspaces (one per app) and each has
its own device — no collisions. **The developer owns the device lifecycle** with
simple commands: `device start` to start (or wake) it, `device stop` to
halt it, `device remove` to delete it. One thing stays automatic: deleting the
workspace deletes the device with it (Kubernetes owner-reference GC).

```
 user1's namespace                                 user2's namespace
   workspace "shop-app" ──adb──▶ dev-shop-app          workspace "game" ──adb──▶ dev-game
   workspace "admin-app" ─adb──▶ dev-admin-app         (Flutter app)      + live screen
   (each workspace owns its own device + screen)
```

> **Scope at a glance:** **Android emulators runs today**; **iOS is a design sketch only**
> (it needs an external Mac pool — see [`mac-pool/`](mac-pool/README.md)). This is a
> **demo**, not a supported product — see
> [*Status & scope*](#status--scope).

---

## Why run this on the cluster? (and when not to)

Be honest about the trade first: for a single developer on a capable laptop, working
offline, a local VSCode + emulator setup is probably faster and more ergonomic than any browser
workspace — lower latency, native plugins. This demo is not trying
to win *that* comparison. It approach more from an **organization** benefits perspective.

**A local laptop is the better choice when** you're one experienced developer, on a
machine you control, building offline, and setup cost is a one-time annoyance you've
already paid.

**This platform is the better choice when** you're onboarding people, running a team
that has to stay in sync, working under security or compliance constraints, or you need
a real device without buying and managing one. Development in a corporate world.

### For platform & security owners
- **Source code never lands on an endpoint.** It's cloned, built, and run inside the
  cluster — nothing to exfiltrate from a lost, stolen, or compromised laptop.
- **Works on locked-down or BYO machines.** No admin rights, no Android SDK install, no
  toolchain on the endpoint — a managed Chromebook or a contractor's laptop is enough.
- **Secrets and signing keys stay cluster-side.** Registry credentials, keystores, and
  tokens live in the namespace, never copied to laptops.
- **Access is revocable and leaves no residue.** Delete the workspace and the code, the
  build cache, and the device all go with it — no remote-wipe dance.
- **The real device is inside the trust boundary too.** No USB-debugging a personal
  phone, no rooted handset on someone's desk, no app data leaving to personal hardware.
  Everything stays in your region and your cluster.

### For engineering leaders
- **Open the project and you're already working.** Pick the app from the catalog and the
  workspace comes up with the *exact* environment it needs — pinned Flutter and Android
  SDK, every device script already on `PATH`, a real device attached. No "spend day one
  installing Android Studio and matching versions."
- **Curated and governed, not assembled.** The org ships one blessed image and one
  devfile; every developer gets the identical, approved setup instead of a laptop that
  quietly drifted over eighteen months. "Works on my machine" stops being a sentence
  anyone says.
- **Ephemeral and disposable.** A broken environment is one delete away from a clean
  one; nothing accretes.
- **Everyone tests the same thing.** Same device profile, geometry, and Android version
  across the team — not whatever phone or emulator each person happened to have.
- **No hardware to procure.** Devices and builds run on cluster compute; the laptop just
  needs a browser. Scaling is a number of workspaces, not a purchase order.

Where this goes next: the same devfile and on-cluster device a developer drives by hand
are exactly the seam a pipeline plugs into — the on-ramp to **fully automated CI/CD that
builds and tests on a real device**, on the same platform, with no separate device lab.
This demo ships the interactive half; the automated half is the natural next step.

---

## What you're deploying

Three moving parts, one namespace, no extra controller to babysit:

- **Android** runs on the cluster: each device is a KubeVirt VM running
  [redroid](https://github.com/remote-android/redroid-doc) (native Android in a
  container — *not* an emulator). Because redroid is the real Android runtime, not
  QEMU, the Android layer needs no nested virtualization of its own. It does,
  however, run **inside a KubeVirt VM**, and that VM wants hardware virtualization —
  so the device must be scheduled onto a **KVM-capable node**
  (see [Prerequisites](#prerequisites)). OpenShift Virtualisation enabled.
- **No controller, no extra component, no RBAC magic.** The developer manages the
  device with scripts on `PATH` (`device start` / `device stop` /
  `device remove`) using their own standard `edit` rights; a Kubernetes
  **owner-reference** garbage-collects the device when the workspace is deleted.
- **iOS is a design sketch — not implemented.** It can't run on the cluster (Apple
  forbids macOS virtualization off Apple hardware), so the design reaches it through
  a remote Mac pool. That Mac pool is **external infrastructure you build and
  operate** — budget it as its own project, not a flag to switch on. See
  [`mac-pool/`](mac-pool/README.md).

---

## Quick Start: Deploy in 7 steps

The canonical runbook — steps 1–3 are cluster prerequisites, 4–7 deploy the platform.
[Prerequisites](#prerequisites) and the self-hosted-git-host branch are detailed below.

```bash
./preflight.sh check                                       # 1. readiness check
#                                                            2. install OpenShift Virtualization if missing
./preflight.sh prepare                                     # 3. install Dev Spaces (or let step 4 prompt) — pick ONE
./openshift/build-and-deploy.sh                            # 4. workspace image + platform bindings (once; developer perms come from Dev Spaces itself)
oc apply -f openshift/screen/buildconfig.yaml -n devspace-android-demo   # 5. ws-scrcpy screen image…
oc start-build ws-scrcpy -n devspace-android-demo          #    …then build it
./openshift/prepare-golden-image.sh                        # 6. pre-bake the device golden image (~10 min, once)
export REPO_URL=https://github.com/serhat-dirik/devspaces-android-sample-app   # 7. register an app in the catalog
# (deploying your own app? point REPO_URL at your fork / your app repo instead)
./samples/register-sample.sh
```

> **Step 6 is what makes device provisioning fast.** It bakes Ubuntu + docker +
> the redroid Android images into one golden disk; every device then CSI-clones
> that disk in seconds instead of downloading everything from the internet —
> `device start` drops from **~10 min to ~2 min**. Skippable (provisioning falls
> back to the slow full-import path), but you want it. Optional extra:
> `oc apply -f openshift/image-prewarm.yaml -n devspace-android-demo` pre-pulls
> the big workspace image onto every node, so first workspaces start fast too.

> Device VMs need a KVM-capable node, but **KubeVirt schedules them there
> automatically**.
>
> **No custom roles, no per-developer setup.** Dev Spaces itself grants each
> developer the **built-in `edit` role** in their own namespace (CheCluster
> `user.clusterRoles`, set by `preflight.sh prepare`) — and KubeVirt/CDI aggregate
> into `edit`, so the same standard role that lets a developer deploy apps also lets
> them provision their device VM. Every future namespace is covered automatically.

**You'll see:** developers can open the app from the Dev Spaces dashboard catalog,
each developer starts their own device with one command (`device start`),
and the live screen renders behind an OpenShift login. Per-step notes and the self-hosted git-host branch are in
[*Deploy: what lives where*](#deploy-what-lives-where).

---
# Detailed Setup
## Prerequisites

> **Goal:** confirm the cluster can host devices *before* you deploy — the scripts
> only *check* these, they don't install them for you.

- OpenShift with **OpenShift Virtualization** (KubeVirt) and **CDI** installed. This
  is the biggest unscoped prerequisite — a cluster-admin must install it **before
  deploy**; the deploy scripts only *check* for the CRDs, they don't install it.
  Follow Red Hat's official install docs:
  [Installing OpenShift Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/installing#installing-virt).
- **OpenShift Dev Spaces** (the deploy script can install it for you).
- At least one **hardware-virtualization (KVM-capable) node** for the device VMs.
  Each Android device runs inside a KubeVirt VM, which needs KVM on its node —
  but you don't label or pin anything: **KubeVirt schedules device VMs onto
  KVM-capable nodes automatically** (the device VM sets no `nodeSelector`). Just
  make sure at least one such node exists. (Deliberately confining device VMs to
  *specific* nodes is an optional hardening choice — see
  [*Before multi-tenant*](#before-multi-tenant--shared-production-use) — not a
  requirement.)
- A default storage class for VM disks.
- The cluster can pull Red Hat base images (`registry.redhat.io`).

**Do this — run the readiness check.** `preflight.sh` has two modes:

```bash
./preflight.sh check      # read-only: verifies login, KVM/virtualization, and
                          # whether Dev Spaces is present
./preflight.sh prepare    # runs check, then (needs cluster-admin) installs the
                          # Dev Spaces operator + a CheCluster if they're missing
```

`prepare` is the one command that installs Dev Spaces for you. `build-and-deploy.sh`
also prompts to install Dev Spaces at deploy time as a fallback, so **pick one** —
run `prepare` up front, or let the deploy script offer it later; you don't need
both. `prepare` does **not** install OpenShift Virtualization — that depends on
your node pool and stays explicit. The
[**Deploy the platform**](#deploy-the-platform-cluster-admin-once) runbook below is the
single canonical order; this section just explains the two preflight modes it references.

<details>
<summary><b>Registries &amp; air-gapped clusters</b></summary>

This platform pulls images from **two different places**, and a
disconnected/registry-restricted cluster has to account for both. Pointers, not a
full air-gapped install guide:

- **Platform images come from `registry.redhat.io`** — the workspace image's UBI
  base (built on-cluster) and the `ose-oauth-proxy` auth-gate image both pull from
  there, so the **global cluster pull secret** must have `registry.redhat.io`
  credentials. On a connected cluster the install pull secret already does; confirm
  with `oc get secret/pull-secret -n openshift-config`. (Red Hat base images are
  the one Prerequisites line above.)
- **redroid is pulled UNAUTHENTICATED from Docker Hub — *inside the KubeVirt
  guest*, not by the cluster.** `device start` bakes a `docker pull
  redroid/redroid:...` into the guest's cloud-init, so the **device VM itself**
  must have egress to Docker Hub (or wherever you mirror it). Two implications: the
  guest needs outbound network (the default device egress policy allows it — see
  *Security & hardening notes*), and on a busy cluster these **anonymous Docker Hub
  pulls hit rate limits**. For anything beyond a demo, mirror redroid into an
  internal registry and point the guest at it.
- **Mirror-to-internal-registry path (disconnected clusters).** Mirror the platform
  images (UBI base + `ose-oauth-proxy`) with `oc mirror` / `oc adm catalog mirror`
  and your `ImageContentSourcePolicy`, the same as any other Red Hat image. For
  redroid, mirror `redroid/redroid:<tag>` into your internal registry, then point
  the guest at that mirror (edit the `REDROID_IMG` values in the `DEVICE_PROFILE`
  case in `device start`, or mirror at the registry level via your
  `ImageContentSourcePolicy`) and ensure the **device VM can reach** that registry
  (egress + any CA the guest must trust). Without this, a disconnected cluster's
  devices never boot, even though the workspace itself starts fine.

</details>

---

## Deploy: what lives where

The [Quick Start](#quick-start-deploy-in-7-steps) block **is** the canonical
runbook — run those seven steps in order (1–3 are cluster prerequisites, 4–7 deploy
the platform). Two things worth knowing:

- Everything the platform owns lives in **one namespace** (`devspace-android-demo`):
  the shared workspace + ws-scrcpy **images** and the provisioner `ClusterRole`. Each
  device lives in its **workspace's** namespace, owned by that workspace.
- **New developer namespace later? Nothing to do.** Che binds the built-in `edit`
  role to the developer in every namespace it provisions (CheCluster
  `user.clusterRoles`) — future namespaces are covered the moment they're created.

<details>
<summary><b>If it snags — self-hosted git host (GitHub Enterprise / self-hosted GitLab / in-cluster Gitea)</b></summary>

The one-liner above (step 7) is all you need when `REPO_URL` is on a git host Che
recognizes (GitHub/GitLab/Bitbucket public or enterprise SaaS). If your repo lives
on a **self-hosted / unrecognized** host — where Che can't fetch the devfile
directly (it guesses a `raw.<host>` URL the wildcard cert doesn't cover) — serve the
devfile from a small in-cluster `devfile-server` instead. This is a **standing**
deployment (one per cluster, see *Footprint*):

| Git host | Recognized? | What you deploy |
|---|---|---|
| GitHub.com, GitLab.com, Bitbucket Cloud, and their enterprise-SaaS hosted offerings | **Recognized** | nothing — zero standing deployment (step 7 one-liner only) |
| Self-hosted GitHub Enterprise Server | **Unrecognized** | the always-on `devfile-server` (sub-procedure below) |
| Self-managed GitLab | **Unrecognized** | the always-on `devfile-server` (sub-procedure below) |
| The in-cluster Gitea (this demo) | **Unrecognized** | the always-on `devfile-server` (sub-procedure below) |

```bash
# a. Stand up the devfile-server Deployment + Route.
oc apply -f samples/devfile-server.yaml -n devspace-android-demo

# b. Load the served devfile as a ConfigMap the server serves. Use the committed
#    samples/served-devfile.yaml — the app's devfile plus a `projects:` clause that
#    clones the app repo. Its committed URL is the published GitHub repo; you're on
#    this path because your repo is SELF-HOSTED, so substitute YOUR clone URL
#    (don't skip this — a wrong URL here means workspaces open empty):
sed 's#https://github.com/serhat-dirik/devspaces-android-sample-app.git#https://<your-git-host>/<your-app-repo>.git#' \
  samples/served-devfile.yaml | oc create configmap mobile-workspace-devfile \
  -n devspace-android-demo --from-file=devfile.yaml=/dev/stdin \
  --dry-run=client -o yaml | oc apply -f -

# c. Point REPO_URL at the SERVED url (no devfilePath) and register as in step 7.
export REPO_URL=https://<mobile-workspace-devfile route host>/devfile.yaml
DEVFILE= ./samples/register-sample.sh
```

See `samples/served-devfile.yaml` for the copy-paste-ready served devfile (set
your repo URL in its `projects:` clause) and `samples/register-sample.sh` for the
exact served-URL form.

</details>

---

## The developer experience

> **Goal:** know what a developer actually does once you've published the app —
> what they see, and the day-2 scripts they lean on.

A developer opens their app from the dashboard catalog. There are **two ways to
run** the app, both always available:

- **Web preview** — the default Run ▶, a fast full-size **browser preview**
  (re-run after edits; for hot reload use the IDE debug launch). This is where most
  develop/test happens; **no device needed**.
- **On the real Android device** — `device run` builds, installs and
  launches on this workspace's **own** on-cluster device; `device screen` opens
  its live screen. The sample app shows *which surface* it's on (distinct colour +
  icon) so the preview tab and the device tab are never confused.

**The device lifecycle belongs to the developer** — deliberately manual, so it
needs no lifecycle RBAC and behaves predictably. The terminal greeting and
`mobile-help` say exactly this; the same commands are in the **Run Task** menu:

| Script | What it does |
|---|---|
| `device start` | **START — run this first.** Creates the device (~2 min with the golden image, ~10 min without); also wakes a stopped one. Idempotent. |
| `device stop` | **STOP when done.** Halts VM + screen, keeps the disk, frees ~4 CPU/4Gi. Workspace sleep does **not** stop the device. |
| `device remove` | **DELETE** the device + disk. (Deleting the workspace also removes it — owner-reference GC.) |
| `device status` | is the device up? what's its screen URL? |
| `device watch` | follow the boot live until the device is ready |
| `device restart` | reboot a frozen device |

The developer-facing README lives in the **sample app repo** (`devspaces-android-sample-app`).

<details>
<summary><b>Device profiles — phone / tablet / older Android</b></summary>

The device form factor is set by the `DEVICE_PROFILE` env, which
`device start` resolves to a redroid image + screen geometry:

| Profile | Resolution | DPI | Android |
|---|---|---|---|
| `phone` (default) | 1080×1920 | 320 | 13 |
| `tablet` | 1600×2560 | 240 | 13 |
| `phone-a12` | 1080×1920 | 320 | 12 |

The default lives in the app devfile's `tools` container env. To switch the
current workspace's device, run in a terminal:

```bash
export DEVICE_PROFILE=tablet
device start
```

The device stays `dev-<workspace>`, owner-referenced to the DevWorkspace — only
the form factor changes; the per-workspace lifecycle is unchanged.

</details>

---

## Resource cost per developer

> **Goal:** size the cluster. Budget **disk for your total developer count** (it
> persists through sleep) and **compute for your concurrently active count**.

Each **active** workspace consumes, in its developer's namespace:

| Component | Default cost | Reclaimed when? |
|---|---|---|
| Device VM (redroid) | **4Gi RAM + 4 vCPU** (`VM_MEM`/`VM_CPU`, overridable) | When the **developer runs `device stop`** (or deletes the device/workspace). Workspace sleep does **not** stop it. |
| Device disk (DataVolume) | **40Gi** | On `device remove` or workspace delete — the disk **persists** across stop/start so the device keeps its state |
| Device screen pod (ws-scrcpy + oauth-proxy) | ~150m CPU + ~320Mi RAM | `device stop` scales it to 0 (restored on the next provision) |
| Dev Spaces workspace pod | per your Dev Spaces sizing | Automatically — Dev Spaces stops it on idle |
| Workspace storage (PVC) | **15Gi per workspace** (`per-workspace` strategy) | On workspace delete — persists so `/projects` + build caches survive sleep |

So a **stopped** device costs only its **40Gi disk**; a **running** device keeps its
4 CPU/4Gi even while the workspace sleeps — the lifecycle is developer-managed, so
tell developers to `device stop` when they're done (the terminal banner does).
Consider namespace **quotas** as the backstop for forgotten devices. On **delete**,
everything goes (owner-reference GC).

> **Storage strategy:** `preflight.sh prepare` sets `pvcStrategy: per-workspace`
> (15Gi each), so every workspace gets its **own** disk — one workspace's Flutter/
> Android build caches (~3Gi Gradle each) can't fill another's. The Dev Spaces
> **default is `per-user`** (one shared PVC for *all* a developer's workspaces), which
> exhausts fast under disk-heavy Android builds ("No space left on device"). Tune
> `claimSize` in `preflight.sh` for your projects.

| Per-platform component | Default cost | When |
|---|---|---|
| `devfile-server` (self-hosted git only) | ~**50m CPU + 64Mi RAM** (limits 200m / 256Mi) | Always-on, but **one per cluster — not per developer**, and only when your git host is self-hosted/unrecognized (see *Footprint*) |

**You'll need to override the VM size?** Per workspace:

```bash
export VM_MEM=6Gi VM_CPU=6   # both above the 4Gi/4-vCPU defaults
device start
```

<details>
<summary><b>Worked example — 10 simultaneously active developers</b></summary>

- ~**40 vCPU + 40Gi RAM** for the device VMs (10 × 4/4Gi).
- ~**1.5 vCPU + 3.2Gi RAM** for the screen pods on top (10 × ~150m / ~320Mi).
- **Workspace pods** are sized by your Dev Spaces configuration, not this platform —
  budget them per your sizing (see the
  [Dev Spaces resource-sizing docs](https://docs.redhat.com/en/documentation/red_hat_openshift_dev_spaces/3.28/html/administration_guide/configuring-devspaces#configuring-the-dev-spaces-resources)).
- So the compute floor is ~**41.5 vCPU + 43.2Gi RAM** plus your workspace pods.
- ~**400Gi standing disk** (10 × 40Gi) — this stays allocated even while those
  workspaces sleep, until the workspaces are deleted.

Budget the disk for your **total** developer count (it persists through sleep);
budget the compute for your expected **concurrently active** count.

</details>

---

## Status & scope

This is a **demo** — it shows the design working end-to-end, but it is **not a
supported product**. Before any real multi-tenant or production use, work through
[*Before multi-tenant / shared production use*](#before-multi-tenant--shared-production-use)
and *Security & hardening notes*. Treat the worked numbers and versions here as a
starting point to size and validate against your own cluster.

### Tested with

| Component | Version |
|---|---|
| OpenShift | 4.20 |
| OpenShift Virtualization (KubeVirt / HCO) | 4.20 |
| OpenShift Dev Spaces | 3.28 (DevWorkspace operator 0.41) |
| Flutter | `stable` channel (Dart bundled) |
| redroid (Android) | 13 (`13.0.0_64only`; profile `phone-a12` uses 12) |

Other recent 4.x releases are likely fine; these are the versions this was
exercised against.

### Two repositories

| Repo | For | Contents |
|---|---|---|
| **This platform repo** | cluster admins | workspace image, on-cluster builds, RBAC, device scripts |
| **`devspaces-android-sample-app`** (one per app) | developers | the Flutter project + a developer devfile + a short README |

A developer only ever clones the **app repo** — the working example is
[`github.com/serhat-dirik/devspaces-android-sample-app`](https://github.com/serhat-dirik/devspaces-android-sample-app),
whose `devfile.yaml` the catalog entry serves. Deploying under your own org? Substitute
your repo URL into `REPO_URL` at step 7 of the Quick Start.

<details>
<summary><b>Footprint — what runs when nobody's working</b></summary>

The platform's **standing** runtime footprint depends entirely on *where your app
repo is hosted*:

- **Recognized git host (GitHub / GitLab / Bitbucket): zero standing deployment.**
  The catalog points straight at the repo and Che fetches the devfile directly.
  Nothing runs except the developers' own (sleep-on-idle) workspaces and devices.
- **Self-hosted / unrecognized git host: one small always-on `devfile-server`.**
  This demo ships an in-cluster Gitea, which Che can't fetch from directly, so a
  tiny `devfile-server` Deployment serves the devfile. It's a **per-platform**
  cost (one for the whole cluster, *not* per developer), ~**50m CPU / 64Mi RAM**
  (limits 200m / 256Mi). See `samples/devfile-server.yaml` and step 4 of *Deploy*.

</details>

<details>
<summary><b>Scale &amp; limits — where it tops out, and what was actually tested</b></summary>

- **First bottleneck: KVM-capable node capacity.** Concurrency is bounded by how
  many device VMs your KVM-capable nodes can hold (each device asks for
  4 vCPU / 4Gi RAM by default — see *Resource cost*); that ceiling is reached
  before anything else. KVM-capable nodes are typically **bare-metal or nested-virt
  instances** — a real cloud cost premium over ordinary worker nodes, so size that
  node-pool line item accordingly. **Storage** (the 40Gi standing disk per device)
  is the next constraint as your *total* developer count grows.
  - **Worked node sizing (illustrative, not a guarantee).** At the 4 vCPU / 4Gi
    device default, a bare-metal node with N vCPU / M Gi RAM holds roughly
    `(N/4)`-ish device VMs, minus node/system overhead (kubelet, OS, the screen
    pods) — so treat the quotient as a ceiling, not a target. Known-good
    bare-metal families to size against are AWS `m5.metal` and `c5.metal` (as
    *examples* — any KVM-capable bare-metal node works); nested-virtualization
    instance types work too, but run slower. Size against your own node spec.
- **Validation evidence (what was actually run).** In the reference environment the
  full single-developer loop was exercised end-to-end: a workspace provisions its
  own device VM, redroid boots, `device run` builds + installs + launches the
  APK, the live `ws-scrcpy` screen renders behind the oauth-proxy gate, and the
  lifecycle holds (workspace sleep → VM halt, wake → resume, delete → owner-reference
  GC). **Concurrency
  is where evidence stops:** it was validated with only a **small number of
  concurrent devices**; beyond the 10-developer worked example (under *Resource
  cost*) the numbers are **modeled, not load-tested**. The ceiling is your
  KVM-capable node capacity — treat the worked numbers as a sizing starting
  point and validate at your target scale before committing a team pilot.
- **Inner-loop speed.** A cold device start is ~**1–2 min** (`device start`
  boots the VM); after that, `adb` runs at near-native redroid speed. Most
  develop/test happens in the no-device web preview, which is immediate. (The
  **first-ever** provision is longer — see *Inner-loop: first provision vs cold
  start* below.)

**Inner-loop: first provision vs cold start**

The ~**1–2 min** figure above is a **cold start** — resuming an already-provisioned
device (VM resume). The **first-ever** provision of a device is realistically much
longer, **several minutes up to ~15 min**, because `device start` does first-
run work that a later cold start skips: the **DataVolume import** of the Ubuntu guest
image, the **VM boot + in-guest setup** (cloud-init: `apt` packages, the `binder`
kernel module), and the **redroid Docker pull** inside the guest. So the first pilot
run of a workspace feels slower than the steady-state number — that's expected.
Subsequent cold starts are the ~**1–2 min** above.

</details>

<details>
<summary><b>What this is not / support</b></summary>

This is a **reference implementation, not a supported product — there is no SLA.**
You own operating and patching it: in particular the **Ubuntu device VM image** and
the **redroid Android image** are yours to keep current (both pull `:latest` here —
pin and patch them for production). See *Security & hardening notes* and *Before
multi-tenant / shared production use* for the full go/no-go list.

</details>

---

## iOS via a remote Mac pool

**iOS is a design sketch — not implemented.** iOS can't run on the cluster (Apple
forbids macOS virtualization off Apple hardware), so the design surfaces a remote Mac
pool into the same IDE: a workspace *would* lease a Mac, build/test over SSH, and
return the `.ipa`. None of that ships here — [`mac-pool/`](mac-pool/README.md) is a
reference sketch, and the Mac pool is external infrastructure you build and operate.
Android works without any of it.

---

## Before multi-tenant / shared production use

> **Goal:** know exactly what's already isolated and what you add before
> productionizing — so you don't over- or under-harden.

This is a reference implementation (see *Status & scope*). **The demo's own model is
already well-isolated:** each developer gets their **own namespace** (Dev Spaces
default `<user>-devspaces`), with per-namespace RBAC, deny-by-default
NetworkPolicies, admin-set quotas, and a per-device VM boundary — so *multiple
developers*, and one developer's *multiple workspaces*, are fine as-is. The items
below are the extra controls to add **before productionizing, or before running
genuinely untrusted / hostile tenants** on a shared cluster — all detailed in
*Security & hardening notes* below:

- [ ] **(Defense-in-depth) Pin device VMs to dedicated nodes for *hostile* multi-tenancy.**
  redroid runs `--privileged` **inside the guest VM** (it needs the `binder` kernel
  module) — so a compromise there is root *in a throwaway VM*, contained by the
  **KVM/QEMU hypervisor**, the same boundary every cloud VM relies on. **The cluster
  side stays unprivileged** (the workspace is `restricted-v2`; the device is a VM,
  not a privileged pod). That VM boundary is sufficient for normal multi-developer
  use. *Only* if you run genuinely untrusted tenant code and want to defend against a
  hypervisor escape do you also pin device VMs onto **dedicated nodes**, so a
  (theoretical) breakout can't reach other tenants' workloads. (*optional; taint +
  toleration + nodeSelector, ~1 day, platform team*)
- [ ] **adb isolation depends on your CNI enforcing NetworkPolicy.** The device
  ports are fenced by deny-by-default NetworkPolicies; that only holds if the CNI
  enforces them. OpenShift's default **OVN-Kubernetes** does. On a CNI that ignores
  NetworkPolicy, adb would be reachable cluster-wide. (*default — just verify
  OVN-Kubernetes enforces NetworkPolicy*)
- [ ] **The redroid and UDI `:latest` images are unpinned.** A documented demo
  trade-off (see *Security & hardening notes*); pin them by digest before
  production. (*~half a day + a bump process*)

---

## Reference: how it's built

The deep technical record below survived 5 rounds of usability QA — collapsed for
the happy path, every word preserved. Open what you need.

<details>
<summary><b>Architecture &amp; why it's built this way</b></summary>

**One device per workspace, bound to the workspace — no controller.** The whole
device lifecycle is driven by the workspace's own devfile events plus a Kubernetes
owner-reference, so there's no extra deployment to run or keep matched to
workspaces:

| Device action | Who / what does it | Mechanism |
|---|---|---|
| start / wake | **the developer** | `device start` (idempotent — creates or wakes) |
| stop (keep disk) | **the developer** | `device stop` (halts VM + screen; workspace sleep does NOT do this) |
| delete | the developer, or **automatic on workspace delete** | `device remove`, or the `ownerReference` from the device to the `DevWorkspace` |

The lifecycle is deliberately **manual**: devfile `postStart`/`preStop` events run as
the workspace *service account*, which has no VM rights (only the developer does, via
the built-in `edit` role) — so automating them would mean granting SAs extra RBAC.
Manual scripts + owner-reference GC keep the model simple and the permissions standard.

The device is named after the workspace (`dev-<workspace>`), so a developer's
multiple workspaces each get their own device with no collisions.

**Why the device is a VM, not an emulator in the workspace.** Android needs the
Linux `binder` driver and a *privileged* container — putting that in the
developer's workspace would mean a privileged developer container. Instead:

- The device runs **redroid** — native Android in a container, on the kernel via
  `binder`. Not a QEMU emulator, so **no `/dev/kvm`, no nested virtualization**,
  near-native speed.
- redroid (privileged, with `binder`) runs **inside a KubeVirt VM** — the VM is
  the privilege boundary.
- The developer's workspace stays an unprivileged `restricted-v2` container; it
  talks to the device over `adb` and provisions/controls it through the
  Kubernetes API (scoped RBAC) — never via host privilege or the OpenShift console.

</details>

<details>
<summary><b>Why Ubuntu for the device VM (Red Hat everywhere else)</b></summary>

OpenShift, OpenShift Virtualization, Dev Spaces, and the workspace image are all
Red Hat. The device VM is the single exception: redroid needs the `binder` kernel
driver, which **RHEL/CentOS Stream ship disabled** and **current Fedora kernels**
are incompatible with. **Ubuntu 22.04 LTS** is redroid's reference platform, so it
backs the device VM only. The developer never sees it — they see an Android device
on `adb`.

</details>

<details>
<summary><b>Repository layout</b></summary>

```
.
├── Dockerfile                 # workspace image (Flutter + Android SDK + adb + scripts)
├── scripts/                   # the `device` CLI + its backing scripts (baked into the image)
│   ├── device                 #   the ONE command developers use: device start|stop|status|…
│   ├── provision-device.sh    #   backs `device start` (create/start/wake device + screen)
│   ├── stop-device.sh         #   backs `device stop` (halt when done; keeps disk)
│   ├── remove-device.sh  restart-device.sh  device-status.sh
│   ├── run-on-device.sh       #   backs `device run` (build + install + launch)
│   ├── open-screen.sh         #   backs `device screen`
│   └── mobile-help            #   cheatsheet (`device help`) + terminal banner
├── openshift/
│   ├── build-and-deploy.sh        # build the workspace image on-cluster + apply RBAC
│   ├── imagestream.yaml / buildconfig.yaml
│   ├── platform-rbac.yaml         # built-in-role bindings + golden-image clone consent
│   ├── prepare-golden-image.sh    # pre-bake Ubuntu+docker+redroid into the golden disk (step 6)
│   ├── image-prewarm.yaml         # OPTIONAL: pre-pull workspace image onto all nodes
│   └── screen/buildconfig.yaml    # the ws-scrcpy (screen) image build
├── samples/                   # register an app in the Dev Spaces catalog
├── preflight.sh
└── mac-pool/                  # iOS design sketch — NOT implemented (remote Mac pool)
```

The sample app lives in its own repo, **`devspaces-android-sample-app`** (cloned
alongside this one) —
[`github.com/serhat-dirik/devspaces-android-sample-app`](https://github.com/serhat-dirik/devspaces-android-sample-app).

</details>

<details>
<summary><b>Security &amp; hardening notes</b></summary>

This runs in a dedicated platform namespace. Hardening applied / remaining:

- **No custom roles — developer permissions are the built-in `edit` role, granted by
  Dev Spaces itself.** By default Che binds developers to a restricted role that lacks
  `virtualmachines`/`datavolumes`/`networkpolicies`; this platform sets CheCluster
  `user.clusterRoles: ["edit"]` so Che instead binds the standard `edit` role in each
  developer's own namespace — automatically, for every future namespace too. KubeVirt/
  CDI aggregate into `edit`, so no device-specific role exists. Scope note: `edit` in
  their own namespace is more than the Che default (review for your posture); it is
  still namespace-confined.
- **Only two RBAC objects ship with the platform, both built-in roles**
  (`platform-rbac.yaml`, applied once): `system:auth-delegator` for the screen's
  oauth-proxy TokenReview (the standard oauth-proxy requirement), and
  `system:image-puller` on the platform namespace so workspaces can pull the shared
  images. (Cleaner still: build the ImageStreams into the globally-pullable
  `openshift` namespace and drop the puller binding.)
- **The device screen (ws-scrcpy) is behind oauth-proxy** — it requires an OpenShift
  login (`--email-domain=*`: any authenticated user; the Route is `reencrypt`, no
  unauthenticated path). It does **not** gate on the workspace owner — a deliberate
  choice, because the owner SAR (`--openshift-sar`) mis-resolves the identity on
  RH-SSO/OIDC clusters. Restrict to the owner only if you solve that identity mapping
  for your IdP.
- **adb is network-isolated, deny-by-default.** adb itself is unauthenticated, so
  the device + screen pods are fenced by NetworkPolicy: an explicit
  `default-deny-ingress` scoped to those pods, plus scoped allows that re-admit
  `dev-<ws>:5555` only from the owning workspace pod and the screen :8443 only
  from the router + owning pod. (A pod that's *selected* by an Ingress policy is
  already deny-by-default; the explicit deny makes that baseline unambiguous and
  defense-in-depth. The workspace pod itself is deliberately not fenced, so Che's
  gateway routes keep working.) Verified: a pod in an unrelated namespace
  connecting to `dev-<ws>:5555` is denied (times out). No cross-namespace
  device takeover. **Prerequisite:** this isolation depends on the cluster CNI
  *enforcing* NetworkPolicy — OpenShift's default **OVN-Kubernetes** does. On a
  CNI that ignores NetworkPolicy, adb would be reachable cluster-wide; for real
  multi-tenant use, confirm enforcement (or move adb behind TLS/authkey).
- **Image inputs are pinned**, including the auth gate: the consumed `ose-oauth-proxy`
  (by **digest**) and `ws-scrcpy` (by digest) references in `device start`,
  the ws-scrcpy git ref + base-image digest (`screen/buildconfig.yaml`), and the
  Ubuntu cloud image SHA256 (CDI checksum). The redroid and UDI `:latest` tags
  remain a documented demo trade-off (redroid runs in the throwaway guest) — pin
  them for production.
  - **To pin redroid for production:** resolve the tag to its digest with
    `oc`/`skopeo`, e.g. `skopeo inspect docker://docker.io/redroid/redroid:13.0.0_64only-latest | jq -r .Digest`,
    then set the digest form (`redroid/redroid@sha256:<digest>`) in the
    `DEVICE_PROFILE` case block of `device start`. For disconnected
    clusters, mirror that digest into an internal registry and point the guest at
    the mirror. Be honest about the cost: this is a **manual pin plus a bump
    process** — you re-resolve and re-set the digest whenever you want a newer
    redroid.
- The privilege lives in **redroid inside the guest VM** (`--privileged`, for
  `binder`); the KVM/QEMU hypervisor is its boundary and the cluster side stays
  unprivileged. That boundary is sufficient for normal multi-developer use — only
  for *hostile* multi-tenancy add dedicated-node isolation as defense-in-depth.

</details>

---

## Cleanup

```bash
oc delete namespace devspace-android-demo     # the platform
oc delete namespace <user>-devspaces          # a developer's workspace + device
```

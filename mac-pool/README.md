# Phase 2 — add iOS (design sketch — NOT implemented)

> **Status: this is a design sketch, not a working feature.** Unlike Android,
> nothing here is turnkey. iOS can't run on the cluster at all (Apple forbids
> macOS virtualization off Apple hardware — see the main README), so it depends
> on a **Mac build pool that you, the customer, must provide and operate as
> external infrastructure**. The bundled `mac.sh` and `devfile-ios-additions.yaml`
> are a **reference** showing how a workspace *would* talk to such a pool — they
> are not a deployable iOS solution. Budget this as its own project, not a flag.

iOS needs real Apple hardware. The shape of the design: you stand up a **Mac
pool** (managed Macs that hand out short-lived build machines) and wire commands
— `build-ios` / `run-ios` — that run on a leased Mac over SSH. The workspace stays
the same; the Mac is an external build helper.

For the why, see the main README's **Architecture & why it's built this way**
section ([../README.md](../README.md)).

## The hard parts (unbuilt — you own these)

The Mac pool is **external infrastructure the customer provides and operates.**
None of the following ships here; each is a real, non-trivial piece of work:

- **A Mac pool with real cost.** On AWS, EC2 Mac instances run on **dedicated
  hosts with a 24-hour minimum allocation** — you pay for a full day per host even
  for a short build, so a pool is materially more expensive than ordinary compute.
  (MacStadium / Orka, Orchard+Tart, Veertu Anka are alternatives with their own
  pricing and operational models.) Sizing, capacity, and on-call are yours.
- **A golden macOS image** with Xcode + command-line tools + simulators + fastlane
  + `sshd`, and **code-signing certificates pulled from a vault into an ephemeral
  keychain at build time** (never baked into the image). Building and maintaining
  this image is ongoing work.
- **A lease protocol** so concurrent workspaces don't collide on a finite set of
  Macs. `mac.sh` sketches the client side; the pool side is yours to run.

## What you'd build on the cluster side

The cluster-side glue is small (the heavy lifting is the Mac pool above). For iOS
the workspace `tools` container also needs `openssh-clients`, `rsync`, `fastlane`,
`jq` and (for EC2 Mac) `awscli` — add them to the workspace image's **`Dockerfile`**
(the repo ships a single `Dockerfile`; there is no `Dockerfile.dev`).

## How it works

`mac.sh` is a **reference script, not a turnkey tool** — it assumes a pool you've
already stood up. As sketched, it leases a Mac, syncs the code (rsync for the inner
loop, git for CI), runs `xcodebuild`/`fastlane`, copies the `.ipa` back to the
workspace volume, and releases the Mac. Every command ensures its own lease, so
start/stop/sleep/wake never breaks it (the Mac is stateless). The `.ipa` goes to
app distribution (TestFlight / App Store / Firebase / MDM), not the cluster.

## Wiring it in

1. Stand up and operate the Mac pool (the hard parts above), then set the env vars
   `mac.sh` expects (see its header).
2. Copy `mac.sh` into your app repo at `scripts/mac.sh` and adapt it to your pool.
3. Merge `devfile-ios-additions.yaml` into your devfile (adds `build-ios`,
   `run-ios`, `lease-mac`, `release-mac`).

Android keeps working unchanged either way. Once — and only once — you've built and
are operating the Mac pool, golden image, and lease protocol, the workspace side is
thin. Until then, iOS here is a design to implement, not a feature to switch on.

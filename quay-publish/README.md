# Publishing the quickstart images (maintainer notes)

This folder is the procedure for publishing pre-built images to quay.io so
people can try the demo without building anything (see the sample-app repo's
"Quick test" section). It is deliberately not linked from the main README —
the platform's essence is that YOUR platform team builds and owns its images;
this is only the try-it shortcut.

## What gets published
| quay.io repo | Content |
|---|---|
| `serhat_dirik/devspaces-mobile-allinone` | the workspace image, copied from a deployed cluster |
| `serhat_dirik/devspaces-ws-scrcpy` | the screen image, same |
| `serhat_dirik/devspaces-android-golden` | the baked golden disk, wrapped as a KubeVirt containerDisk |

Tags: `:latest` + `:<date>`. The date tag exists only so old digests are never
garbage-collected (rollback = `git revert` of the digest pins). Consumers pin
digests; nothing consumes the tags.

## Procedure
1. `oc login` a cluster where the platform is FULLY deployed (steps 4–6 done:
   both images built, golden disk baked).
2. Export the robot credentials and run:
   ```bash
   export QUAY_USER='serhat_dirik+<robot>' QUAY_PASSWORD='<token>'
   ./quay-publish/publish.sh
   ```
   Everything heavy runs in-cluster (temporary Jobs in the platform namespace);
   this machine only needs `oc`.
3. The script ends by rewriting the digest pins in the app repo
   (`devfile-quay.yaml` + `quickstart-cache.sh`) — **review the diff, commit,
   push**. Testers stay on the previous version until that push.

## First-time notes
- Pushing auto-creates the quay repos but they default to **private** — flip
  all three to public in the quay UI once.
- The robot needs write (or repo-create) permission in the quay account.

# Argo CD + server-side apply: zombie containers after `managedFields` compaction

This repo reproduces, end to end on a local [kind](https://kind.sigs.k8s.io/) cluster, a
failure mode described in LinkedIn's engineering post
[*How we scale deployments with a custom GitOps engine*](https://www.linkedin.com/blog/engineering/infrastructure/how-we-scale-deployments-with-a-custom-gitops-engine)
(section "Side-effects of PATCH"):

> When managedFields compaction occurs on these objects, the ownership information of some
> containers may be lost. … the PATCH operation leaves the containers as they are, because
> they appear to be owned externally.

**Result:** a container removed from Git keeps running in the cluster, and Argo CD reports
the Application as `Synced/Healthy`. Argo CD's diff never shows it as drift.

```
==> Result
    NAMESPACE        LIVE CONTAINERS                    ARGO SYNC/HEALTH   OWNERS OF feature-cache
    demo-control     retriever,ranker                   Synced/Healthy     -
    demo-compacted   retriever,ranker,feature-cache     Synced/Healthy     ancient-changes (Update)

    ✔ demo-control: 'feature-cache' was removed, as Git says
    ✘ demo-compacted: 'feature-cache' is still running although it is no longer in Git  <== BUG
    ✘ demo-compacted: ...and Argo CD reports the Application as Synced
```

Tested with Argo CD **v3.6.1** (`quay.io/argoproj/argocd:v3.6.1`) on Kubernetes **v1.37.0**
(`kindest/node:v1.37.0`, kind v0.33.0).

## Quick start

Prerequisites: `docker` (Docker Desktop, OrbStack or colima), `kind`, `kubectl`, `jq`, `git`.

```bash
make repro        # == scripts/run-all.sh: cluster + Argo CD + both scenarios + verdict (~3 min)
make verify       # print the verdict again
make down         # delete the kind cluster and .work/
```

No GitHub access or `argocd` CLI is needed. The scripts serve a local bare Git repo
(`.work/git/manifests.git`) to Argo CD as `file:///repro-git/manifests.git`. They do this by
mounting the directory into the kind node and then into `argocd-repo-server`. They trigger syncs by
writing the Application's `.operation` field.

> colima users: the repo has to be under `$HOME`, because colima only shares that
> directory with its VM by default.

## Background: what the API server actually does

In [`capmanagers.go`](https://github.com/kubernetes/kubernetes/blob/v1.34.0/staging/src/k8s.io/apimachinery/pkg/util/managedfields/internal/capmanagers.go),
the API server keeps at most `DefaultMaxUpdateManagers = 10` `managedFields` entries with
**`operation: Update`**. The cap is checked on every Update. When an object has more than 10
such entries, the API server sorts them by timestamp and **merges the oldest ones** into one
entry named **`ancient-changes`**. That entry holds the union of their field sets.

Three details matter for this bug:

* The cap only counts **Update** entries. `Apply` entries (server-side apply, which is what
  Argo CD uses with `ServerSideApply=true`) are never merged.
* The merged fields are kept, but **the original manager's name is lost**. Any code that
  looks up a specific manager by name stops finding it.
* Every imperative kubectl verb registers its own manager: `kubectl-label`, `kubectl-annotate`,
  `kubectl-patch`, `kubectl-set`, `kubectl-rollout`, `kubectl-edit`, `kubectl-replace`,
  `kubectl` (the scale subresource). So do controllers, such as `kube-controller-manager` on
  `status`, and any tool that passes `--field-manager`. Reaching 11 is easy.

## Root cause in Argo CD

The Argo CD code that depends on a manager's name is the **client-side-apply → server-side-apply
migration**. It runs on every SSA sync (references are for tag `v3.6.1`, commit `94037c4d`):

* `gitops-engine/pkg/sync/sync_context.go:1456`: before applying, `applyObject` calls
  `needsClientSideApplyMigration(t.liveObj, sc.clientSideApplyMigrationManager)`.
* `gitops-engine/pkg/sync/sync_context.go:1341-1354`: that function returns true only when
  an entry has `field.Manager == "kubectl-client-side-apply"` **and**
  `field.Operation == Update`. The manager name defaults to
  `DefaultClientSideApplyMigrationManager` (`gitops-engine/pkg/sync/common/types.go:58`).
  The `argocd.argoproj.io/client-side-apply-migration-manager` annotation can override it.
* `gitops-engine/pkg/sync/sync_context.go:1398`: when the function returns true,
  `csaupgrade.UpgradeManagedFieldsPatch` moves that manager's fields to `argocd-controller`.
  Argo CD then owns the containers and can remove them later.

Once compaction has renamed the `kubectl-client-side-apply` entry to `ancient-changes`, the
lookup misses and the migration is silently skipped:

1. Argo CD's first SSA sync makes `argocd-controller` (Apply) a **co-owner** of
   `feature-cache`. The container's other owner is `ancient-changes` (Update).
2. The container is removed from Git, and Argo CD applies the new manifest. SSA drops
   `argocd-controller`'s claim on the container. `ancient-changes` still owns it, so the
   API server **keeps the container**. This is correct SSA behaviour.
3. Server-side diff (`gitops-engine/pkg/diff/diff.go:172`, `serverSideDiff` /
   `removeWebhookMutation`) works from a dry-run SSA. The dry run predicts the same
   outcome: the container stays. The predicted live state therefore equals the live state,
   and the app is **`Synced` both before and after the sync**. In the control namespace, the
   same Git change shows `OutOfSync` as expected.

The objects that hit this are common. Anything created with client-side `kubectl apply` gets a
`kubectl-client-side-apply` entry: bootstrap scripts, CI, migration tooling, or a human. If that
object then gathers 10 more Update managers before Argo CD adopts it with `ServerSideApply=true`,
it is affected. That is roughly a week of on-call `kubectl label/annotate/rollout restart` on
a busy object.

## What the scripts do

| Script | Purpose |
|---|---|
| `scripts/00-prereqs.sh` | Check that the CLIs and the Docker daemon are available |
| `scripts/01-cluster-up.sh` | Create the kind cluster `argocd-ssa-repro` with `.work/git` mounted at `/repro-git` |
| `scripts/02-install-argocd.sh` | Install Argo CD `$ARGOCD_VERSION` (default `v3.6.1`) and mount `/repro-git` into `argocd-repo-server` |
| `scripts/03-seed-git.sh` | Create the bare repo and commit `manifests/v1` (containers `retriever`, `ranker`, `feature-cache`) |
| `scripts/04-bootstrap-and-inflate.sh` | In two namespaces, create the Deployment with **client-side** `kubectl apply`, then run day-2 kubectl verbs (see below) |
| `scripts/05-create-apps.sh` | Create the `AppProject` and one `Application` per namespace (`ServerSideApply=true`), then sync v1 |
| `scripts/06-remove-container.sh` | Commit `manifests/v2` (`feature-cache` removed) and sync both apps |
| `scripts/verify.sh` | Print the verdict. Exits 0 if the bug reproduced. With `EXPECT_FIXED=1`, exits 0 only if both namespaces are clean, for testing a patch |
| `scripts/run-all.sh` | All of the above. Re-runnable: it reuses the cluster and recreates the demo state |
| `scripts/cluster-down.sh` | Delete the cluster and `.work/` |

The two namespaces get the same treatment except for **how many** managers are added:

| Namespace | Update managers added | `kubectl-client-side-apply` entry at first SSA sync | Outcome |
|---|---|---|---|
| `demo-control` | stays at ≤ 8 | present → Argo CD migrates it | `feature-cache` removed ✔ |
| `demo-compacted` | added until compaction happens (the 11th Update manager) | merged into `ancient-changes` → migration skipped | `feature-cache` remains, app `Synced` ✘ |

None of the kubectl verbs touches the `feature-cache` container. The only thing that keeps it
alive is the ownership it inherited from `kubectl-client-side-apply`.

Sample output of the inflation step:

```
==> demo-compacted: adding field managers until the API server compacts managedFields
    kubectl-label            -> Update managers:  3   kubectl-client-side-apply entry present: yes
    ...
    kubectl-replace          -> Update managers: 10   kubectl-client-side-apply entry present: yes
    migration-orchestrator   -> Update managers: 10   kubectl-client-side-apply entry present: NO

    owners of container 'feature-cache' in demo-control:   kubectl-client-side-apply (Update)
    owners of container 'feature-cache' in demo-compacted: ancient-changes (Update)
```

## Poking at it manually

```bash
kubectl --context kind-argocd-ssa-repro -n demo-compacted get deploy ranker -o yaml --show-managed-fields
kubectl --context kind-argocd-ssa-repro -n argocd get app ranker-demo-compacted -o yaml
```

## Possible directions for a fix (for discussion)

* When the configured CSA manager is missing but an `ancient-changes` entry exists, Argo CD
  could treat that as "migration state unknown". It could then surface a warning or condition,
  or offer an opt-in to also migrate `ancient-changes`. Migrating it by default would be
  risky, because the entry can also hold fields from unrelated managers.
* Server-side diff could flag fields that are missing from the desired state but still live
  only because an `Update` manager owns them. This is the "zombie" case, and today it is
  invisible to the user.
* Documentation: tell users to adopt CSA-created objects with SSA *early*. Alternatively, they
  can run the migration themselves (`kubectl apply --server-side` with the CSA manager) before
  the object gathers more than 10 Update managers.

# Argo CD + server-side apply: fields deleted from Git silently survive in the cluster

## Starting point

This repo started from the LinkedIn Engineering blog post
[*How we scale deployments with a custom GitOps engine*](https://www.linkedin.com/blog/engineering/infrastructure/how-we-scale-deployments-with-a-custom-gitops-engine)
by **Ramesh G. Iyer**, who also wrote this test bed. Its "Side-effects of PATCH" section describes a
problem LinkedIn hit in production while running Argo CD with server-side apply at scale:

> When managedFields compaction occurs on these objects, the ownership information of some
> containers may be lost. … the PATCH operation leaves the containers as they are, because
> they appear to be owned externally.

At LinkedIn, Argo CD creates every object with server-side apply. Afterwards, operators,
controllers and on-call engineers mitigating incidents change the objects with kubectl. Later, a
field is deleted from Git, and Argo CD leaves it in the cluster.

This repo reproduces that, end to end, on a local [kind](https://kind.sigs.k8s.io/) cluster. It also
pins down the mechanism more precisely than the post does. Argo CD loses ownership **at the moment
kubectl changes the field's value**, not at compaction. Compaction only replaces the real owner's
name with `ancient-changes`, which hides who changed the field and when.

**The danger: Argo CD's desired-state generation leaves the object drifted, silently.** After the
incident, Argo CD correctly shows `OutOfSync`. Then the Git commit that deletes the field flips the
app to `Synced`, **without any sync and with the drifted value still live**. The following sync
succeeds and changes nothing. Nothing in Argo CD's UI or status shows that the cluster no longer
matches Git.

**Interactive walkthrough:** <https://rameshgi.github.io/argocd-ssa-managedfields-repro/> (source:
[`docs/index.html`](docs/index.html)). Click through the timeline one change at a time. Three panels
show the manifest in Git, the object in the cluster, and the field managers with how many fields each
one owns. For Argo CD steps, a strip shows how Argo CD builds the desired state and applies it. Every
value comes from the captured run.

**Result:**

```
==> Result: Git no longer sets spec.template.spec.containers[name=retriever].resources.limits.cpu
    NAMESPACE        LIVE VALUE   ARGO SYNC/HEALTH   OWNER OF THE FIELD
    demo-drift       2            Synced/Healthy     kubectl-set (Update)
    demo-resync      <absent>     Synced/Healthy
    demo-compacted   2            Synced/Healthy     ancient-changes (Update)

    ✘ demo-drift: retriever still runs with limits.cpu=2, which is not in Git, and Argo CD says Synced/Healthy  <== SILENT DRIFT
    ✔ demo-resync: CPU limit removed, as Git says
    ✘ demo-compacted: retriever still runs with limits.cpu=2, which is not in Git, and Argo CD says Synced/Healthy  <== SILENT DRIFT
```

Tested with Argo CD **v3.6.1** (`quay.io/argoproj/argocd:v3.6.1`) on Kubernetes **v1.37.0**
(`kindest/node:v1.37.0`, kind v0.33.0).

## The scenario

Every namespace runs the same Deployment, `ranker`, with two containers. Argo CD creates it from
Git with `ServerSideApply=true`.

1. **Argo CD creates the object.** `argocd-controller` (operation `Apply`) owns every field in the
   manifest, including `retriever`'s `resources.limits.cpu: 500m`.
2. **Incident.** On-call runs
   `kubectl set resources deploy/ranker -c retriever --limits=cpu=2`. Argo CD shows `OutOfSync`.
3. **Git deletes `retriever`'s CPU limit**, a common cleanup ("don't set CPU limits").
4. **Argo CD syncs.**

| Namespace | Between steps 2 and 3 | After step 3 (no sync yet) | After step 4 |
|---|---|---|---|
| `demo-drift` | nothing | **Synced**, `limits.cpu=2` live | **Synced/Healthy**, `limits.cpu=2` live ✘ |
| `demo-resync` (control) | Argo CD syncs v1 again (redeploy or self-heal) | OutOfSync | CPU limit removed ✔ |
| `demo-compacted` | routine day-2 operations push the object past 10 `Update` managers | **Synced**, `limits.cpu=2` live | **Synced/Healthy**, `limits.cpu=2` live, owner `ancient-changes` ✘ |

## Quick start

Prerequisites: `docker` (Docker Desktop, OrbStack or colima), `kind`, `kubectl`, `jq`, `git`.

```bash
make repro        # == scripts/run-all.sh: cluster + Argo CD + all scenarios + verdict (~4 min)
make verify       # print the verdict again
make timeline     # regenerate the README timeline and docs/snapshots.js from the last run
make down         # delete the kind cluster and .work/
```

No GitHub access or `argocd` CLI is needed. The scripts serve a local bare Git repo
(`.work/git/manifests.git`) to Argo CD as `file:///repro-git/manifests.git`. They do this by
mounting the directory into the kind node and then into `argocd-repo-server`. They trigger syncs by
writing the Application's `.operation` field.

> colima users: the repo has to be under `$HOME`, because colima only shares that
> directory with its VM by default.

## Why it happens

**1. A kubectl change takes the field away from Argo CD.** In
[server-side apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/), every write
records which manager owns which fields in `metadata.managedFields`. An imperative write (`kubectl
set`, `edit`, `patch`, `replace`, `scale`, …) is an `Update` operation. When an `Update` changes a
field's value, the API server makes the writer the owner of that field and removes it from every
other manager's set. After the incident, `kubectl-set` owns `limits.cpu`, and `argocd-controller`
no longer does.

**2. A server-side apply only deletes fields the applier owns.** When Argo CD applies a manifest
that no longer contains `limits.cpu`, the API server deletes the field only if `argocd-controller`
owns it. `kubectl-set` owns it, so it stays. This is documented server-side-apply behaviour, and
it is exactly why a PATCH cannot guarantee "the object equals Git".

**3. Argo CD's desired state is "whatever server-side apply would produce", not Git.** With
`ServerSideApply=true`, Argo CD enables server-side diff
([`controller/state.go:1184`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/controller/state.go#L1184)).
Server-side diff computes the predicted object with a dry-run server-side apply of the Git manifest
([`gitops-engine/pkg/diff/diff.go:177`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/diff/diff.go#L177))
and compares it with the live object. The dry run keeps `limits.cpu: 2`, so prediction and live are
equal. In addition,
[`diff.go:286-290`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/diff/diff.go#L286-L290)
explicitly drops removals of fields `argocd-controller` doesn't own ("SSA only removes fields the
applier owned … so it is not a diff"). The result is `Synced`. The sync
([`sync_context.go:1485`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/sync/sync_context.go#L1485))
sends the same PATCH and gets the same result.

**4. When it heals by accident.** Argo CD applies with `force-conflicts`
([`resource_ops.go:496`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/utils/kube/resource_ops.go#L496)).
Any sync that still has the field in Git takes ownership back (`demo-resync`). The drift therefore
survives exactly when the *next* change to that field in Git is its deletion. That is common in
production: self-heal is often off, deployments go through approvals, and incident changes are
rarely reverted before the next deployment.

**5. Compaction hides the evidence.** The API server keeps at most 10 `managedFields` entries with
`operation: Update`
([`capmanagers.go`](https://github.com/kubernetes/kubernetes/blob/v1.37.0/staging/src/k8s.io/apimachinery/pkg/util/managedfields/internal/capmanagers.go),
[`DefaultMaxUpdateManagers = 10`](https://github.com/kubernetes/kubernetes/blob/v1.37.0/staging/src/k8s.io/apimachinery/pkg/util/managedfields/internal/fieldmanager.go#L35),
unchanged since at least v1.34). Beyond that, it merges the oldest entries into one named
`ancient-changes`. Busy production objects reach that quickly: status writers, controllers and every
kubectl verb each count as a separate manager. The outcome is unchanged (`demo-compacted` =
`demo-drift`), but the object no longer records who set the value or when. That makes the drift hard
to diagnose.

## Timeline: how the field survives its deletion

<!-- timeline:start -->
Each block below is a snapshot of the live `demo-drift/ranker` Deployment, captured by
`scripts/run-all.sh` and rendered by `scripts/render-timeline.sh`. Expand a step to see
`retriever`'s resources and `metadata.managedFields` at that moment.

<details open>
<summary><b>Step 1 · Argo CD creates the Deployment with server-side apply</b> — Argo CD: <code>Synced/Healthy</code> · live <code>limits.cpu</code>: <code>500m</code></summary>

Argo CD syncs `manifests/v1` with `ServerSideApply=true`. `argocd-controller` (operation `Apply`) owns every
field in the manifest, including `retriever`'s `limits.cpu: 500m`.

```diff
# live: containers[name=retriever].resources   ('+' = in the cluster but NOT in Git v1)
  resources:
    requests: {cpu: 10m, memory: 16Mi}
    limits:
      cpu: 500m
      memory: 64Mi
```

**managedFields** (`demo-drift`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| **argocd-controller** | Apply | 06:12:35 | **yes** | 17 |
| kube-controller-manager | Update (`status`) | 06:12:35 | — | 19 |

</details>

<details>
<summary><b>Step 2 · Incident: on-call raises the CPU limit with kubectl</b> — Argo CD: <code>OutOfSync/Progressing</code> · live <code>limits.cpu</code>: <code>2</code></summary>

`kubectl set resources deploy/ranker -c retriever --limits=cpu=2`. kubectl sends an **Update** that changes the value, and the API server moves ownership of that
field to `kubectl-set`. `argocd-controller` no longer owns it. Argo CD correctly reports **OutOfSync**, because Git
still says `500m`.

```diff
# live: containers[name=retriever].resources   ('+' = in the cluster but NOT in Git v1)
  resources:
    requests: {cpu: 10m, memory: 16Mi}
    limits:
      cpu: 2
      memory: 64Mi
```

**managedFields** (`demo-drift`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 06:12:35 | — | 16 |
| kube-controller-manager | Update (`status`) | 06:12:51 | — | 20 |
| **kubectl-set** | Update | 06:12:51 | **yes** | 1 |

</details>

<details>
<summary><b>Step 3 · Git deletes the CPU limit, and Argo CD flips to Synced without syncing</b> — Argo CD: <code>Synced/Healthy</code> · live <code>limits.cpu</code>: <code>2</code></summary>

The team deletes `retriever`'s CPU limit from Git (`manifests/v2`). Argo CD's server-side diff
([`diff.go:177`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/diff/diff.go#L177)) runs a dry-run server-side apply of v2. That dry run
keeps every field `argocd-controller` doesn't own, so it predicts `limits.cpu: 2` stays. The prediction equals live,
and [`diff.go:286-290`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/diff/diff.go#L286-L290) explicitly drops removals of fields
Argo CD doesn't own. The app goes from **OutOfSync to Synced**, although nothing in the cluster changed and the
live value still differs from Git.

```diff
# live: containers[name=retriever].resources   ('+' = in the cluster but NOT in Git v2)
  resources:
    requests: {cpu: 10m, memory: 16Mi}
    limits:
+     cpu: 2
      memory: 64Mi
```

**managedFields** (`demo-drift`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 06:12:35 | — | 16 |
| kube-controller-manager | Update (`status`) | 06:12:51 | — | 19 |
| **kubectl-set** | Update | 06:12:51 | **yes** | 1 |

<details><summary>Same moment in <code>demo-resync</code> (Argo CD: <code>OutOfSync/Healthy</code>, live <code>limits.cpu</code>: <code>500m</code>)</summary>

In `demo-resync`, Argo CD re-synced v1 *before* this commit. With `force-conflicts` it took `limits.cpu` back
(value `500m`, owner `argocd-controller`). The dry run therefore predicts the field is removed, and the app correctly
shows **OutOfSync**.

```diff
# live: containers[name=retriever].resources   ('+' = in the cluster but NOT in Git v2)
  resources:
    requests: {cpu: 10m, memory: 16Mi}
    limits:
+     cpu: 500m
      memory: 64Mi
```

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| **argocd-controller** | Apply | 06:12:54 | **yes** | 17 |
| kube-controller-manager | Update (`status`) | 06:12:55 | — | 19 |

</details>

</details>

<details>
<summary><b>Step 4 · Argo CD syncs v2: the sync succeeds, and the CPU limit stays</b> — Argo CD: <code>Synced/Healthy</code> · live <code>limits.cpu</code>: <code>2</code></summary>

Argo CD applies v2 as a server-side-apply PATCH
([`sync_context.go:1485`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/sync/sync_context.go#L1485)). The API server deletes a field
only when the applier owns it, and `kubectl-set` owns `limits.cpu`. The sync **Succeeds**, the app is
**Synced/Healthy**, and `retriever` keeps running with a 2-core CPU limit that exists nowhere in Git.

```diff
# live: containers[name=retriever].resources   ('+' = in the cluster but NOT in Git v2)
  resources:
    requests: {cpu: 10m, memory: 16Mi}
    limits:
+     cpu: 2
      memory: 64Mi
```

**managedFields** (`demo-drift`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 06:12:35 | — | 16 |
| kube-controller-manager | Update (`status`) | 06:12:51 | — | 19 |
| **kubectl-set** | Update | 06:12:51 | **yes** | 1 |

<details><summary>Same moment in <code>demo-resync</code> (Argo CD: <code>Synced/Healthy</code>, live <code>limits.cpu</code>: <code>none</code>)</summary>

`argocd-controller` owned the field again, so the sync deletes it, as Git says.

```diff
# live: containers[name=retriever].resources   ('+' = in the cluster but NOT in Git v2)
  resources:
    requests: {cpu: 10m, memory: 16Mi}
    limits:
      memory: 64Mi
```

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 06:13:21 | — | 16 |
| kube-controller-manager | Update (`status`) | 06:13:22 | — | 19 |

</details>

</details>

<details>
<summary><b>Step 5 · The same outcome after managedFields compaction: the owner is now anonymous</b> — Argo CD: <code>Synced/Healthy</code> · live <code>limits.cpu</code>: <code>2</code></summary>

In `demo-compacted`, routine day-2 operations (labels, annotations, `rollout restart`, `scale`, `edit`, `replace`,
controllers) pushed the object past 10 `Update` managers before Git changed. The API server merged the oldest
entries, including `kubectl-set`, into **`ancient-changes`**. The result is the same silent drift, but nothing in
the object says who set the value or when.

```diff
# live: containers[name=retriever].resources   ('+' = in the cluster but NOT in Git v2)
  resources:
    requests: {cpu: 10m, memory: 16Mi}
    limits:
+     cpu: 2
      memory: 64Mi
```

**managedFields** (`demo-compacted`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 06:12:46 | — | 16 |
| **ancient-changes** | Update | 06:12:58 | **yes** | 2 |
| kubectl-annotate | Update | 06:12:59 | — | 1 |
| kubectl-patch | Update | 06:13:00 | — | 1 |
| kubectl-rollout | Update | 06:13:02 | — | 1 |
| kubectl-edit | Update | 06:13:05 | — | 1 |
| kubectl-replace | Update | 06:13:06 | — | 1 |
| hpa-controller | Update | 06:13:07 | — | 1 |
| kube-controller-manager | Update (`status`) | 06:13:09 | — | 19 |
| migration-orchestrator | Update | 06:13:09 | — | 1 |
| cost-attribution-bot | Update | 06:13:10 | — | 1 |

</details>

<details>
<summary><b>Step 6 · Contrast: the same sync as a PUT (<code>Replace=true</code>)</b> — Argo CD: <code>Synced/Healthy</code> · live <code>limits.cpu</code>: <code>none</code></summary>

Argo CD's existing `Replace=true` sync option writes the object with a PUT. A PUT replaces the whole object and never
consults `managedFields`, so the drifted CPU limit is gone. Argo CD sends the manifest exactly as written, though, so
it also wipes fields other managers set: `replicas` and the labels added during day-2 operations. See
[the proposed fix](#proposed-fix-authoritative-put-instead-of-patch) for how a PUT-based sync keeps them.

```diff
# live: containers[name=retriever].resources   ('+' = in the cluster but NOT in Git v2)
  resources:
    requests: {cpu: 10m, memory: 16Mi}
    limits:
      memory: 64Mi
```

**managedFields** (`demo-compacted`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 06:12:46 | — | 16 |
| argocd-application-controller | Update | 06:13:32 | — | 1 |
| kube-controller-manager | Update (`status`) | 06:13:33 | — | 19 |

</details>

<!-- timeline:end -->

## What the scripts do

| Script | Purpose |
|---|---|
| `scripts/00-prereqs.sh` | Check that the CLIs and the Docker daemon are available |
| `scripts/01-cluster-up.sh` | Create the kind cluster `argocd-ssa-repro` with `.work/git` mounted at `/repro-git` |
| `scripts/02-install-argocd.sh` | Install Argo CD `$ARGOCD_VERSION` (default `v3.6.1`) and mount `/repro-git` into `argocd-repo-server` |
| `scripts/03-seed-git.sh` | Create the bare repo and commit `manifests/v1` |
| `scripts/04-create-apps.sh` | Create the `AppProject` and one `Application` per namespace (`ServerSideApply=true`). Argo CD creates the Deployments by syncing v1 |
| `scripts/05-incident.sh` | Run `kubectl set resources … --limits=cpu=2` in every namespace. Then `demo-resync` re-syncs v1, and `demo-compacted` gets routine day-2 kubectl operations until the API server compacts `managedFields` |
| `scripts/06-git-drop-field.sh` | Commit `manifests/v2` (CPU limit deleted) and record what Argo CD reports before any sync |
| `scripts/07-sync.sh` | Sync v2 in every namespace |
| `scripts/verify.sh` | Print the verdict. Exits 0 if the bug reproduced. With `EXPECT_FIXED=1`, exits 0 only if every namespace is clean, for testing a patch |
| `scripts/08-replace-sync.sh` | Contrast: re-sync `demo-compacted` with `Replace=true` (PUT). The drifted field is removed, but fields set by other managers are wiped too |
| `scripts/render-timeline.sh` | Regenerate the [timeline](#timeline-how-the-field-survives-its-deletion) and `docs/snapshots.js` (data for the interactive page) from `.work/snapshots/` |
| `scripts/run-all.sh` | All of the above. Re-runnable: it reuses the cluster and recreates the demo state |
| `scripts/cluster-down.sh` | Delete the cluster and `.work/` |

## Poking at it manually

```bash
kubectl --context kind-argocd-ssa-repro -n demo-drift get deploy ranker -o yaml --show-managed-fields
kubectl --context kind-argocd-ssa-repro -n argocd get app ranker-demo-drift -o yaml
```

## Related paths to the same silent drift

While building this repo we also confirmed two narrower paths. Neither is scripted here any more;
commit [`93bd972`](https://github.com/rameshgi/argocd-ssa-managedfields-repro/tree/93bd972) has a
scripted version of the second.

* **A container someone else (re)created.** A container's name is its list key, so whoever creates
  the list item owns it. Argo CD removes a container it created even if kubectl changed every other
  field in it. If an on-call engineer *removes and re-adds* a container, the new item belongs to
  kubectl. Deleting it from Git then leaves the whole container running, and Argo CD shows `Synced`.
* **Objects first created by client-side `kubectl apply`.** Argo CD migrates the
  `kubectl-client-side-apply` entry to itself on its first server-side-apply sync
  ([`sync_context.go:1341`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/sync/sync_context.go#L1341-L1354)).
  If compaction has already renamed that entry to `ancient-changes`, the migration is skipped, and
  containers later deleted from Git survive.

All of these paths have the same root: with a PATCH, what gets deleted depends on the object's
ownership history, not on Git.

## Proposed fix: authoritative PUT instead of PATCH

A server-side-apply PATCH only removes a field when the applier owns it. Whether a field Git no
longer contains is deleted therefore depends on `managedFields` bookkeeping. Any imperative change
silently rewrites that bookkeeping, and compaction erases its history. As long as the sync is a
PATCH, Argo CD can neither guarantee nor even detect that the object matches Git.

The engine described in the [blog post](https://www.linkedin.com/blog/engineering/infrastructure/how-we-scale-deployments-with-a-custom-gitops-engine)
takes a different approach: **no PATCH, only PUT**. Each deployment is authoritative for the parts
of the object it owns, and the object is written with full-replacement semantics. Applied to Argo CD,
a sync would:

1. **Render the desired object** from Git, exactly as today.
2. **Reconcile externally managed fields from the live object.** Some fields are deliberately owned
   by something other than Git: `spec.replicas` under an HPA, labels or annotations added by
   other controllers, fields injected by webhooks. These are declared up front, and their *live*
   values are copied into the desired object. Everything else comes from Git.
3. **PUT the result**, guarded by the live object's `resourceVersion`. Fields that are not in the
   desired object, such as a CPU limit deleted from Git, are gone after the write, whoever
   `managedFields` says owns them.
4. **On `409 Conflict`, re-read the live object, recompute step 2 and retry** with exponential
   backoff. A concurrent writer is never silently overwritten, and the deployment never acts on a
   stale view.

With this design the outcome no longer depends on `managedFields`: the object equals Git plus the
explicitly declared external fields. The diff becomes honest too, because desired state is no longer
"whatever a server-side apply would leave behind". That is the declarative contract users expect
from GitOps.

**Evidence from this repo** (step 6 of the [timeline](#timeline-how-the-field-survives-its-deletion),
`scripts/08-replace-sync.sh`): Argo CD already has a PUT path, the `Replace=true` sync option
(`kubectl replace`). Re-syncing `demo-compacted` with it removes the drifted CPU limit right away:

```
before: limits.cpu=2  replicas=2  labels=app,cost-center,team
after:  limits.cpu=<absent>  replicas=1  labels=app
```

It also shows why step 2 is essential. `Replace=true` PUTs the Git manifest exactly as written, so
it also wipes everything other managers set: `replicas` (2 → 1) and the labels added during day-2
operations. The missing piece in Argo CD is therefore not the PUT itself, but reconciling the
declared external fields before the PUT, plus the conflict-retry loop. Together they make a PUT
safe to use as the default way to sync.

## License

[Apache License 2.0](LICENSE), the same license as Argo CD. Copyright 2026 Ramesh G. Iyer.

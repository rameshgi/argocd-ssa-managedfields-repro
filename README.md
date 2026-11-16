# Argo CD + server-side apply: what Git deletes can silently survive in the cluster

## Starting point

This test bed started from the LinkedIn Engineering blog post
[*How we scale deployments with a custom GitOps engine*](https://www.linkedin.com/blog/engineering/infrastructure/how-we-scale-deployments-with-a-custom-gitops-engine)
by **Ramesh G. Iyer**, who also wrote this test bed. Its "Side-effects of PATCH" section describes
containers in multi-container pods that survive their removal from the manifest when Argo CD syncs
with server-side apply:

> When managedFields compaction occurs on these objects, the ownership information of some
> containers may be lost. … the PATCH operation leaves the containers as they are, because
> they appear to be owned externally.

The post attributes the loss to compaction. This test bed shows that ownership moves earlier, when
kubectl changes the field or re-creates the container. Compaction then hides who owns the field, which is what made the
production case hard to diagnose. The post itself notes that this "is not an Argo CD issue per se".
The test bed reproduces the mechanism behind that symptom, end to end, on a local
[kind](https://kind.sigs.k8s.io/) cluster, for both a single field and a whole container.

**The danger: Argo CD's diff hides the drift.** Once Git deletes something kubectl changed, the live
object no longer matches Git, and Argo CD still reports `Synced/Healthy` both before and after the
sync. Nothing in its UI or status shows the difference.

**Interactive walkthrough:** <https://rameshgi.github.io/argocd-ssa-managedfields-repro/> (source:
[`docs/index.html`](docs/index.html)). Click through the timeline one change at a time. Three panels
show the manifest in Git, the object in the cluster, and the field managers with how many fields each
one owns. For Argo CD steps, a strip shows how Argo CD builds the desired state and applies it. Every
value comes from the captured run.

**Result** (summarised from `scripts/verify.sh`, after Argo CD synced v2 everywhere):

| Namespace | Deleted in Git | Still live | Argo CD | Owner in `managedFields` | Verdict |
|---|---|---|---|---|---|
| `demo-drift` | `retriever` `limits.cpu` | `2` | Synced/Healthy | `kubectl-set` (Update) | ✘ silent drift |
| `demo-resync` (control) | `retriever` `limits.cpu` | — | Synced/Healthy | — | ✔ removed |
| `demo-compacted` | `retriever` `limits.cpu` | `2` | Synced/Healthy | `ancient-changes` (Update) | ✘ silent drift, owner hidden (later removed by the PUT in step 08) |
| `demo-put` | `retriever` `limits.cpu` | `2` | Synced/Healthy | `kubectl-set` (Update) | ✘ silent drift (later removed by the PUT in step 08) |
| `demo-container` | container `feature-cache` | running | Synced/Healthy | `kubectl-patch` (Update) | ✘ silent drift |

| Component | Version |
|---|---|
| Argo CD | v3.6.1 (`quay.io/argoproj/argocd:v3.6.1`) |
| Kubernetes | v1.37.0 (`kindest/node:v1.37.0`) |
| kind | v0.33.0 |

## The scenarios

Every namespace runs the same Deployment, `ranker`, with three containers (`retriever`, `ranker`,
`feature-cache`). Argo CD creates it from Git with `ServerSideApply=true`, so `argocd-controller`
(operation `Apply`) owns every field in the manifest. Then:

| Namespace | Incident (kubectl) | Before the Git change | Git change | After the Argo CD sync |
|---|---|---|---|---|
| `demo-drift` | `kubectl set resources … -c retriever --limits=cpu=2` | — | delete `retriever`'s CPU limit | limit stays, **Synced** |
| `demo-resync` | same | Argo CD syncs v1 again (redeploy or self-heal) | same | limit removed ✔ |
| `demo-compacted` | same | routine day-2 operations push the object past 10 `Update` managers | same | limit stays, **Synced**, owner `ancient-changes` |
| `demo-put` | same | day-2 `scale` and labels, declared in `ignoreDifferences` | same | limit stays, **Synced**; step 08 re-syncs with a PUT |
| `demo-container` | remove the `feature-cache` container, then add it back | — | delete the `feature-cache` container | container stays, **Synced** |

| Moment | `demo-drift` | `demo-resync` | `demo-container` |
|---|---|---|---|
| after the incident | OutOfSync (correct) | OutOfSync (correct) | Synced (the re-added spec matches Git) |
| after the Git change, before any sync | **Synced**, drift live | OutOfSync (correct) | **Synced**, drift live |
| after the sync | **Synced/Healthy**, drift live | Synced, clean | **Synced/Healthy**, drift live |

## Quick start

Prerequisites: `docker` (Docker Desktop, OrbStack or colima), `kind`, `kubectl`, `jq`, `git`.

| Command | What it does |
|---|---|
| `make repro` | `scripts/run-all.sh`: cluster, Argo CD, all scenarios, verdict, PUT contrast, timeline (~5 min) |
| `make verify` | print the verdict of the server-side-apply sync again. For `demo-compacted` and `demo-put`, which step 08 later cleans with a PUT, it reads the state recorded right after that sync and notes the current state, so the verdict matches `make repro` |
| `make timeline` | regenerate the README timeline and `docs/snapshots.js` from the last run |
| `make down` | delete the kind cluster and `.work/` |

No GitHub access or `argocd` CLI is needed. The scripts serve a local bare Git repo
(`.work/git/manifests.git`) to Argo CD as `file:///repro-git/manifests.git`. They do this by
mounting the directory into the kind node and then into `argocd-repo-server`. They trigger syncs by
writing the Application's `.operation` field. colima users: the repo has to be under `$HOME`,
because colima only shares that directory with its VM by default.

## Why it happens

| # | What happens | Source |
|---|---|---|
| 1 | **A kubectl change takes ownership away from Argo CD.** Imperative writes (`kubectl set`, `edit`, `patch`, `replace`, `scale`, …) are `Update` operations. When an `Update` changes a field's value, the API server makes the writer that field's owner and removes it from every other manager. | [Server-side apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/) |
| 2 | **Whoever creates a list item owns it.** A container's name is its list key. If kubectl removes a container and adds it back, the new item belongs to kubectl, and Argo CD owns nothing in it. | `demo-container` (timeline B) |
| 3 | **A server-side apply only deletes what the applier owns.** When Argo CD applies a manifest without the field or container, the API server keeps it, because `argocd-controller` doesn't own it. | [Server-side apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/), [`sync_context.go:1485`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/sync/sync_context.go#L1485) |
| 4 | **Argo CD's diff predicts with the same server-side apply.** With `ServerSideApply=true`, Argo CD uses server-side diff. It predicts the object with a dry-run server-side apply of the Git manifest and compares that with live. The dry run keeps what Argo CD doesn't own, so prediction and live are equal: `Synced`. | [`controller/state.go:1184`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/controller/state.go#L1184), [`diff.go:177`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/diff/diff.go#L177) |
| 5 | **It heals only by accident.** Argo CD applies with `force-conflicts`, so a sync that still has the field in Git takes it back (`demo-resync`). The drift survives when the next Git change to that field is its deletion. That is common when self-heal is off and deployments go through approvals. | [`resource_ops.go:496`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/utils/kube/resource_ops.go#L496) |
| 6 | **Compaction hides the evidence.** The API server keeps at most 10 `Update` entries and merges the oldest into `ancient-changes` (unchanged since at least v1.34). The outcome is the same, but the object no longer records who changed the field or when. | [`capmanagers.go`](https://github.com/kubernetes/kubernetes/blob/v1.37.0/staging/src/k8s.io/apimachinery/pkg/util/managedfields/internal/capmanagers.go), [`fieldmanager.go:35`](https://github.com/kubernetes/kubernetes/blob/v1.37.0/staging/src/k8s.io/apimachinery/pkg/util/managedfields/internal/fieldmanager.go#L35) |

## Prior reports

| Reference | What it says | Relation to this test bed |
|---|---|---|
| [argoproj/argo-cd#18251](https://github.com/argoproj/argo-cd/issues/18251) | "server-side-diff with server-side-apply not applying changes" (open). A maintainer couldn't reproduce it. Later commenters reproduced it when helm co-owned the fields. | Same mechanism (another manager owns the field). This test bed gives a minimal, scripted reproduction with kubectl. |
| [argoproj/argo-cd#7951](https://github.com/argoproj/argo-cd/issues/7951) | A maintainer explains that changes made with `kubectl edit` aren't reported, because Argo CD and `kubectl diff` "assume that change was performed by a controller". | The designed behaviour behind step 4 of "Why it happens". |
| [Best practices: Leaving Room For Imperativeness](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/#leaving-room-for-imperativeness) | Argo CD deliberately leaves room for imperative changes to fields it doesn't manage. | Explains why the behaviour is intended. The gap shown here: the field *was* in Git, and its deletion from Git is silently not applied. |
| The blog post | "This is not an Argo CD issue per se." | The framing used here: Argo CD reports `Synced` when the object doesn't match Git. |

## Timeline

<!-- timeline:start -->
Each block below is a snapshot of the live Deployment, captured by `scripts/run-all.sh` and rendered
by `scripts/render-timeline.sh`. Expand a step to see what Git says, what is live, and
`metadata.managedFields` at that moment.

### A. A field changed with kubectl (`demo-drift`)

<details open>
<summary><b>Step 1 · Argo CD creates the Deployment with server-side apply</b> — Argo CD: <code>Synced/Healthy</code> · live <code>limits.cpu: 500m</code></summary>

Argo CD syncs `manifests/v1` with `ServerSideApply=true`. `argocd-controller` (operation `Apply`) owns every field in
the manifest, including `retriever`'s `limits.cpu`.

Last sync operation: revision `20c2f4bf`, Succeeded, finished `07:05:34`, options `ServerSideApply=true`.

| | Git | Live | Owner in `managedFields` |
|---|---|---|---|
| `retriever` `limits.cpu` | 500m | 500m | `argocd-controller` (Apply) |

**managedFields** (`demo-drift`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| **argocd-controller** | Apply | 07:05:34 | **yes** | 23 |
| kube-controller-manager | Update (`status`) | 07:05:34 | — | 19 |

</details>

<details>
<summary><b>Step 2 · Incident: on-call raises the CPU limit with kubectl</b> — Argo CD: <code>OutOfSync/Progressing</code> · live <code>limits.cpu: 2</code></summary>

`kubectl set resources deploy/ranker -c retriever --limits=cpu=2`. kubectl sends an **Update** that changes the value, and the API server moves ownership of that field
to `kubectl-set`. `argocd-controller` no longer owns it. Argo CD correctly reports **OutOfSync**, because Git still says
`500m`.

| | Git | Live | Owner in `managedFields` |
|---|---|---|---|
| `retriever` `limits.cpu` | 500m | 2 | `kubectl-set` (Update) |

**managedFields** (`demo-drift`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 07:05:34 | — | 22 |
| kube-controller-manager | Update (`status`) | 07:05:59 | — | 20 |
| **kubectl-set** | Update | 07:05:59 | **yes** | 1 |

</details>

<details>
<summary><b>Step 3 · Git deletes the CPU limit, and Argo CD flips to Synced without syncing</b> — Argo CD: <code>Synced/Healthy</code> · live <code>limits.cpu: 2</code></summary>

The team deletes `retriever`'s CPU limit from Git (`manifests/v2`). Argo CD's server-side diff
([`diff.go:177`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/diff/diff.go#L177)) predicts the result with a dry-run server-side apply of v2.
That dry run keeps every field `argocd-controller` doesn't own, so it keeps `limits.cpu: 2`. Prediction and live are equal,
and the app goes from **OutOfSync to Synced**, although nothing in the cluster changed.

| | Git | Live | Owner in `managedFields` |
|---|---|---|---|
| `retriever` `limits.cpu` | none | 2 | `kubectl-set` (Update) |

**managedFields** (`demo-drift`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 07:05:34 | — | 22 |
| **kubectl-set** | Update | 07:05:59 | **yes** | 1 |
| kube-controller-manager | Update (`status`) | 07:06:00 | — | 19 |

<details><summary>Same moment in <code>demo-resync</code> (Argo CD: <code>OutOfSync/Healthy</code>)</summary>

In `demo-resync`, Argo CD re-synced v1 *before* this commit. With `force-conflicts` it took `limits.cpu` back (value `500m`,
owner `argocd-controller`). The dry run therefore predicts the field is removed, and the app correctly shows **OutOfSync**.

| | Git | Live | Owner in `managedFields` |
|---|---|---|---|
| `retriever` `limits.cpu` | none | 500m | `argocd-controller` (Apply) |

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| **argocd-controller** | Apply | 07:06:03 | **yes** | 23 |
| kube-controller-manager | Update (`status`) | 07:06:03 | — | 19 |

</details>

</details>

<details>
<summary><b>Step 4 · Argo CD syncs v2: the sync succeeds, and the CPU limit stays</b> — Argo CD: <code>Synced/Healthy</code> · live <code>limits.cpu: 2</code></summary>

Argo CD applies v2 as a server-side-apply PATCH
([`sync_context.go:1485`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/sync/sync_context.go#L1485)). The API server deletes a field only when
the applier owns it, and `kubectl-set` owns `limits.cpu`. The sync **Succeeds**, the app is **Synced/Healthy**, and
`retriever` keeps a 2-core CPU limit that exists nowhere in Git. `argocd-controller`'s timestamp doesn't move,
because the apply changed nothing.

Last sync operation: revision `72f32706`, Succeeded, finished `07:06:32`, options `ServerSideApply=true`.

| | Git | Live | Owner in `managedFields` |
|---|---|---|---|
| `retriever` `limits.cpu` | none | 2 | `kubectl-set` (Update) |

**managedFields** (`demo-drift`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 07:05:34 | — | 22 |
| **kubectl-set** | Update | 07:05:59 | **yes** | 1 |
| kube-controller-manager | Update (`status`) | 07:06:00 | — | 19 |

<details><summary>Same moment in <code>demo-resync</code> (Argo CD: <code>Synced/Healthy</code>)</summary>

`argocd-controller` owned the field again, so the sync deletes it, as Git says.

| | Git | Live | Owner in `managedFields` |
|---|---|---|---|
| `retriever` `limits.cpu` | none | none | — |

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 07:06:38 | — | 22 |
| kube-controller-manager | Update (`status`) | 07:06:38 | — | 19 |

</details>

</details>

<details>
<summary><b>Step 5 · The same outcome after managedFields compaction: the owner is anonymous</b> — Argo CD: <code>Synced/Healthy</code> · live <code>limits.cpu: 2</code></summary>

In `demo-compacted`, routine day-2 operations pushed the object past 10 `Update` managers before Git changed. The operations
are `kubectl label`, `annotate`, `patch`, `rollout restart`, `scale`, `edit` and `replace`, plus simulated
controllers. Names such as `hpa-controller` and `migration-orchestrator` are set by the script with `--field-manager`.
The API server merged the oldest entries, including `kubectl-set`, into **`ancient-changes`**. The result is the same
silent drift, but nothing in the object records who set the value or when.

Last sync operation: revision `72f32706`, Succeeded, finished `07:06:43`, options `ServerSideApply=true`.

| | Git | Live | Owner in `managedFields` |
|---|---|---|---|
| `retriever` `limits.cpu` | none | 2 | `ancient-changes` (Update) |

**managedFields** (`demo-compacted`)

| manager | operation | time | owns `limits.cpu` | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 07:05:43 | — | 22 |
| **ancient-changes** | Update | 07:06:07 | **yes** | 2 |
| kubectl-annotate | Update | 07:06:08 | — | 1 |
| kubectl-patch | Update | 07:06:10 | — | 1 |
| kubectl-rollout | Update | 07:06:11 | — | 1 |
| kubectl-edit | Update | 07:06:14 | — | 1 |
| kubectl-replace | Update | 07:06:15 | — | 1 |
| hpa-controller | Update | 07:06:17 | — | 1 |
| kube-controller-manager | Update (`status`) | 07:06:18 | — | 19 |
| migration-orchestrator | Update | 07:06:18 | — | 1 |
| cost-attribution-bot | Update | 07:06:20 | — | 1 |

</details>

<details>
<summary><b>Step 6 · Contrast: the same sync as a PUT</b></summary>

**`Replace=true` alone** (`demo-compacted`). Argo CD PUTs the manifest exactly as written. The drifted CPU limit is gone, and so is everything other managers set.

| | before (after the SSA sync) | after the PUT |
|---|---|---|
| `retriever` `limits.cpu` | 2 | none |
| `replicas` | 2 | 1 |
| labels | `app`, `cost-center`, `team` | `app` |
| annotations (count) | 8 | 2 |

**`Replace=true` + `RespectIgnoreDifferences=true`** (`demo-put`, with `ignoreDifferences` on `/spec/replicas`, `/metadata/labels/team` and `/metadata/labels/cost-center`). Argo CD copies the live values of the declared fields into the target before the PUT ([`controller/sync.go:310`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/controller/sync.go#L310)). The drifted CPU limit is gone, and the declared external fields are kept.

| | before (after the SSA sync) | after the PUT |
|---|---|---|
| `retriever` `limits.cpu` | 2 | none |
| `replicas` | 2 | 2 |
| labels | `app`, `cost-center`, `team` | `app`, `cost-center`, `team` |
| annotations (count) | 2 | 2 |

</details>

### B. A container re-created with kubectl (`demo-container`)

<details open>
<summary><b>Step C1 · Argo CD creates the Deployment with server-side apply</b> — Argo CD: <code>Synced/Healthy</code> · live <code>feature-cache: running</code></summary>

Argo CD creates the Deployment from `apps/ranker-container`, which has three containers. `argocd-controller` owns the
`feature-cache` list item (`.` and `f:name`).

Last sync operation: revision `20c2f4bf`, Succeeded, finished `07:05:52`, options `ServerSideApply=true`.

| | Git | Live | Owner of the list item (`.`) |
|---|---|---|---|
| container `feature-cache` | running | running | `argocd-controller` (Apply) |

**managedFields** (`demo-container`)

| manager | operation | time | owns `feature-cache` item | fields owned |
|---|---|---|---|---|
| **argocd-controller** | Apply | 07:05:52 | **yes** | 23 |
| kube-controller-manager | Update (`status`) | 07:05:53 | — | 19 |

</details>

<details>
<summary><b>Step C2 · Incident: on-call removes the crash-looping container</b> — Argo CD: <code>OutOfSync/Progressing</code> · live <code>feature-cache: none</code></summary>

`kubectl patch --type json` removes `feature-cache`. The list item and `argocd-controller`'s ownership of it are gone.
Argo CD reports **OutOfSync**.

Last sync operation: revision `20c2f4bf`, Succeeded, finished `07:05:52`, options `ServerSideApply=true`.

| | Git | Live | Owner of the list item (`.`) |
|---|---|---|---|
| container `feature-cache` | running | none | — |

**managedFields** (`demo-container`)

| manager | operation | time | owns `feature-cache` item | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 07:05:52 | — | 17 |
| kube-controller-manager | Update (`status`) | 07:06:01 | — | 20 |

</details>

<details>
<summary><b>Step C3 · After the fix, on-call adds the container back</b> — Argo CD: <code>Synced/Progressing</code> · live <code>feature-cache: running</code></summary>

After the fix is rolled out, on-call restores `feature-cache` with a second `kubectl patch`, using the same spec as Git. It is a *new* list item, owned by
`kubectl-patch`. The spec matches Git, so Argo CD reports **Synced**. `argocd-controller` owns nothing in it.

Last sync operation: revision `20c2f4bf`, Succeeded, finished `07:05:52`, options `ServerSideApply=true`.

| | Git | Live | Owner of the list item (`.`) |
|---|---|---|---|
| container `feature-cache` | running | running | `kubectl-patch` (Update) |

**managedFields** (`demo-container`)

| manager | operation | time | owns `feature-cache` item | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 07:05:52 | — | 17 |
| kube-controller-manager | Update (`status`) | 07:06:02 | — | 20 |
| **kubectl-patch** | Update | 07:06:02 | **yes** | 9 |

</details>

<details>
<summary><b>Step C4 · Git deletes the container, and Argo CD stays Synced</b> — Argo CD: <code>Synced/Healthy</code> · live <code>feature-cache: running</code></summary>

The commit deletes `feature-cache` from `apps/ranker-container`. The dry-run server-side apply keeps the container, because
`argocd-controller` doesn't own it, so the app stays **Synced**.

Last sync operation: revision `20c2f4bf`, Succeeded, finished `07:05:52`, options `ServerSideApply=true`.

| | Git | Live | Owner of the list item (`.`) |
|---|---|---|---|
| container `feature-cache` | none | running | `kubectl-patch` (Update) |

**managedFields** (`demo-container`)

| manager | operation | time | owns `feature-cache` item | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 07:05:52 | — | 17 |
| **kubectl-patch** | Update | 07:06:02 | **yes** | 9 |
| kube-controller-manager | Update (`status`) | 07:06:03 | — | 19 |

</details>

<details>
<summary><b>Step C5 · Argo CD syncs: the sync succeeds, and the container keeps running</b> — Argo CD: <code>Synced/Healthy</code> · live <code>feature-cache: running</code></summary>

The server-side-apply PATCH can't delete a list item another manager owns. The sync **Succeeds**, the app is
**Synced/Healthy**, and a container Git no longer has keeps running.

Last sync operation: revision `72f32706`, Succeeded, finished `07:06:57`, options `ServerSideApply=true`.

| | Git | Live | Owner of the list item (`.`) |
|---|---|---|---|
| container `feature-cache` | none | running | `kubectl-patch` (Update) |

**managedFields** (`demo-container`)

| manager | operation | time | owns `feature-cache` item | fields owned |
|---|---|---|---|---|
| argocd-controller | Apply | 07:05:52 | — | 17 |
| **kubectl-patch** | Update | 07:06:02 | **yes** | 9 |
| kube-controller-manager | Update (`status`) | 07:06:03 | — | 19 |

</details>

<!-- timeline:end -->

## What the scripts do

| Script | Purpose |
|---|---|
| `scripts/00-prereqs.sh` | Check that the CLIs and the Docker daemon are available |
| `scripts/01-cluster-up.sh` | Create the kind cluster `argocd-ssa-repro` with `.work/git` mounted at `/repro-git` |
| `scripts/02-install-argocd.sh` | Install Argo CD `$ARGOCD_VERSION` (default `v3.6.1`) and mount `/repro-git` into `argocd-repo-server` |
| `scripts/03-seed-git.sh` | Create the bare repo and commit v1 to `apps/ranker` and `apps/ranker-container` |
| `scripts/04-create-apps.sh` | Create the `AppProject` and one `Application` per namespace (`ServerSideApply=true`). Argo CD creates the Deployments by syncing v1 |
| `scripts/05-incident.sh` | Incident and day-2 changes with kubectl (see [The scenarios](#the-scenarios)). Managers other than `kubectl-*` in `demo-compacted` are simulated with `--field-manager` |
| `scripts/06-git-drop-field.sh` | One commit: delete `retriever`'s CPU limit (`apps/ranker`) and the `feature-cache` container (`apps/ranker-container`). Records what Argo CD reports before any sync |
| `scripts/07-sync.sh` | Sync v2 in every namespace |
| `scripts/verify.sh` | Print the verdict. Exits 0 if the bug reproduced. With `EXPECT_FIXED=1`, exits 0 only if Git's deletions took effect everywhere, for testing a patch |
| `scripts/08-replace-sync.sh` | Contrast: re-sync `demo-compacted` with `Replace=true`, and `demo-put` with `Replace=true` + `RespectIgnoreDifferences=true` |
| `scripts/render-timeline.sh` | Regenerate the [timeline](#timeline) and `docs/snapshots.js` from `.work/snapshots/` |
| `scripts/run-all.sh` | All of the above. Re-runnable: it reuses the cluster and recreates the demo state |
| `scripts/cluster-down.sh` | Delete the cluster and `.work/` |

| To inspect | Command |
|---|---|
| the drifted object and its owners | `kubectl --context kind-argocd-ssa-repro -n demo-drift get deploy ranker -o yaml --show-managed-fields` |
| what Argo CD reports | `kubectl --context kind-argocd-ssa-repro -n argocd get app ranker-demo-drift -o yaml` |

## Separate edge case

*Not the production path:* objects first created by client-side `kubectl apply`. Argo CD migrates the
`kubectl-client-side-apply` entry to itself on its first server-side-apply sync
([`sync_context.go:1341-1359`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/sync/sync_context.go#L1341-L1359)),
but only when an `Update` entry has exactly that manager name. If compaction has already renamed it
to `ancient-changes`, the migration is skipped, and containers later deleted from Git keep running
while Argo CD reports `Synced`. Scripted at commit
[`93bd972`](https://github.com/rameshgi/argocd-ssa-managedfields-repro/tree/93bd972)
(`04-bootstrap-and-inflate.sh`, `06-remove-container.sh`, `verify.sh`).

## Proposed fixes

### 1. Authoritative PUT instead of PATCH

The engine described in the blog post takes this approach: **no PATCH, only PUT**. Each deployment is
authoritative for the parts of the object it owns, and the object is written with full-replacement
semantics. Testing it against Argo CD shows
that most of the pieces already exist:

| Step | Design in the blog post | Argo CD v3.6.1 today |
|---|---|---|
| 1. Render | desired object from Git | ✔ as today |
| 2. External fields | copy the live values of declared externally managed fields into the desired object | ✔ `RespectIgnoreDifferences=true` + `ignoreDifferences` ([`controller/sync.go:310`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/controller/sync.go#L310)); verified in `demo-put` |
| 3. PUT | full replacement, regardless of `managedFields` | ✔ `Replace=true` (`kubectl replace`) |
| 4. Concurrency | PUT guarded by the live `resourceVersion`; on `409 Conflict`, re-read, recompute step 2 and retry with backoff | ✘ for most kinds, the replace sends no `resourceVersion` (only CRDs and Namespaces get one, [`sync_context.go:1469-1479`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/sync/sync_context.go#L1469-L1479)), and step 2 reads live values from the cache. A concurrent write is silently overwritten. |
| 5. Honest diff | desired state = Git + declared external fields | ✘ the diff still predicts with a dry-run server-side apply, so it reports `Synced` and nothing prompts the sync (step 3 of the timeline) |

Measured in `scripts/08-replace-sync.sh`:

| | before (after the SSA sync) | `Replace=true` (`demo-compacted`) | `Replace=true` + `RespectIgnoreDifferences=true` (`demo-put`) |
|---|---|---|---|
| `retriever` `limits.cpu` | `2` | removed ✔ | removed ✔ |
| `replicas` | `2` | `1` ✘ wiped | `2` ✔ kept |
| labels `team`, `cost-center` | present | wiped ✘ | kept ✔ |

The proposal therefore narrows to two changes:
- a `resourceVersion`-guarded replace with a conflict-retry loop;
- a diff that compares against Git plus the declared external fields when replace semantics are used.

Together they make a PUT safe and visible as the way to sync.

### 2. Alternative: detect and report the drift

A smaller change that leaves sync semantics alone. During comparison, Argo CD flags a field or list
item when all of the following hold:

| Condition | Where Argo CD gets it |
|---|---|
| it was in the manifest Argo CD last synced | `status.history` stores only revisions, not manifests. Argo CD would either re-render the last synced revision, or store the set of field paths it last applied. |
| it is absent from the current desired state | the rendered manifest, as today |
| it is still live and owned by a manager other than `argocd-controller` | `managedFields` on the live object |
| its path is **not** listed in `ignoreDifferences` | the Application spec |

| Source of "last synced manifest" | Cost |
|---|---|
| re-render the last synced revision | one extra manifest generation per comparison. Revisions are immutable, so the result can be cached by revision, the same way current manifests are. |
| store the field set Argo CD last applied | no extra rendering, but more data in the Application status (or a separate object), growing with the size of the app |

**Reported as a non-blocking application condition, not `OutOfSync`.** Removing a field from Git can be
an intentional hand-off. Argo CD's own docs recommend it in
[Leaving Room For Imperativeness](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/#leaving-room-for-imperativeness):
delete `spec.replicas` from Git so that an HPA owns it. Once the HPA has scaled the Deployment, `spec.replicas`
meets the first three conditions: it was synced before, it is no longer in Git, and the HPA (via
`kube-controller-manager`) owns it.
- If the path is listed in `ignoreDifferences`, the fourth condition excludes it.
- If it isn't, a condition that names the field and its owner (`spec.replicas` owned by
  `kube-controller-manager`) is easy to recognise as expected and doesn't break anything.
- `OutOfSync` would be wrong in that case. It would make auto-sync retry a sync that can't change the
  outcome, and mark a correct hand-off as drift.

In this test bed, the condition would appear at step 3 and step C4 of the timeline. It would name the
owning manager (or `ancient-changes`, after compaction).

## License

[Apache License 2.0](LICENSE), the same license as Argo CD. Copyright 2026 Ramesh G. Iyer.

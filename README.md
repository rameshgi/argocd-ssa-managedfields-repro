# Argo CD + server-side apply: zombie containers after `managedFields` compaction

## Starting point

This repo started from the LinkedIn Engineering blog post
[*How we scale deployments with a custom GitOps engine*](https://www.linkedin.com/blog/engineering/infrastructure/how-we-scale-deployments-with-a-custom-gitops-engine)
by **Ramesh G. Iyer**, who also wrote this test bed. Its "Side-effects of PATCH" section describes a
problem LinkedIn ran into while running Argo CD with server-side apply at scale:

> When managedFields compaction occurs on these objects, the ownership information of some
> containers may be lost. … the PATCH operation leaves the containers as they are, because
> they appear to be owned externally.

The post describes the symptom from production. This repo is a minimal, self-contained way for
Argo CD maintainers to reproduce it, end to end, on a local [kind](https://kind.sigs.k8s.io/) cluster.
It pins down the exact mechanism: Kubernetes compacts `managedFields`, and as a result Argo CD
silently skips its client-side-apply → server-side-apply migration.

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
make timeline     # regenerate the README timeline from the last run's snapshots
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

## Timeline: how the container survives its deletion

<!-- timeline:start -->
Every block below is a snapshot of the live `demo-compacted/ranker` Deployment, captured by
`scripts/run-all.sh` and rendered by `scripts/render-timeline.sh`. Expand a step to see the
container spec and `metadata.managedFields` at that moment. 🧟 marks the `feature-cache`
container: it is deleted from Git in step 5, but it survives step 6.

<details open>
<summary><b>Step 1 · Client-side <code>kubectl apply</code> creates the Deployment</b> — Argo CD: <code>n/a</code></summary>

A human, CI job or migration tool creates the object with plain (client-side) `kubectl apply`.
The API server records this as an **Update** by `kubectl-client-side-apply`, which owns all three containers.

**Container spec** (`demo-compacted`)

```yaml
# live spec.template.spec.containers
  - name: retriever
    image: registry.k8s.io/pause:3.10
  - name: ranker
    image: registry.k8s.io/pause:3.10
  - name: feature-cache
    image: registry.k8s.io/pause:3.10
    env: [CACHE_MODE=legacy]
```

**managedFields** (`demo-compacted`). Bold = claims `feature-cache`

| manager | operation | time | containers it owns | other fields it owns |
|---|---|---|---|---|
| kube-controller-manager | Update (`status`) | 04:53:40 | — | `metadata.annotations.deployment.kubernetes.io/revision`, `status.availableReplicas`, `status.conditions.{"type":"Available"}.lastTransitionTime` … (+16) |
| **kubectl-client-side-apply** | Update | 04:53:40 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations.kubectl.kubernetes.io/last-applied-configuration`, `metadata.labels.app`, `spec.progressDeadlineSeconds` … (+12) |

<details><summary><code>fieldsV1</code> claims on <code>feature-cache</code></summary>

```jsonc
// manager: kubectl-client-side-apply  operation: Update
// f:spec.f:template.f:spec.f:containers.k:{"name":"feature-cache"}
{
  ".": {},
  "f:env": {
    ".": {},
    "k:{\"name\":\"CACHE_MODE\"}": {
      ".": {},
      "f:name": {},
      "f:value": {}
    }
  },
  "f:image": {},
  "f:imagePullPolicy": {},
  "f:name": {},
  "f:resources": {
    ".": {},
    "f:requests": {
      ".": {},
      "f:cpu": {},
      "f:memory": {}
    }
  },
  "f:terminationMessagePath": {},
  "f:terminationMessagePolicy": {}
}
```

</details>

</details>

<details>
<summary><b>Step 2 · Day-2 kubectl verbs push Update managers to the cap (10)</b> — Argo CD: <code>n/a</code></summary>

Routine operations each register their own **Update** manager: `kubectl (scale)`, `kubectl-annotate`, `kubectl-edit`, `kubectl-label`, `kubectl-patch`, `kubectl-replace`, `kubectl-rollout`, `kubectl-set`. None of them touches
`feature-cache`. There are now 10 Update entries, and `kubectl-client-side-apply` is still the only owner of
`feature-cache`. Note that `kubectl (scale)` has **no timestamp**. The API server sorts entries without a timestamp as the oldest.

**Container spec** (`demo-compacted`)

```yaml
# live spec.template.spec.containers
  - name: retriever
    image: registry.k8s.io/pause:3.10
    env: [LOG_LEVEL=debug]
  - name: ranker
    image: registry.k8s.io/pause:3.10
  - name: feature-cache
    image: registry.k8s.io/pause:3.10
    env: [CACHE_MODE=legacy]
```

**managedFields** (`demo-compacted`). Bold = claims `feature-cache`

| manager | operation | time | containers it owns | other fields it owns |
|---|---|---|---|---|
| kubectl | Update (`scale`) |  | — | `spec.replicas` |
| **kubectl-client-side-apply** | Update | 04:53:40 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations`, `metadata.labels.app`, `spec.progressDeadlineSeconds` … (+11) |
| kubectl-label | Update | 04:53:51 | — | `metadata.labels.team` |
| kubectl-annotate | Update | 04:53:53 | — | `metadata.annotations.owner` |
| kubectl-patch | Update | 04:53:54 | — | `metadata.annotations.ticket` |
| kubectl-set | Update | 04:53:55 | `retriever` | — |
| kubectl-rollout | Update | 04:53:57 | — | `spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt` |
| kubectl-edit | Update | 04:53:59 | — | `metadata.annotations.edited-by` |
| kube-controller-manager | Update (`status`) | 04:54:01 | — | `metadata.annotations.deployment.kubernetes.io/revision`, `status.availableReplicas`, `status.conditions.{"type":"Available"}.lastTransitionTime` … (+16) |
| kubectl-replace | Update | 04:54:01 | — | `metadata.annotations.kubectl.kubernetes.io/last-applied-configuration`, `metadata.annotations.replaced-at` |

<details><summary><code>fieldsV1</code> claims on <code>feature-cache</code></summary>

```jsonc
// manager: kubectl-client-side-apply  operation: Update
// f:spec.f:template.f:spec.f:containers.k:{"name":"feature-cache"}
{
  ".": {},
  "f:env": {
    ".": {},
    "k:{\"name\":\"CACHE_MODE\"}": {
      ".": {},
      "f:name": {},
      "f:value": {}
    }
  },
  "f:image": {},
  "f:imagePullPolicy": {},
  "f:name": {},
  "f:resources": {
    ".": {},
    "f:requests": {
      ".": {},
      "f:cpu": {},
      "f:memory": {}
    }
  },
  "f:terminationMessagePath": {},
  "f:terminationMessagePolicy": {}
}
```

</details>

</details>

<details>
<summary><b>Step 3 · Update manager #11 (<code>migration-orchestrator</code>) → API server compacts managedFields</b> — Argo CD: <code>n/a</code></summary>

There are now more than `DefaultMaxUpdateManagers = 10` Update entries, so the API server (`capmanagers.go`) sorts the
Update entries by time and merges the oldest ones, `kubectl (scale)`, `kubectl-client-side-apply`, into **`ancient-changes`**. The fields survive, but the
`kubectl-client-side-apply` entry no longer exists under that name. `feature-cache` is now owned by
`ancient-changes`.

**Container spec** (`demo-compacted`)

```yaml
# live spec.template.spec.containers
  - name: retriever
    image: registry.k8s.io/pause:3.10
    env: [LOG_LEVEL=debug]
  - name: ranker
    image: registry.k8s.io/pause:3.10
  - name: feature-cache
    image: registry.k8s.io/pause:3.10
    env: [CACHE_MODE=legacy]
```

**managedFields** (`demo-compacted`). Bold = claims `feature-cache`

| manager | operation | time | containers it owns | other fields it owns |
|---|---|---|---|---|
| **ancient-changes** | Update | 04:53:40 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations`, `metadata.labels.app`, `spec.progressDeadlineSeconds` … (+12) |
| kubectl-label | Update | 04:53:51 | — | `metadata.labels.team` |
| kubectl-annotate | Update | 04:53:53 | — | `metadata.annotations.owner` |
| kubectl-patch | Update | 04:53:54 | — | `metadata.annotations.ticket` |
| kubectl-set | Update | 04:53:55 | `retriever` | — |
| kubectl-rollout | Update | 04:53:57 | — | `spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt` |
| kubectl-edit | Update | 04:53:59 | — | `metadata.annotations.edited-by` |
| kubectl-replace | Update | 04:54:01 | — | `metadata.annotations.kubectl.kubernetes.io/last-applied-configuration`, `metadata.annotations.replaced-at` |
| kube-controller-manager | Update (`status`) | 04:54:02 | — | `metadata.annotations.deployment.kubernetes.io/revision`, `status.availableReplicas`, `status.conditions.{"type":"Available"}.lastTransitionTime` … (+16) |
| migration-orchestrator | Update | 04:54:02 | — | `metadata.annotations.migration/state` |

<details><summary><code>fieldsV1</code> claims on <code>feature-cache</code></summary>

```jsonc
// manager: ancient-changes  operation: Update
// f:spec.f:template.f:spec.f:containers.k:{"name":"feature-cache"}
{
  ".": {},
  "f:env": {
    ".": {},
    "k:{\"name\":\"CACHE_MODE\"}": {
      ".": {},
      "f:name": {},
      "f:value": {}
    }
  },
  "f:image": {},
  "f:imagePullPolicy": {},
  "f:name": {},
  "f:resources": {
    ".": {},
    "f:requests": {
      ".": {},
      "f:cpu": {},
      "f:memory": {}
    }
  },
  "f:terminationMessagePath": {},
  "f:terminationMessagePolicy": {}
}
```

</details>

</details>

<details>
<summary><b>Step 4 · Argo CD adopts the object: first sync with <code>ServerSideApply=true</code> (Git = v1)</b> — Argo CD: <code>Synced/Healthy</code></summary>

Before applying, Argo CD calls `needsClientSideApplyMigration` (`gitops-engine/pkg/sync/sync_context.go:1341`).
It looks for an entry with `manager == "kubectl-client-side-apply"` and `operation == Update`, finds none,
and **skips the csaupgrade migration**. The server-side apply then makes `argocd-controller` (Apply) a
*co-owner* of `feature-cache`, next to `ancient-changes`.

**Container spec** (`demo-compacted`)

```yaml
# live spec.template.spec.containers
  - name: retriever
    image: registry.k8s.io/pause:3.10
    env: [LOG_LEVEL=debug]
  - name: ranker
    image: registry.k8s.io/pause:3.10
  - name: feature-cache
    image: registry.k8s.io/pause:3.10
    env: [CACHE_MODE=legacy]
```

**managedFields** (`demo-compacted`). Bold = claims `feature-cache`

| manager | operation | time | containers it owns | other fields it owns |
|---|---|---|---|---|
| **argocd-controller** | Apply | 04:54:08 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations.argocd.argoproj.io/tracking-id`, `metadata.labels.app`, `spec.selector` … (+2) |
| **ancient-changes** | Update | 04:53:40 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations`, `metadata.labels.app`, `spec.progressDeadlineSeconds` … (+12) |
| kubectl-label | Update | 04:53:51 | — | `metadata.labels.team` |
| kubectl-annotate | Update | 04:53:53 | — | `metadata.annotations.owner` |
| kubectl-patch | Update | 04:53:54 | — | `metadata.annotations.ticket` |
| kubectl-set | Update | 04:53:55 | `retriever` | — |
| kubectl-rollout | Update | 04:53:57 | — | `spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt` |
| kubectl-edit | Update | 04:53:59 | — | `metadata.annotations.edited-by` |
| migration-orchestrator | Update | 04:54:02 | — | `metadata.annotations.migration/state` |
| kube-controller-manager | Update (`status`) | 04:54:08 | — | `metadata.annotations.deployment.kubernetes.io/revision`, `status.availableReplicas`, `status.conditions.{"type":"Available"}.lastTransitionTime` … (+16) |

<details><summary><code>fieldsV1</code> claims on <code>feature-cache</code></summary>

```jsonc
// manager: argocd-controller  operation: Apply
// f:spec.f:template.f:spec.f:containers.k:{"name":"feature-cache"}
{
  ".": {},
  "f:env": {
    "k:{\"name\":\"CACHE_MODE\"}": {
      ".": {},
      "f:name": {},
      "f:value": {}
    }
  },
  "f:image": {},
  "f:name": {},
  "f:resources": {
    "f:requests": {
      "f:cpu": {},
      "f:memory": {}
    }
  }
}


// manager: ancient-changes  operation: Update
// f:spec.f:template.f:spec.f:containers.k:{"name":"feature-cache"}
{
  ".": {},
  "f:env": {
    ".": {},
    "k:{\"name\":\"CACHE_MODE\"}": {
      ".": {},
      "f:name": {},
      "f:value": {}
    }
  },
  "f:image": {},
  "f:imagePullPolicy": {},
  "f:name": {},
  "f:resources": {
    ".": {},
    "f:requests": {
      ".": {},
      "f:cpu": {},
      "f:memory": {}
    }
  },
  "f:terminationMessagePath": {},
  "f:terminationMessagePolicy": {}
}
```

</details>

<details><summary>Same moment in <code>demo-control</code> (Argo CD: <code>Synced/Healthy</code>)</summary>

Here the `kubectl-client-side-apply` entry still exists, so `performCSAUpgradeMigration` moves its fields to
`argocd-controller` and deletes the entry. `argocd-controller` is now the **sole** owner of `feature-cache`.

```yaml
# live spec.template.spec.containers
  - name: retriever
    image: registry.k8s.io/pause:3.10
    env: [LOG_LEVEL=debug]
  - name: ranker
    image: registry.k8s.io/pause:3.10
  - name: feature-cache
    image: registry.k8s.io/pause:3.10
    env: [CACHE_MODE=legacy]
```

| manager | operation | time | containers it owns | other fields it owns |
|---|---|---|---|---|
| **argocd-controller** | Apply | 04:54:03 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations.argocd.argoproj.io/tracking-id`, `metadata.labels.app`, `spec.selector` … (+2) |
| kubectl | Update (`scale`) |  | — | `spec.replicas` |
| kubectl-label | Update | 04:53:43 | — | `metadata.labels.team` |
| kubectl-annotate | Update | 04:53:45 | — | `metadata.annotations.owner` |
| kubectl-patch | Update | 04:53:46 | — | `metadata.annotations.ticket` |
| kubectl-set | Update | 04:53:47 | `retriever` | — |
| kubectl-rollout | Update | 04:53:49 | — | `spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt` |
| kube-controller-manager | Update (`status`) | 04:54:03 | — | `metadata.annotations.deployment.kubernetes.io/revision`, `status.availableReplicas`, `status.conditions.{"type":"Available"}.lastTransitionTime` … (+16) |

</details>

</details>

<details>
<summary><b>Step 5 · <code>feature-cache</code> deleted in Git (v2), before sync</b> — Argo CD: <code>Synced/Healthy</code></summary>

Server-side diff (`gitops-engine/pkg/diff/diff.go:172`) runs a dry-run SSA of v2. Because `ancient-changes`
still owns the container, the dry run predicts that the container **stays**. The predicted state equals live, so
Argo CD says **Synced**: the change in Git is invisible.

**Container spec** (`demo-compacted`)

```diff
# live spec.template.spec.containers vs. Git (manifests/v2). '+' = in the cluster but NOT in Git
  - name: retriever
    image: registry.k8s.io/pause:3.10
    env: [LOG_LEVEL=debug]
  - name: ranker
    image: registry.k8s.io/pause:3.10
+ - name: feature-cache
+   image: registry.k8s.io/pause:3.10
+   env: [CACHE_MODE=legacy]
```

**managedFields** (`demo-compacted`). Bold = claims `feature-cache`

| manager | operation | time | containers it owns | other fields it owns |
|---|---|---|---|---|
| **argocd-controller** | Apply | 04:54:08 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations.argocd.argoproj.io/tracking-id`, `metadata.labels.app`, `spec.selector` … (+2) |
| **ancient-changes** | Update | 04:53:40 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations`, `metadata.labels.app`, `spec.progressDeadlineSeconds` … (+12) |
| kubectl-label | Update | 04:53:51 | — | `metadata.labels.team` |
| kubectl-annotate | Update | 04:53:53 | — | `metadata.annotations.owner` |
| kubectl-patch | Update | 04:53:54 | — | `metadata.annotations.ticket` |
| kubectl-set | Update | 04:53:55 | `retriever` | — |
| kubectl-rollout | Update | 04:53:57 | — | `spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt` |
| kubectl-edit | Update | 04:53:59 | — | `metadata.annotations.edited-by` |
| migration-orchestrator | Update | 04:54:02 | — | `metadata.annotations.migration/state` |
| kube-controller-manager | Update (`status`) | 04:54:08 | — | `metadata.annotations.deployment.kubernetes.io/revision`, `status.availableReplicas`, `status.conditions.{"type":"Available"}.lastTransitionTime` … (+16) |

<details><summary><code>fieldsV1</code> claims on <code>feature-cache</code></summary>

```jsonc
// manager: argocd-controller  operation: Apply
// f:spec.f:template.f:spec.f:containers.k:{"name":"feature-cache"}
{
  ".": {},
  "f:env": {
    "k:{\"name\":\"CACHE_MODE\"}": {
      ".": {},
      "f:name": {},
      "f:value": {}
    }
  },
  "f:image": {},
  "f:name": {},
  "f:resources": {
    "f:requests": {
      "f:cpu": {},
      "f:memory": {}
    }
  }
}


// manager: ancient-changes  operation: Update
// f:spec.f:template.f:spec.f:containers.k:{"name":"feature-cache"}
{
  ".": {},
  "f:env": {
    ".": {},
    "k:{\"name\":\"CACHE_MODE\"}": {
      ".": {},
      "f:name": {},
      "f:value": {}
    }
  },
  "f:image": {},
  "f:imagePullPolicy": {},
  "f:name": {},
  "f:resources": {
    ".": {},
    "f:requests": {
      ".": {},
      "f:cpu": {},
      "f:memory": {}
    }
  },
  "f:terminationMessagePath": {},
  "f:terminationMessagePolicy": {}
}
```

</details>

<details><summary>Same moment in <code>demo-control</code> (Argo CD: <code>OutOfSync/Healthy</code>)</summary>

Here the dry run predicts that the container is removed, so the app correctly goes **OutOfSync**.

```diff
# live spec.template.spec.containers vs. Git (manifests/v2). '+' = in the cluster but NOT in Git
  - name: retriever
    image: registry.k8s.io/pause:3.10
    env: [LOG_LEVEL=debug]
  - name: ranker
    image: registry.k8s.io/pause:3.10
+ - name: feature-cache
+   image: registry.k8s.io/pause:3.10
+   env: [CACHE_MODE=legacy]
```

| manager | operation | time | containers it owns | other fields it owns |
|---|---|---|---|---|
| **argocd-controller** | Apply | 04:54:03 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations.argocd.argoproj.io/tracking-id`, `metadata.labels.app`, `spec.selector` … (+2) |
| kubectl | Update (`scale`) |  | — | `spec.replicas` |
| kubectl-label | Update | 04:53:43 | — | `metadata.labels.team` |
| kubectl-annotate | Update | 04:53:45 | — | `metadata.annotations.owner` |
| kubectl-patch | Update | 04:53:46 | — | `metadata.annotations.ticket` |
| kubectl-set | Update | 04:53:47 | `retriever` | — |
| kubectl-rollout | Update | 04:53:49 | — | `spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt` |
| kube-controller-manager | Update (`status`) | 04:54:03 | — | `metadata.annotations.deployment.kubernetes.io/revision`, `status.availableReplicas`, `status.conditions.{"type":"Available"}.lastTransitionTime` … (+16) |

</details>

</details>

<details>
<summary><b>Step 6 · Argo CD syncs v2 with <code>ServerSideApply=true</code></b> — Argo CD: <code>Synced/Healthy</code></summary>

The sync drops `argocd-controller`'s claim on `feature-cache`. Server-side apply only deletes a field when
no other manager owns it. `ancient-changes` still does, so the API server **keeps the container**. The
sync *Succeeds*, the app reports **Synced/Healthy**, and a container that is no longer in Git keeps running.

**Container spec** (`demo-compacted`)

```diff
# live spec.template.spec.containers vs. Git (manifests/v2). '+' = in the cluster but NOT in Git
  - name: retriever
    image: registry.k8s.io/pause:3.10
    env: [LOG_LEVEL=debug]
  - name: ranker
    image: registry.k8s.io/pause:3.10
+ - name: feature-cache
+   image: registry.k8s.io/pause:3.10
+   env: [CACHE_MODE=legacy]
```

**managedFields** (`demo-compacted`). Bold = claims `feature-cache`

| manager | operation | time | containers it owns | other fields it owns |
|---|---|---|---|---|
| argocd-controller | Apply | 04:54:08 | `ranker`, `retriever` | `metadata.annotations.argocd.argoproj.io/tracking-id`, `metadata.labels.app`, `spec.selector` … (+2) |
| **ancient-changes** | Update | 04:53:40 | **`feature-cache`** 🧟, `ranker`, `retriever` | `metadata.annotations`, `metadata.labels.app`, `spec.progressDeadlineSeconds` … (+12) |
| kubectl-label | Update | 04:53:51 | — | `metadata.labels.team` |
| kubectl-annotate | Update | 04:53:53 | — | `metadata.annotations.owner` |
| kubectl-patch | Update | 04:53:54 | — | `metadata.annotations.ticket` |
| kubectl-set | Update | 04:53:55 | `retriever` | — |
| kubectl-rollout | Update | 04:53:57 | — | `spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt` |
| kubectl-edit | Update | 04:53:59 | — | `metadata.annotations.edited-by` |
| migration-orchestrator | Update | 04:54:02 | — | `metadata.annotations.migration/state` |
| kube-controller-manager | Update (`status`) | 04:54:08 | — | `metadata.annotations.deployment.kubernetes.io/revision`, `status.availableReplicas`, `status.conditions.{"type":"Available"}.lastTransitionTime` … (+16) |

<details><summary><code>fieldsV1</code> claims on <code>feature-cache</code></summary>

```jsonc
// manager: ancient-changes  operation: Update
// f:spec.f:template.f:spec.f:containers.k:{"name":"feature-cache"}
{
  ".": {},
  "f:env": {
    ".": {},
    "k:{\"name\":\"CACHE_MODE\"}": {
      ".": {},
      "f:name": {},
      "f:value": {}
    }
  },
  "f:image": {},
  "f:imagePullPolicy": {},
  "f:name": {},
  "f:resources": {
    ".": {},
    "f:requests": {
      ".": {},
      "f:cpu": {},
      "f:memory": {}
    }
  },
  "f:terminationMessagePath": {},
  "f:terminationMessagePolicy": {}
}
```

</details>

<details><summary>Same moment in <code>demo-control</code> (Argo CD: <code>Synced/Healthy</code>)</summary>

`argocd-controller` was the sole owner, so server-side apply deletes the container, as Git says.

```diff
# live spec.template.spec.containers vs. Git (manifests/v2). '+' = in the cluster but NOT in Git
  - name: retriever
    image: registry.k8s.io/pause:3.10
    env: [LOG_LEVEL=debug]
  - name: ranker
    image: registry.k8s.io/pause:3.10
```

| manager | operation | time | containers it owns | other fields it owns |
|---|---|---|---|---|
| argocd-controller | Apply | 04:54:16 | `ranker`, `retriever` | `metadata.annotations.argocd.argoproj.io/tracking-id`, `metadata.labels.app`, `spec.selector` … (+2) |
| kubectl | Update (`scale`) |  | — | `spec.replicas` |
| kubectl-label | Update | 04:53:43 | — | `metadata.labels.team` |
| kubectl-annotate | Update | 04:53:45 | — | `metadata.annotations.owner` |
| kubectl-patch | Update | 04:53:46 | — | `metadata.annotations.ticket` |
| kubectl-set | Update | 04:53:47 | `retriever` | — |
| kubectl-rollout | Update | 04:53:49 | — | `spec.template.metadata.annotations.kubectl.kubernetes.io/restartedAt` |
| kube-controller-manager | Update (`status`) | 04:54:17 | — | `metadata.annotations.deployment.kubernetes.io/revision`, `status.availableReplicas`, `status.conditions.{"type":"Available"}.lastTransitionTime` … (+16) |

</details>

</details>

<!-- timeline:end -->

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
| `scripts/render-timeline.sh` | Regenerate the [timeline](#timeline-how-the-container-survives-its-deletion) above from the snapshots in `.work/snapshots/` |
| `scripts/run-all.sh` | All of the above, plus the timeline. Re-runnable: it reuses the cluster and recreates the demo state |
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

# shellcheck shell=bash
# Shared settings and helpers. Source this file; do not execute it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-argocd-ssa-repro}"
KCTX="kind-${CLUSTER_NAME}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.6.1}"
# Leave empty to use the kind release's default node image.
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"

WORK_DIR="${ROOT}/.work"
# Host directory that holds the bare Git repo Argo CD reads from. It is mounted
# into the kind node, then into argocd-repo-server, at /repro-git.
GIT_HOST_DIR="${WORK_DIR}/git"
BARE_REPO="${GIT_HOST_DIR}/manifests.git"
CHECKOUT_DIR="${WORK_DIR}/checkout"

# Scenarios, side by side. In all of them Argo CD creates the object with
# server-side apply, someone changes it with kubectl during an incident, and Git
# later deletes what was changed.
#   demo-drift     : kubectl changes retriever's CPU limit; Git drops it      -> field stays, Synced  (BUG)
#   demo-resync    : same, but Argo CD re-syncs before Git drops it           -> field removed         (control)
#   demo-compacted : like demo-drift, plus >10 Update managers                -> field stays, owner "ancient-changes"
#   demo-put       : like demo-drift, plus day-2 replicas/labels; ends with a
#                    Replace=true + RespectIgnoreDifferences=true sync          (contrast, step 08)
#   demo-container : kubectl removes and re-adds the feature-cache container;
#                    Git drops that container                                -> container stays, Synced (BUG)
NS_DRIFT="demo-drift"
NS_RESYNC="demo-resync"
NS_COMPACTED="demo-compacted"
NS_PUT="demo-put"
NS_CONTAINER="demo-container"
FIELD_NS=("${NS_DRIFT}" "${NS_RESYNC}" "${NS_COMPACTED}" "${NS_PUT}")
ALL_NS=("${FIELD_NS[@]}" "${NS_CONTAINER}")
app_path() { [[ "$1" == "${NS_CONTAINER}" ]] && echo apps/ranker-container || echo apps/ranker; }

DEPLOY="ranker"
ARGO_MANAGER="argocd-controller"   # Argo CD's server-side-apply field manager
# The field that drifts: retriever's CPU limit.
FIELD_CONTAINER="retriever"
FIELD_DESC="spec.template.spec.containers[name=${FIELD_CONTAINER}].resources.limits.cpu"
INCIDENT_CPU="2"                   # value on-call sets during the incident
INCIDENT_CMD="kubectl set resources deploy/${DEPLOY} -c ${FIELD_CONTAINER} --limits=cpu=${INCIDENT_CPU}"
# The container that is removed and re-added during the incident (demo-container).
SIDECAR="feature-cache"

k() { kubectl --context "${KCTX}" "$@"; }

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; else B=; G=; R=; Y=; N=; fi
step() { printf '\n%s==> %s%s\n' "${B}" "$*" "${N}"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔ %s%s\n' "${G}" "$*" "${N}"; }
bad()  { printf '    %s✘ %s%s\n' "${R}" "$*" "${N}"; }
warn() { printf '    %s! %s%s\n' "${Y}" "$*" "${N}"; }
die()  { bad "$*"; exit 1; }

deploy_json() { k -n "$1" get deploy "${DEPLOY}" -o json --show-managed-fields; }

# Current value of the drifting field, or "<absent>".
field_value() {
  deploy_json "$1" | jq -r --arg c "${FIELD_CONTAINER}" \
    '.spec.template.spec.containers[] | select(.name==$c) | .resources.limits.cpu // "<absent>"'
}

# Managers whose managedFields entry claims the drifting field.
field_owners() {
  deploy_json "$1" | jq -r --arg c "k:{\"name\":\"${FIELD_CONTAINER}\"}" '[.metadata.managedFields[]
    | select(.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$c]["f:resources"]["f:limits"]["f:cpu"] != null)
    | "\(.manager) (\(.operation))"] | join(", ")'
}

live_containers() { deploy_json "$1" | jq -r '[.spec.template.spec.containers[].name] | join(",")'; }

# Managers whose managedFields entry claims the given container list item.
container_owners() { # ns container
  deploy_json "$1" | jq -r --arg c "k:{\"name\":\"$2\"}" '[.metadata.managedFields[]
    | select(.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$c] != null)
    | "\(.manager) (\(.operation))"] | join(", ")'
}

# Save the live Deployment (+ the Application's sync/health and its last sync
# operation) for the README timeline and the interactive page.
SNAP_DIR="${WORK_DIR}/snapshots"
snapshot() { # label ns [note]
  local argo k8s sync
  mkdir -p "${SNAP_DIR}"
  argo="$(k -n argocd get app "ranker-$2" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  sync="$(k -n argocd get app "ranker-$2" -o json 2>/dev/null | jq -c '.status.operationState // {} | {revision: (.syncResult.revision // null), phase: (.phase // null), finishedAt: (.finishedAt // null), options: (.operation.sync.syncOptions // [])}' || echo '{}')"
  k8s="$(k version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty' || true)"
  deploy_json "$2" | jq --arg argo "${argo}" --arg note "${3:-}" --arg k8s "${k8s}" --argjson sync "${sync:-{\}}" \
    '. + {_argo: $argo, _note: $note, _k8s: $k8s, _sync: $sync}' > "${SNAP_DIR}/$1.$2.json"
}

# Print the managedFields table for the Deployment in namespace $1.
show_managers() {
  printf '    %-28s %-7s %-12s %s\n' MANAGER OPERATION SUBRESOURCE TIME
  deploy_json "$1" | jq -r '.metadata.managedFields[] | [.manager, .operation, (.subresource // "-"), .time] | @tsv' |
    while IFS=$'\t' read -r m o s t; do printf '    %-28s %-7s %-12s %s\n' "$m" "$o" "$s" "$t"; done
}

# Number of managedFields entries with operation=Update (the only ones the
# API server caps; see capmanagers.go, DefaultMaxUpdateManagers = 10).
update_manager_count() {
  deploy_json "$1" | jq '[.metadata.managedFields[] | select(.operation=="Update")] | length'
}

has_manager() { # ns manager
  deploy_json "$1" | jq -e --arg m "$2" 'any(.metadata.managedFields[]; .manager==$m)' >/dev/null
}

git_sha() { git -C "${CHECKOUT_DIR}" log --format=%H --grep="^ranker $1\$" | head -1; }

# Commit the given version (v1|v2) to the bare repo; print the SHA.
#   v1: apps/ranker and apps/ranker-container both get manifests/v1
#   v2: apps/ranker gets manifests/v2 (CPU limit deleted),
#       apps/ranker-container gets manifests/v2-container (feature-cache deleted)
git_publish() {
  local version="$1"
  mkdir -p "${CHECKOUT_DIR}/apps/ranker" "${CHECKOUT_DIR}/apps/ranker-container"
  cp "${ROOT}/manifests/${version}/deployment.yaml" "${CHECKOUT_DIR}/apps/ranker/deployment.yaml"
  if [[ "${version}" == v1 ]]; then
    cp "${ROOT}/manifests/v1/deployment.yaml" "${CHECKOUT_DIR}/apps/ranker-container/deployment.yaml"
  else
    cp "${ROOT}/manifests/v2-container/deployment.yaml" "${CHECKOUT_DIR}/apps/ranker-container/deployment.yaml"
  fi
  git -C "${CHECKOUT_DIR}" add -A >/dev/null
  git -C "${CHECKOUT_DIR}" -c user.name=repro -c user.email=repro@example.invalid \
    commit -q --allow-empty -m "ranker ${version}"
  git -C "${CHECKOUT_DIR}" push -q origin HEAD:main
  git -C "${CHECKOUT_DIR}" rev-parse HEAD
}

# Hard-refresh the Application and wait until it has compared against revision $2.
app_refresh() { # app sha
  local app="$1" sha="$2" i
  k -n argocd annotate app "${app}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  for i in $(seq 1 90); do
    if [[ "$(k -n argocd get app "${app}" -o jsonpath='{.status.sync.revision}')" == "${sha}" &&
          -z "$(k -n argocd get app "${app}" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}')" ]]; then
      return 0
    fi
    sleep 2
  done
  die "Application ${app} never observed revision ${sha}"
}

# Trigger a sync through the Application's .operation field (no argocd CLI
# needed) and wait for it to finish.
app_sync() { # app sha [extra sync option ...]
  local app="$1" sha="$2" i phase started
  shift 2
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  k -n argocd patch app "${app}" --type merge -p "$(jq -nc --arg r "${sha}" --args \
    '{operation:{initiatedBy:{username:"repro-script"},sync:{revision:$r,syncOptions:(["ServerSideApply=true"] + $ARGS.positional)}}}' "$@")" >/dev/null
  for i in $(seq 1 90); do
    sleep 2
    [[ -n "$(k -n argocd get app "${app}" -o jsonpath='{.operation}')" ]] && continue
    [[ "$(k -n argocd get app "${app}" -o jsonpath='{.status.operationState.startedAt}')" < "${started}" ]] && continue
    phase="$(k -n argocd get app "${app}" -o jsonpath='{.status.operationState.phase}')"
    case "${phase}" in
      Succeeded) return 0 ;;
      Failed|Error) k -n argocd get app "${app}" -o jsonpath='{.status.operationState.message}'; echo; die "sync of ${app} ${phase}" ;;
    esac
  done
  die "sync of ${app} did not finish"
}

app_status() { # app
  k -n argocd get app "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}'
}

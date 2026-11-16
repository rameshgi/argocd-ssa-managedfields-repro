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

# Three scenarios, side by side. In all of them Argo CD creates the object with
# server-side apply, an on-call engineer changes one Argo CD-managed field with
# kubectl during an incident, and Git later deletes that field.
#   demo-drift     : Git drops the field; Argo CD syncs           -> field stays, Synced   (BUG)
#   demo-resync    : Argo CD re-syncs before Git drops the field  -> field removed          (control)
#   demo-compacted : like demo-drift, plus >10 Update managers    -> field stays, owner now "ancient-changes"
NS_DRIFT="demo-drift"
NS_RESYNC="demo-resync"
NS_COMPACTED="demo-compacted"
ALL_NS=("${NS_DRIFT}" "${NS_RESYNC}" "${NS_COMPACTED}")

DEPLOY="ranker"
ARGO_MANAGER="argocd-controller"   # Argo CD's server-side-apply field manager
# The field that drifts: retriever's CPU limit.
FIELD_CONTAINER="retriever"
FIELD_DESC="spec.template.spec.containers[name=${FIELD_CONTAINER}].resources.limits.cpu"
INCIDENT_CPU="2"                   # value on-call sets during the incident
INCIDENT_CMD="kubectl set resources deploy/${DEPLOY} -c ${FIELD_CONTAINER} --limits=cpu=${INCIDENT_CPU}"

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

# Save the live Deployment (+ the Application's sync/health) for the README
# timeline and the interactive page. See scripts/render-timeline.sh.
SNAP_DIR="${WORK_DIR}/snapshots"
snapshot() { # label ns [note]
  local argo k8s
  mkdir -p "${SNAP_DIR}"
  argo="$(k -n argocd get app "ranker-$2" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  k8s="$(k version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty' || true)"
  deploy_json "$2" | jq --arg argo "${argo}" --arg note "${3:-}" --arg k8s "${k8s}" \
    '. + {_argo: $argo, _note: $note, _k8s: $k8s}' > "${SNAP_DIR}/$1.$2.json"
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

# Commit the given manifest version (v1|v2) to the bare repo; print the SHA.
git_publish() {
  local version="$1"
  mkdir -p "${CHECKOUT_DIR}/apps/ranker"
  cp "${ROOT}/manifests/${version}/deployment.yaml" "${CHECKOUT_DIR}/apps/ranker/deployment.yaml"
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

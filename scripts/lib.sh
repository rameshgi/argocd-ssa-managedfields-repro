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

# Two identical scenarios, side by side:
#   demo-control   : fewer than 10 "Update" managers -> no compaction -> works
#   demo-compacted : more than 10 "Update" managers  -> compaction    -> bug
NS_CONTROL="demo-control"
NS_COMPACTED="demo-compacted"

DEPLOY="ranker"
REMOVED_CONTAINER="feature-cache"
CSA_MANAGER="kubectl-client-side-apply"   # Argo CD's default CSA-migration manager
ARGO_MANAGER="argocd-controller"          # Argo CD's SSA field manager

k() { kubectl --context "${KCTX}" "$@"; }

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; else B=; G=; R=; Y=; N=; fi
step() { printf '\n%s==> %s%s\n' "${B}" "$*" "${N}"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔ %s%s\n' "${G}" "$*" "${N}"; }
bad()  { printf '    %s✘ %s%s\n' "${R}" "$*" "${N}"; }
warn() { printf '    %s! %s%s\n' "${Y}" "$*" "${N}"; }
die()  { bad "$*"; exit 1; }

deploy_json() { k -n "$1" get deploy "${DEPLOY}" -o json --show-managed-fields; }

# Save the live Deployment (+ the Application's sync/health, if any) for the
# README timeline. See scripts/render-timeline.sh.
SNAP_DIR="${WORK_DIR}/snapshots"
snapshot() { # label ns [note]
  local argo
  mkdir -p "${SNAP_DIR}"
  argo="$(k -n argocd get app "ranker-$2" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  deploy_json "$2" | jq --arg argo "${argo}" --arg note "${3:-}" '. + {_argo: $argo, _note: $note}' \
    > "${SNAP_DIR}/$1.$2.json"
}

# Print the managedFields table for the Deployment in namespace $1.
show_managers() {
  local ns="$1"
  printf '    %-28s %-7s %-12s %s\n' MANAGER OPERATION SUBRESOURCE TIME
  deploy_json "${ns}" | jq -r '.metadata.managedFields[]
      | [.manager, .operation, (.subresource // "-"), .time] | @tsv' |
    while IFS=$'\t' read -r m o s t; do printf '    %-28s %-7s %-12s %s\n' "$m" "$o" "$s" "$t"; done
}

# Number of managedFields entries with operation=Update (the only ones the
# API server caps; see capmanagers.go, DefaultMaxUpdateManagers = 10).
update_manager_count() {
  deploy_json "$1" | jq '[.metadata.managedFields[] | select(.operation=="Update")] | length'
}

has_manager() { # ns manager operation
  deploy_json "$1" | jq -e --arg m "$2" --arg o "$3" \
    'any(.metadata.managedFields[]; .manager==$m and .operation==$o)' >/dev/null
}

# Managers whose fieldsV1 claims the given container list item.
container_owners() { # ns container
  deploy_json "$1" | jq -r --arg c "k:{\"name\":\"$2\"}" '.metadata.managedFields[]
    | select(.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$c] != null)
    | "\(.manager) (\(.operation))"'
}

live_containers() { deploy_json "$1" | jq -r '[.spec.template.spec.containers[].name] | join(",")'; }

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

# Hard-refresh the Application and wait until it has seen revision $2.
app_refresh() { # app sha
  local app="$1" sha="$2" i
  k -n argocd annotate app "${app}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  for i in $(seq 1 90); do
    [[ "$(k -n argocd get app "${app}" -o jsonpath='{.status.sync.revision}')" == "${sha}" ]] && return 0
    sleep 2
  done
  die "Application ${app} never observed revision ${sha}"
}

# Trigger a sync through the Application's .operation field (no argocd CLI
# needed) and wait for it to finish.
app_sync() { # app sha
  local app="$1" sha="$2" i phase
  k -n argocd patch app "${app}" --type merge -p "$(jq -nc --arg r "${sha}" \
    '{operation:{initiatedBy:{username:"repro-script"},sync:{revision:$r,syncOptions:["ServerSideApply=true"]}}}')" >/dev/null
  for i in $(seq 1 90); do
    phase="$(k -n argocd get app "${app}" -o jsonpath='{.status.operationState.phase}')"
    if [[ -z "$(k -n argocd get app "${app}" -o jsonpath='{.operation}')" &&
          "$(k -n argocd get app "${app}" -o jsonpath='{.status.operationState.syncResult.revision}')" == "${sha}" ]]; then
      case "${phase}" in
        Succeeded) return 0 ;;
        Failed|Error) k -n argocd get app "${app}" -o jsonpath='{.status.operationState.message}'; echo; die "sync of ${app} ${phase}" ;;
      esac
    fi
    sleep 2
  done
  die "sync of ${app} did not finish"
}

app_status() { # app
  k -n argocd get app "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}'
}

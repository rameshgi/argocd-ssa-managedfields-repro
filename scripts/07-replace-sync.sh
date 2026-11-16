#!/usr/bin/env bash
# Contrast: re-sync the same v2 commit with Argo CD's existing `Replace=true`
# sync option, which writes the object with a PUT (`kubectl replace`) instead
# of a server-side-apply PATCH. A PUT replaces the whole object with the
# desired state, so managedFields ownership no longer matters.
#
# Expect: the zombie container is gone. Also expect that fields set by other
# managers and absent from Git (labels, annotations, replicas, env vars added
# with kubectl) are wiped as well. Argo CD's Replace=true sends the manifest
# as-is; it does not reconcile externally managed fields first.
source "$(dirname "$0")/lib.sh"
ns="${NS_COMPACTED}"; app="ranker-${ns}"
sha="$(git -C "${CHECKOUT_DIR}" rev-parse HEAD)"

state() {
  deploy_json "${ns}" | jq -r '"containers=\([.spec.template.spec.containers[].name] | join(","))  replicas=\(.spec.replicas)  labels=\(.metadata.labels | keys | join(","))  retriever.env=\([.spec.template.spec.containers[] | select(.name=="retriever") | .env // [] | .[].name] | join(","))"'
}

step "${ns}: re-syncing v2 (${sha:0:8}) with Replace=true (PUT instead of PATCH)"
info "before: $(state)"
app_sync "${app}" "${sha}" Replace=true
k -n argocd annotate app "${app}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
sleep 10
info "after:  $(state)"
info "Argo CD: $(app_status "${app}")"
snapshot 7-replace-sync "${ns}"

if live_containers "${ns}" | tr ',' '\n' | grep -qx "${REMOVED_CONTAINER}"; then
  bad "'${REMOVED_CONTAINER}' still present after PUT"
else
  ok "PUT removed '${REMOVED_CONTAINER}': full replacement does not depend on managedFields"
fi

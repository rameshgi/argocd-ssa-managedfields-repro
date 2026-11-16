#!/usr/bin/env bash
# Create the AppProject and one Application per namespace (ServerSideApply=true),
# then let Argo CD adopt the existing Deployments by syncing v1.
#
# On this first SSA sync Argo CD runs its client-side-apply migration
# (gitops-engine/pkg/sync/sync_context.go: needsClientSideApplyMigration /
# performCSAUpgradeMigration), which looks for a managedFields entry with
# manager=kubectl-client-side-apply and operation=Update:
#   demo-control   : entry found  -> ownership transferred to argocd-controller
#   demo-compacted : entry was renamed to ancient-changes -> migration SKIPPED
source "$(dirname "$0")/lib.sh"

step "Creating AppProject and Applications"
k apply -f "${ROOT}/argocd/appproject.yaml" >/dev/null
for ns in "${NS_CONTROL}" "${NS_COMPACTED}"; do
  sed "s/\${NAMESPACE}/${ns}/g" "${ROOT}/argocd/application.yaml.tmpl" | k apply -f - >/dev/null
  ok "Application ranker-${ns}"
done

sha="$(git -C "${CHECKOUT_DIR}" rev-parse HEAD)"
step "Syncing v1 (${sha:0:8}) with ServerSideApply=true"
for ns in "${NS_CONTROL}" "${NS_COMPACTED}"; do
  app_refresh "ranker-${ns}" "${sha}"
  app_sync "ranker-${ns}" "${sha}"
  sleep 3
  ok "ranker-${ns}: $(app_status "ranker-${ns}")"
  snapshot 4-argo-sync-v1 "${ns}"
done

for ns in "${NS_CONTROL}" "${NS_COMPACTED}"; do
  step "${ns}: managedFields after Argo CD's first server-side apply"
  show_managers "${ns}"
  info "owners of '${REMOVED_CONTAINER}': $(container_owners "${ns}" "${REMOVED_CONTAINER}" | paste -sd, -)"
done

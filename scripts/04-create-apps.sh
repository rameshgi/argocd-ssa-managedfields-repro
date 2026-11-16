#!/usr/bin/env bash
# Create the AppProject and one Application per namespace (ServerSideApply=true)
# and let Argo CD CREATE the Deployment by syncing v1. From here on,
# argocd-controller (operation: Apply) owns every field in the manifest,
# including retriever's CPU limit.
source "$(dirname "$0")/lib.sh"

step "Creating AppProject and Applications"
k apply -f "${ROOT}/argocd/appproject.yaml" >/dev/null
v1="$(git_sha v1)"
for ns in "${ALL_NS[@]}"; do
  k create namespace "${ns}" --dry-run=client -o yaml | k apply -f - >/dev/null
  sed "s/\${NAMESPACE}/${ns}/g" "${ROOT}/argocd/application.yaml.tmpl" | k apply -f - >/dev/null
  ok "Application ranker-${ns}"
done

step "Argo CD creates the Deployments: sync v1 (${v1:0:8}) with ServerSideApply=true"
for ns in "${ALL_NS[@]}"; do
  app_refresh "ranker-${ns}" "${v1}"
  app_sync "ranker-${ns}" "${v1}"
  k -n "${ns}" rollout status deploy/"${DEPLOY}" --timeout=180s >/dev/null
  sleep 2
  app_refresh "ranker-${ns}" "${v1}"
  snapshot 1-argo-create "${ns}" "Argo CD sync of manifests/v1 (server-side apply)"
  ok "${ns}: $(app_status "ranker-${ns}")   retriever limits.cpu=$(field_value "${ns}")   owner: $(field_owners "${ns}")"
done

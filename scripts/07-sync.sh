#!/usr/bin/env bash
# Argo CD syncs v2 with ServerSideApply=true in every namespace.
source "$(dirname "$0")/lib.sh"
sha="$(git_sha v2)"

step "Argo CD syncs v2 (${sha:0:8}) with ServerSideApply=true"
for ns in "${ALL_NS[@]}"; do
  app_sync "ranker-${ns}" "${sha}"
  sleep 3
  app_refresh "ranker-${ns}" "${sha}"
  snapshot 5-argo-sync-v2 "${ns}" "Argo CD sync of manifests/v2 (server-side apply)"
  info "$(printf '%-16s sync Succeeded   Argo CD: %-16s live limits.cpu=%s' "${ns}" "$(app_status "ranker-${ns}")" "$(field_value "${ns}")")"
done

#!/usr/bin/env bash
# Commit manifests/v2 (feature-cache container removed) and sync both apps.
source "$(dirname "$0")/lib.sh"

step "Committing v2: container '${REMOVED_CONTAINER}' removed from Git"
sha="$(git_publish v2)"
ok "v2 committed: ${sha}"

step "Syncing v2 (${sha:0:8}) with ServerSideApply=true"
for ns in "${NS_CONTROL}" "${NS_COMPACTED}"; do
  app_refresh "ranker-${ns}" "${sha}"
  info "ranker-${ns} before sync: $(app_status "ranker-${ns}")"
  app_sync "ranker-${ns}" "${sha}"
  ok "ranker-${ns}: sync operation Succeeded"
done
# Let the controller finish a post-sync comparison.
for ns in "${NS_CONTROL}" "${NS_COMPACTED}"; do
  k -n argocd annotate app "ranker-${ns}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
done
sleep 10

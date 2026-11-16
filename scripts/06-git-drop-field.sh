#!/usr/bin/env bash
# One Git commit: apps/ranker deletes retriever's CPU limit (manifests/v2) and
# apps/ranker-container deletes the feature-cache container (manifests/v2-container).
# Argo CD refreshes and compares. No sync yet.
source "$(dirname "$0")/lib.sh"

step "Git: delete retriever's CPU limit (apps/ranker) and the ${SIDECAR} container (apps/ranker-container)"
sha="$(git_publish v2)"
ok "v2 committed: ${sha}"
for ns in "${ALL_NS[@]}"; do
  app_refresh "ranker-${ns}" "${sha}"
  if [[ "${ns}" == "${NS_CONTAINER}" ]]; then
    snapshot 4-git-v2 "${ns}" "git commit: delete the ${SIDECAR} container (manifests/v2-container)"
    info "$(printf '%-16s Argo CD: %-20s live containers=%s' "${ns}" "$(app_status "ranker-${ns}")" "$(live_containers "${ns}")")"
  else
    snapshot 4-git-v2 "${ns}" "git commit: delete retriever's CPU limit (manifests/v2)"
    info "$(printf '%-16s Argo CD: %-20s live limits.cpu=%s' "${ns}" "$(app_status "ranker-${ns}")" "$(field_value "${ns}")")"
  fi
done

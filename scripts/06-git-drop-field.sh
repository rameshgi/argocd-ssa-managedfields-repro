#!/usr/bin/env bash
# The team deletes retriever's CPU limit from Git (manifests/v2). Argo CD
# refreshes and compares. No sync yet.
source "$(dirname "$0")/lib.sh"

step "Git: retriever's CPU limit deleted (manifests/v2)"
sha="$(git_publish v2)"
ok "v2 committed: ${sha}"
for ns in "${ALL_NS[@]}"; do
  app_refresh "ranker-${ns}" "${sha}"
  snapshot 4-git-v2 "${ns}" "git commit: delete retriever's CPU limit (manifests/v2)"
  info "$(printf '%-16s Argo CD: %-20s live limits.cpu=%s' "${ns}" "$(app_status "ranker-${ns}")" "$(field_value "${ns}")")"
done

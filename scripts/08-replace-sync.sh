#!/usr/bin/env bash
# Contrast: re-sync with Argo CD's existing PUT path, `Replace=true`.
#   demo-compacted : Replace=true alone. The drifted CPU limit is removed, but
#                    fields set by other managers (replicas, labels) are wiped too.
#   demo-put       : Replace=true + RespectIgnoreDifferences=true, with replicas and
#                    the day-2 labels declared in ignoreDifferences. Argo CD copies
#                    their live values into the target before the PUT, so they are kept.
source "$(dirname "$0")/lib.sh"
sha="$(git_sha v2)"

state() {
  deploy_json "$1" | jq -r --arg c "${FIELD_CONTAINER}" \
    '"limits.cpu=\(.spec.template.spec.containers[] | select(.name==$c) | .resources.limits.cpu // "<absent>")  replicas=\(.spec.replicas)  labels=\(.metadata.labels | keys | join(","))"'
}
put() { # ns label sync-options...
  local ns="$1" label="$2"; shift 2
  step "${ns}: re-sync v2 with $*"
  info "before: $(state "${ns}")"
  app_sync "ranker-${ns}" "${sha}" "$@"
  sleep 3
  app_refresh "ranker-${ns}" "${sha}"
  snapshot "${label}" "${ns}" "Argo CD sync of manifests/v2 with $* (PUT)"
  info "after:  $(state "${ns}")   Argo CD: $(app_status "ranker-${ns}")"
}
put "${NS_COMPACTED}" 6-put Replace=true
put "${NS_PUT}" 6-put-rid Replace=true RespectIgnoreDifferences=true

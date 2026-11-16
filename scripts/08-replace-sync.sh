#!/usr/bin/env bash
# Contrast: re-sync the compacted app with Argo CD's existing `Replace=true`
# option, which writes the object with a PUT instead of a server-side-apply
# PATCH. A PUT replaces the whole object, so ownership no longer matters and
# the drifted CPU limit is gone. Argo CD sends the manifest as written,
# though, so fields set by other managers (labels, annotations, replicas) are
# wiped too. A PUT-based sync must copy declared external fields from the
# live object first.
source "$(dirname "$0")/lib.sh"
ns="${NS_COMPACTED}"; app="ranker-${ns}"; sha="$(git_sha v2)"

state() {
  deploy_json "${ns}" | jq -r --arg c "${FIELD_CONTAINER}" \
    '"limits.cpu=\(.spec.template.spec.containers[] | select(.name==$c) | .resources.limits.cpu // "<absent>")  replicas=\(.spec.replicas)  labels=\(.metadata.labels | keys | join(","))"'
}
step "${ns}: re-sync v2 with Replace=true (PUT instead of PATCH)"
info "before: $(state)"
app_sync "${app}" "${sha}" Replace=true
sleep 3
app_refresh "${app}" "${sha}"
snapshot 6-put "${ns}" "Argo CD sync of manifests/v2 with Replace=true (PUT)"
info "after:  $(state)"
if [[ "$(field_value "${ns}")" == "<absent>" ]]; then ok "PUT removed the drifted CPU limit"; else bad "CPU limit still present after PUT"; fi

#!/usr/bin/env bash
# Incident and day-2 changes, made with kubectl.
#   field namespaces : on-call raises retriever's CPU limit. The Update CHANGES the
#                      value, so the API server moves ownership of that field from
#                      argocd-controller to kubectl-set.
#   demo-container   : on-call removes the crash-looping feature-cache container,
#                      then adds it back. The re-added container is a new list item,
#                      owned by kubectl-patch; Argo CD owns nothing in it.
# Then:
#   demo-resync    : Argo CD syncs v1 again (redeploy / self-heal) and takes the field back
#   demo-compacted : routine day-2 operations push Update managers past 10 and the
#                    API server compacts managedFields ("ancient-changes")
#   demo-put       : day-2 scale and labels (fields declared in ignoreDifferences)
source "$(dirname "$0")/lib.sh"
EDITOR_HELPER="${ROOT}/scripts/helpers/kube-editor-annotate.sh"
v1="$(git_sha v1)"

step "Incident: ${INCIDENT_CMD}"
for ns in "${FIELD_NS[@]}"; do
  k -n "${ns}" set resources deploy/"${DEPLOY}" -c "${FIELD_CONTAINER}" --limits=cpu="${INCIDENT_CPU}" >/dev/null
  app_refresh "ranker-${ns}" "${v1}"
  snapshot 2-incident "${ns}" "${INCIDENT_CMD}"
  ok "${ns}: limits.cpu=$(field_value "${ns}")   owner: $(field_owners "${ns}")   Argo CD: $(app_status "ranker-${ns}")"
done

step "Incident (${NS_CONTAINER}): remove the ${SIDECAR} container, then add it back"
ns="${NS_CONTAINER}"
idx="$(deploy_json "${ns}" | jq --arg c "${SIDECAR}" '[.spec.template.spec.containers[].name] | index($c)')"
k -n "${ns}" patch deploy "${DEPLOY}" --type json -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/${idx}\"}]" >/dev/null
app_refresh "ranker-${ns}" "${v1}"
snapshot 2a-remove "${ns}" "kubectl patch deploy ${DEPLOY} --type json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/${idx}\"}]'"
ok "removed:  containers=$(live_containers "${ns}")   Argo CD: $(app_status "ranker-${ns}")"
sleep 1.1
SIDECAR_SPEC='{"name":"feature-cache","image":"registry.k8s.io/pause:3.10","env":[{"name":"CACHE_MODE","value":"legacy"}],"resources":{"requests":{"cpu":"10m","memory":"16Mi"}}}'
k -n "${ns}" patch deploy "${DEPLOY}" --type json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/-\",\"value\":${SIDECAR_SPEC}}]" >/dev/null
app_refresh "ranker-${ns}" "${v1}"
snapshot 2b-readd "${ns}" "kubectl patch deploy ${DEPLOY} --type json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/-\",\"value\":{\"name\":\"${SIDECAR}\",…same spec as Git…}}]'"
ok "re-added: containers=$(live_containers "${ns}")   owner of ${SIDECAR}: $(container_owners "${ns}" "${SIDECAR}")   Argo CD: $(app_status "ranker-${ns}")"

step "${NS_RESYNC}: Argo CD syncs v1 again before Git changes (redeploy or self-heal)"
app_sync "ranker-${NS_RESYNC}" "${v1}"
app_refresh "ranker-${NS_RESYNC}" "${v1}"
snapshot 3-resync "${NS_RESYNC}" "Argo CD sync of manifests/v1 again (server-side apply, force-conflicts)"
ok "limits.cpu=$(field_value "${NS_RESYNC}")   owner: $(field_owners "${NS_RESYNC}")   Argo CD: $(app_status "ranker-${NS_RESYNC}")"

step "${NS_PUT}: day-2 scale and labels"
k -n "${NS_PUT}" label deploy "${DEPLOY}" team=search >/dev/null
k -n "${NS_PUT}" label deploy "${DEPLOY}" --field-manager=cost-attribution-bot cost-center=ml-42 >/dev/null
k -n "${NS_PUT}" scale deploy/"${DEPLOY}" --replicas=2 >/dev/null
snapshot 3-day2 "${NS_PUT}" "kubectl label deploy ${DEPLOY} team=search; kubectl label … cost-center=ml-42; kubectl scale … --replicas=2"
ok "replicas=2, labels team and cost-center added"

# Day-2 operations for demo-compacted. Each entry: "<manager>|<command against \$NS>".
# Managers other than kubectl-* are SIMULATED: the script sets those names with
# --field-manager to stand in for controllers and automation. None of the
# commands touches retriever's CPU limit.
VERBS=(
  "kubectl-label|k -n \$NS label deploy ${DEPLOY} team=search --overwrite"
  "kubectl-annotate|k -n \$NS annotate deploy ${DEPLOY} owner=ranking-oncall --overwrite"
  "kubectl-patch|k -n \$NS patch deploy ${DEPLOY} --type merge -p '{\"metadata\":{\"annotations\":{\"ticket\":\"INC-1234\"}}}'"
  "kubectl-rollout|k -n \$NS rollout restart deploy/${DEPLOY}"
  "kubectl-scale|k -n \$NS scale deploy/${DEPLOY} --replicas=2"
  "kubectl-edit|KUBE_EDITOR=${EDITOR_HELPER} k -n \$NS edit deploy/${DEPLOY} -o json"
  "kubectl-replace|deploy_json \$NS | jq '.metadata.annotations.\"replaced-at\"=\"'\$(date +%s)'\"' | k -n \$NS replace -f -"
  "hpa-controller|k -n \$NS annotate deploy ${DEPLOY} --field-manager=hpa-controller autoscaling/last-scale=\$(date +%s) --overwrite"
  "migration-orchestrator|k -n \$NS patch deploy ${DEPLOY} --field-manager=migration-orchestrator --type merge -p '{\"metadata\":{\"annotations\":{\"migration/state\":\"done\"}}}'"
  "cost-attribution-bot|k -n \$NS label deploy ${DEPLOY} --field-manager=cost-attribution-bot cost-center=ml-42 --overwrite"
  "release-tagger|k -n \$NS annotate deploy ${DEPLOY} --field-manager=release-tagger release=2026.11 --overwrite"
  "security-scanner|k -n \$NS annotate deploy ${DEPLOY} --field-manager=security-scanner scanned=ok --overwrite"
  "capacity-planner|k -n \$NS label deploy ${DEPLOY} --field-manager=capacity-planner tier=gold --overwrite"
)
pretty_cmd() { # mgr cmd
  local c="$2"
  c="${c//k -n \$NS /kubectl }"
  c="${c//KUBE_EDITOR=${EDITOR_HELPER} /}"
  c="${c//deploy_json \$NS/kubectl get deploy ${DEPLOY} -o json}"
  c="${c//\'\$(date +%s)\'/<now>}"
  c="${c//\$(date +%s)/<now>}"
  [[ "$1" == kubectl-edit ]] && c="${c}   # editor adds annotation edited-by"
  [[ "$1" != kubectl-* ]] && c="${c}   # simulated manager name"
  printf '%s' "${c}"
}

step "${NS_COMPACTED}: routine day-2 operations until the API server compacts managedFields"
NS="${NS_COMPACTED}"; idx=0
for entry in "${VERBS[@]}"; do
  has_manager "${NS}" ancient-changes && break
  mgr="${entry%%|*}"; cmd="${entry#*|}"
  sleep 1.1   # managedFields timestamps have 1s resolution; keep ordering unambiguous
  eval "${cmd}" >/dev/null
  idx=$((idx + 1))
  snapshot "3v-$(printf %02d "${idx}")" "${NS}" "$(pretty_cmd "${mgr}" "${cmd}")"
  info "$(printf '%-24s -> Update managers: %2s   owner of limits.cpu: %s' "${mgr}" "$(update_manager_count "${NS}")" "$(field_owners "${NS}")")"
done
has_manager "${NS}" ancient-changes || die "ran out of verbs before compaction happened"
ok "compacted: the owner of limits.cpu is now recorded as '$(field_owners "${NS}")'"

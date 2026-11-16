#!/usr/bin/env bash
# Incident: on-call raises retriever's CPU limit with kubectl. Because kubectl
# sends an Update that CHANGES the value, the API server moves ownership of that
# one field from argocd-controller to kubectl-set.
# Then, per namespace:
#   demo-resync    : Argo CD syncs v1 again (redeploy / self-heal), which takes the field back
#   demo-compacted : routine day-2 kubectl operations push Update managers past 10,
#                    and the API server compacts managedFields ("ancient-changes")
#   demo-drift     : nothing else happens
source "$(dirname "$0")/lib.sh"
EDITOR_HELPER="${ROOT}/scripts/helpers/kube-editor-annotate.sh"
v1="$(git_sha v1)"

step "Incident: ${INCIDENT_CMD}"
for ns in "${ALL_NS[@]}"; do
  k -n "${ns}" set resources deploy/"${DEPLOY}" -c "${FIELD_CONTAINER}" --limits=cpu="${INCIDENT_CPU}" >/dev/null
  app_refresh "ranker-${ns}" "${v1}"
  snapshot 2-incident "${ns}" "${INCIDENT_CMD}"
  ok "${ns}: limits.cpu=$(field_value "${ns}")   owner: $(field_owners "${ns}")   Argo CD: $(app_status "ranker-${ns}")"
done

step "${NS_RESYNC}: Argo CD syncs v1 again before Git changes (redeploy or self-heal)"
app_sync "ranker-${NS_RESYNC}" "${v1}"
app_refresh "ranker-${NS_RESYNC}" "${v1}"
snapshot 3-resync "${NS_RESYNC}" "Argo CD sync of manifests/v1 again (server-side apply, force-conflicts)"
ok "limits.cpu=$(field_value "${NS_RESYNC}")   owner: $(field_owners "${NS_RESYNC}")   Argo CD: $(app_status "ranker-${NS_RESYNC}")"

# Each entry: "<expected manager>|<command run against namespace \$NS>". None
# of them touches retriever's CPU limit.
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

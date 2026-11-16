#!/usr/bin/env bash
# For BOTH namespaces:
#   1. Create the Deployment with *client-side* `kubectl apply` - the way objects
#      get created by humans, CI scripts, migration tooling or an older Argo CD
#      setup before server-side apply was enabled. This leaves a managedFields
#      entry {manager: kubectl-client-side-apply, operation: Update} that owns
#      all three containers.
#   2. Run ordinary day-2 kubectl verbs, each of which registers its own
#      field manager with operation=Update.
#        demo-control   : stop while Update managers <= 8   (no compaction)
#        demo-compacted : keep going until > 10 Update managers, at which
#                         point the API server merges the OLDEST Update
#                         entries into a single "ancient-changes" entry, and
#                         the kubectl-client-side-apply entry disappears.
# None of the verbs touches the `feature-cache` container.
source "$(dirname "$0")/lib.sh"

EDITOR_HELPER="${ROOT}/scripts/helpers/kube-editor-annotate.sh"

# Each entry: "<expected manager>|<command run against namespace \$NS>"
VERBS=(
  "kubectl-label|k -n \$NS label deploy ${DEPLOY} team=search --overwrite"
  "kubectl-annotate|k -n \$NS annotate deploy ${DEPLOY} owner=ranking-oncall --overwrite"
  "kubectl-patch|k -n \$NS patch deploy ${DEPLOY} --type merge -p '{\"metadata\":{\"annotations\":{\"ticket\":\"INC-1234\"}}}'"
  "kubectl-set|k -n \$NS set env deploy/${DEPLOY} -c retriever LOG_LEVEL=debug"
  "kubectl-rollout|k -n \$NS rollout restart deploy/${DEPLOY}"
  "kubectl-scale|k -n \$NS scale deploy/${DEPLOY} --replicas=2"
  "kubectl-edit|KUBE_EDITOR=${EDITOR_HELPER} k -n \$NS edit deploy/${DEPLOY} -o json"
  "kubectl-replace|deploy_json \$NS | jq '.metadata.annotations.\"replaced-at\"=\"'\$(date +%s)'\"' | k -n \$NS replace -f -"
  "migration-orchestrator|k -n \$NS patch deploy ${DEPLOY} --field-manager=migration-orchestrator --type merge -p '{\"metadata\":{\"annotations\":{\"migration/state\":\"done\"}}}'"
  "cost-attribution-bot|k -n \$NS label deploy ${DEPLOY} --field-manager=cost-attribution-bot cost-center=ml-42 --overwrite"
  "release-tagger|k -n \$NS annotate deploy ${DEPLOY} --field-manager=release-tagger release=2026.11 --overwrite"
  "oncall-hotfix|k -n \$NS patch deploy ${DEPLOY} --field-manager=oncall-hotfix --type merge -p '{\"metadata\":{\"labels\":{\"hotfix\":\"true\"}}}'"
  "security-scanner|k -n \$NS annotate deploy ${DEPLOY} --field-manager=security-scanner scanned=ok --overwrite"
  "capacity-planner|k -n \$NS label deploy ${DEPLOY} --field-manager=capacity-planner tier=gold --overwrite"
)

bootstrap() { # ns
  local NS="$1"
  k create namespace "${NS}" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "${NS}" apply -f "${ROOT}/manifests/v1/deployment.yaml" >/dev/null   # client-side apply
  k -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout=180s >/dev/null
  # Make sure kube-controller-manager's status entry already exists so it
  # cannot appear later and tip the control namespace over the cap.
  sleep 2
  ok "${NS}: created via client-side apply; Update managers = $(update_manager_count "${NS}")"
}

inflate() { # ns mode(control|compact)
  local NS="$1" mode="$2" entry mgr cmd n
  prev_mgrs=""; last_mgr=""
  for entry in "${VERBS[@]}"; do
    n="$(update_manager_count "${NS}")"
    if [[ "${mode}" == control && ${n} -ge 8 ]]; then break; fi
    if [[ "${mode}" == compact ]] && ! has_manager "${NS}" "${CSA_MANAGER}" Update; then break; fi
    mgr="${entry%%|*}"; cmd="${entry#*|}"
    # Remember the state right before each verb; after the loop this holds the
    # state just before the verb that triggered compaction.
    [[ "${mode}" == compact ]] && snapshot 2-before-compaction "${NS}" "${prev_mgrs:-}"
    prev_mgrs="${prev_mgrs:+${prev_mgrs}, }${mgr}"
    last_mgr="${mgr}"
    sleep 1.1   # managedFields timestamps have 1s resolution; keep ordering unambiguous
    eval "${cmd}" >/dev/null
    info "$(printf '%-24s -> Update managers: %2s   %s entry present: %s' \
      "${mgr}" "$(update_manager_count "${NS}")" "${CSA_MANAGER}" \
      "$(has_manager "${NS}" "${CSA_MANAGER}" Update && echo yes || echo NO)")"
  done
}

step "Bootstrapping Deployments with client-side kubectl apply"
bootstrap "${NS_CONTROL}"
bootstrap "${NS_COMPACTED}"
snapshot 1-csa-apply "${NS_COMPACTED}"

step "${NS_CONTROL}: adding field managers, staying under the cap"
inflate "${NS_CONTROL}" control
has_manager "${NS_CONTROL}" "${CSA_MANAGER}" Update \
  && ok "${CSA_MANAGER} entry still present" || die "control namespace was compacted unexpectedly"

step "${NS_COMPACTED}: adding field managers until the API server compacts managedFields"
inflate "${NS_COMPACTED}" compact
has_manager "${NS_COMPACTED}" "${CSA_MANAGER}" Update \
  && die "ran out of verbs before compaction happened" || ok "${CSA_MANAGER} entry is GONE (merged into ancient-changes)"
snapshot 3-after-compaction "${NS_COMPACTED}" "${last_mgr}"

step "${NS_COMPACTED}: managedFields after compaction"
show_managers "${NS_COMPACTED}"
info ""
info "owners of container '${REMOVED_CONTAINER}' in ${NS_CONTROL}:   $(container_owners "${NS_CONTROL}" "${REMOVED_CONTAINER}" | paste -sd, -)"
info "owners of container '${REMOVED_CONTAINER}' in ${NS_COMPACTED}: $(container_owners "${NS_COMPACTED}" "${REMOVED_CONTAINER}" | paste -sd, -)"

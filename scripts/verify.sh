#!/usr/bin/env bash
# Report the outcome of the server-side-apply sync of v2 (step 07). Exit status:
#   default         : 0 if the bug reproduced in every bug namespace and the control is clean
#   EXPECT_FIXED=1  : 0 only if Git's deletions took effect everywhere (to test a fix)
#
# Step 08 later re-syncs demo-compacted and demo-put with a PUT, which removes the
# drift. For a namespace whose last sync was such a PUT, the verdict is taken from
# the snapshot recorded right after step 07 (.work/snapshots/5-argo-sync-v2.<ns>.json),
# and the current, cleaned state is shown next to it. So `make verify` after
# `make repro` gives the same verdict as the run itself.
source "$(dirname "$0")/lib.sh"

rc=0
expect_bug() { [[ "${EXPECT_FIXED:-0}" == 1 ]] && rc=1 || true; }
expect_clean_but_clean() { [[ "${EXPECT_FIXED:-0}" == 1 ]] || { warn "$1: bug did NOT reproduce"; rc=1; }; }

# Was the namespace's last sync step 08's PUT (Replace=true)?
put_resynced() {
  k -n argocd get app "ranker-$1" -o json | jq -e '.status.operationState.operation.sync.syncOptions // [] | index("Replace=true")' >/dev/null
}
# Value of the drifting field after step 07: live, or from the snapshot if step 08 re-synced.
after_step7() { # ns
  local f="${SNAP_DIR}/5-argo-sync-v2.$1.json"
  if put_resynced "$1"; then
    [[ -f "${f}" ]] || die "$1 was re-synced by step 08 but ${f} is missing; run make repro"
    jq -r --arg c "${FIELD_CONTAINER}" '.spec.template.spec.containers[] | select(.name==$c) | .resources.limits.cpu // "<absent>"' "${f}"
  else
    field_value "$1"
  fi
}
owner_after_step7() { # ns
  local f="${SNAP_DIR}/5-argo-sync-v2.$1.json"
  if put_resynced "$1"; then
    jq -r --arg c "k:{\"name\":\"${FIELD_CONTAINER}\"}" '[.metadata.managedFields[]
      | select(.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$c]["f:resources"]["f:limits"]["f:cpu"] != null)
      | "\(.manager) (\(.operation))"] | join(", ")' "${f}"
  else
    field_owners "$1"
  fi
}
status_after_step7() { # ns
  if put_resynced "$1"; then jq -r '._argo' "${SNAP_DIR}/5-argo-sync-v2.$1.json"; else app_status "ranker-$1"; fi
}
note() { put_resynced "$1" && echo "(since cleaned by step 08 PUT; now: $(field_value "$1"))" || true; }

step "Result of the server-side-apply sync of v2: what Git deleted vs. what stayed live"
printf '    %-16s %-24s %-12s %-24s %s\n' NAMESPACE "DELETED IN GIT" "STILL LIVE" "OWNER" "NOTE"
for ns in "${FIELD_NS[@]}"; do
  printf '    %-16s %-24s %-12s %-24s %s\n' "${ns}" "retriever limits.cpu" "$(after_step7 "${ns}")" "$(owner_after_step7 "${ns}")" "$(note "${ns}")"
done
ns="${NS_CONTAINER}"; live="$(live_containers "${ns}" | tr ',' '\n' | grep -qx "${SIDECAR}" && echo yes || echo no)"
printf '    %-16s %-24s %-12s %-24s %s\n' "${ns}" "container ${SIDECAR}" "${live}" "$(container_owners "${ns}" "${SIDECAR}")" ""
echo
for ns in "${FIELD_NS[@]}"; do
  v="$(after_step7 "${ns}")"
  if [[ "${ns}" == "${NS_RESYNC}" ]]; then
    [[ "${v}" == "<absent>" ]] && ok "${ns}: CPU limit removed, as Git says" || { bad "${ns}: CPU limit still ${v} (control should be clean)"; rc=1; }
  elif [[ "${v}" == "<absent>" ]]; then ok "${ns}: CPU limit removed"; expect_clean_but_clean "${ns}"
  else bad "${ns}: retriever kept limits.cpu=${v}, which is not in Git, while Argo CD reported $(status_after_step7 "${ns}")  <== SILENT DRIFT $(note "${ns}")"; expect_bug
  fi
done
if [[ "${live}" == yes ]]; then
  bad "${NS_CONTAINER}: the ${SIDECAR} container is still running, although Git deleted it, and Argo CD says $(app_status "ranker-${NS_CONTAINER}")  <== SILENT DRIFT"; expect_bug
else ok "${NS_CONTAINER}: ${SIDECAR} removed"; expect_clean_but_clean "${NS_CONTAINER}"
fi
exit "${rc}"

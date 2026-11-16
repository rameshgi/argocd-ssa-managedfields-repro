#!/usr/bin/env bash
# Report the outcome after the v2 sync (step 07). Exit status:
#   default         : 0 if the bug reproduced in every bug namespace and the control is clean
#   EXPECT_FIXED=1  : 0 only if Git's deletions took effect everywhere (to test a fix)
source "$(dirname "$0")/lib.sh"

rc=0
expect_bug() { [[ "${EXPECT_FIXED:-0}" == 1 ]] && rc=1 || true; }
expect_clean_but_clean() { [[ "${EXPECT_FIXED:-0}" == 1 ]] || { warn "$1: bug did NOT reproduce"; rc=1; }; }

step "Result: what Git deleted vs. what is still live"
printf '    %-16s %-34s %-12s %-18s %s\n' NAMESPACE "DELETED IN GIT" "STILL LIVE" "ARGO SYNC/HEALTH" "OWNER"
for ns in "${FIELD_NS[@]}"; do
  printf '    %-16s %-34s %-12s %-18s %s\n' "${ns}" "retriever limits.cpu" "$(field_value "${ns}")" "$(app_status "ranker-${ns}")" "$(field_owners "${ns}")"
done
ns="${NS_CONTAINER}"; live="$(live_containers "${ns}" | tr ',' '\n' | grep -qx "${SIDECAR}" && echo yes || echo no)"
printf '    %-16s %-34s %-12s %-18s %s\n' "${ns}" "container ${SIDECAR}" "${live}" "$(app_status "ranker-${ns}")" "$(container_owners "${ns}" "${SIDECAR}")"
echo
for ns in "${FIELD_NS[@]}"; do
  v="$(field_value "${ns}")"; s="$(app_status "ranker-${ns}")"
  if [[ "${ns}" == "${NS_RESYNC}" ]]; then
    [[ "${v}" == "<absent>" ]] && ok "${ns}: CPU limit removed, as Git says" || { bad "${ns}: CPU limit still ${v} (control should be clean)"; rc=1; }
  elif [[ "${v}" == "<absent>" ]]; then ok "${ns}: CPU limit removed"; expect_clean_but_clean "${ns}"
  else bad "${ns}: retriever still runs with limits.cpu=${v}, which is not in Git, and Argo CD says ${s}  <== SILENT DRIFT"; expect_bug
  fi
done
if [[ "${live}" == yes ]]; then
  bad "${NS_CONTAINER}: the ${SIDECAR} container is still running, although Git deleted it, and Argo CD says $(app_status "ranker-${NS_CONTAINER}")  <== SILENT DRIFT"; expect_bug
else ok "${NS_CONTAINER}: ${SIDECAR} removed"; expect_clean_but_clean "${NS_CONTAINER}"
fi
exit "${rc}"

#!/usr/bin/env bash
# Report the outcome. Exit status:
#   default         : 0 if the bug reproduced (drift + compacted keep the field and
#                     report Synced; the resync control is clean)
#   EXPECT_FIXED=1  : 0 only if the field is gone in every namespace (to test a fix)
source "$(dirname "$0")/lib.sh"

rc=0
step "Result: Git no longer sets ${FIELD_DESC}"
printf '    %-16s %-12s %-18s %s\n' NAMESPACE "LIVE VALUE" "ARGO SYNC/HEALTH" "OWNER OF THE FIELD"
for ns in "${ALL_NS[@]}"; do
  printf '    %-16s %-12s %-18s %s\n' "${ns}" "$(field_value "${ns}")" "$(app_status "ranker-${ns}")" "$(field_owners "${ns}")"
done
echo
for ns in "${ALL_NS[@]}"; do
  v="$(field_value "${ns}")"; s="$(app_status "ranker-${ns}")"
  if [[ "${ns}" == "${NS_RESYNC}" ]]; then
    [[ "${v}" == "<absent>" ]] && ok "${ns}: CPU limit removed, as Git says" || { bad "${ns}: CPU limit still ${v} (control should be clean)"; rc=1; }
  elif [[ "${v}" == "<absent>" ]]; then
    ok "${ns}: CPU limit removed"
    [[ "${EXPECT_FIXED:-0}" == 1 ]] || { warn "${ns}: bug did NOT reproduce"; rc=1; }
  else
    bad "${ns}: retriever still runs with limits.cpu=${v}, which is not in Git, and Argo CD says ${s}  <== SILENT DRIFT"
    [[ "${EXPECT_FIXED:-0}" == 1 ]] && rc=1
  fi
done
exit "${rc}"

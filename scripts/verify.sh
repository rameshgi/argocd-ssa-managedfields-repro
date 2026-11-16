#!/usr/bin/env bash
# Report the outcome. Exit status:
#   default         : 0 if the bug reproduced (control OK, compacted has a zombie container)
#   EXPECT_FIXED=1  : 0 only if BOTH namespaces lost the container (use this to test a fix)
source "$(dirname "$0")/lib.sh"

rc=0
step "Result"
printf '    %-16s %-34s %-18s %s\n' NAMESPACE "LIVE CONTAINERS" "ARGO SYNC/HEALTH" "OWNERS OF ${REMOVED_CONTAINER}"
for ns in "${NS_CONTROL}" "${NS_COMPACTED}"; do
  owners="$(container_owners "${ns}" "${REMOVED_CONTAINER}" | paste -sd, -)"
  printf '    %-16s %-34s %-18s %s\n' "${ns}" "$(live_containers "${ns}")" "$(app_status "ranker-${ns}")" "${owners:--}"
done
echo

zombie() { live_containers "$1" | tr ',' '\n' | grep -qx "${REMOVED_CONTAINER}"; }

if zombie "${NS_CONTROL}"; then bad "${NS_CONTROL}: '${REMOVED_CONTAINER}' still present (unexpected - control should be clean)"; rc=1
else ok "${NS_CONTROL}: '${REMOVED_CONTAINER}' was removed, as Git says"; fi

if zombie "${NS_COMPACTED}"; then
  bad "${NS_COMPACTED}: '${REMOVED_CONTAINER}' is still running although it is no longer in Git  <== BUG"
  [[ "$(app_status "ranker-${NS_COMPACTED}")" == Synced/* ]] && bad "${NS_COMPACTED}: ...and Argo CD reports the Application as Synced"
  [[ "${EXPECT_FIXED:-0}" == 1 ]] && rc=1
else
  ok "${NS_COMPACTED}: '${REMOVED_CONTAINER}' was removed"
  [[ "${EXPECT_FIXED:-0}" == 1 ]] || { warn "bug did NOT reproduce"; rc=1; }
fi
exit "${rc}"

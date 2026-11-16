#!/usr/bin/env bash
# End-to-end reproduction. Safe to re-run: the cluster is reused if present,
# but the demo namespaces/apps are recreated from scratch.
source "$(dirname "$0")/lib.sh"
D="$(dirname "$0")"

"${D}/00-prereqs.sh"
"${D}/01-cluster-up.sh"
"${D}/02-install-argocd.sh"

step "Resetting demo state"
k -n argocd delete app "ranker-${NS_CONTROL}" "ranker-${NS_COMPACTED}" --ignore-not-found --wait >/dev/null
k delete namespace "${NS_CONTROL}" "${NS_COMPACTED}" --ignore-not-found --wait >/dev/null
ok "clean"

rm -rf "${SNAP_DIR}"
"${D}/03-seed-git.sh"
"${D}/04-bootstrap-and-inflate.sh"
"${D}/05-create-apps.sh"
"${D}/06-remove-container.sh"
"${D}/verify.sh" || rc=$?
"${D}/render-timeline.sh"
exit "${rc:-0}"

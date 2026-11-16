#!/usr/bin/env bash
# End-to-end reproduction. Safe to re-run: the cluster is reused if present,
# but the demo namespaces/apps and the Git repo are recreated from scratch.
source "$(dirname "$0")/lib.sh"
D="$(dirname "$0")"

"${D}/00-prereqs.sh"
"${D}/01-cluster-up.sh"
"${D}/02-install-argocd.sh"

step "Resetting demo state"
for app in $(k -n argocd get app -o name 2>/dev/null); do k -n argocd delete "${app}" --wait >/dev/null; done
for ns in $(k get ns -o name | grep '^namespace/demo-' || true); do k delete "${ns}" --wait >/dev/null; done
rm -rf "${SNAP_DIR}"
ok "clean"

"${D}/03-seed-git.sh"
"${D}/04-create-apps.sh"
"${D}/05-incident.sh"
"${D}/06-git-drop-field.sh"
"${D}/07-sync.sh"
"${D}/verify.sh" || rc=$?
"${D}/08-replace-sync.sh"
"${D}/render-timeline.sh"
exit "${rc:-0}"

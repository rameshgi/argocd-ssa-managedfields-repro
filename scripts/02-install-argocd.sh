#!/usr/bin/env bash
# Install a pinned Argo CD release and give argocd-repo-server read access to
# the host-mounted Git repo.
source "$(dirname "$0")/lib.sh"

step "Installing Argo CD ${ARGOCD_VERSION}"
k create namespace argocd --dry-run=client -o yaml | k apply -f - >/dev/null
# --server-side because the Argo CD CRDs exceed the client-side-apply annotation limit.
k apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
ok "manifests applied"

step "Mounting /repro-git into argocd-repo-server"
# safe.directory=* : the bare repo is owned by the host user, not uid 999.
k -n argocd patch deployment argocd-repo-server --type strategic -p '{
  "spec": {"template": {"spec": {
    "volumes": [{"name": "repro-git", "hostPath": {"path": "/repro-git", "type": "Directory"}}],
    "containers": [{
      "name": "argocd-repo-server",
      "volumeMounts": [{"name": "repro-git", "mountPath": "/repro-git", "readOnly": true}],
      "env": [
        {"name": "GIT_CONFIG_COUNT",   "value": "1"},
        {"name": "GIT_CONFIG_KEY_0",   "value": "safe.directory"},
        {"name": "GIT_CONFIG_VALUE_0", "value": "*"}
      ]
    }]
  }}}
}' >/dev/null

step "Waiting for Argo CD to become ready"
for d in argocd-repo-server argocd-redis argocd-server; do
  k -n argocd rollout status deployment "${d}" --timeout=300s >/dev/null && ok "${d}"
done
k -n argocd rollout status statefulset argocd-application-controller --timeout=300s >/dev/null && ok "argocd-application-controller"
info "image: $(k -n argocd get sts argocd-application-controller -o jsonpath='{.spec.template.spec.containers[0].image}')"

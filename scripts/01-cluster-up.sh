#!/usr/bin/env bash
# Create a single-node kind cluster. The host directory holding the bare Git
# repo is mounted into the node at /repro-git so argocd-repo-server can read it
# via a file:// URL (no external Git hosting needed).
source "$(dirname "$0")/lib.sh"

step "Creating kind cluster '${CLUSTER_NAME}'"
mkdir -p "${GIT_HOST_DIR}"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "cluster already exists"
  exit 0
fi

cat > "${WORK_DIR}/kind-config.yaml" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${GIT_HOST_DIR}
        containerPath: /repro-git
YAML

kind create cluster --name "${CLUSTER_NAME}" --config "${WORK_DIR}/kind-config.yaml" \
  ${KIND_NODE_IMAGE:+--image "${KIND_NODE_IMAGE}"} --wait 120s
ok "kubernetes $(k version -o json | jq -r .serverVersion.gitVersion)"

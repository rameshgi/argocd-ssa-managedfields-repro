#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
step "Deleting kind cluster '${CLUSTER_NAME}'"
kind delete cluster --name "${CLUSTER_NAME}"
rm -rf "${WORK_DIR}"

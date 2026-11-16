#!/usr/bin/env bash
# Create a local bare Git repo (served to Argo CD as file:///repro-git/manifests.git)
# and commit manifests/v1 (three containers) to it.
source "$(dirname "$0")/lib.sh"

step "Seeding Git repo with manifests/v1 (3 containers)"
rm -rf "${BARE_REPO}" "${CHECKOUT_DIR}"
git init -q --bare --initial-branch=main "${BARE_REPO}"
git clone -q "${BARE_REPO}" "${CHECKOUT_DIR}" 2>/dev/null
chmod -R a+rX "${GIT_HOST_DIR}"
sha="$(git_publish v1)"
ok "v1 committed: ${sha}"

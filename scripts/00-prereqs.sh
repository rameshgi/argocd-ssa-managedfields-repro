#!/usr/bin/env bash
# Check that the required CLIs and a Docker daemon are available.
source "$(dirname "$0")/lib.sh"

step "Checking prerequisites"
missing=0
for bin in docker kind kubectl jq git; do
  if command -v "${bin}" >/dev/null; then ok "${bin}: $(command -v "${bin}")"; else bad "${bin} not found"; missing=1; fi
done
[[ ${missing} -eq 0 ]] || die "install the missing tools (macOS: brew install kind kubectl jq; plus Docker Desktop, OrbStack or colima)"
docker info >/dev/null 2>&1 || die "docker daemon is not reachable (start Docker Desktop / OrbStack, or run: colima start)"
ok "docker daemon reachable ($(docker info --format '{{.ServerVersion}}'))"

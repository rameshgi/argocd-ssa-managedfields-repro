#!/usr/bin/env bash
# Non-interactive $KUBE_EDITOR for `kubectl edit -o json`: adds an annotation.
set -euo pipefail
f="$1"
jq '.metadata.annotations["edited-by"] = "kubectl-edit"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"

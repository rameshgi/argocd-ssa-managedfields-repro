.PHONY: repro up argocd verify down
repro:  ; ./scripts/run-all.sh
up:     ; ./scripts/00-prereqs.sh && ./scripts/01-cluster-up.sh && ./scripts/02-install-argocd.sh
verify: ; ./scripts/verify.sh
down:   ; ./scripts/cluster-down.sh

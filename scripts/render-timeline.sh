#!/usr/bin/env bash
# Render the snapshots taken during a run (.work/snapshots/*.json) into the
# click-through timeline in README.md, between the timeline:start/end markers.
# Every YAML block and table below is generated from real API-server output.
source "$(dirname "$0")/lib.sh"

README="${ROOT}/README.md"
OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT
C="${NS_COMPACTED}"; K="${NS_CONTROL}"
snap() { echo "${SNAP_DIR}/$1.$2.json"; }
for f in 1-csa-apply.$C 2-before-compaction.$C 3-after-compaction.$C 4-argo-sync-v1.$C 4-argo-sync-v1.$K \
         5-v2-committed.$C 5-v2-committed.$K 6-argo-sync-v2.$C 6-argo-sync-v2.$K; do
  [[ -f "${SNAP_DIR}/${f}.json" ]] || die "missing snapshot ${f}; run scripts/run-all.sh first"
done

GIT_V2_CONTAINERS="$(sed -n 's/^        - name: //p' "${ROOT}/manifests/v2/deployment.yaml" | paste -sd, -)"

# Live containers as YAML. With $1=diff, containers missing from Git v2 get a "+".
containers_block() { # file [diff]
  local mode="${2:-}"
  if [[ "${mode}" == diff ]]; then
    echo '```diff'
    echo "# live spec.template.spec.containers vs. Git (manifests/v2). '+' = in the cluster but NOT in Git"
  else
    echo '```yaml'
    echo "# live spec.template.spec.containers"
  fi
  jq -r --arg git "${GIT_V2_CONTAINERS}" --arg mode "${mode}" '
    ($git | split(",")) as $g
    | .spec.template.spec.containers[]
    | (if $mode == "diff" and ((.name as $n | $g | index($n)) | not) then "+" else " " end) as $p
    | "\($p) - name: \(.name)\n\($p)   image: \(.image)"
      + (if .env then "\n\($p)   env: [" + (.env | map("\(.name)=\(.value)") | join(", ")) + "]" else "" end)
  ' "$1"
  echo '```'
}

# One row per managedFields entry: which containers it claims + its other fields.
managed_table() { # file
  echo "| manager | operation | time | containers it owns | other fields it owns |"
  echo "|---|---|---|---|---|"
  jq -r --arg rc "${REMOVED_CONTAINER}" '
    def cname: capture("^k:\\{\"name\":\"(?<n>[^\"]+)\"\\}$").n;
    def leaves: [paths(type == "object" and length == 0)]
      | map(select(last != ".") | map(sub("^[fk]:"; "")) | join("."));
    .metadata.managedFields[]
    | ((.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"] // {}) | keys | map(cname)) as $c
    | (.fieldsV1 | leaves | map(select(startswith("spec.template.spec.containers") | not))) as $o
    | ($c | index($rc)) as $owns
    | [ (if $owns then "**\(.manager)**" else .manager end),
        (.operation + (if .subresource then " (`\(.subresource)`)" else "" end)),
        ((.time // "") | sub("^.*T"; "") | sub("Z$"; "")),
        (if ($c | length) == 0 then "—" else ($c | map(if . == $rc then "**`\(.)`** 🧟" else "`\(.)`" end) | join(", ")) end),
        (if ($o | length) == 0 then "—"
         else ($o[0:3] | map("`\(.)`") | join(", ")) + (if ($o | length) > 3 then " … (+\(($o | length) - 3))" else "" end) end)
      ] | "| " + join(" | ") + " |"
  ' "$1"
}

# The raw fieldsV1 subtree each owner holds for the removed container.
owner_claims() { # file
  local body
  body="$(jq -r --arg key "k:{\"name\":\"${REMOVED_CONTAINER}\"}" '
    .metadata.managedFields[]
    | (.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$key]) as $v
    | select($v != null)
    | "// manager: \(.manager)  operation: \(.operation)\n// f:spec.f:template.f:spec.f:containers.\($key)\n"
      + ($v | tostring) + "\n"' "$1" | while IFS= read -r line; do
        if [[ "${line}" == "{"* ]]; then jq . <<<"${line}"; echo; else echo "${line}"; fi
      done)"
  [[ -z "${body}" ]] && body="// no managedFields entry claims ${REMOVED_CONTAINER} any more"
  printf '<details><summary><code>fieldsV1</code> claims on <code>%s</code></summary>\n\n```jsonc\n%s\n```\n\n</details>\n' \
    "${REMOVED_CONTAINER}" "${body}"
}

argo_of() { local a; a="$(jq -r '._argo' "$1")"; echo "${a:-n/a}"; }
note_of() { jq -r '._note' "$1"; }

# step <n> <title> <file> <diff?> <narrative> [control-file] [control-narrative]
step_md() {
  local n="$1" title="$2" f="$3" diff="$4" text="$5" cf="${6:-}" ctext="${7:-}" argo
  argo="$(argo_of "${f}")"
  title="$(sed -E 's/`([^`]*)`/<code>\1<\/code>/g' <<<"${title}")"
  {
    printf '<details%s>\n<summary><b>Step %s · %s</b> — Argo CD: <code>%s</code></summary>\n\n' \
      "$([[ "${n}" == 1 ]] && echo ' open')" "${n}" "${title}" "${argo}"
    printf '%s\n\n' "${text}"
    printf '**Container spec** (`%s`)\n\n' "${C}"
    containers_block "${f}" "${diff}"
    printf '\n**managedFields** (`%s`). Bold = claims `%s`\n\n' "${C}" "${REMOVED_CONTAINER}"
    managed_table "${f}"
    echo
    owner_claims "${f}"
    if [[ -n "${cf}" ]]; then
      printf '\n<details><summary>Same moment in <code>%s</code> (Argo CD: <code>%s</code>)</summary>\n\n' "${K}" "$(argo_of "${cf}")"
      printf '%s\n\n' "${ctext}"
      containers_block "${cf}" "${diff}"
      echo
      managed_table "${cf}"
      printf '\n</details>\n'
    fi
    printf '\n</details>\n\n'
  } >> "${OUT}"
}

trigger="$(note_of "$(snap 3-after-compaction "$C")")"
upd_ids() { jq -r '.metadata.managedFields[] | select(.operation=="Update") | .manager + (if .subresource then " (\(.subresource))" else "" end)' "$1" | sort; }
codes() { sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g'; }
added="$(comm -13 <(upd_ids "$(snap 1-csa-apply "$C")") <(upd_ids "$(snap 2-before-compaction "$C")") | codes)"
n_before="$(upd_ids "$(snap 2-before-compaction "$C")" | wc -l | tr -d ' ')"
merged="$(comm -23 <(upd_ids "$(snap 2-before-compaction "$C")") <(upd_ids "$(snap 3-after-compaction "$C")") | codes)"
untimed="$(jq -r '[.metadata.managedFields[] | select(.time == null) | .manager + (if .subresource then " (\(.subresource))" else "" end)] | map("`\(.)`") | join(", ")' "$(snap 2-before-compaction "$C")")"

cat >> "${OUT}" <<EOF
Every block below is a snapshot of the live \`${C}/${DEPLOY}\` Deployment, captured by
\`scripts/run-all.sh\` and rendered by \`scripts/render-timeline.sh\`. Expand a step to see the
container spec and \`metadata.managedFields\` at that moment. 🧟 marks the \`${REMOVED_CONTAINER}\`
container: it is deleted from Git in step 5, but it survives step 6.

EOF

step_md 1 "Client-side \`kubectl apply\` creates the Deployment" "$(snap 1-csa-apply "$C")" "" \
"A human, CI job or migration tool creates the object with plain (client-side) \`kubectl apply\`.
The API server records this as an **Update** by \`${CSA_MANAGER}\`, which owns all three containers."

step_md 2 "Day-2 kubectl verbs push Update managers to the cap (${n_before})" "$(snap 2-before-compaction "$C")" "" \
"Routine operations each register their own **Update** manager: ${added}. None of them touches
\`${REMOVED_CONTAINER}\`. There are now ${n_before} Update entries, and \`${CSA_MANAGER}\` is still the only owner of
\`${REMOVED_CONTAINER}\`.${untimed:+ Note that ${untimed} has **no timestamp**. The API server sorts entries without a timestamp as the oldest.}"

step_md 3 "Update manager #$((n_before + 1)) (\`${trigger}\`) → API server compacts managedFields" "$(snap 3-after-compaction "$C")" "" \
"There are now more than \`DefaultMaxUpdateManagers = 10\` Update entries, so the API server ([\`capmanagers.go\`](https://github.com/kubernetes/kubernetes/blob/v1.37.0/staging/src/k8s.io/apimachinery/pkg/util/managedfields/internal/capmanagers.go)) sorts the
Update entries by time and merges the oldest ones, ${merged}, into **\`ancient-changes\`**. The fields survive, but the
\`${CSA_MANAGER}\` entry no longer exists under that name. \`${REMOVED_CONTAINER}\` is now owned by
\`ancient-changes\`."

step_md 4 "Argo CD adopts the object: first sync with \`ServerSideApply=true\` (Git = v1)" \
  "$(snap 4-argo-sync-v1 "$C")" "" \
"Before applying, Argo CD calls \`needsClientSideApplyMigration\` ([\`gitops-engine/pkg/sync/sync_context.go:1341\`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/sync/sync_context.go#L1341)).
It looks for an entry with \`manager == \"${CSA_MANAGER}\"\` and \`operation == Update\`, finds none,
and **skips the csaupgrade migration**. The server-side apply then makes \`${ARGO_MANAGER}\` (Apply) a
*co-owner* of \`${REMOVED_CONTAINER}\`, next to \`ancient-changes\`." \
  "$(snap 4-argo-sync-v1 "$K")" \
"Here the \`${CSA_MANAGER}\` entry still exists, so \`performCSAUpgradeMigration\` moves its fields to
\`${ARGO_MANAGER}\` and deletes the entry. \`${ARGO_MANAGER}\` is now the **sole** owner of \`${REMOVED_CONTAINER}\`."

step_md 5 "\`${REMOVED_CONTAINER}\` deleted in Git (v2), before sync" "$(snap 5-v2-committed "$C")" diff \
"Server-side diff ([\`gitops-engine/pkg/diff/diff.go:172\`](https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/gitops-engine/pkg/diff/diff.go#L172)) runs a dry-run SSA of v2. Because \`ancient-changes\`
still owns the container, the dry run predicts that the container **stays**. The predicted state equals live, so
Argo CD says **Synced**: the change in Git is invisible." \
  "$(snap 5-v2-committed "$K")" \
"Here the dry run predicts that the container is removed, so the app correctly goes **OutOfSync**."

step_md 6 "Argo CD syncs v2 with \`ServerSideApply=true\`" "$(snap 6-argo-sync-v2 "$C")" diff \
"The sync drops \`${ARGO_MANAGER}\`'s claim on \`${REMOVED_CONTAINER}\`. Server-side apply only deletes a field when
no other manager owns it. \`ancient-changes\` still does, so the API server **keeps the container**. The
sync *Succeeds*, the app reports **Synced/Healthy**, and a container that is no longer in Git keeps running." \
  "$(snap 6-argo-sync-v2 "$K")" \
"\`${ARGO_MANAGER}\` was the sole owner, so server-side apply deletes the container, as Git says."

if [[ -f "$(snap 7-replace-sync "$C")" ]]; then
step_md 7 "Contrast: the same sync as a PUT (\`Replace=true\`)" "$(snap 7-replace-sync "$C")" diff \
"Argo CD's existing \`Replace=true\` sync option writes the object with a PUT instead of an SSA PATCH. A PUT replaces
the whole object with the desired state and never consults \`managedFields\`, so the zombie container is gone. Argo CD
sends the Git manifest exactly as written, though, so fields set by other managers are wiped too. Compare the
\`replicas\`, labels and the \`retriever\` env var with step 6. See [the proposed fix](#proposed-fix-authoritative-put-instead-of-patch)
for how a PUT-based sync keeps them."
fi

# ---------------------------------------------------------------------------
# Data for the interactive page (docs/index.html): a trimmed copy of every
# snapshot, written as a script so the page also works when opened from disk.
JS="${ROOT}/docs/snapshots.js"
mkdir -p "${ROOT}/docs"
names_of() { sed -n 's/^        - name: //p' "${ROOT}/manifests/$1/deployment.yaml" | jq -R . | jq -sc .; }
# Manifest as the user wrote it, minus the explanatory comment lines.
manifest_of() { grep -v '^ *#' "${ROOT}/manifests/$1/deployment.yaml" | jq -Rs .; }
k8s_version="$(jq -r '._k8s // empty' "$(snap 1-csa-apply "$C")")"
{
  echo "// Generated by scripts/render-timeline.sh from .work/snapshots - do not edit by hand."
  printf 'window.REPRO = '
  for f in "${SNAP_DIR}"/*.json; do
    b="$(basename "${f}" .json)"
    # Field paths use the managedFields spelling with the f:/k: prefixes
    # removed, e.g. spec.template.spec.containers.{"name":"ranker"}.image
    jq -c --arg step "${b%%.*}" --arg ns "${b#*.}" '
      def leaves: [paths(type == "object" and length == 0)]
        | map(select(last != ".") | map(sub("^[fk]:"; "")) | join("."));
      def short: with_entries(if (.value | length) > 60 then .value = "{…}" else . end);
      { step: $step, ns: $ns, argo: ._argo, note: ._note,
        replicas: .spec.replicas,
        labels: (.metadata.labels // {}),
        annotations: ((.metadata.annotations // {}) | short),
        tplAnnotations: ((.spec.template.metadata.annotations // {}) | short),
        containers: [.spec.template.spec.containers[] | {name, image, env: [(.env // [])[] | {name, value}]}],
        managers: [.metadata.managedFields[] | {
          manager, operation, subresource: (.subresource // null), time: (.time // null),
          leaves: (.fieldsV1 | leaves) }] }' "${f}"
  done | jq -s --arg argocd "${ARGOCD_VERSION}" --arg k8s "${k8s_version}" \
           --argjson v1 "$(names_of v1)" --argjson v2 "$(names_of v2)" \
           --argjson m1 "$(manifest_of v1)" --argjson m2 "$(manifest_of v2)" \
           --arg removed "${REMOVED_CONTAINER}" \
    '{argocd: $argocd, k8s: $k8s, removed: $removed,
      git: {v1: $v1, v2: $v2}, manifests: {v1: $m1, v2: $m2}, snapshots: .}'
  echo ";"
} > "${JS}"
step "docs/snapshots.js regenerated ($(wc -c < "${JS}" | tr -d ' ') bytes)"

# Splice into README between the markers.
grep -q '<!-- timeline:start -->' "${README}" || die "README.md has no <!-- timeline:start --> marker"
awk -v gen="${OUT}" '
  /<!-- timeline:start -->/ { print; while ((getline l < gen) > 0) print l; skip=1; next }
  /<!-- timeline:end -->/   { skip=0 }
  !skip
' "${README}" > "${README}.tmp" && mv "${README}.tmp" "${README}"
step "README.md timeline regenerated from ${SNAP_DIR}"

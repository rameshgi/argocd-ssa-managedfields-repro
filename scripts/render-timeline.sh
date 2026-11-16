#!/usr/bin/env bash
# Render the snapshots taken during a run (.work/snapshots/*.json) into
#   1. the click-through timeline in README.md (between the timeline markers), and
#   2. docs/snapshots.js, the data behind the interactive page docs/index.html.
# Every table and value is generated from real API-server output.
source "$(dirname "$0")/lib.sh"

README="${ROOT}/README.md"
OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT
snap() { echo "${SNAP_DIR}/$1.$2.json"; }
D="${NS_DRIFT}"; Rs="${NS_RESYNC}"; Cm="${NS_COMPACTED}"; Pt="${NS_PUT}"; Ct="${NS_CONTAINER}"
for f in 1-argo-create.$D 2-incident.$D 4-git-v2.$D 5-argo-sync-v2.$D 4-git-v2.$Rs 5-argo-sync-v2.$Rs \
         5-argo-sync-v2.$Cm 6-put.$Cm 5-argo-sync-v2.$Pt 6-put-rid.$Pt \
         1-argo-create.$Ct 2a-remove.$Ct 2b-readd.$Ct 4-git-v2.$Ct 5-argo-sync-v2.$Ct; do
  [[ -f "${SNAP_DIR}/${f}.json" ]] || die "missing snapshot ${f}; run scripts/run-all.sh first"
done

ARGO="https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/"
FKEY="k:{\"name\":\"${FIELD_CONTAINER}\"}"
SKEY="k:{\"name\":\"${SIDECAR}\"}"

val()   { jq -r --arg c "${FIELD_CONTAINER}" '.spec.template.spec.containers[] | select(.name==$c) | .resources.limits.cpu // "none"' "$1"; }
has_sc(){ jq -r --arg c "${SIDECAR}" 'if any(.spec.template.spec.containers[]; .name==$c) then "running" else "none" end' "$1"; }
argo_of() { local a; a="$(jq -r '._argo' "$1")"; echo "${a:-n/a}"; }
owner_field() { jq -r --arg k "${FKEY}" '[.metadata.managedFields[] | select(.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$k]["f:resources"]["f:limits"]["f:cpu"]) | "`\(.manager)` (\(.operation))"] | join(", ") | if . == "" then "—" else . end' "$1"; }
owner_item()  { jq -r --arg k "${SKEY}" '[.metadata.managedFields[] | select(.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$k]["."]) | "`\(.manager)` (\(.operation))"] | join(", ") | if . == "" then "—" else . end' "$1"; }
sync_line() {
  jq -r '._sync // {} | if .revision then "Last sync operation: revision `\(.revision[0:8])`, \(.phase), finished `\(.finishedAt | sub("^.*T"; "") | sub("Z$"; ""))`, options `\(.options | join(", "))`." else "" end' "$1"
}

# State table: what Git says vs. what is live, and who owns it.
state_field() { # file git-value
  printf '| | Git | Live | Owner in `managedFields` |\n|---|---|---|---|\n'
  printf '| `%s` `limits.cpu` | %s | %s | %s |\n' "${FIELD_CONTAINER}" "$2" "$(val "$1")" "$(owner_field "$1")"
}
state_container() { # file git-value
  printf '| | Git | Live | Owner of the list item (`.`) |\n|---|---|---|---|\n'
  printf '| container `%s` | %s | %s | %s |\n' "${SIDECAR}" "$2" "$(has_sc "$1")" "$(owner_item "$1")"
}

managed_table() { # file mode(field|container)
  local col; [[ "$2" == container ]] && col="owns \`${SIDECAR}\` item" || col="owns \`limits.cpu\`"
  echo "| manager | operation | time | ${col} | fields owned |"
  echo "|---|---|---|---|---|"
  jq -r --arg fk "${FKEY}" --arg sk "${SKEY}" --arg mode "$2" '
    def leaves: [paths(type == "object" and length == 0)] | map(select(last != "."));
    .metadata.managedFields[]
    | (if $mode == "container" then .fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$sk]["."] != null
       else .fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$fk]["f:resources"]["f:limits"]["f:cpu"] != null end) as $o
    | [ (if $o then "**\(.manager)**" else .manager end),
        (.operation + (if .subresource then " (`\(.subresource)`)" else "" end)),
        ((.time // "") | sub("^.*T"; "") | sub("Z$"; "")),
        (if $o then "**yes**" else "—" end),
        (.fieldsV1 | leaves | length | tostring) ] | "| " + join(" | ") + " |"' "$1"
}

# step <n> <title> <file> <mode> <git-value> <narrative> [control-file control-label control-narrative]
step_md() {
  local n="$1" title="$2" f="$3" mode="$4" gv="$5" text="$6" cf="${7:-}" clabel="${8:-}" ctext="${9:-}" live sl
  title="$(sed -E 's/`([^`]*)`/<code>\1<\/code>/g' <<<"${title}")"
  if [[ "${mode}" == container ]]; then live="${SIDECAR}: $(has_sc "${f}")"; else live="limits.cpu: $(val "${f}")"; fi
  {
    printf '<details%s>\n<summary><b>Step %s · %s</b> — Argo CD: <code>%s</code> · live <code>%s</code></summary>\n\n' \
      "$([[ "${n}" == 1 || "${n}" == C1 ]] && echo ' open')" "${n}" "${title}" "$(argo_of "${f}")" "${live}"
    printf '%s\n\n' "${text}"
    sl="$(sync_line "${f}")"; [[ -n "${sl}" && "${mode}" != nosync ]] && printf '%s\n\n' "${sl}"
    if [[ "${mode}" == container ]]; then state_container "${f}" "${gv}"; else state_field "${f}" "${gv}"; fi
    printf '\n**managedFields** (`%s`)\n\n' "$(basename "${f}" .json | cut -d. -f2)"
    managed_table "${f}" "${mode}"
    if [[ -n "${cf}" ]]; then
      printf '\n<details><summary>Same moment in <code>%s</code> (Argo CD: <code>%s</code>)</summary>\n\n%s\n\n' "${clabel}" "$(argo_of "${cf}")" "${ctext}"
      state_field "${cf}" "${gv}"
      echo
      managed_table "${cf}" field
      printf '\n</details>\n'
    fi
    printf '\n</details>\n\n'
  } >> "${OUT}"
}

# before/after table for the PUT contrasts.
put_table() { # before after
  jq -rn --slurpfile b "$1" --slurpfile a "$2" --arg c "${FIELD_CONTAINER}" '
    def row($n; f): "| \($n) | \($b[0] | f) | \($a[0] | f) |";
    "| | before (after the SSA sync) | after the PUT |", "|---|---|---|",
    row("`" + $c + "` `limits.cpu`"; [.spec.template.spec.containers[] | select(.name==$c) | .resources.limits.cpu // "none"][0]),
    row("`replicas`"; .spec.replicas),
    row("labels"; .metadata.labels | keys | map("`\(.)`") | join(", ")),
    row("annotations (count)"; .metadata.annotations | length)'
}

cat >> "${OUT}" <<EOF
Each block below is a snapshot of the live Deployment, captured by \`scripts/run-all.sh\` and rendered
by \`scripts/render-timeline.sh\`. Expand a step to see what Git says, what is live, and
\`metadata.managedFields\` at that moment.

### A. A field changed with kubectl (\`${D}\`)

EOF

step_md 1 "Argo CD creates the Deployment with server-side apply" "$(snap 1-argo-create "$D")" field 500m \
"Argo CD syncs \`manifests/v1\` with \`ServerSideApply=true\`. \`${ARGO_MANAGER}\` (operation \`Apply\`) owns every field in
the manifest, including \`${FIELD_CONTAINER}\`'s \`limits.cpu\`."

step_md 2 "Incident: on-call raises the CPU limit with kubectl" "$(snap 2-incident "$D")" nosync 500m \
"\`${INCIDENT_CMD}\`. kubectl sends an **Update** that changes the value, and the API server moves ownership of that field
to \`kubectl-set\`. \`${ARGO_MANAGER}\` no longer owns it. Argo CD correctly reports **OutOfSync**, because Git still says
\`500m\`."

step_md 3 "Git deletes the CPU limit, and Argo CD flips to Synced without syncing" "$(snap 4-git-v2 "$D")" nosync none \
"The team deletes \`${FIELD_CONTAINER}\`'s CPU limit from Git (\`manifests/v2\`). Argo CD's server-side diff
([\`diff.go:177\`](${ARGO}gitops-engine/pkg/diff/diff.go#L177)) predicts the result with a dry-run server-side apply of v2.
That dry run keeps every field \`${ARGO_MANAGER}\` doesn't own, so it keeps \`limits.cpu: 2\`. Prediction and live are equal,
and the app goes from **OutOfSync to Synced**, although nothing in the cluster changed." \
  "$(snap 4-git-v2 "$Rs")" "${Rs}" \
"In \`${Rs}\`, Argo CD re-synced v1 *before* this commit. With \`force-conflicts\` it took \`limits.cpu\` back (value \`500m\`,
owner \`${ARGO_MANAGER}\`). The dry run therefore predicts the field is removed, and the app correctly shows **OutOfSync**."

step_md 4 "Argo CD syncs v2: the sync succeeds, and the CPU limit stays" "$(snap 5-argo-sync-v2 "$D")" field none \
"Argo CD applies v2 as a server-side-apply PATCH
([\`sync_context.go:1485\`](${ARGO}gitops-engine/pkg/sync/sync_context.go#L1485)). The API server deletes a field only when
the applier owns it, and \`kubectl-set\` owns \`limits.cpu\`. The sync **Succeeds**, the app is **Synced/Healthy**, and
\`${FIELD_CONTAINER}\` keeps a 2-core CPU limit that exists nowhere in Git. \`${ARGO_MANAGER}\`'s timestamp doesn't move,
because the apply changed nothing." \
  "$(snap 5-argo-sync-v2 "$Rs")" "${Rs}" \
"\`${ARGO_MANAGER}\` owned the field again, so the sync deletes it, as Git says."

step_md 5 "The same outcome after managedFields compaction: the owner is anonymous" "$(snap 5-argo-sync-v2 "$Cm")" field none \
"In \`${Cm}\`, routine day-2 operations pushed the object past 10 \`Update\` managers before Git changed. The operations
are \`kubectl label\`, \`annotate\`, \`patch\`, \`rollout restart\`, \`scale\`, \`edit\` and \`replace\`, plus simulated
controllers. Names such as \`hpa-controller\` and \`migration-orchestrator\` are set by the script with \`--field-manager\`.
The API server merged the oldest entries, including \`kubectl-set\`, into **\`ancient-changes\`**. The result is the same
silent drift, but nothing in the object records who set the value or when."

{
  printf '<details>\n<summary><b>Step 6 · Contrast: the same sync as a PUT</b></summary>\n\n'
  printf '**`Replace=true` alone** (`%s`). Argo CD PUTs the manifest exactly as written. The drifted CPU limit is gone, and so is everything other managers set.\n\n' "${Cm}"
  put_table "$(snap 5-argo-sync-v2 "$Cm")" "$(snap 6-put "$Cm")"
  printf '\n**`Replace=true` + `RespectIgnoreDifferences=true`** (`%s`, with `ignoreDifferences` on `/spec/replicas`, `/metadata/labels/team` and `/metadata/labels/cost-center`). Argo CD copies the live values of the declared fields into the target before the PUT ([`controller/sync.go:310`](%scontroller/sync.go#L310)). The drifted CPU limit is gone, and the declared external fields are kept.\n\n' "${Pt}" "${ARGO}"
  put_table "$(snap 5-argo-sync-v2 "$Pt")" "$(snap 6-put-rid "$Pt")"
  printf '\n</details>\n\n'
} >> "${OUT}"

cat >> "${OUT}" <<EOF
### B. A container re-created with kubectl (\`${Ct}\`)

EOF

step_md C1 "Argo CD creates the Deployment with server-side apply" "$(snap 1-argo-create "$Ct")" container running \
"Argo CD creates the Deployment from \`apps/ranker-container\`, which has three containers. \`${ARGO_MANAGER}\` owns the
\`${SIDECAR}\` list item (\`.\` and \`f:name\`)."

step_md C2 "Incident: on-call removes the crash-looping container" "$(snap 2a-remove "$Ct")" container running \
"\`kubectl patch --type json\` removes \`${SIDECAR}\`. The list item and \`${ARGO_MANAGER}\`'s ownership of it are gone.
Argo CD reports **OutOfSync**."

step_md C3 "…and adds it back" "$(snap 2b-readd "$Ct")" container running \
"A second \`kubectl patch\` adds \`${SIDECAR}\` back with the same spec as Git. It is a *new* list item, owned by
\`kubectl-patch\`. The spec matches Git, so Argo CD reports **Synced**. \`${ARGO_MANAGER}\` owns nothing in it."

step_md C4 "Git deletes the container, and Argo CD stays Synced" "$(snap 4-git-v2 "$Ct")" container none \
"The commit deletes \`${SIDECAR}\` from \`apps/ranker-container\`. The dry-run server-side apply keeps the container, because
\`${ARGO_MANAGER}\` doesn't own it, so the app stays **Synced**."

step_md C5 "Argo CD syncs: the sync succeeds, and the container keeps running" "$(snap 5-argo-sync-v2 "$Ct")" container none \
"The server-side-apply PATCH can't delete a list item another manager owns. The sync **Succeeds**, the app is
**Synced/Healthy**, and a container Git no longer has keeps running."

# ---------------------------------------------------------------------------
# docs/snapshots.js: a trimmed copy of every snapshot, as a script so the page
# also works when opened from disk.
JS="${ROOT}/docs/snapshots.js"
mkdir -p "${ROOT}/docs"
manifest_of() { grep -v '^ *#' "${ROOT}/manifests/$1/deployment.yaml" | jq -Rs .; }
k8s_version="$(jq -r '._k8s // empty' "$(snap 1-argo-create "$D")")"
{
  echo "// Generated by scripts/render-timeline.sh from .work/snapshots - do not edit by hand."
  printf 'window.REPRO = '
  for f in "${SNAP_DIR}"/*.json; do
    b="$(basename "${f}" .json)"
    # Field paths use the managedFields spelling with the f:/k: prefixes
    # removed, e.g. spec.template.spec.containers.{"name":"retriever"}.resources.limits.cpu
    jq -c --arg step "${b%%.*}" --arg ns "${b#*.}" '
      def leaves: [paths(type == "object" and length == 0)]
        | map(map(sub("^[fk]:"; "")) | join("."));
      def short: with_entries(if (.value | length) > 60 then .value = "{…}" else . end);
      { step: $step, ns: $ns, argo: ._argo, note: ._note, sync: (._sync // {}),
        replicas: .spec.replicas,
        labels: (.metadata.labels // {}),
        annotations: ((.metadata.annotations // {}) | short),
        tplAnnotations: ((.spec.template.metadata.annotations // {}) | short),
        containers: [.spec.template.spec.containers[] | {name, image, env: [(.env // [])[] | {name, value}], resources: (.resources // {})}],
        managers: [.metadata.managedFields[] | {
          manager, operation, subresource: (.subresource // null), time: (.time // null),
          leaves: (.fieldsV1 | leaves) }] }' "${f}"
  done | jq -s --arg argocd "${ARGOCD_VERSION}" --arg k8s "${k8s_version}" \
           --argjson m1 "$(manifest_of v1)" --argjson m2 "$(manifest_of v2)" --argjson m2c "$(manifest_of v2-container)" \
           --arg container "${FIELD_CONTAINER}" --arg sidecar "${SIDECAR}" --arg cmd "${INCIDENT_CMD}" \
           --arg ns_drift "${NS_DRIFT}" --arg ns_resync "${NS_RESYNC}" --arg ns_compacted "${NS_COMPACTED}" \
           --arg ns_put "${NS_PUT}" --arg ns_container "${NS_CONTAINER}" \
    '{argocd: $argocd, k8s: $k8s, container: $container, sidecar: $sidecar, incident: $cmd,
      namespaces: {drift: $ns_drift, resync: $ns_resync, compacted: $ns_compacted, put: $ns_put, container: $ns_container},
      manifests: {v1: $m1, v2: $m2, v2c: $m2c}, snapshots: .}'
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

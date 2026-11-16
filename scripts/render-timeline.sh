#!/usr/bin/env bash
# Render the snapshots taken during a run (.work/snapshots/*.json) into
#   1. the click-through timeline in README.md (between the timeline markers), and
#   2. docs/snapshots.js, the data behind the interactive page docs/index.html.
# Every YAML block, table and value is generated from real API-server output.
source "$(dirname "$0")/lib.sh"

README="${ROOT}/README.md"
OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT
snap() { echo "${SNAP_DIR}/$1.$2.json"; }
for f in 1-argo-create.${NS_DRIFT} 2-incident.${NS_DRIFT} 4-git-v2.${NS_DRIFT} 5-argo-sync-v2.${NS_DRIFT} \
         4-git-v2.${NS_RESYNC} 5-argo-sync-v2.${NS_RESYNC} 5-argo-sync-v2.${NS_COMPACTED} 6-put.${NS_COMPACTED}; do
  [[ -f "${SNAP_DIR}/${f}.json" ]] || die "missing snapshot ${f}; run scripts/run-all.sh first"
done

ARGO="https://github.com/argoproj/argo-cd/blob/94037c4d4e1af4bd0651d37a179fbd9e347e668c/"
FKEY="k:{\"name\":\"${FIELD_CONTAINER}\"}"

# retriever's resources as YAML; the drifting line is marked when Git no longer has it.
container_block() { # file git(v1|v2)
  local git="$2"
  echo '```diff'
  echo "# live: containers[name=${FIELD_CONTAINER}].resources   ('+' = in the cluster but NOT in Git ${git})"
  jq -r --arg c "${FIELD_CONTAINER}" --arg git "${git}" '
    .spec.template.spec.containers[] | select(.name == $c) | .resources as $r
    | "  resources:",
      "    requests: {cpu: \($r.requests.cpu), memory: \($r.requests.memory)}",
      "    limits:",
      (if $r.limits.cpu then (if $git == "v2" then "+" else " " end) + "     cpu: \($r.limits.cpu)" else empty end),
      "      memory: \($r.limits.memory)"' "$1"
  echo '```'
}

managed_table() { # file
  echo "| manager | operation | time | owns \`limits.cpu\` | fields owned |"
  echo "|---|---|---|---|---|"
  jq -r --arg k "${FKEY}" '
    def leaves: [paths(type == "object" and length == 0)] | map(select(last != "."));
    .metadata.managedFields[]
    | (.fieldsV1["f:spec"]["f:template"]["f:spec"]["f:containers"][$k]["f:resources"]["f:limits"]["f:cpu"] != null) as $o
    | [ (if $o then "**\(.manager)**" else .manager end),
        (.operation + (if .subresource then " (`\(.subresource)`)" else "" end)),
        ((.time // "") | sub("^.*T"; "") | sub("Z$"; "")),
        (if $o then "**yes**" else "—" end),
        (.fieldsV1 | leaves | length | tostring) ] | "| " + join(" | ") + " |"' "$1"
}

val() { jq -r --arg c "${FIELD_CONTAINER}" '.spec.template.spec.containers[] | select(.name==$c) | .resources.limits.cpu // "none"' "$1"; }
argo_of() { local a; a="$(jq -r '._argo' "$1")"; echo "${a:-n/a}"; }

# step <n> <title> <file> <git> <narrative> [control-file control-label control-narrative]
step_md() {
  local n="$1" title="$2" f="$3" git="$4" text="$5" cf="${6:-}" clabel="${7:-}" ctext="${8:-}"
  title="$(sed -E 's/`([^`]*)`/<code>\1<\/code>/g' <<<"${title}")"
  {
    printf '<details%s>\n<summary><b>Step %s · %s</b> — Argo CD: <code>%s</code> · live <code>limits.cpu</code>: <code>%s</code></summary>\n\n' \
      "$([[ "${n}" == 1 ]] && echo ' open')" "${n}" "${title}" "$(argo_of "${f}")" "$(val "${f}")"
    printf '%s\n\n' "${text}"
    container_block "${f}" "${git}"
    printf '\n**managedFields** (`%s`)\n\n' "$(basename "${f}" .json | cut -d. -f2)"
    managed_table "${f}"
    if [[ -n "${cf}" ]]; then
      printf '\n<details><summary>Same moment in <code>%s</code> (Argo CD: <code>%s</code>, live <code>limits.cpu</code>: <code>%s</code>)</summary>\n\n%s\n\n' \
        "${clabel}" "$(argo_of "${cf}")" "$(val "${cf}")" "${ctext}"
      container_block "${cf}" "${git}"
      echo
      managed_table "${cf}"
      printf '\n</details>\n'
    fi
    printf '\n</details>\n\n'
  } >> "${OUT}"
}

D="${NS_DRIFT}"; Rs="${NS_RESYNC}"; Cm="${NS_COMPACTED}"
cat >> "${OUT}" <<EOF
Each block below is a snapshot of the live \`${D}/${DEPLOY}\` Deployment, captured by
\`scripts/run-all.sh\` and rendered by \`scripts/render-timeline.sh\`. Expand a step to see
\`retriever\`'s resources and \`metadata.managedFields\` at that moment.

EOF

step_md 1 "Argo CD creates the Deployment with server-side apply" "$(snap 1-argo-create "$D")" v1 \
"Argo CD syncs \`manifests/v1\` with \`ServerSideApply=true\`. \`${ARGO_MANAGER}\` (operation \`Apply\`) owns every
field in the manifest, including \`retriever\`'s \`limits.cpu: 500m\`."

step_md 2 "Incident: on-call raises the CPU limit with kubectl" "$(snap 2-incident "$D")" v1 \
"\`${INCIDENT_CMD}\`. kubectl sends an **Update** that changes the value, and the API server moves ownership of that
field to \`kubectl-set\`. \`${ARGO_MANAGER}\` no longer owns it. Argo CD correctly reports **OutOfSync**, because Git
still says \`500m\`."

step_md 3 "Git deletes the CPU limit, and Argo CD flips to Synced without syncing" "$(snap 4-git-v2 "$D")" v2 \
"The team deletes \`retriever\`'s CPU limit from Git (\`manifests/v2\`). Argo CD's server-side diff
([\`diff.go:177\`](${ARGO}gitops-engine/pkg/diff/diff.go#L177)) runs a dry-run server-side apply of v2. That dry run
keeps every field \`${ARGO_MANAGER}\` doesn't own, so it predicts \`limits.cpu: 2\` stays. The prediction equals live,
and [\`diff.go:286-290\`](${ARGO}gitops-engine/pkg/diff/diff.go#L286-L290) explicitly drops removals of fields
Argo CD doesn't own. The app goes from **OutOfSync to Synced**, although nothing in the cluster changed and the
live value still differs from Git." \
  "$(snap 4-git-v2 "$Rs")" "${Rs}" \
"In \`${Rs}\`, Argo CD re-synced v1 *before* this commit. With \`force-conflicts\` it took \`limits.cpu\` back
(value \`500m\`, owner \`${ARGO_MANAGER}\`). The dry run therefore predicts the field is removed, and the app correctly
shows **OutOfSync**."

step_md 4 "Argo CD syncs v2: the sync succeeds, and the CPU limit stays" "$(snap 5-argo-sync-v2 "$D")" v2 \
"Argo CD applies v2 as a server-side-apply PATCH
([\`sync_context.go:1485\`](${ARGO}gitops-engine/pkg/sync/sync_context.go#L1485)). The API server deletes a field
only when the applier owns it, and \`kubectl-set\` owns \`limits.cpu\`. The sync **Succeeds**, the app is
**Synced/Healthy**, and \`retriever\` keeps running with a 2-core CPU limit that exists nowhere in Git." \
  "$(snap 5-argo-sync-v2 "$Rs")" "${Rs}" \
"\`${ARGO_MANAGER}\` owned the field again, so the sync deletes it, as Git says."

step_md 5 "The same outcome after managedFields compaction: the owner is now anonymous" "$(snap 5-argo-sync-v2 "$Cm")" v2 \
"In \`${Cm}\`, routine day-2 operations (labels, annotations, \`rollout restart\`, \`scale\`, \`edit\`, \`replace\`,
controllers) pushed the object past 10 \`Update\` managers before Git changed. The API server merged the oldest
entries, including \`kubectl-set\`, into **\`ancient-changes\`**. The result is the same silent drift, but nothing in
the object says who set the value or when."

step_md 6 "Contrast: the same sync as a PUT (\`Replace=true\`)" "$(snap 6-put "$Cm")" v2 \
"Argo CD's existing \`Replace=true\` sync option writes the object with a PUT. A PUT replaces the whole object and never
consults \`managedFields\`, so the drifted CPU limit is gone. Argo CD sends the manifest exactly as written, though, so
it also wipes fields other managers set: \`replicas\` and the labels added during day-2 operations. See
[the proposed fix](#proposed-fix-authoritative-put-instead-of-patch) for how a PUT-based sync keeps them."

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
        | map(select(last != ".") | map(sub("^[fk]:"; "")) | join("."));
      def short: with_entries(if (.value | length) > 60 then .value = "{…}" else . end);
      { step: $step, ns: $ns, argo: ._argo, note: ._note,
        replicas: .spec.replicas,
        labels: (.metadata.labels // {}),
        annotations: ((.metadata.annotations // {}) | short),
        tplAnnotations: ((.spec.template.metadata.annotations // {}) | short),
        containers: [.spec.template.spec.containers[] | {name, image, resources: (.resources // {})}],
        managers: [.metadata.managedFields[] | {
          manager, operation, subresource: (.subresource // null), time: (.time // null),
          leaves: (.fieldsV1 | leaves) }] }' "${f}"
  done | jq -s --arg argocd "${ARGOCD_VERSION}" --arg k8s "${k8s_version}" \
           --argjson m1 "$(manifest_of v1)" --argjson m2 "$(manifest_of v2)" \
           --arg container "${FIELD_CONTAINER}" --arg cmd "${INCIDENT_CMD}" \
           --arg ns_drift "${NS_DRIFT}" --arg ns_resync "${NS_RESYNC}" --arg ns_compacted "${NS_COMPACTED}" \
    '{argocd: $argocd, k8s: $k8s, container: $container, incident: $cmd,
      namespaces: {drift: $ns_drift, resync: $ns_resync, compacted: $ns_compacted},
      manifests: {v1: $m1, v2: $m2}, snapshots: .}'
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

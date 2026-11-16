#!/usr/bin/env bash
# Regenerate the README screenshots of the interactive page (docs/img/*.png)
# from docs/index.html + docs/snapshots.js. Needs Google Chrome or Chromium;
# set CHROME=/path/to/chrome if it is not at the default macOS location.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "${CHROME}" ]] || { echo "Chrome not found; set CHROME=..." >&2; exit 1; }
# Step numbers are positions in each namespace's timeline (see the page).
# Only demo-compacted has day-2 ("3v-NN") steps.
n_verbs="$(grep -c '"step": *"3v-' "${ROOT}/docs/snapshots.js" || true)"
SHOTS=(
  "container|5"                       # container still running after the sync
  "drift|3"                           # Git deletes the CPU limit; Argo CD flips to Synced
  "resync|5"                          # control: the limit is removed
  "compacted|$((2 + n_verbs))"        # the day-2 operation that triggers compaction
  "put|6"                             # Replace=true + RespectIgnoreDifferences=true
)
for s in "${SHOTS[@]}"; do
  ns="${s%%|*}"; step="${s#*|}"
  "${CHROME}" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --virtual-time-budget=3000 --window-size=1400,1260 \
    --screenshot="${ROOT}/docs/img/${ns}.png" "file://${ROOT}/docs/index.html#step=${step}&ns=${ns}&shot" >/dev/null 2>&1
  echo "docs/img/${ns}.png  (ns=${ns}, step=${step})"
done

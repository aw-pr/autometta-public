#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=regression suite; no stage card freezes it
# live-share-smoke.sh: the aggregator predicts each stage role in the measure
# the stage cells show. No auth, no network, no token spend.
#
# What it asserts, against a fixture cost log whose cached reads dwarf its
# uncached tokens:
#
#   1. A role predicts from the median uncached tokens (input plus output) its
#      model has spent per dispatch here, never the processed median.
#   2. It counts only the samples that carry an uncached split.
#   3. A model with no history here falls back to the middle of the per-model
#      medians in that role, and says so.
#   4. A repo with no history predicts nothing rather than a zero.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

fail=0
check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "ok" ]]; then printf '  PASS: %s\n' "$desc" >&2
  else printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2; fail=1; fi
}
eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }

# The aggregator reads registered subscribers and live transcripts, so both
# point at throwaway directories rather than the operator's.
export PHAT_CONTROLLER_HOME="$tmp_root/controller"
export AUTOMETTA_CLAUDE_PROJECTS="$tmp_root/claude-projects"
export AUTOMETTA_CODEX_SESSIONS="$tmp_root/codex-sessions"
mkdir -p "$PHAT_CONTROLLER_HOME/subscribers" "$PHAT_CONTROLLER_HOME/log" \
  "$AUTOMETTA_CLAUDE_PROJECTS" "$AUTOMETTA_CODEX_SESSIONS"

subscribe() {
  local name="$1" path="$2"
  mkdir -p "$path/state"
  printf 'version: 1\n' > "$path/.autometta.local.yaml"
  cat > "$PHAT_CONTROLLER_HOME/subscribers/$name.yaml" <<YAML
repo_path: "$path"
manifest_path: "$path/.autometta.local.yaml"
weight: 100
enabled: true
YAML
}

repo="$tmp_root/repo"
empty="$tmp_root/empty"
subscribe repo "$repo"
subscribe empty "$empty"

opus="Opus <opus@local>"
terra="Terra <terra@local>"
sol="Sol <sol@local>"

cat > "$repo/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: 01-known-pair
    status: completed
    worker: "$opus"
    verifier: "$sol"
  - id: 02-new-models
    status: pending
    worker: "Fable <fable@local>"
    verifier: "Never <never@local>"
YAML
cp "$repo/state/state.yaml" "$empty/state/state.yaml"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
row() {
  # Five million cached reads per dispatch put the processed median an order
  # of magnitude above the uncached one, so a prediction in the wrong measure
  # cannot pass by accident.
  printf '{"ts":"%s","repo":"repo","stage_id":"history","role":"%s","identity":"%s","input_tokens":%s,"cached_input_tokens":5000000,"output_tokens":%s,"cost_usd_est":1.0,"result":"pass"}\n' \
    "$now" "$1" "$2" "$3" "$4" >> "$repo/state/cost-log.jsonl"
}
row worker   "$opus"  90000 10000
row worker   "$opus" 180000 20000
row worker   "$opus" 270000 30000
row worker   "$opus" 360000 40000
row worker   "$opus" 450000 50000
row worker   "$terra" 70000 10000
row worker   "$terra" 100000 20000
row verifier "$sol"  45000  5000
row verifier "$sol"  54000  6000
row verifier "$sol"  63000  7000
# A dispatch with no uncached split still counts towards the processed median
# but must not count as an uncached sample.
printf '{"ts":"%s","repo":"repo","stage_id":"history","role":"worker","identity":"%s","total_tokens":9000000,"cost_usd_est":1.0,"result":"pass"}\n' \
  "$now" "$opus" >> "$repo/state/cost-log.jsonl"

payload="$("$script_dir/aggregate-dashboard.sh" --repo "$repo" 2>/dev/null)"
[[ -n "$payload" ]] || { echo "FAIL: aggregator produced nothing" >&2; exit 1; }
field() { printf '%s' "$payload" | jq -r "$1"; }
stage() { printf '.stages[] | select(.id == "%s")' "$1"; }

printf '== 1. a role predicts from its model'"'"'s uncached median ==\n' >&2
check "the worker predicts 300,000 uncached, not the processed median" \
  "$(eq 300000 "$(field "$(stage 01-known-pair) | .estimate.worker.uncached_tokens")")"
check "the verifier predicts 60,000 uncached" \
  "$(eq 60000 "$(field "$(stage 01-known-pair) | .estimate.verifier.uncached_tokens")")"
check "the total predicts both roles" \
  "$(eq 360000 "$(field "$(stage 01-known-pair) | .estimate.total_uncached_tokens")")"
check "the basis is the model's own history" \
  "$(eq model "$(field "$(stage 01-known-pair) | .estimate.worker.basis")")"

printf '== 2. only dispatches with an uncached split are samples ==\n' >&2
check "the worker counts five samples, not six" \
  "$(eq 5 "$(field "$(stage 01-known-pair) | .estimate.worker.samples")")"

printf '== 3. a model with no history falls back to the role ==\n' >&2
check "a new worker takes the middle of the worker medians" \
  "$(eq 300000 "$(field "$(stage 02-new-models) | .estimate.worker.uncached_tokens")")"
check "and says the basis is the role" \
  "$(eq role "$(field "$(stage 02-new-models) | .estimate.worker.basis")")"
check "with no sample count of its own" \
  "$(eq null "$(field "$(stage 02-new-models) | .estimate.worker.samples")")"

printf '== 4. no history predicts nothing ==\n' >&2
payload="$("$script_dir/aggregate-dashboard.sh" --repo "$empty" 2>/dev/null)"
check "an empty repo predicts no worker figure" \
  "$(eq null "$(field "$(stage 01-known-pair) | .estimate.worker")")"
check "and no total" \
  "$(eq null "$(field "$(stage 01-known-pair) | .estimate.total_uncached_tokens")")"

if [[ "$fail" -eq 0 ]]; then printf 'live-share-smoke: PASS\n' >&2
else printf 'live-share-smoke: FAIL\n' >&2; fi
exit "$fail"

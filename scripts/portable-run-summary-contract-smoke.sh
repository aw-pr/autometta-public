#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/182-portable-run-summary.md
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/state/verifiers"
run=run-20261122-080000
other=run-20261121-080000
sha=3456789012345678901234567890123456789012
cat >"$repo/state/state.yaml" <<YAML
stages:
  - id: 01-good
    run_id: $run
    status: completed
    started_at: "2026-11-22T08:10:00Z"
    completed_at: "2026-11-22T08:20:00Z"
    verifier_attempts: 1
    worker_pid: 7654321
    verifier_artefact: state/verifiers/01-good.json
    integration: {state: merged, head: badcafe, rebased_tip: "$sha"}
  - id: 02-legacy
    run_id: $run
    status: superseded
  - id: 03-elsewhere
    run_id: $other
    status: completed
YAML
printf '{"stage_id":"01-good","overall":"PASS","additional_findings":"PRIVATE_CANARY"}\n' >"$repo/state/verifiers/01-good.json"
printf '{"token_cap_total":9999,"tokens_spent":42,"reason":"PRIVATE_CANARY"}\n' >"$repo/state/budget.json"
cat >"$repo/state/cost-log.jsonl" <<JSON
{"ts":"2026-11-21T08:01:00Z","run_id":"$other","stage_id":"01-good","role":"worker","result":"pass","total_tokens":900}
{"ts":"2026-11-22T08:01:00Z","stage_id":"01-good","role":"worker","result":"pass","total_tokens":30}
{"ts":"2026-11-22T08:03:00Z","stage_id":"01-good","role":"verifier","result":"fail","total_tokens":20}
{"ts":"2026-11-22T08:11:00Z","stage_id":"01-good","role":"worker","result":"pass","total_tokens":25}
{"ts":"2026-11-22T08:19:00Z","stage_id":"01-good","role":"verifier","result":"pass","total_tokens":15}
JSON
tool="$root/scripts/run-summary.sh"
[[ -x "$tool" ]] || { echo 'FAIL: run summary renderer missing' >&2; exit 1; }
before="$(cksum "$repo"/state/{state.yaml,budget.json,cost-log.jsonl} "$repo"/state/verifiers/01-good.json)"
"$tool" "$repo" "$run" finished >"$tmp/one"
"$tool" "$repo" "$run" finished >"$tmp/two"
cmp "$tmp/one" "$tmp/two"
jq -e --arg sha "$sha" --arg run "$run" '
  (keys == ["outcome","run_id","stages","version"]) and .version == 1 and
  .run_id == $run and .outcome == "finished" and (.stages | length) == 2 and
  .stages[0] == {id:"01-good",status:"completed",verdict:"PASS",worker_attempts:2,
      retries:1,total_tokens:90,landed_commit:$sha} and
  .stages[1] == {id:"02-legacy",status:"superseded",verdict:null,worker_attempts:null,
      retries:null,total_tokens:null,landed_commit:null}' "$tmp/one" >/dev/null
# Explicitly unknown usage in a real dispatch prevents a misleading complete total.
printf '{"ts":"2026-11-22T08:19:30Z","stage_id":"01-good","role":"verifier","result":"fail","usage_status":"unknown","total_tokens":0}\n' >>"$repo/state/cost-log.jsonl"
"$tool" "$repo" "$run" halted | jq -e '.outcome=="halted" and .stages[0].total_tokens==null and .stages[0].worker_attempts==2' >/dev/null
if "$tool" "$repo" run-20261120-000000 finished >"$tmp/missing" 2>/dev/null; then exit 1; fi
[[ ! -s "$tmp/missing" && ! -e "$repo/runs" ]]
if "$tool" "$repo" "$run" running >"$tmp/invalid" 2>/dev/null; then exit 1; fi
[[ ! -s "$tmp/invalid" ]]
# Compare the original inputs after reversing only the fixture's own append.
sed '$d' "$repo/state/cost-log.jsonl" >"$tmp/original-ledger"
cat "$tmp/original-ledger" >"$repo/state/cost-log.jsonl"
[[ "$(cksum "$repo"/state/{state.yaml,budget.json,cost-log.jsonl} "$repo"/state/verifiers/01-good.json)" == "$before" ]]
# AUTOMETTA-CONTRACT-END
echo 'PASS: portable run summary'

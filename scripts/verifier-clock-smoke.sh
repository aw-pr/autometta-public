#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=regression suite beyond the frozen verifier-clock contract
# verifier-clock-smoke.sh: offline proof that the harness's own observation of a
# finished verifier, not the report's ran_at, stamps stage state and governs
# proposals freshness. Isolated temporary fixtures; no auth, network or spend.
#
#   1. A second attempt on the same stage and artefact path gets its own stamp,
#      and a replay within one attempt keeps the first.
#   2. An orphan found by the in-progress scan is stamped, for PASS as well as FAIL.
#   3. proposals.sh uses the observed time only when the receipt matches the
#      report on disk; a rewritten report or a stale receipt falls back to ran_at.
#   4. Re-verification after a citation brings the finding back; a citation made
#      after the observation suppresses it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export AUTOMETTA_HOME="$tmp/host" PHAT_CONTROLLER_HOME="$tmp/host" PROPOSALS_LEDGER_PATH="$tmp/ledger.jsonl"
export AUTOMETTA_AGENT='Fixture <fixture@local>'
source "$root/scripts/tick.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
repo="$tmp/lab"; state="$repo/state/state.yaml"
mkdir -p "$repo/state/verifiers" "$repo/state/logs" "$AUTOMETTA_HOME/subscribers"
printf 'repo_path: "%s"\nenabled: true\n' "$repo" > "$AUTOMETTA_HOME/subscribers/lab.yaml"
budget_account_tokens_from_dispatch() { return 0; }
stage_snapshot_tokens() { return 0; }
costlog_emit_verifier() { return 0; }
_process_verifier_artefact() { return 0; }
log() { :; }
verifier_completion_ready() { return 0; }
field() { state_json "$state" | jq -r --arg id "$1" ".stages[] | select(.id == \$id) | $2"; }
report() { jq -nc --arg id "$1" --arg at "$2" --arg o "$3" \
  '{stage_id:$id,ran_at:$at,overall:$o,criteria:[],additional_findings:"HARNESS: clock fixture"}' > "$repo/state/verifiers/$1.json"; }
rel() { printf 'state/verifiers/%s.json' "$1"; }

printf '{"current_stage":null,"stages":[{"id":"01-a","status":"in_progress","verifier":"V","verifier_attempts":1,"verifier_started_at":"2026-01-01T00:00:00Z","verifier_artefact":"state/verifiers/01-a.json"}]}\n' > "$state"
report 01-a 2099-01-01T00:00:00Z FAIL
consume_verifier_artefact "$repo" "$state" 01-a "$(rel 01-a)" ""
first="$(field 01-a .verifier_completed_at)"
[[ "$first" != null && "$first" != 2099* ]] || fail "attempt 1 not stamped by the harness: $first"
[[ "$(field 01-a .verifier_completed_receipt.reported_at)" == 2099-01-01T00:00:00Z ]] || fail "receipt lost the reported time"
sleep 2
consume_verifier_artefact "$repo" "$state" 01-a "$(rel 01-a)" ""
[[ "$(field 01-a .verifier_completed_at)" == "$first" ]] || fail "replay moved the first observation"

state_apply_json "$state" '(.stages[0]).verifier_attempts = 2 | (.stages[0]).verifier_started_at = "2026-01-02T00:00:00Z"'
report 01-a 2099-01-01T00:00:00Z PASS
consume_verifier_artefact "$repo" "$state" 01-a "$(rel 01-a)" ""
second="$(field 01-a .verifier_completed_at)"
[[ "$second" != "$first" ]] || fail "second attempt on the same artefact path reused the older stamp"
[[ "$(field 01-a .verifier_completed_receipt.dispatch)" == 2:2026-01-02T00:00:00Z ]] || fail "receipt not bound to the second dispatch"

printf '{"current_stage":null,"stages":[{"id":"02-b","status":"in_progress","verifier":"V","verifier_attempts":1,"verifier_started_at":"2026-01-01T00:00:00Z","verifier_pid":99999,"verifier_artefact":"state/verifiers/02-b.json"}]}\n' > "$state"
report 02-b 2099-01-01T00:00:00Z PASS
consume_orphaned_verifier_artefacts "$repo" "$state" ""
[[ "$VERIFIER_ARTEFACTS_CONSUMED" == 1 ]] || fail "orphan scan consumed $VERIFIER_ARTEFACTS_CONSUMED artefacts"
[[ "$(field 02-b .verifier_completed_at)" != null ]] || fail "orphan not stamped"

rm -f "$repo/state/verifiers/01-a.json"
# 3 and 4: proposals freshness follows the receipt.
sh="$root/scripts/proposals.sh"
"$sh" unlifted | grep -F 'HARNESS: clock fixture' >/dev/null || fail "orphan finding not listed"
"$sh" dismiss --repo lab --stage 02-b --evidence "$(rel 02-b)" --note fixture >/dev/null
[[ -z "$("$sh" unlifted)" ]] || fail "citation after the observation did not suppress the finding"
report 02-b 2099-06-01T00:00:00Z PASS
"$sh" unlifted | grep -F 'HARNESS: clock fixture' >/dev/null || fail "a rewritten report should fall back to its own ran_at and list again"
# Digest and dispatch binding: re-observe, dismiss, then break each half of the receipt.
report 02-b 2099-01-01T00:00:00Z PASS
printf '{"current_stage":null,"stages":[{"id":"02-b","status":"in_progress","verifier":"V","verifier_attempts":1,"verifier_started_at":"2026-01-01T00:00:00Z","verifier_artefact":"state/verifiers/02-b.json"}]}\n' > "$state"
consume_verifier_artefact "$repo" "$state" 02-b "$(rel 02-b)" ""
"$sh" dismiss --repo lab --stage 02-b --evidence "$(rel 02-b)" --note digest >/dev/null
[[ -z "$("$sh" unlifted)" ]] || fail "unchanged replay must stay suppressed"
jq -c '.additional_findings = "HARNESS: replaced bytes"' "$repo/$(rel 02-b)" > "$tmp/r.json" && mv "$tmp/r.json" "$repo/$(rel 02-b)"
"$sh" unlifted | grep -F 'HARNESS: replaced bytes' >/dev/null || fail "replacement at same path and ran_at must list"
report 02-b 2099-01-01T00:00:00Z PASS
[[ -z "$("$sh" unlifted)" ]] || fail "restored bytes should match the receipt again"
state_apply_json "$state" '(.stages[0]).verifier_started_at = "2026-01-03T00:00:00Z"'
"$sh" unlifted | grep -F 'HARNESS: clock fixture' >/dev/null || fail "obsolete receipt for an earlier dispatch must be rejected"
state_apply_json "$state" '(.stages[0]).verifier_started_at = "2026-01-01T00:00:00Z" | del(.stages[0].verifier_completed_receipt.sha256)'
"$sh" unlifted | grep -F 'HARNESS: clock fixture' >/dev/null || fail "receipt without a digest must fall back"
printf '{"current_stage":null,"stages":[{"id":"02-b","status":"verifier_failed","verifier_completed_at":"2000-01-01T00:00:00Z","verifier_completed_receipt":{"dispatch":"1:x","artefact":"state/verifiers/other.json","reported_at":"2099-06-01T00:00:00Z"}}]}\n' > "$state"
"$sh" unlifted | grep -F 'HARNESS: clock fixture' >/dev/null || fail "a receipt for another artefact must not be bound to this report"
# 6. Replacement within one dispatch: the first receipt is frozen, the replacement stays listed.
printf '{"current_stage":null,"stages":[{"id":"03-c","status":"in_progress","verifier":"V","verifier_attempts":1,"verifier_started_at":"2026-01-01T00:00:00Z","verifier_artefact":"state/verifiers/03-c.json"}]}\n' > "$state"
report 03-c 2099-01-01T00:00:00Z PASS
consume_verifier_artefact "$repo" "$state" 03-c "$(rel 03-c)" ""
orig_digest="$(shasum -a 256 < "$repo/$(rel 03-c)" | awk '{print $1}')"
first_receipt="$(field 03-c '[.verifier_completed_at, .verifier_completed_receipt] | tojson')"
"$sh" dismiss --repo lab --stage 03-c --evidence "$(rel 03-c)" --note replay >/dev/null
jq -c '.additional_findings = "HARNESS: replaced in dispatch"' "$repo/$(rel 03-c)" > "$tmp/r.json" && mv "$tmp/r.json" "$repo/$(rel 03-c)"
"$sh" unlifted | grep -F 'HARNESS: replaced in dispatch' >/dev/null || fail "replacement should be listed before reconsumption"
sleep 2
consume_verifier_artefact "$repo" "$state" 03-c "$(rel 03-c)" ""
consume_verifier_artefact "$repo" "$state" 03-c "$(rel 03-c)" ""
[[ "$(field 03-c '[.verifier_completed_at, .verifier_completed_receipt] | tojson')" == "$first_receipt" ]] || fail "receipt changed on reconsumption in one dispatch"
[[ "$(field 03-c .verifier_completed_receipt.sha256)" == "$orig_digest" ]] || fail "digest no longer belongs to the original bytes"
"$sh" unlifted | grep -F 'HARNESS: replaced in dispatch' >/dev/null || fail "replacement should stay listed after reconsumption"
state_apply_json "$state" '(.stages[0]).verifier_attempts = 2 | (.stages[0]).verifier_started_at = "2026-01-02T00:00:00Z"'
consume_verifier_artefact "$repo" "$state" 03-c "$(rel 03-c)" ""
[[ "$(field 03-c .verifier_completed_receipt.sha256)" == "$(shasum -a 256 < "$repo/$(rel 03-c)" | awk '{print $1}')" ]] || fail "new dispatch receipt should name its own report"
[[ "$(field 03-c .verifier_completed_receipt.dispatch)" == 2:2026-01-02T00:00:00Z ]] || fail "new dispatch receipt not bound to its dispatch"
# 5. The public record: the schema accepts the receipt and still rejects strays.
if python3 -c 'import jsonschema' 2>/dev/null; then
  python3 - "$root/schemas/state.yaml.json" <<'PY2' || fail "schema does not describe the verifier receipt"
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
doc = {"stages": [{"id": "01-a", "status": "completed", "verifier_completed_at": "2026-11-22T09:00:00Z",
       "verifier_completed_receipt": {"dispatch": "1:x", "artefact": "state/verifiers/01-a.json", "reported_at": None}}]}
v = jsonschema.Draft202012Validator(schema)
errors = [e for e in v.iter_errors(doc) if "verifier_completed" in "/".join(map(str, e.absolute_path)) or "verifier_completed" in e.message]
assert not errors, errors
doc["stages"][0]["verifier_completed_receipt"]["stray"] = 1
assert any("stray" in e.message for e in v.iter_errors(doc))
PY2
fi
printf 'PASS: verifier-clock-smoke\n'

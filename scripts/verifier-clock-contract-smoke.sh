#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/180-verifier-clock.md
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export AUTOMETTA_HOME="$tmp/host" PHAT_CONTROLLER_HOME="$tmp/host" PROPOSALS_LEDGER_PATH="$tmp/ledger.jsonl"
source "$root/scripts/tick.sh"
repo="$tmp/lab"
state="$repo/state/state.yaml"
id=01-clock
rel="state/verifiers/$id.json"
mkdir -p "$repo/state/verifiers" "$repo/state/logs" "$AUTOMETTA_HOME/subscribers"
printf 'repo_path: "%s"\nenabled: true\n' "$repo" > "$AUTOMETTA_HOME/subscribers/lab.yaml"
printf '{"current_stage":"01-clock","stages":[{"id":"01-clock","status":"in_progress","verifier":"Claude Fixture","verifier_attempts":1,"verifier_started_at":"2026-01-01T00:00:00Z","verifier_artefact":"state/verifiers/01-clock.json"}]}\n' > "$state"
printf '{"stage_id":"01-clock","ran_at":"2099-01-01T00:00:00Z","overall":"FAIL","criteria":[],"additional_findings":"HARNESS: test clock"}\n' > "$repo/$rel"
# Keep bookkeeping and landing out of this fixture. Exercise the real receipt intake.
budget_account_tokens_from_dispatch() { return 0; }
stage_snapshot_tokens() { return 0; }
costlog_emit_verifier() { return 0; }
_process_verifier_artefact() { return 0; }
consume() { consume_verifier_artefact "$repo" "$state" "$id" "$rel" ""; }
stamp() { state_json "$state" | jq -er '.stages[0].verifier_completed_at | strings'; }
before="$(date -u +%s)"
consume
first="$(stamp)" || { echo 'FAIL: no harness completion in stage state' >&2; exit 1; }
python3 - "$first" "$before" "$(date -u +%s)" <<'PY'
import sys
from datetime import datetime
value = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
assert value.utcoffset() is not None and int(sys.argv[2]) <= int(value.timestamp()) <= int(sys.argv[3])
PY
sleep 2
consume
[[ "$(stamp)" == "$first" ]]
jq -e '.overall=="FAIL" and .ran_at=="2099-01-01T00:00:00Z"' "$repo/$rel" >/dev/null
"$root/scripts/proposals.sh" unlifted | grep -F 'HARNESS: test clock' >/dev/null
export AUTOMETTA_AGENT='Fixture <fixture@local>'
"$root/scripts/proposals.sh" dismiss --repo lab --stage "$id" --evidence "$rel" --note 'fixture citation' >/dev/null
[[ -z "$("$root/scripts/proposals.sh" unlifted)" ]] || { echo 'FAIL: clock did not govern citation freshness' >&2; exit 1; }
# A historical report without any stage receipt retains its legacy timestamp.
printf '{"stage_id":"02-old","ran_at":"2099-01-01T00:00:00Z","additional_findings":"HARNESS: legacy"}\n' > "$repo/state/verifiers/02-old.json"
"$root/scripts/proposals.sh" dismiss --repo lab --stage 02-old --evidence state/verifiers/02-old.json --note 'older citation' >/dev/null
"$root/scripts/proposals.sh" unlifted | grep -F 'HARNESS: legacy' >/dev/null
# AUTOMETTA-CONTRACT-END
echo 'PASS: verifier completion clock'

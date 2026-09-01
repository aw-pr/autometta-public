#!/usr/bin/env bash
# dashboard-fail-closed-smoke.sh: unavailable spend must never render as zero.
# shellcheck disable=SC2016,SC2251
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
aggregate_script="${AGGREGATE_DASHBOARD_SCRIPT:-$script_dir/aggregate-dashboard.sh}"
real_jq="$(command -v jq)"
scratch="$(mktemp -d)"
cleanup() {
  case "$scratch" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$scratch" ;; esac
}
trap cleanup EXIT

fixture_repo="$scratch/repo"
controller_home="$scratch/controller"
mkdir -p "$fixture_repo/state" "$controller_home/subscribers" "$scratch/bin"

cat > "$fixture_repo/state/state.yaml" <<'YAML'
version: 1
current_stage: sample
stages:
  - id: sample
    run_id: run-20260901T120000Z
    status: pending
    tokens: 0
YAML
cat > "$controller_home/subscribers/sample.yaml" <<YAML
enabled: true
repo_path: "$fixture_repo"
manifest_path: "$fixture_repo/.autometta.local.yaml"
YAML
cat > "$scratch/bin/jq" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ "$argument" == -s ]]; then
    exit 42
  fi
done
exec "$REAL_JQ" "$@"
SH
chmod +x "$scratch/bin/jq"

run_aggregate() {
  AUTOMETTA_HOME="$controller_home" HOME="$scratch/home" \
    "$aggregate_script" --repo "$fixture_repo"
}

assert_unavailable_payload() {
  "$real_jq" -e '
    (.state_error | contains("spend unavailable")) and
    (.spend.state_error == "spend unavailable") and
    (.history.state_error == "spend unavailable") and
    ([.spend.input_tokens, .spend.cached_input_tokens, .spend.output_tokens,
      .spend.tokens_total, .spend.cost_usd_est,
      .history.summary.card_count, .history.summary.seven_day_cost_usd_est]
      | all(. == null))
  ' >/dev/null
}

# AUTOMETTA-CONTRACT-BEGIN
printf '%s\n' '{"ts":"2026-09-01T12:00:00Z","stage_id":"sample","role":"worker","result":"pass","input_tokens":7,"cached_input_tokens":0,"output_tokens":3,"cost_usd_est":0.01}' \
  > "$fixture_repo/state/cost-log.jsonl"
broken_payload="$(REAL_JQ="$real_jq" PATH="$scratch/bin:$PATH" run_aggregate)"
printf '%s' "$broken_payload" | assert_unavailable_payload

printf '%s\n' '{malformed' > "$fixture_repo/state/cost-log.jsonl"
malformed_payload="$(run_aggregate)"
printf '%s' "$malformed_payload" | assert_unavailable_payload

rm -f "$fixture_repo/state/cost-log.jsonl"
absent_payload="$(run_aggregate)"
printf '%s' "$absent_payload" | "$real_jq" -e '
  (.state_error == null) and
  (.spend.state_error == null) and
  (.spend.tokens_total == 0) and
  (.spend.cost_usd_est == 0) and
  (.history.summary.card_count == 0)
' >/dev/null

tui_capture="$(PYTHONPATH="$script_dir/lib/tui" python3 - "$malformed_payload" <<'PY'
import json
import sys

from render import TuiState, render

payload = json.loads(sys.argv[1])
state = TuiState()
state.update(payload)
state.page = 2
print(render(state, 120, 35).text())
state.page = 1
print(render(state, 120, 40).text())
PY
)"
grep -q 'spend unavailable' <<<"$tui_capture"
! grep -q '0 cards' <<<"$tui_capture"
! grep -q '\$0.00 actual' <<<"$tui_capture"
# AUTOMETTA-CONTRACT-END

printf 'tui capture: %s\n' "$(grep -m 1 'spend unavailable' <<<"$tui_capture" | sed 's/^[[:space:]│]*//')"
printf 'dashboard fail-closed smoke: PASS\n'

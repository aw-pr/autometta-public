#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

controller_home="$fixture_root/controller"
fixture_repo="$fixture_root/fleet-fixture"
mkdir -p "$controller_home/subscribers" "$fixture_repo/state/logs" \
  "$fixture_repo/state/handoffs" "$fixture_repo/state/verifiers"

cat > "$controller_home/subscribers/fleet-fixture.yaml" <<EOF
enabled: true
repo_path: "$fixture_repo"
manifest_path: ""
EOF

cat > "$fixture_repo/state/state.yaml" <<'EOF'
current_stage: null
stages:
  - id: failed-stage
    status: verifier_failed
    worker: Codex fixture
    verifier: Claude fixture
    completed_at: null
EOF

cat > "$fixture_repo/state/budget.json" <<'EOF'
{
  "tokens_spent": 16096027,
  "token_cap_total": 150000000,
  "halted": false,
  "halt_reason": null,
  "consecutive_failures": 0,
  "consecutive_failure_cap": 3
}
EOF

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$fixture_repo/state/cost-log.jsonl" <<EOF
{"ts":"$now","input_tokens":12000000,"cached_input_tokens":300000,"output_tokens":45678,"cost_usd_est":1.234}
{"ts":"$now","input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"cost_usd_est":2.221}
EOF

printf '%s\n' '  # Provider limit alerts (usage/rate limit, overload, exhausted credit)' \
  > "$fixture_repo/state/logs/completed-a-worker.log"
printf '%s\n' '{"status":"pass"}' > "$fixture_repo/state/handoffs/completed-a.json"
printf '%s\n' '71f99a7 996d42eab40d765bc5ea681511ecfe7234cb823c fix(budget): rate-limit the halt log; keep one halt-clearing path' \
  > "$fixture_repo/state/logs/completed-b-verifier.log"
printf '%s\n' '{"overall":"PASS"}' > "$fixture_repo/state/verifiers/completed-b.json"
printf '%s\n' '71f99a7 fix(budget): rate-limit the halt log; keep one halt-clearing path' \
  > "$fixture_repo/state/logs/completed-c-verifier.attempt-1.log"
printf '%s\n' '{"overall":"PASS"}' > "$fixture_repo/state/verifiers/completed-c.json"
printf '%s\n' "You've hit your session limit · resets 11:10pm (Europe/London)" \
  > "$fixture_repo/state/logs/genuine-worker.log"

scan_output="$("$script_dir/scan-usage-limits.sh" "$fixture_repo")"
[[ "$scan_output" == *"You've hit your session limit"* ]]
[[ "$scan_output" != *"# Provider limit alerts"* ]]
[[ "$scan_output" != *"996d42eab40d765bc5ea681511ecfe7234cb823c"* ]]
[[ "$scan_output" != *"71f99a7 fix(budget): rate-limit"* ]]

PHAT_CONTROLLER_HOME="$controller_home" "$script_dir/aggregate-dashboard.sh" >/dev/null
render_one="$(PHAT_CONTROLLER_HOME="$controller_home" PHAT_CONTROLLER_FLEET_ONCE=true \
  "$script_dir/attach.sh" --fleet-ticker)"
render_two="$(PHAT_CONTROLLER_HOME="$controller_home" PHAT_CONTROLLER_FLEET_ONCE=true \
  "$script_dir/attach.sh" --fleet-ticker)"

alerts_one="$(printf '%s\n' "$render_one" | sed -n '/^ALERTS/,/^OVERLAP/p')"
alerts_two="$(printf '%s\n' "$render_two" | sed -n '/^ALERTS/,/^OVERLAP/p')"
[[ "$alerts_one" == "$alerts_two" ]]
[[ "$alerts_one" == *"repo"*"queue"*"empty"* ]]
[[ "$alerts_one" == *"failed-stage"*"stage"*"verifier_failed"* ]]
[[ "$alerts_one" == *"genuine"*"provider-limit"*"You've hit your session limit"* ]]
[[ "$render_one" == *"12.3M/\$3.46"* ]]
[[ "$render_one" == *"16.1M/150M"* ]]
[[ "$(jq -r '.repos[0].today_tokens' "$controller_home/dashboard/data.json")" == 12345678 ]]

jq '.generated_at = "2000-01-01T00:00:00Z"' "$controller_home/dashboard/data.json" \
  > "$controller_home/dashboard/data.json.tmp"
mv "$controller_home/dashboard/data.json.tmp" "$controller_home/dashboard/data.json"
stale_render="$(PHAT_CONTROLLER_HOME="$controller_home" PHAT_CONTROLLER_FLEET_ONCE=true \
  "$script_dir/attach.sh" --fleet-ticker)"
[[ "$stale_render" == *"Data generated: 2000-01-01T00:00:00Z"* ]]
[[ "$stale_render" == *"FLEET DATA STALE"* ]]

PHAT_CONTROLLER_HOME="$controller_home" PHAT_CONTROLLER_FLEET_REFRESH_INTERVAL=1 \
  "$script_dir/attach.sh" --fleet-refresh >/dev/null 2>&1 &
refresh_pid=$!
for _ in 1 2 3 4 5; do
  generated="$(jq -r '.generated_at' "$controller_home/dashboard/data.json")"
  [[ "$generated" != "2000-01-01T00:00:00Z" ]] && break
  sleep 1
done
kill "$refresh_pid" 2>/dev/null || true
wait "$refresh_pid" 2>/dev/null || true
[[ "$generated" != "2000-01-01T00:00:00Z" ]]

printf 'PASS alerts table, spend formatting, limit evidence and scheduled refresh\n'

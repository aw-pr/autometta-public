#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3" ;; *) ;; esac; }

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
printf '%s\n' 'weights through the same codex CLI. Zero marginal cost, no rate limits, no API bill.' \
  > "$fixture_repo/state/logs/card-45-worker.log"

scan_output="$("$script_dir/scan-usage-limits.sh" "$fixture_repo")"
assert_contains "$scan_output" "You've hit your session limit" 'genuine provider banner was missed'
assert_not_contains "$scan_output" 'Zero marginal cost' 'card 45 prose raised a provider limit'
assert_not_contains "$scan_output" '# Provider limit alerts' 'scanner implementation prose raised an alert'
assert_not_contains "$scan_output" '996d42eab40d765bc5ea681511ecfe7234cb823c' 'completed verifier raised an alert'
assert_not_contains "$scan_output" '71f99a7 fix(budget): rate-limit' 'commit prose raised an alert'

PHAT_CONTROLLER_HOME="$controller_home" "$script_dir/aggregate-dashboard.sh" >/dev/null
# Wide enough that ESCALATIONS' detail column (the provider-limit message)
# is not squeezed out by the mandatory repo/result/stage columns ahead of it.
render_one="$(PHAT_CONTROLLER_HOME="$controller_home" PHAT_CONTROLLER_FLEET_ONCE=true \
  PHAT_CONTROLLER_FLEET_COLUMNS=160 "$script_dir/attach.sh" --fleet-ticker)"

assert_contains "$render_one" 'ESCALATIONS' 'ESCALATIONS section missing'
assert_contains "$render_one" 'failed-stage' 'failed stage missing'
assert_contains "$render_one" 'verifier_failed' 'failure status missing'
assert_contains "$render_one" "session limit" 'genuine provider alert missing from pane'
assert_not_contains "$render_one" 'Zero marginal cost' 'card prose appeared in pane limits'
assert_contains "$render_one" '12.3M' 'today token shortening changed'
assert_contains "$render_one" "\$3.46" 'today cost formatting changed'
# Card 66 moved the REPOS row's token shortening onto the reused
# scripts/lib/repo-ticker-render.py short_tokens (one formatter for both
# pages), which always carries one decimal place rather than card 63's own
# bash formatter's whole-number special case, hence 150.0M rather than 150M.
assert_contains "$render_one" '16.1M/150.0M' 'window token formatting changed'
[[ "$(jq -r '.repos[0].today_tokens' "$controller_home/dashboard/data.json")" == 12345678 ]] \
  || fail 'exact aggregate token total changed'

jq '.generated_at = "2000-01-01T00:00:00Z"' "$controller_home/dashboard/data.json" \
  > "$controller_home/dashboard/data.json.tmp"
mv "$controller_home/dashboard/data.json.tmp" "$controller_home/dashboard/data.json"
stale_render="$(PHAT_CONTROLLER_HOME="$controller_home" PHAT_CONTROLLER_FLEET_ONCE=true \
  "$script_dir/attach.sh" --fleet-ticker)"
assert_contains "$stale_render" 'Data generated:' 'generated age missing'
assert_contains "$stale_render" 'FLEET DATA STALE' 'stale warning missing'

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
[[ "$generated" != "2000-01-01T00:00:00Z" ]] || fail 'scheduled refresh did not update data'

printf 'PASS alerts table, spend formatting, limit evidence and scheduled refresh\n'

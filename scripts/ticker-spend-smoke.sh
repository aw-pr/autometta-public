#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

repo="$fixture_root/repo"
controller="$fixture_root/controller"
mkdir -p "$repo/state/active-agents" "$repo/state/recent-agents" "$repo/state/logs" "$controller/subscribers"

printf '%s\n' '{"tokens_spent":250,"token_cap_total":1000}' > "$repo/state/budget.json"
printf '%s\n' 'stages: []' > "$repo/state/state.yaml"
printf 'repo_path: "%s"\nenabled: false\n' "$repo" > "$controller/subscribers/fixture.yaml"

now="$(date -u +%s)"
jq -nc --argjson now "$now" '
  def row($ago; $input; $cached; $output; $cost; $hit):
    {ts:(($now-$ago)|strftime("%Y-%m-%dT%H:%M:%SZ")),input_tokens:$input,
     cached_input_tokens:$cached,output_tokens:$output,cost_usd_est:$cost,cache_hit_rate:$hit};
  row(1800;100;50;25;1.25;0.8),
  row(7200;20;0;0;0.75;0.4),
  row(518399;30;0;0;3;0)
' > "$repo/state/cost-log.jsonl"

printf 'tokens used\n1,234\n' > "$repo/state/logs/live.log"
jq -n --arg log "$repo/state/logs/live.log" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {checked_at:$now,entries:[{family:"codex",role:"worker",card_path:"fixture.md",pid:42,
    elapsed_seconds:90,log_size:20,log_path:$log,flags:[]}]}' > "$repo/state/heartbeat.json"

output="$(PHAT_CONTROLLER_HOME="$controller" "$script_dir/agent-ticker.sh" "$repo" --once)"
printf '%s\n' "$output" | grep -Fq 'window: 250 / 1000 tokens (25%)'
printf '%s\n' "$output" | grep -Fq 'today: $2 est  |  7d: $5 est'
printf '%s\n' "$output" | grep -Fq 'mean cache hit today: 60%  |  last hour: 175 tokens/h'
printf '%s\n' "$output" | grep -Eq 'tokens:1234[[:space:]]'

# A large historical prefix must not change the figures or make refresh cost
# proportional to the whole ledger: the ticker reads only the final 5,000 rows.
large_log="$fixture_root/large-cost-log.jsonl"
awk 'BEGIN { for (i=0;i<50000;i++) print "{\"ts\":\"2020-01-01T00:00:00Z\",\"input_tokens\":1}" }' > "$large_log"
cat "$repo/state/cost-log.jsonl" >> "$large_log"
mv "$large_log" "$repo/state/cost-log.jsonl"

TIMEFORMAT='%R'
{ time PHAT_CONTROLLER_HOME="$controller" "$script_dir/agent-ticker.sh" "$repo" --once >/dev/null; } 2> "$fixture_root/timing"
elapsed="$(tail -n1 "$fixture_root/timing")"
awk -v elapsed="$elapsed" 'BEGIN { if (elapsed > 5.0) exit 1 }'

printf 'PASS ticker spend figures; 50,003-row refresh %ss (bounded to final 5,000 rows)\n' "$elapsed"

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixture="$(mktemp -d)"
cleanup() {
  case "$fixture" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$fixture" ;; esac
}
trap cleanup EXIT

controller="$fixture/controller"
mkdir -p "$controller/subscribers" "$controller/dashboard"
now="$(date -u +%s)"
iso_at() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
today="$(iso_at "$now")"
old="$(iso_at "$(( now - 6 * 86400 ))")"
started="$(iso_at "$(( now - 90 ))")"

make_repo() {
  local name="$1" spent="$2" cap="$3" halted="$4"
  local path="$fixture/$name"
  mkdir -p "$path/state/active-agents" "$path/state/verifiers" "$path/state/logs"
  printf 'enabled: true\nrepo_path: %s\nmanifest_path: \n' "$path" > "$controller/subscribers/$name.yaml"
  printf '{"tokens_spent":%s,"token_cap_total":%s,"halted":%s,"halt_reason":%s,"consecutive_failures":0,"consecutive_failure_cap":3}\n' \
    "$spent" "$cap" "$halted" "$([[ "$halted" == true ]] && printf '"operator stop"' || printf null)" \
    > "$path/state/budget.json"
}

make_repo halted 10 100 true
make_repo cap 90 100 false
make_repo historic 10 100 false
make_repo clean 0 100 false
make_repo broken 0 100 false

printf '{"stages":[]}\n' > "$fixture/halted/state/state.yaml"
printf '%s\n' "{\"stages\":[
  {\"id\":\"active-42\",\"status\":\"in_progress\",\"worker\":\"GPT-5.6 Sol <gpt-5-6-sol@local>\",\"verifier\":\"Claude Sonnet 5 <claude-sonnet-5@local>\",\"started_at\":\"$started\"},
  {\"id\":\"queue-one\",\"status\":\"pending\",\"worker\":\"GPT-5.6 Terra <gpt-5-6-terra@local>\",\"verifier\":\"Claude Sonnet 5 <claude-sonnet-5@local>\"},
  {\"id\":\"queue-two\",\"status\":\"pending\",\"worker\":\"GPT-5.6 Luna <gpt-5-6-luna@local>\",\"verifier\":\"Claude Haiku 4.5 <claude-haiku-4-5@local>\"}
]}" > "$fixture/cap/state/state.yaml"
printf '%s\n' "{\"stages\":[{\"id\":\"old-failure\",\"status\":\"verifier_failed\",\"completed_at\":\"$old\"}]}" \
  > "$fixture/historic/state/state.yaml"
printf '{"stages":[]}\n' > "$fixture/clean/state/state.yaml"
printf 'stages:\n  - id: broken\n    status: [\n' > "$fixture/broken/state/state.yaml"

printf '%s\n' "{\"pid\":$$,\"role\":\"worker\",\"family\":\"codex\",\"identity\":\"GPT-5.6 Sol <gpt-5-6-sol@local>\",\"card_path\":\"docs/stages/active-42.md\",\"log_path\":\"$fixture/cap/state/logs/active.log\",\"budget_seconds\":5400,\"started_at\":\"$started\"}" \
  > "$fixture/cap/state/active-agents/$$.json"
printf '%s\n' "{\"checked_at\":\"$today\",\"entries\":[{\"pid\":$$,\"elapsed_seconds\":90,\"flags\":[]}]}" \
  > "$fixture/cap/state/heartbeat.json"
printf 'live\n' > "$fixture/cap/state/logs/active.log"

cost_log="$fixture/cap/state/cost-log.jsonl"
printf '%s\n' \
  "{\"ts\":\"$today\",\"repo\":\"cap\",\"stage_id\":\"good-stage\",\"role\":\"worker\",\"input_tokens\":100,\"cached_input_tokens\":200,\"output_tokens\":50,\"cost_usd_est\":0.01,\"result\":\"pass\"}" \
  "{\"ts\":\"$today\",\"repo\":\"cap\",\"stage_id\":\"failed-stage\",\"role\":\"worker\",\"input_tokens\":1000,\"cached_input_tokens\":2000,\"output_tokens\":300,\"cost_usd_est\":0.02,\"result\":\"fail\"}" \
  "{\"ts\":\"$today\",\"repo\":\"cap\",\"stage_id\":\"aborted-stage\",\"role\":\"verifier\",\"input_tokens\":400,\"cached_input_tokens\":500,\"output_tokens\":60,\"cost_usd_est\":0.03,\"result\":\"aborted\"}" \
  "{\"ts\":\"$today\",\"repo\":\"cap\",\"stage_id\":\"stalled-stage\",\"role\":\"worker\",\"input_tokens\":70,\"cached_input_tokens\":80,\"output_tokens\":90,\"cost_usd_est\":0.04,\"result\":\"stalled\"}" \
  > "$cost_log"

aggregate() { AUTOMETTA_HOME="$controller" "$script_dir/aggregate-dashboard.sh" >/dev/null; }
render_ascii() {
  local width="$1" out="$2"
  LC_ALL=C NO_COLOR=1 AUTOMETTA_HOME="$controller" AUTOMETTA_FLEET_ONCE=true \
    AUTOMETTA_FLEET_COLUMNS="$width" "$script_dir/attach.sh" --fleet-ticker > "$out"
}
assert_jq() {
  local filter="$1" message="$2"
  jq -e "$filter" "$controller/dashboard/data.json" >/dev/null || { printf 'FAIL %s\n' "$message" >&2; exit 1; }
}

aggregate
assert_jq '.repos | length == 5' 'corrupt subscriber stopped fleet aggregation'
[[ "$(jq -r '.repos[] | select(.name=="halted") | [.light,.light_reason] | @tsv' "$controller/dashboard/data.json")" == $'red\tbudget halted' ]]
[[ "$(jq -r '.repos[] | select(.name=="cap") | [.light,.light_reason] | @tsv' "$controller/dashboard/data.json")" == $'amber\t85% of token cap' ]]
[[ "$(jq -r '.repos[] | select(.name=="historic") | [.light,.light_reason] | @tsv' "$controller/dashboard/data.json")" == $'amber\thistoric terminal failure' ]]
[[ "$(jq -r '.repos[] | select(.name=="clean") | [.light,.light_reason] | @tsv' "$controller/dashboard/data.json")" == $'green\tno dashboard rule fired' ]]
[[ "$(jq -r '.repos[] | select(.name=="broken") | [.light,.light_reason] | @tsv' "$controller/dashboard/data.json")" == $'red\tstate unreadable' ]]
assert_jq '.repos[] | select(.name=="cap") |
  (.agents[0].stage_id == "active-42" and .agents[0].elapsed_seconds == 90 and .agents[0].elapsed == 90 and
   [.queue[].stage_id] == ["queue-one","queue-two"])' 'agent or queue join is wrong'
assert_jq '.spend.tokens_total == 4850 and .fleet_totals.today_tokens == 4850 and
  .spend.lost.tokens == 4500 and ([.spend.failures[].tokens_lost] | add) == 4500' \
  'spend or lost-token totals do not reconcile'

# Card 66: the live fleet page carries TOTALS, REPOS (state, queue, spend)
# and ESCALATIONS only; the itemised failures and per-role spend tables it
# replaces those checks below verify from scripts/failures-history.sh
# --fleet instead, the command they moved to.
ascii80="$fixture/ascii-80.txt"; ascii120="$fixture/ascii-120.txt"
render_ascii 80 "$ascii80"; render_ascii 120 "$ascii120"
for pair in "$ascii80:80" "$ascii120:120"; do
  file="${pair%:*}"; limit="${pair##*:}"
  awk -v max="$limit" 'length($0)>max {exit 1}' "$file" || { printf 'FAIL line exceeds %s columns\n' "$limit" >&2; exit 1; }
done
[[ "$(grep -c '^TOTALS$' "$ascii120")" -eq 1 ]]
grep -q 'halted.*HALTED: operator stop' "$ascii120"
grep -q 'state unreadable' "$ascii120"
grep -q 'ESCALATIONS' "$ascii120"
if grep -q 'FAILURES' "$ascii120"; then printf 'FAIL FAILURES table leaked into the live fleet page\n' >&2; exit 1; fi
fleet_history="$(AUTOMETTA_HOME="$controller" "$script_dir/failures-history.sh" --fleet)"
[[ "$fleet_history" == *'old-failure'* ]] || { printf 'FAIL stage failure missing from the fleet history command\n' >&2; exit 1; }
[[ "$fleet_history" == *'verifier_failed'* ]] || { printf 'FAIL failure status missing from the fleet history command\n' >&2; exit 1; }
[[ "$fleet_history" == *'failed-stage'* ]] || { printf 'FAIL dispatch failure missing from the fleet history command\n' >&2; exit 1; }
[[ "$fleet_history" == *'aborted-stage'* ]] || { printf 'FAIL aborted dispatch missing from the fleet history command\n' >&2; exit 1; }
[[ "$fleet_history" == *'stalled-stage'* ]] || { printf 'FAIL stalled dispatch missing from the fleet history command\n' >&2; exit 1; }
[[ "$fleet_history" == *'Total tokens lost (6d): 4500'* ]] || { printf 'FAIL lost-token total missing from the fleet history command\n' >&2; exit 1; }

printf '{"token_cap_total":250,"expires_at":%s,"repos":[]}\n' "$(( now + 3600 ))" > "$controller/drain.json"
aggregate
drain_frame="$fixture/drain.txt"; render_ascii 120 "$drain_frame"
grep -q 'DRAIN cap 250, expires' "$drain_frame"
assert_jq '.drain.active == true and .drain.cap == 250 and
  .drain_active == true and .drain_cap == 250 and .drain_expires_at != null' \
  'active drain missing from data'
printf '{"token_cap_total":250,"expires_at":%s,"repos":[]}\n' "$(( now - 1 ))" > "$controller/drain.json"
aggregate
expired_frame="$fixture/expired.txt"; render_ascii 120 "$expired_frame"
if grep -q '^DRAIN cap' "$expired_frame"; then printf 'FAIL expired drain still rendered\n' >&2; exit 1; fi

jq '.halted=false | .halt_reason=null' "$fixture/halted/state/budget.json" > "$fixture/halted/state/budget.next"
mv "$fixture/halted/state/budget.next" "$fixture/halted/state/budget.json"
aggregate
cleared_frame="$fixture/cleared.txt"; render_ascii 120 "$cleared_frame"
if grep -q 'HALTED' "$cleared_frame"; then
  printf 'FAIL cleared halt condition still rendered\n' >&2
  exit 1
fi

grep -q 'window.AUTOMETTA_DATA = ' "$controller/dashboard/data.js"
grep -q '<script src="data.js"></script>' "$repo_root/dashboard/index.html"
grep -q 'window.location.protocol === "file:"' "$repo_root/dashboard/dashboard.js"
json_compact="$(jq -c '.' "$controller/dashboard/data.json")"
js_compact="$(sed -e 's/^window.AUTOMETTA_DATA = //' -e 's/;$//' "$controller/dashboard/data.js")"
[[ "$json_compact" == "$js_compact" ]]

printf 'PASS fleet lights, agent/queue joins, fleet failures command, spend, drain, widths and file fallback\n'

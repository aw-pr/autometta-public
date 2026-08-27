#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Replay the 2026-08-25 worker sequence entirely offline: ordinary completed
# rows establish the baseline, then a live transcript reaches 45,758,708.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
agent_pid=""
cleanup() {
  if [[ -n "$agent_pid" ]] && kill -0 "$agent_pid" 2>/dev/null; then
    kill "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
  fi
  case "$fixture" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$fixture" ;; esac
}
trap cleanup EXIT

fail_count=0
check() {
  local label="$1" got="$2"
  if [[ "$got" == "ok" ]]; then
    printf '  PASS: %s\n' "$label"
  else
    printf '  FAIL: %s (got %q)\n' "$label" "$got"
    fail_count=$((fail_count + 1))
  fi
}

iso_at() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

now_epoch="$(date -u +%s)"
now_iso="$(iso_at "$now_epoch")"
controller="$fixture/controller"
target_repo="$fixture/replay-repo"
cold_repo="$fixture/cold-repo"
sessions="$fixture/codex-sessions"
mkdir -p "$controller/subscribers" "$controller/dashboard" \
  "$target_repo/state/active-agents" "$target_repo/state/recent-agents" \
  "$cold_repo/state/active-agents" "$cold_repo/state/recent-agents" \
  "$sessions/2026/08/25"

cat > "$target_repo/state/cost-log.jsonl" <<'EOF'
{"stage_id":"ordinary-1","role":"worker","total_tokens":1824717,"usage_status":"recorded"}
{"stage_id":"ordinary-2","role":"worker","total_tokens":1900000,"usage_status":"recorded"}
{"stage_id":"unknown","role":"worker","total_tokens":null,"usage_status":"unknown"}
{"stage_id":"ordinary-3","role":"worker","total_tokens":1700000,"usage_status":"recorded"}
{"stage_id":"null-recorded","role":"worker","total_tokens":null,"usage_status":"recorded"}
{"stage_id":"ordinary-4","role":"worker","total_tokens":1824717,"usage_status":"total_only"}
{"stage_id":"other-role","role":"verifier","total_tokens":1,"usage_status":"recorded"}
{"stage_id":"ordinary-5","role":"worker","total_tokens":2804011,"usage_status":"recorded"}
{"stage_id":"ordinary-6","role":"worker","total_tokens":1824717,"usage_status":"recorded"}
EOF

cat > "$target_repo/state/state.yaml" <<EOF
version: 1
current_stage: 63-one-ticker-per-repo-that-fits-its-pane
last_tick_at: "$now_iso"
stages:
  - id: 63-one-ticker-per-repo-that-fits-its-pane
    status: in_progress
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    started_at: "$now_iso"
EOF
cat > "$target_repo/state/budget.json" <<'EOF'
{"tokens_spent":0,"token_cap_total":150000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF

transcript="$sessions/2026/08/25/rollout-replay.jsonl"
cat > "$transcript" <<EOF
{"type":"session_meta","payload":{"cwd":"$target_repo","timestamp":"$now_iso"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":45000000,"cached_input_tokens":44000000,"output_tokens":758708,"total_tokens":45758708}}}}
EOF

sleep 6 &
agent_pid=$!
cat > "$target_repo/state/active-agents/$agent_pid.json" <<EOF
{"pid":$agent_pid,"family":"codex","role":"worker","identity":"Claude Sonnet 5 <claude-sonnet-5@local>","stage_id":"63-one-ticker-per-repo-that-fits-its-pane","card_path":"63-one-ticker-per-repo-that-fits-its-pane.md","log_path":"$target_repo/worker.log","started_at":"$now_iso","budget_seconds":3600,"working_dir":"$target_repo"}
EOF
: > "$target_repo/worker.log"

printf 'repo_path: "%s"\nenabled: true\n' "$target_repo" \
  > "$controller/subscribers/replay-repo.yaml"
export PHAT_CONTROLLER_HOME="$controller"
export AUTOMETTA_CODEX_TRANSCRIPT_ROOTS="$sessions"

printf '== live outlier ==\n'
warning="$({ "$script_dir/heartbeat.sh" "$target_repo"; } 2>&1)"
report="$target_repo/state/heartbeat.json"
check "warning fires during the live third dispatch" \
  "$([[ "$warning" == *"WARNING: token outlier"* ]] && printf ok || printf missing)"
check "warning names the exact live figure and roughly 25x multiple" \
  "$([[ "$warning" == *"live_tokens=45758708"* && "$warning" == *"multiple=25.1x"* ]] && printf ok || printf '%s' "$warning")"
check "heartbeat names the live agent and carries the outlier flag" \
  "$(jq -r --argjson pid "$agent_pid" 'if any(.entries[]; .pid == $pid and .alive == true and (.flags | index("token-outlier"))) then "ok" else "missing" end' "$report")"
check "baseline is per-role and remains the ordinary worker median" \
  "$(jq -r 'if .baselines.worker.median_tokens == 1824717 and .baselines.worker.comparable_rows == 6 and .baselines.verifier.comparable_rows == 1 then "ok" else (.baselines|tostring) end' "$report")"
check "unknown and null-total rows are excluded rather than zeroed" \
  "$(jq -r 'if .baselines.worker.comparable_rows == 6 and .baselines.worker.median_tokens == 1824717 then "ok" else "changed" end' "$report")"
check "the watchdog takes no action and the agent remains alive" \
  "$(kill -0 "$agent_pid" 2>/dev/null && jq -r 'if .halted == false then "ok" else "halted" end' "$target_repo/state/budget.json" || printf killed)"

printf '\n== operator surfaces ==\n'
frame="$(NO_COLOR=1 AUTOMETTA_TICKER_COLUMNS=180 AUTOMETTA_TICKER_ROWS=40 \
  "$script_dir/repo-ticker.sh" "$target_repo" --once)"
escalations="$(printf '%s\n' "$frame" | sed -n '/^ESCALATIONS/,/^$/p')"
check "repo ticker ESCALATIONS carries the live warning" \
  "$([[ "$escalations" == *"OUTLIER"* && "$escalations" == *"63-one-ticker"* ]] && printf ok || printf '%s' "$escalations")"
check "ticker names the figure, multiple and role baseline" \
  "$([[ "$escalations" == *"45.8M"* && "$escalations" == *"25.1x worker median"* ]] && printf ok || printf '%s' "$escalations")"
check "tick routes heartbeat warning text through its existing logger" \
  "$({ grep -q 'heartbeat_output=.*heartbeat.sh' "$script_dir/tick.sh" && grep -q 'log "heartbeat: \$heartbeat_line"' "$script_dir/tick.sh"; } && printf ok || printf missing)"

printf '\n== cold start ==\n'
head -n 4 "$target_repo/state/cost-log.jsonl" > "$cold_repo/state/cost-log.jsonl"
cold_transcript="$sessions/2026/08/25/rollout-cold.jsonl"
cat > "$cold_transcript" <<EOF
{"type":"session_meta","payload":{"cwd":"$cold_repo","timestamp":"$now_iso"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":45000000,"cached_input_tokens":44000000,"output_tokens":758708,"total_tokens":45758708}}}}
EOF
cat > "$cold_repo/state/active-agents/$agent_pid.json" <<EOF
{"pid":$agent_pid,"family":"codex","role":"worker","stage_id":"cold","card_path":"cold.md","started_at":"$now_iso","budget_seconds":3600,"working_dir":"$cold_repo"}
EOF
cold_warning="$({ "$script_dir/heartbeat.sh" "$cold_repo"; } 2>&1)"
check "fewer than five comparable rows emits no warning" \
  "$([[ -z "$cold_warning" ]] && printf ok || printf '%s' "$cold_warning")"
check "cold-start report records no baseline and no outlier flag" \
  "$(jq -r 'if .baselines.worker.comparable_rows == 3 and .baselines.worker.median_tokens == null and all(.entries[]; (.flags | index("token-outlier")) == null) then "ok" else "warned" end' "$cold_repo/state/heartbeat.json")"

wait "$agent_pid"
agent_pid=""
check "the warned agent runs to natural completion" "ok"

if ((fail_count > 0)); then
  printf '\nFAIL outlier-warning smoke: %d assertion(s) failed\n' "$fail_count"
  exit 1
fi
printf '\nPASS outlier warning: live 25x signal, cold-start silence, excluded rows, no action, ticker and tick-log surfaces\n'

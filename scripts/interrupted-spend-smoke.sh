#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/176-interrupted-dispatch-spend.md
if [[ $# == 0 ]]; then
  rc=0
  for role in worker verifier; do bash "$0" "$role" || rc=1; done
  exit "$rc"
fi
role="$1"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export AUTOMETTA_HOME="$tmp/host" AUTOMETTA_NOTIFY=0 AUTOMETTA_CODEX_TRANSCRIPT_ROOTS="$tmp/transcripts"
export GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$AUTOMETTA_HOME/log" "$AUTOMETTA_CODEX_TRANSCRIPT_ROOTS"
source "$root/scripts/tick.sh"
quota_write_repo_state() { :; }
budget_ensure_window() { :; }
budget_check_caps() { :; }
commit_state_branch() { :; }
pipeline_prepare_tail_rebase() { :; }
quota_gate_role_dispatch() { return 1; }
network_preflight_ok() { return 1; }
stage=01-interrupted
repo="$tmp/repo"
git init -q -b dev "$repo"
cd "$repo"
mkdir -p stage-cards state/{envelopes,logs,verifiers}
printf 'state/\n' > .gitignore
printf '# Fixture\n\n## Budget\n\n- **Worker wall-clock:** 60 minutes\n- **Verifier wall-clock:** 20 minutes\n' > "stage-cards/$stage.md"
git add .gitignore stage-cards
git -c user.name=fixture -c user.email=fixture@local -c core.hooksPath=/dev/null commit -qm fixture
printf '{"version":1,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3,"token_cap_total":5000000,"tokens_spent":10,"lifetime_tokens_spent":20,"wall_clock_cap_seconds":864000,"wall_clock_elapsed_seconds":0,"clock_tick_cap":10000,"clock_ticks_used":1}\n' > state/budget.json
start="$(date -u -v-15S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '15 seconds ago' '+%Y-%m-%dT%H:%M:%SZ')"
cat > state/state.yaml <<YAML
version: 1
current_stage: $stage
stages:
  - id: $stage
    status: in_progress
    base_branch: dev
    worker: "Claude Opus 5.5 <claude-opus-5-5@local>"
    verifier: "GPT-6.2 Astra <gpt-6-2-astra@local>"
    started_at: "$start"
    ${role}_pid: 99999999
    verifier_attempts: 1
YAML
work="$(ensure_run_worktree "$repo" "$stage" dev)"
if [[ "$role" == worker ]]; then
  expected=410797
  printf 'Total tokens: 410797\nYou\047ve hit your session limit\n' > "state/logs/$stage-worker.log"
else
  expected=176459
  yq -i '.stages[0].verifier_started_at = .stages[0].started_at' state/state.yaml
  printf '{"stage_id":"%s","status":"pass","deliverables":[],"notes":"complete"}\n' "$stage" > "state/envelopes/$stage.json"
  echo 'aborted' > "state/logs/$stage-verifier.log"
  jq -nc --arg cwd "$work" --arg ts "$start" '{type:"session_meta",payload:{cwd:$cwd,timestamp:$ts}}' > "$tmp/transcripts/attempt.jsonl"
  cat >> "$tmp/transcripts/attempt.jsonl" <<'JSON'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120000,"cached_input_tokens":90000,"output_tokens":712,"total_tokens":120712}}}}
{"type":"token_usage_record","payload":{"usage":{"input_tokens":55400,"cached_input_tokens":44544,"output_tokens":347},"thread_token_usage":{"input_tokens":175588,"cached_input_tokens":133120,"output_tokens":871,"total_tokens":176459}}}
JSON
fi
if [[ "$role" == verifier ]]; then
  jq -c 'if .type=="session_meta" then .payload.timestamp="2000-01-01T00:00:00Z" else . end' "$tmp/transcripts/attempt.jsonl" > "$tmp/transcripts/previous.jsonl"
  jq -c 'if .type=="session_meta" then .payload.cwd="/other-fixture" else . end' "$tmp/transcripts/attempt.jsonl" > "$tmp/transcripts/other.jsonl"
fi
cp state/budget.json "$tmp/before-budget"
cp state/state.yaml "$tmp/before.yaml"
for pass in initial replay budget-only cost-only; do
  if [[ "$pass" != initial ]]; then
    # Recover each half-written arrangement using the same dispatch identity.
    case "$pass" in
      budget-only) : > state/cost-log.jsonl ;;
      cost-only) cp "$tmp/before-budget" state/budget.json ;;
    esac
    # Replay the same dead dispatch, including its original start and pid.
    cp "$tmp/before.yaml" state/state.yaml
    jq 'del(.paused_until,.paused_reason)' state/budget.json > "$tmp/budget"
    mv "$tmp/budget" state/budget.json
  fi
  _process_repo_locked "$repo" ""
  jq -e --argjson n "$expected" '.tokens_spent == 10+$n and .lifetime_tokens_spent == 20+$n' state/budget.json >/dev/null || {
    echo "FAIL: $role pass $pass expected a single charge of $expected, observed $(jq .tokens_spent state/budget.json)" >&2; exit 1; }
  jq -se --arg role "$role" --argjson n "$expected" '[.[]|select(.role==$role)]|length==1 and .[0].total_tokens==$n' state/cost-log.jsonl >/dev/null
  if [[ "$role" == worker ]]; then
    [[ "$(yq -r '.stages[0].status' state/state.yaml)" == pending ]]
    jq -e '.paused_until > 0 and .consecutive_failures == 0' state/budget.json >/dev/null
  else
    jq -se 'any(.[]; .role=="verifier" and .result=="aborted" and .cached_input_tokens==133120)' state/cost-log.jsonl >/dev/null
  fi
done
if [[ "$role" == worker ]]; then
  cp "$tmp/before.yaml" state/state.yaml
  yq -i '.stages[0].worker_pid = 99999998' state/state.yaml
  jq 'del(.paused_until,.paused_reason)' state/budget.json > "$tmp/budget"
  mv "$tmp/budget" state/budget.json
  printf 'Total tokens: 23\nYou\047ve hit your session limit\n' > "state/logs/$stage-worker.log"
  _process_repo_locked "$repo" ""
  jq -e '.tokens_spent == 410830 and .lifetime_tokens_spent == 410840' state/budget.json >/dev/null
  jq -se '[.[]|select(.role=="worker")|.total_tokens]|sort==[23,410797]' state/cost-log.jsonl >/dev/null
  for amount in 0 unknown; do
    cp "$tmp/before.yaml" state/state.yaml
    if [[ "$amount" == 0 ]]; then pid=99999997; else pid=99999996; fi
    yq -i ".stages[0].worker_pid = $pid" state/state.yaml
    jq 'del(.paused_until,.paused_reason)' state/budget.json > "$tmp/budget"
    mv "$tmp/budget" state/budget.json
    log_file="state/logs/$stage-worker.log"
    : > "$log_file"
    [[ "$amount" != 0 ]] || echo 'Total tokens: 0' >> "$log_file"
    printf "You've hit your session limit\n" >> "$log_file"
    _process_repo_locked "$repo" ""
  done
  jq -e '.tokens_spent == 410830 and .lifetime_tokens_spent == 410840' state/budget.json >/dev/null
  jq -se '[.[]|select(.role=="worker")]| length==4 and any(.[];.total_tokens==0) and any(.[];.total_tokens==null and .usage_status=="unknown")' state/cost-log.jsonl >/dev/null
fi
# AUTOMETTA-CONTRACT-END

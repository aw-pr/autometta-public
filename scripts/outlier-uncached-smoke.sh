#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Offline replay of the heartbeat's token-outlier judgement. Each case is its
# own fixture repo with a live placeholder pid and a Codex transcript, so a
# kill in one case cannot leak into another. No network, no agent, no spend.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
pids=()
cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  case "$fixture" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$fixture" ;; esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: 164-the-outlier-kill-ignores-cache-reads: %s\n' "$1"
  exit 1
}

iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sessions="$fixture/codex-sessions"
mkdir -p "$fixture/controller/subscribers" "$sessions/2026/10/23"
export PHAT_CONTROLLER_HOME="$fixture/controller"
export AUTOMETTA_HOME="$fixture/controller"
export AUTOMETTA_CODEX_TRANSCRIPT_ROOTS="$sessions"
unset AUTOMETTA_OUTLIER_KILL_MULTIPLE AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE \
  AUTOMETTA_OUTLIER_MULTIPLE AUTOMETTA_OUTLIER_BASELINE_WINDOW AUTOMETTA_OUTLIER_MIN_SAMPLES

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/164-the-outlier-kill-ignores-cache-reads.md

# Ten recorded worker rows. Uncached (input + output) median 71,000; total
# median 840,000. Card 162's attempt 1 sat at about 16x total and 4x uncached.
split_rows() {
  local u t
  local -a uncached=(60000 65000 68000 70000 70000 72000 74000 80000 90000 100000)
  local -a totals=(700000 750000 800000 830000 840000 840000 850000 900000 950000 1000000)
  local i
  for i in 0 1 2 3 4 5 6 7 8 9; do
    u="${uncached[$i]}"; t="${totals[$i]}"
    printf '{"stage_id":"row-%s","role":"worker","input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s,"total_tokens":%s,"usage_status":"recorded"}\n' \
      "$i" "$((u - 5000))" "$((t - u))" 5000 "$t"
  done
}

# The same totals with no input/output split: the uncached baseline has no
# comparable rows, so judgement falls back to the total measure.
total_only_rows() {
  local t
  for t in 700000 750000 800000 830000 840000 840000 850000 900000 950000 1000000; do
    printf '{"stage_id":"legacy","role":"worker","total_tokens":%s,"usage_status":"recorded"}\n' "$t"
  done
}

# make_case <name> <rows-fn> <uncached-input> <cached> <output>
# The transcript's input_tokens includes the cached share, as Codex reports it.
make_case() {
  local name="$1" rows="$2" input="$3" cached="$4" output="$5"
  local repo="$fixture/$name"
  mkdir -p "$repo/state/active-agents" "$repo/state/recent-agents"
  "$rows" > "$repo/state/cost-log.jsonl"
  printf '{"tokens_spent":0,"token_cap_total":1000000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}\n' \
    > "$repo/state/budget.json"
  cat > "$sessions/2026/10/23/rollout-$name.jsonl" <<EOF
{"type":"session_meta","payload":{"cwd":"$repo","timestamp":"$iso_now"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":$((input + cached)),"cached_input_tokens":$cached,"output_tokens":$output,"total_tokens":$((input + cached + output))}}}}
EOF
  sleep 60 >/dev/null 2>&1 &
  case_pid=$!
  pids+=("$case_pid")
  local pid="$case_pid"
  : > "$repo/worker.log"
  printf '{"pid":%s,"family":"codex","role":"worker","identity":"GPT-6.1 Sol <gpt-6-1-sol@local>","stage_id":"%s","card_path":"%s.md","log_path":"%s/worker.log","started_at":"%s","budget_seconds":3600,"working_dir":"%s"}\n' \
    "$pid" "$name" "$name" "$repo" "$iso_now" "$repo" > "$repo/state/active-agents/$pid.json"
}

alive() { kill -0 "$1" 2>/dev/null; }

recorded_measure() {
  jq -r '[.entries[] | select(.outcome == "killed-token-outlier") | .token_outlier.measure] | first // "none"' \
    "$1/state/heartbeat.json" 2>/dev/null || printf none
}

# 1. Card 162's attempt: 236,156 input, 13,438,000 cached, 50,419 output.
make_case replay-162 split_rows 236156 13438000 50419; pid="$case_pid"
out="$("$script_dir/heartbeat.sh" "$fixture/replay-162" 2>&1)" || true
alive "$pid" || fail "card 162 replay was killed; cache reads must not count (output: $out)"
[[ "$out" != *"token outlier"* ]] || fail "card 162 replay warned at 4x uncached: $out"
jq -e --argjson pid "$pid" 'any(.entries[]; .pid == $pid and .live_uncached_tokens == 286575)' \
  "$fixture/replay-162/state/heartbeat.json" >/dev/null \
  || fail "heartbeat report lacks live_uncached_tokens 286575 for the replay"
jq -e --argjson pid "$pid" 'any(.entries[]; .pid == $pid and .baseline_median_uncached_tokens == 71000)' \
  "$fixture/replay-162/state/heartbeat.json" >/dev/null \
  || fail "heartbeat report lacks baseline_median_uncached_tokens 71000"
jq -e '.tokens_spent == 0' "$fixture/replay-162/state/budget.json" >/dev/null \
  || fail "heartbeat changed budget accounting"

# 2. Uncached runaway with little cache: 1,136,000 uncached (16x), 1.9x total.
make_case uncached-runaway split_rows 1100000 500000 36000; pid="$case_pid"
out="$("$script_dir/heartbeat.sh" "$fixture/uncached-runaway" 2>&1)" || true
sleep 1
alive "$pid" && fail "16x uncached dispatch was not killed (output: $out)"
[[ "$out" == *"KILLED: token outlier"* ]] || fail "uncached kill printed no KILLED line: $out"
[[ "$(recorded_measure "$fixture/uncached-runaway")" == "uncached" ]] \
  || fail "uncached kill did not record token_outlier.measure uncached"

# 3. AUTOMETTA_OUTLIER_KILL_MULTIPLE=0 still disables the kill and leaves the warning.
make_case uncached-observe split_rows 1100000 500000 36000; pid="$case_pid"
out="$(AUTOMETTA_OUTLIER_KILL_MULTIPLE=0 "$script_dir/heartbeat.sh" "$fixture/uncached-observe" 2>&1)" || true
alive "$pid" || fail "kill multiple 0 no longer disables the uncached kill"
[[ "$out" == *"WARNING: token outlier"* ]] || fail "kill multiple 0 suppressed the uncached warning: $out"

# 4. Total backstop: 300,000 uncached (4.2x) but 34,440,000 total (41x).
make_case total-backstop split_rows 280000 34140000 20000; pid="$case_pid"
out="$("$script_dir/heartbeat.sh" "$fixture/total-backstop" 2>&1)" || true
sleep 1
alive "$pid" && fail "41x total dispatch survived the 40x backstop (output: $out)"
[[ "$(recorded_measure "$fixture/total-backstop")" == "total" ]] \
  || fail "backstop kill did not record token_outlier.measure total"

# 5. AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE=0 disables the backstop.
make_case total-disabled split_rows 280000 34140000 20000; pid="$case_pid"
out="$(AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE=0 "$script_dir/heartbeat.sh" "$fixture/total-disabled" 2>&1)" || true
alive "$pid" || fail "backstop multiple 0 still killed a 4x-uncached dispatch (output: $out)"

# 6. No split rows: fall back to the total measure at the existing 15x kill.
make_case total-fallback total_only_rows 236156 13438000 50419; pid="$case_pid"
out="$("$script_dir/heartbeat.sh" "$fixture/total-fallback" 2>&1)" || true
sleep 1
alive "$pid" && fail "without split rows a 16x total dispatch was not killed (output: $out)"

# 7. The documentation names both variables.
grep -q 'AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE' "$script_dir/../docs/observability.md" \
  || fail "docs/observability.md does not document AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE"
grep -qi 'uncached' "$script_dir/../docs/observability.md" \
  || fail "docs/observability.md does not describe the uncached measure"

# AUTOMETTA-CONTRACT-END

printf 'PASS outlier uncached: cache reads ignored, uncached kill, 40x total backstop, legacy fallback\n'

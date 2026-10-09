#!/usr/bin/env bash
# Offline proof for stage card 145: a claude dispatch streams its log.
#
# Drives the stdout filter with a synthetic stream-json session shaped like
# the one `claude -p --output-format stream-json --verbose` printed on
# 2026-10-09, then the registry writer and the heartbeat against a fixture
# repo. No auth, no network, no token spend, no real claude process.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
pids=()
cleanup() {
  local pid
  for pid in "${pids[@]+"${pids[@]}"}"; do kill "$pid" 2>/dev/null || true; done
  case "$tmp" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$tmp" ;; esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

set_mtime() {
  python3 - "$1" "$2" <<'PY'
import os, sys
stamp = int(sys.argv[2])
os.utime(sys.argv[1], (stamp, stamp))
PY
}

now_epoch="$(date -u +%s)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
filter="$script_dir/claude-token-log.sh"

# One line per message, the result last, cumulative usage on the result.
init_line='{"type":"system","subtype":"init","cwd":"/tmp/smoke","session_id":"smoke","tools":["Bash"],"model":"claude-smoke"}'
tool_line='{"type":"assistant","message":{"model":"claude-smoke","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"bash scripts/example-smoke.sh","description":"Run the smoke"}}],"stop_reason":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":40}},"parent_tool_use_id":null,"session_id":"smoke","uuid":"u1"}'
tool_result_line='{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"PASS","is_error":false}]},"parent_tool_use_id":null,"session_id":"smoke","uuid":"u2"}'
final_line='{"type":"result","subtype":"success","is_error":false,"duration_ms":1500,"duration_api_ms":1400,"num_turns":2,"result":"smoke finished cleanly","stop_reason":"end_turn","session_id":"smoke","total_cost_usd":0.01,"usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":634},"uuid":"u3"}'
build_check='{"status":"current","stale":false,"installed_sha":null,"checkout_sha":null,"checked_at":"'"$now_iso"'"}'

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/145-a-claude-dispatch-streams-its-log.md
# 1. Progress is forwarded as it arrives, not at exit: a tool call written
#    to the filter's stdin is readable in the log while the session is still
#    running. That is the whole card.
streamed="$tmp/streamed.log"
{
  printf '%s\n' "$init_line" "$tool_line" "$tool_result_line"
  sleep 4
  printf '%s\n' "$final_line"
} | "$filter" > "$streamed" &
filter_job=$!
pids+=("$filter_job")
sleep 2
grep -q 'Bash' "$streamed" \
  || fail "145: nothing about the Bash call reached the log before the session ended"
wait "$filter_job"
# 2. The settled tail keeps the contract the budget parser already reads:
#    the result text, then exactly one "Total tokens: N" line summing all
#    four usage buckets of the result message.
grep -q 'smoke finished cleanly' "$streamed" \
  || fail "145: the result text is missing from the log"
[[ "$(grep -c '^Total tokens: 1234$' "$streamed")" == "1" ]] \
  || fail "145: expected exactly one 'Total tokens: 1234' line, got: $(grep 'Total tokens' "$streamed" | tr '\n' '|')"
# 3. Non-JSON input passes through byte for byte, so a CLI error such as
#    "Not logged in" is never swallowed.
[[ "$(printf 'Not logged in. Please run /login\n' | "$filter")" == 'Not logged in. Please run /login' ]] \
  || fail "145: a non-JSON line did not pass through unchanged"
# 4. A single --output-format json document, which phat-controller still
#    emits, keeps yielding the same tail.
single="$(printf '{"type":"result","subtype":"success","result":"one shot","usage":{"input_tokens":1,"output_tokens":2}}\n' | "$filter")"
[[ "$single" == *'one shot'* && "$single" == *'Total tokens: 3'* ]] \
  || fail "145: the single-document json format no longer yields its total"
# 5. Every claude dispatch line in the spawn scripts asks for the stream,
#    and print mode only grants it alongside --verbose.
for spawn in spawn-worker.sh spawn-verifier.sh; do
  grep -Eq -- '--output-format stream-json' "$script_dir/$spawn" \
    || fail "145: $spawn does not dispatch claude with --output-format stream-json"
  grep -Eq -- '--verbose' "$script_dir/$spawn" \
    || fail "145: $spawn omits --verbose, which print mode requires for stream-json"
  if grep -Eq -- '--output-format json([^-]|$)' "$script_dir/$spawn"; then
    fail "145: $spawn still carries a one-burst --output-format json dispatch"
  fi
done
# 6. The registry records whether a dispatch streams its log, so silence is
#    judged per dispatch rather than per family.
repo="$tmp/repo"
mkdir -p "$repo/state/active-agents" "$repo/state/recent-agents" "$repo/state/logs"
sleep 60 & streaming_pid=$!; pids+=("$streaming_pid")
sleep 60 & legacy_pid=$!; pids+=("$legacy_pid")
sleep 60 & codex_pid=$!; pids+=("$codex_pid")
AUTOMETTA_LOG_STREAMS=1 "$script_dir/register-agent.sh" "$repo" "$streaming_pid" worker claude \
  "Claude Smoke <claude-smoke@local>" "cards/a.md" "$repo/state/logs/a.log" 600 "$repo" >/dev/null
"$script_dir/register-agent.sh" "$repo" "$legacy_pid" worker claude \
  "Claude Smoke <claude-smoke@local>" "cards/b.md" "$repo/state/logs/b.log" 600 "$repo" >/dev/null
"$script_dir/register-agent.sh" "$repo" "$codex_pid" worker codex \
  "Codex Smoke <codex-smoke@local>" "cards/c.md" "$repo/state/logs/c.log" 600 "$repo" >/dev/null
[[ "$(jq -r '.log_streams' "$repo/state/active-agents/$streaming_pid.json")" == "true" ]] \
  || fail "145: AUTOMETTA_LOG_STREAMS=1 did not record log_streams: true"
[[ "$(jq -r '.log_streams // "absent"' "$repo/state/active-agents/$legacy_pid.json")" == "absent" ]] \
  || fail "145: a registration without the flag must not carry log_streams"
# 7. The heartbeat flags a streaming claude log that has stopped growing,
#    leaves a one-burst claude log alone, and treats codex exactly as before.
for log in a b c; do
  : > "$repo/state/logs/$log.log"
  set_mtime "$repo/state/logs/$log.log" "$((now_epoch - 900))"
done
AUTOMETTA_BUILD_CHECK_JSON="$build_check" AUTOMETTA_HEARTBEAT_STALL=300 \
  "$script_dir/heartbeat.sh" "$repo" >/dev/null 2>&1
flags_of() {
  jq -r --argjson pid "$1" '[.entries[] | select(.pid == $pid) | .flags[]] | join(",")' "$repo/state/heartbeat.json"
}
[[ "$(flags_of "$streaming_pid")" == *silent* ]] \
  || fail "145: a stale streaming claude log was not flagged silent (flags: $(flags_of "$streaming_pid"))"
[[ "$(flags_of "$legacy_pid")" != *silent* ]] \
  || fail "145: a one-burst claude log must stay exempt from silent"
[[ "$(flags_of "$codex_pid")" == *silent* ]] \
  || fail "145: the codex silent rule regressed (flags: $(flags_of "$codex_pid"))"
# AUTOMETTA-CONTRACT-END

printf 'log-streams-smoke: PASS\n'

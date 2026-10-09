#!/usr/bin/env bash
# Offline proof for stage card 146: the agents panel says what the agent is
# doing.
#
# Fixture transcripts are shaped like the real ones read on 2026-10-09: a
# Claude Code project transcript (assistant records carrying tool_use blocks)
# and a Codex rollout (custom_tool_call and function_call response items,
# token_count events). The reader, the renderer, the dashboard source and the
# aggregator seam are each driven directly. No auth, no network, no token
# spend, no real agent process.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp="$(mktemp -d)"
agent_pid=""
cleanup() {
  [[ -z "$agent_pid" ]] || kill "$agent_pid" 2>/dev/null || true
  case "$tmp" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$tmp" ;; esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

iso_at() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

now_epoch="$(date -u +%s)"
now_iso="$(iso_at "$now_epoch")"
started_iso="$(iso_at "$((now_epoch - 300))")"
t_text="$(iso_at "$((now_epoch - 120))")"
t_bash="$(iso_at "$((now_epoch - 100))")"
t_read="$(iso_at "$((now_epoch - 40))")"
t_late="$(iso_at "$((now_epoch - 5))")"
t_exec="$(iso_at "$((now_epoch - 30))")"
t_shell="$(iso_at "$((now_epoch - 20))")"

claude_root="$tmp/claude-projects"
codex_root="$tmp/codex-sessions"
claude_work="$tmp/claude-work"
codex_work="$tmp/codex-work"
mkdir -p "$claude_work" "$codex_work" "$codex_root/2026/10/09"
claude_slug="$(printf '%s' "$claude_work" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
mkdir -p "$claude_root/$claude_slug"
claude_transcript="$claude_root/$claude_slug/session.jsonl"
codex_transcript="$codex_root/2026/10/09/rollout-2026-10-09T10-00-00-smoke.jsonl"

usage='"usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"output_tokens":10}'
cat > "$claude_transcript" <<EOF
{"type":"assistant","timestamp":"$t_text","requestId":"req_1","uuid":"u1","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Reading the card."}],$usage}}
{"type":"assistant","timestamp":"$t_bash","requestId":"req_2","uuid":"u2","message":{"id":"msg_2","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"bash scripts/example-smoke.sh --all","description":"Run the smoke"}}],$usage}}
{"type":"user","timestamp":"$t_bash","uuid":"u3","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"PASS","is_error":false}]}}
{"type":"assistant","timestamp":"$t_read","requestId":"req_3","uuid":"u4","message":{"id":"msg_3","role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"docs/observability.md"}}],$usage}}
{"type":"user","timestamp":"$t_read","uuid":"u5","message":{"role":"user","content":[{"tool_use_id":"toolu_2","type":"tool_result","content":"# Observability","is_error":false}]}}
EOF

cat > "$codex_transcript" <<EOF
{"timestamp":"$started_iso","type":"session_meta","payload":{"id":"smoke-thread","timestamp":"$started_iso","cwd":"$codex_work"}}
{"timestamp":"$started_iso","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"$t_text","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":1050},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":1050}}}}
{"timestamp":"$t_exec","ordinal":4,"type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_1","status":"completed","call_id":"call_1","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"rg -n smoke docs\",\"workdir\":\"$codex_work\"}); return r;"}}
{"timestamp":"$t_exec","ordinal":5,"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_1","output":"docs/a.md:1:smoke"}}
{"timestamp":"$t_shell","ordinal":6,"type":"response_item","payload":{"type":"function_call","id":"fc_1","status":"completed","call_id":"call_2","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"ls docs\"]}"}}
{"timestamp":"$t_shell","ordinal":7,"type":"response_item","payload":{"type":"function_call_output","call_id":"call_2","output":"a.md"}}
{"timestamp":"$t_shell","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":900,"cache_write_input_tokens":0,"output_tokens":120,"reasoning_output_tokens":0,"total_tokens":2120},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":700,"cache_write_input_tokens":0,"output_tokens":70,"reasoning_output_tokens":0,"total_tokens":1070}}}}
{"timestamp":"$t_shell","ordinal":9,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Found it."}]}}
EOF

reader="$script_dir/lib/transcript-tokens.py"
registry="$tmp/registry"
mkdir -p "$registry"
agents_json="$(jq -nc --arg cw "$claude_work" --arg xw "$codex_work" --arg started "$started_iso" '[
  {pid: 4001, family: "claude", role: "worker", working_dir: $cw, started_at: $started, elapsed_seconds: 300},
  {pid: 4002, family: "codex", role: "verifier", working_dir: $xw, started_at: $started, elapsed_seconds: 300}
]')"
read_activity() {
  python3 "$reader" "$registry" "$claude_root" "$codex_root" <<<"$agents_json"
}
field() {
  printf '%s' "$1" | jq -r --argjson pid "$2" ".[] | select(.pid == \$pid) | $3"
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/146-the-agents-panel-says-what-the-agent-is-doing.md
# 1. The reader derives an activity object per live agent from the transcript
#    it already reads for tokens: turns taken, tool calls made, the last tool
#    and what it was pointed at, and when. Same reader, both families.
first="$(read_activity)" || fail "146: the reader exited non-zero"
[[ "$(field "$first" 4001 '.activity.turns')" == "3" ]] \
  || fail "146: claude turns should count assistant records (want 3, got $(field "$first" 4001 '.activity.turns'))"
[[ "$(field "$first" 4001 '.activity.tool_calls')" == "2" ]] \
  || fail "146: claude tool_calls should count tool_use blocks (want 2)"
[[ "$(field "$first" 4001 '.activity.last_tool')" == "Read" ]] \
  || fail "146: claude last_tool should be the latest tool_use name (want Read)"
[[ "$(field "$first" 4001 '.activity.last_detail')" == *docs/observability.md* ]] \
  || fail "146: claude last_detail should name the file a Read was pointed at"
[[ "$(field "$first" 4001 '.activity.last_at')" == "$t_read" ]] \
  || fail "146: claude last_at should be the timestamp of the latest tool call"
[[ "$(field "$first" 4001 '.stage_tokens')" == "345" ]] \
  || fail "146: the token total must survive the change (want 345)"
[[ "$(field "$first" 4002 '.activity.turns')" == "2" ]] \
  || fail "146: codex turns should count token_count events (want 2)"
[[ "$(field "$first" 4002 '.activity.tool_calls')" == "2" ]] \
  || fail "146: codex tool_calls should count custom_tool_call and function_call items (want 2)"
[[ "$(field "$first" 4002 '.activity.last_tool')" == "shell" ]] \
  || fail "146: codex last_tool should be the latest call's name (want shell)"
[[ "$(field "$first" 4002 '.activity.last_detail')" == *"ls docs"* ]] \
  || fail "146: codex last_detail should surface the command inside the call arguments"
[[ "$(field "$first" 4002 '.activity.last_at')" == "$t_shell" ]] \
  || fail "146: codex last_at should be the latest call's timestamp"
[[ "$(field "$first" 4002 '.stage_tokens')" == "2120" ]] \
  || fail "146: the codex token total must survive the change (want 2120)"
# 2. Reading is incremental for claude, so counts must accumulate across
#    calls rather than restart from the cached offset.
cat >> "$claude_transcript" <<EOF
{"type":"assistant","timestamp":"$t_late","requestId":"req_4","uuid":"u6","message":{"id":"msg_4","role":"assistant","content":[{"type":"tool_use","id":"toolu_3","name":"Bash","input":{"command":"git status --short"}}],$usage}}
EOF
second="$(read_activity)" || fail "146: the second read exited non-zero"
[[ "$(field "$second" 4001 '.activity.turns')" == "4" ]] \
  || fail "146: turns did not accumulate across incremental reads (want 4, got $(field "$second" 4001 '.activity.turns'))"
[[ "$(field "$second" 4001 '.activity.tool_calls')" == "3" ]] \
  || fail "146: tool_calls did not accumulate across incremental reads (want 3)"
[[ "$(field "$second" 4001 '.activity.last_tool')" == "Bash" ]] \
  || fail "146: last_tool did not advance to the appended call"
[[ "$(field "$second" 4001 '.activity.last_detail')" == *"git status"* ]] \
  || fail "146: last_detail did not advance to the appended command"
[[ "$(field "$second" 4001 '.activity.last_at')" == "$t_late" ]] \
  || fail "146: last_at did not advance to the appended call"
# 3. An agent with no readable transcript carries a null activity, never a
#    zero that reads as an agent doing nothing.
missing="$(python3 "$reader" "$registry" "$claude_root" "$codex_root" <<<'[{"pid":4003,"family":"claude","role":"worker","working_dir":"/nowhere/at/all","started_at":"2026-10-09T00:00:00Z","elapsed_seconds":30}]')"
[[ "$(field "$missing" 4003 '.activity')" == "null" ]] \
  || fail "146: an unreadable transcript must yield activity: null"
# 4. The TUI agents panel shows the turn count, the tool and its age, and
#    renders an agent without activity without inventing a zero.
python3 - "$script_dir/lib/tui/render.py" "$now_epoch" "$(iso_at "$((now_epoch - 40))")" <<'PY' || fail "146: the agents panel does not show what the agent is doing"
import importlib.util, re, sys

spec = importlib.util.spec_from_file_location("autometta_tui_render", sys.argv[1])
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)
now = int(sys.argv[2])
last_at = sys.argv[3]
payload = {
    "_now": now,
    "agents": [
        {"pid": 1, "stage_id": "01-busy", "role": "worker", "family": "claude",
         "identity": "Claude Sonnet 5.5 <claude-sonnet-5-5@local>",
         "elapsed_seconds": 240, "budget_seconds": 2400, "live_total_tokens": 1234567,
         "activity": {"turns": 14, "tool_calls": 37, "last_tool": "Bash",
                      "last_detail": "bash scripts/example-smoke.sh", "last_at": last_at}},
        {"pid": 2, "stage_id": "02-quiet", "role": "verifier", "family": "codex",
         "identity": "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>",
         "elapsed_seconds": 30, "budget_seconds": 1500, "live_total_tokens": None,
         "activity": None},
    ],
    "current_run": {
        "id": "run-smoke", "started_at": "2026-10-09T08:00:00Z",
        "stages": [
            {"id": "01-busy", "status": "in_progress",
             "worker": "Claude Sonnet 5.5 <claude-sonnet-5-5@local>",
             "verifier": "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>",
             "started_at": "2026-10-09T08:00:00Z"},
        ],
    },
}
state = render.TuiState(5.0)
state.update(payload, observed_at=0.0)
state.observe_time(0.0)
frame = render.render(state, 180, 50).text()
problems = []
if "turn 14" not in frame:
    problems.append("no 'turn 14' for the busy agent")
if "Bash" not in frame:
    problems.append("the last tool name is not shown")
if not re.search(r"\b40s ago\b", frame):
    problems.append("the age of the last call is not shown as '40s ago'")
if "02-quiet" not in frame:
    problems.append("the agent without activity vanished from the panel")
if re.search(r"turn 0\b", frame):
    problems.append("an agent with no activity is shown as 'turn 0'")
if problems:
    sys.stderr.write("146: " + "; ".join(problems) + "\n")
    sys.exit(1)
PY
# 5. The web dashboard's agents table carries the same facts.
grep -q '"Activity"' "$repo_root/dashboard/dashboard.js" \
  || fail "146: dashboard.js has no Activity column in the agents table"
grep -q 'activity' "$repo_root/dashboard/dashboard.js" \
  || fail "146: dashboard.js never reads the activity object"
# 6. The aggregator seam carries activity for a live agent in --repo mode, so
#    the TUI and the ticker learn it at their own poll, not at the tick.
controller="$tmp/controller"
target_repo="$tmp/target-repo"
mkdir -p "$controller/subscribers" "$controller/dashboard" \
  "$target_repo/state/active-agents" "$target_repo/state/recent-agents"
sleep 60 &
agent_pid=$!
cat > "$target_repo/state/state.yaml" <<EOF
version: 1
current_stage: 01-busy
last_tick_at: "$now_iso"
stages:
  - id: 01-busy
    status: in_progress
    worker: "Claude Sonnet 5.5 <claude-sonnet-5-5@local>"
    verifier: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    started_at: "$started_iso"
EOF
printf '{"tokens_spent":0,"token_cap_total":150000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}\n' \
  > "$target_repo/state/budget.json"
: > "$target_repo/state/cost-log.jsonl"
: > "$target_repo/worker.log"
cat > "$target_repo/state/active-agents/$agent_pid.json" <<EOF
{"pid":$agent_pid,"family":"claude","role":"worker","identity":"Claude Sonnet 5.5 <claude-sonnet-5-5@local>","stage_id":"01-busy","card_path":"stage-cards/01-busy.md","log_path":"$target_repo/worker.log","started_at":"$started_iso","budget_seconds":2400,"working_dir":"$claude_work"}
EOF
printf 'repo_path: "%s"\nenabled: true\n' "$target_repo" > "$controller/subscribers/target-repo.yaml"
seam="$(PHAT_CONTROLLER_HOME="$controller" AUTOMETTA_CLAUDE_PROJECTS="$claude_root" \
  AUTOMETTA_CODEX_SESSIONS="$codex_root" "$script_dir/aggregate-dashboard.sh" --repo "$target_repo")" \
  || fail "146: aggregate-dashboard.sh --repo exited non-zero"
[[ "$(printf '%s' "$seam" | jq -r '.agents[0].activity.last_tool')" == "Bash" ]] \
  || fail "146: the --repo seam does not carry activity.last_tool for the live agent"
[[ "$(printf '%s' "$seam" | jq -r '.agents[0].activity.tool_calls')" == "3" ]] \
  || fail "146: the --repo seam does not carry activity.tool_calls"
# AUTOMETTA-CONTRACT-END

printf 'agent-activity-smoke: PASS\n'

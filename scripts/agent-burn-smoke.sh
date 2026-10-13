#!/usr/bin/env bash
# Offline proof for stage card 149: the dashboard draws the burn.
#
# Fixture transcripts follow the record shapes read on 2026-10-11. A Claude
# Code transcript writes one record per content block, and each record repeats
# the message's id and usage (the 123b worker transcript had 112 assistant
# records for 64 messages). A Codex rollout carries cumulative token_count
# events. The reader, the aggregator seam and the dashboard's burn cell are
# each driven directly. No auth, no network, no token spend, no real agent.
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
base=$(( (now_epoch / 60) * 60 - 600 ))
started_iso="$(iso_at "$((base - 60))")"
t1="$(iso_at "$((base + 10))")"
t2="$(iso_at "$((base + 70))")"
t3_ms="$(iso_at "$((base + 190))" | sed 's/Z$/.123Z/')"
t4="$(iso_at "$((base + 250))")"

claude_root="$tmp/claude-projects"
codex_root="$tmp/codex-sessions"
claude_work="$tmp/claude-work"
bulk_work="$tmp/bulk-work"
codex_work="$tmp/codex-work"
mkdir -p "$claude_work" "$bulk_work" "$codex_work" "$codex_root/2026/10/11"
slug_of() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-'; }
mkdir -p "$claude_root/$(slug_of "$claude_work")" "$claude_root/$(slug_of "$bulk_work")"
claude_transcript="$claude_root/$(slug_of "$claude_work")/session.jsonl"
bulk_transcript="$claude_root/$(slug_of "$bulk_work")/session.jsonl"
codex_transcript="$codex_root/2026/10/11/rollout-2026-10-11T10-00-00-smoke.jsonl"

# 1115 tokens per message, 1000 of them cache reads.
usage='"usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":10}'
assistant() { # timestamp message-id uuid content-json
  printf '{"type":"assistant","timestamp":"%s","uuid":"%s","message":{"id":"%s","role":"assistant","content":[%s],%s}}\n' \
    "$1" "$3" "$2" "$4" "$usage"
}
{
  assistant "$t1" msg_1 u1 '{"type":"text","text":"Reading the card."}'
  assistant "$t2" msg_2 u2 '{"type":"text","text":"Running the smoke."}'
  assistant "$t2" msg_2 u3 '{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"bash scripts/example-smoke.sh"}}'
  printf '{"type":"user","timestamp":"%s","uuid":"u4","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"PASS"}]}}\n' "$t2"
  assistant "$t3_ms" msg_3 u5 '{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"docs/dashboard.md"}}'
} > "$claude_transcript"

python3 - "$bulk_transcript" "$((now_epoch - 600 * 60))" <<'PY'
import datetime, json, sys
path, start = sys.argv[1], int(sys.argv[2])
usage = {"input_tokens": 5, "cache_creation_input_tokens": 100,
         "cache_read_input_tokens": 1000, "output_tokens": 10}
with open(path, "w") as fh:
    for i in range(600):
        stamp = datetime.datetime.fromtimestamp(start + i * 60, datetime.timezone.utc)
        fh.write(json.dumps({"type": "assistant", "timestamp": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
                             "uuid": "b%d" % i, "message": {"id": "bulk_%d" % i, "role": "assistant",
                             "content": [{"type": "text", "text": "."}], "usage": usage}}) + "\n")
PY

cat > "$codex_transcript" <<EOF
{"timestamp":"$started_iso","type":"session_meta","payload":{"id":"smoke-thread","timestamp":"$started_iso","cwd":"$codex_work"}}
{"timestamp":"$t1","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":1050}}}}
{"timestamp":"$(iso_at "$((base + 130))")","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":900,"output_tokens":120,"reasoning_output_tokens":0,"total_tokens":2120}}}}
EOF

reader="$script_dir/lib/transcript-tokens.py"
registry="$tmp/registry"
mkdir -p "$registry"
agents_json="$(jq -nc --arg cw "$claude_work" --arg bw "$bulk_work" --arg xw "$codex_work" \
  --arg started "$started_iso" --arg bulk_started "$(iso_at "$((now_epoch - 601 * 60))")" '[
  {pid: 4101, family: "claude", role: "worker", working_dir: $cw, started_at: $started, elapsed_seconds: 660},
  {pid: 4102, family: "codex", role: "verifier", working_dir: $xw, started_at: $started, elapsed_seconds: 660},
  {pid: 4103, family: "claude", role: "worker", working_dir: $bw, started_at: $bulk_started, elapsed_seconds: 36060}
]')"
read_agents() {
  python3 "$reader" "$registry" "$claude_root" "$codex_root" <<<"$agents_json"
}
field() {
  printf '%s' "$1" | jq -c --argjson pid "$2" ".[] | select(.pid == \$pid) | $3"
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/149-the-dashboard-draws-the-burn.md
# 1. A Claude message split across records is counted once: tokens and turns
#    key on message.id, while every tool_use block still counts as a call.
first="$(read_agents)" || fail "149: the reader exited non-zero"
[[ "$(field "$first" 4101 '.stage_tokens')" == "3345" ]] \
  || fail "149: a split message was counted twice (want 3345, got $(field "$first" 4101 '.stage_tokens'))"
[[ "$(field "$first" 4101 '.activity.turns')" == "3" ]] \
  || fail "149: turns should count messages, not records (want 3, got $(field "$first" 4101 '.activity.turns'))"
[[ "$(field "$first" 4101 '.activity.tool_calls')" == "2" ]] \
  || fail "149: tool_calls should still count every tool_use block (want 2)"
# 2. Each live agent carries a burn series: cumulative tokens, cache reads and
#    turns at the end of each minute bucket, bucket start in epoch seconds.
want_points="[{\"t\":$base,\"tokens\":1115,\"cached\":1000,\"turns\":1},{\"t\":$((base + 60)),\"tokens\":2230,\"cached\":2000,\"turns\":2},{\"t\":$((base + 180)),\"tokens\":3345,\"cached\":3000,\"turns\":3}]"
[[ "$(field "$first" 4101 '.burn.bucket_seconds')" == "60" ]] \
  || fail "149: claude burn.bucket_seconds should start at 60"
[[ "$(field "$first" 4101 '[.burn.points[] | {t, tokens, cached, turns}]')" == "$want_points" ]] \
  || fail "149: claude burn points wrong: $(field "$first" 4101 '.burn.points')"
[[ "$(field "$first" 4102 '[.burn.points[] | {t, tokens, cached, turns}]')" == "[{\"t\":$base,\"tokens\":1050,\"cached\":200,\"turns\":1},{\"t\":$((base + 120)),\"tokens\":2120,\"cached\":900,\"turns\":2}]" ]] \
  || fail "149: codex burn points should follow total_token_usage: $(field "$first" 4102 '.burn.points')"
# 3. The claude series survives incremental reads, and a message whose
#    records straddle two reads is still counted once.
assistant "$t4" msg_4 u6 '{"type":"text","text":"Checking status."}' >> "$claude_transcript"
second="$(read_agents)" || fail "149: the second read exited non-zero"
assistant "$t4" msg_4 u7 '{"type":"tool_use","id":"toolu_3","name":"Bash","input":{"command":"git status --short"}}' >> "$claude_transcript"
third="$(read_agents)" || fail "149: the third read exited non-zero"
[[ "$(field "$third" 4101 '.stage_tokens')" == "4460" ]] \
  || fail "149: a message split across two reads was counted twice (want 4460, got $(field "$third" 4101 '.stage_tokens'))"
[[ "$(field "$third" 4101 '[.activity.turns, .activity.tool_calls]')" == "[4,3]" ]] \
  || fail "149: after the straddling message want turns 4 and tool_calls 3, got $(field "$third" 4101 '[.activity.turns, .activity.tool_calls]')"
[[ "$(field "$third" 4101 '.burn.points | length')" == "4" ]] \
  || fail "149: the incremental series should keep its earlier points and add one (want 4)"
[[ "$(field "$third" 4101 '.burn.points[-1] | [.t, .tokens, .cached, .turns]')" == "[$((base + 240)),4460,4000,4]" ]] \
  || fail "149: the newest point is wrong: $(field "$third" 4101 '.burn.points[-1]')"
# 4. The series is bounded. A ten-hour run coarsens its buckets by doubling
#    rather than growing without limit, and still ends on the running total.
[[ "$(field "$third" 4103 '.burn.points | length <= 240')" == "true" ]] \
  || fail "149: a ten-hour series must hold at most 240 points (got $(field "$third" 4103 '.burn.points | length'))"
bucket="$(field "$third" 4103 '.burn.bucket_seconds')"
[[ "$bucket" =~ ^(120|240|480|960)$ ]] \
  || fail "149: a coarsened series doubles its 60-second bucket (got $bucket)"
[[ "$(field "$third" 4103 "[.burn.points[] | .t % $bucket] | all(. == 0)")" == "true" ]] \
  || fail "149: coarsened bucket starts must sit on the new bucket width"
[[ "$(field "$third" 4103 '[.burn.points[-1].tokens, .stage_tokens]')" == "[669000,669000]" ]] \
  || fail "149: the coarsened series must still end on the running total"
[[ "$(field "$third" 4103 '[.burn.points | (map(.t) | . == (sort | unique)), (map(.tokens) | . == sort)] | all')" == "true" ]] \
  || fail "149: points must be strictly time-ordered with non-decreasing tokens"
# 5. No transcript means no series, not an empty or zero one.
missing="$(python3 "$reader" "$registry" "$claude_root" "$codex_root" <<<'[{"pid":4104,"family":"claude","role":"worker","working_dir":"/nowhere/at/all","started_at":"2026-10-11T00:00:00Z","elapsed_seconds":30}]')"
[[ "$(field "$missing" 4104 '.burn')" == "null" ]] \
  || fail "149: an unreadable transcript must yield burn: null"
# 6. The --repo seam carries the series for a live agent.
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
  || fail "149: aggregate-dashboard.sh --repo exited non-zero"
[[ "$(printf '%s' "$seam" | jq -c '.agents[0].burn.points[-1] | [.tokens, .cached, .turns]')" == "[4460,4000,4]" ]] \
  || fail "149: the --repo seam does not carry the burn series for the live agent"
# 7. The dashboard's burn cell: SDK figures keep their LIVE label; a CLI
#    dispatch shows its transcript total, recent rate, cache share and a
#    sparkline; absence stays absence.
command -v node >/dev/null 2>&1 || fail "149: node is required for the dashboard assertions"
node --check "$repo_root/dashboard/dashboard.js" || fail "149: dashboard.js does not parse"
AUTOMETTA_DASHBOARD_JS="$repo_root/dashboard/dashboard.js" BURN_NOW="$now_epoch" node <<'NODE' || fail "149: the dashboard burn cell is wrong"
const fs = require("fs");
const source = fs.readFileSync(process.env.AUTOMETTA_DASHBOARD_JS, "utf8");
const defs = source.match(/\n  function \w+\([^)]*\) \{[\s\S]*?\n  \}(?=\n)/g) || [];
if (!defs.some((d) => /\n  function burnCell\(agent\) \{/.test(d))) {
  console.error("149: dashboard.js defines no top-level burnCell(agent)");
  process.exit(1);
}
const api = new Function("state", "charts", "document", "window",
  defs.join("\n") + "\nreturn { burnCell: burnCell };")({}, {}, {}, {});
const html = (cell) => (cell && typeof cell === "object" && cell.html != null) ? String(cell.html) : String(cell == null ? "" : cell);
const text = (cell) => html(cell).replace(/<[^>]*>/g, " ");
const now = Number(process.env.BURN_NOW);
const problems = [];

const live = { live_usage: { input_tokens: 1000, output_tokens: 234, updated_at: "2026-10-11T12:00:00Z" },
  stage_tokens: 99, stage_tokens_status: "counted", burn: null };
if (!/LIVE 1,234/.test(text(api.burnCell(live)))) problems.push("an SDK figure lost its 'LIVE 1,234' label");

const cli = { live_usage: null, stage_tokens: 2500000, stage_tokens_status: "counted",
  burn: { bucket_seconds: 60, points: [
    { t: now - 600, tokens: 400000, cached: 300000, turns: 4 },
    { t: now - 300, tokens: 1000000, cached: 800000, turns: 9 },
    { t: now, tokens: 2500000, cached: 2000000, turns: 20 }] } };
const cliText = text(api.burnCell(cli));
const cliHtml = html(api.burnCell(cli));
if (!/2\.5M|2,500,000/.test(cliText)) problems.push("the transcript total is not shown: " + cliText);
if (!/transcript/i.test(cliText)) problems.push("the total is not labelled as a transcript figure");
if (!/300(\.0)?k\/min|300,000\/min/i.test(cliText)) problems.push("the five-minute rate is not 300k/min: " + cliText);
if (!/80% cached/.test(cliText)) problems.push("the cache-read share is not shown as '80% cached'");
if (!/<svg[\s\S]*<(polyline|path)\b/.test(cliHtml)) problems.push("no inline SVG sparkline for a series of three points");
if (/\bn\/a\b/.test(cliText)) problems.push("a counted transcript total still reads n/a");

const single = Object.assign({}, cli, { burn: { bucket_seconds: 60, points: [cli.burn.points[2]] } });
if (/\/min/.test(text(api.burnCell(single)))) problems.push("a single point invented a rate");

const waiting = { live_usage: null, stage_tokens: null, stage_tokens_status: "waiting", burn: null };
const waitingText = text(api.burnCell(waiting));
if (!/waiting/.test(waitingText) || /\b0\b/.test(waitingText) || /<svg/.test(html(api.burnCell(waiting))))
  problems.push("a waiting agent should read 'waiting' with no zero and no sparkline: " + waitingText);

const unavailable = { live_usage: null, stage_tokens: null, stage_tokens_status: "unavailable", burn: null };
if (!/n\/a/.test(text(api.burnCell(unavailable)))) problems.push("an unavailable figure should still read n/a");

if (!/function renderAgents\(repos\) \{[\s\S]*?burnCell\(a\)[\s\S]*?\n  \}/.test(source))
  problems.push("renderAgents does not use burnCell for the live rows");

if (problems.length) { console.error("149: " + problems.join("; ")); process.exit(1); }
NODE
# AUTOMETTA-CONTRACT-END

printf 'agent-burn-smoke: PASS\n'

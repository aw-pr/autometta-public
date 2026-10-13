#!/usr/bin/env bash
# Offline proof for stage card 154: the ticker and the dashboard read one way.
#
# scripts/agent-ticker.sh and scripts/lib/transcript-tokens.py advance the
# same registry offset. Card 149's verifier showed that when the ticker
# consumes a chunk, the library's burn series and cache figure skip it. Here
# the two readers alternate over one registry, and the result must equal one
# library pass over the whole transcript. No auth, no network, no token spend.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
base=$(( (now_epoch / 60) * 60 - 600 ))
started_iso="$(iso_at "$((base - 60))")"

repo="$tmp/repo"
claude_root="$tmp/claude-projects"
work="$tmp/work"
mkdir -p "$repo/state/active-agents" "$repo/state/logs" "$work"
slug="$(printf '%s' "$work" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
mkdir -p "$claude_root/$slug"
transcript="$claude_root/$slug/session.jsonl"
: > "$repo/state/logs/01-fixture-worker.log"

usage='"usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":10}'
assistant() { # minute-offset message-id uuid content-json
  printf '{"type":"assistant","timestamp":"%s","uuid":"%s","message":{"id":"%s","role":"assistant","content":[%s],%s}}\n' \
    "$(iso_at "$((base + $1 * 60 + 5))")" "$3" "$2" "$4" "$usage"
}
text='{"type":"text","text":"."}'
bash_call='{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls"}}'

sleep 120 &
agent_pid=$!
cat > "$repo/state/active-agents/$agent_pid.json" <<EOF
{"pid":$agent_pid,"family":"claude","role":"worker","identity":"Claude Sonnet 5.5 <claude-sonnet-5-5@local>","stage_id":"01-fixture","card_path":"stage-cards/01-fixture.md","log_path":"$repo/state/logs/01-fixture-worker.log","started_at":"$started_iso","budget_seconds":2400,"working_dir":"$work"}
EOF
cat > "$repo/state/heartbeat.json" <<EOF
{"checked_at":"$(iso_at "$now_epoch")","entries":[{"pid":$agent_pid,"family":"claude","role":"worker","elapsed_seconds":660,"card_path":"stage-cards/01-fixture.md","log_path":"$repo/state/logs/01-fixture-worker.log","log_size":0,"flags":[]}]}
EOF

agents_json="$(jq -nc --argjson pid "$agent_pid" --arg w "$work" --arg s "$started_iso" \
  '[{pid: $pid, family: "claude", role: "worker", working_dir: $w, started_at: $s, elapsed_seconds: 660}]')"
library_read() { # registry-dir
  python3 "$script_dir/lib/transcript-tokens.py" "$1" "$claude_root" "$tmp/no-codex" <<<"$agents_json"
}
ticker_read() {
  AUTOMETTA_CLAUDE_PROJECTS="$claude_root" AUTOMETTA_CODEX_SESSIONS="$tmp/no-codex" \
    "$script_dir/agent-ticker.sh" "$repo" --once 2>/dev/null
}
view() {
  printf '%s' "$1" | jq -cS '.[0] | {stage_tokens, turns: .activity.turns, tool_calls: .activity.tool_calls, burn}'
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/154-the-ticker-and-the-dashboard-read-one-way.md
# 1. Library, then ticker, then library over one registry ends where a single
#    library pass over the whole transcript ends: total, counts and series.
{ assistant 0 m1 u1 "$text"; assistant 1 m2 u2 "$text"; assistant 1 m2 u3 "$bash_call"; } > "$transcript"
library_read "$repo/state/active-agents" >/dev/null || fail "154: the first library read failed"
{ assistant 3 m3 u4 "$bash_call"; assistant 4 m4 u5 "$text"; } >> "$transcript"
ticker_out="$(ticker_read)" || fail "154: agent-ticker.sh --once exited non-zero"
printf '%s\n' "$ticker_out" | grep -Eq 'tokens:4460\b' \
  || fail "154: the ticker should report the deduplicated 4460 tokens: $(printf '%s\n' "$ticker_out" | grep 'tokens:' || true)"
{ assistant 4 m4 u6 "$bash_call"; assistant 6 m5 u7 "$text"; } >> "$transcript"
alternated="$(view "$(library_read "$repo/state/active-agents")")"
mkdir -p "$tmp/fresh-registry"
cp "$repo/state/active-agents/$agent_pid.json" "$tmp/fresh-registry/" 2>/dev/null || true
jq 'with_entries(select(.key | startswith("transcript") | not)) | del(.activity)' \
  "$tmp/fresh-registry/$agent_pid.json" > "$tmp/fresh-registry/clean.json"
mv "$tmp/fresh-registry/clean.json" "$tmp/fresh-registry/$agent_pid.json"
fresh="$(view "$(library_read "$tmp/fresh-registry")")"
[[ "$(printf '%s' "$fresh" | jq -c '[.stage_tokens, .turns, .tool_calls]')" == "[5575,5,3]" ]] \
  || fail "154: the fresh single pass is not the expected fixture reading: $fresh"
[[ "$alternated" == "$fresh" ]] \
  || fail "154: alternating the ticker and the library diverged from one pass: alternated $alternated, fresh $fresh"
# 2. One reader, not two copies of it: the ticker carries no transcript
#    parser of its own and loads the library's.
! grep -Eq '^def transcript_tokens\(' "$script_dir/agent-ticker.sh" \
  || fail "154: agent-ticker.sh still defines its own transcript_tokens"
grep -q 'transcript-tokens.py' "$script_dir/agent-ticker.sh" \
  || fail "154: agent-ticker.sh does not load scripts/lib/transcript-tokens.py"
# AUTOMETTA-CONTRACT-END

printf 'ticker-shared-reader-smoke: PASS\n'

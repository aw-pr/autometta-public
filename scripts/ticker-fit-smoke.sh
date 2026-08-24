#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3"
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "$3"
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3 (got $1, expected $2)"
}

repo="$fixture/repo"
controller="$fixture/controller"
claude_root="$fixture/claude-projects"
codex_root="$fixture/codex-sessions"
bin="$fixture/bin"
mkdir -p "$repo/state/active-agents" "$repo/state/recent-agents" \
  "$repo/state/logs" "$repo/state/verifiers" "$controller/subscribers" \
  "$controller/dashboard" "$claude_root" "$codex_root/2026/08/24" "$bin"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$repo/state/state.yaml" <<'EOF'
current_stage: live
stages:
  - id: retired
    status: superseded
  - id: bad
    status: verifier_failed
  - id: live
    status: in_progress
EOF
cat > "$repo/state/budget.json" <<'EOF'
{"tokens_spent":12521044,"token_cap_total":100000000,"halted":false,"consecutive_failures":0}
EOF
printf '{"ts":"%s","input_tokens":100,"cached_input_tokens":50,"output_tokens":25,"cost_usd_est":1.25,"cache_hit_rate":0.5}\n' "$now" > "$repo/state/cost-log.jsonl"
printf 'repo_path: "%s"\nenabled: false\n' "$repo" > "$controller/subscribers/repo.yaml"

claude_cwd="$fixture/claude-run"
codex_cwd="$fixture/codex-run"
claude_slug="$(printf '%s' "$claude_cwd" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$claude_root/$claude_slug"
cat > "$claude_root/$claude_slug/session.jsonl" <<'EOF'
{"message":{"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}
EOF
cat > "$codex_root/2026/08/24/rollout-fixture.jsonl" <<EOF
{"type":"session_meta","payload":{"cwd":"$codex_cwd"}}
{"payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":321}}}}
EOF

write_registry() {
  local pid="$1" family="$2" cwd="$3"
  cat > "$repo/state/active-agents/$pid.json" <<EOF
{"pid":$pid,"family":"$family","role":"worker","working_dir":"$cwd","started_at":"$now"}
EOF
}
write_registry 101 claude "$claude_cwd"
write_registry 102 codex "$codex_cwd"
write_registry 103 claude "$fixture/missing"
cat > "$repo/state/heartbeat.json" <<EOF
{"checked_at":"$now","entries":[
 {"pid":101,"family":"claude","role":"worker","card_path":"live.md","elapsed_seconds":30,"log_size":0,"log_path":"$repo/state/logs/claude.log","flags":[]},
 {"pid":102,"family":"codex","role":"verifier","card_path":"live.md","elapsed_seconds":30,"log_size":0,"log_path":"$repo/state/logs/codex.log","flags":[]},
 {"pid":103,"family":"claude","role":"worker","card_path":"missing.md","elapsed_seconds":200,"log_size":0,"log_path":"$repo/state/logs/missing.log","flags":[]}
]}
EOF
: > "$repo/state/logs/claude.log"
: > "$repo/state/logs/codex.log"
: > "$repo/state/logs/missing.log"

count_file="$fixture/version-count"
cat > "$bin/autometta" <<'EOF'
#!/usr/bin/env bash
printf x >> "$AUTOMETTA_VERSION_COUNT"
printf 'autometta %s\n' "${AUTOMETTA_FAKE_SHA:-deadbee}"
EOF
chmod +x "$bin/autometta"
head_sha="$(git -C "$script_dir/.." rev-parse --short HEAD)"

common=(PHAT_CONTROLLER_HOME="$controller" AUTOMETTA_CLAUDE_PROJECTS="$claude_root" \
  AUTOMETTA_CODEX_SESSIONS="$codex_root" AUTOMETTA_VERSION_COUNT="$count_file" PATH="$bin:$PATH")
output="$(env "${common[@]}" AUTOMETTA_FAKE_SHA="$head_sha" AUTOMETTA_TICKER_COLUMNS=39 AUTOMETTA_TICKER_ROWS=15 \
  "$script_dir/agent-ticker.sh" "$repo" --once)"
line_count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
(( line_count <= 15 )) || fail "39x15 agent ticker exceeded 15 rows"
AUTOMETTA_TEST_FRAME="$output" python3 -c 'import os; assert all(len(x) <= 39 for x in os.environ["AUTOMETTA_TEST_FRAME"].splitlines())'
assert_contains "$output" "ALERTS" "39x15 frame omitted ALERTS"
assert_contains "$output" "bad" "39x15 frame omitted failed stage"
assert_not_contains "$output" "retired" "superseded stage appeared as an alert"
assert_contains "$output" "ACTIVE" "39x15 frame omitted ACTIVE"
assert_contains "$output" "tokens:100" "Claude transcript total was not rendered"
assert_contains "$output" "12.5M/100.0M" "SPEND did not use short token units"
assert_contains "$output" "hidden" "fitted frame did not report hidden content"

wide="$(env "${common[@]}" AUTOMETTA_TICKER_COLUMNS=120 AUTOMETTA_TICKER_ROWS=32 \
  "$script_dir/agent-ticker.sh" "$repo" --once)"
assert_contains "$wide" "tokens:100" "quiet Claude frame lost its persisted transcript total"
assert_contains "$wide" "tokens:321" "tall frame omitted the Codex transcript total"
assert_contains "$wide" "tokens:unavailable" "tall frame omitted the unavailable transcript row"
assert_contains "$wide" "\$1.25" "SPEND did not format money to two decimals"
assert_contains "$wide" "exact window: 12521044 / 100000000" "SPEND hid the exact token figures"
assert_contains "$wide" "BUILD DRIFT: installed deadbee, checkout $head_sha" "agent ticker omitted build drift"
matching="$(env "${common[@]}" AUTOMETTA_FAKE_SHA="$head_sha" AUTOMETTA_TICKER_COLUMNS=120 \
  "$script_dir/agent-ticker.sh" "$repo" --once)"
assert_not_contains "$matching" "BUILD DRIFT" "matching builds raised a drift warning"

printf 'repo_path: "%s"\nenabled: true\n' "$repo" > "$controller/subscribers/repo.yaml"
status40="$(env "${common[@]}" AUTOMETTA_TICKER_COLUMNS=40 AUTOMETTA_TICKER_ROWS=32 \
  "$script_dir/status-ticker.sh" --once --repo "$repo")"
AUTOMETTA_TEST_FRAME="$status40" python3 -c 'import os; assert all(len(x) <= 40 for x in os.environ["AUTOMETTA_TEST_FRAME"].splitlines())'
assert_contains "$status40" "repo" "40-column status omitted repo"
assert_contains "$status40" "live" "40-column status omitted live stage"
status120="$(env "${common[@]}" AUTOMETTA_TICKER_COLUMNS=120 "$script_dir/status.sh" --repo "$repo")"
assert_contains "$status120" "process/log" "120-column status omitted process/log field"
assert_contains "$status120" "ticks:" "120-column status omitted tick field"

cat > "$controller/dashboard/data.json" <<EOF
{"generated_at":"$now","repos":[],"fleet_totals":{}}
EOF
fleet="$(env "${common[@]}" PHAT_CONTROLLER_FLEET_ONCE=true "$script_dir/attach.sh" --fleet-ticker)"
assert_contains "$fleet" "autometta $head_sha fleet" "fleet ticker omitted version header"
assert_contains "$fleet" "BUILD DRIFT" "fleet ticker omitted build drift"

: > "$count_file"
env "${common[@]}" PHAT_CONTROLLER_TICKER_INTERVAL=1 AUTOMETTA_TICKER_COLUMNS=39 \
  AUTOMETTA_TICKER_ROWS=15 "$script_dir/agent-ticker.sh" "$repo" > "$fixture/frames" &
ticker_pid=$!
sleep 3
kill "$ticker_pid" 2>/dev/null || true
wait "$ticker_pid" 2>/dev/null || true
assert_eq "$(wc -c < "$count_file" | tr -d ' ')" 1 "build check ran more than once within a minute"
python3 - "$fixture/frames" <<'PY'
import sys
data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
frames = data.split("\x1b[H")[1:]
assert len(frames) >= 2
for frame in frames:
    assert "agent ticker" in frame and "Refresh:" in frame
PY

printf 'PASS ticker fit, transcript totals, atomic frames, status widths and build drift\n'

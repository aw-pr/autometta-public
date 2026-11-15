#!/usr/bin/env bash
# Offline contract proof for card 174: a Claude snapshot the reader cannot
# trust (stale, unparseable, or the reader itself failing) holds Claude
# dispatch instead of admitting it, an over-100 window is exhausted rather
# than unknown, and everything the operator relies on today stays as it is:
# an absent snapshot, a codex-only card, reserve off, observe, the
# --ignore-reserve drain and the manual escape. The mandate mirrors the
# operator's live window_reserve of 2026-11-15.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'FAIL: 174-quota-unknown-holds-claude: %s\n' "$1" >&2; exit 1; }

export AI_QUOTA_DIR="$fixture/quota"
export AUTOMETTA_CODEX_SESSIONS="$fixture/codex-sessions"
export AUTOMETTA_HOME="$fixture/controller"
export AUTOMETTA_CODEX_LIVE_READ=0
export AI_QUOTA_NOW_EPOCH=2000000000
export AI_QUOTA_STALE_SECONDS=600
export AUTOMETTA_SCHEDULE_CLOCK=14:00
unset AUTOMETTA_CODEX_QUOTA_POLICY AUTOMETTA_IGNORE_RESERVE AUTOMETTA_RESERVE_GATED AUTOMETTA_IGNORE_PACE \
  AUTOMETTA_CONTROLLER_MANDATE AUTOMETTA_QUOTA_TICK_JSON AUTOMETTA_CLAUDE_MODE AUTOMETTA_CODEX_MODE
mkdir -p "$AI_QUOTA_DIR" "$AUTOMETTA_CODEX_SESSIONS/2033/05/18" "$AUTOMETTA_HOME/log" "$AUTOMETTA_HOME/subscribers"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/174-quota-unknown-holds-claude.md

assert_eq() { [[ -n "$1" && "$1" == "$2" ]] || fail "$3: expected $1, got ${2:-<empty>}"; }
assert_contains() { [[ -n "$2" && "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_not_contains() { [[ -n "$2" && "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"; }

# Now is 2033-05-18T03:33:20Z. Fresh is 60 s old, stale 700 s old (limit 600 s).
FRESH_AT=2033-05-18T03:32:20Z
STALE_AT=2033-05-18T03:21:40Z
FIVE_HOUR_RESET=2033-05-18T06:00:00Z
FIVE_HOUR_RESET_EPOCH=2000008800

# The live exporter's shape (vibe-menuapp claude-usage.json, 2026-11-15).
write_claude() {
  local fetched="$1" five_hour="$2"
  cat > "$AI_QUOTA_DIR/claude.json" <<JSON
{
  "detail": "",
  "fetched_at": "${fetched}",
  "observed_at": "${fetched}",
  "source": "claude",
  "windows": [
    {"key": "5-hour", "label": "5-hour", "resets_at": "${FIVE_HOUR_RESET}", "utilization": ${five_hour}},
    {"key": "weekly", "label": "Weekly", "resets_at": "2033-05-23T00:00:00Z", "utilization": 64},
    {"key": "weekly-fable", "label": "Weekly (Fable)", "resets_at": "2033-05-23T00:00:00Z", "utilization": 43}
  ]
}
JSON
}

# A fresh Codex reading well inside its windows, so the codex card policy
# admits and only the Claude reading can decide a Claude dispatch.
cat > "$AUTOMETTA_CODEX_SESSIONS/2033/05/18/rollout-fixture.jsonl" <<'JSONL'
{"timestamp":"2033-05-18T03:33:00Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":20,"window_minutes":300,"resets_at":2000009000},"secondary":{"used_percent":30,"window_minutes":10080,"resets_at":2000600000}}}}
JSONL

mandate="$AUTOMETTA_HOME/phat-controller-mandate.yaml"
write_mandate() {
  local percent="$1" action="$2"
  cat > "$mandate" <<YAML
window_reserve:
  percent: ${percent}
  action: ${action}
  claude_window: 5-hour
  codex_admit_percent: 100
  pace:
    action: observe
    slot_hours: 48
    families:
      - codex
  overnight:
    start: "22:00"
    end: "09:00"
    percent: ${percent}
    stop_outside: false
  timezone: local
YAML
}

write_drain() {
  local ignore_reserve="$1"
  jq -n --argjson expires "$(( $(date -u +%s) + 3600 ))" --argjson ignore "$ignore_reserve" \
    '{version:1, token_cap_total:1000000000, expires_at:$expires, started_at:"2026-11-15T10:25:44Z",
      repos:[], reason:"fixture drain", ignore_reserve:$ignore}' > "$AUTOMETTA_HOME/drain.json"
}

repo="$fixture/repo"
mkdir -p "$repo/state" "$repo/stage-cards"
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages:
  - id: 01-claude-card
    status: pending
    worker: "Claude Opus 5.5 <claude-opus-5-5@local>"
    verifier: "GPT-6.1 Sol <gpt-6-1-sol@local>"
  - id: 02-codex-card
    status: pending
    worker: "GPT-6.1 Sol <gpt-6-1-sol@local>"
    verifier: "GPT-6 Astra <gpt-6-astra@local>"
  - id: 03-claude-verifier
    status: in_progress
    worker: "GPT-6.1 Sol <gpt-6-1-sol@local>"
    verifier: "Claude Opus 5.5 <claude-opus-5-5@local>"
    reserve_exempt: false
YAML
card="$repo/stage-cards/01-claude-card.md"
printf '%s\n' '# Stage card 01' '' '- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>' \
  '- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>' > "$card"

clear_pause() {
  printf '{"paused_until":null,"paused_reason":null}\n' > "$repo/state/budget.json"
}

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

refresh() {
  AUTOMETTA_QUOTA_TICK_JSON=""
  quota_refresh_tick 2>/dev/null || true
}

tick_logs() { cat "$AUTOMETTA_HOME"/log/tick-*.log 2>/dev/null || true; }
log_mark() { tick_logs | wc -l | tr -d ' '; }
log_since() { tick_logs | tail -n +"$(( $1 + 1 ))"; }

GATE_RC=""
GATE_LOG=""
gate() {
  local stage="$1" role="$2" mark rc=0
  clear_pause
  mark="$(log_mark)"
  quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" "$stage" "$role" 2>/dev/null || rc=$?
  GATE_RC="$rc"
  GATE_LOG="$(log_since "$mark")"
}
paused_until() { jq -r '.paused_until' "$repo/state/budget.json"; }

write_mandate 10 hold
clear_pause

# 1. A fresh snapshot under the reserve admits the Claude card.
write_claude "$FRESH_AT" 18
refresh
assert_eq known "$(jq -r '.families.claude.status' <<<"$AUTOMETTA_QUOTA_TICK_JSON")" "fresh snapshot reads known"
gate 01-claude-card worker
assert_eq 0 "$GATE_RC" "fresh 18% snapshot admits the Claude worker"
assert_eq null "$(paused_until)" "fresh admit records no pause"

# 2. A stale snapshot holds the Claude worker, records no pause (there is no
# reset to wait for), and the log line names the reason and the hold.
write_claude "$STALE_AT" 18
refresh
assert_contains "$(jq -r '.families.claude.reason' <<<"$AUTOMETTA_QUOTA_TICK_JSON")" "snapshot stale" "stale snapshot reads unknown"
gate 01-claude-card worker
assert_eq 1 "$GATE_RC" "stale snapshot holds the Claude worker"
assert_eq null "$(paused_until)" "stale hold records no pause"
assert_eq null "$(jq -r '.paused_reason' "$repo/state/budget.json")" "stale hold records no pause reason"
stale_line="$(grep -F '01-claude-card' <<<"$GATE_LOG" | grep -F 'reading unknown: snapshot stale' || true)"
assert_contains "$stale_line" "held" "stale hold log line says held"
assert_not_contains "$stale_line" "fail-open" "stale hold log line"
mark="$(log_mark)"
quota_log_tick_readings 2>/dev/null
summary="$(log_since "$mark" | grep -F 'quota claude: unknown' || true)"
assert_contains "$summary" "snapshot stale" "tick summary names the stale Claude reading"
assert_not_contains "$summary" "fail-open" "tick summary for a stale Claude reading"

# 3. A Claude verifier of a stage whose worker was not reserve-exempt is held
# the same way; an exempt one still proceeds.
gate 03-claude-verifier verifier
assert_eq 1 "$GATE_RC" "stale snapshot holds a non-exempt Claude verifier"
assert_eq null "$(paused_until)" "verifier hold records no pause"
yq -i '(.stages[] | select(.id == "03-claude-verifier")).reserve_exempt = true' "$repo/state/state.yaml"
gate 03-claude-verifier verifier
assert_eq 0 "$GATE_RC" "a reserve-exempt Claude verifier still proceeds"
yq -i '(.stages[] | select(.id == "03-claude-verifier")).reserve_exempt = false' "$repo/state/state.yaml"

# 4. The manual spawn path holds on the same reading, and the operator's
# explicit escape still admits.
QUOTA_GATE_REASON=""
manual_rc=0
quota_spawn_permits "$repo" claude "$card" 2>/dev/null || manual_rc=$?
assert_eq 1 "$manual_rc" "manual spawn refuses on a stale Claude snapshot"
assert_contains "$QUOTA_GATE_REASON" "snapshot stale" "manual refusal names the stale reading"
[[ -z "$QUOTA_GATE_RESET" ]] || fail "an unknown hold carries no reset, got $QUOTA_GATE_RESET"
escape_rc=0
AUTOMETTA_IGNORE_RESERVE=1 quota_spawn_permits "$repo" claude "$card" 2>/dev/null || escape_rc=$?
assert_eq 0 "$escape_rc" "AUTOMETTA_IGNORE_RESERVE=1 still admits a manual spawn"

# 5. An unparseable snapshot holds, naming the malformed reading.
printf '{bad json\n' > "$AI_QUOTA_DIR/claude.json"
refresh
gate 01-claude-card worker
assert_eq 1 "$GATE_RC" "unparseable snapshot holds the Claude worker"
assert_eq null "$(paused_until)" "malformed hold records no pause"
malformed_line="$(grep -F '01-claude-card' <<<"$GATE_LOG" | grep -F 'reading unknown: snapshot malformed' || true)"
assert_contains "$malformed_line" "held" "malformed hold log line says held"

# 6. The reader itself failing is no reading at all, and holds too. An
# unparseable clock makes quota-window.py exit non-zero, so this is the
# tick's own reader-failed fallback, not a hand-written reading.
write_claude "$FRESH_AT" 18
AUTOMETTA_QUOTA_TICK_JSON=""
AI_QUOTA_NOW_EPOCH=not-a-clock quota_refresh_tick 2>/dev/null || true
assert_eq "reader failed" "$(jq -r '.families.claude.reason' <<<"$AUTOMETTA_QUOTA_TICK_JSON")" "a crashing reader yields reader failed"
clear_pause
mark="$(log_mark)"
reader_rc=0
quota_gate_family_dispatch "$repo" claude "worker 01-claude-card" claude-opus-5-5 2>/dev/null || reader_rc=$?
assert_eq 1 "$reader_rc" "a failed reader holds Claude dispatch"
assert_contains "$(log_since "$mark" | grep -F 'reader failed' || true)" "held" "reader-failed hold log line says held"
assert_eq null "$(paused_until)" "reader-failed hold records no pause"

# 7. Over 100% is exhausted, not unknown: the reader keeps the figure and the
# reserve holds to the window's published reset.
write_claude "$FRESH_AT" 105
refresh
assert_eq known "$(jq -r '.families.claude.status' <<<"$AUTOMETTA_QUOTA_TICK_JSON")" "an over-100 snapshot reads known"
assert_eq 105.0 "$(jq -r '.families.claude.windows[] | select(.label == "5-hour") | .utilization' <<<"$AUTOMETTA_QUOTA_TICK_JSON")" "the reader keeps the over-100 figure"
gate 01-claude-card worker
assert_eq 1 "$GATE_RC" "an over-100 5-hour window holds the Claude worker"
assert_eq "$FIVE_HOUR_RESET_EPOCH" "$(paused_until)" "the exhausted hold pauses to the 5-hour reset"
assert_contains "$(jq -r '.paused_reason' "$repo/state/budget.json")" "5-hour" "the pause names the exhausted window"
assert_not_contains "$GATE_LOG" "reading unknown" "an over-100 reading is not reported unknown"

# 8. A codex-only card is untouched by a stale Claude snapshot.
write_claude "$STALE_AT" 18
refresh
gate 02-codex-card worker
assert_eq 0 "$GATE_RC" "a codex-only card dispatches while the Claude snapshot is stale"
assert_not_contains "$GATE_LOG" "(claude)" "a codex-only card consults no Claude gate"

# 9. An absent snapshot (a host with no exporter) still admits, as cards 124,
# 135 and 138a freeze.
rm -f "$AI_QUOTA_DIR/claude.json"
refresh
assert_eq "snapshot absent" "$(jq -r '.families.claude.reason' <<<"$AUTOMETTA_QUOTA_TICK_JSON")" "absent snapshot reason"
gate 01-claude-card worker
assert_eq 0 "$GATE_RC" "an absent snapshot still admits the Claude worker"
assert_contains "$GATE_LOG" "snapshot absent" "the absent admit is logged"

# 10. The reserve's own off switches still admit on a stale snapshot:
# percent 0, action observe, and an --ignore-reserve drain. A drain that only
# lifts token caps (the live 2026-11-15 shape, ignore_reserve false) does not.
write_claude "$STALE_AT" 18
refresh
write_mandate 0 hold
gate 01-claude-card worker
assert_eq 0 "$GATE_RC" "reserve percent 0 admits on a stale snapshot"
write_mandate 10 observe
gate 01-claude-card worker
assert_eq 0 "$GATE_RC" "action observe admits on a stale snapshot"
write_mandate 10 off
gate 01-claude-card worker
assert_eq 0 "$GATE_RC" "action off admits on a stale snapshot"
write_mandate 10 hold
write_drain true
gate 01-claude-card worker
assert_eq 0 "$GATE_RC" "an --ignore-reserve drain admits on a stale snapshot"
write_drain false
gate 01-claude-card worker
assert_eq 1 "$GATE_RC" "a token-cap drain without --ignore-reserve still holds on a stale snapshot"
rm -f "$AUTOMETTA_HOME/drain.json"

# 11. The operator documentation states the new rule, not the old one.
tick_loop_doc="$(tr '\n' ' ' < "$script_dir/../docs/tick-loop.md" | tr -s ' ')"
assert_not_contains "$tick_loop_doc" "unknown Claude readings retain the existing fail-open behaviour" "docs/tick-loop.md"
assert_not_contains "$tick_loop_doc" "an unknown reading fails open by design" "docs/tick-loop.md curfew rationale"
absent_passage=""
if [[ "$tick_loop_doc" == *"snapshot absent"* ]]; then
  before_absent="${tick_loop_doc%%snapshot absent*}"
  after_absent="${tick_loop_doc#*snapshot absent}"
  (( ${#before_absent} > 400 )) && before_absent="${before_absent: -400}"
  absent_passage="${before_absent}snapshot absent${after_absent:0:200}"
fi
assert_contains "$absent_passage" "stale" "the absent-snapshot passage names stale readings"
assert_contains "$absent_passage" "malformed" "the absent-snapshot passage names malformed readings"
assert_contains "$absent_passage" "hold" "the absent-snapshot passage says they hold"

# 12. Unchanged reader guards: negative or non-numeric utilisation is still
# malformed, the default staleness limit is still 600 s, and the default
# snapshot directory is unchanged.
reader() { python3 "$script_dir/quota-window.py" claude; }
write_claude "$FRESH_AT" -5
assert_eq "snapshot malformed" "$(reader | jq -r '.reason')" "negative utilisation stays malformed"
write_claude "$FRESH_AT" '"high"'
assert_eq "snapshot malformed" "$(reader | jq -r '.reason')" "non-numeric utilisation stays malformed"
write_claude "$STALE_AT" 18
assert_contains "$(env -u AI_QUOTA_STALE_SECONDS python3 "$script_dir/quota-window.py" claude | jq -r '.reason')" "limit 600s" "the default staleness limit is 600 s"
write_claude 2033-05-18T03:25:00Z 18
assert_eq known "$(env -u AI_QUOTA_STALE_SECONDS python3 "$script_dir/quota-window.py" claude | jq -r '.status')" "a 500 s old snapshot is inside the default limit"
grep -qF '"~/.local/state/ai-quota"' "$script_dir/quota-window.py" || fail "the default snapshot directory moved"

# AUTOMETTA-CONTRACT-END

printf 'PASS quota-unknown-hold-smoke: stale, malformed and reader-failed Claude readings hold; over-100 is exhausted; absent, codex-only, reserve-off, observe and --ignore-reserve unchanged\n'

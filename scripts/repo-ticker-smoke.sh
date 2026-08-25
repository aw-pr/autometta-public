#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# repo-ticker-smoke.sh: card 63's contract test and acceptance criteria,
# offline. Fixture: one stage in flight past its budget, one stalled stage
# with a wip pin, one re-queued stage that must not appear in ESCALATIONS, a
# halt with a reason, and a tick log two hours old, plus a second, unrelated
# subscriber that must never leak into the first repo's frame.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixture="$(mktemp -d)"
cleanup() {
  case "$fixture" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$fixture" ;; esac
}
trap cleanup EXIT

fail_count=0
check() {
  local label="$1" got="$2" want="ok"
  if [[ "$got" == "$want" ]]; then
    printf '  PASS: %s\n' "$label"
  else
    printf '  FAIL: %s (got %q)\n' "$label" "$got"
    fail_count=$(( fail_count + 1 ))
  fi
}

now_epoch="$(date -u +%s)"
iso_at() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now_iso="$(iso_at "$now_epoch")"
two_hours_ago="$(iso_at "$(( now_epoch - 7200 ))")"
started_over_budget="$(iso_at "$(( now_epoch - 5400 ))")"

controller="$fixture/controller"
target_repo="$fixture/alert-repo"
other_repo="$fixture/other-repo"
mkdir -p "$controller/subscribers" "$controller/dashboard" \
  "$target_repo/state/active-agents" "$other_repo/state"

# ---------------------------------------------------------------------------
# The target repo: everything the contract test asks for.
long_queue_id_1="63-a-very-long-stage-identifier-that-would-once-have-truncated-at-forty-columns"
long_queue_id_2="64-another-long-stage-identifier-needing-the-full-width-of-a-119-column-pane"
requeued_id="50-was-failed-now-back-to-pending-after-a-repair-requeue"
stalled_id="15-boids-density-motion-tuning-stalled-with-a-preserved-attempt"
live_id="63-one-ticker-per-repo-that-fits-its-pane-live"
completed_id="01-first-stage-ever-shipped"
itemized_only_id="99-itemized-dispatch-only-in-cost-log"

cat > "$target_repo/state/state.yaml" <<EOF
version: 1
current_stage: $live_id
last_tick_at: "$two_hours_ago"
tick_count: 40
clock_tick_budget_remaining: 10
stages:
  - id: $completed_id
    status: completed
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "Codex GPT-5.6 Sol <gpt-5-6-sol@local>"
    completed_at: "$now_iso"
  - id: $requeued_id
    status: pending
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "Codex GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier_attempts: 1
    wip_branch: "wip/$requeued_id-attempt-1"
  - id: $stalled_id
    status: stalled
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "Codex GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier_attempts: 3
    wip_branch: "wip/15-boids-density-motion-tuning-attempt-3"
  - id: $live_id
    status: in_progress
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "Codex GPT-5.6 Sol <gpt-5-6-sol@local>"
    started_at: "$started_over_budget"
  - id: $long_queue_id_1
    status: pending
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "Codex GPT-5.6 Sol <gpt-5-6-sol@local>"
  - id: $long_queue_id_2
    status: pending
    worker: "Codex GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
EOF

cat > "$target_repo/state/budget.json" <<EOF
{"tokens_spent":9000000,"token_cap_total":150000000,"halted":true,"halt_reason":"token-cap","consecutive_failures":1,"consecutive_failure_cap":3}
EOF

cat > "$target_repo/state/cost-log.jsonl" <<EOF
{"ts":"$now_iso","stage_id":"$itemized_only_id","role":"verifier","result":"fail","identity":"Codex GPT-5.6 Sol <gpt-5-6-sol@local>","input_tokens":2600000,"cached_input_tokens":0,"output_tokens":0,"usage_status":"recorded","cost_usd_est":4.10}
EOF

cat > "$target_repo/state/active-agents/$$.json" <<EOF
{"pid":$$,"family":"claude","role":"worker","identity":"Claude Sonnet 5 <claude-sonnet-5@local>","stage_id":"$live_id","card_path":"live.md","started_at":"$started_over_budget","budget_seconds":3600,"working_dir":"$target_repo"}
EOF

printf 'repo_path: "%s"\nenabled: true\n' "$target_repo" > "$controller/subscribers/alert-repo.yaml"

# ---------------------------------------------------------------------------
# The second, unrelated subscriber -- must never leak into repo-ticker's
# frame for the target repo (acceptance criterion 1).
other_only_id="77-only-the-other-repo-should-ever-show-this-stage-id"
cat > "$other_repo/state/state.yaml" <<EOF
version: 1
current_stage: null
last_tick_at: "$now_iso"
tick_count: 1
clock_tick_budget_remaining: 10
stages:
  - id: $other_only_id
    status: verifier_failed
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "Codex GPT-5.6 Sol <gpt-5-6-sol@local>"
EOF
cat > "$other_repo/state/budget.json" <<EOF
{"tokens_spent":0,"token_cap_total":8000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF
: > "$other_repo/state/cost-log.jsonl"
printf 'repo_path: "%s"\nenabled: true\n' "$other_repo" > "$controller/subscribers/other-repo.yaml"

export PHAT_CONTROLLER_HOME="$controller"

capture() {
  local width="$1"; shift
  AUTOMETTA_TICKER_COLUMNS="$width" AUTOMETTA_TICKER_ROWS=40 "$script_dir/repo-ticker.sh" "$target_repo" --once
}

printf '== 1. isolation: no data from the other subscriber ==\n' >&2
frame119="$(capture 119)"
check "target frame carries its own live stage" \
  "$([[ "$frame119" == *"$live_id"* ]] && printf ok || printf 'missing')"
check "target frame never mentions the other repo's stage" \
  "$([[ "$frame119" != *"$other_only_id"* ]] && printf ok || printf 'leaked')"
other_frame="$(AUTOMETTA_TICKER_COLUMNS=119 AUTOMETTA_TICKER_ROWS=40 "$script_dir/repo-ticker.sh" "$other_repo" --once)"
check "the other repo's own frame does show its stage" \
  "$([[ "$other_frame" == *"$other_only_id"* ]] && printf ok || printf 'missing')"
check "the other repo's frame never mentions the target's live stage" \
  "$([[ "$other_frame" != *"$live_id"* ]] && printf ok || printf 'leaked')"

printf '\n== 2. fits its pane, no scrollback, at 80 and 119 ==\n' >&2
frame80="$(capture 80)"
frame160="$(capture 160)"
check "80-col frame has no line over 80 printable columns" \
  "$(AUTOMETTA_TEST_FRAME="$frame80" python3 -c '
import os, re
ansi = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
print("ok" if all(len(ansi.sub("", l)) <= 80 for l in lines) else "overflow")')"
check "119-col frame has no line over 119 printable columns" \
  "$(AUTOMETTA_TEST_FRAME="$frame119" python3 -c '
import os, re
ansi = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
print("ok" if all(len(ansi.sub("", l)) <= 119 for l in lines) else "overflow")')"
check "80-col frame line count fits the given height (no scrollback)" \
  "$([[ "$(printf '%s\n' "$frame80" | wc -l | tr -d ' ')" -le 40 ]] && printf ok || printf 'too tall')"
check "119-col frame line count fits the given height (no scrollback)" \
  "$([[ "$(printf '%s\n' "$frame119" | wc -l | tr -d ' ')" -le 40 ]] && printf ok || printf 'too tall')"

printf '\n== 3/4. NOW: elapsed vs budget, verified by arithmetic, over budget reads as such ==\n' >&2
check "NOW carries the live stage id in full" \
  "$([[ "$frame119" == *"$live_id"* ]] && printf ok || printf 'missing')"
check "past-budget stage reads OVER BUDGET rather than resting at 99% or 100%" \
  "$([[ "$frame119" == *"OVER BUDGET"* ]] && printf ok || printf 'no OVER BUDGET marker')"
# Verify the displayed percentage against the SUT's own displayed elapsed and
# budget, not against a value this test computed at fixture-creation time --
# the fixture's started_at is fixed the moment the test begins, so comparing
# to a constant "elapsed" drifts by however long fixture setup and the
# earlier checks took to run (observed: 150.0% vs 153.3% a few seconds later).
check "NOW's displayed percentage matches elapsed*100/budget from its own displayed durations" \
  "$(AUTOMETTA_TEST_FRAME="$frame119" python3 -c '
import os, re
frame = os.environ["AUTOMETTA_TEST_FRAME"]
m = re.search(r"OVER BUDGET (\S+)/(\S+) \(([\d.]+)%\)", frame)
if not m:
    print("no OVER BUDGET line found"); raise SystemExit
def secs(s):
    mo = re.fullmatch(r"(\d+)h(\d+)m", s)
    if mo: return int(mo.group(1)) * 3600 + int(mo.group(2)) * 60
    mo = re.fullmatch(r"(\d+)m(\d+)s", s)
    if mo: return int(mo.group(1)) * 60 + int(mo.group(2))
    mo = re.fullmatch(r"(\d+)s", s)
    if mo: return int(mo.group(1))
    raise ValueError(s)
elapsed_s, budget_s, shown_pct = secs(m.group(1)), secs(m.group(2)), float(m.group(3))
expected = round(elapsed_s * 100.0 / budget_s, 1)
print("ok" if abs(expected - shown_pct) < 0.15 else "expected %.1f from %ds/%ds, shown %.1f" % (expected, elapsed_s, budget_s, shown_pct))
')"
check "the over-budget percentage is not clamped to 100" \
  "$([[ "$frame119" != *" (100.0%)"* ]] && printf ok || printf 'clamped to 100')"

printf '\n== 5. ESCALATIONS: only outstanding, wip pin shown, requeued excluded, counts agree ==\n' >&2
escalations_block="$(printf '%s\n' "$frame119" | sed -n '/^ESCALATIONS/,/^$/p')"
check "ESCALATIONS shows the stalled stage" \
  "$([[ "$escalations_block" == *"$stalled_id"* ]] && printf ok || printf 'missing')"
check "ESCALATIONS shows its preserved wip pin" \
  "$([[ "$escalations_block" == *"wip/15-boids"* ]] && printf ok || printf 'missing wip pin')"
check "ESCALATIONS shows the halt and its reason" \
  "$([[ "$escalations_block" == *"HALTED"* && "$escalations_block" == *"token-cap"* ]] && printf ok || printf 'missing halt')"
check "the re-queued stage (now pending) never appears in ESCALATIONS" \
  "$([[ "$escalations_block" != *"$requeued_id"* ]] && printf ok || printf 'requeued stage leaked into ESCALATIONS')"
done_n=1
outstanding_n=5
escalated_n=1
check "NEXT counts line states done/outstanding/escalated correctly, escalated a subset of outstanding" \
  "$([[ "$frame119" == *"${done_n} done"*"${outstanding_n} outstanding"*"${escalated_n} escalated"* ]] && printf ok || printf 'counts mismatch')"

printf '\n== empty ESCALATIONS renders nothing at all ==\n' >&2
clean_repo="$fixture/clean-repo"
mkdir -p "$clean_repo/state"
cat > "$clean_repo/state/state.yaml" <<EOF
version: 1
current_stage: null
last_tick_at: "$now_iso"
tick_count: 1
clock_tick_budget_remaining: 10
stages:
  - id: 01-clean
    status: completed
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "Codex GPT-5.6 Sol <gpt-5-6-sol@local>"
EOF
cat > "$clean_repo/state/budget.json" <<EOF
{"tokens_spent":0,"token_cap_total":8000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF
: > "$clean_repo/state/cost-log.jsonl"
printf 'repo_path: "%s"\nenabled: true\n' "$clean_repo" > "$controller/subscribers/clean-repo.yaml"
clean_frame="$(AUTOMETTA_TICKER_COLUMNS=119 AUTOMETTA_TICKER_ROWS=40 "$script_dir/repo-ticker.sh" "$clean_repo" --once)"
check "a healthy repo renders no ESCALATIONS section at all" \
  "$([[ "$clean_frame" != *"ESCALATIONS"* ]] && printf ok || printf 'ESCALATIONS rendered with nothing to say')"

printf '\n== 6. SPEND AND LOSS: table plus the OpenAI under-reporting caveat ==\n' >&2
spend_block="$(printf '%s\n' "$frame119" | sed -n '/^SPEND AND LOSS/,/^$/p')"
check "SPEND AND LOSS shows spent today" "$([[ "$spend_block" == *"spent today"* ]] && printf ok || printf missing)"
check "SPEND AND LOSS shows lost today and lost 7d side by side with spend" \
  "$([[ "$spend_block" == *"lost today"* && "$spend_block" == *"lost 7d"* ]] && printf ok || printf missing)"
check "SPEND AND LOSS shows the resolved cap and percent used" \
  "$([[ "$spend_block" == *"cap"* && "$spend_block" == *"% used)"* ]] && printf ok || printf missing)"
check "SPEND AND LOSS carries the OpenAI/codex under-reporting caveat" \
  "$([[ "$spend_block" == *"codex/GPT"*"output_tokens"* ]] && printf ok || printf missing)"

printf '\n== 7. FRESHNESS: both states, loud past the threshold ==\n' >&2
freshness_block="$(printf '%s\n' "$frame119" | sed -n '/^FRESHNESS/,/^$/p')"
check "a tick two hours old reads STALE" \
  "$([[ "$freshness_block" == *STALE* ]] && printf ok || printf 'not loud')"
fresh_frame="$(AUTOMETTA_TICKER_COLUMNS=119 AUTOMETTA_TICKER_ROWS=40 "$script_dir/repo-ticker.sh" "$clean_repo" --once)"
check "a fresh tick does not read STALE" \
  "$([[ "$fresh_frame" != *STALE* ]] && printf ok || printf 'falsely loud')"

printf '\n== 8. proportional widths, no truncation at 119, stated drop order at 80 ==\n' >&2
check "the long stage id is never truncated at 119 columns" \
  "$([[ "$frame119" == *"$long_queue_id_1"* ]] && printf ok || printf 'truncated')"
check "160 columns renders without error and keeps the long stage id intact" \
  "$([[ "$frame160" == *"$long_queue_id_1"* ]] && printf ok || printf 'missing at 160')"
check "the 80 and 119 column captures actually differ (allocation responds to width)" \
  "$([[ "$frame80" != "$frame119" ]] && printf ok || printf 'identical at both widths')"

# A dedicated fixture for the stated drop order in NOW: over budget (long
# "OVER BUDGET ..." text), verifying (so an attempt count is shown), and
# tokens still "waiting" (elapsed under 120s). NOW's fixed fields (phase,
# agent, elapsed/budget, criteria 3/4) never drop; tokens is dropped first,
# the attempt count survives longer because it is the clearer sign a stage
# is near its retry cap.
drop_repo="$fixture/drop-repo"
mkdir -p "$drop_repo/state/active-agents"
drop_stage="20-drop-order-fixture"
started_90s_ago="$(iso_at "$(( now_epoch - 90 ))")"
cat > "$drop_repo/state/state.yaml" <<EOF
version: 1
current_stage: $drop_stage
last_tick_at: "$now_iso"
tick_count: 1
clock_tick_budget_remaining: 10
stages:
  - id: $drop_stage
    status: in_progress
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "Codex GPT-5.6 Sol <gpt-5-6-sol@local>"
    started_at: "$started_90s_ago"
    verifier_attempts: 1
EOF
cat > "$drop_repo/state/budget.json" <<EOF
{"tokens_spent":0,"token_cap_total":8000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF
: > "$drop_repo/state/cost-log.jsonl"
cat > "$drop_repo/state/active-agents/$$.json" <<EOF
{"pid":$$,"family":"codex","role":"verifier","identity":"Codex GPT-5.6 Sol <gpt-5-6-sol@local>","stage_id":"$drop_stage","card_path":"live.md","started_at":"$started_90s_ago","budget_seconds":60,"working_dir":"$drop_repo"}
EOF
printf 'repo_path: "%s"\nenabled: true\n' "$drop_repo" > "$controller/subscribers/drop-repo.yaml"

drop_frame80="$(AUTOMETTA_TICKER_COLUMNS=80 AUTOMETTA_TICKER_ROWS=40 "$script_dir/repo-ticker.sh" "$drop_repo" --once)"
drop_frame119="$(AUTOMETTA_TICKER_COLUMNS=119 AUTOMETTA_TICKER_ROWS=40 "$script_dir/repo-ticker.sh" "$drop_repo" --once)"
check "at 119 columns NOW shows both tokens and the attempt count" \
  "$([[ "$drop_frame119" == *"tokens:waiting"* && "$drop_frame119" == *"attempt 1/"* ]] && printf ok || printf 'missing one of tokens/attempt at 119')"
check "at 80 columns NOW drops tokens first, but keeps the attempt count" \
  "$([[ "$drop_frame80" != *"tokens:waiting"* && "$drop_frame80" == *"attempt 1/"* ]] && printf ok || printf 'wrong field dropped at 80')"
check "at 80 columns NOW still shows OVER BUDGET with a percentage over 100" \
  "$(AUTOMETTA_TEST_FRAME="$drop_frame80" python3 -c '
import os, re
m = re.search(r"OVER BUDGET \S+/\S+ \(([\d.]+)%\)", os.environ["AUTOMETTA_TEST_FRAME"])
print("ok" if m and float(m.group(1)) > 100.0 else "no over-100 OVER BUDGET line at 80")
')"

printf '\n== 9. the renderer reads only the aggregated JSON, nothing recomputed ==\n' >&2
check "repo-ticker-render.py opens no files of its own" \
  "$([[ "$(grep -c 'open(' "$repo_root/scripts/lib/repo-ticker-render.py" || true)" == 0 ]] && printf ok || printf 'opens a file')"
check "repo-ticker.sh never reads a subscriber's state.yaml, budget.json or cost-log.jsonl directly" \
  "$([[ -z "$(grep -v '^\s*#' "$repo_root/scripts/repo-ticker.sh" | grep -E 'state\.yaml|budget\.json|cost-log\.jsonl' || true)" ]] && printf ok || printf 'reads a file directly')"

printf '\n== 10. failures history is a command; the live view no longer itemises ==\n' >&2
failures_out="$("$script_dir/failures-history.sh" "$target_repo")"
check "the failures command shows the itemised dispatch" \
  "$([[ "$failures_out" == *"$itemized_only_id"* ]] && printf ok || printf 'missing from command output')"
check "the live ticker view does not itemise that dispatch" \
  "$([[ "$frame119" != *"$itemized_only_id"* ]] && printf ok || printf 'itemised dispatch leaked into the live pane')"

printf '\n== 11. locale and TERM pinned, colour and plain both render clean ==\n' >&2
colour_capture="$(LC_ALL=en_GB.UTF-8 TERM=xterm-256color NO_COLOR='' AUTOMETTA_TICKER_COLUMNS=119 AUTOMETTA_TICKER_ROWS=40 "$script_dir/repo-ticker.sh" "$target_repo" --once)"
plain_capture="$(LC_ALL=C NO_COLOR=1 AUTOMETTA_TICKER_COLUMNS=119 AUTOMETTA_TICKER_ROWS=40 "$script_dir/repo-ticker.sh" "$target_repo" --once)"
check "colour-locale capture still carries the live stage id" \
  "$([[ "$colour_capture" == *"$live_id"* ]] && printf ok || printf missing)"
check "NO_COLOR capture carries no ANSI escape codes" \
  "$(printf '%s' "$plain_capture" | LC_ALL=C grep -q $'\x1b\[' && printf 'escapes present' || printf ok)"

if (( fail_count > 0 )); then
  printf '\nFAIL repo-ticker smoke: %d assertion(s) failed\n' "$fail_count"
  exit 1
fi
printf '\nPASS repo-ticker: isolation, widths, arithmetic, escalations, spend and loss, freshness, one-JSON-source, failures command\n'

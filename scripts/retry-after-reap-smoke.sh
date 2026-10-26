#!/usr/bin/env bash
# retry-after-reap-smoke.sh: the automatic retry survives the reaper, and a
# dispatch the heartbeat killed is never retried automatically (card 163).
#
# Production order on 2026-10-23 (card 162): the stall path preserved the
# attempt, the reaper removed the pinned worktree, and the retry then failed
# because there was no worktree left to preserve. Separately, the heartbeat's
# reason for killing the worker was lost by the next heartbeat pass.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
agent_pid=""
cleanup() {
  [[ -z "$agent_pid" ]] || kill "$agent_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

export AUTOMETTA_HOME="$tmp/home"
export PHAT_CONTROLLER_HOME="$AUTOMETTA_HOME"
export AUTOMETTA_ESCALATIONS="$tmp/escalations"
export AUTOMETTA_NOTIFY=0
mkdir -p "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_HOME/log" "$AUTOMETTA_HOME/dashboard"

fail() {
  printf 'FAIL: 163-a-retry-survives-the-reaper: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/163-a-retry-survives-the-reaper.md
stage=07-dead
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
make_case() {
  local name="$1" started="$2"
  local dir="$tmp/repos/$name"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b dev .
    git config user.email smoke@local
    git config user.name smoke
    git config commit.gpgsign false
    printf 'state/**\n' > .gitignore
    printf 'seed\n' > README.md
    git add -A
    git commit -qm seed
    git worktree add -q -b "autometta/$stage" "$dir/../$name-run-$stage" dev
  )
  mkdir -p "$dir/state/envelopes" "$dir/state/verifiers" "$dir/state/logs" \
    "$dir/state/active-agents" "$dir/state/recent-agents"
  printf 'half-done deliverable\n' > "$dir/../$name-run-$stage/work-in-progress.txt"
  cat > "$dir/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage
    status: stalled
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    started_at: "$started"
    verifier_attempts: 0
    worker_pid: null
    stall_marker: worker_envelope_missing_after_exit
YAML
  printf '{"version":1,"halted":false,"consecutive_failures":1,"consecutive_failure_cap":3,"token_cap_total":150000000,"tokens_spent":0,"wall_clock_cap_seconds":86400,"wall_clock_elapsed_seconds":0,"clock_tick_cap":400,"clock_ticks_used":1}\n' \
    > "$dir/state/budget.json"
  printf '%s\n' "$dir"
}
field() {
  yq -r ".stages[] | select(.id == \"$stage\") | .$2 // \"\"" "$1/state/state.yaml"
}
retry() {
  auto_retry_dead_workers "$1" "$1/state/state.yaml" >/dev/null 2>&1 \
    || fail "auto_retry_dead_workers exited non-zero for $(basename "$1")"
}
wip_branches() {
  git -C "$1" for-each-ref --format='%(refname)' "refs/heads/wip/$stage-attempt-*" | grep -c . || true
}

# (a) The production order: stall-time preservation, then the reaper, then the retry.
a="$(make_case reaped "$now_iso")"
preserve_failed_work "$a" "$a/state/state.yaml" "$stage" "" worker_envelope_missing_after_exit stalled >/dev/null 2>&1 \
  || fail "(a) fixture: stall-time preservation failed"
pinned="$(field "$a" wip_commit)"
[[ -n "$pinned" ]] || fail "(a) fixture: stall-time preservation recorded no wip_commit"
"$script_dir/requeue-stage.sh" --worktree-only "$a" "$stage" >/dev/null 2>&1 || fail "(a) fixture: the reap failed"
[[ ! -d "$a/../reaped-run-$stage" ]] || fail "(a) fixture: the run worktree survived the reap"
retry "$a"
[[ "$(field "$a" status)" == "pending" ]] || fail "(a) a preserved and reaped attempt was not retried (status $(field "$a" status))"
[[ "$(field "$a" auto_retries)" == "1" ]] || fail "(a) auto_retries is not 1"
[[ "$(field "$a" wip_commit)" == "$pinned" ]] || fail "(a) the retry changed the recorded wip_commit"
[[ "$(git -C "$a" show "$pinned:work-in-progress.txt" 2>/dev/null)" == "half-done deliverable" ]] \
  || fail "(a) the pinned commit lost the attempt's work"
[[ "$(wip_branches "$a")" == "1" ]] || fail "(a) the retry pinned a second wip branch"

# (b) No worktree and nothing recorded: the reaper only removes a clean or pinned worktree.
b="$(make_case clean-reaped "$now_iso")"
"$script_dir/requeue-stage.sh" --worktree-only "$b" "$stage" >/dev/null 2>&1 || fail "(b) fixture: the reap failed"
retry "$b"
[[ "$(field "$b" status)" == "pending" && "$(field "$b" auto_retries)" == "1" ]] \
  || fail "(b) a stalled stage whose worktree was already reaped was not retried"

# (c) The heartbeat kills a token outlier and leaves a durable record of why.
c="$(make_case killed "$now_iso")"
yq -i "(.stages[] | select(.id == \"$stage\")) |= (.status = \"in_progress\" | .stall_marker = null)" "$c/state/state.yaml"
yq -i ".current_stage = \"$stage\"" "$c/state/state.yaml"
for n in 1 2 3 4 5 6; do
  printf '{"stage_id":"ordinary-%s","role":"worker","total_tokens":1800000,"usage_status":"recorded"}\n' "$n"
done > "$c/state/cost-log.jsonl"
sessions="$tmp/codex-sessions/2026/10/23"
mkdir -p "$sessions"
cat > "$sessions/rollout-killed.jsonl" <<EOF
{"type":"session_meta","payload":{"cwd":"$c/../killed-run-$stage","timestamp":"$now_iso"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":45000000,"cached_input_tokens":44000000,"output_tokens":758708,"total_tokens":45758708}}}}
EOF
export AUTOMETTA_CODEX_TRANSCRIPT_ROOTS="$tmp/codex-sessions"
export AUTOMETTA_OUTLIER_KILL_MULTIPLE=15
sleep 120 &
agent_pid=$!
cat > "$c/state/active-agents/$agent_pid.json" <<EOF
{"pid":$agent_pid,"family":"codex","role":"worker","identity":"Worker <worker@local>","stage_id":"$stage","card_path":"$stage.md","log_path":"$c/state/logs/$stage-worker.log","started_at":"$now_iso","budget_seconds":3600,"working_dir":"$c/../killed-run-$stage"}
EOF
: > "$c/state/logs/$stage-worker.log"
printf 'repo_path: "%s"\nenabled: true\n' "$c" > "$AUTOMETTA_HOME/subscribers/killed.yaml"
"$script_dir/heartbeat.sh" "$c" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$agent_pid" 2>/dev/null || break; sleep 0.5; done
! kill -0 "$agent_pid" 2>/dev/null || fail "(c) fixture: the heartbeat did not kill a 25x token outlier"
{ wait "$agent_pid"; } 2>/dev/null || true
agent_pid=""
kill_record="$c/state/kills/$stage.json"
[[ -s "$kill_record" ]] || fail "(c) the heartbeat left no state/kills/$stage.json"
jq -e . "$kill_record" >/dev/null 2>&1 || fail "(c) the kill record is not JSON"
[[ "$(jq -r '.stage_id' "$kill_record")" == "$stage" ]] || fail "(c) the kill record does not name the stage"
[[ "$(jq -r '.role' "$kill_record")" == "worker" ]] || fail "(c) the kill record does not name the role"
[[ "$(jq -r '.reason' "$kill_record")" == "token-outlier" ]] || fail "(c) the kill record reason is not token-outlier"
jq -e '.killed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$kill_record" >/dev/null 2>&1 \
  || fail "(c) killed_at is not an ISO 8601 UTC timestamp"
"$script_dir/heartbeat.sh" "$c" >/dev/null 2>&1 || true
[[ "$(jq -r '.reason' "$kill_record" 2>/dev/null)" == "token-outlier" ]] \
  || fail "(c) the next heartbeat pass lost or rewrote the kill record"

# (d) The tick marks the dead worker stalled as it does today; the retry must leave it for the operator.
yq -i "(.stages[] | select(.id == \"$stage\")) |= (.status = \"stalled\" | .stall_marker = \"worker_envelope_missing_after_exit\" | .worker_pid = null)" "$c/state/state.yaml"
yq -i '.current_stage = null' "$c/state/state.yaml"
retry "$c"
[[ "$(field "$c" status)" == "stalled" ]] || fail "(d) a dispatch the heartbeat killed was retried automatically"
[[ "$(field "$c" auto_retries)" == "" || "$(field "$c" auto_retries)" == "0" ]] || fail "(d) auto_retries was recorded for a killed dispatch"
[[ -d "$c/../killed-run-$stage" ]] || fail "(d) the killed attempt's worktree was removed"

# (e) The escalation names why.
escalations_scan "$c" >/dev/null 2>&1 || fail "(e) escalations_scan exited non-zero"
esc_file="$(find "$AUTOMETTA_ESCALATIONS/pending" -name "*-killed-$stage-stalled.md" | head -1)"
[[ -n "$esc_file" ]] || fail "(e) no stalled escalation was written for the killed stage"
grep -q 'token-outlier' "$esc_file" || fail "(e) the escalation does not name the heartbeat kill reason"

# (f) A kill record from an earlier attempt does not block this attempt's retry.
f="$(make_case old-kill "$now_iso")"
mkdir -p "$f/state/kills"
printf '{"stage_id":"%s","role":"worker","pid":1,"reason":"token-outlier","killed_at":"2026-10-01T00:00:00Z"}\n' "$stage" \
  > "$f/state/kills/$stage.json"
retry "$f"
[[ "$(field "$f" status)" == "pending" && "$(field "$f" auto_retries)" == "1" ]] \
  || fail "(f) a kill record older than the stage's started_at blocked the retry"

# (g) An operator requeue clears the record.
"$script_dir/requeue-stage.sh" "$c" "$stage" >/dev/null 2>&1 || fail "(g) the operator requeue of the killed stage failed"
[[ ! -e "$kill_record" ]] || fail "(g) requeue-stage.sh left the kill record behind"
[[ "$(field "$c" status)" == "pending" ]] || fail "(g) the operator requeue did not reset the stage"

jq -e '.. | objects | select(has("auto_retries"))' "$script_dir/../schemas/state.yaml.json" >/dev/null 2>&1 \
  || fail "the state schema lost auto_retries"
bash -n "$script_dir/tick.sh" || fail "tick.sh does not parse"
bash -n "$script_dir/heartbeat.sh" || fail "heartbeat.sh does not parse"
# AUTOMETTA-CONTRACT-END

printf 'retry-after-reap-smoke: PASS\n'

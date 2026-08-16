#!/usr/bin/env bash
# Re-queue a stage for a fresh worker dispatch after a verifier FAIL,
# a killed agent, or a card re-brief.
#
# The tick trusts per-stage state on disk. Two traps make a hand re-queue
# go wrong:
#   1. A stale worker envelope in state/handoffs/<stage>.json still says
#      status=pass, so the next tick skips the worker and dispatches the
#      verifier straight at the old code, driving the stage toward the
#      terminal verifier_failed state.
#   2. A run worktree (../<repo>-run-<stage>) and branch (autometta/<stage>)
#      left standing by a prior FAIL or stall would collide with the fresh
#      one the next dispatch tries to cut.
# This script removes both mechanically. (Before the 2026-08-14
# worktree-per-run backport, trap 2 was dirty worker WIP in repo_root's own
# tree, which this script refused to touch rather than discard; that no
# longer applies since dispatch never touches repo_root.)
#
# Usage: requeue-stage.sh <repo-root> <stage-id>
# Example: requeue-stage.sh ~/repos/aegis-guardrails 01-per-call-approval-broker
set -euo pipefail

usage() { sed -n '2,17p' "$0"; exit 2; }
[ $# -eq 2 ] || usage
repo_root="$(cd "$1" && pwd)"
stage_id="$2"

for tool in yq jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "requeue: $tool is required" >&2; exit 1; }
done

state_yaml="$repo_root/state/state.yaml"
budget_json="$repo_root/state/budget.json"
[ -f "$state_yaml" ] || { echo "requeue: no state/state.yaml in $repo_root" >&2; exit 1; }

yq -o=json '.' "$state_yaml" | jq -e --arg id "$stage_id" \
  '.stages[] | select(.id == $id)' >/dev/null \
  || { echo "requeue: stage '$stage_id' not found in $state_yaml" >&2; exit 1; }

# Trap 2 (retired 2026-08-14 by worktree-per-run dispatch): a prior attempt
# leaves worker WIP in its own ephemeral worktree/run branch, not in
# repo_root, so repo_root's tree is never a re-queue blocker. Remove that
# worktree and run branch so the next tick cuts a fresh one; the WIP inside
# is simply discarded (the verifier already FAILed it, or it stalled).
run_branch="autometta/${stage_id}"
work_dir="$(dirname "$repo_root")/$(basename "$repo_root")-run-${stage_id}"
git -C "$repo_root" worktree remove --force "$work_dir" >/dev/null 2>&1 || true
rm -rf "$work_dir"
git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
git -C "$repo_root" branch -D "$run_branch" >/dev/null 2>&1 || true
echo "requeue: removed run worktree ${work_dir} and branch ${run_branch} (if present)"

# Kill any live agent working this stage, then drop its registration.
for agent_file in "$repo_root"/state/active-agents/*.json; do
  [ -f "$agent_file" ] || continue
  card_path="$(jq -r '.card_path // ""' "$agent_file")"
  case "$card_path" in
    *"$stage_id"*)
      pid="$(jq -r '.pid // 0' "$agent_file")"
      if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        echo "requeue: killed live agent pid $pid for $stage_id"
      fi
      rm -f "$agent_file"
      ;;
  esac
done

# Trap 1: purge every per-stage artefact the tick could misread as progress.
rm -f "$repo_root/state/handoffs/$stage_id.json" \
      "$repo_root/state/verifiers/$stage_id.json" \
      "$repo_root/state/logs/$stage_id-worker.log" \
      "$repo_root/state/logs/$stage_id-verifier.log"

# Reset the stage record to a clean pending; clear current_stage if it points
# here. Same yq->jq->yq round-trip the tick uses for atomic state edits.
tmp_json="$(mktemp)"; tmp_yaml="$(mktemp)"
yq -o=json '.' "$state_yaml" | jq --arg id "$stage_id" '
  .current_stage = (if .current_stage == $id then null else .current_stage end)
  | .stages = [ .stages[]
      | if .id == $id then
          .status = "pending"
          | .verifier_attempts = 0
          | .completed_at = null
          | .verifier_started_at = null
          | .started_at = null
          | .worker_pid = null
          | .verifier_pid = null
          | .worker_tokens = 0
          | .tokens = 0
        else . end ]' > "$tmp_json"
yq -P '.' "$tmp_json" > "$tmp_yaml"
mv "$tmp_yaml" "$state_yaml"
rm -f "$tmp_json"

# Clear this repo's halt so the next tick considers it. Re-queueing a stage
# is exactly the operator saying "that failure is dealt with", so it clears
# consecutive_failures with the halt.
#
# It does NOT clear a halt whose spend cap is still blown. The old version
# cleared .halted unconditionally on the reasoning that "tick re-halts if a
# halt condition genuinely still exists"; that is true of the *tick* check
# but it makes a hand re-queue an unlatch of the only safety in the design,
# and on emergence-lab-gpu the loop was re-queued repeatedly across a window
# it had already overrun. Manufacturing token budget is not a re-queue, so
# say so and stop.
if [ -f "$budget_json" ]; then
  blown="$(jq -r '
    [ (if .tokens_spent >= .token_cap_total then "token-cap" else empty end),
      (if .wall_clock_elapsed_seconds >= .wall_clock_cap_seconds then "wall-clock-cap" else empty end),
      (if .clock_ticks_used >= .clock_tick_cap then "tick-cap" else empty end)
    ] | join(" ")
  ' "$budget_json")"
  if [ -n "$blown" ]; then
    echo "requeue: $stage_id reset to pending, but NOT clearing the halt." >&2
    echo "requeue: spend caps still exhausted: $blown" >&2
    jq -r '"requeue:   tokens \(.tokens_spent)/\(.token_cap_total), ticks \(.clock_ticks_used)/\(.clock_tick_cap), wall \(.wall_clock_elapsed_seconds)/\(.wall_clock_cap_seconds)"' "$budget_json" >&2
    echo "requeue: the next UTC window resets the counters, or raise the cap" >&2
    echo "requeue: deliberately in $budget_json. Do not clear .halted by hand." >&2
    exit 3
  fi
  tmp_budget="$(mktemp)"
  jq '.halted = false | .halt_reason = null | .halt_reasons = null | .halted_at = null
      | .consecutive_failures = 0' "$budget_json" > "$tmp_budget"
  mv "$tmp_budget" "$budget_json"
fi

echo "requeue: $stage_id in $repo_root reset to pending; stale envelopes purged."
echo "requeue: next tick dispatches a fresh worker. If the card was re-briefed,"
echo "requeue: make sure the re-brief references committed work, not the tree."

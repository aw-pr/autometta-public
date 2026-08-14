#!/usr/bin/env bash
# Re-queue a stage for a fresh worker dispatch after a verifier FAIL,
# a killed agent, or a card re-brief.
#
# The tick trusts per-stage state on disk. Two traps make a hand re-queue
# go wrong (both hit on 2026-08-13):
#   1. A stale worker envelope in state/handoffs/<stage>.json still says
#      status=pass, so the next tick skips the worker and dispatches the
#      verifier straight at the old code, driving the stage toward the
#      terminal verifier_failed state.
#   2. Worker WIP left uncommitted "for the next round to continue from"
#      keeps the tree dirty, which halts the very dispatch that would
#      continue it.
# This script removes trap 1 mechanically and refuses to run while trap 2
# is present.
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

# Trap 2 first: refuse while the tree is dirty (state/ excluded, same filter
# the tick uses). Uncommitted worker WIP must become a commit the re-briefed
# card can point at - author it as the worker model, not yourself.
if [ -n "$(git -C "$repo_root" status --porcelain -- . ':(exclude)state')" ]; then
  echo "requeue: $repo_root has a dirty tree (outside state/) - the tick would" >&2
  echo "         halt on it anyway. Commit the worker WIP first, e.g.:" >&2
  echo "           git commit --author=\"<worker model identity>\" -m 'wip(${stage_id}): round-N output, pre re-queue'" >&2
  echo "         then point the card re-brief at that SHA and re-run this." >&2
  exit 1
fi

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

# Clear this repo's halt so the next tick considers it (tick re-halts if a
# halt condition genuinely still exists - this is safe).
if [ -f "$budget_json" ]; then
  tmp_budget="$(mktemp)"
  jq '.halted = false | .halt_reason = null | .halted_at = null' "$budget_json" > "$tmp_budget"
  mv "$tmp_budget" "$budget_json"
fi

echo "requeue: $stage_id in $repo_root reset to pending; stale envelopes purged."
echo "requeue: next tick dispatches a fresh worker. If the card was re-briefed,"
echo "requeue: make sure the re-brief references committed work, not the tree."

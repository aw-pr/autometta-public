#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/183-commit-run-summary.md
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export AUTOMETTA_HOME="$tmp/host" PHAT_CONTROLLER_HOME="$tmp/host"
source "$root/scripts/tick.sh"
repo="$tmp/subscriber"
run=run-20261122-080000
path="runs/$run.json"
manifest="$repo/.autometta.local.yaml"
git init -qb dev "$repo"
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@local
git -C "$repo" config workflow.style publish-mirror
git -C "$repo" config publishguard.privatefile runs
git -C "$repo" config publishguard.publishbranch publish
mkdir -p "$repo/state"
printf 'state/\n.autometta.local.yaml\n' >"$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" branch publish "$base"
printf 'input\n' >"$repo/mine"
git -C "$repo" add mine
printf 'my unstaged edit\n' >>"$repo/mine"
printf 'base_branch: dev\n' >"$manifest"
printf '{"current_stage":"01-live","stages":[{"id":"01-live","run_id":"%s","status":"in_progress","base_branch":"dev"}]}\n' "$run" >"$repo/state/state.yaml"
printf '{"halted":false}\n' >"$repo/state/budget.json"
# Drive the real per-repo tick, isolating peripheral and provider processes.
run_heartbeat() { :; }
warn_if_vendor_stale() { :; }
escalations_scan() { :; }
ensure_tmux_viewer() { :; }
sweep_repo_retention() { :; }
_process_repo_locked() {
  case "$transition" in
    halt) printf '{"halted":true,"halted_at":"2026-11-22T08:05:00Z","halt_reason":"token-cap"}\n' >"$repo/state/budget.json" ;;
    awaiting)
      printf '{"halted":false}\n' >"$repo/state/budget.json"
      state_apply_json "$repo/state/state.yaml" '.current_stage=null | .stages[0].status="completed" | .stages[0].integration={state:"awaiting"}' ;;
    finish)
      printf '{"halted":false}\n' >"$repo/state/budget.json"
      state_apply_json "$repo/state/state.yaml" '.current_stage=null | .stages[0].status="completed" | .stages[0].integration={state:"merged",head:$sha}' --arg sha "$base" ;;
  esac
  return 0
}
fire() { transition="$1"; process_repo "$repo" "$manifest"; }
tip() { git -C "$repo" rev-parse HEAD; }
fire halt
[[ "$(tip)" == "$base" && ! -e "$repo/$path" ]]
printf '{"halted":false}\n' >"$repo/state/budget.json"
printf 'run_history:\n  private_branch: dev\n' >>"$manifest"
fire idle
[[ "$(tip)" == "$base" ]]
git -C "$repo" config --unset-all publishguard.privatefile
fire halt
[[ "$(tip)" == "$base" && ! -e "$repo/$path" ]]
git -C "$repo" config publishguard.privatefile runs
printf '{"halted":false}\n' >"$repo/state/budget.json"
fire halt
first="$(tip)"
[[ "$first" != "$base" ]] || { echo 'FAIL: halted run has no private summary commit' >&2; exit 1; }
git -C "$repo" show "HEAD:$path" | jq -e '.outcome=="halted" and .stages[0].id=="01-live"' >/dev/null
fire idle
[[ "$(tip)" == "$first" ]]
fire awaiting
[[ "$(tip)" == "$first" ]]
printf 'operator draft\n' >"$repo/$path"
fire finish
[[ "$(tip)" == "$first" && "$(cat "$repo/$path")" == 'operator draft' ]]
git -C "$repo" restore --worktree -- "$path"
fire idle
last="$(tip)"
[[ "$last" != "$first" ]]
git -C "$repo" show "HEAD:$path" | jq -e '.outcome=="finished" and .stages[0].status=="completed"' >/dev/null
fire idle
[[ "$(tip)" == "$last" ]]
for commit in "$first" "$last"; do
  [[ "$(git -C "$repo" diff-tree --no-commit-id --name-only -r "$commit")" == "$path" ]]
done
[[ "$(git -C "$repo" rev-list --count "$base..HEAD")" == 2 ]]
[[ "$(git -C "$repo" rev-parse publish)" == "$base" ]]
[[ "$(git -C "$repo" diff --cached --name-only)" == mine ]]
[[ "$(git -C "$repo" show :mine)" == input && "$(tail -1 "$repo/mine")" == 'my unstaged edit' ]]
git -C "$repo" diff --quiet HEAD -- "$path"
git clone -q --local -b dev "$repo" "$tmp/clone"
jq -e '.outcome=="finished"' "$tmp/clone/$path" >/dev/null
# Explicitly reject a configured publication target even when named in the manifest.
git -C "$repo" switch -q publish
printf 'base_branch: publish\nrun_history:\n  private_branch: publish\n' >"$manifest"
printf '{"current_stage":"01-live","stages":[{"id":"01-live","run_id":"%s","status":"in_progress","base_branch":"publish"}]}\n' "$run" >"$repo/state/state.yaml"
fire halt
[[ "$(tip)" == "$base" && "$(git -C "$repo" rev-parse dev)" == "$last" ]]
# AUTOMETTA-CONTRACT-END
echo 'PASS: private run summary commits'

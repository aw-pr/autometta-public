#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Offline replay of the pipeline tail rebase (pipeline_prepare_tail_rebase in
# tick.sh) against throwaway git fixtures. The operator keeps a stash in the
# main checkout; the tail worktree carries committed and uncommitted work.
# No network, no agent, no spend.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
smoke_tmp="$(mktemp -d)"
smoke_pids=()
cleanup() {
  local pid
  for pid in "${smoke_pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  case "$smoke_tmp" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$smoke_tmp" ;; esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: 169-the-tail-rebase-keeps-its-own-stash: %s\n' "$1"
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/169-the-tail-rebase-keeps-its-own-stash.md

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

smoke_log="$smoke_tmp/tick.log"
: >"$smoke_log"
log() { printf '%s\n' "$1" >>"$smoke_log"; }
commit_state_branch() { return 0; }

export GIT_AUTHOR_NAME=Smoke GIT_AUTHOR_EMAIL=smoke@local
export GIT_COMMITTER_NAME=Smoke GIT_COMMITTER_EMAIL=smoke@local

repo="" tail_work="" old_base="" head_commit=""

# A subscriber repo on dev, its state/ ignored, a tail worktree cut from the
# old base through the tick's own ensure_run_worktree, and the pair recorded
# in state as the head verifier leaves it: rebase_required, tail worker gone.
new_fixture() {
  local name="$1"
  repo="$smoke_tmp/$name"
  mkdir -p "$repo/state"
  git -C "$repo" init -q -b dev
  printf 'state/\n' >"$repo/.gitignore"
  printf 'base a\n' >"$repo/a.txt"
  printf 'base tail\n' >"$repo/tail.txt"
  printf 'base w\n' >"$repo/w.txt"
  git -C "$repo" add .gitignore a.txt tail.txt w.txt
  git -C "$repo" commit -qm base
  old_base="$(git -C "$repo" rev-parse HEAD)"
  cat >"$repo/state/budget.json" <<'JSON'
{"token_cap_total":10000,"tokens_spent":0,"clock_tick_cap":100,"clock_ticks_used":0,"idle_ticks_used":0,"consecutive_failure_cap":3,"consecutive_failures":0,"wall_clock_cap_seconds":10000,"wall_clock_elapsed_seconds":0,"halted":false}
JSON
  tail_work="$(ensure_run_worktree "$repo" 02-tail dev)"
  [[ -n "$tail_work" && -d "$tail_work" ]] || fail "fixture: ensure_run_worktree cut no tail worktree"
}

operator_stash() {
  printf 'operator wip\n' >"$repo/op.txt"
  git -C "$repo" stash push -q -u -m "operator: half-finished refactor"
  [[ ! -e "$repo/op.txt" ]] || fail "fixture: operator stash did not clean op.txt"
}

land_head() {
  printf 'head output\n' >"$repo/h.txt"
  git -C "$repo" add h.txt
  git -C "$repo" commit -qm "01-head: landed"
  head_commit="$(git -C "$repo" rev-parse HEAD)"
}

write_pair_state() {
  local tail_pid="${1:-null}"
  cat >"$repo/state/state.yaml" <<EOF
{"current_stage":"02-tail","pipeline_pair":{"head":"01-head","tail":"02-tail","phase":"tail-running","rebase_required":true,"base_tip":"$old_base"},"stages":[
 {"id":"01-head","status":"completed","commit":"$head_commit","base_branch":"dev","worker_pid":null,"verifier_pid":null},
 {"id":"02-tail","status":"in_progress","base_branch":"dev","worker_pid":$tail_pid,"verifier_pid":null,"verifier_artefact":null}
]}
EOF
}

stash_ref() { git -C "$repo" rev-parse -q --verify refs/stash 2>/dev/null || printf 'none\n'; }
stash_count() { git -C "$repo" stash list | wc -l | tr -d ' '; }
pair_phase() { state_json "$repo/state/state.yaml" | jq -r '.pipeline_pair.phase // empty'; }
tail_status() { state_json "$repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-tail") | .status'; }
file_is() { [[ -f "$1" && "$(cat "$1")" == "$2" ]]; }
other_refs() { git -C "$repo" for-each-ref --format='%(refname) %(objectname)' | grep -v '^refs/heads/' || true; }
state_link_intact() { assert_run_worktree_state_link "$repo" 02-tail; }

# Case 1: the review's reproduction. The tail worker self-committed and left
# nothing uncommitted; the operator holds a stash in the main checkout.
new_fixture commit-and-operator-stash
operator_stash
op_stash_before="$(stash_ref)"
[[ "$op_stash_before" != none ]] || fail "fixture: no operator stash recorded"
printf 'tail work\n' >"$tail_work/t.txt"
git -C "$tail_work" add t.txt
git -C "$tail_work" commit -qm "worker self-commit"
land_head
write_pair_state
refs_before="$(other_refs)"
rc=0
pipeline_prepare_tail_rebase "$repo" "$repo/state/state.yaml" 02-tail || rc=$?
[[ "$(stash_ref)" == "$op_stash_before" ]] \
  || fail "the operator's stash was popped or replaced (refs/stash $(stash_ref), was $op_stash_before)"
[[ "$(stash_count)" == 1 ]] || fail "the shared stash list changed ($(stash_count) entries, want 1)"
[[ ! -e "$tail_work/op.txt" ]] || fail "the operator's stashed op.txt landed in the tail worktree"
[[ "$rc" == 0 ]] || fail "a file-disjoint tail with a self-commit was not rebased (rc=$rc)"
[[ "$(pair_phase)" == tail-rebased ]] || fail "pair phase is '$(pair_phase)', want tail-rebased"
git -C "$repo" log --format=%s dev..autometta/02-tail | grep -qx 'worker self-commit' \
  || fail "the tail worker's commit is not on the run branch above dev"
git -C "$repo" merge-base --is-ancestor "$head_commit" autometta/02-tail \
  || fail "the run branch was not rebased onto the landed head"
file_is "$tail_work/t.txt" 'tail work' || fail "the tail's committed t.txt is missing from the tail worktree"
file_is "$tail_work/h.txt" 'head output' || fail "the landed head's h.txt is missing from the tail worktree"
[[ "$(other_refs)" == "$refs_before" ]] || fail "the rebase left a ref behind outside refs/heads"
state_link_intact || fail "the tail worktree's state symlink did not survive the rebase"

# Case 2: the tail worker self-committed and also left uncommitted edits and
# an untracked file, with the operator's stash present.
new_fixture commit-and-wip
operator_stash
op_stash_before="$(stash_ref)"
[[ "$op_stash_before" != none ]] || fail "fixture: no operator stash recorded"
printf 'tail work\n' >"$tail_work/t.txt"
git -C "$tail_work" add t.txt
git -C "$tail_work" commit -qm "worker self-commit"
printf 'tail edited\n' >"$tail_work/tail.txt"
printf 'untracked work\n' >"$tail_work/u.txt"
land_head
write_pair_state
rc=0
pipeline_prepare_tail_rebase "$repo" "$repo/state/state.yaml" 02-tail || rc=$?
[[ "$(stash_ref)" == "$op_stash_before" ]] \
  || fail "commit-and-wip: the operator's stash was popped or replaced (refs/stash $(stash_ref), was $op_stash_before)"
[[ "$(stash_count)" == 1 ]] || fail "commit-and-wip: the shared stash list changed ($(stash_count) entries, want 1)"
[[ ! -e "$tail_work/op.txt" ]] || fail "commit-and-wip: the operator's stashed op.txt landed in the tail worktree"
[[ "$rc" == 0 ]] || fail "commit-and-wip: a file-disjoint tail with a self-commit was not rebased (rc=$rc)"
[[ "$(pair_phase)" == tail-rebased ]] || fail "commit-and-wip: pair phase is '$(pair_phase)', want tail-rebased"
git -C "$repo" log --format=%s dev..autometta/02-tail | grep -qx 'worker self-commit' \
  || fail "commit-and-wip: the tail worker's commit is not on the run branch above dev"
git -C "$repo" merge-base --is-ancestor "$head_commit" autometta/02-tail \
  || fail "commit-and-wip: the run branch was not rebased onto the landed head"
file_is "$tail_work/h.txt" 'head output' || fail "commit-and-wip: the landed head's h.txt is missing from the tail worktree"
file_is "$tail_work/t.txt" 'tail work' || fail "commit-and-wip: the tail's committed t.txt is missing from the tail worktree"
file_is "$tail_work/tail.txt" 'tail edited' || fail "commit-and-wip: the tail's uncommitted edit to tail.txt was lost"
file_is "$tail_work/u.txt" 'untracked work' || fail "commit-and-wip: the tail's untracked u.txt was lost"
state_link_intact || fail "commit-and-wip: the tail worktree's state symlink did not survive the rebase"

# Case 2b: committed work only, and no stash anywhere in the repo.
new_fixture commit-only
printf 'tail work\n' >"$tail_work/t.txt"
git -C "$tail_work" add t.txt
git -C "$tail_work" commit -qm "worker self-commit"
land_head
write_pair_state
rc=0
pipeline_prepare_tail_rebase "$repo" "$repo/state/state.yaml" 02-tail || rc=$?
[[ "$rc" == 0 ]] || fail "a committed-only tail with no stash in the repo was not rebased (rc=$rc)"
[[ "$(pair_phase)" == tail-rebased ]] || fail "committed-only: pair phase is '$(pair_phase)', want tail-rebased"
git -C "$repo" log --format=%s dev..autometta/02-tail | grep -qx 'worker self-commit' \
  || fail "committed-only: the tail worker's commit is not on the run branch above dev"
file_is "$tail_work/t.txt" 'tail work' || fail "committed-only: t.txt is missing from the tail worktree"
file_is "$tail_work/h.txt" 'head output' || fail "committed-only: h.txt is missing from the tail worktree"
[[ "$(stash_ref)" == none ]] || fail "committed-only: the rebase left an entry on the shared refs/stash"

# Case 3 (regression): the ordinary tail, uncommitted work only, with an
# operator stash present. The tail ends exactly on dev with its work restored.
new_fixture uncommitted
operator_stash
op_stash_before="$(stash_ref)"
printf 'tail edited\n' >"$tail_work/tail.txt"
printf 'untracked work\n' >"$tail_work/u.txt"
land_head
write_pair_state
rc=0
pipeline_prepare_tail_rebase "$repo" "$repo/state/state.yaml" 02-tail || rc=$?
[[ "$rc" == 0 ]] || fail "uncommitted: the ordinary tail was not rebased (rc=$rc)"
[[ "$(pair_phase)" == tail-rebased ]] || fail "uncommitted: pair phase is '$(pair_phase)', want tail-rebased"
[[ "$(git -C "$tail_work" rev-parse HEAD)" == "$head_commit" ]] \
  || fail "uncommitted: the tail worktree HEAD is not the landed dev tip"
file_is "$tail_work/tail.txt" 'tail edited' || fail "uncommitted: the edit to tail.txt was lost"
file_is "$tail_work/u.txt" 'untracked work' || fail "uncommitted: untracked u.txt was lost"
file_is "$tail_work/h.txt" 'head output' || fail "uncommitted: h.txt is missing from the tail worktree"
[[ "$(stash_ref)" == "$op_stash_before" && "$(stash_count)" == 1 ]] \
  || fail "uncommitted: the operator's stash changed"
[[ ! -e "$tail_work/op.txt" ]] || fail "uncommitted: op.txt landed in the tail worktree"
state_link_intact || fail "uncommitted: the tail worktree's state symlink did not survive the rebase"

# Case 4: the rebase cannot complete. dev moved past the head with a commit
# that conflicts with the tail's own commit (file-disjoint from the head, so
# the overlap check passes). The tail must escalate with its branch tip and
# its uncommitted work exactly as the worker left them.
new_fixture conflict
operator_stash
op_stash_before="$(stash_ref)"
printf 'tail committed\n' >"$tail_work/tail.txt"
git -C "$tail_work" add tail.txt
git -C "$tail_work" commit -qm "worker self-commit"
tail_tip_before="$(git -C "$tail_work" rev-parse HEAD)"
printf 'w edited\n' >"$tail_work/w.txt"
printf 'untracked work\n' >"$tail_work/u.txt"
land_head
printf 'operator tail\n' >"$repo/tail.txt"
git -C "$repo" commit -qam "operator: direct edit after the head landed"
write_pair_state
rc=0
pipeline_prepare_tail_rebase "$repo" "$repo/state/state.yaml" 02-tail || rc=$?
[[ "$rc" == 1 ]] || fail "conflict: a tail rebase that cannot complete returned rc=$rc, want 1"
[[ "$(pair_phase)" == controller-escalation ]] \
  || fail "conflict: pair phase is '$(pair_phase)', want controller-escalation"
[[ "$(tail_status)" == stalled ]] || fail "conflict: tail status is '$(tail_status)', want stalled"
[[ "$(git -C "$repo" rev-parse autometta/02-tail)" == "$tail_tip_before" ]] \
  || fail "conflict: the run branch tip moved off the tail worker's commit"
[[ "$(git -C "$tail_work" rev-parse HEAD)" == "$tail_tip_before" ]] \
  || fail "conflict: the tail worktree HEAD moved off the tail worker's commit"
file_is "$tail_work/tail.txt" 'tail committed' || fail "conflict: the tail's committed tail.txt was not restored"
file_is "$tail_work/w.txt" 'w edited' || fail "conflict: the tail's uncommitted edit to w.txt was lost"
file_is "$tail_work/u.txt" 'untracked work' || fail "conflict: the tail's untracked u.txt was lost"
[[ -z "$(git -C "$tail_work" rev-parse -q --verify REBASE_HEAD 2>/dev/null || true)" ]] \
  || fail "conflict: a rebase was left in progress in the tail worktree"
[[ "$(stash_ref)" == "$op_stash_before" && "$(stash_count)" == 1 ]] \
  || fail "conflict: the operator's stash changed"
[[ ! -e "$tail_work/op.txt" ]] || fail "conflict: op.txt landed in the tail worktree"

# Case 4b: the rebase succeeds but the saved work cannot be re-applied. dev
# moved past the head with a commit to the file the tail edited without
# committing. The tail must escalate on its recorded HEAD with its edit back.
new_fixture reapply-conflict
operator_stash
op_stash_before="$(stash_ref)"
printf 'tail edited\n' >"$tail_work/tail.txt"
printf 'untracked work\n' >"$tail_work/u.txt"
land_head
printf 'operator tail\n' >"$repo/tail.txt"
git -C "$repo" commit -qam "operator: direct edit after the head landed"
write_pair_state
refs_before="$(other_refs)"
rc=0
pipeline_prepare_tail_rebase "$repo" "$repo/state/state.yaml" 02-tail || rc=$?
[[ "$rc" == 1 ]] || fail "reapply-conflict: a tail whose work cannot be re-applied returned rc=$rc, want 1"
[[ "$(pair_phase)" == controller-escalation ]] \
  || fail "reapply-conflict: pair phase is '$(pair_phase)', want controller-escalation"
[[ "$(git -C "$tail_work" rev-parse HEAD)" == "$old_base" ]] \
  || fail "reapply-conflict: the tail worktree HEAD is not back on its recorded HEAD"
file_is "$tail_work/tail.txt" 'tail edited' || fail "reapply-conflict: the tail's uncommitted edit to tail.txt was not restored"
file_is "$tail_work/u.txt" 'untracked work' || fail "reapply-conflict: the tail's untracked u.txt was not restored"
[[ "$(stash_ref)" == "$op_stash_before" && "$(stash_count)" == 1 ]] \
  || fail "reapply-conflict: the shared stash list changed ($(stash_count) entries, want the operator's 1)"
[[ "$(other_refs)" == "$refs_before" ]] || fail "reapply-conflict: a ref was left behind outside refs/heads"
state_link_intact || fail "reapply-conflict: the tail worktree's state symlink did not survive"

# Case 5 (regression): a live tail worker defers the rebase and touches nothing.
new_fixture live-worker
printf 'tail edited\n' >"$tail_work/tail.txt"
land_head
sleep 300 &
live_pid=$!
smoke_pids+=("$live_pid")
write_pair_state "$live_pid"
tail_tip_before="$(git -C "$tail_work" rev-parse HEAD)"
rc=0
pipeline_prepare_tail_rebase "$repo" "$repo/state/state.yaml" 02-tail || rc=$?
[[ "$rc" == 2 ]] || fail "live-worker: a running tail worker did not defer (rc=$rc, want 2)"
[[ "$(git -C "$tail_work" rev-parse HEAD)" == "$tail_tip_before" ]] \
  || fail "live-worker: the tail worktree moved while its worker was running"
file_is "$tail_work/tail.txt" 'tail edited' || fail "live-worker: the running worker's edit was touched"
[[ "$(pair_phase)" == tail-running ]] || fail "live-worker: pair phase changed to '$(pair_phase)'"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

# The shared stash is never touched, not only left as found: the function body
# names none of the commands that read or move refs/stash.
rebase_body="$(declare -f pipeline_prepare_tail_rebase)"
[[ -n "$rebase_body" ]] || fail "pipeline_prepare_tail_rebase is not defined"
for forbidden in 'refs/stash' 'stash push' 'stash pop' 'stash drop' 'stash list' 'stash save'; do
  [[ "$rebase_body" != *"$forbidden"* ]] || fail "pipeline_prepare_tail_rebase still uses '$forbidden'"
done

# AUTOMETTA-CONTRACT-END

printf 'PASS: tail-rebase-stash-smoke\n'

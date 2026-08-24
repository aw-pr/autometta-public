#!/usr/bin/env bash
# state-branch-smoke.sh: offline check that a tick keeps its hands off the
# shared working tree, and that the loop still snapshots its state.
#
# The defect this guards (card 39): commit_state_branch ran
# `git checkout -B phat-controller/state` in repo_root, committed, and
# restored the operator's branch from an EXIT trap. repo_root is the tree the
# operator works in and the fleet job opens that window roughly 288 times a
# day per subscriber, so "the window is short" is not a safety argument.
#
# On 2026-08-23, retiring card 36 produced commit 2d4dc08, authored against
# dev, landed on phat-controller/state. It was invisible to
# `git push origin dev` ("Everything up-to-date"), and the next tick's
# `checkout -B` would have reset the ref past it and made it unreachable. It
# survived because it was noticed within minutes and cherry-picked back as
# 1efd82a. The reflog shows four HEAD moves between the two branches inside
# two minutes, one per tick.
#
# Everything below runs against throwaway git repositories in a temp dir.
# No auth, no network, no agent dispatch, no spend. It asserts:
#
#   1. The race is real and this harness detects it: replaying the pre-fix
#      implementation with the window held open lands the operator's commit
#      on phat-controller/state. This is the control -- without it, test 2
#      would pass on a script that does nothing at all.
#   2. The shipped implementation loses the same race by not having it: 40
#      snapshots interleaved with operator commits, every commit on the
#      branch its author was standing on.
#   3. repo_root's HEAD, index, working tree and reflog are untouched by a
#      snapshot.
#   4. The snapshot is durable and honest: it holds the current state.yaml
#      and budget.json, it names what it captured in the commit body, and it
#      does not commit again when nothing changed.
#   5. A full tick, including one that writes state, leaves repo_root's HEAD
#      exactly where it was.
#   6. A fast-forward of the base branch does not check base out in
#      repo_root.
#   7. The reaper removes a finished stage's worktree, and refuses to remove
#      one that is in_progress, dirty, or awaiting integration.
#   8. A PASS whose base branch moved between dispatch and verdict records
#      the outstanding merge on the stage, where a person or a panel will
#      see it, rather than only in HANDOFF.md.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# tick.sh resolves controller_home, and therefore its log path, once at source
# time. Point it at a sandbox home BEFORE sourcing: every later log() from a
# sourced function writes there rather than into the operator's real
# ~/.phat-controller. Setting the variable after the source has no effect on
# those calls, which is what made sections 8 onwards depend on $HOME being
# writable -- passing on the operator's machine and failing in a sandboxed
# verifier, the worst way round for a test whose whole job is to be run by one.
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
export PHAT_CONTROLLER_HOME="$tmp_root/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/subscribers" "$PHAT_CONTROLLER_HOME/log"

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

fail=0

check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2
    fail=1
  fi
}

eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }

# A subscriber-shaped repo: dev checked out, state/ gitignored exactly as
# every real subscriber has it, one completed stage on record.
make_repo() {
  local name="$1"
  local dir="$tmp_root/$name"
  mkdir -p "$dir/state/handoffs" "$dir/state/verifiers" "$dir/state/logs"
  (
    cd "$dir"
    git init -q -b dev .
    git config user.email smoke@local
    git config user.name "smoke"
    git config commit.gpgsign false
    printf 'state/**\n!state/handoffs/\n!state/handoffs/.gitkeep\n' > .gitignore
    touch state/handoffs/.gitkeep
    printf 'seed\n' > README.md
    git add -A
    git commit -qm 'seed'
  )
  cat > "$dir/state/state.yaml" <<YAML
version: 1
current_stage: null
last_tick_at: "2026-08-23T00:00:00Z"
tick_count: 1
clock_tick_budget_remaining: 399
stages:
  - id: 01-seed
    status: completed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
YAML
  cat > "$dir/state/budget.json" <<JSON
{
  "version": 1,
  "token_cap_total": 1000000,
  "tokens_spent": 0,
  "wall_clock_cap_seconds": 86400,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 400,
  "clock_ticks_used": 1,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "window_started_at": "$(date -u +%F)"
}
JSON
  printf '%s' "$dir"
}

# One operator commit, as a person at a terminal makes it.
operator_commit() {
  local dir="$1" text="$2"
  printf '%s\n' "$text" >> "$dir/README.md"
  git -C "$dir" commit -q -am "operator: $text"
  git -C "$dir" rev-parse HEAD
}

# Which local branches contain a commit.
branches_containing() {
  git -C "$1" branch --format='%(refname:short)' --contains "$2" 2>/dev/null | tr '\n' ' '
}

# ---------------------------------------------------------------------------
printf '== 1. the pre-fix implementation, with the window held open ==\n' >&2

control="$(make_repo control)"
ready="$tmp_root/ready"
go="$tmp_root/go"

# The pre-2026-08-23 commit_state_branch verbatim, with one addition: it
# blocks in the middle of the window instead of racing through it, so the
# control is deterministic rather than a coin toss on scheduling.
checkout_based_snapshot() (
  cd "$control"
  original_branch="$(git rev-parse --abbrev-ref HEAD)"
  trap 'git checkout "$original_branch" >/dev/null 2>&1 || true' EXIT
  git checkout -B phat-controller/state >/dev/null 2>&1
  : > "$ready"
  while [[ ! -f "$go" ]]; do sleep 0.05; done
  git add state/state.yaml state/budget.json 2>/dev/null || true
  if ! git diff --cached --quiet; then
    git commit -qm "phat-controller: tick state update" >/dev/null 2>&1
  fi
)

checkout_based_snapshot &
control_pid=$!
while [[ ! -f "$ready" ]]; do sleep 0.05; done
control_sha="$(operator_commit "$control" 'landed during a pre-fix tick')"
: > "$go"
wait "$control_pid" || true

printf '  the operator committed onto: %s\n' "$(branches_containing "$control" "$control_sha")" >&2
check "the pre-fix window puts an operator commit on phat-controller/state" \
  "$(eq "phat-controller/state " "$(branches_containing "$control" "$control_sha")")"
check "and dev never sees it, which is how it goes unnoticed" \
  "$(git -C "$control" merge-base --is-ancestor "$control_sha" dev 2>/dev/null && printf 'dev contains it\n' || printf 'ok\n')"

# ---------------------------------------------------------------------------
printf '== 2. the same race, against the shipped implementation ==\n' >&2

live="$(make_repo live)"
(
  for i in $(seq 1 40); do
    printf 'tick %s\n' "$i" > "$live/state/state.yaml.tmp"
    mv "$live/state/state.yaml.tmp" "$live/state/counter"
    commit_state_branch "$live"
  done
) &
snapshot_pid=$!

stray=""
for i in $(seq 1 8); do
  sha="$(operator_commit "$live" "concurrent commit $i")"
  on="$(branches_containing "$live" "$sha")"
  [[ "$on" == "dev " ]] || stray="${stray}${sha} on [${on}]; "
  head_branch="$(git -C "$live" rev-parse --abbrev-ref HEAD)"
  [[ "$head_branch" == "dev" ]] || stray="${stray}HEAD moved to ${head_branch}; "
done
wait "$snapshot_pid" || true

check "every commit made during 40 snapshots landed on dev" "$(eq "" "$stray")"
check "repo_root is still on dev afterwards" \
  "$(eq dev "$(git -C "$live" rev-parse --abbrev-ref HEAD)")"
check "the snapshot ref advanced while that happened" \
  "$(git -C "$live" rev-parse -q --verify autometta/state >/dev/null && printf 'ok\n' || printf 'no snapshot ref\n')"

# ---------------------------------------------------------------------------
printf '== 3. HEAD, index, working tree and reflog are untouched ==\n' >&2

quiet="$(make_repo quiet)"
before_branch="$(git -C "$quiet" rev-parse --abbrev-ref HEAD)"
before_head="$(git -C "$quiet" rev-parse HEAD)"
before_status="$(git -C "$quiet" status --porcelain)"
before_reflog="$(git -C "$quiet" reflog | wc -l | tr -d ' ')"
before_index="$quiet/.git/index"
before_index_sum="$(shasum "$before_index" 2>/dev/null | awk '{print $1}' || printf 'none')"

commit_state_branch "$quiet"

check "HEAD still names the same branch" \
  "$(eq "$before_branch" "$(git -C "$quiet" rev-parse --abbrev-ref HEAD)")"
check "HEAD still points at the same commit" \
  "$(eq "$before_head" "$(git -C "$quiet" rev-parse HEAD)")"
check "the working tree is as it was" \
  "$(eq "$before_status" "$(git -C "$quiet" status --porcelain)")"
check "no HEAD reflog entries were written" \
  "$(eq "$before_reflog" "$(git -C "$quiet" reflog | wc -l | tr -d ' ')")"
check "repo_root's index was not rewritten" \
  "$(eq "$before_index_sum" "$(shasum "$before_index" 2>/dev/null | awk '{print $1}' || printf 'none')")"

# ---------------------------------------------------------------------------
printf '== 4. what the snapshot captures, and what it does not ==\n' >&2

check "state.yaml really is gitignored in the fixture, as in every subscriber" \
  "$(git -C "$quiet" check-ignore -q state/state.yaml && printf 'ok\n' || printf 'not ignored\n')"
check "the snapshot holds state.yaml anyway" \
  "$(eq "$(cat "$quiet/state/state.yaml")" "$(git -C "$quiet" show autometta/state:state/state.yaml 2>/dev/null || printf 'absent')")"
check "the snapshot holds budget.json" \
  "$(eq "$(cat "$quiet/state/budget.json")" "$(git -C "$quiet" show autometta/state:state/budget.json 2>/dev/null || printf 'absent')")"
check "the snapshot does not hold worker logs" \
  "$(git -C "$quiet" ls-tree -r --name-only autometta/state | grep -q '^state/logs/' && printf 'logs captured\n' || printf 'ok\n')"
check "the commit body names what was captured" \
  "$(git -C "$quiet" log -1 --format=%b autometta/state | grep -q 'captured: state/state.yaml' && printf 'ok\n' || printf 'no captured: line\n')"

snapshot_count() { git -C "$1" rev-list --count autometta/state; }
before_count="$(snapshot_count "$quiet")"
commit_state_branch "$quiet"
check "an unchanged state does not add a commit" \
  "$(eq "$before_count" "$(snapshot_count "$quiet")")"
printf 'stages: [changed]\n' >> "$quiet/state/state.yaml"
commit_state_branch "$quiet"
check "a changed state does add one" \
  "$(eq "$((before_count + 1))" "$(snapshot_count "$quiet")")"

# ---------------------------------------------------------------------------
printf '== 5. a full tick leaves repo_root where it was ==\n' >&2

ticked="$(make_repo ticked)"
# A stage in flight whose worker died long ago: the tick stalls it, which
# rewrites state.yaml and budget.json without dispatching anything. That is
# a tick that writes state, with no agent, no auth and no spend.
cat > "$ticked/state/state.yaml" <<YAML
version: 1
current_stage: 02-stuck
last_tick_at: "2026-08-23T00:00:00Z"
tick_count: 1
clock_tick_budget_remaining: 399
stages:
  - id: 02-stuck
    status: in_progress
    started_at: "2020-01-01T00:00:00Z"
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
YAML

mkdir -p "$PHAT_CONTROLLER_HOME/subscribers"
cat > "$PHAT_CONTROLLER_HOME/subscribers/ticked.yaml" <<YAML
repo_path: "$ticked"
weight: 100
enabled: true
YAML
# tmux is stubbed out: the tick's viewer and its idle-session reaper are
# real side effects on the operator's terminal and have nothing to do with
# what is under test here.
mkdir -p "$tmp_root/stub"
printf '#!/bin/sh\nexit 0\n' > "$tmp_root/stub/tmux"
chmod +x "$tmp_root/stub/tmux"

tick_before_branch="$(git -C "$ticked" rev-parse --abbrev-ref HEAD)"
tick_before_head="$(git -C "$ticked" rev-parse HEAD)"
PATH="$tmp_root/stub:$PATH" "$script_dir/tick.sh" >/dev/null 2>&1 || true

check "the tick wrote state.yaml (the stalled stage was recorded)" \
  "$(eq stalled "$(yq -r '.stages[] | select(.id == "02-stuck") | .status' "$ticked/state/state.yaml")")"
check "repo_root's HEAD still names the same branch after a full tick" \
  "$(eq "$tick_before_branch" "$(git -C "$ticked" rev-parse --abbrev-ref HEAD)")"
check "repo_root's HEAD still points at the same commit" \
  "$(eq "$tick_before_head" "$(git -C "$ticked" rev-parse HEAD)")"
check "the tick's state.yaml reached the snapshot ref" \
  "$(eq "$(cat "$ticked/state/state.yaml")" "$(git -C "$ticked" show autometta/state:state/state.yaml 2>/dev/null || printf 'absent')")"
check "so did its budget.json" \
  "$(eq "$(cat "$ticked/state/budget.json")" "$(git -C "$ticked" show autometta/state:state/budget.json 2>/dev/null || printf 'absent')")"
# Not unset: tick.sh's log() defaults to $HOME/.phat-controller, and a tee
# failure there is fatal under set -e, so unsetting made the later sections
# depend on the operator's home being writable. They failed in a sandboxed
# verifier for that reason and passed on the operator's machine, which is the
# worst way round. Point at a second, empty controller home instead: later
# sections stay isolated from section 5's fake subscriber, and nothing outside
# the temporary tree is touched.
rm -f "$PHAT_CONTROLLER_HOME/subscribers/ticked.yaml"

# ---------------------------------------------------------------------------
printf '== 6. the fast-forward does not check base out in repo_root ==\n' >&2

ff="$(make_repo ff)"
git -C "$ff" branch -q sidebar
git -C "$ff" checkout -q sidebar
git -C "$ff" branch -q autometta/02-ff dev
ff_wt="$(worktree_path_for_stage "$ff" 02-ff)"
git -C "$ff" worktree add -q "$ff_wt" autometta/02-ff
printf 'stage output\n' > "$ff_wt/deliverable.txt"
git -C "$ff_wt" add deliverable.txt
git -C "$ff_wt" commit -qm '02-ff: worker output'
ff_tip="$(git -C "$ff" rev-parse autometta/02-ff)"

ff_result="$(finalize_run_worktree "$ff" 02-ff dev)"
check "an unmoved base fast-forwards" "$(eq merged "$ff_result")"
check "dev advanced to the run branch tip" \
  "$(eq "$ff_tip" "$(git -C "$ff" rev-parse dev)")"
check "repo_root stayed on the operator's branch" \
  "$(eq sidebar "$(git -C "$ff" rev-parse --abbrev-ref HEAD)")"

git -C "$ff" checkout -q dev
printf 'operator moved base\n' >> "$ff/README.md"
git -C "$ff" commit -q -am 'operator: base moves'
git -C "$ff" checkout -q sidebar
printf 'more stage output\n' >> "$ff_wt/deliverable.txt"
git -C "$ff_wt" commit -qam '02-ff: more output'
check "a moved base reports diverged rather than merging" \
  "$(eq diverged "$(finalize_run_worktree "$ff" 02-ff dev)")"

# ---------------------------------------------------------------------------
printf '== 7. the reaper leaves what it should and collects the rest ==\n' >&2

reap="$(make_repo reap)"
cat > "$reap/state/state.yaml" <<YAML
version: 1
current_stage: 12-live
last_tick_at: "2026-08-23T00:00:00Z"
tick_count: 1
clock_tick_budget_remaining: 399
stages:
  - id: 10-done
    status: completed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    base_branch: dev
  - id: 11-failed
    status: verifier_failed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    base_branch: dev
  - id: 12-live
    status: in_progress
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    base_branch: dev
  - id: 13-unmerged
    status: completed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    base_branch: dev
  - id: 14-real-state-dir
    status: completed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    base_branch: dev
YAML

for stage in 10-done 11-failed 12-live 13-unmerged 14-real-state-dir; do
  ensure_run_worktree "$reap" "$stage" dev >/dev/null
done
# 11-failed holds the worker's uncommitted diff, which is the whole of what
# an operator inspects after a FAIL.
printf 'work in progress\n' > "$(worktree_path_for_stage "$reap" 11-failed)/wip.txt"
# 13-unmerged holds a commit that is not on dev.
unmerged_wt="$(worktree_path_for_stage "$reap" 13-unmerged)"
printf 'passed work\n' > "$unmerged_wt/deliverable.txt"
git -C "$unmerged_wt" add deliverable.txt
git -C "$unmerged_wt" commit -qm '13-unmerged: worker output'

# 14-real-state-dir replaces the state symlink with a real directory holding a
# modified tracked file. The dirty check used to exclude the whole state path
# rather than the symlink artefact alone, so this content was invisible and the
# worktree was reaped with it inside.
real_state_wt="$(worktree_path_for_stage "$reap" 14-real-state-dir)"
rm -f "$real_state_wt/state"
git -C "$real_state_wt" checkout -q -- state 2>/dev/null || mkdir -p "$real_state_wt/state/handoffs"
# .gitkeep, because the subscriber gitignore is state/** with that one file
# un-ignored. It is the only tracked path under state/, so it is the only one
# whose modification git will report at all.
printf 'operator content nobody else has\n' >> "$real_state_wt/state/handoffs/.gitkeep"

reap_out="$("$script_dir/reap-worktrees.sh" "$reap" 2>&1 || true)"
printf '%s\n' "$reap_out" | sed 's/^/  | /' >&2

check "a finished stage's worktree is removed" \
  "$([[ -d "$(worktree_path_for_stage "$reap" 10-done)" ]] && printf 'still there\n' || printf 'ok\n')"
check "a worktree with uncommitted work is left standing" \
  "$([[ -d "$(worktree_path_for_stage "$reap" 11-failed)" ]] && printf 'ok\n' || printf 'removed\n')"
check "and reported rather than removed silently" \
  "$(printf '%s' "$reap_out" | grep -q '11-failed: uncommitted work' && printf 'ok\n' || printf 'not reported\n')"
check "an in_progress stage is never touched" \
  "$([[ -d "$(worktree_path_for_stage "$reap" 12-live)" ]] && printf 'ok\n' || printf 'removed\n')"
check "an unmerged run branch is left standing" \
  "$([[ -d "$unmerged_wt" ]] && printf 'ok\n' || printf 'removed\n')"
check "and recorded as awaiting integration in state.yaml" \
  "$(eq awaiting "$(yq -r '.stages[] | select(.id == "13-unmerged") | .integration.state' "$reap/state/state.yaml")")"
check "the state symlink alone is not read as uncommitted work" \
  "$(printf '%s' "$reap_out" | grep -q '10-done: uncommitted work' && printf '10-done misread\n' || printf 'ok\n')"
check "a real state directory with modified content is not forgiven" \
  "$(printf '%s' "$reap_out" | grep -q '14-real-state-dir: uncommitted work' && printf 'ok\n' || printf '14-real-state-dir was not reported\n')"
check "and its worktree survives" \
  "$(test -d "$real_state_wt" && printf 'ok\n' || printf 'reaped with uncommitted content inside\n')"

# Once a person merges it, the next sweep closes the record and collects the
# worktree. This is the whole reason the reaper does not simply skip
# 'awaiting' forever.
git -C "$reap" merge -q --no-edit autometta/13-unmerged
reap_out2="$("$script_dir/reap-worktrees.sh" "$reap" 2>&1 || true)"
printf '%s\n' "$reap_out2" | sed 's/^/  | /' >&2
check "a merged-by-hand stage is closed out to merged" \
  "$(eq merged "$(yq -r '.stages[] | select(.id == "13-unmerged") | .integration.state' "$reap/state/state.yaml")")"
check "and its worktree is then collected" \
  "$([[ -d "$unmerged_wt" ]] && printf 'still there\n' || printf 'ok\n')"

# ---------------------------------------------------------------------------
printf '== 8. a PASS whose base moved records the outstanding merge ==\n' >&2

# One PASS through the real verdict path, with the operator committing to
# base between dispatch and verdict. That is the common case in an active
# session: both stages that took this path on 2026-08-23 got there because
# the orchestrator had committed to dev in between.
make_passing_stage() {
  local dir="$1"
  cat > "$dir/state/state.yaml" <<YAML
version: 1
current_stage: 20-pass
last_tick_at: "2026-08-23T00:00:00Z"
tick_count: 1
clock_tick_budget_remaining: 399
stages:
  - id: 20-pass
    status: in_progress
    started_at: "2026-08-23T00:00:00Z"
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    base_branch: dev
    verifier_artefact: state/verifiers/20-pass.json
YAML
  printf '{"overall":"PASS","headline":"the thing works"}\n' > "$dir/state/verifiers/20-pass.json"
  local wt
  wt="$(ensure_run_worktree "$dir" 20-pass dev)"
  printf 'deliverable\n' > "$wt/out.txt"
  printf '%s' "$wt"
}

moved="$(make_repo moved)"
moved_wt="$(make_passing_stage "$moved")"
printf '# Handoff\n' > "$moved/HANDOFF.md"
operator_commit "$moved" 'base moves between dispatch and verdict' >/dev/null
_process_verifier_artefact "$moved" "$moved/state/state.yaml" 20-pass state/verifiers/20-pass.json "" >/dev/null 2>&1

check "the stage completed" \
  "$(eq completed "$(yq -r '.stages[] | select(.id == "20-pass") | .status' "$moved/state/state.yaml")")"
check "and is recorded as awaiting integration, not silently done" \
  "$(eq awaiting "$(yq -r '.stages[] | select(.id == "20-pass") | .integration.state' "$moved/state/state.yaml")")"
check "the record names the branch to merge and where to" \
  "$(eq "autometta/20-pass dev" "$(yq -r '.stages[] | select(.id == "20-pass") | .integration.run_branch + " " + .integration.base_branch' "$moved/state/state.yaml")")"
check "the worker's commit is on the run branch" \
  "$(eq "20-pass: the thing works" "$(git -C "$moved" log -1 --format=%s autometta/20-pass)")"
check "the run worktree is left standing for the merge" \
  "$([[ -d "$moved_wt" ]] && printf 'ok\n' || printf 'removed\n')"
check "repo_root is still on the operator's branch" \
  "$(eq dev "$(git -C "$moved" rev-parse --abbrev-ref HEAD)")"
check "HANDOFF.md still gets its line too" \
  "$(grep -q 'moved since dispatch' "$moved/HANDOFF.md" && printf 'ok\n' || printf 'no handoff line\n')"

# The other half of the same path: base did not move, so it merges and the
# record says there is nothing outstanding.
still="$(make_repo still)"
still_wt="$(make_passing_stage "$still")"
_process_verifier_artefact "$still" "$still/state/state.yaml" 20-pass state/verifiers/20-pass.json "" >/dev/null 2>&1

check "an unmoved base merges and records merged" \
  "$(eq merged "$(yq -r '.stages[] | select(.id == "20-pass") | .integration.state' "$still/state/state.yaml")")"
check "dev carries the worker's commit" \
  "$(eq "20-pass: the thing works" "$(git -C "$still" log -1 --format=%s dev)")"
check "and the worktree is gone" \
  "$([[ -d "$still_wt" ]] && printf 'still there\n' || printf 'ok\n')"

# ---------------------------------------------------------------------------
if (( fail )); then
  printf '\nstate-branch-smoke: FAIL\n' >&2
  exit 1
fi
printf '\nstate-branch-smoke: all checks passed\n' >&2

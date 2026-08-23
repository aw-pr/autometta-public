#!/usr/bin/env bash
# reap-worktrees.sh: collect the run worktrees nobody came back for.
#
# Worktree-per-run dispatch cuts ../<repo>-run-<stage> for every stage and
# two paths remove one: the ff-merge teardown in tick.sh, and a re-queue.
# A stage that neither completed cleanly nor was re-queued left its worktree
# standing forever. On 2026-08-23 that was every stage that PASSed while the
# operator had committed to the base branch mid-session, which is the normal
# condition during an active session rather than an edge case.
#
# What this will not do, in order of how much it would cost to get wrong:
#
#   1. A stage that is in_progress owns its worktree. Never touched.
#   2. A worktree holding uncommitted work is reported, never removed. On a
#      verifier FAIL the worker's diff is uncommitted by design and is the
#      whole of what the operator inspects. The one exception is the known
#      state/ symlink artefact -- dispatch replaces the tracked state/ dir
#      with a symlink to the shared one, which shows up as two deletions and
#      one untracked path in every run worktree -- so the check excludes the
#      'state' pathspec exactly as the PASS commit path does.
#   3. A run branch holding commits that are not on the base branch is work
#      awaiting integration. It is reported and the stage's .integration
#      record is backfilled so `autometta status` shows it, but the worktree
#      and branch stay. Removing them would delete the only local copy of a
#      passed stage's commit.
#   4. A worktree whose stage is not in state.yaml at all is reported, not
#      removed. Something else made it; it is not ours to collect.
#
# What it does remove: a worktree whose stage is finished with it -- clean
# tree, run branch fully contained in base (or gone) -- via
# `requeue-stage.sh --worktree-only`, the one implementation of that removal.
# When the containment check shows a human has since merged an 'awaiting'
# stage, the record is closed out to 'merged' before the worktree goes.
#
# Usage: reap-worktrees.sh <repo-root> [--dry-run]
#
# Prints one line per worktree it acts on or reports, and nothing for the
# ones it silently leaves alone. Called after every tick by
# sweep_repo_retention, where it is best-effort housekeeping and never a
# gate; run it by hand with --dry-run to see what it would do.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tick.sh is the home of state_apply_json (with its read/write guards),
# the run-branch and worktree path conventions, and the integration record
# helpers. Sourcing it is deliberate reuse: a second copy of any of those
# would drift, and the state writer is the last thing that should have two
# implementations. Sourcing does not fire the tick loop.
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

usage() { sed -n '2,40p' "$0"; exit 2; }

[[ $# -ge 1 && $# -le 2 ]] || usage
repo_root="$(cd "$1" 2>/dev/null && pwd)" || { printf 'reap: no such repo root: %s\n' "$1" >&2; exit 2; }
dry_run=false
if [[ "${2:-}" == "--dry-run" ]]; then
  dry_run=true
elif [[ -n "${2:-}" ]]; then
  usage
fi

state_yaml="$repo_root/state/state.yaml"
[[ -f "$state_yaml" ]] || { printf 'reap: no state/state.yaml in %s\n' "$repo_root" >&2; exit 2; }
for tool in yq jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'reap: %s is required\n' "$tool" >&2; exit 2; }
done

say() { printf 'reap: %s\n' "$1"; }

repo_name="$(basename "$repo_root")"
repo_root_phys="$(cd "$repo_root" && pwd -P)"
state_snapshot="$(mktemp)"
trap 'rm -f "$state_snapshot"' EXIT
state_json "$state_yaml" > "$state_snapshot" 2>/dev/null || : > "$state_snapshot"
if [[ ! -s "$state_snapshot" ]]; then
  printf 'reap: %s unreadable; leaving every worktree alone\n' "$state_yaml" >&2
  exit 2
fi

stage_field() {
  jq -r --arg id "$1" --arg f "$2" '.stages[] | select(.id == $id) | .[$f] // "" | tostring' \
    "$state_snapshot" 2>/dev/null || printf ''
}

current_stage="$(jq -r '.current_stage // ""' "$state_snapshot" 2>/dev/null || printf '')"

# Registered-but-gone worktrees are administrative litter with no directory
# behind them; git's own prune is the right tool and removes nothing on disk.
git -C "$repo_root" worktree prune >/dev/null 2>&1 || true

consider() {
  local work_dir="$1"
  local stage_id="${work_dir##*/}"
  stage_id="${stage_id#${repo_name}-run-}"
  validate_stage_id "$stage_id" || { say "${work_dir}: not a stage-shaped run worktree, left standing"; return 0; }

  local status integration_state base_branch run_branch
  status="$(stage_field "$stage_id" status)"
  if [[ -z "$status" ]]; then
    say "${stage_id}: no such stage in state.yaml, left standing (${work_dir})"
    return 0
  fi
  if [[ "$status" == "in_progress" || "$stage_id" == "$current_stage" ]]; then
    return 0
  fi

  # A status that cannot be read is not a clean status. Report rather than
  # guess: an unreadable worktree is exactly the case where removing it
  # could throw away something nobody can see.
  # Exclude state only when it is the known artefact: a symlink into
  # repo_root, as card 29's dispatch makes it, whose shadowed tracked files
  # git reports as deleted. A real state directory is ordinary content, and
  # excluding it wholesale hid modified tracked files from this check and let
  # the worktree be reaped with them in it. docs/phat-controller.md promises
  # only the symlink is forgiven, so forgive only the symlink.
  local -a dirt_pathspec=( . )
  if [[ -L "$work_dir/state" ]]; then
    dirt_pathspec+=( ':(exclude)state' )
  fi
  local dirt dirt_rc=0
  dirt="$(git -C "$work_dir" status --porcelain -- "${dirt_pathspec[@]}" 2>/dev/null)" || dirt_rc=$?
  if (( dirt_rc != 0 )); then
    say "${stage_id}: cannot read the worktree at ${work_dir} (git status exit ${dirt_rc}), left standing"
    return 0
  fi
  if [[ -n "$dirt" ]]; then
    say "${stage_id}: uncommitted work in ${work_dir}, left standing (status=${status})"
    return 0
  fi

  run_branch="$(run_branch_for_stage "$stage_id")"
  base_branch="$(stage_field "$stage_id" base_branch)"
  integration_state="$(jq -r --arg id "$stage_id" \
    '.stages[] | select(.id == $id) | .integration.state // ""' "$state_snapshot" 2>/dev/null || printf '')"

  local run_tip base_tip
  run_tip="$(git -C "$repo_root" rev-parse -q --verify "refs/heads/${run_branch}" 2>/dev/null || true)"
  if [[ -n "$run_tip" ]]; then
    if [[ -z "$base_branch" ]]; then
      say "${stage_id}: ${run_branch} exists but no base branch is recorded, left standing"
      return 0
    fi
    base_tip="$(git -C "$repo_root" rev-parse -q --verify "refs/heads/${base_branch}" 2>/dev/null || true)"
    if [[ -z "$base_tip" ]]; then
      say "${stage_id}: base branch ${base_branch} is gone, left standing"
      return 0
    fi
    if ! git -C "$repo_root" merge-base --is-ancestor "$run_tip" "$base_tip" 2>/dev/null; then
      if [[ "$integration_state" != "awaiting" ]]; then
        $dry_run || record_stage_integration "$state_yaml" "$stage_id" \
          "$(integration_record awaiting "$base_branch" "$run_branch" "$run_tip" "")"
        say "${stage_id}: ${run_branch} is not on ${base_branch}; recorded as awaiting integration"
      else
        say "${stage_id}: still awaiting integration into ${base_branch} (${run_branch})"
      fi
      return 0
    fi
    if [[ "$integration_state" == "awaiting" ]]; then
      $dry_run || record_stage_integration "$state_yaml" "$stage_id" \
        "$(integration_record merged "$base_branch" "$run_branch" "$run_tip" "")"
      say "${stage_id}: ${run_branch} is now contained in ${base_branch}; integration closed out"
    fi
  fi

  if $dry_run; then
    say "${stage_id}: would reap ${work_dir} (status=${status})"
    return 0
  fi
  remove_run_worktree "$repo_root" "$stage_id"
  say "${stage_id}: reaped ${work_dir} (status=${status})"
}

while IFS= read -r line; do
  case "$line" in
    "worktree "*) ;;
    *) continue ;;
  esac
  wt="${line#worktree }"
  [[ "$wt" != "$repo_root" && "$wt" != "$repo_root_phys" ]] || continue
  case "${wt##*/}" in
    "${repo_name}-run-"*) consider "$wt" ;;
  esac
done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null || true)

# Directories that look like run worktrees but are not registered as one:
# an interrupted `git worktree add`, or a copy someone made. Reported, never
# removed -- git does not know what is in them and neither do we.
#
# Compared on physical paths. git prints worktree paths with symlinks
# resolved, and on macOS a temp or home path routinely is one, so a textual
# comparison reports every live worktree as an orphan on every tick.
registered_paths="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' || true)"
for orphan in "$(dirname "$repo_root")/${repo_name}"-run-*; do
  [[ -d "$orphan" ]] || continue
  orphan_phys="$(cd "$orphan" 2>/dev/null && pwd -P)" || continue
  if ! printf '%s\n' "$registered_paths" | grep -qxF "$orphan_phys"; then
    say "${orphan##*/}: directory is not a registered worktree, left standing"
  fi
done

exit 0

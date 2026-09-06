#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_source="$(cd "$script_dir/.." && pwd)"
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

smoke_tmp="$(mktemp -d)"
export AUTOMETTA_CONTROLLER_HOME="$smoke_tmp/controller"
export PHAT_CONTROLLER_HOME="$AUTOMETTA_CONTROLLER_HOME"
# shellcheck source=./phat-controller.sh
source "$script_dir/phat-controller.sh"

cleanup() {
  rm -rf "$smoke_tmp"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3 (got '$1', want '$2')"
}

assert_true() {
  "$@" || fail "$*"
}

new_fixture() {
  local name="$1" stage_id="$2"
  fixture_repo="$smoke_tmp/$name"
  fixture_stage="$stage_id"
  fixture_work="$(worktree_path_for_stage "$fixture_repo" "$fixture_stage")"
  mkdir -p "$fixture_repo/state/verifiers"
  git -C "$fixture_repo" init -q -b dev
  git -C "$fixture_repo" config user.name Smoke
  git -C "$fixture_repo" config user.email smoke@local
  printf 'state/\n' >"$fixture_repo/.gitignore"
  printf 'base documentation\n' >"$fixture_repo/README.md"
  printf 'line-1\nline-2\nline-3\nline-4\nline-5\nline-6\nline-7\nline-8\nline-9\nline-10\nline-11\nline-12\nline-13\nline-14\nline-15\nline-16\nline-17\nline-18\nline-19\nline-20\n' >"$fixture_repo/shared.txt"
  git -C "$fixture_repo" add .
  git -C "$fixture_repo" commit -qm fixture
  fixture_dispatch_tip="$(git -C "$fixture_repo" rev-parse dev)"
  cat >"$fixture_repo/state/state.yaml" <<EOF
{"current_stage":"$fixture_stage","stages":[{"id":"$fixture_stage","status":"in_progress","worker":"Codex Smoke <codex-smoke@local>","verifier":"Claude Smoke <claude-smoke@local>","base_branch":"dev","dispatch_base_tip":"$fixture_dispatch_tip"}]}
EOF
  printf '{"consecutive_failures":0}\n' >"$fixture_repo/state/budget.json"
  git -C "$fixture_repo" worktree add -q -b "autometta/$fixture_stage" "$fixture_work" dev
}

tear_down_run_worktree() {
  git -C "$fixture_repo" worktree remove --force "$fixture_work"
  git -C "$fixture_repo" branch -D "autometta/$fixture_stage" >/dev/null
}

rebase_and_ff_smoke() {
  new_fixture rebase-and-ff 11-rebase-and-ff
  printf 'worker code\n' >"$fixture_work/worker-code.sh"
  mkdir -p "$fixture_repo/docs"
  printf 'base docs movement\n' >"$fixture_repo/docs/moved.md"
  git -C "$fixture_repo" add docs/moved.md
  git -C "$fixture_repo" commit -qm base-moves

  jq -n --arg headline 'smoke landing' '{overall:"PASS",headline:$headline,criteria:[]}' \
    >"$fixture_repo/state/verifiers/$fixture_stage.json"
  _process_verifier_artefact "$fixture_repo" "$fixture_repo/state/state.yaml" "$fixture_stage" \
    "state/verifiers/$fixture_stage.json" ""
  local verified_tip rebased_tip
  verified_tip="$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[0].integration.head')"
  rebased_tip="$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[0].integration.rebased_tip')"
  assert_eq "$rebased_tip" "$(git -C "$fixture_repo" rev-parse dev)" "dev is not the rebased run tip"
  [[ ! -e "$fixture_work" ]] || fail "rebased run worktree was not removed"
  assert_eq true "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[0].integration.rebased')" "integration did not record rebase"
  assert_eq "$verified_tip" "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[0].integration.head')" "verified tip was not retained"
  assert_eq "$rebased_tip" "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[0].integration.rebased_tip')" "rebased tip was not recorded"
}

overlap_parks_and_controller_merges_smoke() {
  new_fixture overlap-parks 12-overlap-parks
  sed '2s/line-2/worker-line-2/' "$fixture_work/shared.txt" >"$fixture_work/shared.txt.tmp"
  mv "$fixture_work/shared.txt.tmp" "$fixture_work/shared.txt"
  git -C "$fixture_work" add shared.txt
  git -C "$fixture_work" commit -qm worker
  local verified_tip result
  verified_tip="$(git -C "$fixture_work" rev-parse HEAD)"
  sed '18s/line-18/base-line-18/' "$fixture_repo/shared.txt" >"$fixture_repo/shared.txt.tmp"
  mv "$fixture_repo/shared.txt.tmp" "$fixture_repo/shared.txt"
  git -C "$fixture_repo" add shared.txt
  git -C "$fixture_repo" commit -qm base-moves

  result="$(rebase_disjoint_run_branch "$fixture_repo" "$fixture_work" "$fixture_dispatch_tip" dev "autometta/$fixture_stage")"
  assert_eq overlap:shared.txt "$result" "overlapping file did not park"
  record_stage_integration "$fixture_repo/state/state.yaml" "$fixture_stage" \
    "$(integration_record awaiting dev "autometta/$fixture_stage" "$verified_tip" false)"
  assert_eq awaiting "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[0].integration.state')" "overlap did not record awaiting"
  assert_eq '' "$(git -C "$fixture_repo" status --porcelain)" "base checkout was dirtied by park"
  "$script_dir/phat-controller.sh" merge-awaiting "$fixture_repo" "$fixture_stage" >/dev/null
  assert_true git -C "$fixture_repo" merge-base --is-ancestor "$verified_tip" dev
  assert_eq merged "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[0].integration.state')" "pc_merge_awaiting did not close clean parked branch"
}

disjoint_directory_conflict_parks_smoke() {
  new_fixture directory-conflict 13-directory-conflict
  mkdir "$fixture_work/collision"
  printf 'worker child\n' >"$fixture_work/collision/child.txt"
  git -C "$fixture_work" add collision/child.txt
  git -C "$fixture_work" commit -qm worker
  printf 'base file\n' >"$fixture_repo/collision"
  git -C "$fixture_repo" add collision
  git -C "$fixture_repo" commit -qm base-moves

  local result rebase_dir
  result="$(rebase_disjoint_run_branch "$fixture_repo" "$fixture_work" "$fixture_dispatch_tip" dev "autometta/$fixture_stage")"
  assert_eq conflict "$result" "directory collision did not park"
  rebase_dir="$(git -C "$fixture_work" rev-parse --git-path rebase-merge)"
  [[ ! -e "$rebase_dir" ]] || fail "rebase remained in progress after conflict"
  assert_eq '' "$(git -C "$fixture_work" status --porcelain)" "run worktree was not clean after rebase abort"
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/111-dev-moving-does-not-park-a-disjoint-landing.md
rebase_and_ff_smoke
overlap_parks_and_controller_merges_smoke
disjoint_directory_conflict_parks_smoke
# AUTOMETTA-CONTRACT-END

printf 'PASS: disjoint landing rebase, overlap park and controller merge, clean base checkout, and aborted directory-collision rebase\n'

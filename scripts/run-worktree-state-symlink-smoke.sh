#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

smoke_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./tick.sh
source "$smoke_dir/tick.sh"

tmp_root="$(mktemp -d)"
repo_root="$tmp_root/subscriber"
stage_id="99-state-symlink-smoke"
work_dir="$tmp_root/subscriber-run-$stage_id"
trap 'rm -rf "$tmp_root"' EXIT

controller_log_dir="$tmp_root/controller-log"
budget_halt() { :; }

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

git init -q -b dev "$repo_root"
git -C "$repo_root" config user.name smoke
git -C "$repo_root" config user.email smoke@local
mkdir -p "$repo_root/state/handoffs" "$repo_root/state/verifiers"
touch "$repo_root/state/handoffs/.gitkeep"
git -C "$repo_root" add state/handoffs/.gitkeep
git -C "$repo_root" commit -qm bootstrap

created_work_dir="$(ensure_run_worktree "$repo_root" "$stage_id" dev)"
[[ "$created_work_dir" == "$work_dir" ]] || fail "fresh dispatch returned the wrong worktree"
[[ -L "$work_dir/state" ]] || fail "fresh dispatch did not create the state symlink"
assert_run_worktree_state_link "$repo_root" "$stage_id" \
  || fail "fresh dispatch state symlink did not resolve to subscriber state"
printf 'PASS: fresh dispatch state symlink resolves to subscriber state\n'

rm "$work_dir/state"
mkdir -p "$work_dir/state/verifiers" "$work_dir/state/handoffs"
if assert_run_worktree_state_link "$repo_root" "$stage_id" 2>"$tmp_root/symlink-fault.log"; then
  fail "a real state directory passed the symlink assertion"
fi
grep -qi 'state symlink' "$tmp_root/symlink-fault.log" \
  || fail "broken-link fault did not name the state symlink"
printf 'PASS: a real state directory fails with a message naming the symlink\n'

cat >"$repo_root/state/state.yaml" <<YAML
current_stage: $stage_id
stages:
  - id: $stage_id
    status: in_progress
    verifier_attempts: 1
YAML
if guard_run_worktree_state_before_dispatch "$repo_root" "$stage_id" verifier; then
  fail "verifier dispatch passed with a real state directory"
fi
pre_spawn_attempts="$(state_json "$repo_root/state/state.yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .verifier_attempts')"
[[ "$pre_spawn_attempts" == "1" ]] \
  || fail "pre-spawn state fault consumed a verifier attempt"
printf 'PASS: verifier dispatch fails before spawn without reserving an attempt\n'

# Replay the misdirection: the verifier writes successfully relative to its
# worktree, while the subscriber's shared state still has no artefact.
cat >"$work_dir/state/verifiers/$stage_id.json" <<JSON
{"stage_id":"$stage_id","overall":"PASS","criteria":[]}
JSON
[[ ! -f "$repo_root/state/verifiers/$stage_id.json" ]] \
  || fail "the replay did not isolate the verifier artefact"

# One attempt exists before this dispatch. Reserve the second exactly as the
# tick does immediately before spawn; the dispatch fault must return it.
cat >"$repo_root/state/state.yaml" <<YAML
current_stage: $stage_id
stages:
  - id: $stage_id
    status: in_progress
    verifier_attempts: 1
    verifier_pid: 999999
YAML
before_dispatch_attempts="$(state_json "$repo_root/state/state.yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .verifier_attempts')"
state_apply_json "$repo_root/state/state.yaml" \
  '(.stages[] | select(.id == $id)).verifier_attempts = ((.stages[] | select(.id == $id) | .verifier_attempts) + 1)' \
  --arg id "$stage_id"
handle_missing_completion_dispatch_fault \
  "$repo_root" "$stage_id" verifier "$repo_root/state/verifiers/$stage_id.json" \
  || fail "missing verifier artefact was not classified as a dispatch fault"
after_fault_attempts="$(state_json "$repo_root/state/state.yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .verifier_attempts')"
[[ "$after_fault_attempts" == "$before_dispatch_attempts" ]] \
  || fail "verifier attempt changed across the broken-symlink dispatch"
verifier_marker="$(state_json "$repo_root/state/state.yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .stall_marker')"
[[ "$verifier_marker" == "dispatch_configuration_fault:verifier" ]] \
  || fail "missing verifier artefact received the wrong diagnosis"
printf 'PASS: missing artefact is a dispatch fault and the attempt counter stays at %s\n' "$after_fault_attempts"

cat >"$repo_root/state/state.yaml" <<YAML
current_stage: $stage_id
stages:
  - id: $stage_id
    status: in_progress
    verifier_attempts: $before_dispatch_attempts
    worker_pid: 999999
YAML
handle_missing_completion_dispatch_fault \
  "$repo_root" "$stage_id" worker "$repo_root/state/handoffs/$stage_id.json" \
  || fail "missing worker envelope was not classified as a dispatch fault"
worker_marker="$(state_json "$repo_root/state/state.yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .stall_marker')"
[[ "$worker_marker" == "dispatch_configuration_fault:worker" ]] \
  || fail "missing worker envelope received the wrong diagnosis"
[[ "$worker_marker" != "worker_envelope_missing_after_exit" ]] \
  || fail "missing worker envelope was blamed on the worker"
printf 'PASS: missing worker envelope is a dispatch fault, not worker_envelope_missing_after_exit\n'

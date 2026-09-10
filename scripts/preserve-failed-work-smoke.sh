#!/usr/bin/env bash
# Offline proof that verifier FAIL preserves worker work before requeue.
# No auth, network access or provider dispatch is used.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'chmod -R u+w "$fixture" 2>/dev/null || true; rm -rf "$fixture"' EXIT
export PHAT_CONTROLLER_HOME="$fixture/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/log"
# tick.sh resolves its controller paths while it is sourced, so the fixture
# root must be exported first.
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || { printf '%s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2; return 1; }
}
assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || { printf '%s: missing %q\n' "$label" "$needle" >&2; return 1; }
}

# Prove the assertion helper can fail. A bare [[ ]] under Bash 3.2 set -e is
# not sufficient when it appears in a context whose status is being tested.
if assert_eq expected deliberately-wrong assertion-self-test 2>/dev/null; then
  fail "assertion helper did not fail on a mismatch"
fi
printf 'PASS assertion helper rejects a mismatch\n'

write_budget() {
  cat > "$1/state/budget.json" <<JSON
{
  "version": 1,
  "token_cap_total": 1000000,
  "tokens_spent": 0,
  "wall_clock_cap_seconds": 86400,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 400,
  "clock_ticks_used": 0,
  "consecutive_failure_cap": 10,
  "consecutive_failures": 0,
  "halted": false,
  "window_started_at": "$(date -u +%F)"
}
JSON
}

make_repo() {
  local name="$1" stage_id="$2"
  local repo="$fixture/$name"
  mkdir -p "$repo/state/verifiers" "$repo/state/handoffs" "$repo/state/logs"
  (
    cd "$repo"
    git init -q -b dev
    git config user.name Smoke
    git config user.email smoke@local
    git config commit.gpgsign false
    printf 'state/**\n' > .gitignore
    printf 'seed\n' > README.md
    git add .gitignore README.md
    git commit -qm seed
  )
  cat > "$repo/state/state.yaml" <<YAML
version: 1
current_stage: $stage_id
last_tick_at: "2026-08-24T00:00:00Z"
tick_count: 1
clock_tick_budget_remaining: 399
stages:
  - id: $stage_id
    status: in_progress
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
    base_branch: dev
    verifier_attempts: 2
    verifier_artefact: state/verifiers/$stage_id.json
YAML
  cat > "$repo/state/verifiers/$stage_id.json" <<JSON
{
  "overall": "FAIL",
  "criteria": [
    {"id": 1, "name": "fixture preservation", "verdict": "FAIL", "evidence": "fixture reason survives in the commit subject"}
  ],
  "additional_findings": ""
}
JSON
  write_budget "$repo"
  printf '%s' "$repo"
}

run_fail() {
  local repo="$1" stage_id="$2"
  _process_verifier_artefact "$repo" "$repo/state/state.yaml" "$stage_id" \
    "state/verifiers/$stage_id.json" ""
}

printf '== dirty FAIL is committed, pinned and recorded ==\n'
dirty_stage=53-preserve-dirty
dirty_repo="$(make_repo dirty "$dirty_stage")"
dirty_wt="$(ensure_run_worktree "$dirty_repo" "$dirty_stage" dev)"
printf 'near passing work\n' > "$dirty_wt/result.txt"
run_fail "$dirty_repo" "$dirty_stage"

dirty_sha="$(yq -r ".stages[] | select(.id == \"$dirty_stage\") | .wip_commit" "$dirty_repo/state/state.yaml")"
dirty_branch="$(yq -r ".stages[] | select(.id == \"$dirty_stage\") | .wip_branch" "$dirty_repo/state/state.yaml")"
assert_eq verifier_failed "$(yq -r ".stages[] | select(.id == \"$dirty_stage\") | .status" "$dirty_repo/state/state.yaml")" "dirty status"
assert_eq "wip/$dirty_stage-attempt-1" "$dirty_branch" "wip branch"
assert_eq "$dirty_sha" "$(git -C "$dirty_repo" rev-parse "refs/heads/$dirty_branch")" "pin SHA"
assert_eq "$dirty_sha" "$(git -C "$dirty_repo" rev-parse "refs/heads/autometta/$dirty_stage")" "run branch SHA"
assert_eq 'GPT-5.6 Sol <gpt-5-6-sol@local>' "$(git -C "$dirty_repo" show -s --format='%an <%ae>' "$dirty_sha")" "worker author"
assert_contains "$(git -C "$dirty_repo" show -s --format=%s "$dirty_sha")" "attempt 1, verifier FAIL: criterion 1 fixture preservation" "commit subject"
assert_eq '' "$(git -C "$dirty_wt" status --porcelain -- . ':(exclude)state')" "preserved worktree cleanliness"
printf 'PASS dirty FAIL: run=%s pin=%s sha=%s author=%s\n' \
  "autometta/$dirty_stage" "$dirty_branch" "$dirty_sha" "$(git -C "$dirty_repo" show -s --format='%an <%ae>' "$dirty_sha")"

printf '== requeue removes ephemeral refs but retains the pin ==\n'
requeue_out="$("$script_dir/requeue-stage.sh" "$dirty_repo" "$dirty_stage" 2>&1)"
[[ ! -d "$dirty_wt" ]] || fail "requeue left the run worktree standing"
if git -C "$dirty_repo" show-ref --verify --quiet "refs/heads/autometta/$dirty_stage"; then
  fail "requeue left the run branch standing"
fi
assert_eq "$dirty_sha" "$(git -C "$dirty_repo" rev-parse "refs/heads/$dirty_branch")" "pin after requeue"
assert_contains "$requeue_out" "$dirty_sha" "requeue output"
printf 'PASS requeue: run worktree and branch removed; %s remains at %s\n' "$dirty_branch" "$dirty_sha"

printf '== clean FAIL logs that there is nothing to preserve ==\n'
clean_stage=54-preserve-clean
clean_repo="$(make_repo clean "$clean_stage")"
clean_wt="$(ensure_run_worktree "$clean_repo" "$clean_stage" dev)"
clean_out="$(run_fail "$clean_repo" "$clean_stage" 2>&1)"
assert_contains "$clean_out" "clean worktree, nothing to preserve" "clean FAIL log"
[[ -d "$clean_wt" ]] || fail "clean FAIL removed the run worktree"
assert_eq null "$(yq -r ".stages[] | select(.id == \"$clean_stage\") | .wip_commit // null" "$clean_repo/state/state.yaml")" "clean wip_commit"
assert_eq verifier_failed "$(yq -r ".stages[] | select(.id == \"$clean_stage\") | .status" "$clean_repo/state/state.yaml")" "clean status"
printf 'PASS clean FAIL: no commit or pin created\n'

printf '== a pinned failed worktree is reaper-collectable ==\n'
reap_stage=55-preserve-reap
reap_repo="$(make_repo reap "$reap_stage")"
reap_wt="$(ensure_run_worktree "$reap_repo" "$reap_stage" dev)"
printf 'preserved then reaped\n' > "$reap_wt/result.txt"
run_fail "$reap_repo" "$reap_stage"
reap_sha="$(yq -r ".stages[] | select(.id == \"$reap_stage\") | .wip_commit" "$reap_repo/state/state.yaml")"
reap_branch="$(yq -r ".stages[] | select(.id == \"$reap_stage\") | .wip_branch" "$reap_repo/state/state.yaml")"
reap_out="$("$script_dir/reap-worktrees.sh" "$reap_repo" 2>&1)"
[[ ! -d "$reap_wt" ]] || fail "reaper left a pinned failed worktree standing"
assert_eq "$reap_sha" "$(git -C "$reap_repo" rev-parse "refs/heads/$reap_branch")" "pin after reap"
assert_contains "$reap_out" "safe to reap" "reaper output"
printf 'PASS reaper: removed worktree and run branch; %s remains at %s\n' "$reap_branch" "$reap_sha"

printf '== git failure leaves dirty work standing and FAIL still completes ==\n'
broken_stage=56-preserve-git-failure
broken_repo="$(make_repo broken "$broken_stage")"
broken_wt="$(ensure_run_worktree "$broken_repo" "$broken_stage" dev)"
printf 'must not be lost\n' > "$broken_wt/result.txt"
broken_before="$(git -C "$broken_repo" rev-parse "refs/heads/autometta/$broken_stage")"
chmod a-w "$broken_repo/.git/refs/heads/autometta"
broken_out="$(run_fail "$broken_repo" "$broken_stage" 2>&1)"
chmod u+w "$broken_repo/.git/refs/heads/autometta"
assert_contains "$broken_out" "git commit preservation failed" "git failure log"
assert_eq verifier_failed "$(yq -r ".stages[] | select(.id == \"$broken_stage\") | .status" "$broken_repo/state/state.yaml")" "failure status"
assert_eq "$broken_before" "$(git -C "$broken_repo" rev-parse "refs/heads/autometta/$broken_stage")" "run branch after failure"
[[ -n "$(git -C "$broken_wt" status --porcelain -- . ':(exclude)state')" ]] || fail "git failure lost the dirty work"
if git -C "$broken_repo" show-ref --verify --quiet "refs/heads/wip/$broken_stage-attempt-1"; then
  fail "git failure unexpectedly created the wip pin"
fi
printf 'PASS git failure: tick FAIL transition completed and dirty worktree remains\n'

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/110-preserve-keeps-what-the-card-called-a-deliverable.md
make_repo_with_card() {
  local name="$1" stage_id="$2" started_at="$3"
  local repo="$fixture/$name"
  mkdir -p "$repo/state/verifiers" "$repo/state/handoffs" "$repo/state/logs" "$repo/stage-cards"
  (
    cd "$repo"
    git init -q -b dev
    git config user.name Smoke
    git config user.email smoke@local
    git config commit.gpgsign false
    printf 'out/\nstate/**\n' > .gitignore
    printf 'seed\n' > README.md
    git add .gitignore README.md
    git commit -qm seed
  )
  cat > "$repo/stage-cards/$stage_id.md" <<EOF
# Stage card $stage_id: fixture

## Deliverables

1. \`out/frame.png\` is the rendered frame.
EOF
  cat > "$repo/state/state.yaml" <<YAML
version: 1
current_stage: $stage_id
last_tick_at: "2026-08-24T00:00:00Z"
tick_count: 1
clock_tick_budget_remaining: 399
stages:
  - id: $stage_id
    status: in_progress
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
    base_branch: dev
    verifier_attempts: 2
    started_at: "$started_at"
    verifier_artefact: state/verifiers/$stage_id.json
YAML
  cat > "$repo/state/verifiers/$stage_id.json" <<JSON
{
  "overall": "FAIL",
  "criteria": [
    {"id": 1, "name": "fixture preservation", "verdict": "FAIL", "evidence": "ignored deliverable survives"}
  ],
  "additional_findings": ""
}
JSON
  write_budget "$repo"
  printf '%s' "$repo"
}

printf '== an ignored deliverable named on the card is in the WIP commit ==\n'
deliverable_stage=110-preserve-deliverable
deliverable_repo="$(make_repo_with_card deliverable "$deliverable_stage" "2026-08-24T00:00:00Z")"
deliverable_wt="$(ensure_run_worktree "$deliverable_repo" "$deliverable_stage" dev)"
mkdir -p "$deliverable_wt/out"
printf 'rendered frame\n' > "$deliverable_wt/out/frame.png"
run_fail "$deliverable_repo" "$deliverable_stage"
deliverable_sha="$(yq -r ".stages[] | select(.id == \"$deliverable_stage\") | .wip_commit" "$deliverable_repo/state/state.yaml")"
assert_eq present "$([[ -n "$deliverable_sha" && "$deliverable_sha" != null ]] && echo present || echo missing)" "deliverable wip_commit exists"
assert_contains "$(git -C "$deliverable_repo" show --stat "$deliverable_sha")" "out/frame.png" "ignored deliverable is in the WIP commit"
printf 'PASS ignored deliverable named on the card: preserved at %s\n' "$deliverable_sha"

printf '== an ignored non-deliverable is not preserved ==\n'
nondeliverable_stage=110-preserve-nondeliverable
nondeliverable_repo="$(make_repo_with_card nondeliverable "$nondeliverable_stage" "2026-08-24T00:00:00Z")"
nondeliverable_wt="$(ensure_run_worktree "$nondeliverable_repo" "$nondeliverable_stage" dev)"
mkdir -p "$nondeliverable_wt/out"
printf 'not named by the card\n' > "$nondeliverable_wt/out/other.png"
nondeliverable_out="$(run_fail "$nondeliverable_repo" "$nondeliverable_stage" 2>&1)"
assert_contains "$nondeliverable_out" "clean worktree, nothing to preserve" "non-deliverable FAIL log"
assert_eq null "$(yq -r ".stages[] | select(.id == \"$nondeliverable_stage\") | .wip_commit // null" "$nondeliverable_repo/state/state.yaml")" "non-deliverable wip_commit"
printf 'PASS ignored non-deliverable: no commit or pin created\n'

printf '== a stall produces a WIP branch ==\n'
stall_stage=110-preserve-stall
stall_repo="$(make_repo_with_card stall "$stall_stage" "2026-08-24T00:00:00Z")"
stall_wt="$(ensure_run_worktree "$stall_repo" "$stall_stage" dev)"
mkdir -p "$stall_wt/out"
printf 'rendered frame under a stall\n' > "$stall_wt/out/frame.png"
preserve_failed_work "$stall_repo" "$stall_repo/state/state.yaml" "$stall_stage" "" \
  "worker_envelope_missing_after_exit" "stalled"
stall_sha="$(yq -r ".stages[] | select(.id == \"$stall_stage\") | .wip_commit" "$stall_repo/state/state.yaml")"
stall_branch="$(yq -r ".stages[] | select(.id == \"$stall_stage\") | .wip_branch" "$stall_repo/state/state.yaml")"
assert_eq present "$([[ -n "$stall_sha" && "$stall_sha" != null ]] && echo present || echo missing)" "stall wip_commit exists"
assert_eq "$stall_sha" "$(git -C "$stall_repo" rev-parse "refs/heads/$stall_branch")" "stall pin SHA"
assert_contains "$(git -C "$stall_repo" show --stat "$stall_sha")" "out/frame.png" "stall WIP commit carries the deliverable"
printf 'PASS stall: preserved as %s on %s before anything removes the worktree\n' "$stall_sha" "$stall_branch"

printf '== requeue refuses the unpreserved-ignored case and proceeds after preserve ==\n'
requeue_ignored_stage=110-preserve-requeue-refuse
requeue_ignored_repo="$(make_repo_with_card requeue-refuse "$requeue_ignored_stage" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
requeue_ignored_wt="$(ensure_run_worktree "$requeue_ignored_repo" "$requeue_ignored_stage" dev)"
sleep 1
mkdir -p "$requeue_ignored_wt/out"
printf 'fresh, unpreserved\n' > "$requeue_ignored_wt/out/frame.png"
refuse_rc=0
refuse_out="$("$script_dir/requeue-stage.sh" "$requeue_ignored_repo" "$requeue_ignored_stage" 2>&1)" || refuse_rc=$?
[[ "$refuse_rc" -ne 0 ]] || fail "requeue did not refuse an unpreserved ignored deliverable"
assert_contains "$refuse_out" "out/" "requeue refusal names the ignored path"
[[ -d "$requeue_ignored_wt" ]] || fail "requeue removed the worktree despite refusing"
printf 'PASS requeue refuses: exit %s, worktree retained\n' "$refuse_rc"

run_fail "$requeue_ignored_repo" "$requeue_ignored_stage"
proceed_out="$("$script_dir/requeue-stage.sh" "$requeue_ignored_repo" "$requeue_ignored_stage" 2>&1)"
assert_contains "$proceed_out" "reset to pending" "requeue proceeds once preserved"
[[ ! -d "$requeue_ignored_wt" ]] || fail "requeue left the run worktree standing after a successful preserve"
printf 'PASS requeue proceeds once the ignored deliverable is preserved\n'
# AUTOMETTA-CONTRACT-END

printf 'PASS preserve-failed-work smoke\n'

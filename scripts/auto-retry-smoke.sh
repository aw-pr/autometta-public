#!/usr/bin/env bash
# auto-retry-smoke.sh: the tick requeues a worker that died without an
# envelope exactly once, after preserving its work, and leaves every ending
# that needs a decision for the escalation folder (card 161).
#
# Each case is a throwaway git repo with a run worktree; nothing dispatches.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
live_pid=""
cleanup() {
  [[ -z "$live_pid" ]] || kill "$live_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

export AUTOMETTA_HOME="$tmp/home"
export PHAT_CONTROLLER_HOME="$AUTOMETTA_HOME"
export AUTOMETTA_ESCALATIONS="$tmp/escalations"
export AUTOMETTA_NOTIFY=0
mkdir -p "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_HOME/log"

fail() {
  printf 'FAIL: 161-the-tick-retries-a-dead-worker-once: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/161-the-tick-retries-a-dead-worker-once.md
declare -F auto_retry_dead_workers >/dev/null || fail "tick.sh defines no auto_retry_dead_workers"

stage=07-dead
make_case() {
  local name="$1" status="$2" marker="$3" extra="${4:-}"
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
  mkdir -p "$dir/state/envelopes" "$dir/state/verifiers" "$dir/state/logs"
  printf 'half-done deliverable\n' > "$dir/../$name-run-$stage/work-in-progress.txt"
  cat > "$dir/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage
    status: $status
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    started_at: "2026-10-23T10:00:00Z"
    verifier_attempts: 0
    worker_pid: null
    stall_marker: $marker
$extra
YAML
  printf '{"version":1,"halted":false,"consecutive_failures":2,"consecutive_failure_cap":3,"token_cap_total":1000000,"tokens_spent":0,"wall_clock_cap_seconds":86400,"wall_clock_elapsed_seconds":0,"clock_tick_cap":400,"clock_ticks_used":1}\n' \
    > "$dir/state/budget.json"
  printf '%s\n' "$dir"
}
field() {
  yq -r ".stages[] | select(.id == \"$stage\") | .$2 // \"\"" "$1/state/state.yaml"
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
retry() {
  local dir="$1"
  auto_retry_dead_workers "$dir" "$dir/state/state.yaml" >/dev/null 2>&1 || fail "auto_retry_dead_workers exited non-zero for $(basename "$dir")"
}
assert_not_retried() {
  local dir="$1" want="$2" why="$3"
  [[ "$(field "$dir" status)" == "$want" ]] || fail "$why: status changed from $want to $(field "$dir" status)"
  [[ "$(field "$dir" auto_retries)" == "" || "$(field "$dir" auto_retries)" == "0" ]] || fail "$why: auto_retries was recorded"
  [[ -d "$dir/../$(basename "$dir")-run-$stage" ]] || fail "$why: the run worktree was removed"
}

a="$(make_case gone stalled worker_envelope_missing_after_exit)"
budget_before="$(sha "$a/state/budget.json")"
retry "$a"
[[ "$(field "$a" status)" == "pending" ]] || fail "(a) a dead worker with no envelope was not requeued (status $(field "$a" status))"
[[ "$(field "$a" auto_retries)" == "1" ]] || fail "(a) auto_retries is not 1 after the retry"
[[ ! -d "$a/../gone-run-$stage" ]] || fail "(a) the requeue did not remove the run worktree"
! git -C "$a" show-ref --verify --quiet "refs/heads/autometta/$stage" || fail "(a) the requeue did not remove the run branch"
[[ "$(sha "$a/state/budget.json")" == "$budget_before" ]] || fail "(a) the retry changed budget.json (halt or failure count)"
wip="$(field "$a" wip_commit)"
[[ -n "$wip" ]] || fail "(f) no wip_commit recorded for the retried attempt"
git -C "$a" cat-file -e "$wip^{commit}" 2>/dev/null || fail "(f) the preserved commit $wip does not exist"
[[ "$(git -C "$a" show "$wip:work-in-progress.txt" 2>/dev/null)" == "half-done deliverable" ]] \
  || fail "(f) the preserved commit does not contain the uncommitted file"
[[ -n "$(git -C "$a" for-each-ref --format='%(refname)' "refs/heads/wip/$stage-attempt-*")" ]] \
  || fail "(f) no wip/$stage-attempt-N branch pins the preserved commit"

yq -i "(.stages[] | select(.id == \"$stage\")) |= (.status = \"stalled\" | .stall_marker = \"worker_envelope_missing_after_exit\" | .started_at = \"2026-10-23T12:00:00Z\")" \
  "$a/state/state.yaml"
git -C "$a" worktree add -q -b "autometta/$stage" "$a/../gone-run-$stage" dev
printf 'second attempt\n' > "$a/../gone-run-$stage/again.txt"
retry "$a"
[[ "$(field "$a" status)" == "stalled" ]] || fail "(b) a second death of the same stage was retried"
[[ "$(field "$a" auto_retries)" == "1" ]] || fail "(b) a second death changed auto_retries"

c="$(make_case env-fail failed '"worker says the contract is wrong"')"
printf '{"stage_id":"%s","status":"fail","deliverables":[],"notes":"worker says the contract is wrong"}\n' "$stage" \
  > "$c/state/envelopes/$stage.json"
retry "$c"
assert_not_retried "$c" failed "(c) a worker FAIL envelope"

d="$(make_case has-envelope stalled '""')"
printf '{"stage_id":"%s","status":"pass","deliverables":["x"],"notes":"done"}\n' "$stage" \
  > "$d/state/envelopes/$stage.json"
retry "$d"
assert_not_retried "$d" stalled "(d) a stall that carries a worker envelope (verifier side)"

e="$(make_case judged verifier_failed '""')"
printf '{"overall":"FAIL"}\n' > "$e/state/verifiers/$stage.json"
retry "$e"
assert_not_retried "$e" verifier_failed "(e) verifier_failed"

for marker in dispatch_configuration_fault:worker run_worktree_failed dispatch_base_tip_unresolved card_missing; do
  g="$(make_case "fault-${marker%%:*}" stalled "$marker")"
  retry "$g"
  assert_not_retried "$g" stalled "(g) the deterministic fault $marker"
done

h="$(make_case halted stalled worker_envelope_missing_after_exit)"
printf '{"version":1,"halted":true,"halt_reason":"failure-cap","consecutive_failures":3,"consecutive_failure_cap":3}\n' \
  > "$h/state/budget.json"
halted_budget="$(sha "$h/state/budget.json")"
retry "$h"
assert_not_retried "$h" stalled "(h) a halted repo"
[[ "$(sha "$h/state/budget.json")" == "$halted_budget" ]] || fail "(h) a halted repo's budget.json changed"

sleep 300 &
live_pid=$!
i="$(make_case live stalled worker_envelope_missing_after_exit)"
yq -i "(.stages[] | select(.id == \"$stage\")).worker_pid = $live_pid" "$i/state/state.yaml"
retry "$i"
assert_not_retried "$i" stalled "(i) a stalled stage whose worker process is still alive"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
live_pid=""

j="$(make_case unpreservable stalled worker_envelope_missing_after_exit)"
git -C "$j/../unpreservable-run-$stage" checkout -q --detach
retry "$j"
assert_not_retried "$j" stalled "(j) a preservation failure"
[[ -f "$j/../unpreservable-run-$stage/work-in-progress.txt" ]] || fail "(j) a preservation failure lost the uncommitted file"

k="$(make_case unmarked stalled '""')"
retry "$k"
[[ "$(field "$k" status)" == "pending" && "$(field "$k" auto_retries)" == "1" ]] \
  || fail "(k) a silent or wall-clock worker stall with no marker and no envelope was not retried"

l="$(make_case two-stages stalled worker_envelope_missing_after_exit \
  "  - id: 08-done
    status: completed
    worker: \"Worker <worker@local>\"")"
retry "$l"
[[ "$(yq -r '.stages[] | select(.id == "08-done") | .status' "$l/state/state.yaml")" == "completed" ]] \
  || fail "(l) the retry touched another stage"

"$script_dir/requeue-stage.sh" "$a" "$stage" >/dev/null 2>&1 || fail "(m) an operator requeue of the retried stage failed"
[[ "$(field "$a" auto_retries)" == "" || "$(field "$a" auto_retries)" == "0" ]] \
  || fail "(m) an operator requeue did not reset auto_retries"

n="$(make_case stall-preserved stalled worker_envelope_missing_after_exit)"
mkdir -p "$n/stage-cards"
printf '# Stage card 07: dead\n\n## Deliverables\n\n1. `out/deliverable.txt`: the output.\n\n## Constraints\n\nNone.\n' \
  > "$n/stage-cards/$stage.md"
printf 'state/**\nout/\n' > "$n/../stall-preserved-run-$stage/.gitignore"
mkdir -p "$n/../stall-preserved-run-$stage/out"
printf 'ignored deliverable\n' > "$n/../stall-preserved-run-$stage/out/deliverable.txt"
preserve_failed_work "$n" "$n/state/state.yaml" "$stage" "" "worker_envelope_missing_after_exit" "stalled" >/dev/null 2>&1 \
  || fail "(n) fixture: the stall-time preservation the tick performs failed"
stall_wip="$(field "$n" wip_commit)"
[[ -n "$stall_wip" ]] || fail "(n) fixture: stall-time preservation recorded no wip_commit"
retry "$n"
[[ "$(field "$n" status)" == "pending" && "$(field "$n" auto_retries)" == "1" ]] \
  || fail "(n) a stage already preserved at stall time, with a card naming an ignored deliverable, was not retried"
[[ "$(git -C "$n" show "$(field "$n" wip_commit):out/deliverable.txt" 2>/dev/null)" == "ignored deliverable" ]] \
  || fail "(n) the recorded wip_commit does not hold the card's deliverable"

jq -e '.. | objects | select(has("auto_retries")) | .auto_retries | select(.type? != null)' \
  "$script_dir/../schemas/state.yaml.json" >/dev/null 2>&1 \
  || fail "schemas/state.yaml.json does not declare auto_retries"

body="$(declare -f _process_repo_locked)"
retry_line="$(printf '%s\n' "$body" | grep -n 'auto_retry_dead_workers' | head -1 | cut -d: -f1)"
caps_line="$(printf '%s\n' "$body" | grep -n 'budget_check_caps' | head -1 | cut -d: -f1)"
pause_line="$(printf '%s\n' "$body" | grep -n 'budget_pause_active' | head -1 | cut -d: -f1)"
[[ -n "$retry_line" && -n "$caps_line" && -n "$pause_line" ]] || fail "_process_repo_locked lacks the retry call or a gate"
(( retry_line > caps_line && retry_line > pause_line )) \
  || fail "_process_repo_locked calls auto_retry_dead_workers before the budget or pause gate"
[[ "$body" == *auto_retry_dead_workers* ]] || fail "_process_repo_locked does not call auto_retry_dead_workers"
requeue_calls="$(declare -f auto_retry_dead_workers | grep -c 'requeue-stage.sh\|requeue_script' || true)"
[[ "$requeue_calls" -ge 1 ]] || fail "auto_retry_dead_workers does not call requeue-stage.sh for its requeue mechanics"
bash -n "$script_dir/tick.sh" || fail "tick.sh does not parse"
# AUTOMETTA-CONTRACT-END

printf 'auto-retry-smoke: PASS\n'

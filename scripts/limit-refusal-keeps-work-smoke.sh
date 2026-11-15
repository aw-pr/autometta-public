#!/usr/bin/env bash
# limit-refusal-keeps-work-smoke.sh: a worker exit whose log matches a
# provider limit message keeps the attempt's work (card 168).
#
# Only an exit inside the instant bound is a refusal that leaves the stage
# untouched. A worker that ran for a while and then matched the pattern has
# its work pinned on a wip ref before the stage is rewound, the rewind is
# bounded, and the next dispatch never removes work it could not pin.
#
# Each case is a throwaway git repo with a real run worktree; nothing
# dispatches and no agent runs.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_raw="$(mktemp -d "${TMPDIR:-/tmp}/limit-refusal-smoke.XXXXXX")" \
  || { printf 'FAIL: 168-a-limit-refusal-keeps-the-work: mktemp failed\n' >&2; exit 1; }
[[ -n "$tmp_raw" && -d "$tmp_raw" ]] \
  || { printf 'FAIL: 168-a-limit-refusal-keeps-the-work: no temp dir\n' >&2; exit 1; }
tmp="$(cd "$tmp_raw" && pwd -P)"
case "$(basename "$tmp")" in
  limit-refusal-smoke.*) ;;
  *) printf 'FAIL: 168-a-limit-refusal-keeps-the-work: temp dir resolved to %s\n' "$tmp" >&2; exit 1 ;;
esac
trap 'rm -rf "$tmp"' EXIT

export AUTOMETTA_HOME="$tmp/home"
export PHAT_CONTROLLER_HOME="$AUTOMETTA_HOME"
export AUTOMETTA_ESCALATIONS="$tmp/escalations"
export AUTOMETTA_NOTIFY=0
mkdir -p "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_HOME/log"

fail() {
  printf 'FAIL: 168-a-limit-refusal-keeps-the-work: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/168-a-limit-refusal-keeps-the-work.md
# Seams outside this card: quota, caps, drains, pipelines, the state branch
# and token accounting. The limit pause, failure count, preservation and
# worktree handling stay real.
quota_write_repo_state() { return 0; }
budget_ensure_window() { return 0; }
budget_check_caps() { return 0; }
budget_drain_active() { return 1; }
budget_increment_tick() { return 0; }
commit_state_branch() { return 0; }
pipeline_prepare_tail_rebase() { return 0; }
budget_account_tokens_from_dispatch() { return 0; }
stage_snapshot_tokens() { return 0; }
costlog_emit_worker() { return 0; }

stage=07-limited
worker_identity='GPT-6.1 Sol <gpt-6-1-sol@local>'
# Above any macOS or Linux pid_max, so it can never name a live process.
gone_pid=99999999

epoch_to_utc() {
  python3 -c 'import datetime as d, sys; print(d.datetime.fromtimestamp(int(sys.argv[1]), d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}
set_mtime() {
  python3 -c 'import os, sys; t = int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"
}
field() {
  yq -r ".stages[] | select(.id == \"$stage\") | .$2 // \"\"" "$1/state/state.yaml"
}
failures() { jq -r '.consecutive_failures // 0' "$1/state/budget.json"; }
paused_until() { jq -r '.paused_until // 0' "$1/state/budget.json"; }
clear_pause() {
  jq 'del(.paused_until, .paused_reason)' "$1/state/budget.json" >"$1/state/budget.json.tmp"
  mv "$1/state/budget.json.tmp" "$1/state/budget.json"
}
run_dir() { worktree_path_for_stage "$1" "$stage"; }

# A wip ref of this stage holds <path> with <content>.
work_pinned() {
  local dir="$1" path="$2" content="$3" ref
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    if [[ "$(git -C "$dir" show "$ref:$path" 2>/dev/null)" == "$content" ]]; then
      return 0
    fi
  done < <(git -C "$dir" for-each-ref --format='%(refname)' "refs/heads/wip/$stage-attempt-*")
  return 1
}

make_repo() {
  local name="$1" identity="${2-$worker_identity}" dir
  dir="$tmp/repos/$name"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b dev .
    git config user.email smoke@local
    git config user.name smoke
    git config commit.gpgsign false
    printf 'state/**\n' > .gitignore
    mkdir -p stage-cards docs
    printf 'seed deliverable\n' > docs/partial.md
    cat > "stage-cards/$stage.md" <<'CARD'
# Stage card 07: limited

## Deliverables

1. `docs/partial.md`

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 20 minutes
CARD
    git add -A
    git commit -qm seed
  )
  mkdir -p "$dir/state/envelopes" "$dir/state/verifiers" "$dir/state/logs"
  cat > "$dir/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage
    status: pending
    worker: "$identity"
    verifier: "Claude Sonnet 5.5 <claude-sonnet-5-5@local>"
    verifier_attempts: 0
    worker_pid: null
    verifier_pid: null
YAML
  printf '{"version":1,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":10,"token_cap_total":1000000000,"tokens_spent":0,"wall_clock_cap_seconds":864000,"wall_clock_elapsed_seconds":0,"clock_tick_cap":100000,"clock_ticks_used":1}\n' \
    > "$dir/state/budget.json"
  ensure_run_worktree "$dir" "$stage" dev >/dev/null 2>>"$tmp/tick.log" \
    || fail "ensure_run_worktree could not cut a fresh run worktree for $name"
  printf '%s\n' "$dir"
}

# Put the stage back in flight as a dispatch would, with a worker that has
# already exited without writing a dispatch envelope and whose log was last
# written exactly <ran> seconds after started_at.
exited_after() {
  local dir="$1" ran="$2" now started_epoch log_path
  now="$(date -u +%s)"
  started_epoch=$((now - ran))
  log_path="$dir/state/logs/$stage-worker.log"
  yq -i "(.stages[] | select(.id == \"$stage\")) |= (.status = \"in_progress\" | .worker_pid = $gone_pid | .started_at = \"$(epoch_to_utc "$started_epoch")\" | .base_branch = \"dev\") | .current_stage = \"$stage\"" \
    "$dir/state/state.yaml"
  rm -f "$dir/state/envelopes/$stage.json"
  clear_pause "$dir"
  set_mtime "$log_path" "$((started_epoch + ran))"
  _process_repo_locked "$dir" "" >>"$tmp/tick.log" 2>&1 \
    || fail "the tick returned non-zero for a worker that exited after ${ran}s"
}

# A long worker whose own output names a session limit (the promo-flow
# stage 35 log line of 2026-10-22), after editing the tracked deliverable
# and leaving an untracked note.
work_then_limit_line() {
  local dir="$1" tag="$2" wd i
  wd="$(run_dir "$dir")"
  [[ -d "$wd" ]] || fail "($tag) no run worktree to work in"
  printf 'partial deliverable %s\n' "$tag" > "$wd/docs/partial.md"
  printf 'scratch notes %s\n' "$tag" > "$wd/notes-$tag.txt"
  {
    for i in $(seq 1 300); do printf 'tool call %d: edited docs/partial.md and ran the checks\n' "$i"; done
    printf -- '- when the user asked for "30%% session limit saved" by day, encode the threshold\n'
    for i in $(seq 301 600); do printf 'tool call %d: edited docs/partial.md and ran the checks\n' "$i"; done
  } > "$dir/state/logs/$stage-worker.log"
}

# A refusal log: one line (claude), or codex's prompt echo then the refusal.
# Neither names a reset clock, so every pause is the one-hour fallback and
# no assertion depends on the time of day.
refusal_log() {
  local dir="$1" shape="$2" i
  if [[ "$shape" == codex ]]; then
    {
      printf 'OpenAI Codex v0.164.0\n--------\nworkdir: %s\nmodel: gpt-6.1-sol\n--------\nuser\n' "$(run_dir "$dir")"
      for i in $(seq 1 160); do printf 'You are a worker in the dispatch-contract loop. Read the stage card first. (%d)\n' "$i"; done
      printf "ERROR: You've hit your usage limit. Visit the usage settings to purchase more credits or try again at 3:49 PM.\n"
    } > "$dir/state/logs/$stage-worker.log"
  else
    printf "You've hit your session limit\n" > "$dir/state/logs/$stage-worker.log"
  fi
}

assert_untouched_refusal() {
  local dir="$1" what="$2"
  [[ "$(field "$dir" status)" == "pending" ]] \
    || fail "$what was not rewound to pending (status $(field "$dir" status))"
  [[ -z "$(field "$dir" worker_pid)" && -z "$(field "$dir" started_at)" ]] \
    || fail "$what left worker_pid or started_at set"
  [[ "$(failures "$dir")" == "0" ]] || fail "$what recorded a failure"
  (( $(paused_until "$dir") > $(date -u +%s) )) || fail "$what did not pause dispatch"
  [[ "$(git -C "$(run_dir "$dir")" rev-parse HEAD 2>/dev/null)" == "$(git -C "$dir" rev-parse dev)" ]] \
    || fail "$what did not leave the run worktree standing untouched"
}

# (1) A worker that ran 40 minutes and then matched the limit pattern has its
# work pinned on a wip ref, then is rewound to pending as a pause, not a failure.
a="$(make_repo midrun)"
work_then_limit_line "$a" one
exited_after "$a" 2400
[[ "$(field "$a" status)" == "pending" ]] \
  || fail "(1) a mid-run limit exit was not rewound to pending (status $(field "$a" status))"
[[ -z "$(field "$a" worker_pid)" && -z "$(field "$a" started_at)" ]] \
  || fail "(1) the rewind left worker_pid or started_at set"
[[ "$(failures "$a")" == "0" ]] || fail "(1) a mid-run limit exit recorded a failure"
(( $(paused_until "$a") > $(date -u +%s) )) || fail "(1) a mid-run limit exit did not pause dispatch"
work_pinned "$a" docs/partial.md "partial deliverable one" \
  || fail "(1) the rewind did not pin the attempt's tracked deliverable on a wip/$stage-attempt-N ref"
work_pinned "$a" notes-one.txt "scratch notes one" \
  || fail "(1) the rewind did not pin the attempt's untracked file on a wip ref"
[[ "$(git -C "$a" show "$(field "$a" wip_commit):docs/partial.md" 2>/dev/null)" == "partial deliverable one" ]] \
  || fail "(1) the recorded wip_commit does not hold this attempt's work"
[[ "$(field "$a" limit_rewinds)" == "1" ]] || fail "(1) limit_rewinds is not 1 after the first rewind (got '$(field "$a" limit_rewinds)')"

# (2) The next dispatch re-cuts the worktree from base and the work survives.
wd="$(ensure_run_worktree "$a" "$stage" dev 2>>"$tmp/tick.log")" || fail "(2) the next dispatch could not cut a run worktree"
[[ "$wd" == "$(run_dir "$a")" ]] || fail "(2) the next dispatch cut the worktree at $wd"
[[ "$(git -C "$wd" rev-parse HEAD)" == "$(git -C "$a" rev-parse dev)" ]] \
  || fail "(2) the next dispatch did not start from the base branch tip"
[[ "$(cat "$wd/docs/partial.md")" == "seed deliverable" && ! -e "$wd/notes-one.txt" ]] \
  || fail "(2) the next dispatch reused the previous attempt's tree"
work_pinned "$a" docs/partial.md "partial deliverable one" \
  || fail "(2) the next dispatch lost the previous attempt's work"

# (3) The rewind is bounded: a second mid-run limit exit is rewound again, the
# third takes the ordinary missing-envelope path and is not rewound.
work_then_limit_line "$a" two
exited_after "$a" 2400
[[ "$(field "$a" status)" == "pending" ]] \
  || fail "(3) the second mid-run limit exit was not rewound (status $(field "$a" status))"
[[ "$(field "$a" limit_rewinds)" == "2" ]] || fail "(3) limit_rewinds is not 2 after the second rewind"
work_pinned "$a" docs/partial.md "partial deliverable two" \
  || fail "(3) the second rewind did not pin its attempt's work"
ensure_run_worktree "$a" "$stage" dev >/dev/null 2>>"$tmp/tick.log" || fail "(3) the third dispatch could not cut a run worktree"
work_then_limit_line "$a" three
exited_after "$a" 2400
[[ "$(field "$a" status)" == "stalled" ]] \
  || fail "(3) the third mid-run limit exit of one stage was rewound again (status $(field "$a" status))"
[[ "$(field "$a" stall_marker)" == "worker_envelope_missing_after_exit" ]] \
  || fail "(3) the bounded exit did not take the missing-envelope path (marker '$(field "$a" stall_marker)')"
[[ "$(failures "$a")" == "1" ]] || fail "(3) the bounded exit did not record exactly one failure (got $(failures "$a"))"
work_pinned "$a" docs/partial.md "partial deliverable three" \
  || fail "(3) the bounded exit did not pin its attempt's work"

# (4) Regression: a refusal inside the instant bound still rewinds untouched,
# whatever the CLI's log shape, and is never counted toward the bound.
b="$(make_repo instant)"
for shape in claude codex codex codex; do
  refusal_log "$b" "$shape"
  exited_after "$b" 0
  assert_untouched_refusal "$b" "(4) an instant $shape refusal"
done

# (5) The bound is 60 seconds inclusive, measured from started_at to the
# log's last write: three exits at 60s are instant, one at 61s is not, and an
# instant refusal is still untouched after the rewind allowance is spent.
f="$(make_repo boundary)"
for shape in codex codex codex; do
  refusal_log "$f" "$shape"
  exited_after "$f" 60
  assert_untouched_refusal "$f" "(5) a $shape refusal 60s after dispatch"
done
work_then_limit_line "$f" late
exited_after "$f" 61
[[ "$(field "$f" status)" == "pending" ]] || fail "(5) a limit exit at 61s was not rewound"
work_pinned "$f" docs/partial.md "partial deliverable late" \
  || fail "(5) a limit exit at 61s was treated as instant: its work was not pinned"
ensure_run_worktree "$f" "$stage" dev >/dev/null 2>>"$tmp/tick.log" || fail "(5) re-cut after 61s failed"
work_then_limit_line "$f" later
exited_after "$f" 61
[[ "$(field "$f" limit_rewinds)" == "2" ]] || fail "(5) the second 61s exit was not counted"
ensure_run_worktree "$f" "$stage" dev >/dev/null 2>>"$tmp/tick.log" || fail "(5) re-cut after the second 61s exit failed"
refusal_log "$f" claude
exited_after "$f" 0
assert_untouched_refusal "$f" "(5) an instant refusal after the rewind allowance was spent"

# (6) A mid-run limit exit whose work cannot be pinned is not rewound.
g="$(make_repo midrun-unpinnable '')"
work_then_limit_line "$g" stuck
exited_after "$g" 2400
[[ "$(field "$g" status)" != "pending" ]] \
  || fail "(6) a mid-run limit exit was rewound although its work could not be pinned"
[[ "$(cat "$(run_dir "$g")/docs/partial.md" 2>/dev/null)" == "partial deliverable stuck" ]] \
  || fail "(6) unpinnable mid-run work was removed"

# (7) The next dispatch pins unpreserved work in a standing worktree, as a
# rewind before this card left it, before it re-cuts.
c="$(make_repo standing)"
printf 'left by an old rewind\n' > "$(run_dir "$c")/docs/partial.md"
wd="$(ensure_run_worktree "$c" "$stage" dev 2>>"$tmp/tick.log")" || fail "(7) ensure_run_worktree failed on a standing dirty worktree"
work_pinned "$c" docs/partial.md "left by an old rewind" \
  || fail "(7) the next dispatch removed a standing worktree's unpreserved work"
[[ "$(git -C "$wd" rev-parse HEAD)" == "$(git -C "$c" rev-parse dev)" ]] \
  || fail "(7) after pinning, the next dispatch did not start from the base branch tip"
assert_run_worktree_state_link "$c" "$stage" || fail "(7) the re-cut worktree has no valid state link"

# (8) The next dispatch refuses, and removes nothing, when it cannot pin what
# a standing worktree holds: uncommitted work with no worker identity, a
# worktree whose status cannot be read, a real state/ directory, or run-branch
# commits that neither the base nor a wip ref reaches.
d="$(make_repo unpinnable '')"
printf 'cannot be pinned\n' > "$(run_dir "$d")/docs/partial.md"
if ensure_run_worktree "$d" "$stage" dev >/dev/null 2>&1; then
  fail "(8) ensure_run_worktree succeeded although the standing work could not be pinned"
fi
[[ "$(cat "$(run_dir "$d")/docs/partial.md" 2>/dev/null)" == "cannot be pinned" ]] \
  || fail "(8) unpinnable work was removed with the worktree"

h="$(make_repo unreadable)"
printf 'behind a broken gitdir\n' > "$(run_dir "$h")/docs/partial.md"
printf 'gitdir: %s/nowhere\n' "$tmp" > "$(run_dir "$h")/.git"
if ensure_run_worktree "$h" "$stage" dev >/dev/null 2>&1; then
  fail "(8) ensure_run_worktree removed a worktree whose status could not be read"
fi
[[ "$(cat "$(run_dir "$h")/docs/partial.md" 2>/dev/null)" == "behind a broken gitdir" ]] \
  || fail "(8) a worktree with an unreadable status was removed"

k="$(make_repo realstate)"
rm -f "$(run_dir "$k")/state"
mkdir -p "$(run_dir "$k")/state/envelopes"
printf '{"stage_id":"%s"}\n' "$stage" > "$(run_dir "$k")/state/envelopes/$stage.json"
if ensure_run_worktree "$k" "$stage" dev >/dev/null 2>&1; then
  fail "(8) ensure_run_worktree removed a worktree whose state/ is a real directory"
fi
[[ -f "$(run_dir "$k")/state/envelopes/$stage.json" ]] \
  || fail "(8) a real state/ directory was removed with the worktree"

m="$(make_repo selfcommit)"
printf 'committed by the worker\n' > "$(run_dir "$m")/docs/partial.md"
git -C "$(run_dir "$m")" -c user.name=w -c user.email=w@local commit -qam "worker self-commit"
self_sha="$(git -C "$(run_dir "$m")" rev-parse HEAD)"
ensure_run_worktree "$m" "$stage" dev >/dev/null 2>>"$tmp/tick.log" || true
[[ -n "$(git -C "$m" for-each-ref --contains "$self_sha" refs/heads)" ]] \
  || fail "(8) the next dispatch dropped run-branch commits no ref kept"

# (9) Regression: the verifier's refusal handling keeps its four-argument
# contract and still pauses on a long log.
e="$(make_repo verifier)"
{
  for i in $(seq 1 400); do printf 'criterion check %d\n' "$i"; done
  printf "You've hit your session limit\n"
} > "$e/state/logs/$stage-verifier.log"
handle_limit_refusal "$e" "$stage" verifier "$e/state/logs/$stage-verifier.log" >/dev/null 2>&1 \
  || fail "(9) handle_limit_refusal no longer treats a verifier limit log as a refusal"
(( $(paused_until "$e") > $(date -u +%s) )) || fail "(9) a verifier refusal did not pause dispatch"

# (10) The bounds are named values, shared through usage-limit.sh.
[[ "${USAGE_LIMIT_INSTANT_SECONDS:-}" == "60" ]] \
  || fail "(10) usage-limit.sh does not set USAGE_LIMIT_INSTANT_SECONDS=60 (got '${USAGE_LIMIT_INSTANT_SECONDS:-}')"
[[ "${USAGE_LIMIT_MAX_REWINDS:-}" == "2" ]] \
  || fail "(10) usage-limit.sh does not set USAGE_LIMIT_MAX_REWINDS=2 (got '${USAGE_LIMIT_MAX_REWINDS:-}')"

# (11) docs/lessons.md records the rule as one numbered headless gotcha that
# names both bounds.
awk '/^## / { in_section = ($0 ~ /^## Headless gotcha [0-9]+: /); has_instant = 0; has_rewinds = 0 }
     in_section && /USAGE_LIMIT_INSTANT_SECONDS/ { has_instant = 1 }
     in_section && /USAGE_LIMIT_MAX_REWINDS/ { has_rewinds = 1 }
     in_section && has_instant && has_rewinds { found = 1 }
     END { exit !found }' \
  "$script_dir/../docs/lessons.md" \
  || fail "(11) no headless gotcha in docs/lessons.md names both USAGE_LIMIT_INSTANT_SECONDS and USAGE_LIMIT_MAX_REWINDS"
# (12) The counter remains valid under the strict state schema.
if ! python3 - "$script_dir/../schemas/state.yaml.json" <<'SCHEMA'
import json
import sys
schema = json.load(open(sys.argv[1]))
stage = schema["properties"]["stages"]["items"]
counter = stage["properties"].get("limit_rewinds", {})
assert counter.get("type") == "integer", "limit_rewinds must be an integer"
assert counter.get("minimum") == 0, "limit_rewinds must reject negative values"
assert stage.get("additionalProperties") is False, "stage fields must remain strict"
SCHEMA
then
  fail "(12) limit_rewinds is absent or invalid in the strict state schema"
fi
# AUTOMETTA-CONTRACT-END

printf 'PASS limit refusal keeps work smoke\n'

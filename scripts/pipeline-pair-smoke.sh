#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_source="$(cd "$script_dir/.." && pwd)"
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

smoke_tmp="$(mktemp -d)"
smoke_log="$smoke_tmp/tick.log"
smoke_pids=()
fixture_repo=""
started_pid=""

cleanup() {
  local pid
  for pid in "${smoke_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
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

assert_log() {
  grep -Fq "$1" "$smoke_log" || fail "missing log line: $1"
}

log() {
  printf '%s\n' "$1" >>"$smoke_log"
}

quota_gate_role_dispatch() { return 0; }
budget_gate_dispatch() { return 0; }
budget_drain_active() { return 1; }
commit_state_branch() { return 0; }
ensure_yq_or_halt() { return 0; }
quota_write_repo_state() { return 0; }
budget_ensure_window() { return 0; }
budget_pause_active() { return 1; }
budget_check_caps() { return 0; }

spawn_worker_for_stage() {
  local card_path="$1" repo_root="$2" work_dir="$3" stage_id pid
  stage_id="$(basename "$card_path" .md)"
  printf '%s\n' "tail output" >>"$work_dir/tail.txt"
  sleep 300 &
  pid=$!
  smoke_pids+=( "$pid" )
  state_apply_json "$repo_root/state/state.yaml" \
    '(.stages[] | select(.id == $id)).worker_pid = $pid' \
    --arg id "$stage_id" --argjson pid "$pid"
  mkdir -p "$repo_root/state/active-agents"
  jq -n --argjson pid "$pid" --arg stage "$stage_id" \
    '{pid:$pid,role:"worker",stage_id:$stage}' \
    >"$repo_root/state/active-agents/${pid}.json"
}

write_card() {
  local repo_root="$1" id="$2" worker="$3" verifier="$4" claims="${5:-}"
  {
    printf '# Stage card %s: smoke fixture\n\n' "$id"
    printf '## Metadata\n\n'
    printf '%s\n' '- **Orchestrator:** Smoke <smoke@local>'
    printf '%s\n' "- **Worker:** ${worker}"
    printf '%s\n' "- **Verifier:** ${verifier}"
    [[ -z "$claims" ]] || printf '%s\n' "- **Path claims:** ${claims}"
    printf '\n## Budget\n\n- **Worker wall-clock:** 10 minutes\n'
  } >"$repo_root/docs/stages/${id}.md"
}

new_fixture() {
  local name="$1" head_claims="${2-head.txt}" tail_claims="${3-tail.txt}"
  local head_worker="${4-Codex Smoke <codex-smoke@local>}"
  local tail_worker="${5-Claude Smoke <claude-smoke@local>}"
  fixture_repo="$smoke_tmp/$name"
  mkdir -p "$fixture_repo/state/verifiers" "$fixture_repo/state/handoffs" \
    "$fixture_repo/state/logs" "$fixture_repo/docs/stages"
  git -C "$fixture_repo" init -q -b dev
  git -C "$fixture_repo" config user.name Smoke
  git -C "$fixture_repo" config user.email smoke@local
  printf 'base head\n' >"$fixture_repo/head.txt"
  printf 'base tail\n' >"$fixture_repo/tail.txt"
  printf 'base shared\n' >"$fixture_repo/shared.txt"
  write_card "$fixture_repo" 01-head "$head_worker" "Claude Verify <claude-verify@local>" "$head_claims"
  write_card "$fixture_repo" 02-tail "$tail_worker" "Codex Verify <codex-verify@local>" "$tail_claims"
  printf '{"total_tokens":100}\n{"total_tokens":200}\n{"total_tokens":300}\n' \
    >"$fixture_repo/state/cost-log.jsonl"
  cat >"$fixture_repo/state/budget.json" <<'JSON'
{"token_cap_total":10000,"tokens_spent":0,"clock_tick_cap":100,"clock_ticks_used":0,"idle_ticks_used":0,"consecutive_failure_cap":3,"consecutive_failures":0,"wall_clock_cap_seconds":10000,"wall_clock_elapsed_seconds":0,"halted":false}
JSON
  cat >"$fixture_repo/state/state.yaml" <<EOF
{"current_stage":"01-head","stages":[
 {"id":"01-head","status":"in_progress","worker":"$head_worker","verifier":"Claude Verify <claude-verify@local>","path_claims":$(printf '%s' "$head_claims" | jq -R 'split(",") | map(gsub("^ +| +$";""))'),"started_at":"2026-08-25T00:00:00Z","worker_pid":null,"verifier_pid":null,"verifier_artefact":null,"verifier_attempts":1,"base_branch":"dev"},
 {"id":"02-tail","status":"pending","worker":"$tail_worker","verifier":"Codex Verify <codex-verify@local>","path_claims":$(printf '%s' "$tail_claims" | jq -R 'split(",") | map(gsub("^ +| +$";""))'),"started_at":null,"worker_pid":null,"verifier_pid":null,"verifier_artefact":null,"verifier_attempts":0}
]}
EOF
  git -C "$fixture_repo" add .
  git -C "$fixture_repo" commit -qm fixture
  : >"$smoke_log"
}

start_head_verifier() {
  local repo_root="$1" pid
  sleep 300 &
  pid=$!
  smoke_pids+=( "$pid" )
  state_apply_json "$repo_root/state/state.yaml" \
    '(.stages[] | select(.id == "01-head")).verifier_pid = $pid' --argjson pid "$pid"
  mkdir -p "$repo_root/state/active-agents"
  jq -n --argjson pid "$pid" '{pid:$pid,role:"verifier",stage_id:"01-head"}' \
    >"$repo_root/state/active-agents/${pid}.json"
  started_pid="$pid"
}

stop_pid() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

write_verdict() {
  local repo_root="$1" stage_id="$2" overall="$3"
  jq -n --arg overall "$overall" --arg headline "smoke ${stage_id}" \
    '{overall:$overall,headline:$headline,criteria:[]}' \
    >"$repo_root/state/verifiers/${stage_id}.json"
  state_apply_json "$repo_root/state/state.yaml" \
    '(.stages[] | select(.id == $id)).verifier_artefact = $path' \
    --arg id "$stage_id" --arg path "state/verifiers/${stage_id}.json"
}

queue_parser_smoke() {
  local repo="$smoke_tmp/parser" card="$smoke_tmp/03-claims.md" bad="$smoke_tmp/04-bad-claims.md"
  mkdir -p "$repo/state" "$smoke_tmp/docs/stages"
  printf '{"current_stage":null,"stages":[]}\n' >"$repo/state/state.yaml"
  write_card "$smoke_tmp" 03-claims "Codex Smoke <codex-smoke@local>" \
    "Claude Verify <claude-verify@local>" "src/a.sh, docs/a.md"
  mv "$smoke_tmp/docs/stages/03-claims.md" "$card"
  "$repo_source/scripts/add-stage.sh" "$repo" "$card" >/dev/null
  assert_eq "$(yq -o=json '.' "$repo/state/state.yaml" | jq -c '.stages[0].path_claims')" \
    '["docs/a.md","src/a.sh"]' "valid path claims were not queued"
  write_card "$smoke_tmp" 04-bad-claims "Codex Smoke <codex-smoke@local>" \
    "Claude Verify <claude-verify@local>" "../outside"
  mv "$smoke_tmp/docs/stages/04-bad-claims.md" "$bad"
  if "$repo_source/scripts/add-stage.sh" "$repo" "$bad" >"$smoke_tmp/bad.out" 2>&1; then
    fail "unparseable path claims queued"
  fi
  grep -Fq 'refusing unparseable Path claims line' "$smoke_tmp/bad.out" \
    || fail "unparseable claims refusal was not explicit"
}

formation_and_ordered_landing_smoke() {
  new_fixture formed
  local head_work head_pid tail_pid
  head_work="$(ensure_run_worktree "$fixture_repo" 01-head dev)"
  printf 'head output\n' >>"$head_work/head.txt"
  start_head_verifier "$fixture_repo"
  head_pid="$started_pid"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head ""
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.pipeline_pair.tail')" \
    02-tail "pair did not form"
  tail_pid="$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-tail") | .worker_pid')"
  kill -0 "$head_pid" 2>/dev/null || fail "head verifier registration is not live"
  kill -0 "$tail_pid" 2>/dev/null || fail "tail worker registration is not live"
  assert_eq "$(find "$fixture_repo/state/active-agents" -type f | wc -l | tr -d ' ')" 2 \
    "both live registrations were not visible"
  assert_log 'pipeline pair formed:'

  write_verdict "$fixture_repo" 01-head PASS
  verifier_completion_ready "$fixture_repo/state/verifiers/01-head.json" "$head_pid" \
    && fail "verifier artefact was ready while writer pid was live"
  stop_pid "$head_pid"
  verifier_completion_ready "$fixture_repo/state/verifiers/01-head.json" "$head_pid" \
    || fail "verifier artefact stayed blocked after writer exit"
  _process_verifier_artefact "$fixture_repo" "$fixture_repo/state/state.yaml" \
    01-head state/verifiers/01-head.json ""
  pipeline_after_head_resolution "$fixture_repo/state/state.yaml" 01-head
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.current_stage')" \
    02-tail "tail was not promoted after head landing"

  stop_pid "$tail_pid"
  pipeline_prepare_tail_rebase "$fixture_repo" "$fixture_repo/state/state.yaml" 02-tail
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.pipeline_pair.phase')" \
    tail-rebased "tail was not rebased after disjoint head landing"
  write_verdict "$fixture_repo" 02-tail PASS
  _process_verifier_artefact "$fixture_repo" "$fixture_repo/state/state.yaml" \
    02-tail state/verifiers/02-tail.json ""
  pipeline_after_tail_resolution "$fixture_repo/state/state.yaml" 02-tail
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '[.stages[].status] | join(",")')" \
    completed,completed "both paired stages did not complete"
  assert_eq "$(git -C "$fixture_repo" log -2 --format=%s | tail -n1 | cut -d: -f1)" \
    01-head "ordered landing did not put head before tail"
}

refusal_smoke() {
  new_fixture overlap src src/file
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && fail "overlapping claims formed a pair"
  assert_log 'refused: path claims overlap'

  new_fixture same-family head.txt tail.txt \
    "Codex One <codex-one@local>" "Codex Two <codex-two@local>"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && fail "same-family workers formed a pair"
  assert_log 'refused: worker dispatch targets do not alternate'

  # pipeline.pair_on defaults to family, so two distinct local models must
  # still refuse until a repo opts in. This is the guard that keeps the new
  # key from changing any existing repo's behaviour.
  new_fixture local-models-default head.txt tail.txt \
    "Codex Llama 3.3 70B <codex-llama-3-3-70b@local>" \
    "Codex GPT-OSS 20B <codex-gpt-oss-20b@local>"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && fail "distinct local models paired without pipeline.pair_on: target"
  assert_log 'refused: worker dispatch targets do not alternate'

  # Same two identities under pair_on: target must get past the target gate.
  # It still refuses, on the next gate down (no p95 history in a fresh
  # fixture), which is what proves the target check itself let them through.
  new_fixture local-models-target head.txt tail.txt \
    "Codex Llama 3.3 70B <codex-llama-3-3-70b@local>" \
    "Codex GPT-OSS 20B <codex-gpt-oss-20b@local>"
  printf 'pipeline:\n  pair_on: target\n' >>"$fixture_repo/.autometta.local.yaml"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && true
  grep -Fq 'refused: worker dispatch targets do not alternate' "$smoke_log" \
    && fail "pair_on: target still refused two distinct local models on the target gate"

  new_fixture thin
  jq '.token_cap_total = 500' "$fixture_repo/state/budget.json" \
    >"$fixture_repo/state/budget.json.tmp"
  mv "$fixture_repo/state/budget.json.tmp" "$fixture_repo/state/budget.json"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && fail "thin headroom formed a pair"
  assert_log 'is below two p95 dispatches'

  new_fixture serial-only head.txt scripts/tick.sh
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && fail "serial-only tail tick claim formed a pair"
  assert_log 'tick.sh and scripts/lib claims are serial-only'

  new_fixture serial "" ""
  state_apply_json "$fixture_repo/state/state.yaml" \
    '(.stages[] | select(.id == "02-tail")).gate = {type:"stage_completed", stage_id:"01-head"}'
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && fail "claimless stages formed a pair"
  if grep -Eq 'pipeline pair|pipeline pairing' "$smoke_log"; then
    fail "claimless serial path emitted a pairing decision"
  fi
}

head_fail_fast_forward_smoke() {
  new_fixture head-fail
  local head_work head_pid tail_pid
  head_work="$(ensure_run_worktree "$fixture_repo" 01-head dev)"
  printf 'rejected head\n' >>"$head_work/head.txt"
  start_head_verifier "$fixture_repo"
  head_pid="$started_pid"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head ""
  tail_pid="$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-tail") | .worker_pid')"
  stop_pid "$head_pid"
  write_verdict "$fixture_repo" 01-head FAIL
  _process_verifier_artefact "$fixture_repo" "$fixture_repo/state/state.yaml" \
    01-head state/verifiers/01-head.json ""
  pipeline_after_head_resolution "$fixture_repo/state/state.yaml" 01-head
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.pairing_disabled_stage // empty')" \
    "" "head FAIL set the repo-wide serial latch"
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" \
    | jq -r '.stages[] | select(.id == "01-head") | .pairing_failures // 0')" \
    0 "head verifier FAIL was incorrectly attributed to pairing"
  stop_pid "$tail_pid"
  write_verdict "$fixture_repo" 02-tail PASS
  _process_verifier_artefact "$fixture_repo" "$fixture_repo/state/state.yaml" \
    02-tail state/verifiers/02-tail.json ""
  pipeline_after_tail_resolution "$fixture_repo/state/state.yaml" 02-tail
  assert_eq "$(cat "$fixture_repo/tail.txt" | tail -n1)" "tail output" \
    "tail did not fast-forward after head FAIL"
  assert_eq "$(cat "$fixture_repo/head.txt" | tail -n1)" "base head" \
    "failed head moved the base branch"
  assert_log 'dropped to serial'
}

conflict_escalation_smoke() {
  new_fixture conflict head.txt tail.txt
  local head_work head_pid tail_pid tail_work
  head_work="$(ensure_run_worktree "$fixture_repo" 01-head dev)"
  printf 'head shared\n' >>"$head_work/shared.txt"
  start_head_verifier "$fixture_repo"
  head_pid="$started_pid"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head ""
  tail_pid="$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-tail") | .worker_pid')"
  tail_work="$(worktree_path_for_stage "$fixture_repo" 02-tail)"
  printf 'tail shared\n' >>"$tail_work/shared.txt"
  stop_pid "$head_pid"
  write_verdict "$fixture_repo" 01-head PASS
  _process_verifier_artefact "$fixture_repo" "$fixture_repo/state/state.yaml" \
    01-head state/verifiers/01-head.json ""
  pipeline_after_head_resolution "$fixture_repo/state/state.yaml" 01-head
  stop_pid "$tail_pid"
  if pipeline_prepare_tail_rebase "$fixture_repo" "$fixture_repo/state/state.yaml" 02-tail; then
    fail "actual file overlap was rebased"
  fi
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.pipeline_pair.phase')" \
    controller-escalation "conflict did not escalate"
  assert_eq "$(jq -r '.halt_reason' "$fixture_repo/state/budget.json")" \
    controller-escalation "conflict did not halt for controller escalation"
  assert_log 'no headless conflict resolution attempted'
}

orphaned_verdict_scan_smoke() {
  new_fixture orphaned-verdict
  local head_work head_pid tail_pid
  head_work="$(ensure_run_worktree "$fixture_repo" 01-head dev)"
  printf 'head output\n' >>"$head_work/head.txt"
  start_head_verifier "$fixture_repo"
  head_pid="$started_pid"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head ""
  tail_pid="$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-tail") | .worker_pid')"
  stop_pid "$tail_pid"
  write_verdict "$fixture_repo" 02-tail PASS
  _process_verifier_artefact "$fixture_repo" "$fixture_repo/state/state.yaml" \
    02-tail state/verifiers/02-tail.json ""
  pipeline_after_tail_resolution "$fixture_repo/state/state.yaml" 02-tail
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.current_stage')" \
    null "tail landing did not clear current_stage"
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-tail") | .status')" \
    completed "tail did not land before the orphaned verdict scan"

  write_verdict "$fixture_repo" 01-head PASS
  stop_pid "$head_pid"

  _process_repo_locked "$fixture_repo" ""
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.current_stage')" \
    null "orphaned verdict scan restored current_stage"
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "01-head") | .status')" \
    completed "orphaned head PASS was not consumed"
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-tail") | .status')" \
    completed "tail did not remain landed while the orphaned verdict was consumed"
  assert_log 'stage 01-head verifier artefact found by in-progress verdict scan; consuming'
  assert_log 'stage 01-head PASS: committed worker output'

  new_fixture live-verifier
  start_head_verifier "$fixture_repo"
  head_pid="$started_pid"
  write_verdict "$fixture_repo" 01-head PASS
  state_apply_json "$fixture_repo/state/state.yaml" \
    '(.stages[] | select(.id == "02-tail")).status = "completed"
     | .current_stage = null'
  local head_before head_after
  head_before="$(state_json "$fixture_repo/state/state.yaml" | jq -c '.stages[] | select(.id == "01-head")')"
  _process_repo_locked "$fixture_repo" ""
  head_after="$(state_json "$fixture_repo/state/state.yaml" | jq -c '.stages[] | select(.id == "01-head")')"
  assert_eq "$head_after" "$head_before" "live verifier was touched by the verdict scan"
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.current_stage')" \
    null "live verifier scan changed current_stage"
  stop_pid "$head_pid"

  new_fixture current-fast-path
  write_verdict "$fixture_repo" 01-head PASS
  state_apply_json "$fixture_repo/state/state.yaml" \
    '(.stages[] | select(.id == "02-tail")).status = "completed"'
  _process_repo_locked "$fixture_repo" ""
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "01-head") | .status')" \
    completed "single current-stage verdict was not consumed"
}

# The assertions below are the frozen acceptance spec for stage card 113,
# authored by the orchestrator before any implementation existed
# (docs/dispatch-contract.md:131). A worker satisfies them by changing the
# implementation, never by editing them; fixtures and scaffolding may be
# added outside the markers.
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/113-a-card-pairs-unless-it-says-serial.md
c113_write_bare_card() {
  local path="$1" claims="${2-}" dispatch="${3-}"
  {
    printf '# Stage card %s: smoke fixture\n\n' "$(basename "$path" .md)"
    printf '## Metadata\n\n'
    printf '%s\n' '- **Orchestrator:** Smoke <smoke@local>'
    printf '%s\n' '- **Worker:** Codex Smoke <codex-smoke@local>'
    printf '%s\n' '- **Verifier:** Claude Verify <claude-verify@local>'
    [[ -z "$claims" ]]   || printf '%s\n' "- **Path claims:** ${claims}"
    [[ -z "$dispatch" ]] || printf '%s\n' "- **Dispatch:** ${dispatch}"
    printf '\n## Budget\n\n- **Worker wall-clock:** 10 minutes\n'
  } >"$path"
}

# Acceptance 1. A card says how it dispatches, or it does not queue. The
# silent-serial default is the defect: 58 of 86 stage records carry no
# claims and were made serial by omission, with no line in any log saying so.
c113_queue_time_refusal() {
  local repo="$smoke_tmp/c113-queue" cards="$smoke_tmp/c113-cards"
  mkdir -p "$repo/state" "$cards"
  printf '{"current_stage":null,"stages":[]}\n' >"$repo/state/state.yaml"

  c113_write_bare_card "$cards/05-bare.md"
  if "$repo_source/scripts/add-stage.sh" "$repo" "$cards/05-bare.md" \
       >"$smoke_tmp/c113-bare.out" 2>&1; then
    fail "113: a card with neither Path claims nor a Dispatch line was queued"
  fi
  grep -Fq 'Path claims' "$smoke_tmp/c113-bare.out" \
    || fail "113: the refusal does not quote the Path claims form"
  grep -Fq 'Dispatch:' "$smoke_tmp/c113-bare.out" \
    || fail "113: the refusal does not quote the serial Dispatch form"

  c113_write_bare_card "$cards/06-serial.md" "" serial
  "$repo_source/scripts/add-stage.sh" "$repo" "$cards/06-serial.md" >/dev/null 2>&1 \
    || fail "113: a card declaring serial dispatch was refused"

  c113_write_bare_card "$cards/07-claims.md" "src/b.sh, docs/b.md"
  "$repo_source/scripts/add-stage.sh" "$repo" "$cards/07-claims.md" >/dev/null 2>&1 \
    || fail "113: a card declaring path claims was refused"

  assert_eq "$(yq -o=json '.' "$repo/state/state.yaml" \
    | jq -r '[.stages[].id] | sort | join(",")')" \
    "06-serial,07-claims" "113: exactly the two declaring cards did not queue"
}

# Acceptance 2. A member failure is a fact about one stage, not a repo-wide
# latch -- autometta had been latched serial on stage 106 since 2026-09-01,
# five days of every pair refused by one stale failure. And the counter that
# replaces the latch only counts failures that are evidence about pairing.
# Four pairings against 24 refusals is not enough history to read a verifier
# FAIL as a pairing fault, and a threshold on an undiscriminated signal
# trips on noise.
c113_failure_is_per_stage() {
  new_fixture c113-member-failure
  local head_work head_pid tail_pid
  head_work="$(ensure_run_worktree "$fixture_repo" 01-head dev)"
  printf 'rejected head\n' >>"$head_work/head.txt"
  start_head_verifier "$fixture_repo"
  head_pid="$started_pid"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head ""
  tail_pid="$(state_json "$fixture_repo/state/state.yaml" \
    | jq -r '.stages[] | select(.id == "02-tail") | .worker_pid')"
  stop_pid "$head_pid"
  write_verdict "$fixture_repo" 01-head FAIL
  _process_verifier_artefact "$fixture_repo" "$fixture_repo/state/state.yaml" \
    01-head state/verifiers/01-head.json ""
  pipeline_after_head_resolution "$fixture_repo/state/state.yaml" 01-head
  stop_pid "$tail_pid"

  assert_eq "$(state_json "$fixture_repo/state/state.yaml" \
    | jq -r '.pairing_disabled_stage // ""')" \
    "" "113: a member failure still set the repo-wide pairing latch"
  # A verifier FAIL on the merits is not evidence about pairing.
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" \
    | jq -r '.stages[] | select(.id == "01-head") | .pairing_failures // 0')" \
    0 "113: a verifier FAIL on the merits incremented pairing_failures"

  # A tail that cannot rebase onto the landed head is evidence about
  # pairing, and is the case the counter exists for. It records the count
  # and the cause together, so a later refusal can be explained from state.
  new_fixture c113-rebase-failure head.txt tail.txt
  local rf_head_pid rf_tail_pid rf_head_work rf_tail_work
  rf_head_work="$(ensure_run_worktree "$fixture_repo" 01-head dev)"
  printf 'head shared\n' >>"$rf_head_work/shared.txt"
  start_head_verifier "$fixture_repo"
  rf_head_pid="$started_pid"
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head ""
  rf_tail_pid="$(state_json "$fixture_repo/state/state.yaml" \
    | jq -r '.stages[] | select(.id == "02-tail") | .worker_pid')"
  rf_tail_work="$(worktree_path_for_stage "$fixture_repo" 02-tail)"
  printf 'tail shared\n' >>"$rf_tail_work/shared.txt"
  stop_pid "$rf_head_pid"
  write_verdict "$fixture_repo" 01-head PASS
  _process_verifier_artefact "$fixture_repo" "$fixture_repo/state/state.yaml" \
    01-head state/verifiers/01-head.json ""
  pipeline_after_head_resolution "$fixture_repo/state/state.yaml" 01-head
  stop_pid "$rf_tail_pid"
  pipeline_prepare_tail_rebase "$fixture_repo" "$fixture_repo/state/state.yaml" 02-tail \
    && fail "113: the rebase-failure fixture did not fail to rebase"
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" \
    | jq -r '.stages[] | select(.id == "02-tail") | .pairing_failures // 0')" \
    1 "113: a tail that could not rebase onto the landed head recorded no pairing failure"
  [[ -n "$(state_json "$fixture_repo/state/state.yaml" \
    | jq -r '.stages[] | select(.id == "02-tail") | .pairing_failure_causes // [] | .[-1] // ""')" ]] \
    || fail "113: the increment recorded no attributed cause alongside the count"

  # One attributed failure does not disqualify the stage; two do.
  new_fixture c113-one-failure
  state_apply_json "$fixture_repo/state/state.yaml" \
    '(.stages[] | select(.id == "01-head")).pairing_failures = 1
     | (.stages[] | select(.id == "01-head")).pairing_failure_causes = ["tail-rebase-failed"]'
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" || true
  if grep -Fq 'pairing_failures' "$smoke_log"; then
    fail "113: a stage with one attributed pairing failure was refused on the counter"
  fi

  new_fixture c113-two-failures
  state_apply_json "$fixture_repo/state/state.yaml" \
    '(.stages[] | select(.id == "01-head")).pairing_failures = 2
     | (.stages[] | select(.id == "01-head")).pairing_failure_causes = ["tail-rebase-failed","claim-collision"]'
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && fail "113: a stage with two attributed pairing failures still formed a pair"
  assert_log 'pairing_failures'

  # The counter clears when a re-brief lands for that stage, as the latch it
  # replaces did. Otherwise it is the same permanent disqualification with a
  # per-stage scope.
  new_fixture c113-rebrief-clears
  state_apply_json "$fixture_repo/state/state.yaml" \
    '(.stages[] | select(.id == "01-head")).pairing_failures = 2
     | (.stages[] | select(.id == "01-head")).pairing_failure_causes = ["tail-rebase-failed","claim-collision"]
     | (.stages[] | select(.id == "01-head")).status = "completed"'
  pipeline_pairing_disabled_refresh "$fixture_repo/state/state.yaml" || true
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" \
    | jq -r '.stages[] | select(.id == "01-head") | .pairing_failures // 0')" \
    0 "113: a landed re-brief did not clear the stage's pairing_failures"
}

# Acceptance 3. The serial-only claim rule is about what the *head* may do
# while a tail runs behind it. A docs-only tail cannot collide with anything,
# so refusing it buys nothing and costs a third of a stage's wall-clock.
c113_serial_rule_applies_to_the_head() {
  new_fixture c113-docs-tail scripts/tick.sh docs/tick-loop.md
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" || true
  if grep -Fq 'tick.sh and scripts/lib claims are serial-only' "$smoke_log"; then
    fail "113: a docs-only tail was refused behind a tick.sh head"
  fi

  new_fixture c113-lib-tail scripts/tick.sh scripts/lib/tui/render.py
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && fail "113: a scripts/lib tail formed a pair"
  assert_log 'tick.sh and scripts/lib claims are serial-only'

  new_fixture c113-lib-head scripts/lib/tui/render.py tail.txt
  pipeline_try_dispatch_tail "$fixture_repo" "$fixture_repo/state/state.yaml" 01-head "" \
    && fail "113: a scripts/lib head formed a pair"
  assert_log 'tick.sh and scripts/lib claims are serial-only'
}

c113_queue_time_refusal
c113_failure_is_per_stage
c113_serial_rule_applies_to_the_head
# AUTOMETTA-CONTRACT-END

queue_parser_smoke
formation_and_ordered_landing_smoke
refusal_smoke
head_fail_fast_forward_smoke
conflict_escalation_smoke
orphaned_verdict_scan_smoke

printf 'PASS: pipeline pair queue parsing, formation, refusals, pid checks, ordered landing, rebasing, fast-forward, conflict escalation, serial fallback, and orphaned verdict recovery\n'

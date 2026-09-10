#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Envelope path migration smoke (card 104).
#
# Proves the dual-read the migration hazard demands: a worker writing to the
# new state/envelopes/<stage-id>.json completes a stage, a worker writing to
# the legacy state/handoffs/<stage-id>.json (a subscriber still vendoring a
# pre-card-104 worker-prompt.md) is unaffected, and when both are present the
# new path wins deterministically. See docs/dispatch-contract.md (envelope
# path migration) for the full account of why both are read at all.
#
# Cases 1-4 call the same granular functions tick.sh itself calls at the
# envelope check (worker_envelope_path, handle_missing_completion_dispatch_
# fault, costlog_emit_worker, commit_state_branch), the same pattern
# run-worktree-state-symlink-smoke.sh uses for the neighbouring hazard.
# Cases 5-6 go further and drive the full _process_repo_locked reactor
# end to end (dispatch, worker-exit envelope check, verifier dispatch,
# verifier PASS, land) for a worker on each path, the same throwaway-
# subscriber fixture shape pipeline-pair-smoke.sh and
# preserve-failed-work-smoke.sh use to drive it against no live credentials:
# budget/quota gates are stubbed and spawn_verifier_for_stage stands in a
# background placeholder process for a real verifier.
#
# Run against this tick.sh, this passes. Run against the pre-card-104
# tick.sh (no worker_envelope_path, no state/envelopes read anywhere), this
# fails at the first case with "worker_envelope_path: command not found" --
# which is the point: the smoke only passes once the dual read exists.

smoke_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./tick.sh
source "$smoke_dir/tick.sh"

tmp_root="$(mktemp -d)"
repo_root="$tmp_root/subscriber"
trap 'rm -rf "$tmp_root"' EXIT

budget_halt() { :; }

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

git init -q -b dev "$repo_root"
git -C "$repo_root" config user.name smoke
git -C "$repo_root" config user.email smoke@local
mkdir -p "$repo_root/state/envelopes" "$repo_root/state/handoffs" "$repo_root/state/logs"
touch "$repo_root/state/envelopes/.gitkeep"
git -C "$repo_root" add state/envelopes/.gitkeep
git -C "$repo_root" commit -qm bootstrap

write_envelope() {
  local path="$1" stage_id="$2" status="$3" notes="$4"
  cat >"$path" <<JSON
{"stage_id":"${stage_id}","status":"${status}","deliverables":["x"],"notes":"${notes}"}
JSON
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/104-the-envelope-stops-being-called-a-handoff.md
# --- Case 1: new path only ------------------------------------------------
stage_id="104a-new-only"
new_path="$repo_root/state/envelopes/${stage_id}.json"
old_path="$repo_root/state/handoffs/${stage_id}.json"
write_envelope "$new_path" "$stage_id" pass "new-path worker"

resolved="$(worker_envelope_path "$repo_root" "$stage_id")"
[[ "$resolved" == "$new_path" ]] \
  || fail "new-only: resolved ${resolved}, expected ${new_path}"

if handle_missing_completion_dispatch_fault "$repo_root" "$stage_id" worker "$resolved"; then
  fail "new-only: an existing envelope was misclassified as a dispatch fault"
fi

scripts_validate_out="$("$smoke_dir/validate-envelope.sh" "$resolved")" \
  || fail "new-only: validate-envelope.sh rejected a valid envelope at the new path"
[[ "$scripts_validate_out" == VALID:* ]] \
  || fail "new-only: validate-envelope.sh did not report VALID"

printf 'PASS: a worker writing only state/envelopes/ resolves, validates and is not a dispatch fault\n'

# --- Case 2: legacy path only (the stale-subscriber case) -----------------
stage_id="104b-old-only"
new_path="$repo_root/state/envelopes/${stage_id}.json"
old_path="$repo_root/state/handoffs/${stage_id}.json"
write_envelope "$old_path" "$stage_id" pass "old-path worker"

resolved="$(worker_envelope_path "$repo_root" "$stage_id")"
[[ "$resolved" == "$old_path" ]] \
  || fail "old-only: resolved ${resolved}, expected legacy ${old_path}"
[[ ! -f "$new_path" ]] \
  || fail "old-only: a new-path file was created that should not exist"

if handle_missing_completion_dispatch_fault "$repo_root" "$stage_id" worker "$resolved"; then
  fail "old-only: a stale-subscriber envelope was misclassified as a dispatch fault"
fi

scripts_validate_out="$("$smoke_dir/validate-envelope.sh" "$resolved")" \
  || fail "old-only: validate-envelope.sh rejected a valid envelope at the legacy path"
[[ "$scripts_validate_out" == VALID:* ]] \
  || fail "old-only: validate-envelope.sh did not report VALID"

printf 'PASS: a stale subscriber writing only state/handoffs/ resolves, validates and is not a dispatch fault (this is the case that matters)\n'

# --- Case 3: both present, new must win deterministically ------------------
stage_id="104c-both"
new_path="$repo_root/state/envelopes/${stage_id}.json"
old_path="$repo_root/state/handoffs/${stage_id}.json"
write_envelope "$new_path" "$stage_id" pass "new wins"
write_envelope "$old_path" "$stage_id" fail "old must be ignored"

resolved="$(worker_envelope_path "$repo_root" "$stage_id")"
[[ "$resolved" == "$new_path" ]] \
  || fail "both-present: resolved ${resolved}, expected the new path to win"
resolved_status="$(jq -r '.status' "$resolved")"
[[ "$resolved_status" == "pass" ]] \
  || fail "both-present: resolved envelope carried status=${resolved_status}, expected the new file's pass"

printf 'PASS: with both paths present the new path wins deterministically\n'

# --- Case 4: neither present -- resolves to the canonical new path --------
stage_id="104d-neither"
new_path="$repo_root/state/envelopes/${stage_id}.json"
resolved="$(worker_envelope_path "$repo_root" "$stage_id")"
[[ "$resolved" == "$new_path" ]] \
  || fail "neither-present: resolved ${resolved}, expected the canonical new path as the default"
[[ ! -f "$resolved" ]] \
  || fail "neither-present: resolver reported a path that exists"

printf 'PASS: with neither path present the resolver defaults to the canonical new path\n'

# --- costlog_emit_worker reads through the same resolver -------------------
cat >"$repo_root/state/state.yaml" <<'YAML'
current_stage: null
stages:
  - id: 104a-new-only
    status: in_progress
    worker: Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
  - id: 104b-old-only
    status: in_progress
    worker: Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
YAML

costlog_emit_worker "$repo_root" "$repo_root/state/state.yaml" "104a-new-only" ""
costlog_emit_worker "$repo_root" "$repo_root/state/state.yaml" "104b-old-only" ""

cost_log="$repo_root/state/cost-log.jsonl"
[[ -f "$cost_log" ]] || fail "costlog_emit_worker wrote no state/cost-log.jsonl"
new_result="$(jq -r 'select(.stage_id == "104a-new-only") | .result' "$cost_log")"
old_result="$(jq -r 'select(.stage_id == "104b-old-only") | .result' "$cost_log")"
[[ "$new_result" == "pass" ]] \
  || fail "costlog_emit_worker read result='${new_result}' for the new-path envelope, expected pass"
[[ "$old_result" == "pass" ]] \
  || fail "costlog_emit_worker read result='${old_result}' for the legacy-path envelope, expected pass"

printf 'PASS: costlog_emit_worker resolves the same dual path tick.sh does\n'

# --- commit_state_branch captures state/envelopes for durability -----------
commit_state_branch "$repo_root"
state_ref="$(git -C "$repo_root" rev-parse -q --verify "$state_snapshot_ref" 2>/dev/null || true)"
[[ -n "$state_ref" ]] || fail "commit_state_branch did not create ${state_snapshot_ref}"
git -C "$repo_root" show "${state_ref}:state/envelopes/104a-new-only.json" >/dev/null 2>&1 \
  || fail "the state snapshot did not capture state/envelopes/104a-new-only.json"
git -C "$repo_root" show "${state_ref}:state/handoffs/104b-old-only.json" >/dev/null 2>&1 \
  || fail "the state snapshot did not capture the legacy state/handoffs/104b-old-only.json"

printf 'PASS: the durable state snapshot captures both state/envelopes and state/handoffs\n'

# --- Full-reactor cases: a stage actually completes via _process_repo_locked,
# not just that the dual-read function resolves the right file. Same fixture
# shape as pipeline-pair-smoke.sh's formation_and_ordered_landing_smoke:
# budget/quota gates stubbed (no auth, network or provider dispatch),
# spawn_verifier_for_stage replaced with a background placeholder process.
# Each fixture stage starts in_progress with a live worker_pid, standing in
# for a worker mid-dispatch, because tick.sh's single-stage "pending" branch
# shells out to spawn-worker.sh directly rather than through an overridable
# function; entering mid-flight is how pipeline-pair-smoke.sh's own fixtures
# join the reactor too.

quota_gate_role_dispatch() { return 0; }
budget_gate_dispatch() { return 0; }
budget_drain_active() { return 1; }
commit_state_branch() { return 0; }
ensure_yq_or_halt() { return 0; }
quota_write_repo_state() { return 0; }
budget_ensure_window() { return 0; }
budget_pause_active() { return 1; }
budget_check_caps() { return 0; }

reactor_pids=()
kill_reactor_pids() {
  local pid
  for pid in "${reactor_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap 'kill_reactor_pids; rm -rf "$tmp_root"' EXIT

spawn_verifier_for_stage() {
  local card_path="$1" reactor_repo="$2" reactor_stage_id reactor_pid
  reactor_stage_id="$(basename "$card_path" .md)"
  sleep 300 &
  reactor_pid=$!
  reactor_pids+=( "$reactor_pid" )
  state_apply_json "$reactor_repo/state/state.yaml" \
    '(.stages[] | select(.id == $id)).verifier_pid = $pid
     | (.stages[] | select(.id == $id)).verifier_artefact = $art' \
    --arg id "$reactor_stage_id" --argjson pid "$reactor_pid" \
    --arg art "state/verifiers/${reactor_stage_id}.json"
}

stop_reactor_pid() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

full_reactor_case() {
  local label="$1" envelope_subdir="$2"
  local stage_id="104e-reactor-${label}"
  local repo="$tmp_root/reactor-${label}"
  local worker_id="Smoke Worker <smoke-worker@local>"
  local verifier_id="Smoke Verifier <smoke-verifier@local>"

  mkdir -p "$repo/state/envelopes" "$repo/state/handoffs" "$repo/state/verifiers" \
    "$repo/state/logs" "$repo/stage-cards"
  git -C "$repo" init -q -b dev
  git -C "$repo" config user.name smoke
  git -C "$repo" config user.email smoke@local
  git -C "$repo" config commit.gpgsign false
  printf 'state/**\n' >"$repo/.gitignore"
  cat >"$repo/stage-cards/${stage_id}.md" <<CARD
# Stage card ${stage_id}: reactor smoke fixture

## Metadata

- **Orchestrator:** Smoke <smoke@local>
- **Worker:** ${worker_id}
- **Verifier:** ${verifier_id}

## Budget

- **Worker wall-clock:** 10 minutes
CARD
  git -C "$repo" add .gitignore "stage-cards/${stage_id}.md"
  git -C "$repo" commit -qm bootstrap

  cat >"$repo/state/budget.json" <<'JSON'
{"token_cap_total":10000,"tokens_spent":0,"clock_tick_cap":100,"clock_ticks_used":0,"idle_ticks_used":0,"consecutive_failure_cap":3,"consecutive_failures":0,"wall_clock_cap_seconds":10000,"wall_clock_elapsed_seconds":0,"halted":false}
JSON

  sleep 300 &
  local worker_pid=$!
  reactor_pids+=( "$worker_pid" )

  cat >"$repo/state/state.yaml" <<JSON
{"current_stage":"${stage_id}","stages":[
 {"id":"${stage_id}","status":"in_progress","worker":"${worker_id}","verifier":"${verifier_id}","base_branch":"dev","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","worker_pid":${worker_pid},"verifier_pid":null,"verifier_artefact":null,"verifier_attempts":0}
]}
JSON

  ensure_run_worktree "$repo" "$stage_id" dev >/dev/null \
    || fail "${label}: could not cut a run worktree for the reactor fixture"

  write_envelope "$repo/state/${envelope_subdir}/${stage_id}.json" "$stage_id" pass "reactor worker"

  # Worker pid still alive: the reactor must not touch status yet.
  _process_repo_locked "$repo" ""
  [[ "$(state_json "$repo/state/state.yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id==$id) | .status')" == "in_progress" ]] \
    || fail "${label}: stage status moved while the worker pid was still alive"

  # Worker exits: the reactor must validate the envelope and dispatch a
  # verifier, resolving worker_envelope_path exactly the unit cases above do.
  stop_reactor_pid "$worker_pid"
  _process_repo_locked "$repo" ""

  local dispatched_verifier_pid
  dispatched_verifier_pid="$(state_json "$repo/state/state.yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id==$id) | .verifier_pid // empty')"
  [[ -n "$dispatched_verifier_pid" ]] \
    || fail "${label}: no verifier was dispatched after the worker envelope validated"
  kill -0 "$dispatched_verifier_pid" 2>/dev/null \
    || fail "${label}: the dispatched verifier registration is not a live process"

  jq -n --arg overall PASS --arg headline "reactor ${label}" \
    '{overall:$overall,headline:$headline,criteria:[]}' \
    >"$repo/state/verifiers/${stage_id}.json"

  # Verifier exits with a PASS artefact: the reactor must land the stage.
  stop_reactor_pid "$dispatched_verifier_pid"
  _process_repo_locked "$repo" ""

  local final_status
  final_status="$(state_json "$repo/state/state.yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id==$id) | .status')"
  [[ "$final_status" == "completed" ]] \
    || fail "${label}: stage never reached completed through the full tick reactor (status=${final_status})"

  printf 'PASS: a %s worker completes normally through the full tick/_process_repo_locked reactor\n' "$label"
}

full_reactor_case new-path envelopes
full_reactor_case stale-subscriber handoffs
# AUTOMETTA-CONTRACT-END

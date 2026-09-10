#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

fixture_root="$(mktemp -d)"
fixture_log="$fixture_root/tick.log"
trap 'rm -rf "$fixture_root"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (got $1, expected $2)"; }
assert_log() { grep -Fqx "$1" "$fixture_log" || fail "missing log line: $1"; }

log() { printf '%s\n' "$1" >>"$fixture_log"; }
ensure_yq_or_halt() { return 0; }
quota_write_repo_state() { return 0; }
budget_ensure_window() { return 0; }
budget_pause_active() { return 1; }
budget_drain_active() { return 1; }
budget_check_caps() { return 0; }
quota_gate_role_dispatch() { return 0; }
budget_gate_dispatch() { return 0; }
budget_increment_tick() { printf 'tick %s\n' "$2" >>"$fixture_log"; }
commit_state_branch() { return 0; }
pipeline_prepare_tail_rebase() { return 0; }
verifier_completion_ready() { return 0; }
stage_card_for_id() { printf '%s/docs/stages/%s.md\n' "$1" "$2"; }
resolve_base_branch() { printf 'dev\n'; }
ensure_run_worktree() { printf '%s\n' "$1"; }
halt_dispatch_configuration_fault() { return 0; }
budget_halt() { return 0; }
budget_record_failure() { return 0; }

consume_verifier_artefact() {
  local repo_root="$1" state_yaml="$2" stage_id="$3"
  state_apply_json "$state_yaml" \
    '(.stages[] | select(.id == $id)).status = "completed"
     | (.stages[] | select(.id == $id)).completed_at = "2026-09-06T12:00:00Z"
     | .current_stage = null' --arg id "$stage_id"
  log "landed ${stage_id}"
}

write_worker_stub() {
  local harness="$1"
  mkdir -p "$harness/scripts"
  cat >"$harness/scripts/spawn-worker.sh" <<'STUB'
#!/usr/bin/env bash
printf 'worker %s\n' "$(basename "$1" .md)" >>"$AUTOMETTA_LANDING_SMOKE_LOG"
STUB
  chmod +x "$harness/scripts/spawn-worker.sh"
}

new_fixture() {
  local name="$1" gate="$2"
  fixture_repo="$fixture_root/$name"
  mkdir -p "$fixture_repo/state/verifiers" "$fixture_repo/docs/stages"
  git -C "$fixture_repo" init -q -b dev
  git -C "$fixture_repo" config user.name Smoke
  git -C "$fixture_repo" config user.email smoke@local
  printf 'fixture\n' >"$fixture_repo/README.md"
  printf '# stage 01\n' >"$fixture_repo/docs/stages/01-land.md"
  printf '# stage 02\n' >"$fixture_repo/docs/stages/02-next.md"
  cat >"$fixture_repo/state/budget.json" <<'JSON'
{"halted":false,"clock_ticks_used":0,"idle_ticks_used":0}
JSON
  cat >"$fixture_repo/state/state.yaml" <<EOF
{"current_stage":"01-land","stages":[
 {"id":"01-land","status":"in_progress","worker_pid":null,"verifier_pid":null,"verifier_artefact":"state/verifiers/01-land.json"},
 {"id":"02-next","status":"pending","worker_pid":null,"verifier_pid":null,"gate":${gate}}
]}
EOF
  printf '{"overall":"PASS"}\n' >"$fixture_repo/state/verifiers/01-land.json"
  git -C "$fixture_repo" add .
  git -C "$fixture_repo" commit -qm fixture
  : >"$fixture_log"
}

run_fixture() {
  local harness="$fixture_root/harness"
  write_worker_stub "$harness"
  script_dir="$harness/scripts"
  AUTOMETTA_LANDING_SMOKE_LOG="$fixture_log" _process_repo_locked "$fixture_repo" ""
}

landing_dispatches_next_smoke() {
  new_fixture eligible '{"type":"stage_completed","stage_id":"01-land"}'
  run_fixture
  assert_log 'landed 01-land'
  assert_log 'worker 02-next'
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "01-land") | .status')" completed \
    "landing stage did not complete"
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-next") | .status')" in_progress \
    "eligible next stage did not start"
  [[ "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-next") | .started_at')" \
     > "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "01-land") | .completed_at')" ]] \
    || fail "next stage did not start after the landing timestamp"
}

landing_respects_unmet_gate_smoke() {
  new_fixture blocked '{"type":"stage_completed","stage_id":"99-missing"}'
  run_fixture
  assert_log 'landed 01-land'
  if grep -Fq 'worker 02-next' "$fixture_log"; then
    fail "unmet-gate stage dispatched in landing fire"
  fi
  assert_eq "$(state_json "$fixture_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "02-next") | .status')" pending \
    "unmet-gate stage did not remain pending"
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/115-the-fire-that-lands-a-stage-starts-the-next.md
landing_dispatches_next_smoke
landing_respects_unmet_gate_smoke
# AUTOMETTA-CONTRACT-END

printf 'PASS landing dispatch smoke\n'

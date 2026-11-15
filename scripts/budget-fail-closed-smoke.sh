#!/usr/bin/env bash
# budget-fail-closed-smoke.sh: an unreadable budget.json, a failing tick step
# or a failing state render stops that repo's dispatch and nothing else
# (card 167).
#
# Every case is a throwaway fleet under a temporary AUTOMETTA_HOME. The tick
# is sourced by a driver that runs as its own bash process, so no `||` in this
# file can suspend errexit inside the code under test. Nothing is dispatched:
# spawn-worker.sh is a stub that records which repo asked for a worker.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: 167-budget-reads-fail-closed: %s\n' "$1" >&2
  exit 1
}

real_yq="$(command -v yq)" || fail "yq is not on PATH"
real_jq="$(command -v jq)" || fail "jq is not on PATH"
today="$(date -u +%F)"
export AUTOMETTA_NOTIFY=0

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/167-budget-reads-fail-closed.md
harness="$tmp/harness"
mkdir -p "$harness" "$tmp/bin"
for f in "$script_dir"/*; do
  ln -s "$f" "$harness/$(basename "$f")"
done
rm -f "$harness/spawn-worker.sh" "$harness/check-deps.sh"
cat > "$harness/spawn-worker.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$2")" >> "$AUTOMETTA_SMOKE_DISPATCHES"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$harness/check-deps.sh"
chmod +x "$harness/spawn-worker.sh" "$harness/check-deps.sh"

# yq that renders YAML badly on demand, and jq that fails the budget window
# write on demand; each is the real tool otherwise.
cat > "$tmp/bin/yq" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-P" ]]; then
  case "${YQ_STUB_MODE:-pass}" in
    fail-partial) printf 'version: 1\nstages:\n'; exit 1 ;;
    empty) exit 0 ;;
  esac
fi
exec "$AUTOMETTA_SMOKE_REAL_YQ" "$@"
STUB
cat > "$tmp/bin/jq" <<'STUB'
#!/usr/bin/env bash
if [[ "${JQ_STUB_MODE:-pass}" == "fail-window-write" ]]; then
  prev=""
  for a in "$@"; do
    [[ "$prev" == "--arg" && "$a" == "today" ]] && exit 5
    prev="$a"
  done
fi
exec "$AUTOMETTA_SMOKE_REAL_JQ" "$@"
STUB
chmod +x "$tmp/bin/yq" "$tmp/bin/jq"

# The driver stubs only what this card does not judge: agents, displays,
# quota readers, run worktrees and the state branch. Budget, state writes,
# process_repo and main are the real code. quota_write_repo_state is called
# plainly inside _process_repo_locked; its background probe leaves a marker
# only when errexit is suspended in that context.
cat > "$tmp/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
# shellcheck source=/dev/null
source "$AUTOMETTA_SMOKE_SCRIPTS/tick.sh"
script_dir="$AUTOMETTA_SMOKE_HARNESS"
log() { printf '%s\n' "$*" >> "$AUTOMETTA_SMOKE_LOG"; }
run_heartbeat() { :; }
warn_if_vendor_stale() { :; }
quota_refresh_tick() { :; }
quota_log_tick_readings() { :; }
quota_write_repo_state() {
  ( false; : > "$1/errexit-was-off" ) &
  wait "$!" || :
}
quota_gate_role_dispatch() { return 0; }
sweep_controller_log_retention() { :; }
reap_idle_dash_sessions() { :; }
escalations_scan() { : > "$1/escalations-scanned"; }
ensure_tmux_viewer() { :; }
sweep_repo_retention() { :; }
commit_state_branch() { :; }
network_preflight_ok() { return 0; }
resolve_base_branch() { printf 'dev\n'; }
stage_card_for_id() { printf '%s/stage-cards/%s.md\n' "$1" "$2"; }
ensure_run_worktree() { printf '%s\n' "$1"; }
auto_retry_dead_workers() { [[ ! -e "$1/fail-auto-retry" ]]; }
rc=0
case "$1" in
  fire) main ;;
  write-atomic) budget_write_atomic "$2" '.clock_ticks_used += 1' || rc=$? ;;
  write-atomic-error) budget_write_atomic "$2" 'error("smoke")' || rc=$? ;;
  write-atomic-multi) budget_write_atomic "$2" '., .' || rc=$? ;;
  ensure-window) budget_ensure_window "$2" || rc=$? ;;
  check-caps) budget_check_caps "$2" || rc=$? ;;
  gate) budget_gate_dispatch "$2" "smoke dispatch" || rc=$? ;;
  apply-state)
    [[ -z "${AUTOMETTA_SMOKE_TMPDIR:-}" ]] || export TMPDIR="$AUTOMETTA_SMOKE_TMPDIR"
    state_apply_json "$2/state/state.yaml" '.smoke = true' || rc=$? ;;
esac
printf '%s\n' "$rc" > "$AUTOMETTA_SMOKE_RC"
DRIVER

truncated_budget='{"halted":true,"halt_reason":"token-cap","tokens_spent":999999999,"token_cap_total":1000,
 "wall_clock_elapsed_seconds":0,"wall_clock_cap_seconds":3600,"clock_ticks_used":0,"clock_tick_cap":400,
 "consecutive_failures":0,"consecutive_failure_cap":3,"window_started_at":"2000-01-01"
'

new_fleet() {
  fleet="$tmp/$1"
  mkdir -p "$fleet/home/subscribers" "$fleet/home/log"
  : > "$fleet/dispatches"
  : > "$fleet/tick.log"
}

write_budget() {
  local dir="$1" kind="$2" window="$today"
  case "$kind" in
    healthy|stale-window)
      [[ "$kind" == "healthy" ]] || window="2000-01-01"
      printf '{"version":1,"token_cap_total":1000000,"tokens_spent":0,"wall_clock_cap_seconds":86400,"wall_clock_elapsed_seconds":0,"clock_tick_cap":400,"clock_ticks_used":0,"consecutive_failure_cap":3,"consecutive_failures":0,"halted":false,"window_started_at":"%s"}\n' \
        "$window" > "$dir/state/budget.json" ;;
    truncated) printf '%s' "$truncated_budget" > "$dir/state/budget.json" ;;
    empty) : > "$dir/state/budget.json" ;;
    whitespace) printf '  \n\n' > "$dir/state/budget.json" ;;
    array) printf '[]\n' > "$dir/state/budget.json" ;;
    null) printf 'null\n' > "$dir/state/budget.json" ;;
    missing) rm -f "$dir/state/budget.json" ;;
  esac
}

write_state() {
  local dir="$1" current="$2" status="$3"
  cat > "$dir/state/state.yaml" <<YAML
version: 1
current_stage: $current
stages:
  - id: 01-work
    status: $status
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    worker_pid: null
    verifier_pid: null
YAML
}

new_repo() {
  local name="$1" weight="$2" budget="$3" current="${4:-null}" status="${5:-pending}"
  local dir="$fleet/$name"
  mkdir -p "$dir/state" "$dir/stage-cards"
  (
    cd "$dir"
    git init -q -b dev .
    git config user.email smoke@local
    git config user.name smoke
    git config commit.gpgsign false
    printf 'state/**\n' > .gitignore
    printf '# stage 01-work\n' > stage-cards/01-work.md
    git add -A
    git commit -qm seed
  )
  write_state "$dir" "$current" "$status"
  write_budget "$dir" "$budget"
  printf 'repo_path: "%s"\nweight: %s\nenabled: true\n' "$dir" "$weight" \
    > "$fleet/home/subscribers/$name.yaml"
}

drive() {
  AUTOMETTA_HOME="$fleet/home" PHAT_CONTROLLER_HOME="$fleet/home" \
    AUTOMETTA_ESCALATIONS="$fleet/escalations" \
    AUTOMETTA_SMOKE_SCRIPTS="$script_dir" AUTOMETTA_SMOKE_HARNESS="$harness" \
    AUTOMETTA_SMOKE_LOG="$fleet/tick.log" AUTOMETTA_SMOKE_DISPATCHES="$fleet/dispatches" \
    AUTOMETTA_SMOKE_RC="$fleet/rc" AUTOMETTA_SMOKE_REAL_YQ="$real_yq" AUTOMETTA_SMOKE_REAL_JQ="$real_jq" \
    PATH="$tmp/bin:$PATH" \
    bash "$tmp/driver.sh" "$@" >> "$fleet/driver.out" 2>&1 || true
}

unit_rc() {
  rm -f "$fleet/rc"
  drive "$@"
  [[ -s "$fleet/rc" ]] || fail "the driver did not finish '$1' (see the smoke's own output)"
  cat "$fleet/rc"
}

dispatched() { grep -Fqx "$1" "$fleet/dispatches"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fileid() { python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino, s.st_mtime_ns)' "$1"; }
fire_output() { cat "$fleet/tick.log" "$fleet/driver.out"; }
names_integrity() {
  fire_output | grep -F 'budget-integrity:' | grep -Fq "$fleet/$1/state/budget.json"
}
logs_rc() {
  local repo="$1" pattern="$2"
  fire_output | grep -F "$fleet/$repo" | grep -Eq "rc=${pattern}([^0-9]|$)"
}
errexit_live() { [[ ! -e "$fleet/$1/errexit-was-off" ]]; }
finished_cleanly() {
  [[ ! -d "$fleet/$1/state/.tick.lock" ]] || fail "($2) $1's tick lock was left behind"
  [[ -e "$fleet/$1/escalations-scanned" ]] || fail "($2) the escalations scan did not run for $1"
}

# H2: an unreadable budget refuses dispatch, is left as it was, and is named.
new_fleet h2
new_repo a-truncated 10 truncated
new_repo b-empty 20 empty
new_repo c-missing 30 missing
new_repo d-array 40 array
new_repo e-healthy 50 healthy
truncated_sha="$(sha "$fleet/a-truncated/state/budget.json")"
truncated_id="$(fileid "$fleet/a-truncated/state/budget.json")"
empty_id="$(fileid "$fleet/b-empty/state/budget.json")"
array_sha="$(sha "$fleet/d-array/state/budget.json")"
drive fire
unreadable=(a-truncated b-empty c-missing d-array)
for r in "${unreadable[@]}"; do
  ! dispatched "$r" || fail "(h2) a worker was dispatched for $r, whose budget.json is unreadable"
done
dispatched e-healthy || fail "(h2) the healthy repo after the unreadable budgets was not dispatched"
errexit_live e-healthy || fail "(h2) errexit was suspended inside e-healthy's fire"
for fire in 1 2; do
  [[ "$(sha "$fleet/a-truncated/state/budget.json")" == "$truncated_sha" \
     && "$(fileid "$fleet/a-truncated/state/budget.json")" == "$truncated_id" ]] \
    || fail "(h2) fire $fire rewrote, moved or recreated the truncated budget.json"
  [[ -f "$fleet/b-empty/state/budget.json" && ! -s "$fleet/b-empty/state/budget.json" \
     && "$(fileid "$fleet/b-empty/state/budget.json")" == "$empty_id" ]] \
    || fail "(h2) fire $fire replaced, rewrote or removed the empty budget.json"
  [[ ! -e "$fleet/c-missing/state/budget.json" ]] || fail "(h2) fire $fire created a budget.json for a repo that had none"
  [[ "$(sha "$fleet/d-array/state/budget.json")" == "$array_sha" ]] || fail "(h2) fire $fire rewrote the array budget.json"
  for r in "${unreadable[@]}"; do
    names_integrity "$r" || fail "(h2) fire $fire wrote no budget-integrity: line naming $r/state/budget.json"
    logs_rc "$r" '[1-9][0-9]*' || fail "(h2) fire $fire logged no non-zero rc for subscriber $r"
    finished_cleanly "$r" h2
  done
  if [[ "$fire" == "1" ]]; then
    rm -f "$fleet/home/subscribers/e-healthy.yaml" "$fleet"/*/escalations-scanned
    : > "$fleet/tick.log"
    : > "$fleet/driver.out"
    new_repo f-healthy 60 healthy
    drive fire
    for r in "${unreadable[@]}"; do
      ! dispatched "$r" || fail "(h2) a second fire dispatched a worker for $r"
    done
    dispatched f-healthy || fail "(h2) the second fire did not reach the healthy subscriber after the unreadable budgets"
  fi
done

# H2: each budget function refuses explicitly, even where errexit is suspended.
new_fleet units
new_repo u-budget 10 healthy
for fn in write-atomic ensure-window check-caps gate; do
  for kind in truncated empty whitespace array null missing; do
    write_budget "$fleet/u-budget" "$kind"
    before="absent"
    [[ -e "$fleet/u-budget/state/budget.json" ]] && before="$(sha "$fleet/u-budget/state/budget.json")"
    got="$(unit_rc "$fn" "$fleet/u-budget")"
    [[ "$got" != "0" ]] || fail "(h2) $fn returned 0 on a $kind budget.json inside a condition"
    if [[ "$fn" == "check-caps" ]]; then
      [[ "$got" != "1" && "$got" != "2" ]] \
        || fail "(h2) budget_check_caps reported a $kind budget.json as a cap hit or halt (rc $got)"
    fi
    after="absent"
    [[ -e "$fleet/u-budget/state/budget.json" ]] && after="$(sha "$fleet/u-budget/state/budget.json")"
    [[ "$after" == "$before" ]] || fail "(h2) $fn changed a $kind budget.json inside a condition"
    ! compgen -G "$fleet/u-budget/state/budget.json.tmp.*" >/dev/null \
      || fail "(h2) $fn left a budget.json.tmp file behind on a $kind budget.json"
  done
done
for wcase in write-atomic-error write-atomic-multi ensure-window; do
  kind=healthy
  [[ "$wcase" == "ensure-window" ]] && kind=stale-window
  write_budget "$fleet/u-budget" "$kind"
  before="$(sha "$fleet/u-budget/state/budget.json")"
  if [[ "$wcase" == "ensure-window" ]]; then
    got="$(JQ_STUB_MODE=fail-window-write unit_rc "$wcase" "$fleet/u-budget")"
  else
    got="$(unit_rc "$wcase" "$fleet/u-budget")"
  fi
  [[ "$got" != "0" ]] || fail "(h2) $wcase returned 0 after its budget write failed"
  [[ "$(sha "$fleet/u-budget/state/budget.json")" == "$before" ]] \
    || fail "(h2) $wcase replaced a readable budget.json with a failed write"
  ! compgen -G "$fleet/u-budget/state/budget.json.tmp.*" >/dev/null \
    || fail "(h2) $wcase left a budget.json.tmp file behind after a failed write"
done
write_budget "$fleet/u-budget" healthy
for fn in write-atomic ensure-window check-caps gate; do
  [[ "$(unit_rc "$fn" "$fleet/u-budget")" == "0" ]] || fail "(h2) $fn refused a readable budget.json"
done
[[ "$(jq -r '.clock_ticks_used' "$fleet/u-budget/state/budget.json")" == "1" ]] \
  || fail "(h2) budget_write_atomic did not write a readable budget.json"

# L2: one subscriber's non-zero return does not end the fleet fire.
new_fleet l2
new_repo bad-stage 10 healthy '"Bad_Stage"'
new_repo next-healthy 20 healthy
drive fire
dispatched next-healthy || fail "(l2) a subscriber returning non-zero stopped the rest of the fleet fire"
logs_rc bad-stage 1 || fail "(l2) the fire did not log the failing subscriber's path with rc=1"
finished_cleanly bad-stage l2
errexit_live next-healthy || fail "(l2) errexit was suspended inside next-healthy's fire"

# errexit: a failing step stops that repo's fire before it dispatches.
new_fleet errexit
new_repo step-fails 10 healthy
: > "$fleet/step-fails/fail-auto-retry"
new_repo next-healthy 20 healthy
drive fire
errexit_live step-fails || fail "(errexit) errexit was suspended inside step-fails's fire"
! dispatched step-fails || fail "(errexit) a repo whose tick step failed went on to dispatch a worker"
dispatched next-healthy || fail "(errexit) the subscriber after a failing step was not dispatched"
logs_rc step-fails '[1-9][0-9]*' || fail "(errexit) the fire logged no non-zero rc for the failing subscriber"
finished_cleanly step-fails errexit

# L3: a failed or empty YAML render never replaces state.yaml.
new_fleet l3
new_repo s-apply 10 healthy
new_repo q-requeue 20 healthy null failed
mkdir -p "$fleet/tmpdir"
for mode in fail-partial empty; do
  write_state "$fleet/s-apply" null pending
  write_state "$fleet/q-requeue" null failed
  before="$(sha "$fleet/s-apply/state/state.yaml")"
  got="$(YQ_STUB_MODE="$mode" AUTOMETTA_SMOKE_TMPDIR="$fleet/tmpdir" unit_rc apply-state "$fleet/s-apply")"
  [[ "$got" == "1" ]] || fail "(l3) state_apply_json returned $got, not 1, when yq -P was $mode"
  [[ "$(sha "$fleet/s-apply/state/state.yaml")" == "$before" ]] \
    || fail "(l3) state_apply_json replaced state.yaml when yq -P was $mode"
  [[ -z "$(ls -A "$fleet/tmpdir")" ]] || fail "(l3) state_apply_json left temp files behind when yq -P was $mode"

  before="$(sha "$fleet/q-requeue/state/state.yaml")"
  requeue_rc=0
  YQ_STUB_MODE="$mode" AUTOMETTA_SMOKE_REAL_YQ="$real_yq" AUTOMETTA_HOME="$fleet/home" PATH="$tmp/bin:$PATH" \
    AUTOMETTA_SMOKE_REAL_JQ="$real_jq" \
    bash "$script_dir/requeue-stage.sh" --keep-budget "$fleet/q-requeue" 01-work \
    >> "$fleet/requeue.out" 2>&1 || requeue_rc=$?
  [[ "$requeue_rc" != "0" ]] || fail "(l3) requeue-stage.sh exited 0 when yq -P was $mode"
  [[ "$(sha "$fleet/q-requeue/state/state.yaml")" == "$before" ]] \
    || fail "(l3) requeue-stage.sh replaced state.yaml when yq -P was $mode"
done
write_state "$fleet/s-apply" null pending
got="$(unit_rc apply-state "$fleet/s-apply")"
[[ "$got" == "0" && "$(yq -r '.smoke' "$fleet/s-apply/state/state.yaml")" == "true" ]] \
  || fail "(l3) state_apply_json no longer writes state when yq renders normally"
# AUTOMETTA-CONTRACT-END

printf 'PASS budget fail-closed smoke\n'

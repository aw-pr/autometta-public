#!/usr/bin/env bash
# network-fault-smoke.sh: offline proof that a dead network costs no dispatch
# and that a credential-resolution death halts once instead of eating the
# failure cap. Card 108. No auth, no live agent, no token spend, and -- the
# point of the exercise -- no dependency on the machine's real resolver: every
# tick here runs against a stub `dig` that either answers or does not.
#
# Both cases replay the 2026-09-03 evening watch, where the machine's
# resolvers died at about 22:35 and the loop spent a 50-minute worker, two
# instant launch failures and a stale quota read before anyone noticed.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd "$script_dir/.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

export PHAT_CONTROLLER_HOME="$tmp_root/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/subscribers" "$PHAT_CONTROLLER_HOME/log"

fail=0
check() {
  local description="$1" result="$2"
  if [[ "$result" == "ok" ]]; then
    printf '  PASS: %s\n' "$description" >&2
  else
    printf '  FAIL: %s (%s)\n' "$description" "$result" >&2
    fail=1
  fi
}
eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }
yes_no() { [[ "$1" == "yes" ]] && printf 'ok\n' || printf '%s\n' "$2"; }

# The op-fetch line the watch recorded verbatim, twice, at 23:26 and 23:33.
OP_FETCH_LINE='op-fetch: error: failed to resolve CLAUDE_CODE_OAUTH_TOKEN (op exit 1)'

# --- stubs -----------------------------------------------------------------
# Two resolver stubs and one dispatch stub. `op-fetch` stands in for the whole
# provider CLI chain and records that a dispatch was attempted, which is how
# "starts no process" is asserted.
stub_bin="$tmp_root/stub"
mkdir -p "$stub_bin"
printf '#!/bin/sh\nexit 0\n' > "$stub_bin/tmux"
cat > "$stub_bin/op-fetch" <<'SH'
#!/bin/sh
printf 'dispatched\n' >> "$SMOKE_DISPATCH_LEDGER"
exit 0
SH
chmod +x "$stub_bin/tmux" "$stub_bin/op-fetch"

answering_resolver="$tmp_root/resolver-up"
mkdir -p "$answering_resolver"
cat > "$answering_resolver/dig" <<'SH'
#!/bin/sh
echo 160.79.104.10
SH
chmod +x "$answering_resolver/dig"

# --- harnesses -------------------------------------------------------------
# A harness is a copy of the shipped scripts, so a tick under test is the real
# tick found by its own script_dir rather than a model of one.
copy_harness() {
  local destination="$1"
  mkdir -p "$destination"
  cp -R "$source_root/scripts" "$source_root/templates" "$source_root/bin" "$destination/"
}

# The candidate with its preflight replaced by a stub that always refuses,
# which is criterion 1's construction: the dead network is simulated at the
# preflight boundary, not inside the tick.
dead_root="$tmp_root/harness-dead-preflight"
copy_harness "$dead_root"
cat > "$dead_root/scripts/preflight-network.sh" <<'SH'
#!/bin/sh
echo 'api.anthropic.com did not resolve: dig exited 1' >&2
exit 1
SH
chmod +x "$dead_root/scripts/preflight-network.sh"

# The candidate as shipped. Its preflight is real, and the resolver stub on
# PATH is what it measures.
live_root="$tmp_root/harness-candidate"
copy_harness "$live_root"

# The pre-change tick: no dispatch consulted the network, and the instant-fault
# alternation did not carry op-fetch's two credential-resolution shapes. Both
# reversions are asserted, so this frozen model fails loudly if it drifts from
# the code it claims to be the "before" of, rather than quietly passing.
prechange_root="$tmp_root/harness-prechange"
copy_harness "$prechange_root"
rm -f "$prechange_root/scripts/preflight-network.sh"
python3 - "$prechange_root/scripts/tick.sh" <<'PY'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
text = path.read_text()

gate = '''network_preflight_ok() {
  NETWORK_PREFLIGHT_REASON=""
  local output rc=0
  output="$("$script_dir/preflight-network.sh" 2>&1)" || rc=$?
  if (( rc == 0 )); then
    return 0
  fi
  NETWORK_PREFLIGHT_REASON="$(printf '%s\\n' "$output" | head -n 1)"
  [[ -n "$NETWORK_PREFLIGHT_REASON" ]] || NETWORK_PREFLIGHT_REASON="preflight exited ${rc}"
  return 1
}'''
if gate not in text:
    sys.exit("pre-change model drift: the preflight gate is not where it was")
text = text.replace(gate, 'network_preflight_ok() { return 0; }', 1)

widened = '|requires .*auth_mode|failed to resolve|op exit [0-9]+"'
if widened not in text:
    sys.exit("pre-change model drift: the widened fault alternation is not where it was")
text = text.replace(widened, '|requires .*auth_mode"', 1)

path.write_text(text)
PY

# --- fixture subscriber ----------------------------------------------------
write_card() {
  local repo="$1" stage_id="$2"
  cat > "$repo/stage-cards/${stage_id}.md" <<CARD
# Stage card ${stage_id}

## Metadata

- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>

## Budget

- **Worker wall-clock:** 30 minutes
CARD
}

# name -> repo path. Every fixture is one repo with one stage, so a tick has
# exactly one thing it could spend and the assertions are unambiguous.
make_repo() {
  local name="$1" stage_id="$2" state_body="$3"
  local repo="$tmp_root/$name"
  mkdir -p "$repo/state/envelopes" "$repo/state/verifiers" "$repo/state/logs" "$repo/stage-cards"
  write_card "$repo" "$stage_id"
  (
    cd "$repo"
    git init -q -b dev .
    git config user.email smoke@local
    git config user.name smoke
    git config commit.gpgsign false
    printf 'state/**\n' > .gitignore
    git add -A
    git commit -qm seed
  ) >/dev/null 2>&1
  printf '%s\n' "$state_body" > "$repo/state/state.yaml"
  cat > "$repo/state/budget.json" <<JSON
{
  "version": 1,
  "token_cap_total": 100000000,
  "tokens_spent": 0,
  "wall_clock_cap_seconds": 86400,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 400,
  "clock_ticks_used": 0,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "halt_reason": null,
  "halted_at": null,
  "window_started_at": "$(date -u +%F)"
}
JSON
  printf '%s' "$repo"
}

subscribe_only() {
  local repo="$1"
  rm -f "$PHAT_CONTROLLER_HOME"/subscribers/*.yaml
  cat > "$PHAT_CONTROLLER_HOME/subscribers/$(basename "$repo").yaml" <<YAML
repo_path: "$repo"
weight: 100
enabled: true
YAML
}

# Run one real tick from the given harness, with the given resolver directory
# first on PATH. Returns the tick's own stdout+stderr in a file.
run_tick() {
  local harness="$1" repo="$2" resolver_dir="$3" label="$4"
  subscribe_only "$repo"
  SMOKE_DISPATCH_LEDGER="$repo/state/dispatch-ledger" \
    PATH="$resolver_dir:$stub_bin:$PATH" \
    AUTOMETTA_ROOT="$harness" \
    "$harness/scripts/tick.sh" > "$tmp_root/$label.out" 2>&1 || true
}

controller_log() { printf '%s\n' "$PHAT_CONTROLLER_HOME/log/tick-$(date +%F).log"; }
tick_output() { cat "$tmp_root/$1.out" "$(controller_log)" 2>/dev/null; }
dispatched() {
  [[ -s "$1/state/dispatch-ledger" ]] && printf 'yes\n' || printf 'no\n'
}
stage_field() { yq -r "$2" "$1/state/state.yaml"; }
budget_field() { jq -r "$2" "$1/state/budget.json"; }

pending_state() {
  cat <<YAML
version: 1
current_stage: null
last_tick_at: "2026-09-03T20:00:00Z"
tick_count: 0
clock_tick_budget_remaining: 400
stages:
  - id: 108-fixture-pending
    status: pending
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
    started_at: null
    worker_pid: null
    verifier_pid: null
    verifier_artefact: null
    verifier_attempts: 0
    completed_at: null
YAML
}

# --- case (a): a dead network defers, it does not fail ---------------------
printf '== a. a refusing preflight defers the dispatch ==\n' >&2

deferred_repo="$(make_repo deferred 108-fixture-pending "$(pending_state)")"
run_tick "$dead_root" "$deferred_repo" "$answering_resolver" deferred

a_log="$(tick_output deferred)"
a_deferral_logged=no
[[ "$a_log" == *'dispatch deferred: network preflight failed (api.anthropic.com did not resolve: dig exited 1)'* ]] \
  && a_deferral_logged=yes
a_dispatched="$(dispatched "$deferred_repo")"
a_status="$(stage_field "$deferred_repo" '.stages[0].status')"
a_started="$(stage_field "$deferred_repo" '.stages[0].started_at')"
a_worker_pid="$(stage_field "$deferred_repo" '.stages[0].worker_pid')"
a_verifier_attempts="$(stage_field "$deferred_repo" '.stages[0].verifier_attempts')"
a_stall_marker="$(stage_field "$deferred_repo" '.stages[0].stall_marker // "none"')"
a_failures="$(budget_field "$deferred_repo" '.consecutive_failures')"
a_halted="$(budget_field "$deferred_repo" '.halted')"
a_worktree=no
[[ -e "$tmp_root/deferred-run-108-fixture-pending" ]] && a_worktree=yes

# The same fixture, the same harness, through the pre-change tick: no gate, so
# it spends the dispatch the dead network was never going to serve.
prechange_a_repo="$(make_repo prechange-deferred 108-fixture-pending "$(pending_state)")"
run_tick "$prechange_root" "$prechange_a_repo" "$answering_resolver" prechange-deferred
a_prechange_dispatched="$(dispatched "$prechange_a_repo")"
a_prechange_status="$(stage_field "$prechange_a_repo" '.stages[0].status')"

# --- criterion 3: an answering resolver is dispatched against --------------
printf '== c. an answering resolver passes the preflight and dispatches ==\n' >&2

preflight_rc=0
preflight_started="$(date +%s)"
PATH="$answering_resolver:$PATH" "$source_root/scripts/preflight-network.sh" \
  >/dev/null 2>&1 || preflight_rc=$?
preflight_elapsed=$(( $(date +%s) - preflight_started ))

live_repo="$(make_repo live 108-fixture-pending "$(pending_state)")"
run_tick "$live_root" "$live_repo" "$answering_resolver" live
c_dispatched="$(dispatched "$live_repo")"
c_status="$(stage_field "$live_repo" '.stages[0].status')"

# --- case (b): a credential-resolution death halts once --------------------
printf '== b. an op-fetch resolution failure is a configuration fault ==\n' >&2

# The stage is in_progress with a dead worker pid, no envelope, and a tiny log
# holding the watch's line, written at the moment of dispatch. That is the
# whole evidence the classifier has.
halting_state() {
  local started="$1"
  cat <<YAML
version: 1
current_stage: 108-fixture-op-fetch
last_tick_at: "$started"
tick_count: 0
clock_tick_budget_remaining: 400
stages:
  - id: 108-fixture-op-fetch
    status: in_progress
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
    started_at: "$started"
    worker_pid: 999999
    verifier_pid: null
    verifier_artefact: null
    verifier_attempts: 0
    completed_at: null
YAML
}

make_op_fetch_fixture() {
  local name="$1" started
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local repo
  repo="$(make_repo "$name" 108-fixture-op-fetch "$(halting_state "$started")")"
  printf '%s\n' "$OP_FETCH_LINE" > "$repo/state/logs/108-fixture-op-fetch-worker.log"
  # A dispatched stage has a run worktree whose `state` is a symlink back to
  # the subscriber's. Without it the tick reads a missing envelope as the
  # broken-symlink dispatch fault and never reaches the log at all, which is a
  # different fault wearing the same halt reason.
  local work_dir="$tmp_root/${name}-run-108-fixture-op-fetch"
  mkdir -p "$work_dir"
  ln -sfn "$repo/state" "$work_dir/state"
  printf '%s' "$repo"
}

halt_repo="$(make_op_fetch_fixture op-fetch-fault)"
run_tick "$live_root" "$halt_repo" "$answering_resolver" op-fetch-fault
b_halted="$(budget_field "$halt_repo" '.halted')"
b_halt_reason="$(budget_field "$halt_repo" '.halt_reason')"
b_halt_reasons="$(budget_field "$halt_repo" '.halt_reasons | join(",")')"
b_failures="$(budget_field "$halt_repo" '.consecutive_failures')"
b_stall_marker="$(stage_field "$halt_repo" '.stages[0].stall_marker // "none"')"

prechange_b_repo="$(make_op_fetch_fixture prechange-op-fetch)"
run_tick "$prechange_root" "$prechange_b_repo" "$answering_resolver" prechange-op-fetch
b_prechange_halt_reason="$(budget_field "$prechange_b_repo" '.halt_reason')"
b_prechange_failures="$(budget_field "$prechange_b_repo" '.consecutive_failures')"

# An ordinary worker error is not a credential failure, and the widened
# alternation must not swallow it into a repo-wide halt.
ordinary_repo="$(make_op_fetch_fixture ordinary-failure)"
printf 'error: three of the six frames did not render\n' \
  > "$ordinary_repo/state/logs/108-fixture-op-fetch-worker.log"
run_tick "$live_root" "$ordinary_repo" "$answering_resolver" ordinary-failure
b_ordinary_halt_reason="$(budget_field "$ordinary_repo" '.halt_reason')"

printf '\n== assertions ==\n' >&2
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/108-a-dead-network-does-not-spend-a-dispatch.md
check "a refusing preflight logs the deferral with its reason" "$(yes_no "$a_deferral_logged" 'deferral line absent')"
check "a refusing preflight starts no process" "$(eq no "$a_dispatched")"
check "the deferred stage is still pending" "$(eq pending "$a_status")"
check "the deferred stage was not stamped started_at" "$(eq null "$a_started")"
check "the deferred stage holds no worker pid" "$(eq null "$a_worker_pid")"
check "the deferred stage consumed no attempt" "$(eq 0 "$a_verifier_attempts")"
check "the deferred stage is not marked stalled" "$(eq none "$a_stall_marker")"
check "the deferral counted no failure" "$(eq 0 "$a_failures")"
check "the deferral is not a halt" "$(eq false "$a_halted")"
check "the deferral cut no run worktree" "$(eq no "$a_worktree")"
check "the pre-change tick spends the dispatch anyway" "$(eq yes "$a_prechange_dispatched")"
check "the pre-change tick moves the stage to in_progress" "$(eq in_progress "$a_prechange_status")"
check "an answering resolver passes the preflight" "$(eq 0 "$preflight_rc")"
check "the preflight costs under two seconds" "$( (( preflight_elapsed < 2 )) && printf 'ok\n' || printf 'took %ss\n' "$preflight_elapsed")"
check "a tick behind an answering resolver dispatches" "$(eq yes "$c_dispatched")"
check "the dispatched stage moves to in_progress" "$(eq in_progress "$c_status")"
check "the op-fetch resolution failure halts the repo" "$(eq true "$b_halted")"
check "the halt reason carries the op-fetch line" "$(yes_no "$( [[ "$b_halt_reason" == *"$OP_FETCH_LINE"* ]] && echo yes || echo no )" "halt_reason was ${b_halt_reason}")"
check "the halt reason keeps its category" "$(yes_no "$( [[ "$b_halt_reason" == dispatch-configuration-fault:* ]] && echo yes || echo no )" "halt_reason was ${b_halt_reason}")"
check "the halt ledger stays a single category token" "$(eq dispatch-configuration-fault "$b_halt_reasons")"
check "the stage is marked a worker dispatch fault" "$(eq dispatch_configuration_fault:worker "$b_stall_marker")"
check "the halt did not spend the failure cap" "$(eq 0 "$b_failures")"
check "the pre-change tick did not recognise the fault" "$(yes_no "$( [[ "$b_prechange_halt_reason" != *"$OP_FETCH_LINE"* ]] && echo yes || echo no )" "pre-change halt_reason was ${b_prechange_halt_reason}")"
check "the pre-change tick charged it to the failure cap instead" "$(eq 1 "$b_prechange_failures")"
check "an ordinary worker error is still not a configuration fault" "$(eq null "$b_ordinary_halt_reason")"
# AUTOMETTA-CONTRACT-END

if (( fail )); then
  printf '\nnetwork-fault-smoke: FAIL\n' >&2
  exit 1
fi
printf '\nnetwork-fault-smoke: all assertions passed\n' >&2

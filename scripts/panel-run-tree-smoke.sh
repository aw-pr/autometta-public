#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Offline replay of a panel-mode verifier dispatched by the tick reactor
# (_process_repo_locked -> spawn-verifier.sh -> spawn-verifier-panel.sh).
# op-fetch, agent-whoami and dig are stubs on PATH: each stub panellist
# records the tree it was pointed at and the credential names it was handed,
# then casts a scripted vote. No network, no agent, no spend.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
smoke_tmp="$(mktemp -d)"
smoke_pids=()
cleanup() {
  local pid file
  for pid in "${smoke_pids[@]:-}"; do
    [[ -n "$pid" ]] || continue
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  for file in "$smoke_tmp"/*/state/active-agents/*.json; do
    [[ -f "$file" ]] || continue
    pid="$(jq -r '.pid // empty' "$file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  case "$smoke_tmp" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$smoke_tmp" ;; esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: 170-the-panel-verifies-the-run-tree: %s\n' "$1"
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/170-the-panel-verifies-the-run-tree.md

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

smoke_log="$smoke_tmp/tick.log"
: >"$smoke_log"
log() { printf '%s\n' "$1" >>"$smoke_log"; }
quota_gate_role_dispatch() { return 0; }
budget_gate_dispatch() { return 0; }
budget_drain_active() { return 1; }
commit_state_branch() { return 0; }
ensure_yq_or_halt() { return 0; }
quota_write_repo_state() { return 0; }
budget_ensure_window() { return 0; }
budget_pause_active() { return 1; }
budget_check_caps() { return 0; }

stub_bin="$smoke_tmp/bin"
mkdir -p "$stub_bin" "$smoke_tmp/codex-api-home"
printf '{"auth_mode":"apikey"}\n' >"$smoke_tmp/codex-api-home/auth.json"
: >"$smoke_tmp/no-local-refs.sh"

# Stub panellist. Records: stage, role, tree, artefact path, --add-dir roots,
# credential names. Votes from PANEL_STUB_<ROLE>; anything else is a crash.
cat >"$stub_bin/op-fetch" <<'STUB'
#!/usr/bin/env bash
set -u
pairs=""
while [[ $# -gt 0 && "$1" != "--" ]]; do
  case "$1" in
    --pass) shift ;;
    *) pairs="$pairs ${1%%=*}" ;;
  esac
  shift
done
[[ $# -gt 0 ]] && shift
cmd="${1:-}"
[[ $# -gt 0 ]] && shift
role="" dir="" rawdir="" out="" model="" adddirs="" last=""
for arg in "$@"; do last="$arg"; done
case "$cmd" in
  python3)
    dir="$(pwd -P)"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --out) out="${2:-}"; shift ;;
        --model) model="${2:-}"; shift ;;
      esac
      shift
    done
    case "$model" in *opus*) role=opus ;; *sonnet*) role=sonnet ;; *) role="sdk-${model}" ;; esac
    ;;
  codex)
    role=codex
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -C) rawdir="${2:-}"; dir="$(cd "${2:-/nonexistent}" 2>/dev/null && pwd -P)"; shift ;;
        --add-dir) adddirs="$adddirs $(cd "${2:-/nonexistent}" 2>/dev/null && pwd -P)"; shift ;;
      esac
      shift
    done
    out="$(printf '%s\n' "$last" | grep -oE '[^[:space:]`"]*\.panel/codex\.json' | head -n1)"
    ;;
  *) role="other-${cmd}" ;;
esac
stage="$(basename "$(dirname "${out:-none/none}")" .panel)"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$stage" "$role" "$dir" "$out" "${adddirs# }" "${pairs# }" >>"$PANEL_STUB_LOG"
printf 'Total tokens: 1000\n'
# A Codex CLI panellist also leaves a session transcript keyed by its cwd.
if [[ "$role" == codex && -n "${AUTOMETTA_CODEX_TRANSCRIPT_ROOTS:-}" && -d "${AUTOMETTA_CODEX_TRANSCRIPT_ROOTS}" ]]; then
  printf '{"type":"session_meta","payload":{"cwd":"%s","timestamp":"%s"}}\n{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":600,"cached_input_tokens":0,"output_tokens":400,"total_tokens":1000}}}}\n' \
    "$rawdir" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${AUTOMETTA_CODEX_TRANSCRIPT_ROOTS}/${stage}-codex.jsonl"
fi
sleep "${PANEL_STUB_DELAY:-0}"
case "$role" in
  opus) vote="${PANEL_STUB_OPUS:-}" ;;
  sonnet) vote="${PANEL_STUB_SONNET:-}" ;;
  codex) vote="${PANEL_STUB_CODEX:-}" ;;
  *) vote="" ;;
esac
case "$vote" in
  PASS|FAIL)
    [[ -n "$out" && -d "$(dirname "$out")" ]] || exit 1
    printf '{"overall":"%s","criteria":[]}\n' "$vote" >"$out"
    ;;
  *) exit 1 ;;
esac
STUB
cat >"$stub_bin/agent-whoami" <<'STUB'
#!/bin/sh
echo 'GPT-6.1 Sol <gpt-6-1-sol@local>'
STUB
printf '#!/bin/sh\necho 192.0.2.1\n' >"$stub_bin/dig"
chmod +x "$stub_bin/op-fetch" "$stub_bin/agent-whoami" "$stub_bin/dig"

export PATH="$stub_bin:$PATH"
export PANEL_STUB_LOG="$smoke_tmp/panellists.tsv"
: >"$PANEL_STUB_LOG"
export AUTOMETTA_LOCAL_REFS="$smoke_tmp/no-local-refs.sh"
export OP_REF_ANTHROPIC_API_KEY="op://smoke-vault/anthropic/credential"
export OP_REF_OPENAI_API_KEY="op://smoke-vault/openai/credential"
export AUTOMETTA_CODEX_HOME="$smoke_tmp/codex-api-home"
export AUTOMETTA_PANEL_POLL_INTERVAL=1
export AUTOMETTA_HOME="$smoke_tmp/controller" PHAT_CONTROLLER_HOME="$smoke_tmp/controller"
mkdir -p "$AUTOMETTA_HOME/log"
export AUTOMETTA_CODEX_TRANSCRIPT_ROOTS="$smoke_tmp/codex-sessions"
mkdir -p "$AUTOMETTA_CODEX_TRANSCRIPT_ROOTS"
unset AUTOMETTA_VERIFIER_PANEL AUTOMETTA_CLAUDE_MODE AUTOMETTA_CODEX_MODE \
  AUTOMETTA_CLAUDE_MODE_VERIFIER AUTOMETTA_CODEX_MODE_VERIFIER \
  AUTOMETTA_CLAUDE_MODE_WORKER AUTOMETTA_CODEX_MODE_WORKER

stage_field() { state_json "$1/state/state.yaml" | jq -r --arg id "$2" ".stages[] | select(.id == \$id) | .$3 // empty"; }
physical() { (cd "$1" 2>/dev/null && pwd -P); }
checksum() { cat "$1/state/state.yaml" "$1/state/budget.json" | shasum -a 256 | cut -d' ' -f1; }

# A subscriber whose stage is in_progress with a returned worker: pass
# envelope written, worker pid gone, run worktree holding the worker's change
# to src/feature.txt. The card asks for a panel.
new_panel_fixture() {
  local stage_id="$1" repo="$smoke_tmp/$1" work worker_pid
  mkdir -p "$repo/state/envelopes" "$repo/state/verifiers" "$repo/state/logs" \
    "$repo/stage-cards" "$repo/src"
  git -C "$repo" init -q -b dev
  git -C "$repo" config user.name smoke
  git -C "$repo" config user.email smoke@local
  git -C "$repo" config commit.gpgsign false
  printf 'state/**\n' >"$repo/.gitignore"
  printf 'base\n' >"$repo/src/feature.txt"
  cat >"$repo/stage-cards/${stage_id}.md" <<CARD
# Stage card ${stage_id}: panel smoke fixture

## Metadata

- **Orchestrator:** Smoke <smoke@local>
- **Worker:** Smoke Worker <smoke-worker@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Verifier panel:** true

## Deliverables

1. \`src/feature.txt\`: the worker's change.

## Budget

- **Worker wall-clock:** 10 minutes
- **Verifier wall-clock:** 10 minutes
CARD
  git -C "$repo" add .gitignore src/feature.txt "stage-cards/${stage_id}.md"
  git -C "$repo" commit -qm bootstrap
  cat >"$repo/state/budget.json" <<'JSON'
{"token_cap_total":1000000,"tokens_spent":0,"clock_tick_cap":100,"clock_ticks_used":0,"idle_ticks_used":0,"consecutive_failure_cap":3,"consecutive_failures":0,"wall_clock_cap_seconds":100000,"wall_clock_elapsed_seconds":0,"halted":false}
JSON
  sleep 300 &
  worker_pid=$!
  smoke_pids+=("$worker_pid")
  cat >"$repo/state/state.yaml" <<JSON
{"current_stage":"${stage_id}","stages":[
 {"id":"${stage_id}","status":"in_progress","worker":"Smoke Worker <smoke-worker@local>","verifier":"GPT-6.1 Sol <gpt-6-1-sol@local>","base_branch":"dev","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","worker_pid":${worker_pid},"verifier_pid":null,"verifier_artefact":null,"verifier_attempts":0}
]}
JSON
  work="$(ensure_run_worktree "$repo" "$stage_id" dev)"
  [[ -n "$work" && -d "$work" ]] || fail "fixture: no run worktree for ${stage_id}"
  printf 'worker change\n' >"$work/src/feature.txt"
  printf '{"stage_id":"%s","status":"pass","deliverables":["src/feature.txt"],"notes":"smoke"}\n' \
    "$stage_id" >"$repo/state/envelopes/${stage_id}.json"
  kill "$worker_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
}

dispatch_elapsed=0
dispatch_panel() {
  local repo="$smoke_tmp/$1" t0 t1
  export PANEL_STUB_OPUS="$2" PANEL_STUB_SONNET="$3" PANEL_STUB_CODEX="$4"
  export PANEL_STUB_DELAY=30
  t0="$(date +%s)"
  _process_repo_locked "$repo" "" >/dev/null 2>&1 || true
  t1="$(date +%s)"
  dispatch_elapsed=$((t1 - t0))
}

after_dispatch_checks() {
  local id="$1" repo="$smoke_tmp/$1" vpid
  (( dispatch_elapsed < 15 )) \
    || fail "${id}: the tick fire that dispatched the panel blocked for ${dispatch_elapsed}s (panellists take 30s; want under 15s)"
  [[ "$(jq -r '.halted' "$repo/state/budget.json")" != true ]] \
    || fail "${id}: dispatching the panel halted the repo ($(jq -r '.halt_reason // empty' "$repo/state/budget.json"))"
  [[ "$(stage_field "$repo" "$id" status)" == in_progress ]] \
    || fail "${id}: stage status is '$(stage_field "$repo" "$id" status)' after the panel dispatch, want in_progress"
  vpid="$(stage_field "$repo" "$id" verifier_pid)"
  [[ "$vpid" =~ ^[0-9]+$ ]] || fail "${id}: no verifier_pid recorded for the panel"
  kill -0 "$vpid" 2>/dev/null || fail "${id}: the recorded verifier_pid ${vpid} is not a live panel process"
  smoke_pids+=("$vpid")
  [[ "$(stage_field "$repo" "$id" verifier_artefact)" == "state/verifiers/${id}.json" ]] \
    || fail "${id}: verifier_artefact is '$(stage_field "$repo" "$id" verifier_artefact)', want state/verifiers/${id}.json"
  [[ "$(ps -o pgid= -p "$vpid" | tr -d ' ')" == "$vpid" ]] \
    || fail "${id}: the panel process ${vpid} does not lead its own process group"
  [[ "$(jq -r '.working_dir // empty' "$repo/state/active-agents/${vpid}.json" 2>/dev/null)" == "$(worktree_path_for_stage "$repo" "$id")" ]] \
    || fail "${id}: the panel process is not registered in state/active-agents with the run worktree as its working_dir"
}

# Scenario A: majority PASS. Its routes come from the per-role verifier keys
# alone, so a panel resolving family-wide routes finds no API credential.
new_panel_fixture 70-panel-pass
export AUTOMETTA_CLAUDE_MODE_VERIFIER=api AUTOMETTA_CODEX_MODE_VERIFIER=api
dispatch_panel 70-panel-pass PASS PASS FAIL
unset AUTOMETTA_CLAUDE_MODE_VERIFIER AUTOMETTA_CODEX_MODE_VERIFIER
after_dispatch_checks 70-panel-pass
sum_pass="$(checksum "$smoke_tmp/70-panel-pass")"

# Scenarios B and C use family-wide routes: claude api, codex subscription.
export AUTOMETTA_CLAUDE_MODE=api
new_panel_fixture 70-panel-fail
dispatch_panel 70-panel-fail FAIL FAIL PASS
after_dispatch_checks 70-panel-fail
sum_fail="$(checksum "$smoke_tmp/70-panel-fail")"

new_panel_fixture 70-panel-noquorum
dispatch_panel 70-panel-noquorum PASS crash crash
after_dispatch_checks 70-panel-noquorum
sum_noquorum="$(checksum "$smoke_tmp/70-panel-noquorum")"

new_panel_fixture 70-panel-tie
dispatch_panel 70-panel-tie PASS FAIL crash
after_dispatch_checks 70-panel-tie
sum_tie="$(checksum "$smoke_tmp/70-panel-tie")"
unset AUTOMETTA_CLAUDE_MODE

# The panels finish in the background. Nothing but the tick writes state.yaml
# or budget.json, so both are byte-identical until the next fire.
for id in 70-panel-pass 70-panel-fail 70-panel-noquorum 70-panel-tie; do
  vpid="$(stage_field "$smoke_tmp/$id" "$id" verifier_pid)"
  for _ in $(seq 1 90); do
    kill -0 "$vpid" 2>/dev/null || break
    sleep 1
  done
  ! kill -0 "$vpid" 2>/dev/null || fail "${id}: the panel process ${vpid} was still running after 90s"
done
[[ "$(checksum "$smoke_tmp/70-panel-pass")" == "$sum_pass" ]] \
  || fail "70-panel-pass: the background panel wrote state.yaml or budget.json"
[[ "$(checksum "$smoke_tmp/70-panel-fail")" == "$sum_fail" ]] \
  || fail "70-panel-fail: the background panel wrote state.yaml or budget.json"
[[ "$(checksum "$smoke_tmp/70-panel-noquorum")" == "$sum_noquorum" ]] \
  || fail "70-panel-noquorum: the background panel wrote state.yaml or budget.json"
[[ "$(checksum "$smoke_tmp/70-panel-tie")" == "$sum_tie" ]] \
  || fail "70-panel-tie: the background panel wrote state.yaml or budget.json"

# Every panellist was pointed at the stage's run worktree, not the checkout.
for id in 70-panel-pass 70-panel-fail 70-panel-noquorum 70-panel-tie; do
  repo="$smoke_tmp/$id"
  work_phys="$(physical "$(worktree_path_for_stage "$repo" "$id")")"
  state_phys="$(physical "$repo/state")"
  [[ -n "$work_phys" && -n "$state_phys" ]] || fail "${id}: fixture paths did not resolve"
  for role in opus sonnet codex; do
    record="$(awk -F'\t' -v s="$id" -v r="$role" '$1 == s && $2 == r' "$PANEL_STUB_LOG")"
    [[ -n "$record" ]] || fail "${id}: no ${role} panellist was dispatched"
    [[ "$(printf '%s\n' "$record" | wc -l | tr -d ' ')" == 1 ]] \
      || fail "${id}: the ${role} panellist was dispatched more than once"
    [[ "$(printf '%s\n' "$record" | cut -f3)" == "$work_phys" ]] \
      || fail "${id}: the ${role} panellist verified '$(printf '%s\n' "$record" | cut -f3)', not the run worktree ${work_phys}"
  done
  codex_adddirs="$(awk -F'\t' -v s="$id" '$1 == s && $2 == "codex" { print $5 }' "$PANEL_STUB_LOG")"
  grant_ok=false
  for dir in $(printf '%s\n' "$codex_adddirs" | tr ' ' '\n'); do
    [[ "$dir" == "$state_phys" || "$dir" == "$state_phys"/* ]] && grant_ok=true
  done
  [[ "$grant_ok" == true ]] \
    || fail "${id}: the codex panellist got no --add-dir grant on the subscriber state (got '${codex_adddirs}')"
done

# Routes resolve per role: scenario A set only the verifier keys.
for role in opus sonnet; do
  awk -F'\t' -v r="$role" '$1 == "70-panel-pass" && $2 == r { print $6 }' "$PANEL_STUB_LOG" \
    | grep -qw ANTHROPIC_API_KEY \
    || fail "70-panel-pass: the ${role} panellist did not get the verifier route's ANTHROPIC_API_KEY"
done
awk -F'\t' '$1 == "70-panel-pass" && $2 == "codex" { print $6 }' "$PANEL_STUB_LOG" \
  | grep -qw OPENAI_API_KEY \
  || fail "70-panel-pass: the codex panellist did not get the verifier route's OPENAI_API_KEY"

# The synthesis is the verdict, and a missing quorum is never a PASS.
synth() { jq -r "$2" "$smoke_tmp/$1/state/verifiers/$1.json" 2>/dev/null || true; }
[[ "$(synth 70-panel-pass .overall)" == PASS ]] || fail "70-panel-pass: synthesis overall is '$(synth 70-panel-pass .overall)', want PASS"
[[ "$(synth 70-panel-fail .overall)" == FAIL ]] || fail "70-panel-fail: synthesis overall is '$(synth 70-panel-fail .overall)', want FAIL"
[[ "$(synth 70-panel-noquorum .overall)" == FAIL ]] \
  || fail "70-panel-noquorum: synthesis overall is '$(synth 70-panel-noquorum .overall)', want FAIL"
[[ "$(synth 70-panel-noquorum .quorum.achieved)" == 1 && "$(synth 70-panel-noquorum .quorum.required)" == 2 ]] \
  || fail "70-panel-noquorum: synthesis quorum is achieved '$(synth 70-panel-noquorum .quorum.achieved)' of required '$(synth 70-panel-noquorum .quorum.required)', want 1 of 2"
synth 70-panel-noquorum .additional_findings | grep -qi 'no quorum' \
  || fail "70-panel-noquorum: the synthesis does not say 'no quorum' in additional_findings"
[[ "$(synth 70-panel-tie .overall)" == FAIL ]] || fail "70-panel-tie: synthesis overall is '$(synth 70-panel-tie .overall)', want FAIL"
synth 70-panel-tie .additional_findings | grep -qi 'tie' \
  || fail "70-panel-tie: the synthesis does not say 'tie' in additional_findings"

# The next fire consumes each synthesis through the ordinary verifier path.
for id in 70-panel-pass 70-panel-fail 70-panel-noquorum 70-panel-tie; do
  _process_repo_locked "$smoke_tmp/$id" "" >/dev/null 2>&1 || true
done
repo="$smoke_tmp/70-panel-pass"
[[ "$(stage_field "$repo" 70-panel-pass status)" == completed ]] \
  || fail "70-panel-pass: a PASS majority left the stage '$(stage_field "$repo" 70-panel-pass status)', want completed"
[[ "$(git -C "$repo" show dev:src/feature.txt 2>/dev/null)" == 'worker change' ]] \
  || fail "70-panel-pass: dev does not carry the run worktree's change after the PASS landed"
for id in 70-panel-pass 70-panel-fail; do
  repo="$smoke_tmp/$id"
  [[ "$(jq -r '.tokens_spent' "$repo/state/budget.json")" == 3000 ]] \
    || fail "${id}: budget charged $(jq -r '.tokens_spent' "$repo/state/budget.json") tokens for three 1000-token panellists (one with a Codex transcript), want 3000"
  [[ "$(stage_field "$repo" "$id" verifier_tokens)" == 3000 ]] \
    || fail "${id}: the stage's verifier_tokens snapshot is '$(stage_field "$repo" "$id" verifier_tokens)', want 3000"
  [[ "$(jq -r --arg id "$id" 'select(.stage_id == $id and .role == "verifier") | .total_tokens' "$repo/state/cost-log.jsonl" 2>/dev/null | tail -n1)" == 3000 ]] \
    || fail "${id}: the cost-log verifier row does not record 3000 tokens"
done
for id in 70-panel-fail 70-panel-noquorum 70-panel-tie; do
  repo="$smoke_tmp/$id"
  [[ "$(stage_field "$repo" "$id" status)" == verifier_failed ]] \
    || fail "${id}: the stage is '$(stage_field "$repo" "$id" status)' after the panel's FAIL, want verifier_failed"
  [[ "$(jq -r '.halted' "$repo/state/budget.json")" != true ]] \
    || fail "${id}: the panel's FAIL halted the repo ($(jq -r '.halt_reason // empty' "$repo/state/budget.json"))"
done
! grep -q 'dispatch-configuration-fault' "$smoke_log" \
  || fail "a panel verdict was logged as a dispatch-configuration-fault"

# A genuine configuration fault still fails the spawn, in the foreground,
# before any panellist starts: no API route for the Claude panellists.
new_panel_fixture 70-panel-preflight
repo="$smoke_tmp/70-panel-preflight"
export PANEL_STUB_DELAY=0 PANEL_STUB_OPUS=PASS PANEL_STUB_SONNET=PASS PANEL_STUB_CODEX=PASS
pf_rc=0
t0="$(date +%s)"
"$script_dir/spawn-verifier.sh" "$repo/stage-cards/70-panel-preflight.md" "$repo" \
  "$(worktree_path_for_stage "$repo" 70-panel-preflight)" >/dev/null 2>&1 || pf_rc=$?
t1="$(date +%s)"
(( pf_rc != 0 )) || fail "preflight: a panel with no Claude API route exited 0"
(( t1 - t0 < 15 )) || fail "preflight: the refused panel took $((t1 - t0))s to exit"
! awk -F'\t' '$1 == "70-panel-preflight"' "$PANEL_STUB_LOG" | grep -q . \
  || fail "preflight: a panellist was started although the preflight failed"
[[ -z "$(stage_field "$repo" 70-panel-preflight verifier_pid)" ]] \
  || fail "preflight: a verifier_pid was recorded although the preflight failed"

# autometta panel (--read-only) stays synchronous: synthesis on stdout, exit 0
# for PASS and 1 for FAIL, and never state.yaml, budget.json or the canonical
# artefact.
new_panel_fixture 70-panel-readonly
repo="$smoke_tmp/70-panel-readonly"
sum_ro="$(checksum "$repo")"
export AUTOMETTA_CLAUDE_MODE=api PANEL_STUB_DELAY=0 PANEL_STUB_OPUS=PASS PANEL_STUB_SONNET=PASS PANEL_STUB_CODEX=PASS
ro_rc=0
ro_out="$("$script_dir/spawn-verifier-panel.sh" "$repo/stage-cards/70-panel-readonly.md" "$repo" --read-only 2>/dev/null)" || ro_rc=$?
[[ "$(printf '%s' "$ro_out" | jq -r '.overall' 2>/dev/null || true)" == PASS && "$ro_rc" == 0 ]] \
  || fail "read-only: autometta panel printed no PASS synthesis on stdout with exit 0 (exit ${ro_rc})"
export PANEL_STUB_OPUS=FAIL PANEL_STUB_SONNET=FAIL PANEL_STUB_CODEX=PASS
ro_rc=0
ro_out="$("$script_dir/spawn-verifier-panel.sh" "$repo/stage-cards/70-panel-readonly.md" "$repo" --read-only 2>/dev/null)" || ro_rc=$?
unset AUTOMETTA_CLAUDE_MODE
[[ "$(printf '%s' "$ro_out" | jq -r '.overall' 2>/dev/null || true)" == FAIL && "$ro_rc" == 1 ]] \
  || fail "read-only: a FAIL majority did not print a FAIL synthesis with exit 1 (exit ${ro_rc})"
[[ "$(checksum "$repo")" == "$sum_ro" ]] || fail "read-only: the read-only panel wrote state.yaml or budget.json"
[[ ! -e "$repo/state/verifiers/70-panel-readonly.json" ]] || fail "read-only: the read-only panel wrote the canonical artefact"

# The docs describe the panel the tick now runs.
grep -q 'run worktree' "$script_dir/../docs/verifier-panel.md" \
  || fail "docs/verifier-panel.md does not say the panel verifies the run worktree"
! grep -q 'verifier_panel_no_quorum' "$script_dir/../docs/verifier-panel.md" \
  || fail "docs/verifier-panel.md still describes the verifier_panel_no_quorum status"
! grep -q 'verifier_panel_no_quorum' "$script_dir/../schemas/verifier-panel.json" \
  || fail "schemas/verifier-panel.json still describes the verifier_panel_no_quorum status"
! grep -q 'pass_count >= fail_count' "$script_dir/../schemas/verifier-panel.json" \
  || fail "schemas/verifier-panel.json still says PASS needs only pass_count >= fail_count"
grep -q 'AUTOMETTA_PANEL_POLL_INTERVAL' "$script_dir/../docs/verifier-panel.md" \
  || fail "docs/verifier-panel.md does not document AUTOMETTA_PANEL_POLL_INTERVAL"
grep -qi 'background' "$script_dir/../docs/verifier-panel.md" \
  || fail "docs/verifier-panel.md does not say the panel runs in the background under the tick"

# AUTOMETTA-CONTRACT-END

printf 'PASS: panel-run-tree-smoke\n'

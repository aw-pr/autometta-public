#!/usr/bin/env bash
# gate-smoke.sh: offline regression proof for declared dispatch gates.
# No auth, network call, live provider, or token spend.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root_real="$(cd "$script_dir/.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

export PHAT_CONTROLLER_HOME="$tmp_root/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/subscribers" "$PHAT_CONTROLLER_HOME/log" "$tmp_root/stub"

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

# The tick opens tmux and routes every worker through op-fetch. These stubs
# keep the smoke offline. A pre-fix stage-60 dispatch writes the same failing
# envelope its worker wrote on 2026-08-24, so the second tick records the old
# false failure rather than merely proving that a process started.
printf '#!/bin/sh\nexit 0\n' > "$tmp_root/stub/tmux"
cat > "$tmp_root/stub/op-fetch" <<'SH'
#!/bin/sh
case "$*" in
  *60-the-controller-can-see-the-window*)
    mkdir -p "$SMOKE_REPO/state/handoffs"
    cat > "$SMOKE_REPO/state/handoffs/60-the-controller-can-see-the-window.json" <<'JSON'
{
  "stage_id": "60-the-controller-can-see-the-window",
  "status": "fail",
  "deliverables": [],
  "notes": "Blocked by the declared stage-completed gate: prerequisite 58 is not completed.",
  "worker_identity": "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
}
JSON
    ;;
esac
exit 0
SH
chmod +x "$tmp_root/stub/tmux" "$tmp_root/stub/op-fetch"

write_budget() {
  local repo="$1"
  cat > "$repo/state/budget.json" <<JSON
{
  "version": 1,
  "token_cap_total": 1000000,
  "tokens_spent": 0,
  "wall_clock_cap_seconds": 86400,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 400,
  "clock_ticks_used": 0,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "window_started_at": "$(date -u +%F)"
}
JSON
}

write_card() {
  local repo="$1" stage_id="$2"
  cat > "$repo/docs/stages/${stage_id}.md" <<CARD
# Stage card ${stage_id}

## Metadata

- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Dispatch:** serial

## Budget

- **Worker wall-clock:** 30 minutes
CARD
}

make_repo() {
  local name="$1" ledger="$2"
  local repo="$tmp_root/$name"
  # Legacy layout is intentional: the pre-fix replay predates stage-cards/.
  mkdir -p "$repo/state/handoffs" "$repo/state/verifiers" "$repo/state/logs" "$repo/docs/stages"
  write_card "$repo" 50-stage-cards-live-in-stage-cards
  write_card "$repo" 58-the-controller-decides-the-scripts-are-its-verbs
  write_card "$repo" 60-the-controller-can-see-the-window
  write_card "$repo" 62-next-eligible-stage
  (
    cd "$repo"
    git init -q -b dev .
    git config user.email smoke@local
    git config user.name smoke
    git config commit.gpgsign false
    printf 'state/**\n' > .gitignore
    git add -A
    git commit -qm seed
  )
  cp "$ledger" "$repo/state/state.yaml"
  write_budget "$repo"
  cat > "$PHAT_CONTROLLER_HOME/subscribers/${name}.yaml" <<YAML
repo_path: "$repo"
weight: 100
enabled: true
YAML
  printf '%s' "$repo"
}

run_tick() {
  local tick_script="$1" repo="$2"
  SMOKE_REPO="$repo" PATH="$tmp_root/stub:$PATH" "$tick_script" \
    >> "$tmp_root/$(basename "$repo")-tick-output.log" 2>&1 || true
}

drop_subscriber() {
  rm -f "$PHAT_CONTROLLER_HOME/subscribers/$1.yaml"
}

printf '== 1. queue-time parsing ==\n' >&2
parse_repo="$tmp_root/parse"
mkdir -p "$parse_repo/state" "$parse_repo/cards"
cat > "$parse_repo/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages: []
last_tick_at: "2026-08-25T00:00:00Z"
tick_count: 0
clock_tick_budget_remaining: 10
YAML
cat > "$parse_repo/cards/60-gated-stage.md" <<'CARD'
# Stage card 60
- **Worker:** Worker <worker@local>
- **Verifier:** Verifier <verifier@local>
- **Gate:** stage-completed: 58-the-controller-decides-the-scripts-are-its-verbs
- **Dispatch:** serial
CARD
cat > "$parse_repo/cards/62-ungated-stage.md" <<'CARD'
# Stage card 62
- **Worker:** Worker <worker@local>
- **Verifier:** Verifier <verifier@local>
- **Dispatch:** serial
CARD
"$script_dir/add-stage.sh" "$parse_repo" "$parse_repo/cards/60-gated-stage.md" >/dev/null
"$script_dir/add-stage.sh" "$parse_repo" "$parse_repo/cards/62-ungated-stage.md" >/dev/null

printf '  gated record: %s\n' \
  "$(yq -o=json '.stages[] | select(.id == "60-gated-stage")' "$parse_repo/state/state.yaml" | jq -c .)" >&2
printf '  ungated record: %s\n' \
  "$(yq -o=json '.stages[] | select(.id == "62-ungated-stage")' "$parse_repo/state/state.yaml" | jq -c .)" >&2
check "a declared gate is stored structurally" \
  "$(eq stage_completed "$(yq -r '.stages[] | select(.id == "60-gated-stage") | .gate.type' "$parse_repo/state/state.yaml")")"
check "the prerequisite is stored by full id" \
  "$(eq 58-the-controller-decides-the-scripts-are-its-verbs "$(yq -r '.stages[] | select(.id == "60-gated-stage") | .gate.stage_id' "$parse_repo/state/state.yaml")")"
check "an ungated record has no gate field" \
  "$(eq false "$(yq -r '.stages[] | select(.id == "62-ungated-stage") | has("gate")' "$parse_repo/state/state.yaml")")"

cat > "$parse_repo/cards/63-bad-gate.md" <<'CARD'
# Stage card 63
- **Worker:** Worker <worker@local>
- **Verifier:** Verifier <verifier@local>
- **Gate:** after 58
CARD
before_count="$(yq -r '.stages | length' "$parse_repo/state/state.yaml")"
bad_log="$tmp_root/bad-gate.log"
if "$script_dir/add-stage.sh" "$parse_repo" "$parse_repo/cards/63-bad-gate.md" 2>"$bad_log"; then
  bad_result="add-stage accepted the malformed line"
else
  bad_result=ok
fi
check "an unparseable Gate line is refused" "$bad_result"
check "the refusal names the line" \
  "$([[ "$(cat "$bad_log")" == *'- **Gate:** after 58'* ]] && printf ok || printf 'line absent from refusal')"
check "the refusal does not append a stage" \
  "$(eq "$before_count" "$(yq -r '.stages | length' "$parse_repo/state/state.yaml")")"

printf '== 2. dependency gate step-over and the pre-fix replay ==\n' >&2
cat > "$tmp_root/dependency.yaml" <<'YAML'
version: 1
current_stage: null
last_tick_at: "2026-08-25T00:00:00Z"
tick_count: 0
clock_tick_budget_remaining: 400
stages:
  - id: 58-the-controller-decides-the-scripts-are-its-verbs
    status: failed
    worker: Worker
    verifier: Verifier
  - id: 60-the-controller-can-see-the-window
    status: pending
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
    started_at: null
    worker_pid: null
    verifier_pid: null
    verifier_artefact: null
    verifier_attempts: 0
    completed_at: null
    gate:
      type: stage_completed
      stage_id: 58-the-controller-decides-the-scripts-are-its-verbs
  - id: 62-next-eligible-stage
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

fixed_repo="$(make_repo fixed "$tmp_root/dependency.yaml")"
run_tick "$script_dir/tick.sh" "$fixed_repo"
fixed_log="$PHAT_CONTROLLER_HOME/log/tick-$(date +%F).log"
check "the gated stage stays pending" \
  "$(eq pending "$(yq -r '.stages[] | select(.id == "60-the-controller-can-see-the-window") | .status' "$fixed_repo/state/state.yaml")")"
check "the gated stage gets no run worktree" \
  "$([[ ! -e "$tmp_root/fixed-run-60-the-controller-can-see-the-window" ]] && printf ok || printf 'worktree exists')"
check "the gated stage has no dispatch-side state movement" \
  "$(eq '||0' "$(yq -r '.stages[] | select(.id == "60-the-controller-can-see-the-window") | [.started_at, .worker_pid, .verifier_attempts] | join("|")' "$fixed_repo/state/state.yaml")")"
check "the next eligible stage is dispatched" \
  "$(eq 62-next-eligible-stage "$(yq -r '.current_stage' "$fixed_repo/state/state.yaml")")"
check "the log names the skipped stage and condition" \
  "$([[ "$(cat "$fixed_log")" == *'stage 60-the-controller-can-see-the-window gate unmet'*58-the-controller-decides-the-scripts-are-its-verbs*'requires completed'* ]] && printf ok || printf 'skip detail absent')"
drop_subscriber fixed

yq 'del(.stages[] | select(.id == "58-the-controller-decides-the-scripts-are-its-verbs"))' \
  "$tmp_root/dependency.yaml" > "$tmp_root/dependency-missing.yaml"
missing_repo="$(make_repo dependency-missing "$tmp_root/dependency-missing.yaml")"
run_tick "$script_dir/tick.sh" "$missing_repo"
check "a missing prerequisite is visible and does not hold the queue" \
  "$([[ "$(cat "$tmp_root/dependency-missing-tick-output.log")" == *'prerequisite 58-the-controller-decides-the-scripts-are-its-verbs is absent from the queue'* ]] && \
      [[ "$(yq -r '.current_stage' "$missing_repo/state/state.yaml")" == 62-next-eligible-stage ]] && \
      printf ok || printf 'missing prerequisite was silent or held the queue')"
drop_subscriber dependency-missing

# Before the change is HEAD while the smoke is uncommitted. Once committed,
# find the commit that introduced this smoke and use its parent, so the proof
# remains a real pre-fix checkout rather than a hand-written simulation.
pre_fix_ref=HEAD
if git -C "$repo_root_real" cat-file -e HEAD:scripts/gate-smoke.sh 2>/dev/null; then
  introduction="$(git -C "$repo_root_real" log --diff-filter=A --format=%H -- scripts/gate-smoke.sh | head -n1)"
  [[ -n "$introduction" ]] && pre_fix_ref="${introduction}^"
fi
pre_fix_root="$tmp_root/pre-fix-autometta"
mkdir -p "$pre_fix_root"
cp -R "$script_dir" "$pre_fix_root/scripts"
cp -R "$repo_root_real/templates" "$repo_root_real/bin" "$pre_fix_root/"
git -C "$repo_root_real" show "$pre_fix_ref:scripts/tick.sh" > "$pre_fix_root/scripts/tick.sh"
chmod +x "$pre_fix_root/scripts/tick.sh"

old_repo="$(make_repo pre-fix "$tmp_root/dependency.yaml")"
run_tick "$pre_fix_root/scripts/tick.sh" "$old_repo"
old_pid="$(yq -r '.stages[] | select(.id == "60-the-controller-can-see-the-window") | .worker_pid // ""' "$old_repo/state/state.yaml")"
if [[ -d "$tmp_root/pre-fix-run-60-the-controller-can-see-the-window" ]]; then
  old_worktree_cut=ok
else
  old_worktree_cut='worktree absent after dispatch tick'
fi
if [[ -z "$old_pid" ]]; then
  printf '  pre-fix tick output:\n' >&2
  sed 's/^/    /' "$tmp_root/pre-fix-tick-output.log" >&2
fi
for _ in $(seq 1 50); do
  [[ -z "$old_pid" ]] || ! kill -0 "$old_pid" 2>/dev/null || { sleep 0.02; continue; }
  break
done
run_tick "$pre_fix_root/scripts/tick.sh" "$old_repo"
check "the pre-fix checkout cuts the gated stage's worktree" \
  "$old_worktree_cut"
check "the pre-fix checkout records the worker refusal as failed" \
  "$(eq failed "$(yq -r '.stages[] | select(.id == "60-the-controller-can-see-the-window") | .status' "$old_repo/state/state.yaml")")"
drop_subscriber pre-fix

cat > "$tmp_root/dependency-met.yaml" <<'YAML'
version: 1
current_stage: null
last_tick_at: "2026-08-25T00:00:00Z"
tick_count: 0
clock_tick_budget_remaining: 400
stages:
  - id: 58-the-controller-decides-the-scripts-are-its-verbs
    status: completed
    worker: Worker
    verifier: Verifier
  - id: 60-the-controller-can-see-the-window
    status: pending
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
    gate:
      type: stage_completed
      stage_id: 58-the-controller-decides-the-scripts-are-its-verbs
YAML
met_repo="$(make_repo dependency-met "$tmp_root/dependency-met.yaml")"
run_tick "$script_dir/tick.sh" "$met_repo"
check "a completed prerequisite opens its gate" \
  "$(eq 60-the-controller-can-see-the-window "$(yq -r '.current_stage' "$met_repo/state/state.yaml")")"
drop_subscriber dependency-met

printf '== 3. queue-empty in both states ==\n' >&2
cat > "$tmp_root/queue-live.yaml" <<'YAML'
version: 1
current_stage: null
last_tick_at: "2026-08-25T00:00:00Z"
tick_count: 0
clock_tick_budget_remaining: 400
stages:
  - id: 50-stage-cards-live-in-stage-cards
    status: pending
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
    gate:
      type: queue_empty
  - id: 62-next-eligible-stage
    status: pending
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
YAML
live_repo="$(make_repo queue-live "$tmp_root/queue-live.yaml")"
run_tick "$script_dir/tick.sh" "$live_repo"
check "queue-empty holds while another stage is pending" \
  "$(eq pending "$(yq -r '.stages[] | select(.id == "50-stage-cards-live-in-stage-cards") | .status' "$live_repo/state/state.yaml")")"
check "queue-empty does not hold the later stage" \
  "$(eq 62-next-eligible-stage "$(yq -r '.current_stage' "$live_repo/state/state.yaml")")"
drop_subscriber queue-live

yq '(.stages[] | select(.id == "62-next-eligible-stage")).status = "in_progress"' \
  "$tmp_root/queue-live.yaml" > "$tmp_root/queue-in-progress.yaml"
progress_repo="$(make_repo queue-in-progress "$tmp_root/queue-in-progress.yaml")"
run_tick "$script_dir/tick.sh" "$progress_repo"
check "queue-empty also holds while another stage is in_progress" \
  "$(eq pending "$(yq -r '.stages[] | select(.id == "50-stage-cards-live-in-stage-cards") | .status' "$progress_repo/state/state.yaml")")"
check "an in_progress neighbour creates no stage-50 worktree" \
  "$([[ ! -e "$tmp_root/queue-in-progress-run-50-stage-cards-live-in-stage-cards" ]] && printf ok || printf 'worktree exists')"
drop_subscriber queue-in-progress

yq 'del(.stages[] | select(.id == "62-next-eligible-stage"))' \
  "$tmp_root/queue-live.yaml" > "$tmp_root/queue-empty.yaml"
empty_repo="$(make_repo queue-empty "$tmp_root/queue-empty.yaml")"
run_tick "$script_dir/tick.sh" "$empty_repo"
check "queue-empty opens when no other stage is pending or in_progress" \
  "$(eq 50-stage-cards-live-in-stage-cards "$(yq -r '.current_stage' "$empty_repo/state/state.yaml")")"
drop_subscriber queue-empty

printf '== 4. contract-test freeze gate: three states, not two ==\n' >&2

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/121-the-gate-checks-only-what-a-card-can-name.md
gate_script="$script_dir/check-contract-test-gate.sh"
mk_begin="$(sed -n "s/^MARKER_BEGIN='\(.*\)'/\1/p" "$gate_script")"
mk_end="$(sed -n "s/^MARKER_END='\(.*\)'/\1/p" "$gate_script")"
pre_fix_gate="$tmp_root/pre-fix-check-contract-test-gate.sh"
if git -C "$repo_root_real" cat-file -e HEAD:scripts/check-contract-test-gate.sh 2>/dev/null; then
  gate_introduction="$(git -C "$repo_root_real" log --diff-filter=A --format=%H -- scripts/gate-smoke.sh | head -n1)"
  git -C "$repo_root_real" show "${gate_introduction}^:scripts/check-contract-test-gate.sh" > "$pre_fix_gate"
else
  cp "$gate_script" "$pre_fix_gate"
fi
chmod +x "$pre_fix_gate"

make_gate_repo() {
  local name="$1"
  local repo="$tmp_root/gate-$name"
  mkdir -p "$repo/stage-cards" "$repo/scripts"
  (
    cd "$repo"
    git init -q -b dev .
    git config user.email smoke@local
    git config user.name smoke
    git config commit.gpgsign false
    git commit -q --allow-empty -m seed
  )
  printf '%s' "$repo"
}

# State 1: a staged file no card names, carrying no marker, is not this
# gate's business and is skipped.
unnamed_repo="$(make_gate_repo unnamed)"
printf '#!/usr/bin/env bash\necho hi\n' > "$unnamed_repo/scripts/plain.sh"
( cd "$unnamed_repo" && git add -A )
unnamed_out="$tmp_root/gate-unnamed.log"
if ( cd "$unnamed_repo" && bash "$gate_script" ) >"$unnamed_out" 2>&1; then
  unnamed_result=ok
else
  unnamed_result="exited non-zero: $(cat "$unnamed_out")"
fi
check "state 1: an unnamed, unmarked staged file is skipped" "$unnamed_result"

# State 2: a staged file a card names as its contract test, carrying no
# marker, is a violation -- not a skip. This is the fail-open condition
# stage 102 and emergence-lab stages 63/70 disagreed about.
named_repo="$(make_gate_repo named)"
cat > "$named_repo/stage-cards/50-example.md" <<'CARD'
# Stage card 50
## Contract test
- **Test file:** `scripts/named-test.sh`
- **Assertions digest:** `sha256:deadbeef`
CARD
printf '#!/usr/bin/env bash\necho hi\n' > "$named_repo/scripts/named-test.sh"
( cd "$named_repo" && git add -A )
named_out="$tmp_root/gate-named.log"
if ( cd "$named_repo" && bash "$gate_script" ) >"$named_out" 2>&1; then
  named_result="exited zero: $(cat "$named_out")"
else
  named_result=ok
fi
check "state 2: a card-named test with no marker is a violation, not a skip" "$named_result"
check "the violation message names the file and its card" \
  "$([[ "$(cat "$named_out")" == *'scripts/named-test.sh'*'stage-cards/50-example.md'* ]] && printf ok || printf 'message missing file or card')"

# Regression proof: the same fixture wrongly passes under the pre-fix gate.
# A smoke that passes against both the new and the old gate is not a
# regression test.
pre_fix_out="$tmp_root/gate-named-pre-fix.log"
if ( cd "$named_repo" && bash "$pre_fix_gate" ) >"$pre_fix_out" 2>&1; then
  pre_fix_result=ok
else
  pre_fix_result="exited non-zero: $(cat "$pre_fix_out")"
fi
check "the pre-fix gate wrongly passes the same fixture (fail-open regression proof)" "$pre_fix_result"

# State 3: a marked file is recomputed and compared to its card's declared
# digest, exactly as before.
marked_repo="$(make_gate_repo marked)"
cat > "$marked_repo/stage-cards/51-example.md" <<'CARD'
# Stage card 51
## Contract test
- **Test file:** `scripts/marked-test.sh`
- **Assertions digest:** `PLACEHOLDER`
CARD
printf '#!/usr/bin/env bash\n# %s card=stage-cards/51-example.md\necho hi\n# %s\n' \
  "$mk_begin" "$mk_end" > "$marked_repo/scripts/marked-test.sh"
digest="$( ( cd "$marked_repo" && bash "$gate_script" print scripts/marked-test.sh ) )"
sed -i.bak "s/PLACEHOLDER/$digest/" "$marked_repo/stage-cards/51-example.md"
rm -f "$marked_repo/stage-cards/51-example.md.bak"
( cd "$marked_repo" && git add -A )
marked_out="$tmp_root/gate-marked.log"
if ( cd "$marked_repo" && bash "$gate_script" ) >"$marked_out" 2>&1; then
  marked_result=ok
else
  marked_result="exited non-zero: $(cat "$marked_out")"
fi
check "state 3: a marked file whose digest matches its card passes" "$marked_result"

# A marked file whose block changed without its card's digest moving still
# fails, unchanged from today.
printf '#!/usr/bin/env bash\n# %s card=stage-cards/51-example.md\necho changed\n# %s\n' \
  "$mk_begin" "$mk_end" > "$marked_repo/scripts/marked-test.sh"
( cd "$marked_repo" && git add -A )
drift_out="$tmp_root/gate-drift.log"
if ( cd "$marked_repo" && bash "$gate_script" ) >"$drift_out" 2>&1; then
  drift_result="exited zero: $(cat "$drift_out")"
else
  drift_result=ok
fi
check "a changed frozen block without a moved digest still fails" "$drift_result"

# Token-carrying documentation is outside the candidate set and must be
# skipped. The old token-driven gate rejects the same staged content.
docs_repo="$(make_gate_repo docs-token)"
mkdir -p "$docs_repo/docs"
printf '# Contract guide\n\nThe marker is `%s`.\n' "$mk_begin" > "$docs_repo/docs/dispatch-contract.md"
( cd "$docs_repo" && git add docs/dispatch-contract.md )
docs_out="$tmp_root/gate-docs-token.log"
if ( cd "$docs_repo" && bash "$gate_script" ) >"$docs_out" 2>&1; then
  docs_result=ok
else
  docs_result="exited non-zero: $(cat "$docs_out")"
fi
check "a staged docs file containing the token is skipped" "$docs_result"
docs_pre_fix_out="$tmp_root/gate-docs-token-pre-fix.log"
if ( cd "$docs_repo" && bash "$pre_fix_gate" ) >"$docs_pre_fix_out" 2>&1; then
  docs_pre_fix_result="exited zero: $(cat "$docs_pre_fix_out")"
else
  docs_pre_fix_result=ok
fi
check "the pre-change gate rejects the same staged docs file" "$docs_pre_fix_result"

template_repo="$(make_gate_repo template-token)"
mkdir -p "$template_repo/templates"
printf '# Worker prompt\n\nThe marker is `%s`.\n' "$mk_begin" > "$template_repo/templates/worker-prompt.md"
( cd "$template_repo" && git add templates/worker-prompt.md )
template_out="$tmp_root/gate-template-token.log"
if ( cd "$template_repo" && bash "$gate_script" ) >"$template_out" 2>&1; then
  template_result=ok
else
  template_result="exited non-zero: $(cat "$template_out")"
fi
check "a staged template containing the token is skipped" "$template_result"
template_pre_fix_out="$tmp_root/gate-template-token-pre-fix.log"
if ( cd "$template_repo" && bash "$pre_fix_gate" ) >"$template_pre_fix_out" 2>&1; then
  template_pre_fix_result="exited zero: $(cat "$template_pre_fix_out")"
else
  template_pre_fix_result=ok
fi
check "the pre-change gate rejects the same staged template" "$template_pre_fix_result"

# Smoke scripts are candidates even when no card names their path. A changed
# block with a stale digest must still fail after narrowing the candidate set.
smoke_repo="$(make_gate_repo bad-smoke)"
cat > "$smoke_repo/stage-cards/52-example.md" <<'CARD'
# Stage card 52
## Contract test
- **Assertions digest:** `sha256:deadbeef`
CARD
printf '#!/usr/bin/env bash\n# %s card=stage-cards/52-example.md\necho changed\n# %s\n' \
  "$mk_begin" "$mk_end" > "$smoke_repo/scripts/example-smoke.sh"
( cd "$smoke_repo" && git add -A )
smoke_out="$tmp_root/gate-bad-smoke.log"
if ( cd "$smoke_repo" && bash "$gate_script" ) >"$smoke_out" 2>&1; then
  smoke_result="exited zero: $(cat "$smoke_out")"
else
  smoke_result=ok
fi
check "a staged smoke with a changed block and stale card digest still fails" "$smoke_result"
# AUTOMETTA-CONTRACT-END

if (( fail != 0 )); then
  printf 'gate smoke: FAIL\n' >&2
  exit 1
fi
printf 'gate smoke: PASS\n' >&2

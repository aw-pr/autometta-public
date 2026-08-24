#!/usr/bin/env bash
# Offline proof of the warden's four mechanical remediations, the priority
# order between them, and the twice-without-progress escalation rule.
# No auth, network access or provider dispatch is used: remediation 1's
# triage judgement is the only step that would ever call an LLM, and it is
# exercised here by calling warden_apply_triage_decision directly against a
# hand-authored envelope, the same way preserve-failed-work-smoke.sh
# exercises tick.sh's _process_verifier_artefact without a live verifier.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'chmod -R u+w "$fixture" 2>/dev/null || true; rm -rf "$fixture"' EXIT
export PHAT_CONTROLLER_HOME="$fixture/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/log" "$PHAT_CONTROLLER_HOME/subscribers"
# phat-controller.sh resolves its controller paths while it is sourced (same as
# tick.sh), so the fixture root must be exported first.
# shellcheck source=./phat-controller.sh
source "$script_dir/phat-controller.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || { printf '%s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2; return 1; }
}
assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || { printf '%s: missing %q\n' "$label" "$needle" >&2; return 1; }
}
assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" != *"$needle"* ]] || { printf '%s: unexpectedly present %q\n' "$label" "$needle" >&2; return 1; }
}

if assert_eq expected deliberately-wrong assertion-self-test 2>/dev/null; then
  fail "assertion helper did not fail on a mismatch"
fi
printf 'PASS assertion helper rejects a mismatch\n'

write_budget() {
  local repo="$1" halted="${2:-false}" halt_reason="${3:-null}" window="${4:-$(date -u +%F)}" paused="${5:-null}"
  local halt_reason_json paused_json
  [[ "$halt_reason" == "null" ]] && halt_reason_json=null || halt_reason_json="\"$halt_reason\""
  [[ "$paused" == "null" ]] && paused_json=null || paused_json="$paused"
  cat > "$repo/state/budget.json" <<JSON
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
  "halted": ${halted},
  "halt_reason": ${halt_reason_json},
  "window_started_at": "${window}",
  "paused_until": ${paused_json},
  "paused_reason": null
}
JSON
}

make_repo() {
  local name="$1"
  local repo="$fixture/$name"
  mkdir -p "$repo/state/verifiers" "$repo/state/handoffs" "$repo/state/logs" "$repo/examples/self-host"
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
  cat > "$PHAT_CONTROLLER_HOME/subscribers/${name}.yaml" <<YAML
enabled: true
repo_path: "${repo}"
weight: 10
YAML
  write_budget "$repo"
  printf '%s' "$repo"
}

state_status() {
  local repo="$1" id="$2"
  yq -r ".stages[] | select(.id == \"$id\") | .status" "$repo/state/state.yaml"
}

printf '== remediation 3: stale pause cleared, live pause left standing ==\n'
r3="$(make_repo r3)"
mkdir -p "$(dirname "$r3")"
write_budget "$r3" false null "$(date -u +%F)" "$(( $(date -u +%s) - 100 ))"
_warden_clear_stale_for_repo "$r3" >/dev/null 2>&1 || true
assert_eq null "$(jq -r '.paused_until // null' "$r3/state/budget.json")" "stale pause cleared"
assert_eq "$WARDEN_GIT_IDENTITY" "$(tail -n1 "$r3/state/warden-actions.jsonl" | jq -r '.warden_identity')" "stale-clear audit identity"
printf 'PASS stale pause cleared\n'

write_budget "$r3" false null "$(date -u +%F)" "$(( $(date -u +%s) + 3600 ))"
_warden_clear_stale_for_repo "$r3" >/dev/null 2>&1 || true
[[ "$(jq -r '.paused_until' "$r3/state/budget.json")" != "null" ]] || fail "live pause was cleared"
printf 'PASS live pause left standing\n'

printf '== remediation 3: previous-window halt cleared, current-window halt left standing ==\n'
write_budget "$r3" true tick-cap 2020-01-01 null
_warden_clear_stale_for_repo "$r3" >/dev/null 2>&1 || true
assert_eq false "$(jq -r '.halted' "$r3/state/budget.json")" "previous-window halt cleared"
printf 'PASS previous-window halt cleared\n'

write_budget "$r3" true tick-cap "$(date -u +%F)" null
_warden_clear_stale_for_repo "$r3" >/dev/null 2>&1 || true
assert_eq true "$(jq -r '.halted' "$r3/state/budget.json")" "current-window halt left standing"
printf 'PASS current-window halt left standing\n'
write_budget "$r3" false null "$(date -u +%F)" null

printf '== remediation 2: clean awaiting integration is merged, smokes run, ref recorded ==\n'
r2="$(make_repo r2)"
stage2=60-merge-clean
(
  cd "$r2"
  git checkout -qb "autometta/${stage2}"
  printf 'worker output\n' > result.txt
  git add result.txt
  git commit -qam "worker diff"
  git checkout -q dev
  printf 'base moved independently\n' > base.txt
  git add base.txt
  git commit -qam "base moved"
)
run_tip="$(git -C "$r2" rev-parse "refs/heads/autometta/${stage2}")"
cat > "$r2/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage2
    status: completed
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    integration:
      state: awaiting
      base_branch: dev
      run_branch: autometta/${stage2}
      head: "${run_tip}"
      pushed: false
YAML
_warden_merge_awaiting_for_repo "$r2" >/dev/null 2>&1 || true
assert_eq merged "$(yq -r ".stages[] | select(.id == \"$stage2\") | .integration.state" "$r2/state/state.yaml")" "integration state after clean merge"
git -C "$r2" merge-base --is-ancestor "$run_tip" dev || fail "clean divergent run tip was not integrated into dev"
assert_eq 2 "$(git -C "$r2" show -s --format='%P' dev | awk '{print NF}')" "divergent clean integration made a two-parent merge commit"
assert_eq "$WARDEN_GIT_IDENTITY" "$(git -C "$r2" show -s --format='%an <%ae>' dev)" "merge commit author"
assert_eq merge-awaiting "$(tail -n1 "$r2/state/warden-actions.jsonl" | jq -r '.remediation')" "merge action audited"
if git -C "$r2" show-ref --verify --quiet "refs/heads/autometta/${stage2}"; then
  fail "run branch was not torn down after merge"
fi
printf 'PASS clean divergent awaiting integration merged and torn down\n'

printf '== remediation 2: conflicted awaiting integration is surfaced, untouched ==\n'
r2c="$(make_repo r2c)"
stage2c=61-merge-conflict
(
  cd "$r2c"
  printf 'base change\n' > result.txt
  git add result.txt
  git commit -qam "base changes result.txt"
  git checkout -qb "autometta/${stage2c}" 'HEAD~1'
  printf 'conflicting worker change\n' > result.txt
  git add result.txt
  git commit -qam "worker also changes result.txt"
  git checkout -q dev
)
dev_before="$(git -C "$r2c" rev-parse dev)"
run_before="$(git -C "$r2c" rev-parse "refs/heads/autometta/${stage2c}")"
cat > "$r2c/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage2c
    status: completed
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    integration:
      state: awaiting
      base_branch: dev
      run_branch: autometta/${stage2c}
      head: "${run_before}"
      pushed: false
YAML
conflict_out="$(_warden_merge_awaiting_for_repo "$r2c" 2>&1 || true)"
assert_contains "$conflict_out" "conflicts with" "conflict surfaced"
assert_eq awaiting "$(yq -r ".stages[] | select(.id == \"$stage2c\") | .integration.state" "$r2c/state/state.yaml")" "integration state left awaiting"
assert_eq "$dev_before" "$(git -C "$r2c" rev-parse dev)" "dev untouched by a conflicted merge"
assert_eq "$run_before" "$(git -C "$r2c" rev-parse "refs/heads/autometta/${stage2c}")" "run branch untouched by a conflicted merge"
printf 'PASS conflicted awaiting integration surfaced, never resolved by the warden\n'

printf '== remediation 2 escalation: same stuck awaiting stage, applied twice, escalates on the third ==\n'
esc_out1="$(_warden_merge_awaiting_for_repo "$r2c" 2>&1 || true)"
assert_contains "$esc_out1" "conflicts with" "second attempt still surfaces"
esc_out2="$(_warden_merge_awaiting_for_repo "$r2c" 2>&1 || true)"
assert_contains "$esc_out2" "ESCALATION" "third attempt escalates instead of surfacing again"
assert_eq true "$(jq -r '.halted' "$r2c/state/budget.json")" "escalation halts the repo"
assert_eq warden-escalation "$(jq -r '.halt_reason' "$r2c/state/budget.json")" "halt reason names the warden"
printf 'PASS twice-without-progress produced an operator escalation, not a third attempt\n'

printf '== triage spend advances the hard-stop budget and carries role phat-controller in the cost log ==\n'
rcl="$(make_repo rcl)"
: > "$rcl/state/logs/warden-cost-log-fixture.log"
printf 'Total tokens: 4200\n' >> "$rcl/state/logs/warden-cost-log-fixture.log"
warden_record_triage_spend "$rcl" "72-cost-log-fixture" "Claude Sonnet 5 <claude-sonnet-5@local>" \
  "$rcl/state/logs/warden-cost-log-fixture.log" 0 5 pass
cost_line="$(tail -n1 "$rcl/state/cost-log.jsonl")"
assert_eq phat-controller "$(printf '%s' "$cost_line" | jq -r '.role')" "cost-log role for the phat-controller triage dispatch"
assert_eq 72-cost-log-fixture "$(printf '%s' "$cost_line" | jq -r '.stage_id')" "cost-log stage_id"
assert_eq 4200 "$(jq -r '.tokens_spent' "$rcl/state/budget.json")" "warden tokens charged to the hard-stop budget"
printf 'PASS phat-controller triage spend is budgeted and itemised with role=phat-controller\n'

printf '== bounded triage dispatch honours either agent family ==\n'
rfd="$(make_repo rfd)"
stagefd=73-family-dispatch-fixture
cardfd="$rfd/examples/self-host/${stagefd}.md"
printf '# Stage card 73: family dispatch fixture\n' > "$cardfd"
printf '{"overall":"FAIL"}\n' > "$rfd/state/verifiers/${stagefd}.json"
wipfd="$(git -C "$rfd" rev-parse HEAD)"
stub_bin="$fixture/family-stubs"
mkdir -p "$stub_bin"
cat > "$stub_bin/op-fetch" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
[[ "${1:-}" == "--" ]] && shift
exec "$@"
STUB
cat > "$stub_bin/provider-stub" <<'STUB'
#!/usr/bin/env bash
prompt=""
for arg in "$@"; do prompt="$arg"; done
stage_id="$(printf '%s\n' "$prompt" | sed -n 's/^- Stage id: `\([^`]*\)`/\1/p' | tail -n1)"
envelope="$(printf '%s\n' "$prompt" | sed -n 's/^- Envelope to write: `\([^`]*\)`/\1/p' | tail -n1)"
mkdir -p "$(dirname "$envelope")"
printf '{"stage_id":"%s","verdict":"inconclusive","rebrief_markdown":"","amendment_markdown":"","summary":"fixture"}\n' "$stage_id" > "$envelope"
case "$(basename "$0")" in
  claude) printf '{"result":"fixture","usage":{"input_tokens":101,"output_tokens":10}}\n' ;;
  codex) printf 'tokens used\n222\n' ;;
esac
STUB
chmod +x "$stub_bin/op-fetch" "$stub_bin/provider-stub"
ln -s provider-stub "$stub_bin/claude"
ln -s provider-stub "$stub_bin/codex"

warden_mandate_ensure
for family_case in claude codex; do
  case "$family_case" in
    claude) family_identity='Claude Sonnet 5 <claude-sonnet-5@local>' ;;
    codex) family_identity='Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>' ;;
  esac
  FAMILY_IDENTITY="$family_identity" yq -i '.dispatch.triage_identity = strenv(FAMILY_IDENTITY)' "$PHAT_CONTROLLER_HOME/warden-mandate.yaml"
  PATH="$stub_bin:$PATH" _warden_dispatch_triage "$rfd" "$stagefd" "$cardfd" \
    "state/verifiers/${stagefd}.json" "$wipfd" "wip/${stagefd}-attempt-1"
  assert_eq "$family_case" "$(tail -n1 "$rfd/state/cost-log.jsonl" | jq -r '.identity' | tr '[:upper:]' '[:lower:]' | sed -n "s/.*\(${family_case}\).*/\1/p")" "${family_case} triage identity reached the cost log"
done
assert_eq 333 "$(jq -r '.tokens_spent' "$rfd/state/budget.json")" "both family fixtures charged their tokens"
printf 'PASS Claude and Codex triage use the same bounded auth-route path\n'

printf '== remediation 1 (mechanical half): work_defect re-briefs and requeues ==\n'
r1="$(make_repo r1)"
stage1=62-triage-work-defect
cat > "$r1/examples/self-host/${stage1}.md" <<'CARD'
# Stage card 62: triage work defect fixture

## Metadata

- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>

## Objective

Fixture card for warden-smoke.sh.
CARD
(
  cd "$r1"
  git add examples/self-host/${stage1}.md
  git commit -qam "add fixture card"
  git checkout -qb "autometta/${stage1}"
  printf 'near passing\n' > result.txt
  git add result.txt
  git commit --author='GPT-5.6 Sol <gpt-5-6-sol@local>' -qm "wip(${stage1}): attempt 1, verifier FAIL: fixture"
  git branch "wip/${stage1}-attempt-1"
  git checkout -q dev
)
wip_sha="$(git -C "$r1" rev-parse "refs/heads/wip/${stage1}-attempt-1")"
cat > "$r1/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage1
    status: verifier_failed
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier_attempts: 1
    wip_commit: "${wip_sha}"
    wip_branch: "wip/${stage1}-attempt-1"
YAML
card1="$r1/examples/self-host/${stage1}.md"
envelope1="$r1/state/handoffs/warden-${stage1}.json"
cat > "$envelope1" <<JSON
{
  "stage_id": "$stage1",
  "verdict": "work_defect",
  "rebrief_markdown": "## Re-brief for attempt 2 (2026-08-24, fixture)\n\nRestore ${wip_sha} and try again.",
  "amendment_markdown": "",
  "summary": "fixture work defect"
}
JSON
warden_apply_triage_decision "$r1" "$stage1" "$card1" "$envelope1" "$wip_sha"
assert_contains "$(cat "$card1")" "Re-brief for attempt 2" "re-brief appended to the card"
assert_contains "$(cat "$card1")" "$wip_sha" "re-brief cites the preserved wip commit"
assert_eq pending "$(state_status "$r1" "$stage1")" "requeued to pending"
[[ -z "$(git -C "$r1" status --porcelain -- "examples/self-host/${stage1}.md")" ]] || fail "the warden's re-brief edit was left uncommitted in repo_root"
assert_eq "$WARDEN_GIT_IDENTITY" "$(git -C "$r1" log -1 --format='%an <%ae>' -- "examples/self-host/${stage1}.md")" "re-brief commit author"
printf 'PASS work_defect verdict re-briefed, committed with the warden identity, and requeued\n'

write_fixture_card() {
  cat > "$1" <<CARD
# Stage card: fixture

## Metadata

- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>

## Objective

Fixture card for warden-smoke.sh.
CARD
}

printf '== remediation 1 (mechanical half): missing wip citation refuses to requeue ==\n'
stage1b=63-triage-missing-citation
card1b="$r1/examples/self-host/${stage1b}.md"
write_fixture_card "$card1b"
cat > "$r1/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage1b
    status: verifier_failed
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier_attempts: 1
    wip_commit: "${wip_sha}"
    wip_branch: "wip/${stage1}-attempt-1"
YAML
envelope1b="$r1/state/handoffs/warden-${stage1b}.json"
cat > "$envelope1b" <<JSON
{
  "stage_id": "$stage1b",
  "verdict": "work_defect",
  "rebrief_markdown": "## Re-brief for attempt 2 (2026-08-24, fixture)\n\nNo citation here.",
  "amendment_markdown": "",
  "summary": "fixture missing citation"
}
JSON
missing_cite_out="$(warden_apply_triage_decision "$r1" "$stage1b" "$card1b" "$envelope1b" "$wip_sha" 2>&1 || true)"
assert_contains "$missing_cite_out" "does not cite" "missing-citation refusal logged"
assert_eq verifier_failed "$(yq -r ".stages[] | select(.id == \"$stage1b\") | .status // \"verifier_failed\"" "$r1/state/state.yaml")" "not requeued without citation"
assert_not_contains "$(cat "$card1b")" "Re-brief" "no re-brief appended when citation is missing"
printf 'PASS missing wip-commit citation is refused, not requeued\n'

printf '== remediation 1 (mechanical half): card_defect appends PROPOSED-AMENDMENT, nothing requeued ==\n'
stage1c=64-triage-card-defect
card1c="$r1/examples/self-host/${stage1c}.md"
write_fixture_card "$card1c"
cat > "$r1/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage1c
    status: verifier_failed
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier_attempts: 1
YAML
envelope1c="$r1/state/handoffs/warden-${stage1c}.json"
cat > "$envelope1c" <<JSON
{
  "stage_id": "$stage1c",
  "verdict": "card_defect",
  "rebrief_markdown": "",
  "amendment_markdown": "## PROPOSED-AMENDMENT (2026-08-24, fixture)\n\nCriterion 3 contradicts criterion 5.",
  "summary": "fixture card defect"
}
JSON
warden_apply_triage_decision "$r1" "$stage1c" "$card1c" "$envelope1c" ""
assert_contains "$(cat "$card1c")" "PROPOSED-AMENDMENT" "amendment appended to the card"
assert_eq verifier_failed "$(yq -r ".stages[] | select(.id == \"$stage1c\") | .status" "$r1/state/state.yaml")" "card_defect never requeues"
printf 'PASS card_defect verdict appended a PROPOSED-AMENDMENT and requeued nothing\n'

printf '== remediation 1 escalation: at the mandate attempt cap, escalates instead of triaging ==\n'
r1e="$(make_repo r1e)"
stage1e=65-triage-attempt-cap
cat > "$r1e/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage1e
    status: verifier_failed
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier_attempts: 3
YAML
warden_mandate_ensure
cap_out="$(_warden_requeue_verifier_failed_for_repo "$r1e" 2>&1 || true)"
assert_contains "$cap_out" "ESCALATION" "attempt-cap escalation logged"
assert_eq true "$(jq -r '.halted' "$r1e/state/budget.json")" "attempt-cap escalation halts the repo"
printf 'PASS verifier_attempts at the mandate cap escalates rather than dispatching triage\n'

printf '== remediation 4: gate unmet leaves the queue empty; gate met queues the card ==\n'
r4="$(make_repo r4)"
stage4=99-gated-fixture
cat > "$r4/examples/self-host/PLAN.md" <<PLAN
# Fixture plan

| # | Stage | Status | Commit | Card |
|---|---|---|---|---|
| 98 | Prior stage | not-yet-done | \`\` | [\`98-prior.md\`](./98-prior.md) |
| $stage4 | Gated fixture | queued, blocked by 98 | \`\` | [\`${stage4}.md\`](./${stage4}.md) |
PLAN
cat > "$r4/examples/self-host/${stage4}.md" <<'CARD'
# Stage card 99: gated fixture

## Metadata

- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
CARD
cat > "$r4/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages: []
YAML
_warden_queue_next_card_for_repo "$r4" >/dev/null 2>&1 && fail "queued a card whose gate is unmet"
assert_eq 0 "$(yq -r '.stages | length' "$r4/state/state.yaml")" "nothing queued while the gate is unmet"
printf 'PASS gate unmet: nothing queued\n'

sed -i.bak "s/| 98 | Prior stage | not-yet-done |/| 98 | Prior stage | done |/" "$r4/examples/self-host/PLAN.md"
_warden_queue_next_card_for_repo "$r4" >/dev/null 2>&1 || true
assert_eq 1 "$(yq -r '.stages | length' "$r4/state/state.yaml")" "queued once the gate is met"
assert_eq "$stage4" "$(yq -r '.stages[0].id' "$r4/state/state.yaml")" "the gated card was queued"
assert_eq "$WARDEN_GIT_IDENTITY" "$(tail -n1 "$r4/state/warden-actions.jsonl" | jq -r '.warden_identity')" "queue action audit identity"
printf 'PASS gate met: card queued from PLAN.md order\n'

# Every fixture above stays registered as a subscriber. The cross-cutting
# tests below call warden_pass across the whole registry, so any leftover
# live candidate from an earlier fixture (r1's still-verifier_failed
# stage1c, in particular) would otherwise compete with the pass under test.
# Clear the registry and register only what each remaining test needs.
rm -f "$PHAT_CONTROLLER_HOME"/subscribers/*.yaml

printf '== one remediation per pass, in the stated priority order ==\n'
rp="$(make_repo rp)"
stage_merge=70-priority-merge
(
  cd "$rp"
  printf 'base\n' >> README.md
  git commit -qam "base moved"
  git checkout -qb "autometta/${stage_merge}"
  printf 'worker output\n' > result.txt
  git add result.txt
  git commit -qam "worker diff"
  git checkout -q dev
)
run_tip_p="$(git -C "$rp" rev-parse "refs/heads/autometta/${stage_merge}")"
stage_queue=97-priority-queue
cat > "$rp/examples/self-host/PLAN.md" <<PLAN
# Fixture plan

| # | Stage | Status | Commit | Card |
|---|---|---|---|---|
| $stage_queue | Queue fixture | queued | \`\` | [\`${stage_queue}.md\`](./${stage_queue}.md) |
PLAN
cat > "$rp/examples/self-host/${stage_queue}.md" <<'CARD'
# Stage card 97: priority queue fixture

## Metadata

- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
CARD
cat > "$rp/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage_merge
    status: completed
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    integration:
      state: awaiting
      base_branch: dev
      run_branch: autometta/${stage_merge}
      head: "${run_tip_p}"
      pushed: false
YAML
warden_pass >/dev/null 2>&1 || true
assert_eq merged "$(yq -r ".stages[] | select(.id == \"$stage_merge\") | .integration.state" "$rp/state/state.yaml")" "higher-priority remediation (merge) ran"
assert_eq 1 "$(yq -r '.stages | length' "$rp/state/state.yaml")" "lower-priority remediation (queue) did not also run in the same pass"
printf 'PASS pass 1: merge-awaiting ran, queue-next-card did not\n'

warden_pass >/dev/null 2>&1 || true
assert_eq 2 "$(yq -r '.stages | length' "$rp/state/state.yaml")" "second pass performed the remaining remediation"
assert_eq "$stage_queue" "$(yq -r '.stages[1].id' "$rp/state/state.yaml")" "queue-next-card ran on the second pass"
printf 'PASS pass 2: queue-next-card ran once the higher-priority remediation had nothing left\n'

rm -f "$PHAT_CONTROLLER_HOME"/subscribers/*.yaml

printf '== quiet pass: nothing to do produces no action ==\n'
rq="$(make_repo rq)"
cat > "$rq/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages:
  - id: 71-nothing-to-do
    status: in_progress
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
YAML
quiet_out="$(warden_pass 2>&1 || true)"
assert_contains "$quiet_out" "quiet pass, nothing to do" "quiet pass logs plainly"
printf 'PASS quiet pass logs and takes no action\n'

printf 'PASS warden smoke\n'

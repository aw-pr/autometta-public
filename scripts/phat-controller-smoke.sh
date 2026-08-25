#!/usr/bin/env bash
# Offline proof of phat-controller: the seed rendered at configure time, the
# refusal when no spend authority is supplied, each verb individually, the
# decision journal's decision-before-action ordering, and the card-58 contract
# test replaying the evening of 2026-08-24.
#
# No auth, network access or provider dispatch is used. The one verb that
# would ever call an LLM is `pass`, and everything it would decide is decided
# here by calling the verbs directly, the same way preserve-failed-work-smoke.sh
# exercises tick.sh's _process_verifier_artefact without a live verifier.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autometta_root="$(cd "$script_dir/.." && pwd)"
fixture="$(mktemp -d)"
trap 'chmod -R u+w "$fixture" 2>/dev/null || true; rm -rf "$fixture"' EXIT
export AUTOMETTA_HOME="$fixture/controller"
mkdir -p "$AUTOMETTA_HOME/log" "$AUTOMETTA_HOME/subscribers"
# phat-controller.sh resolves its controller paths while it is sourced (same
# as tick.sh), so the fixture home must be exported first.
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
  cat > "$AUTOMETTA_HOME/subscribers/${name}.yaml" <<YAML
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

journal_of() { cat "$(pc_journal_path "$1")" 2>/dev/null || true; }

# journal_order <repo> <decision_id> -> "<decision seq> <outcome seq>"
journal_order() {
  local repo="$1" did="$2"
  jq -r --arg d "$did" 'select(.decision_id == $d) | "\(.phase) \(.seq)"' "$(pc_journal_path "$repo")"
}

# ---------------------------------------------------------------------------
printf '== criterion 3: configuring with no spend authority answered refuses ==\n'
seedless_out="$( "$script_dir/render-controller-seed.sh" --out "$fixture/never-written.md" 2>&1 || true )"
seedless_rc=0
"$script_dir/render-controller-seed.sh" --out "$fixture/never-written.md" >/dev/null 2>&1 || seedless_rc=$?
assert_eq 2 "$seedless_rc" "render refuses with exit 2 when no spend authority is supplied"
assert_contains "$seedless_out" "no spend authority supplied" "the refusal says what is missing"
assert_contains "$seedless_out" "no committed default" "the refusal says why there is no default"
assert_contains "$seedless_out" "Nothing has been written" "the refusal says nothing was written"
[[ -f "$fixture/never-written.md" ]] && fail "a seed was written despite the refusal"
printf 'PASS no spend authority answered: nothing rendered, exit 2, reason stated\n'

printf '== criterion 1 and 2: a fresh job renders an operator-owned seed ==\n'
rseed="$(make_repo rseed)"
( cd "$rseed" && git config workflow.style dev-main )
spend_answer='Up to 40M tokens this run on the Claude subscription. The codex api route stays off tonight.'
seed_out="$fixture/controller/phat-controller-seed.md"
"$script_dir/render-controller-seed.sh" \
  --spend-authority "$spend_answer" \
  --window-reserve-percent 10 --window-reserve-action hold \
  --token-ceiling 40000000 \
  --expires 2126-01-01T00:00:00Z \
  --repo "$rseed" --out "$seed_out" >/dev/null
[[ -s "$seed_out" ]] || fail "seed was not rendered"
seed_body="$(cat "$seed_out")"
assert_not_contains "$seed_body" "<<" "no placeholder survived rendering"
assert_contains "$seed_body" "$spend_answer" "the seed carries the answer given at setup, verbatim"
# All five prohibitions, by their distinguishing clause.
assert_contains "$seed_body" "Editing a card's acceptance criteria, objective, or specification" "prohibition 1"
assert_contains "$seed_body" "Verifying its own dispatches" "prohibition 2"
assert_contains "$seed_body" "Rewriting history, pushing non-fast-forward" "prohibition 3"
assert_contains "$seed_body" "Lifting its own spend caps" "prohibition 4"
assert_contains "$seed_body" "Resolving a merge conflict" "prohibition 5"
assert_contains "$seed_body" "$rseed" "the seed carries this repo's path"
assert_contains "$seed_body" "dev-main" "the seed carries the declared branch policy"
assert_contains "$seed_body" "Auth routes: codex" "the seed carries the per-family auth routes"
assert_contains "$seed_body" "state/budget.json" "the seed says where state lives"
assert_contains "$seed_body" "codex exec\` reads stdin after the prompt arg" "the seed carries this repo's own gotchas"
assert_eq 40000000 "$(yq -r '.spend_authority.token_ceiling' "$AUTOMETTA_HOME/phat-controller-mandate.yaml")" "machine-readable ceiling mirrored into the mandate"
assert_eq 10 "$(yq -r '.window_reserve.percent' "$AUTOMETTA_HOME/phat-controller-mandate.yaml")" "window reserve mirrored into the mandate"
assert_eq hold "$(yq -r '.window_reserve.action' "$AUTOMETTA_HOME/phat-controller-mandate.yaml")" "window action mirrored into the mandate"
# The committed template must not ship a spend authority of its own.
tpl_ceiling="$(yq -r '.spend_authority.token_ceiling' "$autometta_root/templates/phat-controller-mandate.yaml.tpl")"
[[ -z "$tpl_ceiling" || "$tpl_ceiling" == "null" ]] || fail "the committed mandate template ships a default ceiling: ${tpl_ceiling}"
assert_not_contains "$(cat "$autometta_root/templates/phat-controller-seed.md.tpl")" "Up to " "the committed seed template ships no default spend authority"
printf 'PASS seed rendered for a fresh job, carrying the five prohibitions, the answered spend authority and the repo facts\n'
# Acceptance criterion 1 asks to see the rendered output for a fresh job, so
# the smoke shows it rather than describing it. Machine paths below are the
# fixture's, not this machine's.
printf '\n   -- the rendered seed for a fresh job --\n'
sed 's/^/   | /' "$seed_out"
printf '   -- end of rendered seed --\n\n'

printf '== an already-rendered seed is not silently clobbered ==\n'
clobber_rc=0
"$script_dir/render-controller-seed.sh" --spend-authority 'something else' \
  --window-reserve-percent 0 --window-reserve-action observe \
  --out "$seed_out" >/dev/null 2>&1 || clobber_rc=$?
[[ "$clobber_rc" -ne 0 ]] || fail "an existing operator-owned seed was overwritten without --force"
assert_contains "$(cat "$seed_out")" "$spend_answer" "the operator's seed is unchanged"
printf 'PASS an existing seed needs --force, because the operator may have edited it\n'

printf '== the negative list may not drift from the proposal that owns it ==\n'
drift_home="$fixture/drift"
mkdir -p "$drift_home/templates" "$drift_home/docs/proposals" "$drift_home/scripts"
cp "$autometta_root/templates/phat-controller-seed.md.tpl" "$drift_home/templates/"
cp "$autometta_root/templates/phat-controller-mandate.yaml.tpl" "$drift_home/templates/"
cp "$autometta_root/docs/proposals/orchestrator-role-review.md" "$drift_home/docs/proposals/"
for s in render-controller-seed.sh resolve-root.sh subscribers.sh auth-route.sh; do cp "$autometta_root/scripts/$s" "$drift_home/scripts/"; done
sed -i.bak 's/^2\. Verifying its own dispatches\..*/2. Verifying its own dispatches, unless it is in a hurry./' "$drift_home/templates/phat-controller-seed.md.tpl"
rm -f "$drift_home/templates"/*.bak
drift_out="$(AUTOMETTA_ROOT="$drift_home" "$drift_home/scripts/render-controller-seed.sh" \
  --spend-authority x --window-reserve-percent 0 --window-reserve-action observe --print 2>&1 || true)"
assert_contains "$drift_out" "drifted" "a seed template whose prohibitions drifted is refused"
printf 'PASS the seed template cannot drift from the proposal that owns the negative list\n'

# ---------------------------------------------------------------------------
printf '== criterion 4: the verbs remain individually callable and nothing selects a remediation ==\n'
help_out="$("$script_dir/phat-controller.sh" --help)"
for verb in picture preserve rebrief propose-amendment requeue stale-halt merge-awaiting smokes push queue-card escalate journal pass; do
  assert_contains "$help_out" "  ${verb}" "verb ${verb} is callable from the CLI"
done
controller_src="$(cat "$script_dir/phat-controller.sh")"
assert_not_contains "$controller_src" "warden_try_" "the scan-and-choose-remediation loop is gone"
assert_not_contains "$controller_src" "warden_pass" "the pass no longer walks a fixed remediation order"
assert_not_contains "$controller_src" "remediation 1" "no numbered remediation list survives in the verbs"
printf 'PASS every verb is individually callable and no remediation is selected in bash\n'

printf '== picture reports observations and never names an action ==\n'
rpic="$(make_repo rpic)"
cat > "$rpic/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages:
  - id: 80-stalled-fixture
    status: stalled
    stall_marker: worker_envelope_missing_after_exit
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
YAML
pic="$(pc_picture_for_repo "$rpic")"
assert_eq stalled "$(printf '%s' "$pic" | jq -r '.signals[0].signal')" "a stalled stage shows up as a signal"
assert_eq worker_envelope_missing_after_exit "$(printf '%s' "$pic" | jq -r '.signals[0].detail')" "the signal carries the stall marker"
assert_eq null "$(printf '%s' "$pic" | jq -r '.actions // "null"')" "the picture has no actions key"
assert_eq null "$(printf '%s' "$pic" | jq -r '.remediation // "null"')" "the picture has no remediation key"
printf 'PASS the picture reports observations only\n'

# ---------------------------------------------------------------------------
printf '== criterion 6: a fixture where the correct action is none ends with none taken ==\n'
rnone="$(make_repo rnone)"
cat > "$rnone/state/state.yaml" <<'YAML'
version: 1
current_stage: 81-running-fine
stages:
  - id: 81-running-fine
    status: in_progress
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
YAML
none_head="$(git -C "$rnone" rev-parse HEAD)"
none_pic="$(pc_picture_for_repo "$rnone")"
assert_eq 0 "$(printf '%s' "$none_pic" | jq -r '.signals | length')" "a healthy repo produces no signals"
[[ -f "$(pc_journal_path "$rnone")" ]] && fail "a journal line was written for a repo that needed nothing"
assert_eq "$none_head" "$(git -C "$rnone" rev-parse HEAD)" "no ref moved"
assert_eq in_progress "$(state_status "$rnone" 81-running-fine)" "the stage was left alone"
printf 'PASS nothing to do: nothing recorded, nothing moved\n'

# ---------------------------------------------------------------------------
printf '== criteria 5 and 9, and the card-58 contract test: the evening of 2026-08-24 ==\n'
#
# Replay: a stage went stalled with worker_envelope_missing_after_exit, its run
# worktree left standing holding real uncommitted work, and the run tree's
# state/ replaced with a symlink at the repo's own state. The disposition the
# interactive session reached that night was to preserve the work, re-brief
# citing the preserved commit, and requeue, without editing an acceptance
# criterion.
rct="$(make_repo rct)"
stage_ct=54-a-warden-pass-minds-the-queue
card_ct="$rct/examples/self-host/${stage_ct}.md"
cat > "$card_ct" <<'CARD'
# Stage card 54: a phat-controller pass minds the queue

## Metadata

- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>

## Objective

Add a scheduled pass that minds the queue.

## Acceptance criteria

1. Fixture verifier_failed with preserved WIP is triaged and requeued.
2. Fixture where the artefact blames the criterion wording proposes instead.
3. All smokes pass with assertions demonstrated able to fail.

## Budget

- **Worker wall-clock:** 120 minutes
CARD
( cd "$rct" && git add examples/self-host && git commit -qm "add card ${stage_ct}" )
card_before="$(cat "$card_ct")"
criteria_before="$(awk '/^## Acceptance criteria/,/^## Budget/' "$card_ct")"

# The run worktree, as the tick leaves one: cut from base, state/ symlinked at
# the repo's own, and holding the dead worker's uncommitted work.
work_ct="$(worktree_path_for_stage "$rct" "$stage_ct")"
( cd "$rct" && git worktree add "$work_ct" -b "autometta/${stage_ct}" dev >/dev/null 2>&1 )
rm -rf "${work_ct:?}/state"
ln -s "../$(basename "$rct")/state" "$work_ct/state"
mkdir -p "$work_ct/scripts"
printf '#!/usr/bin/env bash\n# 839 lines of real work\n' > "$work_ct/scripts/phat-controller.sh"
printf 'skill body\n' > "$work_ct/README.md"
cat > "$rct/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage_ct
    status: stalled
    stall_marker: worker_envelope_missing_after_exit
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
YAML

ct_sha="$(pc_preserve "$rct" "$stage_ct")"
[[ -n "$ct_sha" ]] || fail "stalled stage: nothing was preserved"
assert_eq "$ct_sha" "$(git -C "$rct" rev-parse "refs/heads/wip/${stage_ct}-attempt-1")" "the preserved commit is pinned on the wip branch"
assert_contains "$(git -C "$rct" show -s --format=%s "$ct_sha")" "stalled: worker_envelope_missing_after_exit" "the preserved commit names the stall, not a verifier FAIL that never happened"
assert_contains "$(git -C "$rct" show --stat --format= "$ct_sha")" "scripts/phat-controller.sh" "the dead worker's real work is in the preserved commit"
assert_not_contains "$(git -C "$rct" show --stat --format= "$ct_sha")" "state" "the run tree's state symlink is not in the preserved commit"
assert_eq "$ct_sha" "$(yq -r ".stages[] | select(.id == \"$stage_ct\") | .wip_commit" "$rct/state/state.yaml")" "wip_commit recorded in state.yaml"
printf 'PASS stalled worker: work preserved, marker recorded, symlink not carried in\n'

cat > "$fixture/ct-rebrief.md" <<REBRIEF
## Re-brief (attempt 2, 2026-08-24, after worker_envelope_missing_after_exit)

Attempt 1 did not fail verification: it exited without writing a handoff
envelope. Its work is real and is preserved as one commit ${ct_sha} on
wip/${stage_ct}-attempt-1. Restore it rather than starting over, then walk
every acceptance criterion above and close whatever is not yet met.
REBRIEF
pc_rebrief "$rct" "$stage_ct" "$fixture/ct-rebrief.md"
pc_requeue "$rct" "$stage_ct"

assert_eq pending "$(state_status "$rct" "$stage_ct")" "the stalled stage is requeued"
card_after="$(cat "$card_ct")"
assert_contains "$card_after" "$ct_sha" "the re-brief cites the preserved commit"
assert_eq "$criteria_before" "$(awk '/^## Acceptance criteria/,/^## Budget/' "$card_ct")" "not one acceptance criterion moved"
assert_eq "$card_before" "${card_after:0:${#card_before}}" "the card was appended to and never rewritten"
[[ -z "$(git -C "$rct" status --porcelain -- "examples/self-host/${stage_ct}.md")" ]] || fail "the re-brief was left uncommitted"
assert_eq "$PC_GIT_IDENTITY" "$(git -C "$rct" log -1 --format='%an <%ae>' -- "examples/self-host/${stage_ct}.md")" "the re-brief commit is attributed to the role"
printf 'PASS stalled stage re-briefed citing the preserved commit and requeued, no criterion touched\n'

printf '   -- the diff proving no acceptance criterion moved --\n'
diff <(printf '%s\n' "$criteria_before") <(awk '/^## Acceptance criteria/,/^## Budget/' "$card_ct") \
  && printf '   (empty: the acceptance criteria block is byte-identical)\n'

printf '== criterion 9: every decision is journalled as structured data, before its action ==\n'
ct_journal="$(journal_of "$rct")"
[[ -n "$ct_journal" ]] || fail "no decision journal was written"
while IFS= read -r line; do
  printf '%s' "$line" | jq -e '.ts and .seq and .decision_id and .phase and .repo and .actor' >/dev/null \
    || fail "journal line is not structured data: $line"
done <<< "$ct_journal"
for verb in preserve rebrief requeue; do
  did="$(printf '%s' "$ct_journal" | jq -r --arg v "$verb" 'select(.phase == "decision" and .verb == $v) | .decision_id' | head -n1)"
  [[ -n "$did" ]] || fail "no decision line for verb ${verb}"
  dseq="$(printf '%s' "$ct_journal" | jq -r --arg d "$did" 'select(.decision_id == $d and .phase == "decision") | .seq')"
  oseq="$(printf '%s' "$ct_journal" | jq -r --arg d "$did" 'select(.decision_id == $d and .phase == "outcome") | .seq')"
  (( dseq < oseq )) || fail "${verb}: the decision was not journalled before its outcome (${dseq} >= ${oseq})"
  printf '%s' "$ct_journal" | jq -e --arg d "$did" 'select(.decision_id == $d and .phase == "decision") | .rationale != "" and .evidence != "" and .expected_effect != ""' >/dev/null \
    || fail "${verb}: the decision line carries no rationale, evidence or expected effect"
done
printf 'PASS every fixture decision is in the journal, structured, before the action it describes\n'

printf '== the journal conforms to the schema that documents it ==\n'
# schemas/decision-journal.json is a committed contract, and the fields above
# are asserted by name. Both can drift from what the code writes, in opposite
# directions, with nothing catching either. Validate the lines the fixtures
# just produced against the schema itself: required keys present, no key the
# schema does not allow, and every enum honoured.
schema_json="$autometta_root/schemas/decision-journal.json"
journal_line_conforms() {
  jq -e --slurpfile s "$schema_json" '
    ($s[0]) as $schema
    | . as $line
    | (($schema.required - ($line | keys)) | length == 0)
      and ((($line | keys) - ($schema.properties | keys)) | length == 0)
      and ([$schema.properties | to_entries[] as $p
            | select($p.value.enum != null)
            | select($line[$p.key] != null)
            | select(($p.value.enum | index($line[$p.key])) == null)
            | $p.key] | length == 0)
      and (($line.seq | type) == "number" and $line.seq >= 1)
  ' >/dev/null 2>&1
}
schema_rc=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  printf '%s' "$line" | journal_line_conforms \
    || { printf 'journal line does not conform to %s: %s\n' "$schema_json" "$line" >&2; schema_rc=1; }
done <<< "$ct_journal"
(( schema_rc == 0 )) || fail "the decision journal does not conform to its own schema"
# And the check is able to fail: a line carrying a key the schema forbids, a
# result outside the enum, or a phase that is neither, must be rejected.
for bad in '{"ts":"t","seq":1,"decision_id":"d","phase":"decision","repo":"/r","actor":"a","invented_key":"x"}' \
           '{"ts":"t","seq":1,"decision_id":"d","phase":"outcome","repo":"/r","actor":"a","result":"probably"}' \
           '{"ts":"t","seq":1,"decision_id":"d","phase":"sideways","repo":"/r","actor":"a"}' \
           '{"ts":"t","seq":1,"decision_id":"d","phase":"decision","actor":"a"}'; do
  if printf '%s' "$bad" | journal_line_conforms; then
    fail "the schema check accepted a line it should have rejected: $bad"
  fi
done
printf 'PASS the journal conforms to its schema, and the check rejects a line that does not\n'

printf '== a decision whose action is then refused still leaves its decision line ==\n'
# The proof that the journal records intent rather than effects: if it were
# derived from what happened, a refused action would leave nothing behind.
uncited="$fixture/uncited.md"
printf '## Re-brief (attempt 3, 2026-08-24)\n\nTry again.\n' > "$uncited"
before_lines="$(printf '%s\n' "$ct_journal" | grep -c '')"
refuse_rc=0
pc_rebrief "$rct" "$stage_ct" "$uncited" >/dev/null 2>&1 || refuse_rc=$?
assert_eq 3 "$refuse_rc" "a re-brief that does not cite the preserved commit is refused"
refused_journal="$(journal_of "$rct")"
assert_eq decision "$(printf '%s' "$refused_journal" | sed -n "$((before_lines + 1))p" | jq -r '.phase')" "the decision line was written first, before the guard refused"
assert_eq refused "$(printf '%s' "$refused_journal" | sed -n "$((before_lines + 2))p" | jq -r '.result')" "the outcome line records the refusal"
assert_eq "$criteria_before" "$(awk '/^## Acceptance criteria/,/^## Budget/' "$card_ct")" "the refused re-brief changed nothing on the card"
printf 'PASS a refused action still leaves the decision that led to it\n'

# ---------------------------------------------------------------------------
printf '== criterion 7: a FAIL resting on the card wording proposes and changes no criterion ==\n'
rcd="$(make_repo rcd)"
stage_cd=82-card-defect
card_cd="$rcd/examples/self-host/${stage_cd}.md"
cat > "$card_cd" <<'CARD'
# Stage card 82: card defect fixture

## Metadata

- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>

## Acceptance criteria

1. The renderer emits British English throughout.
2. The renderer emits the vendor's American spellings verbatim.

## Budget

- **Worker wall-clock:** 30 minutes
CARD
( cd "$rcd" && git add examples/self-host && git commit -qm "add card ${stage_cd}" )
cat > "$rcd/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: $stage_cd
    status: verifier_failed
    verifier_attempts: 1
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
YAML
cd_before="$(cat "$card_cd")"
cd_criteria_before="$(awk '/^## Acceptance criteria/,/^## Budget/' "$card_cd")"
cat > "$fixture/amendment.md" <<'AMEND'
## PROPOSED-AMENDMENT (2026-08-25, after 82-card-defect attempt 1)

Criteria 1 and 2 cannot both hold: criterion 1 requires British English
throughout and criterion 2 requires the vendor's American spellings verbatim.
No implementation satisfies both. Proposed replacement for criterion 2:
"2. Vendor strings are reproduced verbatim; the surrounding prose is British
English." This is a proposal, not a decision.
AMEND
pc_propose_amendment "$rcd" "$stage_cd" "$fixture/amendment.md"
assert_contains "$(cat "$card_cd")" "PROPOSED-AMENDMENT" "the proposal is on the card"
assert_eq "$cd_criteria_before" "$(awk '/^## Acceptance criteria/,/^## Budget/' "$card_cd")" "not one acceptance criterion moved"
assert_eq "$cd_before" "$(head -c ${#cd_before} "$card_cd")" "the card was appended to and never rewritten"
assert_eq verifier_failed "$(state_status "$rcd" "$stage_cd")" "a card defect requeues nothing"
printf 'PASS card defect proposed, nothing requeued, acceptance criteria byte-identical\n'
printf '   -- the diff proving no acceptance criterion moved --\n'
diff <(printf '%s\n' "$cd_criteria_before") <(awk '/^## Acceptance criteria/,/^## Budget/' "$card_cd") \
  && printf '   (empty: the acceptance criteria block is byte-identical)\n'

printf '== the append-only guard refuses a write that would alter existing card bytes ==\n'
# Prohibition 1 is not left to prose. pc_prefix_preserved is the guard itself,
# not a copy of it: pc_card_append calls this exact function and restores the
# card and refuses when it says no.
guard_card="$fixture/guard.md"
printf '3. All smokes pass with assertions demonstrated able to fail.\n' > "$guard_card"
guard_size="$(wc -c < "$guard_card" | tr -d ' ')"
guard_sum="$(shasum -a 256 < "$guard_card" | awk '{print $1}')"
printf '3. All smokes pass with assertions demonstrated able to fail.\n\nAppended.\n' > "$guard_card"
pc_prefix_preserved "$guard_size" "$guard_sum" "$guard_card" \
  || fail "the guard rejected an honest append"
printf '3. All smokes pass, or are skipped.\n' > "$guard_card"
if pc_prefix_preserved "$guard_size" "$guard_sum" "$guard_card"; then
  fail "the guard accepted a softened acceptance criterion"
fi
printf 'PASS the append-only guard accepts an append and rejects a softened criterion\n'

# ---------------------------------------------------------------------------
printf '== criterion 8: git-push-check ASK escalates, does not push, and carries on ==\n'
rask="$(make_repo rask)"
bare="$fixture/rask-origin.git"
git init -q --bare "$bare"
( cd "$rask" && git remote add origin "$bare" && git push -q origin dev )
origin_before="$(git -C "$bare" rev-parse refs/heads/dev)"
( cd "$rask" && printf 'more\n' >> README.md && git commit -qam "local work" )

stub_bin="$fixture/push-stubs"
mkdir -p "$stub_bin"
cat > "$stub_bin/git-push-check" <<'STUB'
#!/usr/bin/env bash
printf 'ASK\tthe destination is a branch this repo pipelines watch\n'
STUB
chmod +x "$stub_bin/git-push-check"

ask_rc=0
PATH="$stub_bin:$PATH" pc_push "$rask" origin "dev:dev" >/dev/null 2>&1 || ask_rc=$?
assert_eq 0 "$ask_rc" "ASK exits 0 so the controller carries on with other work"
assert_eq "$origin_before" "$(git -C "$bare" rev-parse refs/heads/dev)" "nothing was pushed on ASK"
assert_eq false "$(jq -r '.halted' "$rask/state/budget.json")" "an ASK escalation does not halt the queue"
ask_journal="$(journal_of "$rask")"
assert_eq held "$(printf '%s' "$ask_journal" | jq -r 'select(.phase == "outcome") | .result' | head -n1)" "the push outcome records the hold"
assert_contains "$ask_journal" "needs a human yes" "the escalation is recorded"
assert_eq escalated "$(printf '%s' "$ask_journal" | jq -r 'select(.phase == "outcome") | .result' | tail -n1)" "an escalation is journalled alongside it"
printf 'PASS ASK: escalated, recorded, nothing pushed, queue not blocked\n'

printf '== PUSH acts, HOLD stops and reports ==\n'
cat > "$stub_bin/git-push-check" <<'STUB'
#!/usr/bin/env bash
printf 'PUSH\tprivate working branch, strictly ahead\n'
STUB
PATH="$stub_bin:$PATH" pc_push "$rask" origin "dev:dev" >/dev/null 2>&1
assert_eq "$(git -C "$rask" rev-parse dev)" "$(git -C "$bare" rev-parse refs/heads/dev)" "PUSH pushed"
cat > "$stub_bin/git-push-check" <<'STUB'
#!/usr/bin/env bash
printf 'HOLD\tthis is the publish branch\n'
STUB
hold_rc=0
PATH="$stub_bin:$PATH" pc_push "$rask" origin "dev:dev" >/dev/null 2>&1 || hold_rc=$?
assert_eq 3 "$hold_rc" "HOLD stops and reports"
assert_contains "$(journal_of "$rask")" "publish branch" "the HOLD reason is recorded"
printf 'PASS the three verdicts map to act, escalate-and-carry-on, and stop\n'

# ---------------------------------------------------------------------------
printf '== card 54 mechanism kept: stale pause cleared, live pause left standing ==\n'
r3="$(make_repo r3)"
write_budget "$r3" false null "$(date -u +%F)" "$(( $(date -u +%s) - 100 ))"
pc_stale_halt "$r3" >/dev/null 2>&1 || true
assert_eq null "$(jq -r '.paused_until // null' "$r3/state/budget.json")" "stale pause cleared"
write_budget "$r3" false null "$(date -u +%F)" "$(( $(date -u +%s) + 3600 ))"
pc_stale_halt "$r3" >/dev/null 2>&1 || true
[[ "$(jq -r '.paused_until' "$r3/state/budget.json")" != "null" ]] || fail "live pause was cleared"
printf 'PASS stale pause cleared, live pause left standing\n'

printf '== card 54 mechanism kept: previous-window halt cleared, current-window halt standing ==\n'
write_budget "$r3" true tick-cap 2020-01-01 null
pc_stale_halt "$r3" >/dev/null 2>&1 || true
assert_eq false "$(jq -r '.halted' "$r3/state/budget.json")" "previous-window halt cleared"
write_budget "$r3" true tick-cap "$(date -u +%F)" null
stale_rc=0
pc_stale_halt "$r3" >/dev/null 2>&1 || stale_rc=$?
assert_eq true "$(jq -r '.halted' "$r3/state/budget.json")" "current-window halt left standing"
assert_eq 3 "$stale_rc" "a halt that cannot be proved stale is a refusal, not a failure"
write_budget "$r3" false null "$(date -u +%F)" null
printf 'PASS a halt that cannot be proved stale stands\n'

printf '== card 54 mechanism kept: a clean awaiting integration merges, a conflicted one surfaces ==\n'
r2="$(make_repo r2)"
stage2=84-merge-clean
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
pc_merge_awaiting "$r2" >/dev/null 2>&1 || true
assert_eq merged "$(yq -r ".stages[] | select(.id == \"$stage2\") | .integration.state" "$r2/state/state.yaml")" "integration state after clean merge"
git -C "$r2" merge-base --is-ancestor "$run_tip" dev || fail "clean divergent run tip was not integrated into dev"
assert_eq 2 "$(git -C "$r2" show -s --format='%P' dev | awk '{print NF}')" "divergent clean integration made a two-parent merge commit"
assert_eq "$PC_GIT_IDENTITY" "$(git -C "$r2" show -s --format='%an <%ae>' dev)" "merge commit author"
assert_eq acted "$(journal_of "$r2" | jq -r 'select(.phase == "outcome") | .result' | tail -n1)" "the merge is journalled"
printf 'PASS clean divergent awaiting integration merged\n'

r2c="$(make_repo r2c)"
stage2c=85-merge-conflict
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
      head: "$(git -C "$r2c" rev-parse "refs/heads/autometta/${stage2c}")"
      pushed: false
YAML
conflict_rc=0
conflict_out="$(pc_merge_awaiting "$r2c" 2>&1)" || conflict_rc=$?
assert_eq 3 "$conflict_rc" "a conflict is a refusal"
assert_contains "$conflict_out" "never resolved by the controller" "the conflict is surfaced"
assert_eq "$dev_before" "$(git -C "$r2c" rev-parse dev)" "dev untouched by a conflicted merge"
assert_contains "$(journal_of "$r2c")" "prohibition 5" "the refusal names the prohibition it rests on"
printf 'PASS conflicted awaiting integration surfaced, never resolved\n'

printf '== card 54 mechanism kept: the same verb twice with no progress escalates, blocking ==\n'
esc_rc=0
pc_merge_awaiting "$r2c" >/dev/null 2>&1 || true
pc_merge_awaiting "$r2c" >/dev/null 2>&1 || esc_rc=$?
assert_eq 3 "$esc_rc" "the third attempt refuses"
assert_eq true "$(jq -r '.halted' "$r2c/state/budget.json")" "a repeated failure halts the repo"
assert_eq controller-escalation "$(jq -r '.halt_reason' "$r2c/state/budget.json")" "the halt reason names the role"
printf 'PASS twice without progress produced a blocking escalation, not a third attempt\n'

printf '== card 54 mechanism kept: the smokes verb runs the offline checks and reports honestly ==\n'
rsm="$(make_repo rsm)"
mkdir -p "$rsm/scripts"
printf '#!/usr/bin/env bash\nprintf "fixture smoke ok\\n"\n' > "$rsm/scripts/fixture-smoke.sh"
printf '#!/usr/bin/env bash\nprintf "a live API call\\n"\nexit 1\n' > "$rsm/scripts/sdk-cache-smoke.sh"
chmod +x "$rsm/scripts/fixture-smoke.sh" "$rsm/scripts/sdk-cache-smoke.sh"
smoke_log="$fixture/rsm-smokes.log"
pc_smokes "$rsm" "$smoke_log" >/dev/null 2>&1 || fail "the smokes verb reported a failure it should not have"
assert_contains "$(cat "$smoke_log")" "fixture smoke ok" "the repo's own offline smoke ran"
assert_not_contains "$(cat "$smoke_log")" "a live API call" "the metered sdk-cache smoke is excluded"
assert_eq acted "$(journal_of "$rsm" | jq -r 'select(.phase == "outcome") | .result' | tail -n1)" "a passing smoke run is journalled as acted"
printf '#!/usr/bin/env bash\nexit 1\n' > "$rsm/scripts/broken-smoke.sh"
chmod +x "$rsm/scripts/broken-smoke.sh"
smoke_rc=0
pc_smokes "$rsm" "$smoke_log" >/dev/null 2>&1 || smoke_rc=$?
assert_eq 1 "$smoke_rc" "a failing offline smoke is reported as a failure"
assert_eq failed "$(journal_of "$rsm" | jq -r 'select(.phase == "outcome") | .result' | tail -n1)" "a failing smoke run is journalled as failed"
printf 'PASS the smokes verb runs the offline checks, excludes the metered one, and journals either way\n'

printf '== card 54 mechanism kept: queue-card adds a stage, and refuses a card that is not there ==\n'
rqc="$(make_repo rqc)"
cat > "$rqc/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages: []
YAML
qc_card="$rqc/examples/self-host/87-queue-fixture.md"
cat > "$qc_card" <<'CARD'
# Stage card 87: queue fixture

## Metadata

- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
CARD
pc_queue_card "$rqc" "$qc_card" >/dev/null 2>&1 || fail "queue-card did not queue an existing card"
assert_eq 87-queue-fixture "$(yq -r '.stages[0].id' "$rqc/state/state.yaml")" "the card was queued"
qc_rc=0
pc_queue_card "$rqc" "$rqc/examples/self-host/88-absent.md" >/dev/null 2>&1 || qc_rc=$?
assert_eq 3 "$qc_rc" "a card that is not there is a refusal"
assert_eq 1 "$(yq -r '.stages | length' "$rqc/state/state.yaml")" "nothing was queued for the absent card"
printf 'PASS queue-card adds a stage and refuses an absent one\n'

printf '== card 54 mechanism kept: controller spend is budgeted and itemised under role phat-controller ==\n'
rcl="$(make_repo rcl)"
: > "$rcl/state/logs/pc-cost-fixture.log"
printf 'Total tokens: 4200\n' >> "$rcl/state/logs/pc-cost-fixture.log"
pc_record_spend "$rcl" "86-cost-fixture" "Claude Sonnet 5 <claude-sonnet-5@local>" \
  "$rcl/state/logs/pc-cost-fixture.log" 0 5 pass
cost_line="$(tail -n1 "$rcl/state/cost-log.jsonl")"
assert_eq phat-controller "$(printf '%s' "$cost_line" | jq -r '.role')" "cost-log role"
assert_eq 4200 "$(jq -r '.tokens_spent' "$rcl/state/budget.json")" "tokens charged to the hard-stop budget"
printf 'PASS controller spend budgeted and itemised with role=phat-controller\n'

printf '== the spend authority is a hard stop, not a suggestion ==\n'
rsa="$(make_repo rsa)"
pc_mandate_ensure
CEILING=1000 yq -i '.spend_authority.token_ceiling = (strenv(CEILING) | tonumber)' "$pc_mandate_path"
jq '.tokens_spent = 5000' "$rsa/state/budget.json" > "$rsa/state/budget.json.tmp" && mv "$rsa/state/budget.json.tmp" "$rsa/state/budget.json"
assert_contains "$(pc_spend_authority_exhausted "$rsa" || true)" "is spent" "an exhausted ceiling is detected"
jq '.tokens_spent = 10' "$rsa/state/budget.json" > "$rsa/state/budget.json.tmp" && mv "$rsa/state/budget.json.tmp" "$rsa/state/budget.json"
pc_spend_authority_exhausted "$rsa" >/dev/null && fail "an unspent ceiling was reported exhausted"
EXPIRED=2020-01-01T00:00:00Z yq -i '.spend_authority.expires_at = strenv(EXPIRED)' "$pc_mandate_path"
assert_contains "$(pc_spend_authority_exhausted "$rsa" || true)" "expired" "an expired authority is detected"
yq -i '.spend_authority.expires_at = null | .spend_authority.token_ceiling = null' "$pc_mandate_path"
printf 'PASS the spend authority stops a pass when it is exhausted or expired\n'

printf '== a pass with no configured seed refuses rather than inventing a mandate ==\n'
saved_seed="$pc_seed_path"
pc_seed_path="$fixture/no-such-seed.md"
noseed_rc=0
noseed_out="$(pc_pass 2>&1)" || noseed_rc=$?
assert_eq 1 "$noseed_rc" "a pass with no seed fails closed"
assert_contains "$noseed_out" "The job has not been configured" "the failure names the missing configure step"
pc_seed_path="$saved_seed"
printf 'PASS an unconfigured job dispatches nothing\n'

# ---------------------------------------------------------------------------
printf '== criterion 10: the skill and the seed do not restate each other ==\n'
skill_body="$(cat "$autometta_root/skills/phat-controller/SKILL.md")"
seed_tpl_body="$(cat "$autometta_root/templates/phat-controller-seed.md.tpl")"
assert_contains "$skill_body" "Which fact lives where" "the skill carries the ownership table"
for owned in "Persona, mandate" "The five prohibitions" "Spend authority for this job" \
             "Paths, families and their auth modes" "Thresholds and cadence" \
             "What the verbs do" "The current state of the queue" "How to decide"; do
  assert_contains "$skill_body" "$owned" "the ownership table names: ${owned}"
done
# The seed owns the prohibitions; the skill must not carry a second copy.
assert_contains "$seed_tpl_body" "Forbidden, without exception:" "the seed owns the negative list"
assert_not_contains "$skill_body" "Forbidden, without exception:" "the skill does not restate the negative list"
assert_not_contains "$skill_body" "Verifying its own dispatches. Cross-family" "the skill does not restate a prohibition verbatim"
# The mandate owns thresholds; the seed must not restate a number.
assert_not_contains "$seed_tpl_body" "attempt_cap" "the seed does not restate a mandate threshold"
assert_not_contains "$seed_tpl_body" "pass_interval_minutes" "the seed does not restate the cadence"
# The seed owns the repo facts; the skill must not name a path or an auth mode.
assert_not_contains "$skill_body" "/Users/" "the skill carries no machine path"
printf 'PASS each fact has one owner, and the table says which\n'

printf '== bash -n over every touched shell file ==\n'
for f in "$script_dir/phat-controller.sh" "$script_dir/render-controller-seed.sh" \
         "$script_dir/install-launchagent-phat-controller.sh" \
         "$script_dir/uninstall-launchagent-phat-controller.sh" \
         "$script_dir/tick.sh" "$autometta_root/bin/autometta" "$script_dir/phat-controller-smoke.sh"; do
  bash -n "$f" || fail "bash -n failed on $f"
done
printf 'PASS bash -n\n'

printf '\nPASS phat-controller smoke\n'

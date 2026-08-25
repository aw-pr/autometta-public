#!/usr/bin/env bash
# scripts/phat-controller.sh -- the verbs phat-controller calls.
#
# Card 54 shipped this file as a script that occasionally asked an agent for a
# verdict: four remediations enumerated in bash, two stage statuses scanned,
# one narrow judgement dispatched. Card 58 inverts that. phat-controller is an
# agent seeded at configure time with a persona, a mandate and the repo facts
# it would otherwise rediscover (templates/phat-controller-seed.md.tpl,
# rendered by scripts/render-controller-seed.sh). It decides. This file is the
# set of callable operations it decides between.
#
# There is no scan-and-choose-remediation loop here any more. `picture`
# reports observations and never names an action; every other verb performs
# exactly the operation it is asked for and nothing else. Initiative lives in
# the agent, mechanism lives here.
#
# What bounds the agent is a short negative list, not an action enumeration.
# The governing distinction: the controller may change WHAT IS RECORDED AND
# WHERE, never WHAT WAS ASKED FOR OR WHETHER IT WAS MET. The list is written
# once, in docs/proposals/orchestrator-role-review.md, and carried verbatim
# into every rendered seed. Two of the five prohibitions are enforced
# mechanically here rather than trusted to prose:
#
#   - prohibition 1 (never edit a card's acceptance criteria, objective or
#     specification): pc_card_append is append-only by construction. It
#     re-reads the file after writing and refuses unless the previous bytes
#     are still an exact prefix.
#   - prohibition 3 (never rewrite history, push non-fast-forward, or move a
#     publish branch outward): `push` inherits git-push-check's verdict and
#     adds no policy of its own.
#
# Every mutating verb records its decision as structured data BEFORE acting
# (pc_journal_decision), then records the outcome after. A decision line
# therefore survives an action that fails, which is the point: the journal is
# the record of intent, and it is the whole input a second reviewing
# controller would need later. See docs/tick-loop.md "The phat-controller
# role" and examples/self-host/58-the-controller-decides-the-scripts-are-its-verbs.md.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# tick.sh is sourced, not copied, for the reason its own comments give for
# requeue-stage.sh: merge/teardown/state-write/preservation mechanics
# duplicated here would drift, and the drift would only show up as the
# controller acting on a picture the tick no longer agrees with. Sourcing also
# pulls in budget.sh, cost-log.sh, usage-limit.sh, session-slug.sh,
# subscribers.sh, resolve-root.sh and vendor-set.sh, which tick.sh sources
# itself.
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"
# shellcheck source=./models.sh
source "$script_dir/models.sh"
# The one definition of which stage statuses mean "this is not moving". The
# picture reports the same set every renderer alerts on, by reading it rather
# than by spelling it out a second time.
# shellcheck source=./alert-statuses.sh
source "$script_dir/alert-statuses.sh"

controller_home="$(autometta_controller_home)"
pc_log_dir="$controller_home/log"
pc_templates_dir="$script_dir/../templates"
pc_mandate_template="$pc_templates_dir/phat-controller-mandate.yaml.tpl"
pc_seed_template="$pc_templates_dir/phat-controller-seed.md.tpl"
pc_prompt_template="$pc_templates_dir/phat-controller-prompt.md"
pc_skill_path="$script_dir/../skills/phat-controller/SKILL.md"

# AUTOMETTA_WARDEN_MANDATE is the card-54 spelling, honoured for one release.
pc_mandate_path="${AUTOMETTA_CONTROLLER_MANDATE:-${AUTOMETTA_WARDEN_MANDATE:-$controller_home/phat-controller-mandate.yaml}}"
if [[ ! -f "$pc_mandate_path" && -f "$controller_home/warden-mandate.yaml" ]]; then
  pc_mandate_path="$controller_home/warden-mandate.yaml"
fi
pc_seed_path="${AUTOMETTA_CONTROLLER_SEED:-$controller_home/phat-controller-seed.md}"

# The identity every controller action is attributed to, in git and in the
# journal. It is not an agent identity: the agent that happens to be driving a
# pass is named separately in each journal line's `agent` field, so a journal
# read back later distinguishes the role from whichever model held it.
PC_GIT_IDENTITY="Phat Controller <phat-controller@local>"

# Override tick.sh's log() (writes to tick-<date>.log) so every controller
# line lands in its own file. An operator reading phat-controller-*.log must
# not have to filter the tick's own chatter out of it, and a ticker or
# dashboard reading tick-*.log must not have to filter the controller's out.
log() {
  local msg="$1"
  mkdir -p "$pc_log_dir"
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$msg" | tee -a "$pc_log_dir/phat-controller-$(date +%F).log" >&2
}

# --- The mandate manifest ---------------------------------------------------
#
# Thresholds and cadence only. It does not carry authority (the negative list
# is the authority, and it lives in the proposal and the rendered seed) and it
# does not carry the spend authority prose (that is answered for at configure
# time and written into the seed). The two machine-readable spend bounds below
# are mirrored into it by scripts/render-controller-seed.sh so a pass can stop
# without having to parse prose.

pc_mandate_ensure() {
  if [[ -f "$pc_mandate_path" ]]; then
    return 0
  fi
  if [[ ! -f "$pc_mandate_template" ]]; then
    log "phat-controller: mandate template missing at ${pc_mandate_template}"
    return 1
  fi
  mkdir -p "$(dirname "$pc_mandate_path")"
  cp "$pc_mandate_template" "$pc_mandate_path"
  log "phat-controller: mandate copied to ${pc_mandate_path} from the template; edit it to tune thresholds and cadence"
}

pc_mandate_get() {
  local key_path="$1" default_value="$2"
  local value=""
  if command -v yq >/dev/null 2>&1 && [[ -f "$pc_mandate_path" ]]; then
    value="$(yq -r "${key_path} // \"\"" "$pc_mandate_path" 2>/dev/null || true)"
  fi
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$value"
  fi
}

# --- The decision journal ---------------------------------------------------
#
# <repo>/state/phat-controller-journal.jsonl, append-only, one JSON object per
# line. Two phases per decision, sharing a decision_id:
#
#   {"phase":"decision", ...}  written before the action is attempted
#   {"phase":"outcome",  ...}  written after, naming what actually happened
#
# The ordering is the contract. A decision whose action then fails, or is
# refused by a guard, still leaves its decision line: the journal records
# intent, not effects. Reconstructing intent from effects afterwards is
# exactly what a second reviewing controller would not be able to do, and not
# foreclosing that is the whole reason this file exists rather than relying on
# the git commits actions happen to leave.
#
# Gitignored with the rest of state/. Schema: schemas/decision-journal.json.

pc_journal_path() {
  printf '%s/state/phat-controller-journal.jsonl\n' "$1"
}

pc_journal_seq() {
  local journal="$1" lines=0
  [[ -f "$journal" ]] && lines="$(wc -l < "$journal" | tr -d ' ')"
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=0
  printf '%s\n' "$(( lines + 1 ))"
}

# pc_journal_decision <repo> <verb> <stage_id> <rationale> <evidence> <expected_effect>
# Prints the decision_id. Every caller must capture it and pass it to
# pc_journal_outcome.
pc_journal_decision() {
  local repo_root="$1" verb="$2" stage_id="$3" rationale="$4" evidence="$5" expected="$6"
  local journal decision_id seq
  journal="$(pc_journal_path "$repo_root")"
  mkdir -p "$(dirname "$journal")"
  seq="$(pc_journal_seq "$journal")"
  decision_id="pc-$(date -u +%s)-$$-${seq}"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson seq "$seq" \
    --arg decision_id "$decision_id" \
    --arg repo "$repo_root" \
    --arg verb "$verb" \
    --arg stage_id "$stage_id" \
    --arg rationale "$rationale" \
    --arg evidence "$evidence" \
    --arg expected "$expected" \
    --arg actor "$PC_GIT_IDENTITY" \
    --arg agent "${AUTOMETTA_CONTROLLER_AGENT:-}" \
    '{ts:$ts, seq:$seq, decision_id:$decision_id, phase:"decision", repo:$repo,
      verb:$verb, stage_id:(if $stage_id == "" then null else $stage_id end),
      rationale:$rationale, evidence:$evidence, expected_effect:$expected,
      actor:$actor, agent:(if $agent == "" then null else $agent end)}' \
    >> "$journal"
  printf '%s\n' "$decision_id"
}

# pc_journal_outcome <repo> <decision_id> <result> <note>
# result: acted | refused | held | failed | escalated | none
pc_journal_outcome() {
  local repo_root="$1" decision_id="$2" result="$3" note="$4"
  local journal seq
  journal="$(pc_journal_path "$repo_root")"
  mkdir -p "$(dirname "$journal")"
  seq="$(pc_journal_seq "$journal")"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson seq "$seq" \
    --arg decision_id "$decision_id" \
    --arg repo "$repo_root" \
    --arg result "$result" \
    --arg note "$note" \
    --arg actor "$PC_GIT_IDENTITY" \
    '{ts:$ts, seq:$seq, decision_id:$decision_id, phase:"outcome", repo:$repo,
      result:$result, note:$note, actor:$actor}' \
    >> "$journal"
}

# --- Escalation, in two flavours --------------------------------------------
#
# The distinction is whether the queue may carry on. A blocking escalation is
# budget_halt, the signal every renderer (dashboard, agent-ticker, alerts
# table) already reads, and a halted repo dispatches nothing further until an
# operator clears it. A non-blocking escalation is recorded and logged loudly
# and the controller moves on to other work.
#
# git-push-check's ASK verdict is the case that forces the split. Blocking on
# ASK would stop the queue waiting for an answer nobody is awake to give,
# which is the failure this role exists to avoid.

pc_escalate_blocking() {
  local repo_root="$1" reason="$2"
  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" escalate "" \
    "$reason" "blocking: the queue must not carry on past this" "halt the repo until an operator clears it")"
  log "ESCALATION (blocking): ${reason}"
  budget_halt "$repo_root" "controller-escalation"
  pc_journal_outcome "$repo_root" "$decision_id" escalated "repo halted"
}

pc_escalate_nonblocking() {
  local repo_root="$1" reason="$2" stage_id="${3:-}"
  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" escalate "$stage_id" \
    "$reason" "non-blocking: needs a human eventually, not now" "record and carry on with other work")"
  log "ESCALATION (non-blocking, carrying on): ${reason}"
  pc_journal_outcome "$repo_root" "$decision_id" escalated "recorded, queue not blocked"
}

# --- Repeat tracking ---------------------------------------------------------
#
# <repo>/state/phat-controller-state.json: {"<stage_id>": {"<verb>": <count>}}.
# Gitignored. The controller asks this before repeating itself; the mechanism
# is card 54's and is unchanged apart from the file name. Nothing here chooses
# an action, it only answers "have I already tried this twice".

pc_state_file() {
  printf '%s/state/phat-controller-state.json\n' "$1"
}

pc_progress_gc() {
  local repo_root="$1" state_yaml="$2"
  local f
  f="$(pc_state_file "$repo_root")"
  [[ -f "$f" ]] || return 0
  jq empty "$f" >/dev/null 2>&1 || { rm -f "$f"; return 0; }
  local cur
  cur="$(state_json "$state_yaml" 2>/dev/null)" || return 0
  local id status integ resolved_stage resolved_merge tmp
  for id in $(jq -r 'keys[]' "$f" 2>/dev/null || true); do
    status="$(printf '%s' "$cur" | jq -r --arg id "$id" '[.stages[] | select(.id == $id)][0].status // "gone"')"
    integ="$(printf '%s' "$cur" | jq -r --arg id "$id" '[.stages[] | select(.id == $id)][0].integration.state // "gone"')"
    case "$status" in completed|superseded|gone) resolved_stage=true ;; *) resolved_stage=false ;; esac
    case "$integ" in awaiting) resolved_merge=false ;; *) resolved_merge=true ;; esac
    tmp="$(mktemp)"
    if jq --arg id "$id" --arg k1 "requeue" --arg k2 "merge-awaiting" \
        --argjson rs "$resolved_stage" --argjson rm "$resolved_merge" '
        if (.[$id] // {}) == {} then .
        else
          .[$id] |= (
            (if $rs then del(.[$k1]) else . end)
            | (if $rm then del(.[$k2]) else . end)
          )
          | if (.[$id] | length) == 0 then del(.[$id]) else . end
        end
      ' "$f" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  done
}

# pc_progress_check <repo_root> <stage_id> <verb> [cap]
# Prints first | retry | escalate. On first/retry the attempt is already
# recorded; on escalate nothing further is recorded and the caller must not
# apply the verb again.
pc_progress_check() {
  local repo_root="$1" stage_id="$2" verb="$3" cap="${4:-2}"
  local f
  f="$(pc_state_file "$repo_root")"
  local prev_count=0
  if [[ -f "$f" ]] && jq empty "$f" >/dev/null 2>&1; then
    prev_count="$(jq -r --arg id "$stage_id" --arg r "$verb" '.[$id][$r] // 0' "$f" 2>/dev/null || echo 0)"
  fi
  [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
  if (( prev_count >= cap )); then
    printf 'escalate\n'
    return 0
  fi
  mkdir -p "$(dirname "$f")"
  if [[ ! -f "$f" ]] || ! jq empty "$f" >/dev/null 2>&1; then
    printf '{}' > "$f"
  fi
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$stage_id" --arg r "$verb" --argjson n "$((prev_count + 1))" \
    '.[$id] = ((.[$id] // {}) + {($r): $n})' "$f" > "$tmp"
  mv "$tmp" "$f"
  if (( prev_count == 0 )); then printf 'first\n'; else printf 'retry\n'; fi
}

pc_progress_clear() {
  local repo_root="$1" stage_id="$2" verb="$3"
  local f
  f="$(pc_state_file "$repo_root")"
  [[ -f "$f" ]] && jq empty "$f" >/dev/null 2>&1 || return 0
  local tmp
  tmp="$(mktemp)"
  if jq --arg id "$stage_id" --arg r "$verb" 'del(.[$id][$r])' "$f" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

# --- Repo selection ----------------------------------------------------------

pc_enabled_repos() {
  local mind_repos
  mind_repos="$(pc_mandate_get '.repos[]' '')"
  local subscriber_file enabled repo_root
  while IFS= read -r subscriber_file; do
    [[ -n "$subscriber_file" ]] || continue
    enabled="$(read_subscriber_field "$subscriber_file" "enabled")"
    [[ "$enabled" == "true" ]] || continue
    repo_root="$(read_subscriber_field "$subscriber_file" "repo_path")"
    [[ -n "$repo_root" && -d "$repo_root" ]] || continue
    if [[ -n "$mind_repos" ]] && ! printf '%s\n' "$mind_repos" | grep -qxF "$repo_root"; then
      continue
    fi
    printf '%s\n' "$repo_root"
  done < <(sort_subscribers)
}

pc_repo_halted() {
  local repo_root="$1"
  local budget_path="$repo_root/state/budget.json"
  [[ -f "$budget_path" ]] || return 1
  [[ "$(jq -r '.halted // false' "$budget_path" 2>/dev/null || echo false)" == "true" ]]
}

# --- Verb: picture -----------------------------------------------------------
#
# The mechanical triage picture, as JSON, for one repo or the whole fleet.
# It reports OBSERVATIONS and never names an action: `signals` is a list of
# things that are true, not a list of things to do. That separation is the
# inversion card 58 makes. A picture that said "requeue this" would be the
# enumerated remediation list back again, wearing a different hat.

pc_picture_for_repo() {
  local repo_root="$1"
  local state_yaml="$repo_root/state/state.yaml"
  local budget_path="$repo_root/state/budget.json"
  local stages='[]' budget='{}'
  if [[ -f "$state_yaml" ]]; then
    stages="$(state_json "$state_yaml" 2>/dev/null | jq -c '[.stages[]? | {
      id, status, stall_marker, verifier_attempts, worker, verifier,
      wip_commit, wip_branch, integration}]' 2>/dev/null || printf '[]')"
  fi
  [[ -f "$budget_path" ]] && budget="$(jq -c '.' "$budget_path" 2>/dev/null || printf '{}')"

  # Worktree facts the state file does not hold: a run worktree still standing
  # and whether it holds work nobody has committed. `state` is excluded
  # because tick.sh's ensure_run_worktree deliberately symlinks it at the
  # shared repo_root/state, so it is always "dirty" and never the worker's.
  local worktrees='[]' stage_id work_dir dirty
  while IFS= read -r stage_id; do
    [[ -n "$stage_id" ]] || continue
    work_dir="$(worktree_path_for_stage "$repo_root" "$stage_id")"
    [[ -d "$work_dir" ]] || continue
    dirty="$(git -C "$work_dir" status --porcelain -- . ':(exclude)state' 2>/dev/null || true)"
    worktrees="$(printf '%s' "$worktrees" | jq -c \
      --arg id "$stage_id" --arg dir "$work_dir" --argjson d "$([[ -n "$dirty" ]] && echo true || echo false)" \
      '. + [{stage_id:$id, path:$dir, holds_uncommitted_work:$d}]')"
  done < <(printf '%s' "$stages" | jq -r '.[].id')

  local counters='{}' journal_tail='[]'
  [[ -f "$(pc_state_file "$repo_root")" ]] && counters="$(jq -c '.' "$(pc_state_file "$repo_root")" 2>/dev/null || printf '{}')"
  if [[ -f "$(pc_journal_path "$repo_root")" ]]; then
    journal_tail="$(tail -n 20 "$(pc_journal_path "$repo_root")" | jq -sc '.' 2>/dev/null || printf '[]')"
  fi

  jq -nc \
    --arg repo "$repo_root" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson stages "$stages" \
    --argjson budget "$budget" \
    --argjson worktrees "$worktrees" \
    --argjson counters "$counters" \
    --argjson alert_statuses "$(alert_stage_statuses_json)" \
    --argjson journal "$journal_tail" '
    {
      repo: $repo,
      generated_at: $generated_at,
      budget: $budget,
      stages: $stages,
      run_worktrees: $worktrees,
      repeat_counters: $counters,
      recent_journal: $journal,
      signals: (
        ($stages | map(select(.status as $s | $alert_statuses | index($s)) | {
           stage_id: .id,
           signal: .status,
           detail: (if .status == "verifier_failed"
                    then "verifier_attempts=" + ((.verifier_attempts // 0) | tostring)
                    else (.stall_marker // "no stall marker recorded") end)}))
        + ($stages | map(select(.integration.state? == "awaiting") | {
           stage_id: .id, signal: "integration_awaiting",
           detail: (.integration.run_branch + " -> " + .integration.base_branch)}))
        + (if ($budget.halted // false) then
             [{stage_id: null, signal: "repo_halted",
               detail: (($budget.halt_reason // "unknown") + " window_started_at=" + ($budget.window_started_at // "unknown"))}]
           else [] end)
        + (if (($budget.paused_until // null) != null) then
             [{stage_id: null, signal: "repo_paused",
               detail: ("paused_until=" + (($budget.paused_until) | tostring))}]
           else [] end)
        + ($worktrees | map(select(.holds_uncommitted_work) | {
           stage_id: .stage_id, signal: "run_worktree_holds_uncommitted_work",
           detail: .path}))
      )
    }'
}

pc_picture() {
  local target="${1:---all}"
  if [[ "$target" == "--all" ]]; then
    local repo_root out='[]'
    while IFS= read -r repo_root; do
      [[ -n "$repo_root" ]] || continue
      out="$(printf '%s' "$out" | jq -c --argjson r "$(pc_picture_for_repo "$repo_root")" '. + [$r]')"
    done < <(pc_enabled_repos)
    printf '%s\n' "$out" | jq '.'
  else
    pc_picture_for_repo "$(cd "$target" && pwd)" | jq '.'
  fi
}

# --- Verb: preserve ----------------------------------------------------------
#
# Preserve stranded work from a stage's run worktree to a per-attempt wip
# branch. Reuses tick.sh's preserve_failed_work verbatim: the index backup,
# the state/ exclusion, the rollback on any git failure and the append-only
# wip ref are the parts that must not be duplicated.
#
# Card 54's version only ever reached this through a verifier FAIL. The case
# it missed is the one that actually happened on the evening of 2026-08-24: a
# stage marked `stalled` with `worker_envelope_missing_after_exit`, its run
# worktree still standing and holding real, uncommitted work, and no verifier
# artefact anywhere to read a reason out of. That path is here.

pc_preserve() {
  local repo_root="$1" stage_id="$2"
  local state_yaml="$repo_root/state/state.yaml"
  [[ -f "$state_yaml" ]] || { log "preserve: ${repo_root} has no state.yaml"; return 1; }

  local stage status marker artefact_rel artefact_abs reason label
  stage="$(state_json "$state_yaml" | jq -c --arg id "$stage_id" '[.stages[] | select(.id == $id)][0] // empty')"
  if [[ -z "$stage" ]]; then
    log "preserve: ${repo_root} has no stage ${stage_id}"
    return 1
  fi
  status="$(printf '%s' "$stage" | jq -r '.status // ""')"
  marker="$(printf '%s' "$stage" | jq -r '.stall_marker // ""')"
  artefact_rel="$(printf '%s' "$stage" | jq -r '.verifier_artefact // ("state/verifiers/" + .id + ".json")')"
  artefact_abs="$repo_root/$artefact_rel"

  if [[ "$status" == "stalled" ]]; then
    reason="${marker:-stalled without a recorded marker}"
    label="stalled"
    artefact_abs=""
  else
    reason=""
    label="verifier FAIL"
    [[ -f "$artefact_abs" ]] || artefact_abs=""
  fi

  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" preserve "$stage_id" \
    "stage status ${status}${marker:+ (${marker})}: its run worktree holds work that is not in git" \
    "state.yaml status=${status} stall_marker=${marker:-none}" \
    "one commit on wip/${stage_id}-attempt-N, wip_commit recorded in state.yaml")"

  if ! preserve_failed_work "$repo_root" "$state_yaml" "$stage_id" "$artefact_abs" "$reason" "$label"; then
    pc_journal_outcome "$repo_root" "$decision_id" failed "preserve_failed_work declined; the worktree is left standing untouched"
    return 1
  fi

  local sha branch
  sha="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" '[.stages[] | select(.id == $id)][0].wip_commit // ""')"
  branch="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" '[.stages[] | select(.id == $id)][0].wip_branch // ""')"
  if [[ -z "$sha" ]]; then
    pc_journal_outcome "$repo_root" "$decision_id" none "worktree was clean, nothing to preserve"
    printf '\n'
    return 0
  fi
  pc_journal_outcome "$repo_root" "$decision_id" acted "preserved as ${sha} on ${branch}"
  log "preserve: ${repo_root} ${stage_id} preserved as ${sha} on ${branch}"
  printf '%s\n' "$sha"
}

# --- Verbs: rebrief and propose-amendment ------------------------------------
#
# pc_card_append is where prohibition 1 stops being prose. It appends and
# never rewrites: after writing, it re-reads the file and refuses unless every
# byte that was there before is still there, in order, at the front. An
# acceptance criterion cannot be softened, an objective cannot be narrowed,
# and a specification cannot be reworded by anything that goes through this
# function -- including by a future edit to this file that meant well.
#
# It stages exactly the one card path, never a broad `git add`, so an
# operator's unrelated dirty file is never swept in. On any commit failure the
# append stays on disk and the caller is told loudly rather than the text
# being lost or the guard being worked around.

# pc_prefix_preserved <byte-count> <sha256-of-those-bytes> <file>
# True when the file still starts with exactly those bytes. This is the whole
# of prohibition 1's mechanical half, kept as its own function so the smoke
# can exercise the guard itself rather than a copy of it.
pc_prefix_preserved() {
  local before_size="$1" before_sum="$2" card_path="$3"
  local after_prefix_sum
  after_prefix_sum="$(head -c "$before_size" "$card_path" | shasum -a 256 | awk '{print $1}')"
  [[ "$after_prefix_sum" == "$before_sum" ]]
}

pc_card_append() {
  local repo_root="$1" card_path="$2" text="$3" message="$4"
  local before_size before_sum backup
  [[ -f "$card_path" ]] || { log "card-append: no card at ${card_path}"; return 1; }
  before_size="$(wc -c < "$card_path" | tr -d ' ')"
  before_sum="$(shasum -a 256 < "$card_path" | awk '{print $1}')"
  backup="$(mktemp)"
  cp -p "$card_path" "$backup"

  printf '\n%s\n' "$text" >> "$card_path"

  if ! pc_prefix_preserved "$before_size" "$before_sum" "$card_path"; then
    cp -p "$backup" "$card_path"
    rm -f "$backup"
    log "card-append: REFUSED, the write would have changed existing card bytes in ${card_path}; restored and nothing committed"
    return 1
  fi
  rm -f "$backup"

  local rel_path="${card_path#"$repo_root"/}"
  if ! ( cd "$repo_root" && git add -- "$rel_path" && git commit --author="$PC_GIT_IDENTITY" -m "$message" -- "$rel_path" ) >/dev/null 2>&1; then
    log "card-append: ${rel_path} appended but could not be committed (unexpected branch, or a dirty index in ${repo_root}); left on disk for review"
    return 1
  fi
  return 0
}

# pc_read_text <file-or-dash>
pc_read_text() {
  if [[ "$1" == "-" ]]; then cat; else cat "$1"; fi
}

# pc_rebrief <repo> <stage-id> <text-file|-> [wip-commit]
# The re-brief must cite the preserved commit. A re-brief that does not is the
# shape of an agent that never read the preserved work, and the next worker
# would start over rather than restoring it, which is how card 54's first
# attempt lost most of a night.
pc_rebrief() {
  local repo_root="$1" stage_id="$2" source="$3" wip_commit="${4:-}"
  local state_yaml="$repo_root/state/state.yaml"
  local text card_path
  text="$(pc_read_text "$source")"
  if [[ -z "$wip_commit" && -f "$state_yaml" ]]; then
    wip_commit="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" '[.stages[] | select(.id == $id)][0].wip_commit // ""')"
  fi
  card_path="$(stage_card_for_id "$repo_root" "$stage_id" "")"

  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" rebrief "$stage_id" \
    "the next attempt needs to know what the last one did and why it stopped" \
    "preserved wip_commit=${wip_commit:-none} card=${card_path:-unresolved}" \
    "one appended re-brief block on the card, committed, no existing card text changed")"

  if [[ -z "$card_path" ]]; then
    pc_journal_outcome "$repo_root" "$decision_id" refused "no card resolves for ${stage_id}"
    log "rebrief: ${repo_root} ${stage_id} has no resolvable card; nothing appended"
    return 3
  fi
  if [[ -z "$text" ]]; then
    pc_journal_outcome "$repo_root" "$decision_id" refused "empty re-brief text"
    log "rebrief: ${repo_root} ${stage_id} was given no re-brief text; nothing appended"
    return 3
  fi
  if [[ -n "$wip_commit" && "$text" != *"$wip_commit"* ]]; then
    pc_journal_outcome "$repo_root" "$decision_id" refused "re-brief does not cite the preserved commit ${wip_commit}"
    log "rebrief: ${repo_root} ${stage_id} re-brief does not cite the preserved wip commit ${wip_commit}; refused"
    return 3
  fi
  if ! pc_card_append "$repo_root" "$card_path" "$text" "${stage_id}: phat-controller re-brief citing ${wip_commit:-no preserved commit}"; then
    pc_journal_outcome "$repo_root" "$decision_id" failed "append or commit failed"
    return 1
  fi
  pc_journal_outcome "$repo_root" "$decision_id" acted "re-brief committed on ${card_path}"
  log "rebrief: ${repo_root} ${stage_id} re-brief committed (citing ${wip_commit:-nothing})"
}

# pc_propose_amendment <repo> <stage-id> <text-file|->
# Prohibition 1's escape hatch and its only one. The controller proposes; a
# human or an interactive session decides. Requeues nothing: a stage whose
# card is under question must not run again against the wording in question.
pc_propose_amendment() {
  local repo_root="$1" stage_id="$2" source="$3"
  local text card_path
  text="$(pc_read_text "$source")"
  card_path="$(stage_card_for_id "$repo_root" "$stage_id" "")"

  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" propose-amendment "$stage_id" \
    "the FAIL rests on the card's own wording, so no retry fixes it" \
    "card=${card_path:-unresolved}" \
    "one appended PROPOSED-AMENDMENT block, committed; no criterion changed and nothing requeued")"

  if [[ -z "$card_path" ]]; then
    pc_journal_outcome "$repo_root" "$decision_id" refused "no card resolves for ${stage_id}"
    log "propose-amendment: ${repo_root} ${stage_id} has no resolvable card"
    return 3
  fi
  if [[ "$text" != *PROPOSED-AMENDMENT* ]]; then
    pc_journal_outcome "$repo_root" "$decision_id" refused "amendment text is not marked PROPOSED-AMENDMENT"
    log "propose-amendment: ${repo_root} ${stage_id} amendment text is missing the PROPOSED-AMENDMENT marker; refused"
    return 3
  fi
  if ! pc_card_append "$repo_root" "$card_path" "$text" "${stage_id}: phat-controller PROPOSED-AMENDMENT"; then
    pc_journal_outcome "$repo_root" "$decision_id" failed "append or commit failed"
    return 1
  fi
  pc_journal_outcome "$repo_root" "$decision_id" acted "proposal committed on ${card_path}; nothing requeued, awaiting a human or an interactive session"
  log "propose-amendment: ${repo_root} ${stage_id} PROPOSED-AMENDMENT committed; nothing requeued"
}

# --- Verb: requeue -----------------------------------------------------------

pc_requeue() {
  local repo_root="$1" stage_id="$2"
  local cap decision
  cap="$(pc_mandate_get '.escalation.same_remediation_without_progress_cap' 2)"
  decision="$(pc_progress_check "$repo_root" "$stage_id" requeue "$cap")"
  if [[ "$decision" == "escalate" ]]; then
    pc_escalate_blocking "$repo_root" "${stage_id}: requeued ${cap} times without the stage advancing"
    return 3
  fi

  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" requeue "$stage_id" \
    "the stage is briefed and its blockers are cleared, so it should run again" \
    "repeat counter says this is attempt ${decision}" \
    "stage back to pending, stale envelope and run worktree removed")"

  mkdir -p "$pc_log_dir"
  if "$script_dir/requeue-stage.sh" "$repo_root" "$stage_id" >>"$pc_log_dir/phat-controller-$(date +%F).log" 2>&1; then
    pc_journal_outcome "$repo_root" "$decision_id" acted "requeue-stage.sh returned clean"
    log "requeue: ${repo_root} ${stage_id} requeued"
    return 0
  fi
  pc_journal_outcome "$repo_root" "$decision_id" failed "requeue-stage.sh returned non-zero"
  log "requeue: ${repo_root} ${stage_id} requeue-stage.sh failed"
  return 1
}

# --- Verb: stale-halt --------------------------------------------------------
#
# Reuses budget_pause_active (self-clears an elapsed pause) and
# budget_ensure_window (self-clears a halt from a previous UTC window) rather
# than re-deriving staleness. Those are the audited functions every regular
# tick already calls, and a second implementation of "is this stale" could
# only drift from the first. Anything it cannot prove stale stands.

pc_stale_halt() {
  local repo_root="$1"
  local budget_path="$repo_root/state/budget.json"
  [[ -f "$budget_path" ]] || { log "stale-halt: ${repo_root} has no budget ledger"; return 1; }
  if ! acquire_repo_lock "$repo_root"; then
    log "stale-halt: ${repo_root} is locked by a live tick; left alone"
    return 1
  fi
  local acted=3
  local before_paused before_halted before_window
  before_paused="$(jq -r '.paused_until // empty' "$budget_path" 2>/dev/null || true)"
  before_halted="$(jq -r '.halted // false' "$budget_path" 2>/dev/null || echo false)"
  before_window="$(jq -r '.window_started_at // empty' "$budget_path" 2>/dev/null || true)"

  if [[ -z "$before_paused" && "$before_halted" != "true" ]]; then
    release_repo_lock "$repo_root"
    log "stale-halt: ${repo_root} is neither paused nor halted; nothing to clear"
    return 3
  fi

  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" stale-halt "" \
    "a pause or halt is standing; only a provably stale one may be cleared" \
    "paused_until=${before_paused:-none} halted=${before_halted} window_started_at=${before_window:-none}" \
    "clear only what budget_pause_active or budget_ensure_window prove stale, leave anything else standing")"

  if [[ -n "$before_paused" ]]; then
    if ! budget_pause_active "$repo_root" >/dev/null 2>&1; then
      if [[ -z "$(jq -r '.paused_until // empty' "$budget_path" 2>/dev/null || true)" ]]; then
        log "stale-halt: ${repo_root} stale pause cleared (was until epoch ${before_paused})"
        pc_journal_outcome "$repo_root" "$decision_id" acted "paused_until ${before_paused} had elapsed"
        acted=0
      fi
    fi
  fi

  if (( acted != 0 )) && [[ "$before_halted" == "true" && "$before_window" != "$(date -u +%F)" ]]; then
    budget_ensure_window "$repo_root"
    if [[ "$(jq -r '.halted // false' "$budget_path" 2>/dev/null || echo false)" == "false" ]]; then
      log "stale-halt: ${repo_root} previous-window halt (window_started_at ${before_window}) cleared at the window boundary"
      pc_journal_outcome "$repo_root" "$decision_id" acted "previous window ${before_window}"
      acted=0
    fi
  fi

  if (( acted != 0 )); then
    log "stale-halt: ${repo_root} pause or halt could not be proved stale; left standing"
    pc_journal_outcome "$repo_root" "$decision_id" none "not provably stale, left standing"
  fi
  release_repo_lock "$repo_root"
  return "$acted"
}

# --- Verb: smokes ------------------------------------------------------------

pc_run_offline_smokes() {
  local repo_root="$1" log_path="$2"
  local smoke rc=0
  for smoke in "$repo_root"/scripts/*-smoke.sh; do
    [[ -x "$smoke" ]] || continue
    # sdk-cache-smoke.sh makes a live Anthropic API call. It is a useful
    # release check, but it is explicitly not an offline smoke and must not
    # turn a deterministic verb into metered spend.
    [[ "$(basename "$smoke")" == "sdk-cache-smoke.sh" ]] && continue
    printf '\n-- %s --\n' "$smoke" >> "$log_path"
    if ! ( cd "$repo_root" && "$smoke" ) >> "$log_path" 2>&1; then
      rc=1
    fi
  done
  return "$rc"
}

pc_smokes() {
  local repo_root="$1"
  mkdir -p "$pc_log_dir"
  local smoke_log="${2:-$pc_log_dir/phat-controller-smokes-$(date +%F).log}"
  : > "$smoke_log"
  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" smokes "" \
    "a change has landed and the repo's own offline checks are the cheapest evidence it holds" \
    "running every scripts/*-smoke.sh except the live sdk-cache-smoke.sh" \
    "a pass or fail recorded against ${smoke_log}")"
  if pc_run_offline_smokes "$repo_root" "$smoke_log"; then
    pc_journal_outcome "$repo_root" "$decision_id" acted "offline smokes passed"
    log "smokes: ${repo_root} offline smokes passed (${smoke_log})"
    return 0
  fi
  pc_journal_outcome "$repo_root" "$decision_id" failed "offline smokes failed, see ${smoke_log}"
  log "smokes: ${repo_root} offline smokes FAILED (${smoke_log})"
  return 1
}

# --- Verb: push --------------------------------------------------------------
#
# No new policy surface. git-push-check already encodes the fleet's rule, and
# its three verdicts read directly as a human-presence protocol:
#
#   PUSH  act; a private working branch, nothing downstream sees it
#   ASK   escalate, record, and carry on with other work
#   HOLD  stop, and report the reason
#
# ASK deliberately exits 0. The caller has other work to do and there is
# nobody awake to answer; blocking here would be the queue sitting still until
# morning, which is the failure this role exists to prevent.

pc_push() {
  local repo_root="$1" remote="$2" refspec="$3"
  local decision_id verdict
  decision_id="$(pc_journal_decision "$repo_root" push "" \
    "work is committed locally and an unpushed commit is not a backup" \
    "asking git-push-check ${remote} ${refspec}" \
    "act on PUSH, escalate and carry on on ASK, stop and report on HOLD")"

  if ! command -v git-push-check >/dev/null 2>&1; then
    pc_journal_outcome "$repo_root" "$decision_id" refused "git-push-check is not on PATH; the controller adds no policy of its own, so it does not push"
    log "push: git-push-check not on PATH; not pushing"
    return 3
  fi
  verdict="$(cd "$repo_root" && git-push-check "$remote" "$refspec" 2>&1 | tail -n1 || true)"
  case "$verdict" in
    PUSH*)
      if (cd "$repo_root" && git push "$remote" "$refspec" >/dev/null 2>&1); then
        pc_journal_outcome "$repo_root" "$decision_id" acted "pushed ${remote} ${refspec} on verdict PUSH"
        log "push: ${repo_root} pushed ${remote} ${refspec}"
        return 0
      fi
      pc_journal_outcome "$repo_root" "$decision_id" failed "verdict was PUSH but the push itself failed"
      log "push: ${repo_root} git-push-check said PUSH but the push failed"
      return 1
      ;;
    ASK*)
      pc_journal_outcome "$repo_root" "$decision_id" held "verdict ASK: escalated for a human, not pushed, carrying on"
      pc_escalate_nonblocking "$repo_root" "push ${remote} ${refspec} needs a human yes (git-push-check: ${verdict})"
      return 0
      ;;
    HOLD*)
      pc_journal_outcome "$repo_root" "$decision_id" held "verdict HOLD: ${verdict}"
      log "push: ${repo_root} HELD, git-push-check said ${verdict}"
      return 3
      ;;
    NOOP*)
      pc_journal_outcome "$repo_root" "$decision_id" none "verdict NOOP: nothing to send"
      log "push: ${repo_root} nothing to send (${verdict})"
      return 0
      ;;
    *)
      pc_journal_outcome "$repo_root" "$decision_id" refused "unrecognised verdict ${verdict}"
      log "push: ${repo_root} git-push-check verdict unrecognised (${verdict}); not pushing"
      return 3
      ;;
  esac
}

# --- Verb: merge-awaiting ----------------------------------------------------
#
# Merge an already-verified run branch into base without moving repo_root's
# HEAD. Fast-forward when possible. An awaiting record normally means base
# moved after dispatch, so the common path is a clean two-parent merge commit
# in the worktree that already has base checked out, or a commit-tree/update-
# ref transaction when base has no worktree. Prohibition 5 stands: a conflict
# is surfaced, never resolved.

pc_merge_clean() {
  local repo_root="$1" stage_id="$2" base_branch="$3" run_branch="$4" merge_tree="$5"
  local base_tip run_tip base_dir author_name author_email
  author_name="${PC_GIT_IDENTITY% <*}"
  author_email="${PC_GIT_IDENTITY##*<}"
  author_email="${author_email%>}"
  base_tip="$(git -C "$repo_root" rev-parse -q --verify "refs/heads/${base_branch}" 2>/dev/null || true)"
  run_tip="$(git -C "$repo_root" rev-parse -q --verify "refs/heads/${run_branch}" 2>/dev/null || true)"
  [[ -n "$base_tip" && -n "$run_tip" && -n "$merge_tree" ]] || return 1

  if git -C "$repo_root" merge-base --is-ancestor "$base_tip" "$run_tip" 2>/dev/null; then
    [[ "$(finalize_run_worktree "$repo_root" "$stage_id" "$base_branch")" == "merged" ]]
    return
  fi

  base_dir="$(worktree_dir_for_branch "$repo_root" "$base_branch")"
  if [[ -n "$base_dir" ]]; then
    if [[ -n "$(git -C "$base_dir" status --porcelain -- . ':(exclude)state' 2>/dev/null || true)" ]]; then
      log "merge-awaiting: ${repo_root} ${stage_id} base worktree ${base_dir} is dirty; surfaced, not touched"
      return 1
    fi
    (
      cd "$base_dir"
      GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
        git merge --no-ff --no-edit "$run_branch" >/dev/null 2>&1
    )
    return
  fi

  local merge_commit
  merge_commit="$(
    cd "$repo_root"
    GIT_AUTHOR_NAME="$author_name" \
    GIT_AUTHOR_EMAIL="$author_email" \
      git commit-tree "$merge_tree" -p "$base_tip" -p "$run_tip" \
        -m "${stage_id}: phat-controller integrates ${run_branch} into ${base_branch}"
  )" || return 1
  [[ -n "$merge_commit" ]] || return 1
  git -C "$repo_root" update-ref "refs/heads/${base_branch}" "$merge_commit" "$base_tip"
}

pc_merge_awaiting() {
  local repo_root="$1" stage_id="${2:-}"
  local state_yaml="$repo_root/state/state.yaml"
  [[ -f "$state_yaml" ]] || { log "merge-awaiting: ${repo_root} has no state.yaml"; return 1; }
  pc_progress_gc "$repo_root" "$state_yaml"

  local candidate
  if [[ -n "$stage_id" ]]; then
    candidate="$(state_json "$state_yaml" | jq -c --arg id "$stage_id" '[.stages[] | select(.id == $id)][0] // empty' 2>/dev/null || true)"
  else
    candidate="$(state_json "$state_yaml" | jq -c '[.stages[] | select(.integration.state == "awaiting")][0] // empty' 2>/dev/null || true)"
  fi
  [[ -n "$candidate" && "$candidate" != "null" ]] || { log "merge-awaiting: ${repo_root} has no awaiting integration"; return 3; }

  local base_branch run_branch
  stage_id="$(printf '%s' "$candidate" | jq -r '.id')"
  base_branch="$(printf '%s' "$candidate" | jq -r '.integration.base_branch // ""')"
  run_branch="$(printf '%s' "$candidate" | jq -r '.integration.run_branch // ""')"
  if [[ -z "$base_branch" || -z "$run_branch" ]]; then
    log "merge-awaiting: ${repo_root} ${stage_id} has no integration record to act on"
    return 3
  fi

  if ! acquire_repo_lock "$repo_root"; then
    log "merge-awaiting: ${repo_root} is locked by a live tick; left alone"
    return 1
  fi

  local cap decision
  cap="$(pc_mandate_get '.escalation.same_remediation_without_progress_cap' 2)"
  decision="$(pc_progress_check "$repo_root" "$stage_id" merge-awaiting "$cap")"
  if [[ "$decision" == "escalate" ]]; then
    pc_escalate_blocking "$repo_root" "${stage_id}: merge-awaiting attempted ${cap} times with no progress"
    release_repo_lock "$repo_root"
    return 3
  fi

  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" merge-awaiting "$stage_id" \
    "the stage is verified and only its integration is outstanding" \
    "integration.state=awaiting ${run_branch} -> ${base_branch}" \
    "a conflict-free merge into ${base_branch}, worktree torn down, record closed to merged")"

  if ! git -C "$repo_root" rev-parse -q --verify "refs/heads/${base_branch}" >/dev/null 2>&1 \
     || ! git -C "$repo_root" rev-parse -q --verify "refs/heads/${run_branch}" >/dev/null 2>&1; then
    log "merge-awaiting: ${repo_root} ${stage_id} ${base_branch} or ${run_branch} no longer resolves; surfaced, not touched"
    pc_journal_outcome "$repo_root" "$decision_id" refused "a branch named by the integration record no longer resolves"
    release_repo_lock "$repo_root"
    return 3
  fi

  local merge_rc=0 merge_tree=""
  merge_tree="$(git -C "$repo_root" merge-tree --write-tree "$base_branch" "$run_branch" 2>/dev/null)" || merge_rc=$?
  if (( merge_rc != 0 )); then
    log "merge-awaiting: ${repo_root} ${stage_id} ${run_branch} conflicts with ${base_branch}; surfaced, never resolved by the controller"
    pc_journal_outcome "$repo_root" "$decision_id" refused "conflict; prohibition 5 forbids resolving it"
    release_repo_lock "$repo_root"
    return 3
  fi

  local run_tip
  run_tip="$(git -C "$repo_root" rev-parse -q --verify "refs/heads/${run_branch}" 2>/dev/null || true)"
  if ! pc_merge_clean "$repo_root" "$stage_id" "$base_branch" "$run_branch" "$merge_tree"; then
    log "merge-awaiting: ${repo_root} ${stage_id} had a clean merge tree but base could not be advanced safely; surfaced"
    pc_journal_outcome "$repo_root" "$decision_id" failed "clean merge tree but base could not be advanced"
    release_repo_lock "$repo_root"
    return 1
  fi

  teardown_run_worktree "$repo_root" "$stage_id"
  record_stage_integration "$state_yaml" "$stage_id" \
    "$(integration_record merged "$base_branch" "$run_branch" "$run_tip" "")"
  pc_progress_clear "$repo_root" "$stage_id" merge-awaiting
  pc_journal_outcome "$repo_root" "$decision_id" acted "${run_branch} integrated into ${base_branch}"
  log "merge-awaiting: ${repo_root} ${stage_id} merged ${run_branch} into ${base_branch}"
  release_repo_lock "$repo_root"
  return 0
}

# --- Verb: queue-card --------------------------------------------------------

pc_queue_card() {
  local repo_root="$1" card_path="$2"
  local stage_id
  stage_id="$(basename "$card_path" .md)"
  local decision_id
  decision_id="$(pc_journal_decision "$repo_root" queue-card "$stage_id" \
    "the queue has room and this card's stated gate is satisfied" \
    "card=${card_path}" \
    "one new pending stage in state.yaml")"
  if [[ ! -f "$card_path" ]]; then
    pc_journal_outcome "$repo_root" "$decision_id" refused "no card file at ${card_path}"
    log "queue-card: ${repo_root} no card at ${card_path}"
    return 3
  fi
  mkdir -p "$pc_log_dir"
  if "$script_dir/add-stage.sh" "$repo_root" "$card_path" >>"$pc_log_dir/phat-controller-$(date +%F).log" 2>&1; then
    pc_journal_outcome "$repo_root" "$decision_id" acted "queued ${stage_id}"
    log "queue-card: ${repo_root} queued ${stage_id}"
    return 0
  fi
  pc_journal_outcome "$repo_root" "$decision_id" failed "add-stage.sh returned non-zero"
  log "queue-card: ${repo_root} add-stage.sh failed for ${stage_id}"
  return 1
}

# --- Verb: pass --------------------------------------------------------------
#
# The headless caller. It renders the operator's seed, the shared skill and
# the current picture into one prompt and dispatches a single agent, which
# then decides and calls the verbs above. This function chooses nothing about
# the queue: the only decisions it makes are whether the seed exists and
# whether there is spend authority left to make a pass with.

pc_spend_authority_exhausted() {
  local repo_root="$1"
  local ceiling expires spent now
  ceiling="$(pc_mandate_get '.spend_authority.token_ceiling' '')"
  expires="$(pc_mandate_get '.spend_authority.expires_at' '')"
  if [[ -n "$expires" ]]; then
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$now" > "$expires" ]]; then
      printf 'the spend authority expired at %s\n' "$expires"
      return 0
    fi
  fi
  if [[ "$ceiling" =~ ^[0-9]+$ ]] && [[ -f "$repo_root/state/budget.json" ]]; then
    spent="$(jq -r '.tokens_spent // 0' "$repo_root/state/budget.json" 2>/dev/null || echo 0)"
    [[ "$spent" =~ ^[0-9]+$ ]] || spent=0
    if (( spent >= ceiling )); then
      printf 'the spend authority of %s tokens is spent (%s used)\n' "$ceiling" "$spent"
      return 0
    fi
  fi
  return 1
}

pc_render_pass_prompt() {
  local identity="$1"
  local seed skill rendered
  seed="$(cat "$pc_seed_path")"
  skill=""
  [[ -f "$pc_skill_path" ]] && skill="$(cat "$pc_skill_path")"
  # Bash parameter substitution rather than sed or awk: the seed and the skill
  # are multi-line markdown, and in both of those an unescaped `&` in a
  # replacement means "the text that matched". That would be a silently
  # corrupted prompt rather than an error.
  rendered="$(cat "$pc_prompt_template")"
  rendered="${rendered//"<<controller-seed>>"/$seed}"
  rendered="${rendered//"<<controller-skill>>"/$skill}"
  rendered="${rendered//"<<controller-identity>>"/$identity}"
  rendered="${rendered//"<<verbs-path>>"/$script_dir/phat-controller.sh}"
  rendered="${rendered//"<<seed-path>>"/$pc_seed_path}"
  printf '%s\n' "$rendered"
}

pc_pass() {
  for tool in yq jq; do
    command -v "$tool" >/dev/null 2>&1 || { log "phat-controller: ${tool} is required but missing"; return 1; }
  done
  pc_mandate_ensure || return 1

  if [[ ! -f "$pc_seed_path" ]]; then
    log "phat-controller: no context seed at ${pc_seed_path}. The job has not been configured. Run scripts/render-controller-seed.sh --spend-authority '<what this run may spend>' first; the seed is not created with a default because there is no right default for a spend authority."
    return 1
  fi

  local -a repos=()
  local repo_root
  while IFS= read -r repo_root; do
    [[ -n "$repo_root" ]] || continue
    repos+=( "$repo_root" )
  done < <(pc_enabled_repos)
  if [[ ${#repos[@]} -eq 0 ]]; then
    log "phat-controller: no repos to mind"
    return 0
  fi

  # The controller works inside its envelope or it stops (prohibition 4).
  # There is nobody to escalate to mid-run, so an exhausted authority halts
  # rather than waiting.
  # The authority is one answer given for the whole job, so the first repo to
  # exhaust it ends the pass rather than the pass moving on to spend the same
  # envelope somewhere else.
  local exhausted
  for repo_root in "${repos[@]}"; do
    if exhausted="$(pc_spend_authority_exhausted "$repo_root")"; then
      log "phat-controller: no pass dispatched, ${exhausted} (first seen at ${repo_root})"
      pc_escalate_blocking "$repo_root" "spend authority exhausted: ${exhausted}"
      return 0
    fi
  done

  local host_repo="${repos[0]}"
  if pc_repo_halted "$host_repo"; then
    log "phat-controller: ${host_repo} is halted; a halted repo dispatches nothing until an operator clears it"
    return 0
  fi

  local identity family
  identity="$(pc_mandate_get '.dispatch.identity' 'Claude Sonnet 5 <claude-sonnet-5@local>')"
  family="$(costlog_family_for_identity "$identity")"
  if [[ "$family" != "claude" && "$family" != "codex" ]]; then
    log "phat-controller: the mandate names an unsupported controller identity (${identity})"
    return 1
  fi

  mkdir -p "$host_repo/state/logs" "$pc_log_dir"
  local picture_file dispatch_log
  picture_file="$(mktemp)"
  dispatch_log="$host_repo/state/logs/phat-controller-pass.log"
  pc_picture --all > "$picture_file"

  local prompt
  prompt="$(pc_render_pass_prompt "$identity")"
  prompt="${prompt}

## The picture at the start of this pass

\`\`\`json
$(cat "$picture_file")
\`\`\`
"
  rm -f "$picture_file"

  local autometta_root_local
  autometta_root_local="$(autometta_self_root "$script_dir")"
  if [[ -f "$autometta_root_local/op-refs.sh" ]]; then
    # shellcheck source=/dev/null
    source "$autometta_root_local/op-refs.sh"
  fi
  local auth_pairs auth_mode
  auth_pairs="$(REPO_ROOT="$host_repo" "$script_dir/auth-route.sh" "$family")" || {
    log "phat-controller: auth-route resolver failed for ${family}"; return 1; }
  auth_mode="$(REPO_ROOT="$host_repo" "$script_dir/auth-route.sh" "$family" --print-mode)" || {
    log "phat-controller: auth-route mode could not be resolved"; return 1; }

  if ! budget_gate_dispatch "$host_repo" "phat-controller pass"; then
    log "phat-controller: pass refused by the budget gate"
    return 0
  fi
  if ! command -v op-fetch >/dev/null 2>&1; then
    log "phat-controller: op-fetch not on PATH, required for the auth-route wrapper"
    return 1
  fi

  local effort timeout_seconds started_epoch
  effort="$(pc_mandate_get '.dispatch.effort' high)"
  timeout_seconds="$(pc_mandate_get '.dispatch.timeout_seconds' 900)"
  [[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -gt 0 ]] || timeout_seconds=900
  effort_argv_for_family "$family" "$effort"
  codex_state_argv_for_repo "$host_repo"

  local codex_home_override=""
  if [[ "$family" == "codex" && "$auth_mode" == "api" ]]; then
    codex_home_override="${AUTOMETTA_CODEX_HOME:-$HOME/.codex-api-only}"
    if [[ ! -f "$codex_home_override/auth.json" ]]; then
      log "phat-controller: codex api dispatch requires a sibling CODEX_HOME with auth_mode apikey"
      return 1
    fi
  fi

  started_epoch="$(date -u +%s)"
  local dispatch_pid
  case "$family" in
    claude)
      # shellcheck disable=SC2086
      ( cd "$host_repo" && op-fetch $auth_pairs -- claude --model "$(claude_model_for_identity "$identity")" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --dangerously-skip-permissions --output-format json -p "$prompt" </dev/null 2>"$dispatch_log" | "$script_dir/claude-token-log.sh" >>"$dispatch_log" ) 2>>"$dispatch_log" &
      dispatch_pid=$!
      ;;
    codex)
      if [[ -n "$codex_home_override" ]]; then
        # shellcheck disable=SC2086
        CODEX_HOME="$codex_home_override" op-fetch $auth_pairs --pass CODEX_HOME -- codex exec -C "$host_repo" --model "$AUTOMETTA_MODEL_CODEX" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --sandbox workspace-write ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$prompt" </dev/null >"$dispatch_log" 2>&1 &
      else
        # shellcheck disable=SC2086
        op-fetch $auth_pairs -- codex exec -C "$host_repo" --model "$AUTOMETTA_MODEL_CODEX" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --sandbox workspace-write ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$prompt" </dev/null >"$dispatch_log" 2>&1 &
      fi
      dispatch_pid=$!
      ;;
  esac

  local deadline=$((started_epoch + timeout_seconds))
  while kill -0 "$dispatch_pid" 2>/dev/null; do
    if (( $(date -u +%s) >= deadline )); then
      pkill -TERM -P "$dispatch_pid" 2>/dev/null || true
      kill -TERM "$dispatch_pid" 2>/dev/null || true
      sleep 2
      pkill -KILL -P "$dispatch_pid" 2>/dev/null || true
      kill -0 "$dispatch_pid" 2>/dev/null && kill -KILL "$dispatch_pid" 2>/dev/null || true
      log "phat-controller: pass exceeded ${timeout_seconds}s and was stopped"
      break
    fi
    sleep 1
  done
  wait "$dispatch_pid" 2>/dev/null || true

  local wall=$(( $(date -u +%s) - started_epoch ))
  pc_record_spend "$host_repo" "phat-controller-pass" "$identity" "$dispatch_log" "$started_epoch" "$wall" pass
  log "phat-controller: pass complete after ${wall}s (${dispatch_log})"
}

pc_record_spend() {
  local repo_root="$1" stage_id="$2" identity="$3" dispatch_log="$4"
  local started_epoch="$5" wall="$6" result="$7"
  local family
  family="$(costlog_family_for_identity "$identity")"
  budget_account_tokens_from_dispatch "$repo_root" "$dispatch_log" "phat-controller" \
    "$repo_root" "$started_epoch" "$family" || true
  costlog_append "$repo_root" "$stage_id" phat-controller "$identity" "$dispatch_log" "$wall" "$result" \
    "$repo_root" "$started_epoch" || true
}

# --- CLI ---------------------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage: phat-controller.sh <verb> [args]

phat-controller is a seeded agent; this file is the set of verbs it calls.
There is no scan-and-choose loop here: `picture` reports observations and
every other verb performs exactly what it is asked for.

  pass                                  render the seed and dispatch one
                                        controller agent to decide and act
  picture [<repo>|--all]                the mechanical triage picture as JSON
  preserve <repo> <stage-id>            preserve stranded work to a wip branch
                                        (prints the commit sha)
  rebrief <repo> <stage-id> <file|->    append and commit a re-brief; refuses
                                        one that does not cite the preserved
                                        commit
  propose-amendment <repo> <stage-id> <file|->
                                        append and commit a PROPOSED-AMENDMENT;
                                        requeues nothing
  requeue <repo> <stage-id>             run requeue-stage.sh
  stale-halt <repo>                     clear a provably stale pause or halt
  merge-awaiting <repo> [<stage-id>]    merge a conflict-free awaiting
                                        integration
  smokes <repo> [<log-path>]            run the repo's offline smokes
  push <repo> <remote> <refspec>        push per git-push-check's verdict
  queue-card <repo> <card-path>         add a stage to the queue
  escalate <repo> <reason> [--blocking] record an escalation
  journal <repo>                        print the decision journal
  --print-mandate                       print the resolved mandate
  --print-seed                          print the rendered context seed

Exit codes: 0 acted or nothing needed doing, 1 failed, 2 bad usage,
3 refused or held (a deliberate non-action the caller must respect).
USAGE
}

main() {
  local verb="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  case "$verb" in
    --help|-h|"") usage; [[ -z "$verb" ]] && exit 2 || exit 0 ;;
    --print-mandate)
      pc_mandate_ensure
      cat "$pc_mandate_path"
      ;;
    --print-seed)
      if [[ ! -f "$pc_seed_path" ]]; then
        printf 'no context seed at %s; the job has not been configured (scripts/render-controller-seed.sh)\n' "$pc_seed_path" >&2
        exit 1
      fi
      cat "$pc_seed_path"
      ;;
    pass)           pc_pass "$@" ;;
    picture)        pc_picture "${1:---all}" ;;
    preserve)       [[ $# -eq 2 ]] || { usage >&2; exit 2; }; pc_preserve "$(cd "$1" && pwd)" "$2" ;;
    rebrief)        [[ $# -ge 3 ]] || { usage >&2; exit 2; }; pc_rebrief "$(cd "$1" && pwd)" "$2" "$3" "${4:-}" ;;
    propose-amendment) [[ $# -eq 3 ]] || { usage >&2; exit 2; }; pc_propose_amendment "$(cd "$1" && pwd)" "$2" "$3" ;;
    requeue)        [[ $# -eq 2 ]] || { usage >&2; exit 2; }; pc_requeue "$(cd "$1" && pwd)" "$2" ;;
    stale-halt)     [[ $# -eq 1 ]] || { usage >&2; exit 2; }; pc_stale_halt "$(cd "$1" && pwd)" ;;
    merge-awaiting) [[ $# -ge 1 ]] || { usage >&2; exit 2; }; pc_merge_awaiting "$(cd "$1" && pwd)" "${2:-}" ;;
    smokes)         [[ $# -ge 1 ]] || { usage >&2; exit 2; }; pc_smokes "$(cd "$1" && pwd)" "${2:-}" ;;
    push)           [[ $# -eq 3 ]] || { usage >&2; exit 2; }; pc_push "$(cd "$1" && pwd)" "$2" "$3" ;;
    queue-card)     [[ $# -eq 2 ]] || { usage >&2; exit 2; }; pc_queue_card "$(cd "$1" && pwd)" "$2" ;;
    escalate)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      local repo="$(cd "$1" && pwd)" reason="$2"
      if [[ "${3:-}" == "--blocking" ]]; then
        pc_escalate_blocking "$repo" "$reason"
      else
        pc_escalate_nonblocking "$repo" "$reason"
      fi
      ;;
    journal)
      [[ $# -eq 1 ]] || { usage >&2; exit 2; }
      local j; j="$(pc_journal_path "$(cd "$1" && pwd)")"
      [[ -f "$j" ]] && cat "$j" || true
      ;;
    *) usage >&2; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

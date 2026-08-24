#!/usr/bin/env bash
# scripts/warden.sh -- one phat-controller pass: triage the queue and
# perform at most one of four enumerated remediations, then exit.
#
# Cron plus tick, same discipline as scripts/tick.sh: this is not a daemon.
# Invoked as `autometta warden`, on its own LaunchAgent interval
# (templates/launchagent-warden.plist.tpl /
# scripts/install-launchagent-warden.sh), independently of the tick's own
# schedule and under one fleet-wide label. A pass reads state, makes at most
# one remediation across the whole fleet, writes state, exits.
#
# The allowed-actions list is closed and hard-coded here -- not in the
# prompt rendered for remediation 1, and not in the mandate manifest
# (templates/warden-mandate.yaml.tpl / $PHAT_CONTROLLER_HOME/warden-mandate.yaml):
#
#   1. requeue a verifier_failed stage after triage (the only remediation
#      that dispatches an agent and spends tokens)
#   2. merge a conflict-free `awaiting` integration into base
#   3. clear a pause or halt that is provably stale
#   4. queue the next PLAN.md card whose stated gate is satisfied, when the
#      queue is empty
#
# Anything else is out of bounds by construction. See docs/phat-controller.md
# "The warden role" and examples/self-host/54-a-warden-pass-minds-the-queue.md.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# tick.sh is sourced, not copied, for the reason its own comments give for
# requeue-stage.sh: merge/teardown/state-write mechanics duplicated here
# would drift, and the drift would only show up as the warden acting on a
# picture the tick no longer agrees with. Sourcing also pulls in budget.sh,
# cost-log.sh, usage-limit.sh, session-slug.sh, subscribers.sh,
# resolve-root.sh and vendor-set.sh, which tick.sh sources itself.
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"
# shellcheck source=./models.sh
source "$script_dir/models.sh"

controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
warden_log_dir="$controller_home/log"
warden_mandate_path="${AUTOMETTA_WARDEN_MANDATE:-$controller_home/warden-mandate.yaml}"
warden_mandate_template="$script_dir/../templates/warden-mandate.yaml.tpl"
warden_prompt_template="$script_dir/../templates/warden-prompt.md"

# Override tick.sh's log() (writes to tick-<date>.log) so every warden line
# lands in its own file. An operator reading warden-*.log must not have to
# filter the tick's own chatter out of it, and a ticker/dashboard reading
# tick-*.log must not have to filter the warden's out.
log() {
  local msg="$1"
  mkdir -p "$warden_log_dir"
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$msg" | tee -a "$warden_log_dir/warden-$(date +%F).log" >&2
}

# escalate: the loud log line plus the ticker-visible alert acceptance
# criterion 8 asks for. Reuses budget_halt with an operational reason rather
# than inventing a second alert channel: halted is already the signal every
# renderer (dashboard, agent-ticker, alerts table) reads, so a warden
# escalation is visible everywhere a cap halt already is, with no new wiring.
# A halted repo dispatches nothing further -- worker, verifier, or warden --
# until an operator clears it, which is exactly "not a third attempt".
escalate() {
  local repo_root="$1" reason="$2"
  log "ESCALATION: ${reason}"
  budget_halt "$repo_root" "warden-escalation"
  warden_action_record "$repo_root" "" escalation halted "$reason"
}

# --- Mandate manifest -------------------------------------------------------
#
# Deliverable 7: a committed template plus a gitignored operator copy in the
# controller home. This file tunes thresholds and cadence only; the action
# list above is fixed in this script and is never read from the mandate.

warden_mandate_ensure() {
  if [[ -f "$warden_mandate_path" ]]; then
    return 0
  fi
  if [[ ! -f "$warden_mandate_template" ]]; then
    log "warden: mandate template missing at ${warden_mandate_template}, aborting pass"
    return 1
  fi
  mkdir -p "$(dirname "$warden_mandate_path")"
  cp "$warden_mandate_template" "$warden_mandate_path"
  log "warden: mandate copied to ${warden_mandate_path} from the template; edit it to tune thresholds and cadence (never authority -- the action list lives in scripts/warden.sh)"
}

warden_mandate_get() {
  local key_path="$1" default_value="$2"
  local value=""
  if command -v yq >/dev/null 2>&1 && [[ -f "$warden_mandate_path" ]]; then
    value="$(yq -r "${key_path} // \"\"" "$warden_mandate_path" 2>/dev/null || true)"
  fi
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$value"
  fi
}

# Append-only runtime audit. Mechanical actions may not create a git commit,
# so this state write is where the warden identity is attributed consistently
# for stale clears, fast-forwards, queue additions and escalations.
warden_action_record() {
  local repo_root="$1" stage_id="$2" remediation="$3" result="$4" note="$5"
  local out="$repo_root/state/warden-actions.jsonl"
  mkdir -p "$(dirname "$out")"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg stage_id "$stage_id" \
    --arg remediation "$remediation" \
    --arg result "$result" \
    --arg note "$note" \
    --arg identity "$WARDEN_GIT_IDENTITY" \
    '{ts:$ts, stage_id:(if $stage_id == "" then null else $stage_id end), remediation:$remediation, result:$result, note:$note, warden_identity:$identity}' \
    >> "$out"
}

# --- Per-stage progress tracking (the twice-without-progress rule) ---------
#
# <repo>/state/warden-state.json: {"<stage_id>": {"<remediation>": <count>}}.
# Gitignored alongside the rest of state/. Counts survive across passes so
# "applied twice with no progress" can be measured; an entry is dropped once
# the stage reaches a resolved status (completed or superseded), so a stage
# that genuinely recovers starts counting from zero if the same problem ever
# recurs later.

warden_state_file() {
  printf '%s/state/warden-state.json\n' "$1"
}


# GC is remediation-specific, not a single top-level-status check: an
# `awaiting`-integration stage's own .status is already "completed" (the
# verifier passed; only the git integration is outstanding), so a GC keyed
# on .status alone would wipe the merge-awaiting counter on every pass and
# the twice-without-progress rule could never fire for remediation 2.
# requeue-verifier-failed resolves when the stage itself resolves
# (completed/superseded/gone); merge-awaiting resolves when the integration
# record leaves "awaiting" (merged, or the stage is gone).
warden_progress_gc() {
  local repo_root="$1" state_yaml="$2"
  local f
  f="$(warden_state_file "$repo_root")"
  [[ -f "$f" ]] || return 0
  jq empty "$f" >/dev/null 2>&1 || { rm -f "$f"; return 0; }
  local cur
  cur="$(state_json "$state_yaml" 2>/dev/null)" || return 0
  local id status integ resolved_requeue resolved_merge tmp
  for id in $(jq -r 'keys[]' "$f" 2>/dev/null || true); do
    status="$(printf '%s' "$cur" | jq -r --arg id "$id" '[.stages[] | select(.id == $id)][0].status // "gone"')"
    integ="$(printf '%s' "$cur" | jq -r --arg id "$id" '[.stages[] | select(.id == $id)][0].integration.state // "gone"')"
    case "$status" in completed|superseded|gone) resolved_requeue=true ;; *) resolved_requeue=false ;; esac
    case "$integ" in awaiting) resolved_merge=false ;; *) resolved_merge=true ;; esac
    tmp="$(mktemp)"
    if jq --arg id "$id" --arg k1 "requeue-verifier-failed" --arg k2 "merge-awaiting" \
        --argjson rr "$resolved_requeue" --argjson rm "$resolved_merge" '
        if (.[$id] // {}) == {} then .
        else
          .[$id] |= (
            (if $rr then del(.[$k1]) else . end)
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

# warden_progress_check <repo_root> <stage_id> <remediation> [cap]
# Prints one of: first | retry | escalate. On first/retry it has already
# recorded the attempt; on escalate it has recorded nothing further (the
# caller must not apply the remediation a third time).
warden_progress_check() {
  local repo_root="$1" stage_id="$2" remediation="$3" cap="${4:-2}"
  local f
  f="$(warden_state_file "$repo_root")"
  local prev_count=0
  if [[ -f "$f" ]] && jq empty "$f" >/dev/null 2>&1; then
    prev_count="$(jq -r --arg id "$stage_id" --arg r "$remediation" '.[$id][$r] // 0' "$f" 2>/dev/null || echo 0)"
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
  jq --arg id "$stage_id" --arg r "$remediation" --argjson n "$((prev_count + 1))" \
    '.[$id] = ((.[$id] // {}) + {($r): $n})' "$f" > "$tmp"
  mv "$tmp" "$f"
  if (( prev_count == 0 )); then printf 'first\n'; else printf 'retry\n'; fi
}

# --- Repo selection ----------------------------------------------------------

warden_enabled_repos() {
  local mind_repos
  mind_repos="$(warden_mandate_get '.repos[]' '')"
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

warden_repo_halted() {
  local repo_root="$1"
  local budget_path="$repo_root/state/budget.json"
  [[ -f "$budget_path" ]] || return 1
  [[ "$(jq -r '.halted // false' "$budget_path" 2>/dev/null || echo false)" == "true" ]]
}

# --- Remediation 3: clear a provably stale pause or halt --------------------
#
# Reuses budget_pause_active (self-clears an elapsed pause) and
# budget_ensure_window (self-clears a halt from a previous UTC window)
# rather than re-deriving staleness: those are the audited functions every
# regular tick already calls, and a second implementation of "is this
# stale" would only be able to drift from the first. This remediation exists
# because nothing guarantees a tick has run recently enough to have already
# done it for a given repo.

_warden_clear_stale_for_repo() {
  local repo_root="$1"
  local budget_path="$repo_root/state/budget.json"
  [[ -f "$budget_path" ]] || return 1
  if ! acquire_repo_lock "$repo_root"; then
    return 1
  fi
  local acted=1
  local before_paused before_halted before_window
  before_paused="$(jq -r '.paused_until // empty' "$budget_path" 2>/dev/null || true)"
  before_halted="$(jq -r '.halted // false' "$budget_path" 2>/dev/null || echo false)"
  before_window="$(jq -r '.window_started_at // empty' "$budget_path" 2>/dev/null || true)"

  if [[ -n "$before_paused" ]]; then
    if ! budget_pause_active "$repo_root" >/dev/null 2>&1; then
      local after_paused
      after_paused="$(jq -r '.paused_until // empty' "$budget_path" 2>/dev/null || true)"
      if [[ -z "$after_paused" ]]; then
        log "remediation 3: ${repo_root} stale pause cleared (was until epoch ${before_paused})"
        warden_action_record "$repo_root" "" clear-stale cleared-pause "paused_until ${before_paused} had elapsed"
        acted=0
      fi
    fi
  fi

  if (( acted != 0 )) && [[ "$before_halted" == "true" && "$before_window" != "$(date -u +%F)" ]]; then
    budget_ensure_window "$repo_root"
    local after_halted
    after_halted="$(jq -r '.halted // false' "$budget_path" 2>/dev/null || echo false)"
    if [[ "$after_halted" == "false" ]]; then
      log "remediation 3: ${repo_root} previous-window halt (window_started_at ${before_window}) cleared at the window boundary"
      warden_action_record "$repo_root" "" clear-stale cleared-halt "previous window ${before_window}"
      acted=0
    fi
  fi

  release_repo_lock "$repo_root"
  return "$acted"
}

warden_try_clear_stale() {
  local repo_root
  for repo_root in "$@"; do
    if _warden_clear_stale_for_repo "$repo_root"; then
      return 0
    fi
  done
  return 1
}

# --- Remediation 2: merge a conflict-free awaiting integration -------------

_warden_run_offline_smokes() {
  local repo_root="$1" log_path="$2"
  local smoke rc=0
  for smoke in "$repo_root"/scripts/*-smoke.sh; do
    [[ -x "$smoke" ]] || continue
    # sdk-cache-smoke.sh makes a live Anthropic API call. It is a useful
    # release check, but it is explicitly not an offline smoke and must not
    # turn a deterministic merge remediation into metered spend.
    [[ "$(basename "$smoke")" == "sdk-cache-smoke.sh" ]] && continue
    printf '\n-- %s --\n' "$smoke" >> "$log_path"
    if ! ( cd "$repo_root" && "$smoke" ) >> "$log_path" 2>&1; then
      rc=1
    fi
  done
  return "$rc"
}

# Merge an already-verified run branch into base without moving repo_root's
# HEAD. Fast-forward when possible. An awaiting record normally means base
# moved after dispatch, so the common path is a clean two-parent merge commit
# in the worktree that already has base checked out, or a commit-tree/update-
# ref transaction when base has no worktree. The caller has already proved
# the merge tree is conflict-free and holds the repo lock throughout.
_warden_merge_clean() {
  local repo_root="$1" stage_id="$2" base_branch="$3" run_branch="$4" merge_tree="$5"
  local base_tip run_tip base_dir warden_author_name warden_author_email
  warden_author_name="${WARDEN_GIT_IDENTITY% <*}"
  warden_author_email="${WARDEN_GIT_IDENTITY##*<}"
  warden_author_email="${warden_author_email%>}"
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
      log "remediation 2: ${repo_root} ${stage_id} base worktree ${base_dir} is dirty; surfaced, not touched"
      return 1
    fi
    (
      cd "$base_dir"
      GIT_AUTHOR_NAME="$warden_author_name" GIT_AUTHOR_EMAIL="$warden_author_email" \
        git merge --no-ff --no-edit "$run_branch" >/dev/null 2>&1
    )
    return
  fi

  local merge_commit
  merge_commit="$(
    cd "$repo_root"
    GIT_AUTHOR_NAME="$warden_author_name" \
    GIT_AUTHOR_EMAIL="$warden_author_email" \
      git commit-tree "$merge_tree" -p "$base_tip" -p "$run_tip" \
        -m "${stage_id}: warden integrates ${run_branch} into ${base_branch}"
  )" || return 1
  [[ -n "$merge_commit" ]] || return 1
  git -C "$repo_root" update-ref "refs/heads/${base_branch}" "$merge_commit" "$base_tip"
}

_warden_merge_awaiting_for_repo() {
  local repo_root="$1"
  local state_yaml="$repo_root/state/state.yaml"
  [[ -f "$state_yaml" ]] || return 1
  warden_progress_gc "$repo_root" "$state_yaml"

  local candidate
  candidate="$(state_json "$state_yaml" | jq -c '[.stages[] | select(.integration.state == "awaiting")][0] // empty' 2>/dev/null || true)"
  [[ -n "$candidate" && "$candidate" != "null" ]] || return 1

  local stage_id base_branch run_branch
  stage_id="$(printf '%s' "$candidate" | jq -r '.id')"
  base_branch="$(printf '%s' "$candidate" | jq -r '.integration.base_branch')"
  run_branch="$(printf '%s' "$candidate" | jq -r '.integration.run_branch')"
  [[ -n "$stage_id" && -n "$base_branch" && -n "$run_branch" ]] || return 1

  if ! acquire_repo_lock "$repo_root"; then
    return 1
  fi

  local decision
  decision="$(warden_progress_check "$repo_root" "$stage_id" merge-awaiting \
    "$(warden_mandate_get '.escalation.same_remediation_without_progress_cap' 2)")"
  if [[ "$decision" == "escalate" ]]; then
    escalate "$repo_root" "${stage_id}: merge-awaiting applied twice with no progress"
    release_repo_lock "$repo_root"
    return 0
  fi

  if ! git -C "$repo_root" rev-parse -q --verify "refs/heads/${base_branch}" >/dev/null 2>&1 \
     || ! git -C "$repo_root" rev-parse -q --verify "refs/heads/${run_branch}" >/dev/null 2>&1; then
    log "remediation 2: ${repo_root} ${stage_id} awaiting integration but ${base_branch} or ${run_branch} no longer resolves; surfaced, not touched"
    release_repo_lock "$repo_root"
    return 0
  fi

  local merge_rc=0 merge_tree=""
  merge_tree="$(git -C "$repo_root" merge-tree --write-tree "$base_branch" "$run_branch" 2>/dev/null)" || merge_rc=$?
  if (( merge_rc != 0 )); then
    log "remediation 2: ${repo_root} ${stage_id} ${run_branch} conflicts with ${base_branch}; surfaced, never resolved by the warden"
    release_repo_lock "$repo_root"
    return 0
  fi

  local run_tip
  run_tip="$(git -C "$repo_root" rev-parse -q --verify "refs/heads/${run_branch}" 2>/dev/null || true)"
  if ! _warden_merge_clean "$repo_root" "$stage_id" "$base_branch" "$run_branch" "$merge_tree"; then
    log "remediation 2: ${repo_root} ${stage_id} had a clean merge tree but base could not be advanced safely; surfaced"
    release_repo_lock "$repo_root"
    return 0
  fi

  mkdir -p "$warden_log_dir"
  local smoke_log="$warden_log_dir/warden-${stage_id}-smoke.log"
  : > "$smoke_log"
  local smoke_ok=0
  _warden_run_offline_smokes "$repo_root" "$smoke_log" || smoke_ok=1

  teardown_run_worktree "$repo_root" "$stage_id"
  record_stage_integration "$state_yaml" "$stage_id" \
    "$(integration_record merged "$base_branch" "$run_branch" "$run_tip" "")"
  warden_action_record "$repo_root" "$stage_id" merge-awaiting merged "${run_branch} integrated into ${base_branch}"

  if (( smoke_ok != 0 )); then
    log "remediation 2: ${repo_root} ${stage_id} merged ${run_branch} into ${base_branch}, but the repo's offline smokes failed afterwards (see ${smoke_log}); merge left in place, escalated rather than reverted"
    escalate "$repo_root" "${stage_id}: post-merge offline smokes failed"
    release_repo_lock "$repo_root"
    return 0
  fi

  # Success: drop the progress counter so a later, unrelated recurrence of
  # this stage needing an awaiting-merge starts counting from zero.
  local f
  f="$(warden_state_file "$repo_root")"
  if [[ -f "$f" ]] && jq empty "$f" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    if jq --arg id "$stage_id" 'del(.[$id]["merge-awaiting"])' "$f" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  fi

  local pushed="skipped: git-push-check not on PATH"
  if command -v git-push-check >/dev/null 2>&1; then
    local verdict
    verdict="$(cd "$repo_root" && git-push-check origin "${base_branch}:${base_branch}" 2>&1 | tail -n1 || true)"
    case "$verdict" in
      PUSH*)
        if (cd "$repo_root" && git push origin "$base_branch" >/dev/null 2>&1); then
          pushed="pushed origin/${base_branch}"
        else
          pushed="git-push-check said PUSH but the push failed"
        fi
        ;;
      ASK*|HOLD*)
        pushed="held: git-push-check said ${verdict}"
        ;;
      NOOP*)
        pushed="no push needed: ${verdict}"
        ;;
      *)
        pushed="git-push-check verdict unrecognised (${verdict}), not pushing"
        ;;
    esac
  fi

  local rerender="skipped: no scripts/install-homebrew-local.sh in this repo"
  if [[ -x "$repo_root/scripts/install-homebrew-local.sh" ]]; then
    if ( cd "$repo_root" && ./scripts/install-homebrew-local.sh ) >>"$smoke_log" 2>&1; then
      rerender="installed build re-rendered"
    else
      rerender="install-homebrew-local.sh failed, see ${smoke_log}"
    fi
  fi

  log "remediation 2: ${repo_root} ${stage_id} merged ${run_branch} into ${base_branch}; offline smokes passed; ${pushed}; ${rerender}"
  release_repo_lock "$repo_root"
  return 0
}

warden_try_merge_awaiting() {
  local repo_root
  for repo_root in "$@"; do
    warden_repo_halted "$repo_root" && continue
    if _warden_merge_awaiting_for_repo "$repo_root"; then
      return 0
    fi
  done
  return 1
}

# --- Remediation 1: requeue a verifier_failed stage after triage -----------
#
# The only remediation that dispatches an agent. The agent judges (work
# defect vs card defect vs inconclusive) and writes a structured decision
# envelope; this script performs the actual mutation (append to the card,
# run requeue-stage.sh) based on that envelope, the same separation of
# powers the dispatch contract already uses between worker and orchestrator.

warden_render_triage_prompt() {
  local repo_root="$1" stage_id="$2" card_path="$3" artefact_rel="$4"
  local wip_commit="$5" wip_branch="$6" identity="$7" envelope="$8"
  local voice
  voice="$(warden_mandate_get '.reporting.voice' 'Concise and factual: state what was found, what was done or not done, and why.')"
  sed \
    -e "s|<<triage-identity>>|${identity}|g" \
    -e "s|<<repo-root>>|${repo_root}|g" \
    -e "s|<<stage-id>>|${stage_id}|g" \
    -e "s|<<stage-card-path>>|${card_path}|g" \
    -e "s|<<artefact-path>>|${artefact_rel}|g" \
    -e "s|<<wip-commit-or-none>>|${wip_commit:-none}|g" \
    -e "s|<<wip-branch-or-none>>|${wip_branch:-none}|g" \
    -e "s|<<envelope-path>>|${envelope}|g" \
    -e "s|<<reporting-voice>>|${voice}|g" \
    "$warden_prompt_template"
}

warden_record_triage_spend() {
  local repo_root="$1" stage_id="$2" identity="$3" dispatch_log="$4"
  local started_epoch="$5" wall="$6" result="$7"
  budget_account_tokens_from_dispatch "$repo_root" "$dispatch_log" "warden" "$repo_root" "$started_epoch" || true
  costlog_append "$repo_root" "$stage_id" warden "$identity" "$dispatch_log" "$wall" "$result" \
    "$repo_root" "$started_epoch" || true
}

# Every warden action must be a commit or a state write with the warden's
# own identity attributed -- an appended-but-uncommitted card edit sitting in
# repo_root's working tree would be silent action, which the card
# prohibits. Stages only the one card path (never a broad `git add`) so an
# unrelated dirty file the operator is mid-edit on cannot be swept in. On
# any failure (repo_root checked out on an unexpected branch, a dirty index,
# no git identity resolvable) the append is left on disk and this logs
# loudly rather than losing it or guessing further.
WARDEN_GIT_IDENTITY="Autometta Warden <autometta-warden@local>"

_warden_commit_card_change() {
  local repo_root="$1" card_path="$2" message="$3"
  local rel_path="${card_path#"$repo_root"/}"
  ( cd "$repo_root" && git add -- "$rel_path" && git commit --author="$WARDEN_GIT_IDENTITY" -m "$message" -- "$rel_path" ) >/dev/null 2>&1
}

# warden_apply_triage_decision: the mechanical half. Reads the triage
# envelope and performs exactly the action it names -- requeue on
# work_defect (with the re-brief appended and committed), a
# PROPOSED-AMENDMENT append and commit with nothing requeued on card_defect,
# or nothing at all otherwise. Called directly by scripts/warden-smoke.sh
# with a hand-authored envelope, the same way
# scripts/preserve-failed-work-smoke.sh exercises tick.sh's
# _process_verifier_artefact without a live verifier.
warden_apply_triage_decision() {
  local repo_root="$1" stage_id="$2" card_path="$3" envelope="$4" wip_commit="$5"
  if [[ ! -f "$envelope" ]] || ! jq empty "$envelope" >/dev/null 2>&1; then
    log "remediation 1: ${repo_root} ${stage_id} triage produced no usable envelope at ${envelope}; surfaced, nothing requeued"
    return 0
  fi
  local envelope_stage verdict
  envelope_stage="$(jq -r '.stage_id // empty' "$envelope")"
  if [[ "$envelope_stage" != "$stage_id" ]]; then
    log "remediation 1: ${repo_root} ${stage_id} triage envelope names stage '${envelope_stage}'; surfaced, nothing requeued"
    return 0
  fi
  verdict="$(jq -r '.verdict // "inconclusive"' "$envelope")"
  case "$verdict" in
    work_defect)
      local rebrief
      rebrief="$(jq -r '.rebrief_markdown // empty' "$envelope")"
      if [[ -z "$rebrief" ]]; then
        log "remediation 1: ${repo_root} ${stage_id} triage said work_defect but supplied no re-brief text; surfaced, not requeued"
        return 0
      fi
      if [[ -n "$wip_commit" && "$rebrief" != *"$wip_commit"* ]]; then
        log "remediation 1: ${repo_root} ${stage_id} re-brief does not cite the preserved wip_commit ${wip_commit}; surfaced, not requeued"
        return 0
      fi
      printf '\n%s\n' "$rebrief" >> "$card_path"
      if _warden_commit_card_change "$repo_root" "$card_path" \
          "${stage_id}: warden re-brief citing ${wip_commit}"; then
        log "remediation 1: ${repo_root} ${stage_id} re-brief committed (citing ${wip_commit})"
        warden_action_record "$repo_root" "$stage_id" requeue-verifier-failed rebrief-committed "cited ${wip_commit}"
      else
        log "remediation 1: ${repo_root} ${stage_id} re-brief appended but could not be committed (unexpected branch or dirty tree in repo_root); left uncommitted for manual review"
        return 0
      fi
      if "$script_dir/requeue-stage.sh" "$repo_root" "$stage_id" >>"$warden_log_dir/warden-$(date +%F).log" 2>&1; then
        log "remediation 1: ${repo_root} ${stage_id} requeued"
      else
        log "remediation 1: ${repo_root} ${stage_id} re-brief committed but requeue-stage.sh failed; surfaced"
      fi
      ;;
    card_defect)
      local amendment
      amendment="$(jq -r '.amendment_markdown // empty' "$envelope")"
      if [[ -z "$amendment" || "$amendment" != *PROPOSED-AMENDMENT* ]]; then
        log "remediation 1: ${repo_root} ${stage_id} triage said card_defect but the amendment text is missing or unmarked; surfaced, not requeued"
        return 0
      fi
      printf '\n%s\n' "$amendment" >> "$card_path"
      if _warden_commit_card_change "$repo_root" "$card_path" \
          "${stage_id}: warden PROPOSED-AMENDMENT"; then
        log "remediation 1: ${repo_root} ${stage_id} PROPOSED-AMENDMENT committed; nothing requeued, awaiting the operator or an interactive orchestrator"
        warden_action_record "$repo_root" "$stage_id" requeue-verifier-failed proposed-amendment "card wording requires operator review"
      else
        log "remediation 1: ${repo_root} ${stage_id} PROPOSED-AMENDMENT appended but could not be committed (unexpected branch or dirty tree in repo_root); left uncommitted for manual review. Nothing requeued."
      fi
      ;;
    *)
      log "remediation 1: ${repo_root} ${stage_id} triage verdict '${verdict}': the correct action is none, surfaced as-is"
      ;;
  esac
}

_warden_dispatch_triage() {
  local repo_root="$1" stage_id="$2" card_path="$3" artefact_rel="$4"
  local wip_commit="$5" wip_branch="$6"

  local identity
  identity="$(warden_mandate_get '.dispatch.triage_identity' 'Claude Sonnet 5 <claude-sonnet-5@local>')"
  local family
  family="$(costlog_family_for_identity "$identity")"
  if [[ "$family" != "claude" && "$family" != "codex" ]]; then
    log "remediation 1: ${repo_root} ${stage_id} mandate names an unsupported triage identity (${identity}); surfaced"
    return 0
  fi

  mkdir -p "$repo_root/state/handoffs" "$repo_root/state/logs"
  local envelope="$repo_root/state/handoffs/warden-${stage_id}.json"
  local dispatch_log="$repo_root/state/logs/warden-${stage_id}.log"
  rm -f "$envelope"

  local prompt
  prompt="$(warden_render_triage_prompt "$repo_root" "$stage_id" "$card_path" "$artefact_rel" "$wip_commit" "$wip_branch" "$identity" "$envelope")"

  local autometta_root_local
  autometta_root_local="$(autometta_self_root "$script_dir")"
  if [[ -f "$autometta_root_local/op-refs.sh" ]]; then
    # shellcheck source=/dev/null
    source "$autometta_root_local/op-refs.sh"
  fi
  local auth_pairs auth_mode
  if ! auth_pairs="$(REPO_ROOT="$repo_root" "$script_dir/auth-route.sh" "$family")"; then
    log "remediation 1: ${repo_root} ${stage_id} auth-route resolver failed for ${family}; surfaced"
    return 0
  fi
  if ! auth_mode="$(REPO_ROOT="$repo_root" "$script_dir/auth-route.sh" "$family" --print-mode)"; then
    log "remediation 1: ${repo_root} ${stage_id} auth-route mode could not be resolved; surfaced"
    return 0
  fi

  local metered_routes allow_metered
  metered_routes="$(warden_mandate_get '.escalation.metered_spend.auth_routes[]' 'api')"
  allow_metered="$(warden_mandate_get '.escalation.metered_spend.allow_within_budget' true)"
  if printf '%s\n' "$metered_routes" | grep -qxF "$auth_mode" \
     && [[ "$allow_metered" != "true" ]]; then
    escalate "$repo_root" "${stage_id}: triage auth route ${auth_mode} is classified as metered and the mandate forbids metered dispatch"
    return 0
  fi
  if [[ ! -s "$repo_root/state/budget.json" ]] \
     || ! jq -e '.tokens_spent != null and .wall_clock_elapsed_seconds != null and .clock_ticks_used != null' \
          "$repo_root/state/budget.json" >/dev/null 2>&1; then
    escalate "$repo_root" "${stage_id}: triage dispatch has no usable budget ledger"
    return 0
  fi
  if ! budget_gate_dispatch "$repo_root" "warden triage dispatch for ${stage_id}"; then
    log "ESCALATION: ${stage_id}: warden triage dispatch refused by the budget gate"
    return 0
  fi
  if ! command -v op-fetch >/dev/null 2>&1; then
    log "remediation 1: op-fetch not on PATH, required for the auth-route wrapper; surfaced"
    return 0
  fi

  local effort
  effort="$(warden_mandate_get '.dispatch.triage_effort' high)"
  effort_argv_for_family "$family" "$effort"
  codex_state_argv_for_repo "$repo_root"

  local codex_home_override=""
  if [[ "$family" == "codex" && "$auth_mode" == "api" ]]; then
    codex_home_override="${AUTOMETTA_CODEX_HOME:-$HOME/.codex-api-only}"
    if [[ ! -f "$codex_home_override/auth.json" ]]; then
      log "remediation 1: ${repo_root} ${stage_id} codex api triage requires a sibling CODEX_HOME with auth_mode apikey; surfaced"
      return 0
    fi
  fi

  local started_epoch timeout_seconds
  started_epoch="$(date -u +%s)"
  timeout_seconds="$(warden_mandate_get '.dispatch.triage_timeout_seconds' 600)"
  [[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -gt 0 ]] || timeout_seconds=600

  # The pass waits for this one child, while a portable watchdog enforces the
  # bound on macOS without depending on a GNU `timeout` binary.
  local dispatch_pid
  case "$family" in
    claude)
      # shellcheck disable=SC2086
      ( cd "$repo_root" && op-fetch $auth_pairs -- claude --model "$(claude_model_for_identity "$identity")" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --dangerously-skip-permissions --output-format json -p "$prompt" </dev/null 2>"$dispatch_log" | "$script_dir/claude-token-log.sh" >>"$dispatch_log" ) 2>>"$dispatch_log" &
      dispatch_pid=$!
      ;;
    codex)
      if [[ "$auth_mode" == "local" ]]; then
        if ! codex_local_preflight "$AUTOMETTA_MODEL_CODEX_LOCAL"; then
          log "remediation 1: ${repo_root} ${stage_id} local codex pre-flight failed; surfaced"
          return 0
        fi
        # shellcheck disable=SC2086
        op-fetch $auth_pairs -- codex exec --oss --local-provider=ollama -m "$AUTOMETTA_MODEL_CODEX_LOCAL" -C "$repo_root" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --sandbox workspace-write ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$prompt" </dev/null >"$dispatch_log" 2>&1 &
      elif [[ -n "$codex_home_override" ]]; then
        # shellcheck disable=SC2086
        CODEX_HOME="$codex_home_override" op-fetch $auth_pairs --pass CODEX_HOME -- codex exec -C "$repo_root" --model "$AUTOMETTA_MODEL_CODEX" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --sandbox workspace-write ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$prompt" </dev/null >"$dispatch_log" 2>&1 &
      else
        # shellcheck disable=SC2086
        op-fetch $auth_pairs -- codex exec -C "$repo_root" --model "$AUTOMETTA_MODEL_CODEX" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --sandbox workspace-write ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$prompt" </dev/null >"$dispatch_log" 2>&1 &
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
      log "remediation 1: ${repo_root} ${stage_id} triage exceeded ${timeout_seconds}s and was stopped"
      break
    fi
    sleep 1
  done
  wait "$dispatch_pid" 2>/dev/null || true

  local wall=$(( $(date -u +%s) - started_epoch ))
  # Charge the same budget ledger the worker and verifier use before making
  # any decision based on the result. Cost logging is itemisation; it is not
  # a substitute for advancing the hard-stop counters.
  local result="aborted"
  [[ -f "$envelope" ]] && result="pass"
  warden_record_triage_spend "$repo_root" "$stage_id" "$identity" "$dispatch_log" "$started_epoch" "$wall" "$result"

  local payment_pattern
  payment_pattern="$(warden_mandate_get '.escalation.metered_spend.unexpected_provider_signal_pattern' '402[[:space:]]+Payment Required|payment required|billing required|insufficient (credit|credits|funds)|purchase credits|add (funds|credits)')"
  if [[ -n "$payment_pattern" ]] && grep -Eiq "$payment_pattern" "$dispatch_log" 2>/dev/null; then
    escalate "$repo_root" "${stage_id}: provider signalled unexpected payment during warden triage"
    return 0
  fi

  warden_apply_triage_decision "$repo_root" "$stage_id" "$card_path" "$envelope" "$wip_commit"
}

_warden_requeue_verifier_failed_for_repo() {
  local repo_root="$1"
  local state_yaml="$repo_root/state/state.yaml"
  [[ -f "$state_yaml" ]] || return 1
  warden_progress_gc "$repo_root" "$state_yaml"

  local candidate
  candidate="$(state_json "$state_yaml" | jq -c --arg target verifier_failed \
    '[.stages[] | select(.status == $target)][0] // empty' 2>/dev/null || true)"
  [[ -n "$candidate" && "$candidate" != "null" ]] || return 1

  local stage_id verifier_artefact verifier_attempts wip_commit wip_branch
  stage_id="$(printf '%s' "$candidate" | jq -r '.id')"
  verifier_artefact="$(printf '%s' "$candidate" | jq -r '.verifier_artefact // ("state/verifiers/" + .id + ".json")')"
  verifier_attempts="$(printf '%s' "$candidate" | jq -r '.verifier_attempts // 0')"
  wip_commit="$(printf '%s' "$candidate" | jq -r '.wip_commit // ""')"
  wip_branch="$(printf '%s' "$candidate" | jq -r '.wip_branch // ""')"
  [[ -n "$stage_id" ]] || return 1

  if ! acquire_repo_lock "$repo_root"; then
    return 1
  fi

  local attempt_cap
  attempt_cap="$(warden_mandate_get '.escalation.attempt_cap' 3)"
  if [[ "$verifier_attempts" =~ ^[0-9]+$ ]] && (( verifier_attempts >= attempt_cap )); then
    escalate "$repo_root" "${stage_id}: verifier_attempts ${verifier_attempts} at or above the mandate's attempt cap (${attempt_cap})"
    release_repo_lock "$repo_root"
    return 0
  fi

  local decision
  decision="$(warden_progress_check "$repo_root" "$stage_id" requeue-verifier-failed \
    "$(warden_mandate_get '.escalation.same_remediation_without_progress_cap' 2)")"
  if [[ "$decision" == "escalate" ]]; then
    escalate "$repo_root" "${stage_id}: requeue-verifier-failed applied twice with no progress"
    release_repo_lock "$repo_root"
    return 0
  fi

  if [[ "$(warden_mandate_get '.escalation.triage_dispatch_enabled' true)" != "true" ]]; then
    log "remediation 1: ${repo_root} ${stage_id} triage dispatch disabled by the mandate; surfaced, not touched"
    release_repo_lock "$repo_root"
    return 0
  fi

  if [[ -z "$wip_commit" ]] \
     || ! git -C "$repo_root" cat-file -e "${wip_commit}^{commit}" 2>/dev/null; then
    log "remediation 1: ${repo_root} ${stage_id} has no resolvable preserved wip_commit; surfaced, not triaged or requeued"
    release_repo_lock "$repo_root"
    return 0
  fi
  if [[ ! -f "$repo_root/$verifier_artefact" ]]; then
    log "remediation 1: ${repo_root} ${stage_id} verifier artefact missing at ${verifier_artefact}; surfaced, not triaged or requeued"
    release_repo_lock "$repo_root"
    return 0
  fi

  local blown
  blown="$(budget_spend_caps_blown "$repo_root")"
  if [[ -n "$blown" ]]; then
    escalate "$repo_root" "${stage_id}: triage dispatch skipped, spend caps exhausted (${blown})"
    release_repo_lock "$repo_root"
    return 0
  fi

  local card_path
  card_path="$(stage_card_for_id "$repo_root" "$stage_id" "")"
  if [[ -z "$card_path" ]]; then
    log "remediation 1: ${repo_root} ${stage_id} verifier_failed but no card resolves; surfaced, not touched"
    release_repo_lock "$repo_root"
    return 0
  fi

  # Release the lock before the (potentially minutes-long) agent dispatch --
  # holding a repo lock across an LLM call would starve a live tick for the
  # duration. warden_apply_triage_decision re-reads state.yaml fresh and
  # requeue-stage.sh takes no lock of its own, matching how a manual
  # orchestrator re-queue already works without tick's lock held.
  release_repo_lock "$repo_root"
  _warden_dispatch_triage "$repo_root" "$stage_id" "$card_path" "$verifier_artefact" "$wip_commit" "$wip_branch"
  return 0
}

warden_try_requeue_verifier_failed() {
  local repo_root
  for repo_root in "$@"; do
    warden_repo_halted "$repo_root" && continue
    if _warden_requeue_verifier_failed_for_repo "$repo_root"; then
      return 0
    fi
  done
  return 1
}

# --- Remediation 4: queue the next gated card when the queue is empty ------

warden_find_plan() {
  local repo_root="$1" candidate
  for candidate in "$repo_root/stage-cards/PLAN.md" "$repo_root/examples/self-host/PLAN.md" "$repo_root/docs/stages/PLAN.md"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# warden_gate_ref_satisfied: a gate reference (e.g. "46" from "blocked by
# 46") is satisfied when either PLAN.md's own table row for that stage
# number is marked done (authoritative for historical cards never dispatched
# through state.yaml) or state.yaml records it completed (for cards the loop
# itself ran). Never guesses from prose beyond that.
warden_gate_ref_satisfied() {
  local plan_path="$1" state_yaml="$2" ref="$3"
  local plan_line status
  plan_line="$(grep -E "^\| ${ref} \|" "$plan_path" 2>/dev/null | head -n1 || true)"
  if [[ -n "$plan_line" ]]; then
    status="$(printf '%s' "$plan_line" | awk -F'|' '{print $4}' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ "$status" == done* ]] && return 0
  fi
  local st
  st="$(state_json "$state_yaml" 2>/dev/null | jq -r --arg id "$ref" \
    '[.stages[] | select(.id == $id or (.id | startswith($id + "-")))][0].status // ""' 2>/dev/null || true)"
  [[ "$st" == "completed" ]]
}

_warden_queue_next_card_for_repo() {
  local repo_root="$1"
  local state_yaml="$repo_root/state/state.yaml"
  [[ -f "$state_yaml" ]] || return 1

  local pending_count
  pending_count="$(state_json "$state_yaml" | jq -r '[.stages[] | select(.status == "pending" or .status == "in_progress")] | length' 2>/dev/null || echo -1)"
  [[ "$pending_count" == "0" ]] || return 1

  local plan_path
  plan_path="$(warden_find_plan "$repo_root")" || return 1

  local line stage_id status_cell
  while IFS= read -r line; do
    case "$line" in
      '|'*'|'*'|'*) ;;
      *) continue ;;
    esac
    status_cell="$(printf '%s' "$line" | awk -F'|' '{print $4}' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    case "$status_cell" in
      queued*) ;;
      *) continue ;;
    esac
    stage_id="$(printf '%s' "$line" | grep -oE '\(\./[0-9]{2}[a-z]*-[a-z0-9-]+\.md\)' | head -n1 | sed -E 's/^\(\.\///; s/\.md\)$//')"
    [[ -n "$stage_id" ]] || continue

    local exists
    exists="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" '[.stages[] | select(.id == $id)] | length' 2>/dev/null || echo 1)"
    [[ "$exists" == "0" ]] || continue

    local gate_refs
    gate_refs="$(printf '%s' "$status_cell" | grep -oE '(blocked by|gated on|after)[^;]*' | grep -oE '[0-9]+[a-z]?' || true)"
    local unmet="" ref
    for ref in $gate_refs; do
      if ! warden_gate_ref_satisfied "$plan_path" "$state_yaml" "$ref"; then
        unmet="${unmet}${ref} "
      fi
    done
    if [[ -n "$unmet" ]]; then
      log "remediation 4: ${repo_root} skipped ${stage_id}, gate unmet (waiting on ${unmet% })"
      continue
    fi

    local card_path
    card_path="$(dirname "$plan_path")/${stage_id}.md"
    if [[ ! -f "$card_path" ]]; then
      log "remediation 4: ${repo_root} ${stage_id} named in the plan but no card file at ${card_path}; surfaced"
      return 1
    fi

    if ! acquire_repo_lock "$repo_root"; then
      return 1
    fi
    if "$script_dir/add-stage.sh" "$repo_root" "$card_path" >>"$warden_log_dir/warden-$(date +%F).log" 2>&1; then
      log "remediation 4: ${repo_root} queued ${stage_id} (gate satisfied, queue was empty)"
      warden_action_record "$repo_root" "$stage_id" queue-next-card queued "gate satisfied and queue was empty"
    else
      log "remediation 4: ${repo_root} add-stage.sh failed for ${stage_id}; surfaced"
    fi
    release_repo_lock "$repo_root"
    return 0
  done < "$plan_path"

  return 1
}

warden_try_queue_next_card() {
  local repo_root
  for repo_root in "$@"; do
    warden_repo_halted "$repo_root" && continue
    if _warden_queue_next_card_for_repo "$repo_root"; then
      return 0
    fi
  done
  return 1
}

# --- One pass ----------------------------------------------------------------

warden_pass() {
  for tool in yq jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log "warden: ${tool} is required but missing, aborting pass"
      return 1
    fi
  done
  warden_mandate_ensure || return 1

  local -a repos=()
  local repo_root
  while IFS= read -r repo_root; do
    [[ -n "$repo_root" ]] || continue
    repos+=( "$repo_root" )
  done < <(warden_enabled_repos)

  if [[ ${#repos[@]} -eq 0 ]]; then
    log "warden: no repos to mind (subscriber registry empty, or the mandate's repos list excludes all of them)"
    return 0
  fi

  # Priority order, hard-coded (constraint: one remediation per pass, and
  # the order is not a mandate knob). Unblocking dispatch (3) comes first:
  # every other remediation on a paused or stale-halted repo would be
  # wasted work. Landing finished work (2) comes next, the cheapest,
  # already-verified win. Triage (1) is third among the four because it is
  # the only one that spends tokens. Queueing fresh work (4) only matters
  # once a repo's queue is confirmed empty, which is naturally last to
  # check.
  if warden_try_clear_stale "${repos[@]}"; then return 0; fi
  if warden_try_merge_awaiting "${repos[@]}"; then return 0; fi
  if warden_try_requeue_verifier_failed "${repos[@]}"; then return 0; fi
  if warden_try_queue_next_card "${repos[@]}"; then return 0; fi

  log "warden: quiet pass, nothing to do"
  return 0
}

usage() {
  cat <<'USAGE'
Usage: warden.sh [--print-mandate]

One phat-controller pass: triage the queue across every enabled subscriber
and perform at most one of four enumerated remediations (requeue a
verifier_failed stage after triage; merge a conflict-free awaiting
integration; clear a provably stale pause or halt; queue the next gated
PLAN.md card when the queue is empty). See docs/phat-controller.md
"The warden role".
USAGE
}

main() {
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
    --print-mandate)
      warden_mandate_ensure
      cat "$warden_mandate_path"
      exit 0
      ;;
    "")
      warden_pass
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

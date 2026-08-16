#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"
# shellcheck source=./cost-log.sh
source "$script_dir/cost-log.sh"
# shellcheck source=./usage-limit.sh
source "$script_dir/usage-limit.sh"

controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
subscribers_dir="$controller_home/subscribers"
controller_log_dir="$controller_home/log"

log() {
  local msg="$1"
  mkdir -p "$controller_log_dir"
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$msg" | tee -a "$controller_log_dir/tick-$(date +%F).log" >&2
}

# Per-repo advisory lock. mkdir is atomic on POSIX and works on macOS
# without a flock binary. The lock holder records its PID; a stale lock
# from a crashed tick is detected by kill -0.
acquire_repo_lock() {
  local repo_root="$1"
  local lock_dir="$repo_root/state/.tick.lock"
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock_dir/pid"
    return 0
  fi
  local lock_pid=""
  if [[ -f "$lock_dir/pid" ]]; then
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  fi
  if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
    log "stale tick lock for ${repo_root} (pid ${lock_pid} not running), reclaiming"
    rm -rf "$lock_dir"
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock_dir/pid"
      return 0
    fi
  fi
  return 1
}

release_repo_lock() {
  local repo_root="$1"
  rm -rf "$repo_root/state/.tick.lock"
}

# repair_mode: the unattended, every-subscriber form of requeue-stage.sh.
#
# Every stage sitting in stalled or failed is an infrastructure casualty --
# an agent that died, an envelope that never arrived, a worktree the sandbox
# refused to write. Repair puts them back in the queue. It does not touch
# in_progress (a live worker owns it) or verifier_failed (that is a verdict,
# not a casualty, and re-running it without re-briefing the card just buys
# the same FAIL again).
#
# The per-stage mechanics are requeue-stage.sh's, called rather than copied:
# a stage reset has to remove the run worktree and branch, kill any live
# agent, purge the stale handoff and verifier artefacts, and refuse to
# unlatch a halt whose spend cap is still blown. Two implementations of that
# would drift, and the drift would only show up as a tick dispatching a
# verifier at unfixed code.
#
# repair_attempts caps the loop at PHAT_CONTROLLER_REPAIR_ATTEMPT_CAP
# (default 2). A stage that stalls twice after repair is not an
# infrastructure casualty; it stays down for a human, and the field is the
# audit trail that says how many goes it had.
repair_mode() {
  if ! command -v yq >/dev/null 2>&1; then
    log "repair: yq is required but missing, aborting"
    exit 1
  fi

  local attempt_cap="${PHAT_CONTROLLER_REPAIR_ATTEMPT_CAP:-2}"
  local requeue_script="$script_dir/requeue-stage.sh"
  if [[ ! -x "$requeue_script" ]]; then
    log "repair: ${requeue_script} missing or not executable, aborting"
    exit 1
  fi

  local subscriber_file
  local total_requeued=0 total_card_missing=0 total_capped=0 total_blocked=0
  while IFS= read -r subscriber_file; do
    [[ -n "$subscriber_file" ]] || continue
    local enabled repo_path manifest_path
    enabled="$(read_subscriber_field "$subscriber_file" "enabled")"
    repo_path="$(read_subscriber_field "$subscriber_file" "repo_path")"
    manifest_path="$(read_subscriber_field "$subscriber_file" "manifest_path")"
    if [[ "$enabled" != "true" ]]; then
      continue
    fi
    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
      log "repair: invalid repo_path in ${subscriber_file}"
      continue
    fi

    local state_yaml="$repo_path/state/state.yaml"
    if [[ ! -s "$state_yaml" ]] || ! state_json "$state_yaml" >/dev/null 2>&1; then
      log "repair: state.yaml missing or unreadable for ${repo_path}, skipping"
      continue
    fi

    # A repo over a spend cap can requeue but cannot dispatch, so repairing
    # it spends repair attempts against a wall. Ask once, before touching any
    # stage, rather than discovering it partway through and leaving half the
    # queue reset. requeue-stage.sh refuses on the same predicate.
    local blown=""
    if [[ -f "$repo_path/state/budget.json" ]]; then
      blown="$(budget_spend_caps_blown "$repo_path")"
    fi
    if [[ -n "$blown" ]]; then
      log "repair: ${repo_path} skipped, spend caps still exhausted (${blown}); the next UTC window resets the counters, or raise the cap deliberately"
      total_blocked=$((total_blocked + 1))
      continue
    fi

    # Take the same lock a tick takes. Requeueing a stage under a running
    # tick would race its state writes and could remove a run worktree out
    # from under a worker the tick has just spawned.
    if ! acquire_repo_lock "$repo_path"; then
      log "repair: ${repo_path} is locked by a running tick, skipping"
      continue
    fi

    # Snapshot the candidates before mutating anything: requeue-stage.sh
    # rewrites the whole state file, so repairing one stage must not change
    # which other stages this pass considers.
    local candidates
    candidates="$(state_json "$state_yaml" | jq -r \
      '.stages[] | select(.status == "stalled" or .status == "failed")
       | [.id, .status, (.repair_attempts // 0)] | @tsv')"

    local stage_id status repair_attempts
    while IFS=$'\t' read -r stage_id status repair_attempts; do
      [[ -n "$stage_id" ]] || continue
      [[ "$repair_attempts" =~ ^[0-9]+$ ]] || repair_attempts=0

      if (( repair_attempts >= attempt_cap )); then
        log "repair: ${repo_path} ${stage_id} at repair cap (${repair_attempts}/${attempt_cap}), staying ${status}"
        total_capped=$((total_capped + 1))
        continue
      fi

      # Never requeue cardless work. Without a card the next dispatch has no
      # prompt, so the stage would stall again immediately and burn one of
      # its remaining attempts doing it.
      local card_path
      card_path="$(stage_card_for_id "$repo_path" "$stage_id" "$manifest_path")"
      if [[ -z "$card_path" ]]; then
        state_apply_json "$state_yaml" \
          '(.stages[] | select(.id == $id)).stall_marker = "card_missing"' \
          --arg id "$stage_id"
        log "repair: ${repo_path} ${stage_id} stage card no longer resolves; marked card_missing, not requeued"
        total_card_missing=$((total_card_missing + 1))
        continue
      fi

      local rq_rc=0
      "$requeue_script" "$repo_path" "$stage_id" >/dev/null 2>&1 || rq_rc=$?
      case "$rq_rc" in
        0)
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).repair_attempts =
               (((.stages[] | select(.id == $id) | .repair_attempts) // 0) + 1)' \
            --arg id "$stage_id"
          log "repair: ${repo_path} ${stage_id} requeued ${status} -> pending (repair_attempts now $((repair_attempts + 1)))"
          total_requeued=$((total_requeued + 1))
          ;;
        3)
          # A cap was blown between the precheck above and this call. The
          # stage is reset but its halt stands, so stop here rather than
          # resetting the rest of the queue behind the same wall.
          log "repair: ${repo_path} went over a spend cap mid-pass at ${stage_id}; stopping repair for this repo"
          total_blocked=$((total_blocked + 1))
          break
          ;;
        *)
          log "repair: ${repo_path} ${stage_id} requeue failed (exit ${rq_rc}), left ${status}"
          total_blocked=$((total_blocked + 1))
          ;;
      esac
    done <<< "$candidates"

    release_repo_lock "$repo_path"
  done < <(sort_subscribers)

  log "repair summary: requeued=${total_requeued} card_missing=${total_card_missing} capped=${total_capped} blocked=${total_blocked}"
  exit 0
}

reset_halts_mode() {
  local subscriber_file
  while IFS= read -r subscriber_file; do
    [[ -n "$subscriber_file" ]] || continue
    local enabled repo_path budget_path
    enabled="$(read_subscriber_field "$subscriber_file" "enabled")"
    repo_path="$(read_subscriber_field "$subscriber_file" "repo_path")"
    if [[ "$enabled" != "true" ]]; then
      continue
    fi
    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
      log "invalid repo_path in ${subscriber_file}"
      continue
    fi
    budget_path="$repo_path/state/budget.json"
    if [[ ! -f "$budget_path" ]]; then
      log "budget file missing for ${repo_path}, skipping reset"
      continue
    fi
    budget_write_atomic "$repo_path" '.halted = false | .halt_reason = null | .halted_at = null'
    log "reset halt state for ${repo_path}"
  done < <(sort_subscribers)
  exit 0
}

read_subscriber_field() {
  local file_path="$1"
  local key="$2"
  local raw
  raw="$(sed -n "s/^${key}:[[:space:]]*//p" "$file_path" | head -n1)"
  # Strip surrounding double or single quotes if present. subscribe-repo.sh
  # writes quoted strings; the template uses unquoted form. Accept both.
  raw="${raw%\"}"
  raw="${raw#\"}"
  raw="${raw%\'}"
  raw="${raw#\'}"
  printf '%s' "$raw"
}

sort_subscribers() {
  for file in "$subscribers_dir"/*.yaml; do
    [[ -e "$file" ]] || continue
    # Skip the example template; only real subscribers are processed.
    [[ "$(basename "$file")" == "template.yaml" ]] && continue
    local weight
    weight="$(read_subscriber_field "$file" "weight")"
    printf '%s\t%s\n' "${weight:-9999}" "$file"
  done | sort -n | cut -f2-
}

manifest_patterns() {
  local repo_root="$1"
  local manifest_path="$2"
  if [[ -n "$manifest_path" && -f "$manifest_path" ]]; then
    yq -r '.stage_card_globs[]? // empty' "$manifest_path" 2>/dev/null || true
  elif [[ -f "$repo_root/.autometta.local.yaml" ]]; then
    yq -r '.stage_card_globs[]? // empty' "$repo_root/.autometta.local.yaml" 2>/dev/null || true
  fi
  printf '%s\n' 'docs/stages/*.md'
  printf '%s\n' 'examples/self-host/*.md'
}

stage_card_for_id() {
  local repo_root="$1"
  local stage_id="$2"
  local manifest_path="${3:-}"
  local card=""
  local pattern search_path candidate
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if [[ "$pattern" = /* ]]; then
      search_path="$pattern"
    else
      search_path="$repo_root/$pattern"
    fi
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      if [[ "$(basename "$candidate" .md)" == "$stage_id" ]]; then
        card="$candidate"
        break 2
      fi
    done < <(compgen -G "$search_path" || true)
  done < <(manifest_patterns "$repo_root" "$manifest_path")

  if [[ -z "$card" ]]; then
    for candidate in "$repo_root/docs/stages/${stage_id}.md" "$repo_root/docs/stages"/*"${stage_id}"*.md "$repo_root/examples/self-host/${stage_id}.md" "$repo_root/examples/self-host"/*"${stage_id}"*.md; do
      if [[ -f "$candidate" ]]; then
        card="$candidate"
        break
      fi
    done
  fi
  printf '%s\n' "$card"
}

state_json() {
  local state_yaml="$1"
  yq -o=json '.' "$state_yaml"
}

ensure_yq_or_halt() {
  local repo_root="$1"
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi
  log "yq is required but missing, halting tick for ${repo_root}"
  budget_halt "$repo_root" "yq-missing"
  return 1
}

worker_budget_seconds_from_card() {
  local card_path="$1"
  local budget_line value unit
  budget_line="$(grep -A5 '^## Budget' "$card_path" | grep -E 'Worker wall-clock' | head -n1 || true)"
  # NB: bash 3.2 (macOS default) does not support \b in [[ =~ ]] regex.
  # Anchor units with an explicit "followed by non-letter or end" group instead.
  if [[ "$budget_line" =~ ([0-9]+)[[:space:]]*(seconds?|secs?|s)([^[:alpha:]]|$) ]]; then
    value="${BASH_REMATCH[1]}"
    printf '%s\n' "$value"
    return 0
  fi
  if [[ "$budget_line" =~ ([0-9]+)[[:space:]]*(minutes?|mins?|m)([^[:alpha:]]|$) ]]; then
    value="${BASH_REMATCH[1]}"
    printf '%s\n' "$((value * 60))"
    return 0
  fi
  log "warning: could not parse worker wall-clock budget from ${card_path}, defaulting to 600 seconds"
  printf '600\n'
}

stage_started_epoch() {
  local started_at="$1"
  python3 - "$started_at" <<'PY'
import datetime
import sys

value = sys.argv[1]
if not value or value == "null":
    raise SystemExit(1)
dt = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
print(int(dt.timestamp()))
PY
}

# A dead dispatch with no completion artefact is a configuration fault only
# when the remaining evidence agrees: it ended almost immediately, produced a
# tiny log, and that log contains a CLI usage, executable, or auth-route error.
# Keeping this conjunction narrow means an ordinary verifier crash still uses
# the existing bounded retry path.
is_instant_dispatch_configuration_fault() {
  local log_path="$1"
  local started_at="$2"
  local completion_path="$3"

  [[ ! -e "$completion_path" && -f "$log_path" ]] || return 1

  local log_size
  log_size="$(wc -c < "$log_path" 2>/dev/null | tr -d '[:space:]')"
  [[ "$log_size" =~ ^[0-9]+$ ]] || return 1
  (( log_size > 0 && log_size <= 512 )) || return 1

  local started_epoch log_epoch elapsed
  if [[ "$started_at" =~ ^[0-9]+$ ]]; then
    started_epoch="$started_at"
  else
    started_epoch="$(stage_started_epoch "$started_at" 2>/dev/null || true)"
  fi
  [[ "$started_epoch" =~ ^[0-9]+$ ]] || return 1
  if ! log_epoch="$(stat -f '%m' "$log_path" 2>/dev/null)"; then
    log_epoch="$(stat -c '%Y' "$log_path" 2>/dev/null || true)"
  fi
  [[ "$log_epoch" =~ ^[0-9]+$ ]] || return 1
  elapsed=$((log_epoch - started_epoch))
  (( elapsed >= 0 && elapsed <= 2 )) || return 1

  grep -Eiq \
    "unknown (option|argument)|unrecognized (option|argument)|unexpected argument|invalid (option|argument)|^usage:|command not found|no such file or directory|not logged in|auth-route resolver failed|op-fetch not on path|requires .*auth_mode" \
    "$log_path"
}

halt_dispatch_configuration_fault() {
  local repo_root="$1"
  local stage_id="$2"
  local role="$3"
  local state_yaml="$repo_root/state/state.yaml"

  if [[ "$role" == "verifier" ]]; then
    # Attempts are reserved immediately before spawn. Return this one because
    # argument parsing failed before verification began.
    state_apply_json "$state_yaml" \
      '(.stages[] | select(.id == $id)).verifier_attempts = ([((.stages[] | select(.id == $id) | .verifier_attempts // 0) - 1), 0] | max)
       | (.stages[] | select(.id == $id)).verifier_pid = null
       | (.stages[] | select(.id == $id)).status = "stalled"
       | (.stages[] | select(.id == $id)).stall_marker = ("dispatch_configuration_fault:" + $role)
       | .current_stage = null' \
      --arg id "$stage_id" --arg role "$role"
  else
    state_apply_json "$state_yaml" \
      '(.stages[] | select(.id == $id)).worker_pid = null
       | (.stages[] | select(.id == $id)).status = "stalled"
       | (.stages[] | select(.id == $id)).stall_marker = ("dispatch_configuration_fault:" + $role)
       | .current_stage = null' \
      --arg id "$stage_id" --arg role "$role"
  fi
  budget_halt "$repo_root" "dispatch-configuration-fault"
}

# Apply a jq filter to state.yaml. Pass values via --arg / --argjson rather
# than string interpolation: a stage id with a quote or backslash would
# otherwise break the filter (or worse). Trailing args are forwarded to jq.
state_apply_json() {
  local state_yaml="$1"
  local jq_filter="$2"
  shift 2
  local cur_json tmp_json tmp_yaml
  cur_json="$(mktemp)"
  tmp_json="$(mktemp)"
  tmp_yaml="$(mktemp)"

  # Read guard: refuse to derive a new state from an unreadable or empty
  # current state. An empty read would otherwise cascade through jq into an
  # empty write, destroying the (gitignored, un-backed-up) state file.
  if ! state_json "$state_yaml" > "$cur_json" 2>/dev/null || [[ ! -s "$cur_json" ]]; then
    log "state_apply_json: current state ${state_yaml} unreadable or empty; refusing to mutate"
    rm -f "$cur_json" "$tmp_json" "$tmp_yaml"
    return 1
  fi

  jq "$@" "$jq_filter" "$cur_json" > "$tmp_json"

  # Write guard: the result must be non-empty, valid JSON, and still an
  # object carrying a .stages array. Never let a degenerate document
  # (e.g. {"stages":[]} or null) overwrite good state.
  if [[ ! -s "$tmp_json" ]] || ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d, dict) and isinstance(d.get("stages"), list) else 1)' "$tmp_json" 2>/dev/null; then
    log "state_apply_json: refusing to write degenerate state to ${state_yaml} (filter: ${jq_filter})"
    rm -f "$cur_json" "$tmp_json" "$tmp_yaml"
    return 1
  fi

  # state.yaml is gitignored and the state branch cannot persist it, so this
  # rolling backup is its only recovery point. Snapshot the prior good copy
  # before replacing it.
  cp -p "$state_yaml" "${state_yaml}.bak" 2>/dev/null || true

  yq -P '.' "$tmp_json" > "$tmp_yaml"
  mv "$tmp_yaml" "$state_yaml"
  rm -f "$cur_json" "$tmp_json"
}

# stage_snapshot_tokens: parse a worker/verifier log for its token count
# and snapshot it onto the matching stage entry in state.yaml. Sets one of
# worker_tokens / verifier_tokens (per $4) and recomputes .tokens as the
# sum of the two (treating absent halves as 0). Non-fatal: missing log,
# missing match, or non-numeric parse all silently no-op so the tick loop
# never aborts on accounting noise.
#
# Args: repo_root, state_yaml, stage_id, log_path, role (worker|verifier)
# role_started_epoch: epoch seconds at which a stage role was dispatched, or
# 0 when unknown. Scopes transcript token accounting to this dispatch.
role_started_epoch() {
  local state_yaml="$1"
  local stage_id="$2"
  local role="$3"
  local field started epoch
  case "$role" in
    worker) field="started_at" ;;
    verifier) field="verifier_started_at" ;;
    *) printf '0\n'; return 0 ;;
  esac
  started="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" --arg f "$field" \
    '.stages[] | select(.id == $id) | .[$f] // empty')"
  if [[ -n "$started" ]] && epoch="$(stage_started_epoch "$started" 2>/dev/null)"; then
    printf '%s\n' "$epoch"
  else
    printf '0\n'
  fi
}

# handle_limit_refusal: if a dead role's log is a provider limit refusal,
# park the loop and report success (0); otherwise report 1 and let the caller
# treat the death normally.
#
# A refusal means the work was never attempted: the CLI printed one line and
# exited clean, having burned no tokens. Counting that as a stage failure is
# what turned an exhausted window into two stalled stages and a halted fleet
# on 2026-08-16. So this records no failure, consumes no attempt, leaves the
# stage status and its run worktree exactly as they were, and only sets a
# pause. The stage is re-dispatched untouched after the reset.
#
# Backs off one hour when the refusal carries no parseable reset time.
handle_limit_refusal() {
  local repo_root="$1"
  local stage_id="$2"
  local role="$3"
  local log_path="$4"
  local hit reset_epoch
  hit="$(usage_limit_hit "$log_path")" || return 1
  reset_epoch="$(usage_limit_reset_epoch "$hit")"
  if [[ -z "$reset_epoch" || ! "$reset_epoch" =~ ^[0-9]+$ ]]; then
    reset_epoch=$(( $(date -u +%s) + 3600 ))
  fi
  budget_pause_until "$repo_root" "$reset_epoch" "$hit"
  log "stage ${stage_id} ${role} was refused by the provider, not failed: ${hit}"
  log "  stage left untouched; dispatch paused until $(date -r "$reset_epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$reset_epoch")"
  return 0
}

stage_snapshot_tokens() {
  local repo_root="$1"
  local state_yaml="$2"
  local stage_id="$3"
  local log_path="$4"
  local role="$5"
  local work_dir="${6:-}"
  local since_epoch="${7:-0}"
  local tokens=""
  # Prefer the transcript for the same reason budget_account_tokens_from_dispatch
  # does: a role killed at the dispatch timeout never writes its usage to the log.
  if [[ -n "$work_dir" ]]; then
    local triple t_in t_cached t_out
    triple="$(budget_parse_tokens_from_transcript "$work_dir" "$since_epoch")"
    if [[ -n "$triple" ]]; then
      IFS=' ' read -r t_in t_cached t_out <<<"$triple"
      tokens=$(( t_in + t_cached + t_out ))
    fi
  fi
  if [[ -z "$tokens" ]]; then
    if [[ ! -f "$log_path" ]]; then
      return 0
    fi
    tokens="$(budget_parse_tokens_from_log "$log_path")"
  fi
  if [[ -z "$tokens" || ! "$tokens" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  local field
  case "$role" in
    worker) field="worker_tokens" ;;
    verifier) field="verifier_tokens" ;;
    *) return 0 ;;
  esac
  state_apply_json "$state_yaml" \
    '(.stages[] | select(.id == $id))[$field] = ($tokens | tonumber)
     | (.stages[] | select(.id == $id)).tokens
       = (((.stages[] | select(.id == $id)).worker_tokens // 0)
          + ((.stages[] | select(.id == $id)).verifier_tokens // 0))' \
    --arg id "$stage_id" --arg field "$field" --arg tokens "$tokens"
}

# Emit one worker cost-log line (docs/cost-log.md). Reads the worker
# identity and start time from state.yaml, derives the role's result from the
# handoff envelope (pass|fail|partial, else stalled), and estimates
# wall-clock as now - started_at at reap time. Non-fatal; the cost-log is
# observability, never a gate.
costlog_emit_worker() {
  local repo_root="$1"
  local state_yaml="$2"
  local stage_id="$3"
  local started_at="$4"
  local worker_identity worker_log envelope result env_status start_epoch now_epoch wall
  worker_identity="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" \
    '.stages[] | select(.id == $id) | .worker // empty')"
  [[ -n "$worker_identity" ]] || return 0
  worker_log="$repo_root/state/logs/${stage_id}-worker.log"
  envelope="$repo_root/state/handoffs/${stage_id}.json"
  result="stalled"
  if [[ -f "$envelope" ]] && jq empty "$envelope" 2>/dev/null; then
    env_status="$(jq -r '.status // empty' "$envelope")"
    case "$env_status" in pass|fail|partial) result="$env_status" ;; esac
  fi
  wall=0
  start_epoch=0
  if start_epoch="$(stage_started_epoch "$started_at" 2>/dev/null)"; then
    now_epoch="$(date -u +%s)"
    wall=$((now_epoch - start_epoch))
    (( wall < 0 )) && wall=0
  else
    start_epoch=0
  fi
  costlog_append "$repo_root" "$stage_id" worker "$worker_identity" "$worker_log" "$wall" "$result" \
    "$(worktree_path_for_stage "$repo_root" "$stage_id")" "$start_epoch" || true
}

# Emit one verifier cost-log line. Reads the verifier identity and
# verifier_started_at from state.yaml; the caller supplies the result
# (pass|fail from the artefact, or aborted when a verifier died without one).
costlog_emit_verifier() {
  local repo_root="$1"
  local state_yaml="$2"
  local stage_id="$3"
  local result="$4"
  local verifier_identity verifier_log started start_epoch now_epoch wall
  verifier_identity="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" \
    '.stages[] | select(.id == $id) | .verifier // empty')"
  [[ -n "$verifier_identity" ]] || return 0
  verifier_log="$repo_root/state/logs/${stage_id}-verifier.log"
  started="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" \
    '.stages[] | select(.id == $id) | .verifier_started_at // empty')"
  wall=0
  start_epoch=0
  if [[ -n "$started" ]] && start_epoch="$(stage_started_epoch "$started" 2>/dev/null)"; then
    now_epoch="$(date -u +%s)"
    wall=$((now_epoch - start_epoch))
    (( wall < 0 )) && wall=0
  else
    start_epoch=0
  fi
  costlog_append "$repo_root" "$stage_id" verifier "$verifier_identity" "$verifier_log" "$wall" "$result" \
    "$(worktree_path_for_stage "$repo_root" "$stage_id")" "$start_epoch" || true
}

# Stage ids end up in jq filters, yq selectors, log paths, and on-disk
# filenames. Reject anything that is not the documented kebab-slug shape so
# the rest of the script can treat the value as a safe identifier. Matches
# 00-bootstrap, 06-real-dispatch-test, 05a-phat-controller-hardening, etc.
validate_stage_id() {
  local stage_id="$1"
  [[ "$stage_id" =~ ^[0-9]{2}[a-z]*-[a-z0-9-]+$ ]]
}

commit_state_branch() {
  local repo_root="$1"
  (
    cd "$repo_root"
    local original_branch
    original_branch="$(git rev-parse --abbrev-ref HEAD)"
    # Keep operator branch unchanged when tick.sh is run interactively.
    trap 'git checkout "$original_branch" >/dev/null 2>&1 || true' EXIT
    # No clean-tree guard here: dispatch happens in an ephemeral sibling
    # worktree (see ensure_run_worktree below), never in repo_root, so
    # repo_root's non-state tree is never dirtied by a stage in flight.
    # Any dirt here is pre-existing operator content, out of scope for the
    # loop -- see templates/orchestrator-checklist.md ("Worktree dispatch
    # pre-flight") and memory/adopters/emergence-viewer/
    # feedback-worktree-dispatch-thinned-preflight.md.
    git checkout -B phat-controller/state >/dev/null 2>&1
    git add state/state.yaml state/budget.json state/verifiers state/handoffs/.gitkeep state/handoffs/README.md 2>/dev/null || true
    if ! git diff --cached --quiet; then
      git commit --author="$(agent-whoami)" -m "phat-controller: tick state update" >/dev/null 2>&1
    fi
  )
}

# --- Worktree-per-run dispatch --------------------------------------------
#
# Backport of the emergence-viewer stage-44 pilot (memory/adopters/
# emergence-viewer/feedback-worktree-dispatch-thinned-preflight.md). Each
# stage dispatches into an ephemeral sibling worktree cut from the base
# branch; the shared checkout at repo_root is never touched by a worker or
# verifier.

# resolve_base_branch: the manifest's 'base_branch' field if present, else
# the repo's current branch at tick time. Manifest lookup mirrors
# manifest_patterns' fallback-to-repo-local-file behaviour.
resolve_base_branch() {
  local repo_root="$1"
  local manifest_path="${2:-}"
  local base=""
  if [[ -n "$manifest_path" && -f "$manifest_path" ]] && command -v yq >/dev/null 2>&1; then
    base="$(yq -r '.base_branch // ""' "$manifest_path" 2>/dev/null || true)"
  fi
  if [[ -z "$base" && -f "$repo_root/.autometta.local.yaml" ]] && command -v yq >/dev/null 2>&1; then
    base="$(yq -r '.base_branch // ""' "$repo_root/.autometta.local.yaml" 2>/dev/null || true)"
  fi
  if [[ -z "$base" ]]; then
    base="$(cd "$repo_root" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
  printf '%s\n' "$base"
}

run_branch_for_stage() {
  printf 'autometta/%s\n' "$1"
}

# Sibling path, not a subdirectory, so '../sibling-repo'-style card inputs
# still resolve exactly as they do from the main checkout.
worktree_path_for_stage() {
  local repo_root="$1" stage_id="$2"
  printf '%s/%s-run-%s\n' "$(dirname "$repo_root")" "$(basename "$repo_root")" "$stage_id"
}

# ensure_run_worktree: remove any worktree/branch left standing by a prior
# attempt at this stage, cut a fresh one from base_branch, and link its
# state/ to the shared repo_root/state/ (state.yaml, budget.json, logs,
# handoffs, verifier artefacts all stay centralised; only code deliverables
# live in the worktree). Prints the worktree path on success, prints
# nothing and returns non-zero on failure.
ensure_run_worktree() {
  local repo_root="$1" stage_id="$2" base_branch="$3"
  local run_branch work_dir
  run_branch="$(run_branch_for_stage "$stage_id")"
  work_dir="$(worktree_path_for_stage "$repo_root" "$stage_id")"
  (
    cd "$repo_root"
    git worktree remove --force "$work_dir" >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    git worktree prune >/dev/null 2>&1 || true
    git branch -D "$run_branch" >/dev/null 2>&1 || true
    git worktree add "$work_dir" -b "$run_branch" "$base_branch" >/dev/null 2>&1
  ) || { log "ensure_run_worktree: failed to cut ${work_dir} from ${base_branch} for ${stage_id}"; return 1; }
  rm -rf "${work_dir:?}/state"
  ln -s "../$(basename "$repo_root")/state" "$work_dir/state"
  printf '%s\n' "$work_dir"
}

# teardown_run_worktree: remove the worktree and run branch after a
# successful ff-merge. Never called on FAIL -- that path leaves both
# standing for operator inspection (autometta-requeue tears them down on
# re-dispatch).
teardown_run_worktree() {
  local repo_root="$1" stage_id="$2"
  local run_branch work_dir
  run_branch="$(run_branch_for_stage "$stage_id")"
  work_dir="$(worktree_path_for_stage "$repo_root" "$stage_id")"
  (
    cd "$repo_root"
    git worktree remove --force "$work_dir" >/dev/null 2>&1 || true
    git branch -d "$run_branch" >/dev/null 2>&1 || true
  )
}

# finalize_run_worktree: on PASS, fast-forward the base branch to the run
# branch if base hasn't moved since the worktree was cut. If base has
# moved (the ff fails), push the run branch instead and leave it and the
# worktree standing for manual integration. Prints 'merged' or 'diverged'.
finalize_run_worktree() {
  local repo_root="$1" stage_id="$2" base_branch="$3"
  local run_branch
  run_branch="$(run_branch_for_stage "$stage_id")"
  (
    cd "$repo_root"
    if git checkout "$base_branch" >/dev/null 2>&1 && git merge --ff-only "$run_branch" >/dev/null 2>&1; then
      printf 'merged\n'
    else
      printf 'diverged\n'
    fi
  )
}

# Pull the stage card's title-line summary as a commit-message fallback.
# Cards open with: "# Stage card <stage-id>: <summary>" — return the
# <summary> portion. Returns empty if no card / no match; the caller
# substitutes a generic fallback.
stage_card_summary() {
  local card_path="$1"
  [[ -n "$card_path" && -f "$card_path" ]] || { printf ''; return 0; }
  local line
  line="$(grep -m1 '^# ' "$card_path" || true)"
  # Drop "# Stage card <id>: " or just "# " prefix, keep the rest.
  if [[ "$line" =~ ^#\ Stage\ card\ [^:]+:\ (.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$line" =~ ^#\ (.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf ''
}

# Orchestrator identity from the card metadata. The orchestrator is fixed at
# card-authoring time, so the card is its source of truth (worker and verifier
# are resolved at dispatch and live in state.yaml). Mirrors the parse in
# scripts/aggregate-dashboard.sh.
stage_card_orchestrator() {
  local card_path="$1"
  [[ -n "$card_path" && -f "$card_path" ]] || { printf ''; return 0; }
  grep -E '^- \*\*Orchestrator:\*\*' "$card_path" 2>/dev/null \
    | head -n1 \
    | sed -E 's/^- \*\*Orchestrator:\*\*[[:space:]]*//'
}

# Annotate a 'Name <email>' identity with its role in the display name, for a
# human-readable Co-Authored-By line: 'Name (role) <email>'. Git and GitHub key
# co-authorship off the email, so the parenthetical is display-only. The clean
# canonical identity is preserved separately in the Autometta-* role trailers.
annotate_role() {
  local id="$1" role="$2"
  if [[ "$id" == *" <"* ]]; then
    printf '%s (%s) <%s' "${id% <*}" "$role" "${id#*<}"
  else
    printf '%s (%s)' "$id" "$role"
  fi
}

# Decide what to do with a verifier artefact: commit-on-PASS or
# mark-verifier_failed-on-FAIL. Treats a missing / malformed 'overall'
# field as FAIL (fail-safe). The working tree on the operator branch
# is the source of truth for the worker's diff; we commit the non-state
# changes with the worker as --author and the verifier as Co-Authored-By.
#
# Backward-compat: if a worker on the old prompt has already
# self-committed (clean working tree on a PASS artefact), log a
# deprecated-path warning and mark the stage completed without
# erroring.
_process_verifier_artefact() {
  local repo_root="$1"
  local state_yaml="$2"
  local stage_id="$3"
  local artefact_rel="$4"
  local manifest_path="$5"
  local artefact_abs="$repo_root/$artefact_rel"

  local overall
  overall="$(jq -r '.overall // empty' "$artefact_abs" 2>/dev/null || true)"
  if [[ "$overall" != "PASS" && "$overall" != "FAIL" ]]; then
    log "verifier artefact for ${stage_id} has missing or malformed 'overall' field (got '${overall}'); treating as FAIL"
    overall="FAIL"
  fi

  if [[ "$overall" == "FAIL" ]]; then
    state_apply_json "$state_yaml" \
      '(.stages[] | select(.id == $id)).status = "verifier_failed" | .current_stage = null' \
      --arg id "$stage_id"
    budget_record_failure "$repo_root"
    log "stage ${stage_id} verifier reported FAIL; run branch and worktree (if any) left standing for operator review (status=verifier_failed)"
    return 0
  fi

  # PASS path. Stage non-state changes and commit them on the stage's run
  # branch, inside its worktree if one is standing (worktree-per-run
  # dispatch), falling back to repo_root's checked-out branch for a stage
  # dispatched before this feature landed (deprecated path). Commit author
  # is the worker, with the orchestrator and verifier as role-named
  # Co-Authored-By lines and Autometta-Orchestrator / -Worker / -Verifier
  # role trailers. The state-branch commit that follows handles state/ files
  # in repo_root, which are shared with the worktree via a symlink.
  local worker_identity verifier_identity orchestrator_identity headline summary commit_subject card_path
  worker_identity="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .worker // empty')"
  verifier_identity="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .verifier // empty')"
  card_path="$(stage_card_for_id "$repo_root" "$stage_id" "$manifest_path")"
  orchestrator_identity="$(stage_card_orchestrator "$card_path")"
  headline="$(jq -r '.headline // empty' "$artefact_abs" 2>/dev/null || true)"
  if [[ -z "$headline" ]]; then
    headline="$(stage_card_summary "$card_path")"
  fi
  if [[ -z "$headline" ]]; then
    headline="worker output accepted"
  fi
  commit_subject="${stage_id}: ${headline}"

  local base_branch work_dir
  base_branch="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .base_branch // empty')"
  work_dir="$(worktree_path_for_stage "$repo_root" "$stage_id")"
  local commit_dir="$repo_root"
  if [[ -n "$base_branch" && -d "$work_dir" ]]; then
    commit_dir="$work_dir"
  fi

  local commit_rc=0
  (
    cd "$commit_dir"
    local non_state_changes
    non_state_changes="$(git status --porcelain -- . ':(exclude)state' || true)"
    if [[ -z "$non_state_changes" ]]; then
      log "stage ${stage_id} PASS but no diff to commit, presumably worker self-committed (deprecated path)"
      exit 0
    fi
    if [[ -z "$worker_identity" ]]; then
      log "stage ${stage_id} PASS but worker identity missing from state.yaml; refusing to commit"
      exit 2
    fi
    git add -- . ':(exclude)state' >/dev/null 2>&1 || true
    if git diff --cached --quiet; then
      log "stage ${stage_id} PASS: nothing staged after add (state-only diff); skipping worker commit"
      exit 0
    fi
    # Author is the worker (the coder). Trailers carry the full role record:
    # role-named Co-Authored-By lines for the orchestrator and verifier
    # (git-native convention, role shown in the display name), plus role-keyed
    # Autometta-* trailers holding the clean canonical identity for analysis.
    # All trailer lines go in one -m so git parses them as a single block.
    local commit_args=( --author="$worker_identity" -m "$commit_subject" )
    local -a trailer_lines=()
    [[ -n "$orchestrator_identity" ]] && trailer_lines+=( "Co-Authored-By: $(annotate_role "$orchestrator_identity" orchestrator)" )
    [[ -n "$verifier_identity" ]]     && trailer_lines+=( "Co-Authored-By: $(annotate_role "$verifier_identity" verifier)" )
    [[ -n "$orchestrator_identity" ]] && trailer_lines+=( "Autometta-Orchestrator: $orchestrator_identity" )
    [[ -n "$worker_identity" ]]       && trailer_lines+=( "Autometta-Worker: $worker_identity" )
    [[ -n "$verifier_identity" ]]     && trailer_lines+=( "Autometta-Verifier: $verifier_identity" )
    if (( ${#trailer_lines[@]} > 0 )); then
      commit_args+=( -m "$(printf '%s\n' "${trailer_lines[@]}")" )
    fi
    if ! git commit "${commit_args[@]}" >/dev/null 2>&1; then
      log "stage ${stage_id} PASS: git commit failed; leaving working tree intact"
      exit 2
    fi
  ) || commit_rc=$?
  if (( commit_rc != 0 )); then
    state_apply_json "$state_yaml" \
      '(.stages[] | select(.id == $id)).status = "verifier_failed" | .current_stage = null' \
      --arg id "$stage_id"
    budget_record_failure "$repo_root"
    return 0
  fi

  # Record commit SHA back into state.yaml for the audit trail.
  local commit_sha
  commit_sha="$(cd "$commit_dir" && git rev-parse HEAD 2>/dev/null || true)"

  # Integrate the run branch: ff-merge into base if base hasn't moved,
  # otherwise push the run branch and leave it (and the worktree) standing
  # for manual integration. No-op on the deprecated repo_root-commit path
  # (base_branch empty / no worktree).
  if [[ -n "$base_branch" && -d "$work_dir" ]]; then
    local merge_result
    merge_result="$(finalize_run_worktree "$repo_root" "$stage_id" "$base_branch")"
    if [[ "$merge_result" == "merged" ]]; then
      teardown_run_worktree "$repo_root" "$stage_id"
      log "stage ${stage_id} PASS: fast-forwarded ${base_branch} to $(run_branch_for_stage "$stage_id") and removed the run worktree"
    else
      local run_branch push_note
      run_branch="$(run_branch_for_stage "$stage_id")"
      push_note="stage ${stage_id}: ${base_branch} moved since dispatch; ${run_branch} left standing"
      if (cd "$repo_root" && git push origin "$run_branch" >/dev/null 2>&1); then
        push_note="${push_note}, pushed to origin/${run_branch} for manual integration"
      else
        push_note="${push_note}; push to origin also failed, integrate locally"
      fi
      log "stage ${stage_id} PASS: ${push_note}"
      if [[ -f "$repo_root/HANDOFF.md" ]]; then
        printf '\n- %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$push_note" >> "$repo_root/HANDOFF.md"
      fi
    fi
  fi

  if [[ -n "$commit_sha" ]]; then
    state_apply_json "$state_yaml" \
      '(.stages[] | select(.id == $id)).commit = $sha | (.stages[] | select(.id == $id)).status = "completed" | (.stages[] | select(.id == $id)).completed_at = $now | .current_stage = null' \
      --arg id "$stage_id" --arg sha "$commit_sha" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  else
    state_apply_json "$state_yaml" \
      '(.stages[] | select(.id == $id)).status = "completed" | (.stages[] | select(.id == $id)).completed_at = $now | .current_stage = null' \
      --arg id "$stage_id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  budget_reset_failures "$repo_root"
  log "stage ${stage_id} PASS: committed worker output as ${commit_sha:-unknown} with --author=${worker_identity}"
}

process_repo() {
  local repo_root="$1"
  local manifest_path="${2:-}"
  if ! acquire_repo_lock "$repo_root"; then
    log "tick already in progress for ${repo_root}, skipping"
    return 0
  fi
  ensure_tmux_viewer "$repo_root"
  run_heartbeat "$repo_root"
  local rc=0
  _process_repo_locked "$repo_root" "$manifest_path" || rc=$?
  release_repo_lock "$repo_root"
  return $rc
}

# Best-effort: walk the per-agent liveness registry and surface stalls /
# overruns into state/heartbeat.json. Never fatal; the heartbeat itself
# is a watchdog, not a gate.
run_heartbeat() {
  local repo_root="$1"
  if [[ -x "$script_dir/heartbeat.sh" ]]; then
    "$script_dir/heartbeat.sh" "$repo_root" >/dev/null 2>&1 || true
  fi
}

# Best-effort: keep the autometta-<repo> tmux viewer alive whenever the
# loop is actually doing work for a repo. Idempotent and non-fatal —
# cron runs without a TTY, but `tmux new-session -d` does not need one.
ensure_tmux_viewer() {
  local repo_root="$1"
  if ! command -v tmux >/dev/null 2>&1; then
    return 0
  fi
  "$script_dir/attach.sh" --ensure "$repo_root" >/dev/null 2>&1 || true
}

_process_repo_locked() {
  local repo_root="$1"
  local manifest_path="${2:-}"
  local state_yaml="$repo_root/state/state.yaml"

  if ! ensure_yq_or_halt "$repo_root"; then
    return 1
  fi

  # Budget window auto-reset: a halted-or-at-cap budget from a prior run
  # window (UTC calendar day) is not terminal for this window. See
  # budget_ensure_window in budget.sh.
  budget_ensure_window "$repo_root"

  # Provider limit pause: the window was exhausted, not a cap. Dispatching
  # into it costs a stage and a failure for work that was never attempted, so
  # sit the tick out. Clears itself once the clock passes the reset.
  if budget_pause_active "$repo_root"; then
    local paused_until_epoch paused_reason_text budget_path_p
    budget_path_p="$(budget_file "$repo_root")"
    paused_until_epoch="$(jq -r '.paused_until // 0' "$budget_path_p")"
    paused_reason_text="$(jq -r '.paused_reason // "provider limit"' "$budget_path_p")"
    log "paused ${repo_root} until $(date -r "$paused_until_epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$paused_until_epoch"): ${paused_reason_text}"
    return 0
  fi

  local budget_rc=0
  budget_check_caps "$repo_root" || budget_rc=$?
  case "$budget_rc" in
    0)
      ;;
    2)
      local existing_reason budget_path
      budget_path="$(budget_file "$repo_root")"
      existing_reason="$(jq -r '.halt_reason // "unknown"' "$budget_path")"
      if budget_should_log_halt "$repo_root" "$existing_reason"; then
        log "halted ${repo_root} (reason already recorded: ${existing_reason})"
      fi
      return 0
      ;;
    1)
      local cap_name="${BUDGET_CHECK_LAST_HIT:-unknown-cap}"
      budget_halt "$repo_root" "$cap_name"
      log "halted ${repo_root} due to ${BUDGET_CHECK_ALL_HITS:-$cap_name}"
      return 0
      ;;
    *)
      log "budget_check_caps returned unexpected code ${budget_rc} for ${repo_root}"
      return 1
      ;;
  esac

  # State-integrity guard: never dispatch against a corrupt/empty state.yaml.
  # state.yaml is gitignored with no remote copy, so if it has been truncated
  # we auto-restore the rolling .bak written by state_apply_json; failing
  # that, halt loudly rather than proceed against (or re-initialise over)
  # lost stage history.
  if [[ ! -s "$state_yaml" ]] || ! state_json "$state_yaml" 2>/dev/null \
       | jq -e 'type == "object" and (.stages | type == "array")' >/dev/null 2>&1; then
    if [[ -s "${state_yaml}.bak" ]] && state_json "${state_yaml}.bak" 2>/dev/null \
         | jq -e 'type == "object" and (.stages | type == "array")' >/dev/null 2>&1; then
      cp -p "${state_yaml}.bak" "$state_yaml"
      log "state-integrity: ${state_yaml} was corrupt/empty; restored from .bak"
    else
      budget_halt "$repo_root" "state-corrupt"
      log "state-integrity: ${state_yaml} corrupt/empty and no valid .bak; halted (manual recovery required)"
      return 0
    fi
  fi

  local current_stage
  current_stage="$(state_json "$state_yaml" | jq -r '.current_stage')"

  if [[ "$current_stage" != "null" && -n "$current_stage" ]]; then
    if ! validate_stage_id "$current_stage"; then
      log "rejecting malformed current_stage id ${current_stage} in ${repo_root}"
      budget_halt "$repo_root" "invalid-stage-id"
      return 1
    fi
    local started_at worker_pid verifier_pid
    started_at="$(state_json "$state_yaml" | jq -r --arg id "$current_stage" '.stages[] | select(.id == $id) | .started_at // empty')"
    worker_pid="$(state_json "$state_yaml" | jq -r --arg id "$current_stage" '.stages[] | select(.id == $id) | .worker_pid // empty')"
    verifier_pid="$(state_json "$state_yaml" | jq -r --arg id "$current_stage" '.stages[] | select(.id == $id) | .verifier_pid // empty')"

    # Artefact check must run BEFORE the stall check: a verifier that
    # produced a passing artefact wins, even if the worker phase ran
    # past its declared wall-clock budget. Stalling a completed stage
    # corrupts the loop's accounting (false consecutive_failures bump)
    # and forces operator repair.
    local artefact
    artefact="$(state_json "$state_yaml" | jq -r --arg id "$current_stage" '.stages[] | select(.id == $id) | .verifier_artefact // empty')"
    if [[ -n "$artefact" && -f "$repo_root/$artefact" ]]; then
      # Token accounting (stage 10): the verifier has produced its
      # artefact, so its log is final. Count its tokens before the stage
      # closes out. This branch runs exactly once per stage because
      # _process_verifier_artefact clears current_stage on exit.
      local verifier_log_path="$repo_root/state/logs/${current_stage}-verifier.log"
      local verifier_work_dir_acct verifier_start_epoch
      verifier_work_dir_acct="$(worktree_path_for_stage "$repo_root" "$current_stage")"
      verifier_start_epoch="$(role_started_epoch "$state_yaml" "$current_stage" verifier)"
      budget_account_tokens_from_dispatch "$repo_root" "$verifier_log_path" "verifier" \
        "$verifier_work_dir_acct" "$verifier_start_epoch" || true
      # Per-stage snapshot (stage 11): capture verifier tokens against the
      # stage entry. Worker tokens may already be set from an earlier tick.
      stage_snapshot_tokens "$repo_root" "$state_yaml" "$current_stage" "$verifier_log_path" "verifier" \
        "$verifier_work_dir_acct" "$verifier_start_epoch"
      # Cost-log: the verifier produced an artefact, so its log is final.
      # Emit before _process_verifier_artefact clears current_stage.
      local verifier_overall verifier_result
      verifier_overall="$(jq -r '.overall // empty' "$repo_root/$artefact" 2>/dev/null || true)"
      case "$verifier_overall" in
        PASS) verifier_result="pass" ;;
        *)    verifier_result="fail" ;;
      esac
      costlog_emit_verifier "$repo_root" "$state_yaml" "$current_stage" "$verifier_result"
      _process_verifier_artefact "$repo_root" "$state_yaml" "$current_stage" "$artefact" "$manifest_path"
      budget_increment_tick "$repo_root"
      commit_state_branch "$repo_root"
      return 0
    fi

    if [[ -n "$started_at" ]]; then
      local card_path budget_seconds grace_seconds stall_threshold started_epoch now_epoch elapsed
      card_path="$(stage_card_for_id "$repo_root" "$current_stage" "$manifest_path")"
      if [[ -n "$card_path" ]]; then
        budget_seconds="$(worker_budget_seconds_from_card "$card_path")"
      else
        log "warning: stage card missing for ${current_stage}, defaulting worker wall-clock budget to 600 seconds"
        budget_seconds=600
      fi
      grace_seconds=$((budget_seconds / 2))
      stall_threshold=$((budget_seconds + grace_seconds))
      if started_epoch="$(stage_started_epoch "$started_at" 2>/dev/null)"; then
        now_epoch="$(date -u +%s)"
        elapsed=$((now_epoch - started_epoch))
        if (( elapsed > stall_threshold )); then
          if [[ -n "${worker_pid:-}" ]]; then
            kill -TERM "$worker_pid" 2>/dev/null || true
          fi
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).status = "stalled" | .current_stage = null' \
            --arg id "$current_stage"
          budget_record_failure "$repo_root"
          log "stage ${current_stage} stalled after ${elapsed}s (budget ${budget_seconds}s + 50% grace), marked stalled"
          budget_increment_tick "$repo_root"
          commit_state_branch "$repo_root"
          return 0
        fi
      else
        log "warning: invalid started_at for ${current_stage}, skipping stall check"
      fi
    fi

    local card_path
    if [[ -n "${worker_pid:-}" ]] && kill -0 "$worker_pid" 2>/dev/null; then
        log "worker ${worker_pid} for ${current_stage} still running, skipping verifier dispatch"
        budget_increment_tick "$repo_root"
        commit_state_branch "$repo_root"
        return 0
      fi
      # Token accounting (stage 10): worker_pid was set but is no longer
      # alive — the worker has exited. Parse its log once, then clear
      # worker_pid so subsequent ticks (still waiting on the verifier) do
      # not double-count.
      if [[ -n "${worker_pid:-}" ]]; then
        local worker_log_path="$repo_root/state/logs/${current_stage}-worker.log"

        # Provider refusal: the worker exited immediately without attempting
        # the stage. Rewind it to pending so the next unpaused tick dispatches
        # it fresh, rather than counting a failure for work never done. The
        # run worktree is left standing to be reused.
        #
        # Gated on the absence of a handoff envelope. A worker that finished
        # its stage has written one, and a stage whose subject matter is rate
        # limiting would otherwise match the refusal pattern from its own
        # output, get rewound, and loop forever losing completed work.
        if [[ ! -f "$repo_root/state/handoffs/${current_stage}.json" ]] \
           && handle_limit_refusal "$repo_root" "$current_stage" worker "$worker_log_path"; then
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).status = "pending"
             | (.stages[] | select(.id == $id)).worker_pid = null
             | (.stages[] | select(.id == $id)).started_at = null
             | .current_stage = null' \
            --arg id "$current_stage"
          commit_state_branch "$repo_root"
          return 0
        fi

        if [[ ! -f "$repo_root/state/handoffs/${current_stage}.json" ]] \
           && is_instant_dispatch_configuration_fault \
                "$worker_log_path" "$started_at" "$repo_root/state/handoffs/${current_stage}.json"; then
          halt_dispatch_configuration_fault "$repo_root" "$current_stage" worker
          log "stage ${current_stage} halted: worker exited before starting because its dispatch configuration is invalid (dispatch-configuration-fault)"
          commit_state_branch "$repo_root"
          return 0
        fi

        local worker_work_dir_acct worker_start_epoch
        worker_work_dir_acct="$(worktree_path_for_stage "$repo_root" "$current_stage")"
        worker_start_epoch="$(role_started_epoch "$state_yaml" "$current_stage" worker)"
        budget_account_tokens_from_dispatch "$repo_root" "$worker_log_path" "worker" \
          "$worker_work_dir_acct" "$worker_start_epoch" || true
        # Per-stage snapshot (stage 11).
        stage_snapshot_tokens "$repo_root" "$state_yaml" "$current_stage" "$worker_log_path" "worker" \
          "$worker_work_dir_acct" "$worker_start_epoch"
        # Cost-log: the worker has exited and its log is final. Result is
        # read from the handoff envelope inside the helper.
        costlog_emit_worker "$repo_root" "$state_yaml" "$current_stage" "$started_at"
        state_apply_json "$state_yaml" \
          '(.stages[] | select(.id == $id)).worker_pid = null' \
          --arg id "$current_stage"
        worker_pid=""

        # Envelope check (stage 17): the worker has exited. The handoff
        # envelope at state/handoffs/<stage-id>.json is the sole completion
        # signal. Process exit alone is no longer sufficient to advance.
        local envelope_path="$repo_root/state/handoffs/${current_stage}.json"
        local invalid_path="$repo_root/state/handoffs/${current_stage}.invalid.json"
        if [[ ! -f "$envelope_path" ]]; then
          # Worker exited but wrote no envelope. Mark stalled.
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).status = "stalled"
             | (.stages[] | select(.id == $id)).stall_marker = "worker_envelope_missing_after_exit"
             | .current_stage = null' \
            --arg id "$current_stage"
          budget_record_failure "$repo_root"
          log "stage ${current_stage} stalled: worker exited but wrote no handoff envelope (worker_envelope_missing_after_exit)"
          budget_increment_tick "$repo_root"
          commit_state_branch "$repo_root"
          return 0
        fi

        # Validate the envelope against the schema.
        local envelope_valid=1
        if ! jq empty "$envelope_path" 2>/dev/null; then
          envelope_valid=0
        else
          local env_stage env_status env_deliverables env_notes
          env_stage="$(jq -r '.stage_id // empty' "$envelope_path")"
          env_status="$(jq -r '.status // empty' "$envelope_path")"
          env_deliverables="$(jq -r 'if .deliverables | type == "array" then "ok" else "bad" end' "$envelope_path")"
          env_notes="$(jq -r '.notes // empty' "$envelope_path")"
          if [[ -z "$env_stage" || -z "$env_status" || "$env_deliverables" != "ok" || -z "$env_notes" ]]; then
            envelope_valid=0
          elif [[ "$env_status" != "pass" && "$env_status" != "fail" && "$env_status" != "partial" ]]; then
            envelope_valid=0
          fi
        fi

        if (( envelope_valid == 0 )); then
          mv "$envelope_path" "$invalid_path" 2>/dev/null || true
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).status = "stalled"
             | (.stages[] | select(.id == $id)).stall_marker = "worker_envelope_invalid"
             | .current_stage = null' \
            --arg id "$current_stage"
          budget_record_failure "$repo_root"
          log "stage ${current_stage} stalled: handoff envelope failed schema validation (worker_envelope_invalid); moved to ${invalid_path}"
          budget_increment_tick "$repo_root"
          commit_state_branch "$repo_root"
          return 0
        fi

        local env_notes_val
        env_notes_val="$(jq -r '.notes // ""' "$envelope_path")"
        local env_status_val
        env_status_val="$(jq -r '.status' "$envelope_path")"

        # fail or partial: do not dispatch verifier.
        if [[ "$env_status_val" == "fail" || "$env_status_val" == "partial" ]]; then
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).status = "failed"
             | (.stages[] | select(.id == $id)).stall_marker = $notes
             | .current_stage = null' \
            --arg id "$current_stage" --arg notes "$env_notes_val"
          budget_record_failure "$repo_root"
          log "stage ${current_stage} failed: worker envelope status=${env_status_val}; notes: ${env_notes_val}"
          budget_increment_tick "$repo_root"
          commit_state_branch "$repo_root"
          return 0
        fi

        # status=pass: fall through to verifier dispatch below.
        log "stage ${current_stage} worker envelope status=pass, proceeding to verifier dispatch"
      fi

      if [[ -n "${verifier_pid:-}" ]] && kill -0 "$verifier_pid" 2>/dev/null; then
        log "verifier ${verifier_pid} for ${current_stage} still running, skipping verifier dispatch"
        budget_increment_tick "$repo_root"
        commit_state_branch "$repo_root"
        return 0
      fi
      # Token accounting (stage 10): a previous verifier_pid is dead but
      # left no artefact (the re-dispatch path). Capture its tokens before
      # we spawn a fresh verifier, then clear verifier_pid for idempotency.
      if [[ -n "${verifier_pid:-}" ]]; then
        local stale_verifier_log_path="$repo_root/state/logs/${current_stage}-verifier.log"

        # Provider refusal: the verifier was never attempted. Clear its pid so
        # the next unpaused tick re-dispatches it, but do not consume one of
        # its three attempts and do not record a failure. The worker's output
        # is untouched and still waiting to be verified.
        if handle_limit_refusal "$repo_root" "$current_stage" verifier "$stale_verifier_log_path"; then
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).verifier_pid = null' \
            --arg id "$current_stage"
          commit_state_branch "$repo_root"
          return 0
        fi

        local stale_verifier_started_at
        stale_verifier_started_at="$(state_json "$state_yaml" | jq -r --arg id "$current_stage" '.stages[] | select(.id == $id) | .verifier_started_at // empty')"
        if is_instant_dispatch_configuration_fault \
             "$stale_verifier_log_path" "$stale_verifier_started_at" \
             "$repo_root/state/verifiers/${current_stage}.json"; then
          halt_dispatch_configuration_fault "$repo_root" "$current_stage" verifier
          log "stage ${current_stage} halted: verifier exited before verification because its dispatch configuration is invalid; reserved attempt returned (dispatch-configuration-fault)"
          commit_state_branch "$repo_root"
          return 0
        fi

        local stale_work_dir_acct stale_start_epoch
        stale_work_dir_acct="$(worktree_path_for_stage "$repo_root" "$current_stage")"
        stale_start_epoch="$(role_started_epoch "$state_yaml" "$current_stage" verifier)"
        budget_account_tokens_from_dispatch "$repo_root" "$stale_verifier_log_path" "verifier" \
          "$stale_work_dir_acct" "$stale_start_epoch" || true
        # Per-stage snapshot (stage 11).
        stage_snapshot_tokens "$repo_root" "$state_yaml" "$current_stage" "$stale_verifier_log_path" "verifier" \
          "$stale_work_dir_acct" "$stale_start_epoch"
        # Cost-log: a verifier died without an artefact. Record its spend
        # against this stage with result=aborted before we re-dispatch.
        costlog_emit_verifier "$repo_root" "$state_yaml" "$current_stage" "aborted"
        state_apply_json "$state_yaml" \
          '(.stages[] | select(.id == $id)).verifier_pid = null' \
          --arg id "$current_stage"
        verifier_pid=""
      fi
      # Bound verifier re-dispatch. A verifier that crashes without writing
      # its artefact would otherwise be re-spawned every tick until the
      # consecutive-failure cap kicks in, which is wasteful and noisy. Cap per-stage
      # attempts and stall the stage when the cap is reached so a human can
      # look at it.
      local verifier_attempts verifier_attempt_cap=3
      verifier_attempts="$(state_json "$state_yaml" | jq -r --arg id "$current_stage" '.stages[] | select(.id == $id) | .verifier_attempts // 0')"
      if (( verifier_attempts >= verifier_attempt_cap )); then
        log "verifier attempt cap (${verifier_attempt_cap}) reached for ${current_stage} without artefact, marking stalled"
        state_apply_json "$state_yaml" \
          '(.stages[] | select(.id == $id)).status = "stalled" | .current_stage = null' \
          --arg id "$current_stage"
        budget_record_failure "$repo_root"
        budget_increment_tick "$repo_root"
        commit_state_branch "$repo_root"
        return 0
      fi
    card_path="$(stage_card_for_id "$repo_root" "$current_stage" "$manifest_path")"
    if [[ -n "$card_path" ]]; then
      # Cap check at the point of spend, not at the top of the tick. By here
      # this tick may already have reaped a worker and charged its tokens
      # (budget_account_tokens_from_log, above), so the budget read at line
      # ~710 is stale by one dispatch. Verifiers are the expensive half on
      # emergence-lab-gpu -- three of the five largest runs in the incident
      # were verifier dispatches, the largest 18.1M tokens against a
      # 1,000,000 cap.
      if ! budget_gate_dispatch "$repo_root" "verifier dispatch for ${current_stage}"; then
        log "not dispatching verifier for ${current_stage}: budget gate refused"
        commit_state_branch "$repo_root"
        return 0
      fi
      # Stamp verifier_started_at alongside the attempt bump so the cost-log
      # can estimate verifier wall-clock when the artefact lands next tick.
      state_apply_json "$state_yaml" \
        '(.stages[] | select(.id == $id)).verifier_attempts = ((.stages[] | select(.id == $id) | .verifier_attempts // 0) + 1)
         | (.stages[] | select(.id == $id)).verifier_started_at = $now' \
        --arg id "$current_stage" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      local verifier_work_dir
      verifier_work_dir="$(worktree_path_for_stage "$repo_root" "$current_stage")"
      local verifier_spawn_rc=0
      if [[ -d "$verifier_work_dir" ]]; then
        "$script_dir/spawn-verifier.sh" "$card_path" "$repo_root" "$verifier_work_dir" || verifier_spawn_rc=$?
      else
        log "run worktree missing for ${current_stage} at ${verifier_work_dir}, verifying against ${repo_root} (deprecated fallback)"
        "$script_dir/spawn-verifier.sh" "$card_path" "$repo_root" || verifier_spawn_rc=$?
      fi
      if (( verifier_spawn_rc != 0 )); then
        halt_dispatch_configuration_fault "$repo_root" "$current_stage" verifier
        log "stage ${current_stage} halted: verifier dispatch command failed before an agent started (dispatch-configuration-fault, exit ${verifier_spawn_rc}); reserved attempt returned"
        commit_state_branch "$repo_root"
        return 0
      fi
    else
      state_apply_json "$state_yaml" \
        '(.stages[] | select(.id == $id)).status = "stalled"' \
        --arg id "$current_stage"
      budget_record_failure "$repo_root"
    fi
  else
    local next_stage
    next_stage="$(state_json "$state_yaml" | jq -r '.stages[] | select(.status == "pending") | .id' | head -n1)"
    if [[ -n "$next_stage" ]]; then
      if ! validate_stage_id "$next_stage"; then
        log "rejecting malformed pending stage id ${next_stage} in ${repo_root}"
        budget_halt "$repo_root" "invalid-stage-id"
        return 1
      fi
      local card_path now_iso
      card_path="$(stage_card_for_id "$repo_root" "$next_stage" "$manifest_path")"
      if [[ -z "$card_path" ]]; then
        log "stage card missing for ${next_stage} in ${repo_root}"
      elif ! budget_gate_dispatch "$repo_root" "worker dispatch for ${next_stage}"; then
        # Refuse before any state is mutated and before a run worktree is
        # cut, so a gated stage stays cleanly pending for the next window
        # rather than being left in_progress with nothing running.
        log "not dispatching worker for ${next_stage}: budget gate refused"
      else
        local base_branch work_dir
        base_branch="$(resolve_base_branch "$repo_root" "$manifest_path")"
        if [[ -z "$base_branch" ]]; then
          log "could not resolve a base branch for ${next_stage} in ${repo_root}, stalling stage"
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).status = "stalled" | (.stages[] | select(.id == $id)).stall_marker = "base_branch_unresolved"' \
            --arg id "$next_stage"
          budget_record_failure "$repo_root"
        elif ! work_dir="$(ensure_run_worktree "$repo_root" "$next_stage" "$base_branch")" || [[ -z "$work_dir" ]]; then
          log "could not cut a run worktree for ${next_stage} in ${repo_root} from ${base_branch}, stalling stage"
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).status = "stalled" | (.stages[] | select(.id == $id)).stall_marker = "run_worktree_failed"' \
            --arg id "$next_stage"
          budget_record_failure "$repo_root"
        else
          now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          state_apply_json "$state_yaml" \
            '(.stages[] | select(.id == $id)).status = "in_progress" | (.stages[] | select(.id == $id)).started_at = $now | (.stages[] | select(.id == $id)).base_branch = $base | .current_stage = $id' \
            --arg id "$next_stage" --arg now "$now_iso" --arg base "$base_branch"
          local worker_spawn_rc=0
          "$script_dir/spawn-worker.sh" "$card_path" "$repo_root" "$work_dir" || worker_spawn_rc=$?
          if (( worker_spawn_rc != 0 )); then
            halt_dispatch_configuration_fault "$repo_root" "$next_stage" worker
            log "stage ${next_stage} halted: worker dispatch command failed before an agent started (dispatch-configuration-fault, exit ${worker_spawn_rc})"
          fi
        fi
      fi
    fi
  fi

  budget_increment_tick "$repo_root"
  commit_state_branch "$repo_root"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repair)
        repair_mode
        ;;
      --reset-halt)
        reset_halts_mode
        ;;
      *)
        log "unknown flag: $1"
        exit 1
        ;;
    esac
  done

  mkdir -p "$controller_log_dir"

  # Host-level dependency pre-flight. Cheap (a handful of command -v calls).
  # Run on every tick fire so a missing dependency surfaces in the cron log
  # immediately rather than as a partial halt across subscribers.
  if ! "$script_dir/check-deps.sh" >/dev/null; then
    log "dependency pre-flight failed; run scripts/check-deps.sh for details"
    exit 1
  fi

  local subscriber_file
  while IFS= read -r subscriber_file; do
    [[ -n "$subscriber_file" ]] || continue
    local enabled repo_path manifest_path
    enabled="$(read_subscriber_field "$subscriber_file" "enabled")"
    repo_path="$(read_subscriber_field "$subscriber_file" "repo_path")"
    manifest_path="$(read_subscriber_field "$subscriber_file" "manifest_path")"
    if [[ "$enabled" != "true" ]]; then
      continue
    fi
    if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
      log "invalid repo_path in ${subscriber_file}"
      continue
    fi
    process_repo "$repo_path" "$manifest_path"
  done < <(sort_subscribers)
}

# Only auto-run when executed directly; sourcing (e.g. for tests) loads the
# functions without firing the tick loop.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

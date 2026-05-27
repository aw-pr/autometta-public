#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"

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

repair_mode() {
  log "repair not yet implemented, no-op"
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

# Apply a jq filter to state.yaml. Pass values via --arg / --argjson rather
# than string interpolation: a stage id with a quote or backslash would
# otherwise break the filter (or worse). Trailing args are forwarded to jq.
state_apply_json() {
  local state_yaml="$1"
  local jq_filter="$2"
  shift 2
  local tmp_json tmp_yaml
  tmp_json="$(mktemp)"
  tmp_yaml="$(mktemp)"
  state_json "$state_yaml" | jq "$@" "$jq_filter" > "$tmp_json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp_json"
  yq -P '.' "$tmp_json" > "$tmp_yaml"
  mv "$tmp_yaml" "$state_yaml"
  rm -f "$tmp_json"
}

# stage_snapshot_tokens: parse a worker/verifier log for its token count
# and snapshot it onto the matching stage entry in state.yaml. Sets one of
# worker_tokens / verifier_tokens (per $4) and recomputes .tokens as the
# sum of the two (treating absent halves as 0). Non-fatal: missing log,
# missing match, or non-numeric parse all silently no-op so the tick loop
# never aborts on accounting noise.
#
# Args: repo_root, state_yaml, stage_id, log_path, role (worker|verifier)
stage_snapshot_tokens() {
  local repo_root="$1"
  local state_yaml="$2"
  local stage_id="$3"
  local log_path="$4"
  local role="$5"
  if [[ ! -f "$log_path" ]]; then
    return 0
  fi
  local tokens
  tokens="$(budget_parse_tokens_from_log "$log_path")"
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
    local non_state_changes
    non_state_changes="$(git status --porcelain -- . ':(exclude)state' || true)"
    if [[ -n "$non_state_changes" ]]; then
      budget_halt "$repo_root" "dirty-working-tree"
      log "dirty working tree outside state/ for ${repo_root}, refusing state branch checkout"
      return 1
    fi
    git checkout -B phat-controller/state >/dev/null 2>&1
    git add state/state.yaml state/budget.json state/verifiers 2>/dev/null || true
    if ! git diff --cached --quiet; then
      git commit --author="$(agent-whoami)" -m "phat-controller: tick state update" >/dev/null 2>&1
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
    log "stage ${stage_id} verifier reported FAIL; working tree left intact for operator review (status=verifier_failed)"
    return 0
  fi

  # PASS path. Stage non-state working-tree changes on the current
  # branch and commit with the worker as author + verifier as
  # Co-Authored-By. The state-branch commit that follows handles
  # state/ files.
  local worker_identity verifier_identity headline summary commit_subject
  worker_identity="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .worker // empty')"
  verifier_identity="$(state_json "$state_yaml" | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .verifier // empty')"
  headline="$(jq -r '.headline // empty' "$artefact_abs" 2>/dev/null || true)"
  if [[ -z "$headline" ]]; then
    local card_path
    card_path="$(stage_card_for_id "$repo_root" "$stage_id" "$manifest_path")"
    headline="$(stage_card_summary "$card_path")"
  fi
  if [[ -z "$headline" ]]; then
    headline="worker output accepted"
  fi
  commit_subject="${stage_id}: ${headline}"

  local commit_rc=0
  (
    cd "$repo_root"
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
    local commit_args=( --author="$worker_identity" -m "$commit_subject" )
    if [[ -n "$verifier_identity" ]]; then
      commit_args+=( -m "Co-Authored-By: $verifier_identity" )
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
  commit_sha="$(cd "$repo_root" && git rev-parse HEAD 2>/dev/null || true)"
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

  local budget_rc=0
  budget_check_caps "$repo_root" || budget_rc=$?
  case "$budget_rc" in
    0)
      ;;
    2)
      local existing_reason budget_path
      budget_path="$(budget_file "$repo_root")"
      existing_reason="$(jq -r '.halt_reason // "unknown"' "$budget_path")"
      log "halted ${repo_root} (reason already recorded: ${existing_reason})"
      return 0
      ;;
    1)
      local cap_name="${BUDGET_CHECK_LAST_HIT:-unknown-cap}"
      budget_halt "$repo_root" "$cap_name"
      log "halted ${repo_root} due to ${cap_name}"
      return 0
      ;;
    *)
      log "budget_check_caps returned unexpected code ${budget_rc} for ${repo_root}"
      return 1
      ;;
  esac

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
      budget_account_tokens_from_log "$repo_root" "$verifier_log_path" "verifier" || true
      # Per-stage snapshot (stage 11): capture verifier tokens against the
      # stage entry. Worker tokens may already be set from an earlier tick.
      stage_snapshot_tokens "$repo_root" "$state_yaml" "$current_stage" "$verifier_log_path" "verifier"
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
        budget_account_tokens_from_log "$repo_root" "$worker_log_path" "worker" || true
        # Per-stage snapshot (stage 11).
        stage_snapshot_tokens "$repo_root" "$state_yaml" "$current_stage" "$worker_log_path" "worker"
        state_apply_json "$state_yaml" \
          '(.stages[] | select(.id == $id)).worker_pid = null' \
          --arg id "$current_stage"
        worker_pid=""
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
        budget_account_tokens_from_log "$repo_root" "$stale_verifier_log_path" "verifier" || true
        # Per-stage snapshot (stage 11).
        stage_snapshot_tokens "$repo_root" "$state_yaml" "$current_stage" "$stale_verifier_log_path" "verifier"
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
      state_apply_json "$state_yaml" \
        '(.stages[] | select(.id == $id)).verifier_attempts = ((.stages[] | select(.id == $id) | .verifier_attempts // 0) + 1)' \
        --arg id "$current_stage"
      "$script_dir/spawn-verifier.sh" "$card_path" "$repo_root"
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
      else
        now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        state_apply_json "$state_yaml" \
          '(.stages[] | select(.id == $id)).status = "in_progress" | (.stages[] | select(.id == $id)).started_at = $now | .current_stage = $id' \
          --arg id "$next_stage" --arg now "$now_iso"
        "$script_dir/spawn-worker.sh" "$card_path" "$repo_root"
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

main "$@"

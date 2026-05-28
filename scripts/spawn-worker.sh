#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"

# Token-usage accounting (stage 10).
#
# Worker dispatch is fire-and-forget: this script backgrounds the worker
# CLI and exits immediately so the cron-driven tick loop is not blocked
# by a 30-minute run. Post-exit token parsing therefore lives in tick.sh,
# which reaps the worker via kill -0 on the recorded worker_pid and calls
# budget_account_tokens_from_log on the captured log.
#
# The parser implementation (budget_parse_tokens_from_log in budget.sh,
# sourced above) recognises both formats produced by the supported
# families:
#   - Codex two-line:  `tokens used` then a digit run (commas tolerated)
#   - Claude inline:   `Total tokens: <N>`
# grep tokens: "tokens used" "Total tokens:"

log_msg() {
  printf '%s\n' "$1" >&2
}

extract_worker_identity() {
  local card_path="$1"
  sed -n 's/^- \*\*Worker:\*\* //p' "$card_path" | head -n1
}

extract_stage_id() {
  local card_path="$1"
  local base
  base="$(basename "$card_path")"
  base="${base%.md}"
  if [[ ! "$base" =~ ^[0-9]{2}[a-z]*-[a-z0-9-]+$ ]]; then
    log_msg "rejecting malformed stage id derived from ${card_path}: ${base}"
    exit 1
  fi
  printf '%s\n' "$base"
}

worker_family() {
  local identity="$1"
  if [[ "$identity" == *Codex* || "$identity" == *GPT* ]]; then
    printf 'codex\n'
  elif [[ "$identity" == *Claude* ]]; then
    printf 'claude\n'
  else
    printf 'unknown\n'
  fi
}

claude_model_for_identity() {
  local identity="$1"
  if [[ "$identity" == *Sonnet* ]]; then
    printf 'claude-sonnet-4-6\n'
  elif [[ "$identity" == *Opus* ]]; then
    printf 'claude-opus-4-7\n'
  elif [[ "$identity" == *Haiku* ]]; then
    printf 'claude-haiku-4-5\n'
  else
    printf 'sonnet\n'
  fi
}

render_prompt() {
  local repo_root="$1"
  local card_path="$2"
  local worker_identity="$3"
  local template_path="$repo_root/templates/worker-prompt.md"
  local project_name

  if [[ ! -f "$template_path" ]]; then
    template_path="$script_dir/../templates/worker-prompt.md"
  fi
  project_name="$(basename "$repo_root")"

  sed \
    -e "s|<<worker-tier>>|${worker_identity}|g" \
    -e "s|<<project-name>>|${project_name}|g" \
    -e "s|<<orchestrator-identity>>|phat-controller|g" \
    -e "s|<<stage-card-path>>|${card_path}|g" \
    -e "s|<<family-specific-notes-or-none>>|None|g" \
    "$template_path"
}

update_stage_worker_pid() {
  local state_path="$1"
  local stage_id="$2"
  local pid="$3"

  if ! command -v yq >/dev/null 2>&1; then
    log_msg "yq missing during worker dispatch; tick should have halted before reaching here"
    exit 1
  fi
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    log_msg "refusing to write non-numeric worker_pid: ${pid}"
    exit 1
  fi
  STAGE_ID="$stage_id" PID="$pid" yq -i \
    '(.stages[] | select(.id == strenv(STAGE_ID))).worker_pid = (strenv(PID) | tonumber) | .current_stage = strenv(STAGE_ID)' \
    "$state_path"
}

main() {
  if [[ $# -ne 2 ]]; then
    log_msg "usage: $0 <stage-card-path> <repo-root>"
    exit 1
  fi

  local card_path="$1"
  local repo_root="$2"
  local state_path="$repo_root/state/state.yaml"
  local logs_dir="$repo_root/state/logs"

  mkdir -p "$logs_dir"

  local worker_identity stage_id family prompt log_path pid
  worker_identity="$(extract_worker_identity "$card_path")"
  stage_id="$(extract_stage_id "$card_path")"
  family="$(worker_family "$worker_identity")"
  prompt="$(render_prompt "$repo_root" "$card_path" "$worker_identity")"
  log_path="$logs_dir/${stage_id}-worker.log"

  # Resolve auth route via the canonical op-fetch pattern (auth-route-security
  # skill). Subscription mode emits no pairs; api mode emits NAME=$OP_REF_NAME
  # for op-fetch to resolve via the service-account token. op-fetch sanitises
  # the child env (env -i with an allowlist) so any inherited OPENAI_API_KEY /
  # ANTHROPIC_API_KEY cannot redirect billing accidentally.
  local autometta_root_local="$(cd "$script_dir/.." && pwd)"
  if [[ -f "$autometta_root_local/op-refs.sh" ]]; then
    # shellcheck source=/dev/null
    source "$autometta_root_local/op-refs.sh"
  fi
  local auth_pairs
  if ! auth_pairs="$(REPO_ROOT="$repo_root" "$script_dir/auth-route.sh" "$family")"; then
    log_msg "auth-route resolver failed for family=$family"
    exit 1
  fi
  if ! command -v op-fetch >/dev/null 2>&1; then
    log_msg "op-fetch not on PATH; required for the auth-route wrapper"
    exit 1
  fi

  # When codex is in api mode, point CODEX_HOME at a sibling auth dir whose
  # auth.json has auth_mode: "apikey". Codex prefers its auth.json over the
  # OPENAI_API_KEY env var; without this isolation, an OPENAI_API_KEY pair
  # passed via op-fetch is silently overridden by the chatgpt-mode auth at
  # ~/.codex/auth.json and the dispatch still bills the subscription. See
  # docs/lessons.md gotcha #8.
  local codex_home_override=""
  if [[ "$family" == "codex" && -n "$auth_pairs" ]]; then
    codex_home_override="${AUTOMETTA_CODEX_HOME:-$HOME/.codex-api-only}"
    if [[ ! -f "$codex_home_override/auth.json" ]]; then
      log_msg "codex api dispatch requires a sibling CODEX_HOME with auth_mode: apikey at $codex_home_override"
      log_msg "  one-time setup: mkdir -p '$codex_home_override' && chmod 700 '$codex_home_override' && \\"
      log_msg "  CODEX_HOME='$codex_home_override' codex login --with-api-key  (paste the key)"
      exit 1
    fi
  fi

  case "$family" in
    codex)
      # shellcheck disable=SC2086
      if [[ -n "$codex_home_override" ]]; then
        CODEX_HOME="$codex_home_override" op-fetch $auth_pairs --pass CODEX_HOME -- codex exec -C "$repo_root" --sandbox workspace-write "$prompt" </dev/null >"$log_path" 2>&1 &
      else
        op-fetch $auth_pairs -- codex exec -C "$repo_root" --sandbox workspace-write "$prompt" </dev/null >"$log_path" 2>&1 &
      fi
      ;;
    claude)
      # shellcheck disable=SC2086
      ( cd "$repo_root" && op-fetch $auth_pairs -- claude --model "$(claude_model_for_identity "$worker_identity")" --dangerously-skip-permissions -p "$prompt" </dev/null >"$log_path" 2>&1 ) &
      ;;
    *)
      log_msg "unsupported worker family for identity: ${worker_identity}"
      exit 1
      ;;
  esac

  pid="$!"
  # LaunchAgent tick exits after dispatch; disown prevents that SIGHUP reaching the worker subshell.
  disown "$pid" 2>/dev/null || true
  update_stage_worker_pid "$state_path" "$stage_id" "$pid"

  # Register into the per-agent liveness registry so the heartbeat watchdog
  # and the agent ticker can see this worker. Best-effort; never fatal.
  local budget_secs=0
  local budget_line
  budget_line="$(grep -E 'Worker wall-clock' "$card_path" 2>/dev/null | head -n1 || true)"
  if [[ "$budget_line" =~ ([0-9]+)[[:space:]]*(minutes?|mins?|m)([^[:alpha:]]|$) ]]; then
    budget_secs=$((${BASH_REMATCH[1]} * 60))
  elif [[ "$budget_line" =~ ([0-9]+)[[:space:]]*(seconds?|secs?|s)([^[:alpha:]]|$) ]]; then
    budget_secs="${BASH_REMATCH[1]}"
  fi
  "$script_dir/register-agent.sh" "$repo_root" "$pid" "worker" "$family" \
    "$worker_identity" "$card_path" "$log_path" "$budget_secs" >/dev/null 2>&1 || true

  printf '%s\n' "$pid"
}

main "$@"

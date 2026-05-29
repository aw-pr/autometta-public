#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"
# shellcheck source=./models.sh
source "$script_dir/models.sh"

# Token-usage accounting (stage 10).
#
# Verifier dispatch is fire-and-forget: this script backgrounds the
# verifier CLI and exits. Post-exit token parsing therefore lives in
# tick.sh, which reaps the verifier (artefact present, or verifier_pid
# from a prior tick no longer running) and calls
# budget_account_tokens_from_log on the captured verifier log.
#
# The parser handles both:
#   - Codex two-line:  `tokens used` then a digit run (commas tolerated)
#   - Claude inline:   `Total tokens: <N>`
# grep tokens: "tokens used" "Total tokens:"

log_msg() {
  printf '%s\n' "$1" >&2
}

extract_verifier_identity() {
  local card_path="$1"
  sed -n 's/^- \*\*Verifier:\*\* //p' "$card_path" | head -n1
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

verifier_family() {
  local identity="$1"
  if [[ "$identity" == *Codex* || "$identity" == *GPT* ]]; then
    printf 'codex\n'
  elif [[ "$identity" == *Claude* ]]; then
    printf 'claude\n'
  else
    printf 'unknown\n'
  fi
}

render_prompt() {
  local repo_root="$1"
  local card_path="$2"
  local stage_id="$3"
  local verifier_identity="$4"
  local artefact_path="$5"
  local template_path="$repo_root/templates/verifier-prompt.md"

  if [[ ! -f "$template_path" ]]; then
    template_path="$script_dir/../templates/verifier-prompt.md"
  fi

  sed \
    -e "s|<<stage-id>>|${stage_id}|g" \
    -e "s|<<stage-card-path>>|${card_path}|g" \
    -e "s|<<artefact-path>>|${artefact_path}|g" \
    -e "s|<<verifier-tier>>|${verifier_identity}|g" \
    -e "s|<<orchestrator-identity>>|phat-controller|g" \
    -e "s|<<family-specific-notes-or-none>>|None|g" \
    "$template_path"
}

# Resolve the claude verifier transport (sdk | cli).
# Resolution order (most specific wins):
#   1. AUTOMETTA_CLAUDE_TRANSPORT env var override
#   2. verifier.claude.transport in <repo>/.autometta.local.yaml
#   3. default: cli
# Prints: "<transport> <provenance>"
resolve_claude_transport() {
  local repo_root="$1"
  local manifest="$repo_root/.autometta.local.yaml"
  local transport="" provenance="default"

  if [[ -n "${AUTOMETTA_CLAUDE_TRANSPORT:-}" ]]; then
    transport="${AUTOMETTA_CLAUDE_TRANSPORT}"
    provenance="env"
  elif [[ -f "$manifest" ]] && command -v yq >/dev/null 2>&1; then
    local from_manifest
    from_manifest="$(yq -r '.verifier.claude.transport // ""' "$manifest" 2>/dev/null || true)"
    if [[ -n "$from_manifest" ]]; then
      transport="$from_manifest"
      provenance="manifest"
    fi
  fi

  printf '%s %s\n' "${transport:-cli}" "$provenance"
}

# Derive a best-effort artefact glob from the ## Deliverables section of a card.
# Extracts backtick-quoted file paths, takes unique parent directories, and
# returns a single pattern for Python's glob.glob (no brace expansion).
derive_artefact_glob() {
  local card_path="$1"
  local dirs
  dirs="$(awk '/^## Deliverables/{f=1;next} /^## /{f=0} f' "$card_path" \
    | grep -o '`[^` ]*`' | tr -d '`' \
    | while IFS= read -r p; do
        d="${p%/*}"
        [[ "$d" == "$p" ]] && d="."
        printf '%s\n' "$d"
      done \
    | sort -u)"

  local ndirs
  ndirs="$(printf '%s\n' "$dirs" | grep -c . 2>/dev/null || echo 0)"

  if [[ "$ndirs" -eq 1 && "$dirs" != "." ]]; then
    printf '%s/**\n' "$dirs"
  else
    # Multiple or root-level deliverables: broad recursive glob.
    # Python's glob.glob does not support brace expansion prior to 3.13.
    printf '**\n'
  fi
}

update_verifier_state() {
  local state_path="$1"
  local stage_id="$2"
  local pid="$3"
  local artefact="$4"

  if ! command -v yq >/dev/null 2>&1; then
    log_msg "yq missing during verifier dispatch; tick should have halted before reaching here"
    exit 1
  fi
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    log_msg "refusing to write non-numeric verifier_pid: ${pid}"
    exit 1
  fi
  STAGE_ID="$stage_id" PID="$pid" ARTEFACT="$artefact" yq -i \
    '(.stages[] | select(.id == strenv(STAGE_ID))).verifier_pid = (strenv(PID) | tonumber) | (.stages[] | select(.id == strenv(STAGE_ID))).verifier_artefact = strenv(ARTEFACT)' \
    "$state_path"
}

is_panel_mode() {
  local card_path="$1"
  # Check env override first.
  if [[ "${AUTOMETTA_VERIFIER_PANEL:-}" == "1" ]]; then
    return 0
  fi
  # Check card metadata: "- **Verifier panel:** true"
  if grep -qiE '^\s*-\s*\*\*Verifier panel:\*\*\s*true' "$card_path" 2>/dev/null; then
    return 0
  fi
  return 1
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
  local verifiers_dir="$repo_root/state/verifiers"

  mkdir -p "$logs_dir" "$verifiers_dir"

  # Panel mode: delegate to spawn-verifier-panel.sh.
  if is_panel_mode "$card_path"; then
    local panel_script
    panel_script="$(dirname "${BASH_SOURCE[0]}")/spawn-verifier-panel.sh"
    if [[ ! -x "$panel_script" ]]; then
      log_msg "spawn-verifier-panel.sh not found or not executable at $panel_script"
      exit 1
    fi
    log_msg "verifier: panel mode enabled — delegating to spawn-verifier-panel.sh"
    exec "$panel_script" "$card_path" "$repo_root"
  fi

  local verifier_identity stage_id family log_path artefact_path pid prompt
  local claude_transport="cli" claude_transport_provenance="default"
  verifier_identity="$(extract_verifier_identity "$card_path")"
  stage_id="$(extract_stage_id "$card_path")"
  family="$(verifier_family "$verifier_identity")"
  log_path="$logs_dir/${stage_id}-verifier.log"
  artefact_path="state/verifiers/${stage_id}.json"
  prompt="$(render_prompt "$repo_root" "$card_path" "$stage_id" "$verifier_identity" "$artefact_path")"

  # Resolve auth route via op-fetch (auth-route-security skill). Same model
  # as spawn-worker.sh: subscription emits no pairs (op-fetch still sanitises
  # env via env -i + allowlist); api mode emits NAME=$OP_REF_NAME.
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

  # Resolve claude verifier transport after auth route is known.
  if [[ "$family" == "claude" ]]; then
    local transport_result
    transport_result="$(resolve_claude_transport "$repo_root")"
    claude_transport="${transport_result%% *}"
    claude_transport_provenance="${transport_result#* }"
    case "$claude_transport" in
      cli|sdk) ;;
      *)
        log_msg "verifier-transport: invalid value ${claude_transport} (expected cli | sdk)"
        exit 1
        ;;
    esac
  fi

  # Sibling CODEX_HOME for api mode (see spawn-worker.sh + docs/lessons.md
  # gotcha #8 — codex prefers its auth.json over OPENAI_API_KEY).
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
      # Fail closed: sdk transport requires api mode (ANTHROPIC_API_KEY must be in auth_pairs).
      if [[ "$claude_transport" == "sdk" && "$auth_pairs" != *ANTHROPIC_API_KEY* ]]; then
        log_msg "verifier-transport: fail-closed; verifier.claude.transport=sdk requires auth.claude.mode=api"
        log_msg "  set auth.claude.mode: api in .autometta.local.yaml or export AUTOMETTA_CLAUDE_MODE=api"
        exit 1
      fi

      # Fall back to cli if verify-sdk.py is missing.
      local sdk_script="$script_dir/verify-sdk.py"
      if [[ "$claude_transport" == "sdk" && ! -f "$sdk_script" ]]; then
        log_msg "verifier-transport: warning; $sdk_script not found; falling back to cli"
        claude_transport="cli"
        claude_transport_provenance="default"
      fi

      log_msg "verifier-transport: ${claude_transport} (provenance: ${claude_transport_provenance})"

      if [[ "$claude_transport" == "sdk" ]]; then
        local artefact_glob sdk_out
        artefact_glob="$(derive_artefact_glob "$card_path")"
        sdk_out="$repo_root/$artefact_path"
        # shellcheck disable=SC2086
        ( cd "$repo_root" && op-fetch $auth_pairs -- \
            python3 "$sdk_script" \
              --stage-id "$stage_id" \
              --card "$card_path" \
              --artefact-glob "$artefact_glob" \
              --out "$sdk_out" \
            </dev/null >"$log_path" 2>&1 ) &
      else
        # shellcheck disable=SC2086
        ( cd "$repo_root" && op-fetch $auth_pairs -- claude --model "$(claude_model_for_identity "$verifier_identity")" --dangerously-skip-permissions -p "$prompt" </dev/null >"$log_path" 2>&1 ) &
      fi
      ;;
    *)
      log_msg "unsupported verifier family for identity: ${verifier_identity}"
      exit 1
      ;;
  esac

  pid="$!"
  # LaunchAgent tick exits after dispatch; disown prevents that SIGHUP reaching the verifier subshell.
  disown "$pid" 2>/dev/null || true
  update_verifier_state "$state_path" "$stage_id" "$pid" "$artefact_path"

  # Register into the per-agent liveness registry. Best-effort.
  local budget_secs=0
  local budget_line
  budget_line="$(grep -E 'Verifier wall-clock' "$card_path" 2>/dev/null | head -n1 || true)"
  if [[ "$budget_line" =~ ([0-9]+)[[:space:]]*(minutes?|mins?|m)([^[:alpha:]]|$) ]]; then
    budget_secs=$((${BASH_REMATCH[1]} * 60))
  elif [[ "$budget_line" =~ ([0-9]+)[[:space:]]*(seconds?|secs?|s)([^[:alpha:]]|$) ]]; then
    budget_secs="${BASH_REMATCH[1]}"
  fi
  "$script_dir/register-agent.sh" "$repo_root" "$pid" "verifier" "$family" \
    "$verifier_identity" "$card_path" "$log_path" "$budget_secs" >/dev/null 2>&1 || true

  printf '%s\n' "$pid"
}

main "$@"

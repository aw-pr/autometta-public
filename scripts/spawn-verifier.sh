#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
# shellcheck source=resolve-root.sh
source "$script_dir/resolve-root.sh"
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

extract_verifier_effort() {
  local card_path="$1"
  sed -n 's/^- \*\*Verifier effort:\*\* //p' "$card_path" | head -n1
}

extract_requires_gui() {
  local card_path="$1"
  sed -n 's/^- \*\*Requires GUI:\*\* //p' "$card_path" | head -n1
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
  local family_notes="${6:-None}"
  local template_path="$repo_root/templates/verifier-prompt.md"

  if [[ ! -f "$template_path" ]]; then
    template_path="$script_dir/../templates/verifier-prompt.md"
  fi

  # family_notes carries free text the worker wrote and may contain sed's
  # delimiter, an ampersand, or a backslash. Flatten to one line and escape
  # before it goes into a replacement.
  family_notes="${family_notes//$'\n'/ }"
  family_notes="${family_notes//\\/\\\\}"
  family_notes="${family_notes//&/\\&}"
  family_notes="${family_notes//|/\\|}"

  sed \
    -e "s|<<stage-id>>|${stage_id}|g" \
    -e "s|<<stage-card-path>>|${card_path}|g" \
    -e "s|<<artefact-path>>|${artefact_path}|g" \
    -e "s|<<verifier-tier>>|${verifier_identity}|g" \
    -e "s|<<orchestrator-identity>>|phat-controller|g" \
    -e "s|<<family-specific-notes-or-none>>|${family_notes}|g" \
    "$template_path"
}

# resolve_family_notes: when the worker's handoff envelope for this stage
# reports status=partial, hand its notes to the verifier as an explicit
# checklist. status=pass, or a missing or unreadable envelope (the
# pre-stage-17 legacy path), falls back to "None" -- byte-identical to the
# previously hardcoded value.
#
# Reads the envelope off disk rather than taking it as an argument so the
# run worktree's state symlink is the single source: tick.sh has already
# validated this file against the schema before dispatching here.
resolve_family_notes() {
  local repo_root="$1"
  local stage_id="$2"
  local envelope_path="$repo_root/state/handoffs/${stage_id}.json"
  if [[ -f "$envelope_path" ]] && command -v jq >/dev/null 2>&1 && jq empty "$envelope_path" 2>/dev/null; then
    local env_status env_notes
    env_status="$(jq -r '.status // empty' "$envelope_path" 2>/dev/null || true)"
    if [[ "$env_status" == "partial" ]]; then
      env_notes="$(jq -r '.notes // empty' "$envelope_path" 2>/dev/null || true)"
      printf 'The worker self-reported incomplete acceptance (handoff envelope status=partial) — treat the deferred criteria as your checklist and decide acceptability yourself; partial is the worker'"'"'s annotation, not a verdict. Worker notes: %s' \
        "${env_notes:-(none provided)}"
      return 0
    fi
  fi
  printf 'None'
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

# Resolve the optional claude verifier advisor model (Fable-as-advisor).
# Resolution order (most specific wins):
#   1. AUTOMETTA_CLAUDE_ADVISOR env var override
#   2. verifier.claude.advisor in <repo>/.autometta.local.yaml
#   3. default: empty (advisor off; behaviour byte-identical to today)
# The advisor sits under the sdk branch only and inherits its auth.claude.mode:
# api gate; verify-sdk.py enforces the #66714 ordering precondition locally.
# Prints: "<advisor-model-or-empty>"
resolve_claude_advisor() {
  local repo_root="$1"
  local manifest="$repo_root/.autometta.local.yaml"
  local advisor=""

  if [[ -n "${AUTOMETTA_CLAUDE_ADVISOR:-}" ]]; then
    advisor="${AUTOMETTA_CLAUDE_ADVISOR}"
  elif [[ -f "$manifest" ]] && command -v yq >/dev/null 2>&1; then
    advisor="$(yq -r '.verifier.claude.advisor // ""' "$manifest" 2>/dev/null || true)"
  fi

  printf '%s\n' "$advisor"
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
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    log_msg "usage: $0 <stage-card-path> <repo-root> [work-dir]"
    exit 1
  fi

  local card_path="$1"
  local repo_root="$2"
  # work_dir is where the verifier reads the dirty tree it evaluates -- the
  # stage's run worktree under worktree-per-run dispatch, or repo_root for a
  # caller that has not adopted it yet. state/logs/verifiers always stay
  # anchored to repo_root; only the agent's CWD moves.
  local work_dir="${3:-$repo_root}"
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
  local effort
  verifier_identity="$(extract_verifier_identity "$card_path")"
  stage_id="$(extract_stage_id "$card_path")"
  family="$(verifier_family "$verifier_identity")"
  effort="$(extract_verifier_effort "$card_path")"
  effort_argv_for_family "$family" "$effort"
  if [[ ${#AUTOMETTA_EFFORT_ARGV[@]} -gt 0 ]]; then
    log_msg "verifier effort: ${effort} (${stage_id})"
  fi
  local requires_gui codex_sandbox
  requires_gui="$(extract_requires_gui "$card_path")"
  codex_sandbox="$(resolve_codex_sandbox_for_card "$repo_root" "$requires_gui")"
  if [[ "$codex_sandbox" == "danger-full-access" ]]; then
    log_msg "verifier runs codex unsandboxed: card declares Requires GUI (${stage_id})"
  fi
  codex_state_argv_for_repo "$repo_root"
  log_path="$logs_dir/${stage_id}-verifier.log"
  artefact_path="state/verifiers/${stage_id}.json"
  local family_notes
  family_notes="$(resolve_family_notes "$work_dir" "$stage_id")"
  prompt="$(render_prompt "$work_dir" "$card_path" "$stage_id" "$verifier_identity" "$artefact_path" "$family_notes")"

  # Resolve auth route via op-fetch (auth-route-security skill). Same model
  # as spawn-worker.sh: subscription emits no pairs (op-fetch still sanitises
  # env via env -i + allowlist); api mode emits NAME=$OP_REF_NAME.
  local autometta_root_local
  # Self root: op-refs.sh sits beside this script, in whichever tree it is.
  autometta_root_local="$(autometta_self_root "$script_dir")"
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
  # gotcha #8: codex prefers its auth.json over OPENAI_API_KEY). auth_pairs
  # is empty for both subscription and local, so this gate naturally never
  # fires on the local route: local needs no key, and demanding the sibling
  # here would fail a route whose whole point is that it needs no key.
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

  local codex_mode=""
  if [[ "$family" == "codex" ]]; then
    if ! codex_mode="$(REPO_ROOT="$repo_root" "$script_dir/auth-route.sh" codex --print-mode)"; then
      log_msg "auth-route mode resolution failed for family=codex"
      exit 1
    fi
  fi

  case "$family" in
    codex)
      if [[ "$codex_mode" == "local" ]]; then
        # Fail closed before spawn: a dispatch that dies after model
        # negotiation with Ollama burns a verifier attempt on infrastructure.
        if ! codex_local_preflight "$AUTOMETTA_MODEL_CODEX_LOCAL"; then
          exit 1
        fi
        # shellcheck disable=SC2086
        op-fetch $auth_pairs -- codex exec --oss --local-provider=ollama -m "$AUTOMETTA_MODEL_CODEX_LOCAL" -C "$work_dir" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --sandbox "$codex_sandbox" ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$prompt" </dev/null >"$log_path" 2>&1 &
      elif [[ -n "$codex_home_override" ]]; then
        # shellcheck disable=SC2086
        CODEX_HOME="$codex_home_override" op-fetch $auth_pairs --pass CODEX_HOME -- codex exec -C "$work_dir" --model "$AUTOMETTA_MODEL_CODEX" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --sandbox "$codex_sandbox" ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$prompt" </dev/null >"$log_path" 2>&1 &
      else
        # shellcheck disable=SC2086
        op-fetch $auth_pairs -- codex exec -C "$work_dir" --model "$AUTOMETTA_MODEL_CODEX" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --sandbox "$codex_sandbox" ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$prompt" </dev/null >"$log_path" 2>&1 &
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
        local artefact_glob sdk_out claude_advisor advisor_arg notes_arg
        artefact_glob="$(derive_artefact_glob "$card_path")"
        sdk_out="$repo_root/$artefact_path"
        claude_advisor="$(resolve_claude_advisor "$repo_root")"
        advisor_arg=()
        if [[ -n "$claude_advisor" ]]; then
          advisor_arg=(--advisor "$claude_advisor")
          log_msg "verifier-advisor: ${claude_advisor} (Fable-as-advisor; request model does the reading)"
        fi
        # The sdk transport builds its own prompt, so the cli path's
        # family-specific-notes substitution never reaches it. Pass a partial
        # worker envelope's notes explicitly; verify-sdk.py puts them in the
        # variable block, leaving the cacheable prefix untouched.
        notes_arg=()
        if [[ "$family_notes" != "None" ]]; then
          notes_arg=(--worker-notes "$family_notes")
        fi
        # shellcheck disable=SC2086
        ( cd "$work_dir" && op-fetch $auth_pairs -- \
            python3 "$sdk_script" \
              --stage-id "$stage_id" \
              --card "$card_path" \
              --artefact-glob "$artefact_glob" \
              --out "$sdk_out" \
              --model "$(claude_model_for_identity "$verifier_identity")" \
              ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} \
              ${advisor_arg[@]+"${advisor_arg[@]}"} \
              ${notes_arg[@]+"${notes_arg[@]}"} \
            </dev/null >"$log_path" 2>&1 ) &
      else
        # JSON output + claude-token-log.sh restore the "Total tokens:"
        # line the budget parser needs; see spawn-worker.sh claude branch.
        # shellcheck disable=SC2086
        ( cd "$work_dir" && op-fetch $auth_pairs -- claude --model "$(claude_model_for_identity "$verifier_identity")" ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} --dangerously-skip-permissions --output-format json -p "$prompt" </dev/null 2>"$log_path" | "$script_dir/claude-token-log.sh" >>"$log_path" ) 2>>"$log_path" &
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
    "$verifier_identity" "$card_path" "$log_path" "$budget_secs" "$work_dir" >/dev/null 2>&1 || true

  printf '%s\n' "$pid"
}

main "$@"

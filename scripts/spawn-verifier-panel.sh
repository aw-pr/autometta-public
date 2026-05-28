#!/usr/bin/env bash
# spawn-verifier-panel.sh: dispatch N=3 verifiers in parallel and synthesise
# a majority-vote result.
#
# Args: <stage-card-path> <repo-root> [--read-only]
#
# --read-only: write panellist artefacts to a temp dir, print synthesis JSON
#              to stdout, do not mutate state.yaml. Used by autometta panel.
#
# Fixed panel composition for v1:
#   panel-0: Claude Opus 4.7  via SDK (scripts/verify-sdk.py --model claude-opus-4-7)
#   panel-1: Claude Sonnet 4.6 via SDK (scripts/verify-sdk.py --model claude-sonnet-4-6)
#   panel-2: Codex GPT-5.3    via codex exec
#
# Requires: auth.claude.mode: api (ANTHROPIC_API_KEY must be in claude auth_pairs).
# A panellist crash (no artefact returned) counts as no-vote.
# Quorum = 2 of 3; if fewer than 2 panellists return artefacts the stage stalls.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"

PANELLIST_OPUS="Claude Opus 4.7 <claude-opus-4-7@local>"
PANELLIST_SONNET="Claude Sonnet 4.6 <claude-sonnet-4-6@local>"
PANELLIST_CODEX="Codex GPT-5.3 <codex-gpt-5-3@local>"

QUORUM_REQUIRED=2
POLL_INTERVAL=10

log_msg() { printf '%s\n' "$1" >&2; }

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
    printf '**\n'
  fi
}

budget_secs_from_card() {
  local card_path="$1"
  local budget_line budget_secs=0
  budget_line="$(grep -E 'Verifier wall-clock' "$card_path" 2>/dev/null | head -n1 || true)"
  if [[ "$budget_line" =~ ([0-9]+)[[:space:]]*(minutes?|mins?|m)([^[:alpha:]]|$) ]]; then
    budget_secs=$((${BASH_REMATCH[1]} * 60))
  elif [[ "$budget_line" =~ ([0-9]+)[[:space:]]*(seconds?|secs?|s)([^[:alpha:]]|$) ]]; then
    budget_secs="${BASH_REMATCH[1]}"
  fi
  printf '%s\n' "$budget_secs"
}

main() {
  local read_only=0
  local card_path="" repo_root=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --read-only) read_only=1 ;;
      *)
        if [[ -z "$card_path" ]]; then
          card_path="$1"
        elif [[ -z "$repo_root" ]]; then
          repo_root="$1"
        else
          log_msg "unexpected argument: $1"
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [[ -z "$card_path" || -z "$repo_root" ]]; then
    log_msg "usage: $0 <stage-card-path> <repo-root> [--read-only]"
    exit 1
  fi

  local stage_id
  stage_id="$(extract_stage_id "$card_path")"
  local artefact_glob
  artefact_glob="$(derive_artefact_glob "$card_path")"

  local logs_dir="$repo_root/state/logs"
  mkdir -p "$logs_dir"

  # Resolve auth routes via op-fetch auth-route-security pattern.
  local autometta_root
  autometta_root="$(cd "$script_dir/.." && pwd)"
  if [[ -f "$autometta_root/op-refs.sh" ]]; then
    # shellcheck source=/dev/null
    source "$autometta_root/op-refs.sh"
  fi

  local claude_auth_pairs codex_auth_pairs
  if ! claude_auth_pairs="$(REPO_ROOT="$repo_root" "$script_dir/auth-route.sh" claude)"; then
    log_msg "auth-route resolver failed for family=claude"
    exit 1
  fi
  if ! codex_auth_pairs="$(REPO_ROOT="$repo_root" "$script_dir/auth-route.sh" codex)"; then
    log_msg "auth-route resolver failed for family=codex"
    exit 1
  fi

  if ! command -v op-fetch >/dev/null 2>&1; then
    log_msg "op-fetch not on PATH; required for auth-route dispatch"
    exit 1
  fi

  # Fail closed: SDK required for Claude panellists.
  if [[ "$claude_auth_pairs" != *ANTHROPIC_API_KEY* ]]; then
    log_msg "panel mode requires auth.claude.mode: api (ANTHROPIC_API_KEY must be available)"
    log_msg "  set auth.claude.mode: api in .autometta.local.yaml or export AUTOMETTA_CLAUDE_MODE=api"
    exit 1
  fi

  local sdk_script="$script_dir/verify-sdk.py"
  if [[ ! -f "$sdk_script" ]]; then
    log_msg "verify-sdk.py not found at $sdk_script"
    exit 1
  fi

  # Determine artefact output paths.
  local panel_dir synth_path tmp_panel_dir=""
  if [[ $read_only -eq 1 ]]; then
    tmp_panel_dir="$(mktemp -d)"
    panel_dir="$tmp_panel_dir"
    synth_path="$tmp_panel_dir/synthesis.json"
  else
    panel_dir="$repo_root/state/verifiers/${stage_id}.panel"
    synth_path="$repo_root/state/verifiers/${stage_id}.json"
    mkdir -p "$panel_dir"
  fi

  local p0_out="$panel_dir/opus.json"
  local p1_out="$panel_dir/sonnet.json"
  local p2_out="$panel_dir/codex.json"
  local p0_log="$logs_dir/${stage_id}-panel-0.log"
  local p1_log="$logs_dir/${stage_id}-panel-1.log"
  local p2_log="$logs_dir/${stage_id}-panel-2.log"

  log_msg "panel: dispatching 3 verifiers for stage ${stage_id}"

  # Panellist 0: Opus via SDK.
  # shellcheck disable=SC2086
  ( cd "$repo_root" && op-fetch $claude_auth_pairs -- \
      python3 "$sdk_script" \
        --stage-id "$stage_id" \
        --card "$card_path" \
        --artefact-glob "$artefact_glob" \
        --out "$p0_out" \
        --model claude-opus-4-7 \
      </dev/null >"$p0_log" 2>&1 ) &
  local p0_pid=$!

  # Panellist 1: Sonnet via SDK.
  # shellcheck disable=SC2086
  ( cd "$repo_root" && op-fetch $claude_auth_pairs -- \
      python3 "$sdk_script" \
        --stage-id "$stage_id" \
        --card "$card_path" \
        --artefact-glob "$artefact_glob" \
        --out "$p1_out" \
        --model claude-sonnet-4-6 \
      </dev/null >"$p1_log" 2>&1 ) &
  local p1_pid=$!

  # Panellist 2: Codex via CLI. The verifier prompt tells Codex to write the
  # JSON artefact directly to p2_out (workspace-write sandbox allows it).
  local codex_prompt
  local tmpl="$repo_root/templates/verifier-prompt.md"
  [[ -f "$tmpl" ]] || tmpl="$autometta_root/templates/verifier-prompt.md"
  codex_prompt="$(sed \
    -e "s|<<stage-id>>|${stage_id}|g" \
    -e "s|<<stage-card-path>>|${card_path}|g" \
    -e "s|<<artefact-path>>|${p2_out}|g" \
    -e "s|<<verifier-tier>>|${PANELLIST_CODEX}|g" \
    -e "s|<<orchestrator-identity>>|spawn-verifier-panel.sh|g" \
    -e "s|<<family-specific-notes-or-none>>|Write the verifier artefact JSON to the artefact-path shown above. stdin redirect already applied.|g" \
    "$tmpl")"

  local codex_home_override=""
  if [[ -n "$codex_auth_pairs" ]]; then
    codex_home_override="${AUTOMETTA_CODEX_HOME:-$HOME/.codex-api-only}"
    if [[ ! -f "$codex_home_override/auth.json" ]]; then
      log_msg "panel: codex api dispatch requires sibling CODEX_HOME at $codex_home_override"
      kill "$p0_pid" "$p1_pid" 2>/dev/null || true
      exit 1
    fi
    # shellcheck disable=SC2086
    CODEX_HOME="$codex_home_override" op-fetch $codex_auth_pairs --pass CODEX_HOME -- \
      codex exec -C "$repo_root" --sandbox workspace-write "$codex_prompt" \
      </dev/null >"$p2_log" 2>&1 &
  else
    # shellcheck disable=SC2086
    op-fetch $codex_auth_pairs -- \
      codex exec -C "$repo_root" --sandbox workspace-write "$codex_prompt" \
      </dev/null >"$p2_log" 2>&1 &
  fi
  local p2_pid=$!

  log_msg "panel: pids opus=${p0_pid} sonnet=${p1_pid} codex=${p2_pid}"

  # Register all three into the liveness registry.
  local budget_secs
  budget_secs="$(budget_secs_from_card "$card_path")"
  [[ "$budget_secs" -eq 0 ]] && budget_secs=2700  # default 45 min

  "$script_dir/register-agent.sh" "$repo_root" "$p0_pid" verifier claude \
    "$PANELLIST_OPUS" "$card_path" "$p0_log" "$budget_secs" >/dev/null 2>&1 || true
  "$script_dir/register-agent.sh" "$repo_root" "$p1_pid" verifier claude \
    "$PANELLIST_SONNET" "$card_path" "$p1_log" "$budget_secs" >/dev/null 2>&1 || true
  "$script_dir/register-agent.sh" "$repo_root" "$p2_pid" verifier codex \
    "$PANELLIST_CODEX" "$card_path" "$p2_log" "$budget_secs" >/dev/null 2>&1 || true

  # Poll for all three artefacts until budget_secs deadline.
  local deadline=$(( $(date +%s) + budget_secs ))
  local p0_done=0 p1_done=0 p2_done=0

  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    [[ -f "$p0_out" ]] && p0_done=1
    [[ -f "$p1_out" ]] && p1_done=1
    [[ -f "$p2_out" ]] && p2_done=1

    # Treat a dead process with no artefact as a crash (no-vote).
    if [[ $p0_done -eq 0 ]] && ! kill -0 "$p0_pid" 2>/dev/null; then
      [[ -f "$p0_out" ]] && p0_done=1 || p0_done=2
    fi
    if [[ $p1_done -eq 0 ]] && ! kill -0 "$p1_pid" 2>/dev/null; then
      [[ -f "$p1_out" ]] && p1_done=1 || p1_done=2
    fi
    if [[ $p2_done -eq 0 ]] && ! kill -0 "$p2_pid" 2>/dev/null; then
      [[ -f "$p2_out" ]] && p2_done=1 || p2_done=2
    fi

    if [[ $p0_done -ne 0 && $p1_done -ne 0 && $p2_done -ne 0 ]]; then
      break
    fi
    sleep "$POLL_INTERVAL"
  done

  # Kill any still-running panellists after deadline.
  kill "$p0_pid" "$p1_pid" "$p2_pid" 2>/dev/null || true

  # Final artefact presence check after kill.
  [[ -f "$p0_out" ]] && p0_done=1
  [[ -f "$p1_out" ]] && p1_done=1
  [[ -f "$p2_out" ]] && p2_done=1

  # Tally votes.
  local pass_count=0 fail_count=0 votes_received=0
  local p0_overall="" p1_overall="" p2_overall=""

  if [[ $p0_done -eq 1 ]]; then
    p0_overall="$(jq -r '.overall // ""' "$p0_out" 2>/dev/null || true)"
    case "$p0_overall" in
      PASS) pass_count=$((pass_count + 1)); votes_received=$((votes_received + 1)) ;;
      FAIL) fail_count=$((fail_count + 1)); votes_received=$((votes_received + 1)) ;;
    esac
  fi

  if [[ $p1_done -eq 1 ]]; then
    p1_overall="$(jq -r '.overall // ""' "$p1_out" 2>/dev/null || true)"
    case "$p1_overall" in
      PASS) pass_count=$((pass_count + 1)); votes_received=$((votes_received + 1)) ;;
      FAIL) fail_count=$((fail_count + 1)); votes_received=$((votes_received + 1)) ;;
    esac
  fi

  if [[ $p2_done -eq 1 ]]; then
    p2_overall="$(jq -r '.overall // ""' "$p2_out" 2>/dev/null || true)"
    case "$p2_overall" in
      PASS) pass_count=$((pass_count + 1)); votes_received=$((votes_received + 1)) ;;
      FAIL) fail_count=$((fail_count + 1)); votes_received=$((votes_received + 1)) ;;
    esac
  fi

  log_msg "panel: pass=${pass_count} fail=${fail_count} no-vote=$((3 - votes_received))"

  # Check quorum and majority.
  # Quorum: minimum 2 of 3 panellists must return artefacts.
  # Majority: pass_count must strictly exceed fail_count.
  # A tie (pass_count == fail_count) with a crash stalls — no casting vote.
  local stall=0
  if [[ $votes_received -lt $QUORUM_REQUIRED ]]; then
    stall=1
    log_msg "panel: quorum not met (${votes_received}/${QUORUM_REQUIRED} votes received) — stalling"
  elif [[ $pass_count -eq $fail_count ]]; then
    stall=1
    log_msg "panel: split vote (${pass_count}P/${fail_count}F with crash) — no majority — stalling"
  fi

  if [[ $stall -eq 1 ]]; then
    if [[ $read_only -eq 0 ]] && command -v yq >/dev/null 2>&1; then
      local state_path="$repo_root/state/state.yaml"
      if [[ -f "$state_path" ]]; then
        STAGE_ID="$stage_id" yq -i \
          '(.stages[] | select(.id == strenv(STAGE_ID))).status = "verifier_panel_no_quorum"' \
          "$state_path"
      fi
    fi
    [[ -n "$tmp_panel_dir" ]] && rm -rf "$tmp_panel_dir" || true
    exit 2
  fi

  local overall
  [[ $pass_count -gt $fail_count ]] && overall="PASS" || overall="FAIL"
  log_msg "panel: synthesised result = ${overall}"

  # Build panellists JSON array.
  local panellists_json
  panellists_json="$(jq -n \
    --arg id0 "$PANELLIST_OPUS"   --arg ap0 "$p0_out" --arg ov0 "$p0_overall" \
    --arg id1 "$PANELLIST_SONNET" --arg ap1 "$p1_out" --arg ov1 "$p1_overall" \
    --arg id2 "$PANELLIST_CODEX"  --arg ap2 "$p2_out" --arg ov2 "$p2_overall" \
    '[
       {id: 0, identity: $id0, artefact_path: (if $ap0 == "" then null else $ap0 end), overall: (if $ov0 == "" then null else $ov0 end)},
       {id: 1, identity: $id1, artefact_path: (if $ap1 == "" then null else $ap1 end), overall: (if $ov1 == "" then null else $ov1 end)},
       {id: 2, identity: $id2, artefact_path: (if $ap2 == "" then null else $ap2 end), overall: (if $ov2 == "" then null else $ov2 end)}
     ]')"

  # Source criteria from the first available panellist artefact.
  local criteria_json="[]" additional_findings="Panel synthesis — see panellist artefacts."
  for src in "$p0_out" "$p1_out" "$p2_out"; do
    if [[ -f "$src" ]]; then
      criteria_json="$(jq '.criteria // []' "$src" 2>/dev/null || echo "[]")"
      local raw_findings
      raw_findings="$(jq -r '.additional_findings // ""' "$src" 2>/dev/null || true)"
      additional_findings="[Panel synthesis — majority ${overall}] ${raw_findings}"
      break
    fi
  done

  local ran_at
  ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq -n \
    --arg stage_id   "$stage_id" \
    --arg identity   "spawn-verifier-panel.sh <panel@local>" \
    --arg invocation "spawn-verifier-panel.sh ${card_path} ${repo_root}" \
    --arg ran_at     "$ran_at" \
    --argjson criteria    "$criteria_json" \
    --arg findings        "$additional_findings" \
    --arg overall         "$overall" \
    --argjson panellists  "$panellists_json" \
    --argjson quorum_req  "$QUORUM_REQUIRED" \
    --argjson votes       "$votes_received" \
    '{
      stage_id:           $stage_id,
      verifier_identity:  $identity,
      verifier_invocation: $invocation,
      ran_at:             $ran_at,
      criteria:           $criteria,
      additional_findings: $findings,
      overall:            $overall,
      panellists:         $panellists,
      quorum: {required: $quorum_req, achieved: $votes}
    }' > "$synth_path"

  # Token accounting for AC7: record each panellist's cost separately, then
  # write a zero-token synthesis log so tick.sh's subsequent accounting pass
  # adds nothing. budget_account_tokens_from_log is available via budget.sh.
  if [[ $read_only -eq 0 ]]; then
    for plog in "$p0_log" "$p1_log" "$p2_log"; do
      budget_account_tokens_from_log "$repo_root" "$plog" "verifier" || true
    done
    # Synthesis log with zero tokens — tick.sh reads this path.
    local synth_log="$logs_dir/${stage_id}-verifier.log"
    printf '# panel synthesis (no LLM call)\nTotal tokens: 0\n' > "$synth_log"
  fi

  if [[ $read_only -eq 1 ]]; then
    cat "$synth_path"
    rm -rf "$tmp_panel_dir"
  else
    # Update state.yaml verifier_artefact to the synthesised path.
    if command -v yq >/dev/null 2>&1; then
      local state_path="$repo_root/state/state.yaml"
      if [[ -f "$state_path" ]]; then
        local artefact_rel="state/verifiers/${stage_id}.json"
        STAGE_ID="$stage_id" ARTEFACT="$artefact_rel" yq -i \
          '(.stages[] | select(.id == strenv(STAGE_ID))).verifier_artefact = strenv(ARTEFACT)' \
          "$state_path"
      fi
    fi
  fi

  [[ "$overall" == "PASS" ]] && exit 0 || exit 1
}

main "$@"

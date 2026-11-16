#!/usr/bin/env bash
# spawn-verifier-panel.sh: dispatch N=3 verifiers in parallel and synthesise
# a majority-vote result.
#
# Args: <stage-card-path> <repo-root> [--work-dir <dir>] [--read-only]
#
# --work-dir:  the tree the panellists verify, normally the stage's run
#              worktree (spawn-verifier.sh passes it). Defaults to repo-root.
#              Artefacts and logs stay under <repo-root>/state either way.
# --read-only: run synchronously, write panellist artefacts to a temp dir,
#              print the synthesis JSON to stdout and exit 0 for PASS, 1 for a
#              FAIL majority, 2 for no quorum or a tie. Never writes
#              state.yaml, budget.json or the canonical artefact. Used by
#              autometta panel.
#
# Without --read-only (the tick): every preflight runs in the foreground, then
# the panel starts as a disowned background process in its own process group,
# which is recorded as the stage's verifier_pid and registered, and this
# script exits 0. The background panel writes only panellist artefacts and
# logs, the synthesis artefact state/verifiers/<id>.json and the synthesis log
# state/logs/<id>-verifier.log, whose one `Total tokens:` line is the sum of
# the panellists. The tick charges that sum when it consumes the synthesis.
#
# Fixed panel composition for v1:
#   panel-0: Claude Opus 5   via SDK (scripts/verify-sdk.py --model claude-opus-5)
#   panel-1: Claude Sonnet 5.5 via SDK (scripts/verify-sdk.py --model claude-sonnet-5-5)
#   panel-2: current GPT Sol via codex exec (models.sh default)
#
# Routes are the per-role verifier routes (auth-route.sh <family> --role
# verifier); the Claude one must be api (ANTHROPIC_API_KEY in its pairs).
# A panellist with no readable artefact by the deadline casts no vote.
# PASS needs quorum (2 of 3 votes) and a strict PASS majority; no quorum, a
# tie or a FAIL majority is a FAIL synthesis that names its reason.
# AUTOMETTA_PANEL_POLL_INTERVAL: poll interval in whole seconds (default 10).
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
# shellcheck source=resolve-root.sh
source "$script_dir/resolve-root.sh"
source "$script_dir/budget.sh"
# shellcheck source=./models.sh
source "$script_dir/models.sh"

PANELLIST_OPUS="Claude Opus 5 <claude-opus-5@local>"
PANELLIST_SONNET="Claude Sonnet 5.5 <claude-sonnet-5-5@local>"
PANELLIST_CODEX="$(AGENT_WHOAMI= agent-whoami --model "$AUTOMETTA_MODEL_CODEX")"

PANEL_IDENTITY="spawn-verifier-panel.sh <panel@local>"

QUORUM_REQUIRED=2
DEFAULT_POLL_INTERVAL=10

log_msg() { printf '%s\n' "$1" >&2; }

# sed_replacement_escape <value>: the value escaped for the replacement side
# of an `s|...|...|` expression, so a backslash, an ampersand or the `|`
# delimiter in an identity or path reaches the prompt verbatim.
sed_replacement_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

extract_stage_id() {
  local card_path="$1"
  local base
  base="$(basename "$card_path")"
  base="${base%.md}"
  if [[ ! "$base" =~ ^[0-9]{2,}[a-z]*-[a-z0-9-]+$ ]]; then
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

resolve_panel_codex_sandbox() {
  local repo_root="$1"
  local card_path="$2"
  local requires_gui
  requires_gui="$(sed -n 's/^- \*\*Requires GUI:\*\* //p' "$card_path" | head -n1)"
  resolve_codex_sandbox_for_card "$repo_root" "$requires_gui"
}

# panel_poll_interval: AUTOMETTA_PANEL_POLL_INTERVAL in whole seconds, or 10
# for anything that is not a positive integer.
panel_poll_interval() {
  local value="${AUTOMETTA_PANEL_POLL_INTERVAL:-}"
  if [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$DEFAULT_POLL_INTERVAL"
  fi
}

# stop_panellist <pid>: a Claude panellist is a subshell wrapping op-fetch, so
# its children go first.
stop_panellist() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
}

# panellist_vote <artefact>: PASS or FAIL from a readable artefact, else
# nothing. Only one fully parsed JSON object may cast a vote.
panellist_vote() {
  local artefact="$1" vote
  [[ -f "$artefact" ]] || return 0
  if ! vote="$(jq -rs '
    if length == 1 and (.[0] | type) == "object"
    then .[0].overall
    else null
    end
    | if . == "PASS" or . == "FAIL" then . else empty end
  ' "$artefact" 2>/dev/null)"; then
    return 0
  fi
  case "$vote" in
    PASS|FAIL) printf '%s\n' "$vote" ;;
  esac
}

# Set by run_panel: PASS, FAIL, NO_QUORUM or TIE.
PANEL_OUTCOME=""

# run_panel: dispatch the three panellists, wait for them until the deadline,
# tally, and write the synthesis. Writes only panellist artefacts and logs,
# the synthesis artefact and (when synth_log is non-empty) one usage line in
# the synthesis log; never state.yaml or budget.json.
run_panel() {
  local card_path="$1" repo_root="$2" work_dir="$3" stage_id="$4" panel_dir="$5"
  local synth_path="$6" synth_log="$7" budget_secs="$8" poll_interval="$9"
  local logs_dir="$repo_root/state/logs"
  local p0_out="$panel_dir/opus.json"
  local p1_out="$panel_dir/sonnet.json"
  local p2_out="$panel_dir/codex.json"
  local p0_log="$logs_dir/${stage_id}-panel-0.log"
  local p1_log="$logs_dir/${stage_id}-panel-1.log"
  local p2_log="$logs_dir/${stage_id}-panel-2.log"

  # A previous attempt's artefacts must not vote in this one.
  rm -f "$p0_out" "$p1_out" "$p2_out"

  log_msg "panel: dispatching 3 verifiers for stage ${stage_id} in ${work_dir}"

  # Panellist 0: Opus via SDK.
  # shellcheck disable=SC2086
  ( cd "$work_dir" && op-fetch $PANEL_CLAUDE_AUTH_PAIRS -- \
      python3 "$PANEL_SDK_SCRIPT" \
        --stage-id "$stage_id" \
        --card "$card_path" \
        --artefact-glob "$PANEL_ARTEFACT_GLOB" \
        --out "$p0_out" \
        --model "$AUTOMETTA_MODEL_OPUS" \
        ${PANEL_CLAUDE_EFFORT_ARGV[@]+"${PANEL_CLAUDE_EFFORT_ARGV[@]}"} \
      </dev/null >"$p0_log" 2>&1 ) &
  local p0_pid=$!

  # Panellist 1: Sonnet via SDK.
  # shellcheck disable=SC2086
  ( cd "$work_dir" && op-fetch $PANEL_CLAUDE_AUTH_PAIRS -- \
      python3 "$PANEL_SDK_SCRIPT" \
        --stage-id "$stage_id" \
        --card "$card_path" \
        --artefact-glob "$PANEL_ARTEFACT_GLOB" \
        --out "$p1_out" \
        --model "$AUTOMETTA_MODEL_SONNET" \
        ${PANEL_CLAUDE_EFFORT_ARGV[@]+"${PANEL_CLAUDE_EFFORT_ARGV[@]}"} \
      </dev/null >"$p1_log" 2>&1 ) &
  local p1_pid=$!

  # Panellist 2: Codex via CLI. The verifier prompt tells Codex to write the
  # JSON artefact directly to p2_out.
  local codex_prompt
  local tmpl="$repo_root/templates/verifier-prompt.md"
  [[ -f "$tmpl" ]] || tmpl="$PANEL_AUTOMETTA_ROOT/templates/verifier-prompt.md"
  codex_prompt="$(sed \
    -e "s|<<stage-id>>|$(sed_replacement_escape "$stage_id")|g" \
    -e "s|<<stage-card-path>>|$(sed_replacement_escape "$card_path")|g" \
    -e "s|<<artefact-path>>|$(sed_replacement_escape "$p2_out")|g" \
    -e "s|<<verifier-tier>>|$(sed_replacement_escape "$PANELLIST_CODEX")|g" \
    -e "s|<<orchestrator-identity>>|spawn-verifier-panel.sh|g" \
    -e "s|<<family-specific-notes-or-none>>|Write the verifier artefact JSON to the artefact-path shown above. stdin redirect already applied.|g" \
    "$tmpl")"

  if [[ -n "$PANEL_CODEX_HOME_OVERRIDE" ]]; then
    # shellcheck disable=SC2086
    CODEX_HOME="$PANEL_CODEX_HOME_OVERRIDE" op-fetch $PANEL_CODEX_AUTH_PAIRS --pass CODEX_HOME -- \
      codex exec -C "$work_dir" --model "$AUTOMETTA_MODEL_CODEX" ${PANEL_CODEX_EFFORT_ARGV[@]+"${PANEL_CODEX_EFFORT_ARGV[@]}"} --sandbox "$PANEL_CODEX_SANDBOX" ${AUTOMETTA_CODEX_APPROVAL_ARGV[@]+"${AUTOMETTA_CODEX_APPROVAL_ARGV[@]}"} ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$codex_prompt" \
      </dev/null >"$p2_log" 2>&1 &
  else
    # shellcheck disable=SC2086
    op-fetch $PANEL_CODEX_AUTH_PAIRS -- \
      codex exec -C "$work_dir" --model "$AUTOMETTA_MODEL_CODEX" ${PANEL_CODEX_EFFORT_ARGV[@]+"${PANEL_CODEX_EFFORT_ARGV[@]}"} --sandbox "$PANEL_CODEX_SANDBOX" ${AUTOMETTA_CODEX_APPROVAL_ARGV[@]+"${AUTOMETTA_CODEX_APPROVAL_ARGV[@]}"} ${AUTOMETTA_CODEX_STATE_ARGV[@]+"${AUTOMETTA_CODEX_STATE_ARGV[@]}"} "$codex_prompt" \
      </dev/null >"$p2_log" 2>&1 &
  fi
  local p2_pid=$!

  log_msg "panel: pids opus=${p0_pid} sonnet=${p1_pid} codex=${p2_pid}"

  "$script_dir/register-agent.sh" "$repo_root" "$p0_pid" verifier claude \
    "$PANELLIST_OPUS" "$card_path" "$p0_log" "$budget_secs" "$work_dir" >/dev/null 2>&1 || true
  "$script_dir/register-agent.sh" "$repo_root" "$p1_pid" verifier claude \
    "$PANELLIST_SONNET" "$card_path" "$p1_log" "$budget_secs" "$work_dir" >/dev/null 2>&1 || true
  "$script_dir/register-agent.sh" "$repo_root" "$p2_pid" verifier codex \
    "$PANELLIST_CODEX" "$card_path" "$p2_log" "$budget_secs" "$work_dir" >/dev/null 2>&1 || true

  # Wait until every panellist has exited or the deadline passes. A vote is
  # read once its process has gone, or at the deadline from whatever artefact
  # is on disk by then; a panellist with no readable artefact by the deadline
  # casts no vote, and nothing it writes after being stopped is read.
  local deadline=$(( $(date +%s) + budget_secs ))
  local p0_alive=1 p1_alive=1 p2_alive=1
  while :; do
    kill -0 "$p0_pid" 2>/dev/null || p0_alive=0
    kill -0 "$p1_pid" 2>/dev/null || p1_alive=0
    kill -0 "$p2_pid" 2>/dev/null || p2_alive=0
    if (( p0_alive + p1_alive + p2_alive == 0 )) || (( $(date +%s) >= deadline )); then
      break
    fi
    sleep "$poll_interval"
  done

  local p0_overall p1_overall p2_overall
  p0_overall="$(panellist_vote "$p0_out")"
  p1_overall="$(panellist_vote "$p1_out")"
  p2_overall="$(panellist_vote "$p2_out")"

  if (( p0_alive + p1_alive + p2_alive > 0 )); then
    log_msg "panel: deadline reached; stopping panellists still running"
    if (( p0_alive )); then stop_panellist "$p0_pid"; fi
    if (( p1_alive )); then stop_panellist "$p1_pid"; fi
    if (( p2_alive )); then stop_panellist "$p2_pid"; fi
  fi
  wait "$p0_pid" 2>/dev/null || true
  wait "$p1_pid" 2>/dev/null || true
  wait "$p2_pid" 2>/dev/null || true

  local pass_count=0 fail_count=0 votes_received=0 vote
  for vote in "$p0_overall" "$p1_overall" "$p2_overall"; do
    case "$vote" in
      PASS) pass_count=$((pass_count + 1)); votes_received=$((votes_received + 1)) ;;
      FAIL) fail_count=$((fail_count + 1)); votes_received=$((votes_received + 1)) ;;
    esac
  done
  log_msg "panel: pass=${pass_count} fail=${fail_count} no-vote=$((3 - votes_received))"

  # PASS needs quorum and a strict majority. Anything else is a FAIL
  # synthesis whose findings open with the reason; there is no casting vote.
  local overall reason
  if (( votes_received < QUORUM_REQUIRED )); then
    overall="FAIL"; reason="no quorum"; PANEL_OUTCOME="NO_QUORUM"
  elif (( pass_count == fail_count )); then
    overall="FAIL"; reason="tie"; PANEL_OUTCOME="TIE"
  elif (( pass_count > fail_count )); then
    overall="PASS"; reason="majority PASS"; PANEL_OUTCOME="PASS"
  else
    overall="FAIL"; reason="majority FAIL"; PANEL_OUTCOME="FAIL"
  fi
  log_msg "panel: synthesised result = ${overall} (${reason})"

  local ap0="" ap1="" ap2=""
  if [[ -f "$p0_out" ]]; then ap0="$p0_out"; fi
  if [[ -f "$p1_out" ]]; then ap1="$p1_out"; fi
  if [[ -f "$p2_out" ]]; then ap2="$p2_out"; fi
  local panellists_json
  panellists_json="$(jq -n \
    --arg id0 "$PANELLIST_OPUS"   --arg ap0 "$ap0" --arg ov0 "$p0_overall" \
    --arg id1 "$PANELLIST_SONNET" --arg ap1 "$ap1" --arg ov1 "$p1_overall" \
    --arg id2 "$PANELLIST_CODEX"  --arg ap2 "$ap2" --arg ov2 "$p2_overall" \
    '[
       {id: 0, identity: $id0, artefact_path: (if $ap0 == "" then null else $ap0 end), overall: (if $ov0 == "" then null else $ov0 end)},
       {id: 1, identity: $id1, artefact_path: (if $ap1 == "" then null else $ap1 end), overall: (if $ov1 == "" then null else $ov1 end)},
       {id: 2, identity: $id2, artefact_path: (if $ap2 == "" then null else $ap2 end), overall: (if $ov2 == "" then null else $ov2 end)}
     ]')"

  # Criteria and findings come from the first panellist that voted.
  local criteria_json="[]" raw_findings="see panellist artefacts."
  local src src_vote
  for src in "$p0_out:$p0_overall" "$p1_out:$p1_overall" "$p2_out:$p2_overall"; do
    src_vote="${src##*:}"
    src="${src%:*}"
    [[ -n "$src_vote" ]] || continue
    criteria_json="$(jq -c 'if (.criteria | type) == "array" then .criteria else [] end' "$src" 2>/dev/null || printf '[]')"
    raw_findings="$(jq -r '.additional_findings // ""' "$src" 2>/dev/null || true)"
    break
  done
  [[ -n "$criteria_json" ]] || criteria_json="[]"

  local ran_at tmp_synth
  ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp_synth="$(mktemp "${synth_path}.XXXXXX")"
  jq -n \
    --arg stage_id   "$stage_id" \
    --arg identity   "$PANEL_IDENTITY" \
    --arg invocation "spawn-verifier-panel.sh ${card_path} ${repo_root} --work-dir ${work_dir}" \
    --arg ran_at     "$ran_at" \
    --argjson criteria    "$criteria_json" \
    --arg findings        "[Panel synthesis — ${reason}] ${raw_findings}" \
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
    }' >"$tmp_synth"

  # The panel's spend is the sum of its panellists. The tick charges it once,
  # from this line, when it consumes the synthesis under its own lock.
  if [[ -n "$synth_log" ]]; then
    local plog tokens total=0 known=0
    for plog in "$p0_log" "$p1_log" "$p2_log"; do
      tokens="$(budget_parse_tokens_from_log "$plog")"
      if [[ "$tokens" =~ ^[0-9]+$ ]]; then
        total=$((total + tokens))
        known=$((known + 1))
      else
        log_msg "panel: usage unknown for ${plog}; not included in the panel total"
      fi
    done
    if (( known > 0 )); then
      printf 'Total tokens: %s\n' "$total" >>"$synth_log"
    fi
  fi

  # The artefact goes last: once it and this process are gone, the tick reads
  # a complete verdict and a complete usage line.
  mv -f "$tmp_synth" "$synth_path"
}

main() {
  local read_only=0
  local card_path="" repo_root="" work_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --read-only) read_only=1 ;;
      --work-dir)
        if [[ $# -lt 2 || -z "$2" ]]; then
          log_msg "--work-dir needs a directory"
          exit 1
        fi
        work_dir="$2"
        shift
        ;;
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
    log_msg "usage: $0 <stage-card-path> <repo-root> [--work-dir <dir>] [--read-only]"
    exit 1
  fi
  [[ -n "$work_dir" ]] || work_dir="$repo_root"
  if [[ ! -d "$work_dir" ]]; then
    log_msg "panel: work dir ${work_dir} does not exist"
    exit 1
  fi

  local stage_id
  stage_id="$(extract_stage_id "$card_path")"
  local effort
  effort="$(sed -n 's/^- \*\*Verifier effort:\*\* //p' "$card_path" | head -n1)"

  PANEL_CLAUDE_EFFORT_ARGV=()
  PANEL_CODEX_EFFORT_ARGV=()
  effort_argv_for_family claude "$effort"
  if [[ ${#AUTOMETTA_EFFORT_ARGV[@]} -gt 0 ]]; then
    PANEL_CLAUDE_EFFORT_ARGV=("${AUTOMETTA_EFFORT_ARGV[@]}")
  fi
  effort_argv_for_family codex "$effort"
  if [[ ${#AUTOMETTA_EFFORT_ARGV[@]} -gt 0 ]]; then
    PANEL_CODEX_EFFORT_ARGV=("${AUTOMETTA_EFFORT_ARGV[@]}")
  fi
  if [[ -n "$effort" ]]; then
    log_msg "panel verifier effort: ${effort} (${stage_id})"
  fi
  PANEL_ARTEFACT_GLOB="$(derive_artefact_glob "$card_path")"

  local logs_dir="$repo_root/state/logs"
  mkdir -p "$logs_dir"

  # Preflight. Every check runs here, before anything is spawned, so a
  # configuration fault exits non-zero in the caller's foreground.
  # Self root: op-refs.sh sits beside this script, in whichever tree it is.
  PANEL_AUTOMETTA_ROOT="$(autometta_self_root "$script_dir")"
  if [[ -f "$PANEL_AUTOMETTA_ROOT/op-refs.sh" ]]; then
    # shellcheck source=/dev/null
    source "$PANEL_AUTOMETTA_ROOT/op-refs.sh"
  fi

  if ! PANEL_CLAUDE_AUTH_PAIRS="$(REPO_ROOT="$repo_root" "$script_dir/auth-route.sh" claude --role verifier)"; then
    log_msg "auth-route resolver failed for family=claude role=verifier"
    exit 1
  fi
  if ! PANEL_CODEX_AUTH_PAIRS="$(REPO_ROOT="$repo_root" "$script_dir/auth-route.sh" codex --role verifier)"; then
    log_msg "auth-route resolver failed for family=codex role=verifier"
    exit 1
  fi

  if ! command -v op-fetch >/dev/null 2>&1; then
    log_msg "op-fetch not on PATH; required for auth-route dispatch"
    exit 1
  fi

  # Fail closed: SDK required for Claude panellists.
  if [[ "$PANEL_CLAUDE_AUTH_PAIRS" != *ANTHROPIC_API_KEY* ]]; then
    log_msg "panel mode requires the claude verifier route in api mode (ANTHROPIC_API_KEY must be available)"
    log_msg "  set auth.claude.verifier.mode: api in .autometta.local.yaml or export AUTOMETTA_CLAUDE_MODE_VERIFIER=api"
    exit 1
  fi

  PANEL_SDK_SCRIPT="$script_dir/verify-sdk.py"
  if [[ ! -f "$PANEL_SDK_SCRIPT" ]]; then
    log_msg "verify-sdk.py not found at $PANEL_SDK_SCRIPT"
    exit 1
  fi

  PANEL_CODEX_HOME_OVERRIDE=""
  if [[ -n "$PANEL_CODEX_AUTH_PAIRS" ]]; then
    PANEL_CODEX_HOME_OVERRIDE="${AUTOMETTA_CODEX_HOME:-$HOME/.codex-api-only}"
    if [[ ! -f "$PANEL_CODEX_HOME_OVERRIDE/auth.json" ]]; then
      log_msg "panel: codex api dispatch requires sibling CODEX_HOME at $PANEL_CODEX_HOME_OVERRIDE"
      exit 1
    fi
  fi

  PANEL_CODEX_SANDBOX="$(resolve_panel_codex_sandbox "$repo_root" "$card_path")"
  codex_approval_argv
  # The Codex panellist runs in the run worktree but writes its artefact
  # under the subscriber's state/, so it gets the single verifier's grant.
  # autometta panel writes to a temp dir instead and needs none.
  AUTOMETTA_CODEX_STATE_ARGV=()
  if [[ $read_only -eq 0 ]]; then
    codex_state_argv_for_repo "$repo_root"
  fi

  local budget_secs poll_interval
  budget_secs="$(budget_secs_from_card "$card_path")"
  [[ "$budget_secs" -eq 0 ]] && budget_secs=2700  # default 45 min
  poll_interval="$(panel_poll_interval)"

  if [[ $read_only -eq 1 ]]; then
    local tmp_panel_dir
    tmp_panel_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$tmp_panel_dir'" EXIT
    run_panel "$card_path" "$repo_root" "$work_dir" "$stage_id" "$tmp_panel_dir" \
      "$tmp_panel_dir/synthesis.json" "" "$budget_secs" "$poll_interval"
    cat "$tmp_panel_dir/synthesis.json"
    case "$PANEL_OUTCOME" in
      PASS) exit 0 ;;
      FAIL) exit 1 ;;
      *) exit 2 ;;
    esac
  fi

  # Under the tick: the state.yaml write below needs yq, so check it before
  # anything starts.
  local state_path="$repo_root/state/state.yaml"
  if ! command -v yq >/dev/null 2>&1; then
    log_msg "yq missing during panel dispatch; tick should have halted before reaching here"
    exit 1
  fi
  if [[ ! -f "$state_path" ]]; then
    log_msg "panel: no state.yaml at ${state_path}"
    exit 1
  fi

  local panel_dir="$repo_root/state/verifiers/${stage_id}.panel"
  local artefact_rel="state/verifiers/${stage_id}.json"
  local synth_path="$repo_root/$artefact_rel"
  local synth_log="$logs_dir/${stage_id}-verifier.log"
  mkdir -p "$panel_dir"
  rm -f "$synth_path"
  : >"$synth_log"

  # The panel runs in the background, in its own process group, so the tick
  # fire that starts it returns at once and the tick consumes its synthesis
  # like any verifier's artefact. Job control gives the process its own
  # group; disown keeps a LaunchAgent tick's exit from reaching it.
  local panel_pid
  set -m
  ( run_panel "$card_path" "$repo_root" "$work_dir" "$stage_id" "$panel_dir" \
      "$synth_path" "$synth_log" "$budget_secs" "$poll_interval" ) \
    </dev/null >>"$synth_log" 2>&1 &
  panel_pid=$!
  set +m
  disown "$panel_pid" 2>/dev/null || true
  log_msg "panel: running in the background as pid ${panel_pid} for stage ${stage_id}"

  if ! STAGE_ID="$stage_id" PID="$panel_pid" ARTEFACT="$artefact_rel" yq -i \
    '(.stages[] | select(.id == strenv(STAGE_ID))).verifier_pid = (strenv(PID) | tonumber) | (.stages[] | select(.id == strenv(STAGE_ID))).verifier_artefact = strenv(ARTEFACT)' \
    "$state_path"; then
    log_msg "panel: could not record verifier_pid ${panel_pid}; stopping the panel"
    kill -TERM -- "-${panel_pid}" 2>/dev/null || true
    exit 1
  fi

  "$script_dir/register-agent.sh" "$repo_root" "$panel_pid" verifier claude \
    "$PANEL_IDENTITY" "$card_path" "$synth_log" "$budget_secs" "$work_dir" >/dev/null 2>&1 || true

  printf '%s\n' "$panel_pid"
}

main "$@"

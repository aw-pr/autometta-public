#!/usr/bin/env bash
# verifier-bake-off.sh — card 46: measure which free verifier candidate
# (local Ollama weights, or a cloud free tier) agrees with the verdicts a
# frontier verifier already produced, over a fixed set of benchmark stages.
#
# Every candidate speaks an OpenAI-compatible chat-completions endpoint
# (scripts/verifier-bake-off-caller.py), so this script's job is: know the
# candidate table, know the benchmark manifest, respect each cloud
# provider's rate caps with plain sleeps and a hard daily stop (a budget
# file, not retries — the repo's stated policy), and write one verdict JSON
# plus one metadata JSON per (candidate, stage) under examples/bake-off/.
#
# Usage:
#   verifier-bake-off.sh run --candidate <name> --stage <stage-id> [--manifest <path>]
#   verifier-bake-off.sh batch [--candidates c1,c2,...] [--stages s1,s2,...] [--manifest <path>]
#   verifier-bake-off.sh list-candidates
#
# See docs/verifier-bake-off.md for the candidate table, the results, and
# the recommendation this harness's output feeds.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autometta_root="$(cd "$script_dir/.." && pwd)"
default_manifest="$autometta_root/examples/bake-off/manifest.json"
out_root="$autometta_root/examples/bake-off"
budget_path="${AUTOMETTA_BAKEOFF_BUDGET_PATH:-$autometta_root/state/bake-off-budget.json}"
caller="$script_dir/verifier-bake-off-caller.py"

# Daily request caps per free-tier provider (card 46's candidate table).
# Overridable for the one-time $10 OpenRouter unlock (50 -> 1000/day).
OPENROUTER_DAILY_CAP="${AUTOMETTA_BAKEOFF_OPENROUTER_DAILY_CAP:-50}"
GROQ_DAILY_CAP="${AUTOMETTA_BAKEOFF_GROQ_DAILY_CAP:-1000}"
GROQ_DAILY_TOKEN_CAP="${AUTOMETTA_BAKEOFF_GROQ_DAILY_TOKEN_CAP:-200000}"
# Per-minute pacing as a plain sleep between consecutive requests to the
# same provider. OpenRouter's stated cap is 20 req/min, so 3s is generous.
# Groq's stated cap is 30 req/min, but its real binding constraint measured
# live is tokens, not requests: 8000 tokens/min, and one full verifier
# prompt (rubric + schema + a modest stage card) already runs 5-10k input
# tokens on its own — close to or over the per-minute ceiling in a single
# request. 65s between Groq requests (just over the per-minute window) is
# what avoided a 413 tokens-per-minute rejection in testing; see
# docs/verifier-bake-off.md.
OPENROUTER_MIN_INTERVAL_SECONDS="${AUTOMETTA_BAKEOFF_OPENROUTER_INTERVAL_SECONDS:-3}"
GROQ_MIN_INTERVAL_SECONDS="${AUTOMETTA_BAKEOFF_GROQ_INTERVAL_SECONDS:-65}"

log_msg() { printf '%s\n' "$1" >&2; }

# Candidate table: name|provider|base_url|model|api_key_env
# provider is one of: local | groq | openrouter — it selects which rate-cap
# and auth-ref logic applies, not the URL (the URL is data, not a branch).
#
# The two OpenRouter rows are NOT the models named in card 46's candidate
# table (qwen/qwen3-coder:free, deepseek/deepseek-r1:free). Both were gone
# from OpenRouter's /models listing by the time this harness ran
# (2026-08-24), replaced by an unrelated roster — the exact "list rotates
# without notice" risk the card names. nvidia/nemotron-3-super-120b-a12b:free
# (120B-class MoE, replaces the qwen3-coder slot) and
# nvidia/nemotron-3-ultra-550b-a55b:free (550B-class MoE, replaces the
# deepseek-r1 slot) are today's closest equivalents by size class and were
# confirmed live before the batch ran. See docs/verifier-bake-off.md.
candidate_table() {
  cat <<'TABLE'
local-gpt-oss-120b|local|http://localhost:11434/v1|gpt-oss:120b|
local-qwen3-coder-30b|local|http://localhost:11434/v1|qwen3-coder:30b|
local-qwen3-32b|local|http://localhost:11434/v1|qwen3:32b|
local-devstral|local|http://localhost:11434/v1|devstral:latest|
groq-gpt-oss-120b|groq|https://api.groq.com/openai/v1|openai/gpt-oss-120b|GROQ_API_KEY
openrouter-nemotron-3-super-120b|openrouter|https://openrouter.ai/api/v1|nvidia/nemotron-3-super-120b-a12b:free|OPENROUTER_API_KEY
openrouter-nemotron-3-ultra-550b|openrouter|https://openrouter.ai/api/v1|nvidia/nemotron-3-ultra-550b-a55b:free|OPENROUTER_API_KEY
TABLE
}

candidate_row() {
  local name="$1"
  candidate_table | awk -F'|' -v n="$name" '$1==n{print; found=1} END{exit !found}'
}

list_candidates() {
  candidate_table | cut -d'|' -f1
}

op_ref_for_env() {
  case "$1" in
    GROQ_API_KEY) printf '%s\n' "${OP_REF_GROQ_API_KEY:-}" ;;
    OPENROUTER_API_KEY) printf '%s\n' "${OP_REF_OPENROUTER_API_KEY:-}" ;;
    *) printf '\n' ;;
  esac
}

ensure_budget_file() {
  local today
  today="$(date -u +%Y-%m-%d)"
  if [[ ! -f "$budget_path" ]]; then
    mkdir -p "$(dirname "$budget_path")"
    jq -n --arg d "$today" '{date:$d, requests:{openrouter:0, groq:0}, groq_tokens:0}' >"$budget_path"
    return
  fi
  local stored_date
  stored_date="$(jq -r '.date' "$budget_path")"
  if [[ "$stored_date" != "$today" ]]; then
    jq -n --arg d "$today" '{date:$d, requests:{openrouter:0, groq:0}, groq_tokens:0}' >"$budget_path"
  fi
}

budget_requests() {
  jq -r ".requests.$1 // 0" "$budget_path"
}

budget_groq_tokens() {
  jq -r '.groq_tokens // 0' "$budget_path"
}

budget_record_request() {
  local provider="$1"
  local tokens="${2:-0}"
  local tmp
  tmp="$(mktemp)"
  jq --arg p "$provider" --argjson t "$tokens" \
    '.requests[$p] = ((.requests[$p] // 0) + 1) | .groq_tokens = (if $p == "groq" then (.groq_tokens // 0) + $t else .groq_tokens end)' \
    "$budget_path" >"$tmp"
  mv "$tmp" "$budget_path"
}

# Returns 0 (may proceed) or 1 (daily cap reached; caller must skip and
# record the shortfall, not retry).
budget_allows() {
  local provider="$1"
  case "$provider" in
    local) return 0 ;;
    openrouter)
      [[ "$(budget_requests openrouter)" -lt "$OPENROUTER_DAILY_CAP" ]]
      ;;
    groq)
      [[ "$(budget_requests groq)" -lt "$GROQ_DAILY_CAP" ]] && \
        [[ "$(budget_groq_tokens)" -lt "$GROQ_DAILY_TOKEN_CAP" ]]
      ;;
    *) return 0 ;;
  esac
}

pace_provider() {
  case "$1" in
    openrouter) sleep "$OPENROUTER_MIN_INTERVAL_SECONDS" ;;
    groq) sleep "$GROQ_MIN_INTERVAL_SECONDS" ;;
  esac
}

# run_one: dispatch one (candidate, stage) pair. Prints the caller's exit
# code semantics on stdout as "verdict=<pass|fail|error>" for batch's
# bookkeeping; writes the verdict + meta JSON regardless of verdict.
run_one() {
  local candidate="$1" stage_id="$2" manifest="$3"

  local row
  if ! row="$(candidate_row "$candidate")"; then
    log_msg "verifier-bake-off: unknown candidate: $candidate (see: $0 list-candidates)"
    return 2
  fi
  IFS='|' read -r _name provider base_url model api_key_env <<<"$row"

  local stage_json
  stage_json="$(jq -c --arg id "$stage_id" '.stages[] | select(.stage_id == $id)' "$manifest")"
  if [[ -z "$stage_json" ]]; then
    log_msg "verifier-bake-off: stage not in manifest: $stage_id"
    return 2
  fi
  local repo card deliverables
  repo="$(jq -r '.repo' <<<"$stage_json")"
  card="$(jq -r '.card' <<<"$stage_json")"
  deliverables="$(jq -r '.deliverables' <<<"$stage_json")"

  if [[ "$provider" != "local" ]]; then
    ensure_budget_file
    if ! budget_allows "$provider"; then
      log_msg "verifier-bake-off: SKIP $candidate/$stage_id — $provider daily cap reached ($(budget_requests "$provider") requests today)"
      local skip_dir="$out_root/$candidate"
      mkdir -p "$skip_dir"
      jq -n --arg s "$stage_id" --arg c "$candidate" --arg p "$provider" \
        '{stage_id:$s, candidate:$c, skipped:true, reason:($p + " daily cap reached")}' \
        >"$skip_dir/${stage_id}.meta.json"
      return 3
    fi
  fi

  local out_dir="$out_root/$candidate"
  mkdir -p "$out_dir"
  local out="$out_dir/${stage_id}.json"
  local meta_out="$out_dir/${stage_id}.meta.json"

  local api_pairs=()
  if [[ -n "$api_key_env" ]]; then
    local ref
    ref="$(op_ref_for_env "$api_key_env")"
    if [[ -z "$ref" || "$ref" == op://YOUR_VAULT/* ]]; then
      log_msg "verifier-bake-off: $api_key_env is unset or unresolved placeholder; copy templates/op-refs.local.sh.tpl and set the real ref"
      return 2
    fi
    if ! command -v op-fetch >/dev/null 2>&1; then
      log_msg "verifier-bake-off: op-fetch is required for cloud candidates"
      return 2
    fi
    api_pairs=("${api_key_env}=${ref}")
  fi

  local exit_code=0
  if [[ ${#api_pairs[@]} -gt 0 ]]; then
    op-fetch "${api_pairs[@]}" -- python3 "$caller" \
      --stage-id "$stage_id" --card "$repo/$card" --repo-root "$repo" \
      --artefact-glob "$deliverables" --out "$out" --meta-out "$meta_out" \
      --candidate "$candidate" --provider "$provider" --base-url "$base_url" --model "$model" \
      --api-key-env "$api_key_env" || exit_code=$?
  else
    python3 "$caller" \
      --stage-id "$stage_id" --card "$repo/$card" --repo-root "$repo" \
      --artefact-glob "$deliverables" --out "$out" --meta-out "$meta_out" \
      --candidate "$candidate" --provider "$provider" --base-url "$base_url" --model "$model" \
      --api-key-env "" || exit_code=$?
  fi

  if [[ "$provider" != "local" ]]; then
    local tokens_used=0
    if [[ -f "$meta_out" ]]; then
      tokens_used="$(jq -r '.total_tokens // 0' "$meta_out")"
      [[ "$tokens_used" =~ ^[0-9]+$ ]] || tokens_used=0
    fi
    budget_record_request "$provider" "$tokens_used"
    pace_provider "$provider"
  fi

  case "$exit_code" in
    0) printf 'verdict=pass\n' ;;
    1) printf 'verdict=fail\n' ;;
    *) printf 'verdict=error\n' ;;
  esac
  return "$exit_code"
}

cmd_run() {
  local candidate="" stage="" manifest="$default_manifest"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --candidate) candidate="$2"; shift 2 ;;
      --stage) stage="$2"; shift 2 ;;
      --manifest) manifest="$2"; shift 2 ;;
      *) log_msg "run: unknown argument: $1"; exit 1 ;;
    esac
  done
  [[ -n "$candidate" && -n "$stage" ]] || { log_msg "run: --candidate and --stage are required"; exit 1; }
  run_one "$candidate" "$stage" "$manifest"
}

cmd_batch() {
  local candidates="" stages="" manifest="$default_manifest"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --candidates) candidates="$2"; shift 2 ;;
      --stages) stages="$2"; shift 2 ;;
      --manifest) manifest="$2"; shift 2 ;;
      *) log_msg "batch: unknown argument: $1"; exit 1 ;;
    esac
  done
  [[ -n "$candidates" ]] || candidates="$(list_candidates | paste -sd, -)"
  [[ -n "$stages" ]] || stages="$(jq -r '.stages[].stage_id' "$manifest" | paste -sd, -)"

  ensure_budget_file
  log_msg "verifier-bake-off: batch start — candidates=[$candidates] stages=[$stages]"
  log_msg "verifier-bake-off: budget so far today — openrouter=$(budget_requests openrouter)/$OPENROUTER_DAILY_CAP groq=$(budget_requests groq)/$GROQ_DAILY_CAP (tokens $(budget_groq_tokens)/$GROQ_DAILY_TOKEN_CAP)"

  local candidate stage pass=0 fail=0 error=0 skip=0
  IFS=',' read -ra candidate_list <<<"$candidates"
  for candidate in "${candidate_list[@]}"; do
    IFS=',' read -ra stage_list <<<"$stages"
    for stage in "${stage_list[@]}"; do
      log_msg "verifier-bake-off: $candidate / $stage"
      local result
      result="$(run_one "$candidate" "$stage" "$manifest" 2>>"$out_root/batch.log")" || true
      case "$result" in
        verdict=pass) pass=$((pass+1)) ;;
        verdict=fail) fail=$((fail+1)) ;;
        verdict=error) error=$((error+1)) ;;
        *) skip=$((skip+1)) ;;
      esac
    done
  done
  log_msg "verifier-bake-off: batch done — pass=$pass fail=$fail error=$error skip=$skip (see $out_root/batch.log for detail)"
}

main() {
  [[ $# -ge 1 ]] || { log_msg "usage: $0 {run|batch|list-candidates} [args...]"; exit 1; }
  local sub="$1"; shift
  case "$sub" in
    run) cmd_run "$@" ;;
    batch) cmd_batch "$@" ;;
    list-candidates) list_candidates ;;
    *) log_msg "unknown subcommand: $sub"; exit 1 ;;
  esac
}

# op-refs.sh is optional here: local-only runs (list-candidates, or a batch
# restricted to local candidates) need no refs at all.
if [[ -f "$autometta_root/op-refs.sh" ]]; then
  # shellcheck source=../op-refs.sh
  source "$autometta_root/op-refs.sh"
fi

main "$@"

#!/usr/bin/env bash
# cost-log.sh — append one cost-log JSONL line per dispatched role.
#
# The cost-log is the connective tissue between the tick loop and the FinOps
# dashboard: one JSON object per line, one line per worker or verifier the
# loop dispatches, written to <repo>/state/cost-log.jsonl. The schema and the
# per-route token fidelity are documented in docs/cost-log.md — this file is
# the producer; FinOps is the consumer.
#
# Sourced by tick.sh (and by scripts/cost-log-smoke.sh). Depends on budget.sh
# for the total-token fallback parser and rates.sh for the cost rate table.

_costlog_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# budget.sh / rates.sh are normally already sourced by the caller (tick.sh);
# guard so a standalone caller (the smoke test) still gets them.
if ! declare -f budget_parse_tokens_from_log >/dev/null 2>&1; then
  # shellcheck source=./budget.sh
  source "$_costlog_script_dir/budget.sh"
fi
if ! declare -f rate_for_tier >/dev/null 2>&1; then
  # shellcheck source=./rates.sh
  source "$_costlog_script_dir/rates.sh"
fi

# Map an identity string to the dispatch family. Mirrors worker_family /
# verifier_family in the spawn scripts so the cost-log agrees with how the
# role was actually launched.
costlog_family_for_identity() {
  local identity="$1"
  if [[ "$identity" == *Codex* || "$identity" == *GPT* ]]; then
    printf 'codex\n'
  elif [[ "$identity" == *Claude* ]]; then
    printf 'claude\n'
  else
    printf 'unknown\n'
  fi
}

# Resolve the billing route (subscription | api) for a family in a repo.
# Same resolution order as auth-route.sh, kept independent so the cost-log
# records the route without re-running the op-fetch resolver:
#   1. AUTOMETTA_<FAMILY>_MODE env override
#   2. auth.<family>.mode in <repo>/.autometta.local.yaml
#   3. default: subscription
auth_route_for_family() {
  local repo_root="$1"
  local family="$2"
  local override_var mode manifest
  override_var="AUTOMETTA_$(printf '%s' "$family" | tr '[:lower:]' '[:upper:]')_MODE"
  mode="${!override_var:-}"
  manifest="$repo_root/.autometta.local.yaml"
  if [[ -z "$mode" && -f "$manifest" ]] && command -v yq >/dev/null 2>&1; then
    mode="$(yq -r ".auth.${family}.mode // \"\"" "$manifest" 2>/dev/null || true)"
  fi
  case "${mode:-subscription}" in
    api)   printf 'api\n' ;;
    local) printf 'local\n' ;;
    *)     printf 'subscription\n' ;;
  esac
}

# Parse a worker/verifier dispatch into an "INPUT CACHED OUTPUT" token triple.
#
# When work_dir is supplied and a Claude Code transcript exists for it, the
# transcript wins outright: every route below reads the role's stdout log,
# which for `claude -p --output-format json` is written only on a clean exit,
# so a role killed at the dispatch timeout parsed as zero. The transcript is
# appended per turn and survives the kill. since_epoch scopes the sum to this
# dispatch so a reused worktree does not re-bill an earlier stage.
#
# Otherwise fidelity depends on what the route emits (see docs/cost-log.md):
#   - SDK verifier route:  `cache: write=W read=R input=I output=O`
#       -> input = I + W (fresh input, cache writes folded in), cached = R,
#          output = O. This is the one route with a true breakdown today.
#   - claude --output-format json: a usage object carrying input_tokens,
#       output_tokens, cache_creation_input_tokens, cache_read_input_tokens.
#   - codex / claude text: total-only ("tokens used\n<N>" or
#       "Total tokens: <N>") -> the total lands in INPUT, cached/output 0.
#
# Prints the triple on success, an empty line when nothing could be parsed.
costlog_parse_breakdown() {
  local log_path="$1"
  local work_dir="${2:-}"
  local since_epoch="${3:-0}"

  if [[ -n "$work_dir" ]]; then
    local from_transcript
    from_transcript="$(budget_parse_tokens_from_transcript "$work_dir" "$since_epoch")"
    if [[ -n "$from_transcript" ]]; then
      printf '%s\n' "$from_transcript"
      return 0
    fi
  fi

  if [[ ! -f "$log_path" ]]; then
    printf '\n'
    return 0
  fi

  local structured
  structured="$(python3 - "$log_path" <<'PY'
import re
import sys

path = sys.argv[1]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(0)

# 1. SDK verifier route: "cache: write=W read=R input=I output=O". Last wins.
sdk = re.findall(
    r"cache:\s*write=(\d+)\s+read=(\d+)\s+input=(\d+)\s+output=(\d+)", text
)
if sdk:
    w, r, i, o = (int(x) for x in sdk[-1])
    print(f"{i + w} {r} {o}")
    sys.exit(0)

# 2. claude --output-format json usage block. Pull the last occurrence of
#    each key so a streamed/partial earlier value does not win.
def last_int(key):
    found = re.findall(rf'"{key}"\s*:\s*(\d+)', text)
    return int(found[-1]) if found else None

inp = last_int("input_tokens")
out = last_int("output_tokens")
if inp is not None or out is not None:
    create = last_int("cache_creation_input_tokens") or 0
    read = last_int("cache_read_input_tokens") or 0
    print(f"{(inp or 0) + create} {read} {out or 0}")
    sys.exit(0)

# Nothing structured found; let the bash total-only fallback handle it.
sys.exit(0)
PY
)"

  if [[ -n "$structured" ]]; then
    printf '%s\n' "$structured"
    return 0
  fi

  # Total-only fallback: reuse the audited awk parser from budget.sh.
  local total
  total="$(budget_parse_tokens_from_log "$log_path")"
  if [[ -n "$total" && "$total" =~ ^[0-9]+$ ]]; then
    printf '%s 0 0\n' "$total"
  else
    printf '\n'
  fi
}

# Parse the advisor line verify-sdk.py emits when --advisor is used:
#   "advisor: model=<m> input=<I> output=<O>"
# Prints "MODEL INPUT OUTPUT" when present, nothing otherwise. The advisor is
# a distinct (stronger) tier from the request model — historically its tokens
# were dropped on the floor because costlog_parse_breakdown returns on the
# request model's `cache:` line and never reads this one, so the most
# expensive tier's spend was invisible to FinOps. costlog_append costs it
# separately at its own tier rate.
costlog_parse_advisor() {
  local log_path="$1"
  [[ -f "$log_path" ]] || return 0
  python3 - "$log_path" <<'PY'
import re
import sys

try:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(0)

# Last occurrence wins, mirroring costlog_parse_breakdown's "last cache: line".
matches = re.findall(r"advisor:\s*model=(\S+)\s+input=(\d+)\s+output=(\d+)", text)
if matches:
    model, inp, out = matches[-1]
    print(f"{model} {inp} {out}")
PY
}

# Append one cost-log line for a dispatched role.
#
# Args:
#   repo_root stage_id role identity log_path wall_clock_s result
#   [work_dir] [since_epoch]
#
# work_dir/since_epoch are optional. When given for a claude-family role they
# route token accounting through the Claude Code transcript, which is the only
# source that survives a role killed at the dispatch timeout. Omitted (or for
# a codex-family role, which writes no such transcript) the behaviour is
# unchanged.
#
# role:   worker | verifier
# result: pass | fail | partial | stalled | aborted | no-artefact (free-form;
#         the loop's terminal verdict for this role)
#
# Non-fatal by contract: a missing log, an unparseable log, or a python error
# logs a warning to stderr and returns 0 without aborting the tick. The
# cost-log is observability, never a gate.
costlog_append() {
  local repo_root="$1"
  local stage_id="$2"
  local role="$3"
  local identity="$4"
  local log_path="$5"
  local wall_clock_s="${6:-0}"
  local result="${7:-unknown}"
  local work_dir="${8:-}"
  local since_epoch="${9:-0}"

  local family tier auth_route repo_name out_file ts breakdown
  family="$(costlog_family_for_identity "$identity")"
  tier="$(tier_for_identity "$identity")"
  auth_route="$(auth_route_for_family "$repo_root" "$family")"
  repo_name="$(basename "$repo_root")"
  out_file="$repo_root/state/cost-log.jsonl"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  breakdown="$(costlog_parse_breakdown "$log_path" "$work_dir" "$since_epoch")"
  local input_tokens cached_tokens output_tokens
  if [[ -n "$breakdown" ]]; then
    # Explicit space IFS: callers (budget.sh) set IFS=$'\n\t', which would
    # otherwise leave the whole triple in the first variable.
    IFS=' ' read -r input_tokens cached_tokens output_tokens <<<"$breakdown"
  fi
  input_tokens="${input_tokens:-0}"
  cached_tokens="${cached_tokens:-0}"
  output_tokens="${output_tokens:-0}"

  if [[ ! "$wall_clock_s" =~ ^[0-9]+$ ]]; then
    wall_clock_s=0
  fi

  local rates rin rcached rout
  rates="$(rate_for_tier "$tier")"
  IFS=' ' read -r rin rcached rout <<<"$rates"

  # Advisor (Fable et al.) is a separate, stronger tier consulted at the
  # decision point. Cost it at its own tier rate so the priciest tokens in
  # the run are not invisible. No cache breakdown is emitted for the advisor,
  # so its input is billed at the plain input rate (cached rate unused).
  local advisor_raw adv_model adv_in adv_out adv_tier adv_rates arin arout
  advisor_raw="$(costlog_parse_advisor "$log_path")"
  if [[ -n "$advisor_raw" ]]; then
    IFS=' ' read -r adv_model adv_in adv_out <<<"$advisor_raw"
    adv_tier="$(tier_for_identity "$adv_model")"
    adv_rates="$(rate_for_tier "$adv_tier")"
    IFS=' ' read -r arin _ arout <<<"$adv_rates"
  fi
  adv_model="${adv_model:-}"
  adv_in="${adv_in:-0}"
  adv_out="${adv_out:-0}"
  adv_tier="${adv_tier:-}"
  arin="${arin:-0}"
  arout="${arout:-0}"

  mkdir -p "$repo_root/state"
  if ! python3 - "$out_file" "$ts" "$repo_name" "$stage_id" "$role" "$identity" \
      "$tier" "$auth_route" "$input_tokens" "$cached_tokens" "$output_tokens" \
      "$wall_clock_s" "$result" "$rin" "$rcached" "$rout" \
      "$adv_model" "$adv_tier" "$adv_in" "$adv_out" "$arin" "$arout" <<'PY'
import json
import sys

(out_file, ts, repo, stage_id, role, identity, tier, auth_route,
 input_tokens, cached_tokens, output_tokens, wall_clock_s, result,
 rin, rcached, rout,
 adv_model, adv_tier, adv_in, adv_out, arin, arout) = sys.argv[1:]

input_tokens = int(input_tokens)
cached_tokens = int(cached_tokens)
output_tokens = int(output_tokens)
wall_clock_s = int(wall_clock_s)
rin, rcached, rout = float(rin), float(rcached), float(rout)

cost = (
    input_tokens * rin
    + cached_tokens * rcached
    + output_tokens * rout
) / 1_000_000.0

adv_in = int(adv_in)
adv_out = int(adv_out)
arin, arout = float(arin), float(arout)
advisor_cost = (adv_in * arin + adv_out * arout) / 1_000_000.0

total_input = input_tokens + cached_tokens
cache_hit_rate = (cached_tokens / total_input) if total_input > 0 else 0.0

line = {
    "ts": ts,
    "repo": repo,
    "stage_id": stage_id,
    "role": role,
    "identity": identity,
    "tier": tier,
    "auth_route": auth_route,
    "input_tokens": input_tokens,
    "cached_input_tokens": cached_tokens,
    "output_tokens": output_tokens,
    "wall_clock_s": wall_clock_s,
    "cost_usd_est": round(cost, 6),
    "advisor_model": adv_model or None,
    "advisor_tier": adv_tier or None,
    "advisor_input_tokens": adv_in,
    "advisor_output_tokens": adv_out,
    "advisor_cost_usd_est": round(advisor_cost, 6),
    "total_cost_usd_est": round(cost + advisor_cost, 6),
    "cache_hit_rate": round(cache_hit_rate, 4),
    "result": result,
}
with open(out_file, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(line) + "\n")
PY
  then
    printf 'costlog_append: failed to write cost-log line for %s/%s (%s); skipping\n' \
      "$stage_id" "$role" "$identity" >&2
    return 0
  fi

  printf 'costlog_append: %s %s tier=%s route=%s in=%s cached=%s out=%s result=%s\n' \
    "$stage_id" "$role" "$tier" "$auth_route" "$input_tokens" "$cached_tokens" \
    "$output_tokens" "$result" >&2
  if [[ -n "$adv_model" ]]; then
    printf 'costlog_append:   advisor=%s tier=%s in=%s out=%s\n' \
      "$adv_model" "$adv_tier" "$adv_in" "$adv_out" >&2
  fi
}

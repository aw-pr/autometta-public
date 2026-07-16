#!/usr/bin/env bash
# cost-log-smoke.sh — offline check of the cost-log producer.
#
# Exercises scripts/cost-log.sh end to end against synthetic logs in a
# throwaway repo root, with no API spend and no live dispatch. It asserts:
#
#   1. Every route's log parses into a valid cost-log JSONL line carrying
#      the full schema (docs/cost-log.md).
#   2. The codex total-only route lands its total in input_tokens with
#      cache_hit_rate 0 (documented coarseness).
#   3. A repeated-prefix loop on the SDK route shows the Phase-2 result:
#      run 1 (cold) has cache_hit_rate 0; run 2 (warm) has a non-zero
#      cache_hit_rate and a strictly lower cost_usd_est for the same token
#      shape, because cached input is billed at the cache-read rate.
#
# This is the measurement-correctness gate. The LIVE end-to-end cache check
# that actually calls the Anthropic API is scripts/sdk-cache-smoke.sh.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cost-log.sh
source "$script_dir/cost-log.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state/logs"
log_dir="$tmp/state/logs"
cost_log="$tmp/state/cost-log.jsonl"

fail=0
note() { printf '%s\n' "$1" >&2; }
check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then
    note "  PASS: $desc"
  else
    note "  FAIL: $desc"
    fail=1
  fi
}

# jq helper: value of field $2 on the JSONL row whose .stage_id == $1.
row() { jq -r --arg id "$1" --arg f "$2" 'select(.stage_id==$id) | .[$f]' "$cost_log"; }

# --- 1. codex total-only worker log ------------------------------------------
printf 'codex\nWork done.\ntokens used\n28,164\n' > "$log_dir/00-codex-worker.log"
costlog_append "$tmp" "00-codex" worker "GPT-5.6 Sol <gpt-5-6-sol@local>" \
  "$log_dir/00-codex-worker.log" 312 pass

note "== codex total-only =="
check "input_tokens carries the total (28164)" "$([[ "$(row 00-codex input_tokens)" == "28164" ]] && echo 1 || echo 0)"
check "cached_input_tokens is 0"               "$([[ "$(row 00-codex cached_input_tokens)" == "0" ]] && echo 1 || echo 0)"
check "cache_hit_rate is 0"                     "$(python3 -c "import sys; sys.exit(0 if float('$(row 00-codex cache_hit_rate)')==0 else 1)" && echo 1 || echo 0)"
check "tier resolved to T1"                     "$([[ "$(row 00-codex tier)" == "T1" ]] && echo 1 || echo 0)"

# --- 2. claude --output-format json verifier log -----------------------------
printf '{"type":"result","usage":{"input_tokens":1200,"output_tokens":800,"cache_creation_input_tokens":0,"cache_read_input_tokens":3400}}\n' \
  > "$log_dir/01-claude-json-verifier.log"
costlog_append "$tmp" "01-claude-json" verifier "Claude Opus 4.8 <claude-opus-4-8@local>" \
  "$log_dir/01-claude-json-verifier.log" 95 pass

note "== claude json usage =="
check "input_tokens 1200"        "$([[ "$(row 01-claude-json input_tokens)" == "1200" ]] && echo 1 || echo 0)"
check "cached_input_tokens 3400" "$([[ "$(row 01-claude-json cached_input_tokens)" == "3400" ]] && echo 1 || echo 0)"
check "output_tokens 800"        "$([[ "$(row 01-claude-json output_tokens)" == "800" ]] && echo 1 || echo 0)"
check "tier resolved to T1"      "$([[ "$(row 01-claude-json tier)" == "T1" ]] && echo 1 || echo 0)"

# --- 3. SDK route: repeated-prefix loop (cold then warm) ----------------------
# Same token shape both runs; the only difference is whether the 1500-token
# stable prefix is written (cold) or read from cache (warm).
printf 'cache: write=1500 read=0 input=200 output=400\nTotal tokens: 600\n' \
  > "$log_dir/02-sdk-cold-verifier.log"
printf 'cache: write=0 read=1500 input=200 output=400\nTotal tokens: 600\n' \
  > "$log_dir/03-sdk-warm-verifier.log"
costlog_append "$tmp" "02-sdk-cold" verifier "Claude Sonnet 4.6 <claude-sonnet-4-6@local>" \
  "$log_dir/02-sdk-cold-verifier.log" 40 pass
costlog_append "$tmp" "03-sdk-warm" verifier "Claude Sonnet 4.6 <claude-sonnet-4-6@local>" \
  "$log_dir/03-sdk-warm-verifier.log" 11 pass

cold_hit="$(row 02-sdk-cold cache_hit_rate)"
warm_hit="$(row 03-sdk-warm cache_hit_rate)"
cold_cost="$(row 02-sdk-cold cost_usd_est)"
warm_cost="$(row 03-sdk-warm cost_usd_est)"

note "== SDK repeated-prefix loop =="
note "  cold: hit_rate=$cold_hit cost=$cold_cost   warm: hit_rate=$warm_hit cost=$warm_cost"
check "cold run cache_hit_rate is 0" "$(python3 -c "import sys; sys.exit(0 if float('$cold_hit')==0 else 1)" && echo 1 || echo 0)"
check "warm run cache_hit_rate > 0"  "$(python3 -c "import sys; sys.exit(0 if float('$warm_hit')>0 else 1)" && echo 1 || echo 0)"
check "warm run cost < cold run cost" "$(python3 -c "import sys; sys.exit(0 if float('$warm_cost')<float('$cold_cost') else 1)" && echo 1 || echo 0)"

reduction="$(python3 -c "print(f'{(1-float('$warm_cost')/float('$cold_cost'))*100:.1f}')")"
note "  measured cost reduction warm vs cold: ${reduction}%"

# --- 4. whole-file JSONL validity + schema completeness ----------------------
note "== schema validity =="
if python3 - "$cost_log" <<'PY'
import json, sys
required = {"ts","repo","stage_id","role","identity","tier","auth_route",
           "input_tokens","cached_input_tokens","output_tokens","wall_clock_s",
           "cost_usd_est","cache_hit_rate","result"}
ok = True
for n, line in enumerate(open(sys.argv[1]), 1):
    d = json.loads(line)
    missing = required - set(d)
    if missing:
        print(f"  line {n}: missing {sorted(missing)}", file=sys.stderr)
        ok = False
sys.exit(0 if ok else 1)
PY
then
  note "  PASS: every line is valid JSON with the full schema"
else
  note "  FAIL: schema check failed"
  fail=1
fi

note ""
if [[ "$fail" == "0" ]]; then
  note "cost-log-smoke: PASS"
  exit 0
else
  note "cost-log-smoke: FAIL"
  exit 1
fi

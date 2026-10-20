#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=regression suite; no stage card freezes it
# model-rates-smoke.sh — offline check that cost estimates price the model an
# identity actually runs on, falling back to its tier only for an unlisted
# model, and that local weights stay free. Exit 0 on all-pass, 1 on failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./models.sh
source "$script_dir/models.sh"
# shellcheck source=./rates.sh
source "$script_dir/rates.sh"

fail=0
check() {  # check <label> <got> <want>
  if [[ "$2" == "$3" ]]; then printf 'PASS  %s\n' "$1"
  else printf 'FAIL  %s: got "%s" want "%s"\n' "$1" "$2" "$3"; fail=1; fi
}

check 'Opus 5.5 priced below Opus 5' "$(rate_for_model claude-opus-5-5)" '4.0 0.2 20.0'
check 'Opus 5 at list'               "$(rate_for_model claude-opus-5)"   '5.0 0.5 25.0'
check 'Sonnet 5.5 at Sonnet 5 price' "$(rate_for_model claude-sonnet-5-5)" '2.0 0.2 10.0'
check 'Sol shares T1 but not price'  "$(rate_for_model gpt-5.6-sol)"     '5.0 0.5 30.0'
check 'cloud default uses current Sol' "$AUTOMETTA_MODEL_CODEX" 'gpt-6.1-sol'
check 'unnamed Codex uses current Sol' "$(codex_cloud_model_for_identity Codex)" 'gpt-6.1-sol'
for model in gpt-6-astra gpt-6.1-sol gpt-6-sol gpt-6-luna gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna; do
  check "$model routes to its own weights" "$(codex_cloud_model_for_identity "$model")" "$model"
done
check 'current Sol identity routes' "$(codex_cloud_model_for_identity 'GPT-6.1 Sol <gpt-6-1-sol@local>')" 'gpt-6.1-sol'
check 'current Luna identity routes' "$(codex_cloud_model_for_identity 'GPT-6 Luna <gpt-6-luna@local>')" 'gpt-6-luna'
check 'previous Sol identity stays pinned' "$(codex_cloud_model_for_identity 'GPT-6 Sol <gpt-6-sol@local>')" 'gpt-6-sol'
check 'current Sol is T1' "$(tier_for_identity 'GPT-6.1 Sol <gpt-6-1-sol@local>')" T1
check 'previous Sol is T1' "$(tier_for_identity gpt-6-sol)" T1
check 'current Luna is T4' "$(tier_for_identity 'GPT-6 Luna <gpt-6-luna@local>')" T4
check 'current Sol rate' "$(rate_for_model gpt-6.1-sol)" '2.0 0.1 10.0'
check 'previous Sol rate' "$(rate_for_model gpt-6-sol)" '2.0 0.2 10.0'
check 'current Luna rate' "$(rate_for_model gpt-6-luna)" '0.1 0.01 0.5'
check 'unlisted model prints nothing' "$(rate_for_model claude-opus-9)"  ''
check 'identity slug reaches its rate' \
  "$(rate_for_model "$(claude_model_for_identity 'Claude Opus 5.5 <claude-opus-5-5@local>')")" '4.0 0.2 20.0'
check 'Sonnet 5.5 slug reaches its rate' \
  "$(rate_for_model "$(claude_model_for_identity 'Claude Sonnet 5.5 <claude-sonnet-5-5@local>')")" '2.0 0.2 10.0'
check 'local weights stay free'      "$(rate_for_tier "$(tier_for_identity 'Codex GPT-OSS 120B <codex-gpt-oss-120b@local>')")" '0.0 0.0 0.0'
check 'T1 fallback at current Opus list' "$(rate_for_tier T1)"          '5.0 0.5 25.0'

exit "$fail"

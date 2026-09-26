#!/usr/bin/env bash
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
check 'Sol shares T1 but not price'  "$(rate_for_model gpt-5.6-sol)"     '5.0 0.5 30.0'
check 'unlisted model prints nothing' "$(rate_for_model claude-opus-9)"  ''
check 'identity slug reaches its rate' \
  "$(rate_for_model "$(claude_model_for_identity 'Claude Opus 5.5 <claude-opus-5-5@local>')")" '4.0 0.2 20.0'
check 'local weights stay free'      "$(rate_for_tier "$(tier_for_identity 'Codex GPT-OSS 120B <codex-gpt-oss-120b@local>')")" '0.0 0.0 0.0'
check 'T1 fallback at current Opus list' "$(rate_for_tier T1)"          '5.0 0.5 25.0'

exit "$fail"

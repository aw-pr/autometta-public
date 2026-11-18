#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [[ "$#" -ne 4 ]]; then
  printf 'Usage: readiness-headroom.sh REPO CARD BATCH RETRY (nonnegative integer tokens; BATCH includes CARD)\n' >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"

cap="$(budget_effective_token_cap "$1" --read-only)"
python3 - "$(budget_file "$1")" "$cap" "$2" "$3" "$4" <<'PY'
import json
import re
import sys

budget_path, cap_raw, *estimates = sys.argv[1:]


def reject(message):
    print(f"readiness-headroom: {message}", file=sys.stderr)
    sys.exit(2)


if any(re.fullmatch(r"[0-9]+", value) is None for value in estimates):
    reject("CARD, BATCH and RETRY must be nonnegative integer token estimates")
card, batch, retry = map(int, estimates)
if batch < card:
    reject("BATCH must include CARD and cannot be smaller than CARD")
if re.fullmatch(r"[0-9]+", cap_raw) is None or int(cap_raw) <= 0:
    reject("effective token cap is unavailable or invalid")

cap = int(cap_raw)
report = dict(cap=cap, spent=None, headroom=None, card_shortfall=None,
              batch_shortfall=None, with_retry_shortfall=None)
try:
    with open(budget_path, encoding="utf-8") as budget_file:
        budget = json.load(budget_file)
    spent = budget.get("tokens_spent") if isinstance(budget, dict) else None
    if type(spent) is not int or spent < 0:
        raise ValueError("tokens_spent must be a recorded nonnegative integer")
except (OSError, ValueError) as error:
    print(json.dumps(report))
    print(f"readiness-headroom: recorded spend is unknown: {error}", file=sys.stderr)
    sys.exit(1)

headroom = max(0, cap - spent)
report.update(spent=spent, headroom=headroom,
              card_shortfall=max(0, card - headroom),
              batch_shortfall=max(0, batch - headroom),
              with_retry_shortfall=max(0, batch + retry - headroom))
print(json.dumps(report))
PY

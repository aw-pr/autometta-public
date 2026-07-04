#!/usr/bin/env bash
# advisor-order-smoke.sh — offline check of the advisor ordering guard (#66714).
#
# The Fable-as-advisor verifier requires the advisor to be no weaker than the
# request model; the inverted pairing (strong request, weak advisor) returns
# HTTP 400 from the API. verify-sdk.py must reject that pairing locally BEFORE
# any API call. This smoke exercises the pure ordering functions with no API
# spend, no anthropic SDK, and no network, and confirms:
#
#   1. The capability order is fable > opus > sonnet > haiku.
#   2. A valid pairing (sonnet request + fable advisor) passes the guard.
#   3. An inverted pairing (fable request + opus advisor) is rejected with
#      AdvisorOrderingError.
#   4. An equal pairing is allowed (request is not *stronger* than advisor).
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$script_dir/verify-sdk.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("verify_sdk", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

fail = 0


def check(desc, cond):
    global fail
    if cond:
        print(f"  PASS: {desc}", file=sys.stderr)
    else:
        print(f"  FAIL: {desc}", file=sys.stderr)
        fail = 1


print("== advisor ordering guard (#66714) ==", file=sys.stderr)

check(
    "capability order fable > opus > sonnet > haiku",
    m.capability_rank("claude-fable-5")
    > m.capability_rank("claude-opus-4-8")
    > m.capability_rank("claude-sonnet-4-6")
    > m.capability_rank("claude-haiku-4-5"),
)

ok = True
try:
    m.assert_advisor_ordering("claude-sonnet-4-6", "claude-fable-5")
except m.AdvisorOrderingError:
    ok = False
check("valid pair (sonnet request + fable advisor) passes", ok)

rejected = False
try:
    m.assert_advisor_ordering("claude-fable-5", "claude-opus-4-8")
except m.AdvisorOrderingError:
    rejected = True
check("inverted pair (fable request + opus advisor) rejected", rejected)

ok = True
try:
    m.assert_advisor_ordering("claude-opus-4-8", "claude-opus-4-8")
except m.AdvisorOrderingError:
    ok = False
check("equal pair (opus request + opus advisor) allowed", ok)

print("", file=sys.stderr)
if fail == 0:
    print("advisor-order-smoke: PASS", file=sys.stderr)
    sys.exit(0)
print("advisor-order-smoke: FAIL", file=sys.stderr)
sys.exit(1)
PY

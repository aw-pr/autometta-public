#!/usr/bin/env bash
# stage-id-width-smoke.sh: a stage id may carry more than two digits.
# No auth, no network, no token spend.
#
# The id pattern was `^[0-9]{2}[a-z]*-[a-z0-9-]+$` -- exactly two digits --
# copied into six scripts and two schemas. Card 99 was therefore the last card
# that could ever be queued: `add-stage` rejected card 100 as a malformed
# stage id, and had it somehow been queued the tick, both spawners, the panel
# and the envelope validator would each have rejected it again on their own
# copy of the rule.
#
# It is now `{2,}`. Two digits stays the minimum, so a one-digit id is still
# refused and the ordering that the leading number provides is preserved.
#
# What it asserts:
#
#   1. A three-digit id is accepted, and the two-digit ids already in the
#      ledger still are, including the `15a` suffixed form.
#   2. A one-digit id and a digitless id are still refused, so widening the
#      pattern did not turn it into "anything".
#   3. Every file that carries the rule carries the widened form. This is the
#      load-bearing one: the rule lives in eight places, and a copy left at
#      {2} fails a stage somewhere downstream of a successful queue, which is
#      the worst place to find out.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"

fail=0
check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2
    fail=1
  fi
}

matches() {
  [[ "$1" =~ ^[0-9]{2,}[a-z]*-[a-z0-9-]+$ ]] && printf 'yes\n' || printf 'no\n'
}
expect() {
  local id="$1" want="$2" got
  got="$(matches "$id")"
  [[ "$got" == "$want" ]] && printf 'ok\n' || printf 'expected %s, got %s\n' "$want" "$got"
}

printf '== 1. the ids that must be accepted ==\n' >&2
check "a three-digit id"            "$(expect 100-the-tick-stops-costing-ninety-seconds yes)"
check "the two-digit ids in the ledger" "$(expect 99-the-verifier-reaches-the-subscription yes)"
check "a leading-zero id"           "$(expect 02-percent yes)"
check "the suffixed 15a form"       "$(expect 15a-sdk-verifier yes)"

printf '== 2. two digits is still the minimum ==\n' >&2
check "a one-digit id is refused"   "$(expect 9-too-short no)"
check "a digitless id is refused"   "$(expect abc-no-digits no)"

printf '== 3. every copy of the rule was widened ==\n' >&2
stale="$(grep -rln '\[0-9\]{2}\[a-z\]\*-' "$root/scripts" "$root/schemas" 2>/dev/null \
         | grep -v 'stage-id-width-smoke' || true)"
if [[ -z "$stale" ]]; then
  check "no file still pins exactly two digits" ok
else
  check "no file still pins exactly two digits" "still narrow: $(printf '%s' "$stale" | tr '\n' ' ')"
fi

widened="$(grep -rl '\[0-9\]{2,}\[a-z\]\*-' "$root/scripts" "$root/schemas" 2>/dev/null \
           | grep -v 'stage-id-width-smoke' | wc -l | tr -d ' ')"
[[ "$widened" -ge 8 ]] \
  && check "the rule is present in its widened form in $widened files" ok \
  || check "the rule is present in its widened form" "only $widened files carry it, expected >= 8"

if [[ "$fail" -eq 0 ]]; then
  printf 'stage-id-width-smoke: PASS\n' >&2
else
  printf 'stage-id-width-smoke: FAIL\n' >&2
fi
exit "$fail"

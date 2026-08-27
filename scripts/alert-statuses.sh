#!/usr/bin/env bash
# alert-statuses.sh: the one definition of which stage statuses are
# alert-worthy.
#
# Source it from bash; run it to print the same list as JSON for a python
# renderer. Both entry points read the array below, so there is exactly one
# place in the tree where a status joins or leaves the alert set.
#
# Before this file the judgement was spelled out as a literal in four places
# (attach.sh twice, agent-ticker.sh twice) plus repo-ticker-proto.py, and each
# copy was a whitelist: a new status was silently excluded from all of them and
# it looked like it worked. That is luck, not design. Card 41 had already paid
# for the general version of this lesson on the fleet alerts table.
#
# superseded is deliberately absent. It is terminal and it means an operator
# decided the card should not run; alerting on a decision the operator has
# already made is the cry-wolf failure this set exists to avoid. Its absence is
# asserted by scripts/superseded-status-smoke.sh, so it stays a decision rather
# than an accident of enumeration.

AUTOMETTA_ALERT_STAGE_STATUSES=(failed verifier_failed stalled)

# JSON array, for jq --argjson and for python's json.loads.
alert_stage_statuses_json() {
  local status out=""
  for status in "${AUTOMETTA_ALERT_STAGE_STATUSES[@]}"; do
    out+="${out:+,}\"${status}\""
  done
  printf '[%s]' "$out"
}

# Executed rather than sourced: print the JSON so a standalone python renderer
# can read the same list without re-declaring it.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  alert_stage_statuses_json
  printf '\n'
fi

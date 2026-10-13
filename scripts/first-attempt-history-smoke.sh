#!/usr/bin/env bash
# Offline proof for stage card 155: first-attempt history from git alone.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_source="$(cd "$script_dir/.." && pwd)"
tool="$repo_source/scripts/first-attempt-history.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

repo="$tmp/repo"
mkdir -p "$repo/stage-cards"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/155-a-run-knows-its-first-attempt-rate.md
# A run cannot tell whether its cards are getting better until it can count
# the stages that landed on attempt 1 with no re-brief. The count comes from
# git and the cards on disk alone, so it covers every era, including the
# ones before state/cost-log.jsonl existed.
clock=1760000000
g() {
  clock=$((clock + 60))
  GIT_AUTHOR_DATE="@$clock +0000" GIT_COMMITTER_DATE="@$clock +0000" \
    git -C "$repo" -c user.name=Smoke -c user.email=smoke@local \
      -c commit.gpgsign=false "$@"
}
g init -q -b dev

card() {
  local id="$1" rebriefs="${2:-0}" i
  {
    printf '# Stage card %s: fixture\n\n## Objective\n\nFixture.\n' "$id"
    for ((i = 1; i <= rebriefs; i++)); do
      printf '\n## Re-brief %d (2026-10-01)\n\nAmended.\n' "$i"
    done
  } >"$repo/stage-cards/$id.md"
}

land() {
  g commit -q --allow-empty -m "$1: landed" \
    -m "Autometta-Worker: Codex Smoke <codex-smoke@local>
Autometta-Verifier: Claude Smoke <claude-smoke@local>"
}

wip() {
  g commit -q --allow-empty -m "wip($1): attempt $2, verifier FAIL: criterion 1 fixture"
}

card 10-alpha
card 11-beta
card 12-gamma 1
card 13-delta
card 14-epsilon
card 15-zeta
card 16-eta
card 17-theta
g add stage-cards
g commit -q -m "cards(10-17): fixtures"

alpha_sha=""
delta_sha=""
land 10-alpha
alpha_sha="$(git -C "$repo" rev-parse HEAD)"
wip 11-beta 1
land 11-beta
land 12-gamma
g commit -q --allow-empty -m "13-delta: phat-controller re-brief citing abc123" \
  -m "Autometta-Worker: Codex Smoke <codex-smoke@local>"
land 13-delta
delta_sha="$(git -C "$repo" rev-parse HEAD)"
wip 14-epsilon 1
g commit -q --allow-empty -m "15-zeta: an orchestrator note with no role trailers"
g checkout -q -b side
land 16-eta
g checkout -q -b wip/17-theta-attempt-2 dev
wip 17-theta 1
wip 17-theta 2
g checkout -q dev
land 17-theta
g checkout -q -b publish
land 10-alpha
g checkout -q dev

out="$("$tool" "$repo")" || fail "155: the tool exits non-zero on a valid repo"
header="$(printf '%s\n' "$out" | head -n1)"
[[ "$header" == "$(printf 'stage_id\tlanded_commit\twip_attempts\trebriefs\tcontroller_rebriefs\tfirst_attempt_clean')" ]] \
  || fail "155: the first line is not the column header: got '$header'"
summary="$(printf '%s\n' "$out" | grep -E '^first-attempt clean: ' || true)"
[[ "$summary" == 'first-attempt clean: 2 of 6 landed stages (33%)' ]] \
  || fail "155: summary over all stages: got '$summary'"

row() { printf '%s\n' "$out" | awk -F'\t' -v id="$1" '$1 == id'; }
col() { row "$1" | awk -F'\t' -v n="$2" '{ print $n }'; }

[[ "$(row 10-alpha | wc -l | tr -d ' ')" == 1 ]] \
  || fail "155: a stage landed on two branches is not counted once"
[[ "$(col 10-alpha 6)" == yes ]] || fail "155: 10-alpha landed clean and is not marked yes"
alpha_landing="$(col 10-alpha 2)"
[[ "$alpha_landing" =~ ^[0-9a-f]{40}$ ]] \
  || fail "155: landed_commit is not a full SHA: got '$alpha_landing'"
[[ "$alpha_landing" == "$alpha_sha" ]] \
  || fail "155: landed_commit is not the earliest landing of 10-alpha"
[[ "$(col 11-beta 3)" == 1 && "$(col 11-beta 6)" == no ]] \
  || fail "155: a failed attempt before landing does not make 11-beta unclean"
[[ "$(col 12-gamma 4)" == 1 && "$(col 12-gamma 6)" == no ]] \
  || fail "155: a Re-brief section on the card does not make 12-gamma unclean"
[[ "$(col 13-delta 5)" == 1 && "$(col 13-delta 6)" == no ]] \
  || fail "155: a phat-controller re-brief does not make 13-delta unclean"
[[ "$(col 13-delta 2)" == "$delta_sha" ]] \
  || fail "155: a phat-controller re-brief carrying a trailer is taken for the landing"
[[ -z "$(row 14-epsilon)" ]] || fail "155: a stage with only a failed attempt is counted as landed"
[[ -z "$(row 15-zeta)" ]] || fail "155: a commit with no Autometta-Worker trailer is counted as a landing"
[[ "$(col 16-eta 6)" == yes ]] || fail "155: a landing on a branch other than the checked-out one is missed"
[[ "$(col 17-theta 3)" == 2 ]] \
  || fail "155: two failed attempts on a wip branch are not both counted for 17-theta"

since="$("$tool" "$repo" --since 12)" || fail "155: --since exits non-zero"
printf '%s\n' "$since" | grep -qxF 'first-attempt clean: 1 of 4 landed stages (25%)' \
  || fail "155: --since 12 does not restrict the summary to stages 12 and later"
if printf '%s\n' "$since" | awk -F'\t' '$1 == "10-alpha" || $1 == "11-beta"' | grep -q .; then
  fail "155: --since 12 still lists stages numbered below 12"
fi

json="$("$tool" "$repo" --json)" || fail "155: --json exits non-zero"
printf '%s' "$json" | python3 -I -c '
import json, sys
data = json.load(sys.stdin)
assert data["landed"] == 6, data["landed"]
assert data["clean"] == 2, data["clean"]
stages = {s["stage_id"]: s for s in data["stages"]}
assert len(stages) == 6, sorted(stages)
assert stages["17-theta"]["wip_attempts"] == 2
assert stages["10-alpha"]["first_attempt_clean"] is True
assert stages["13-delta"]["first_attempt_clean"] is False
' || fail "155: --json does not carry the same counts as the table"

empty="$tmp/empty"
git init -q "$empty"
empty_out="$("$tool" "$empty")" || fail "155: a repo with no commits makes the tool exit non-zero"
printf '%s\n' "$empty_out" | grep -qxF 'first-attempt clean: 0 of 0 landed stages (n/a)' \
  || fail "155: a repo with no landings does not report 0 of 0"

set +e
"$tool" >/dev/null 2>&1
usage_rc=$?
set -e
[[ "$usage_rc" == 2 ]] || fail "155: no arguments should exit 2, got $usage_rc"
# AUTOMETTA-CONTRACT-END

printf 'PASS: first-attempt history counts clean landings from git and the cards alone\n'

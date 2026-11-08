#!/usr/bin/env bash
# proposals-smoke.sh: the harness proposals ledger accepts a well-formed
# proposal, walks its lifecycle, and refuses the writes that would leave a
# permanent bad line (docs/learning-log.md).
#
# Runs against a temp ledger; nothing here touches memory/proposals.jsonl.
set -euo pipefail
IFS=$'\n\t'

# AUTOMETTA-CONTRACT-NONE reason=regression coverage for scripts/proposals.sh, no card freezes it

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

export PROPOSALS_LEDGER_PATH="$tmp/proposals.jsonl"
export AUTOMETTA_AGENT="Smoke Agent <smoke-agent@local>"
sh="$script_dir/proposals.sh"

fail() { printf 'FAIL: proposals-smoke: %s\n' "$1" >&2; exit 1; }
expect_fail() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$what should have been refused"; fi
}

[[ -x "$sh" ]] || fail "scripts/proposals.sh missing or not executable"

# 1. Lint of an absent ledger passes.
"$sh" lint | grep -q '^PASS' || fail "lint of an absent ledger should pass"

# 2. add mints an id and the line lints.
id="$("$sh" add --title "Verifier template names HARNESS findings" --kind template \
  --target templates/verifier-prompt.md,docs/learning-log.md \
  --change "Add a method step telling the verifier to prefix harness observations with HARNESS: inside additional_findings so the weekly review can lift them." \
  --evidence 160-escalations-skill,memory/facts.jsonl \
  --repo emergence-lab --stage 07-thing --run run-20261101-010203)"
[[ "$id" =~ ^P-[0-9]{8}-[0-9a-f]{4}$ ]] || fail "add did not mint a P- id: $id"
"$sh" lint | grep -q 'PASS proposals ledger: 1 proposal$' || fail "ledger with one proposal should lint"
jq -e --arg id "$id" 'select(.id == $id) | .target | length == 2' "$PROPOSALS_LEDGER_PATH" >/dev/null \
  || fail "comma-separated targets should become a two-element array"

# 3. list defaults to open items and shows the status column.
"$sh" list | grep -q "^$id	proposed	template	07-thing	Verifier template" || fail "list should show the proposed item"
[[ -z "$("$sh" list --status landed)" ]] || fail "list --status landed should be empty"

# 4. Refusals: no agent, missing evidence, absolute target, unknown id.
expect_fail "add without an agent" env -u AUTOMETTA_AGENT "$sh" add --title "No identity here" --kind doc \
  --target docs/x.md --change "Twenty characters of change text." --evidence 01-x
expect_fail "add without evidence" "$sh" add --title "Opinion without evidence" --kind doc \
  --target docs/x.md --change "Twenty characters of change text."
expect_fail "add with an absolute target" "$sh" add --title "Absolute target path" --kind doc \
  --target /Users/someone/docs/x.md --change "Twenty characters of change text." --evidence 01-x
expect_fail "approve of an unknown id" "$sh" approve P-20000101-dead --note "no such thing"
expect_fail "approve without a note" "$sh" approve "$id"

# 5. Illegal transitions: card before approve, land before card.
expect_fail "card before approve" "$sh" card "$id" --stage 90-harness-findings
expect_fail "land before card" "$sh" land "$id" --commit abc1234

# 6. The happy path: approve, card, land; then the id is closed.
"$sh" approve "$id" --note "operator approved 2026-11-08" | grep -q "approved$" || fail "approve failed"
"$sh" card "$id" --stage 90-harness-findings | grep -q "carded$" || fail "card failed"
"$sh" list | grep -q "^$id	carded	template	90-harness-findings	" || fail "list should show the card stage once carded"
"$sh" land "$id" --commit abc1234 | grep -q "landed$" || fail "land failed"
expect_fail "approve after landed" "$sh" approve "$id" --note "too late"
[[ -z "$("$sh" list)" ]] || fail "a landed proposal should leave the open list"
"$sh" list --status all | grep -q "^$id	landed	" || fail "list --status all should still show it"

# 7. merge folds a duplicate into a known id and refuses an unknown or self target.
dup="$("$sh" add --title "Duplicate of the HARNESS findings step" --kind template \
  --target templates/verifier-prompt.md --change "Same change, seen again in another run." --evidence 08-other)"
expect_fail "merge into an unknown id" "$sh" merge "$dup" --into P-20000101-beef
expect_fail "merge into itself" "$sh" merge "$dup" --into "$dup"
"$sh" merge "$dup" --into "$id" | grep -q "merged$" || fail "merge failed"

# 8. show prints every event for one id, oldest first.
events="$("$sh" show "$id" | jq -r .event | paste -sd, -)"
[[ "$events" == "proposed,approved,carded,landed" ]] || fail "show order wrong: $events"

# 9. A hand-edited bad line is caught by lint.
printf '{"id":"%s","event":"approved","agent":"Smoke Agent <smoke-agent@local>","recorded_at":"2026-11-08T00:00:00Z","note":"again"}\n' "$id" \
  >> "$PROPOSALS_LEDGER_PATH"
expect_fail "lint of an illegal appended transition" "$sh" lint

# 10. The committed ledger, when present, lints.
if [[ -f "$script_dir/../memory/proposals.jsonl" ]]; then
  PROPOSALS_LEDGER_PATH="$script_dir/../memory/proposals.jsonl" "$sh" lint >/dev/null \
    || fail "committed memory/proposals.jsonl does not lint"
fi

printf 'PASS: proposals-smoke\n'

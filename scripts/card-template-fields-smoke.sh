#!/usr/bin/env bash
# Offline proof for stage card 156: the template carries what a card needs
# to land on attempt 1.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_source="$(cd "$script_dir/.." && pwd)"
tpl="$repo_source/templates/stage-card.md"
checklist="$repo_source/templates/orchestrator-checklist.md"
contract="$repo_source/docs/dispatch-contract.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/156-the-template-asks-what-the-card-has-not-decided.md
# Over the loop's history most failed attempts traced to the card, and the
# fields that would have caught them existed only by convention. The
# template carries them now, and a card made from it still queues.
section() {
  awk -v h="$2" '
    $0 == h { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

grep -Eq '^- \*\*Open decisions:\*\* ' "$tpl" \
  || fail "156: the template has no Open decisions metadata line"
surfacing_at="$(grep -n '^## Surfacing concern$' "$tpl" | head -n1 | cut -d: -f1)"
objective_at="$(grep -n '^## Objective$' "$tpl" | head -n1 | cut -d: -f1)"
[[ -n "$surfacing_at" && -n "$objective_at" && "$surfacing_at" -lt "$objective_at" ]] \
  || fail "156: the template has no Surfacing concern section ahead of Objective"
section "$tpl" '## Acceptance criteria' \
  | grep -Fq 'names the seat that judges it and the command that produces its evidence' \
  || fail "156: the acceptance criteria section does not ask for a seat and a command per criterion"
section "$tpl" '## Contract test' | grep -Eq '^- \*\*Oracle proof:\*\* ' \
  || fail "156: the Contract test section has no Oracle proof line"
section "$tpl" '## Budget' | grep -Eq '^- \*\*Spend basis:\*\* ' \
  || fail "156: the Budget section has no Spend basis line"

for label in 'Open decisions.' 'Seat and command.' 'Baseline run.' 'Claims closure.' 'Oracle proof.'; do
  grep -Fq -- "- [ ] **$label**" "$checklist" \
    || fail "156: the orchestrator checklist has no '$label' item"
done

awk '
  /^### Separation of powers/ { inside = 1; next }
  inside && /^### / { exit }
  inside { print }
' "$contract" | grep -Fq 'Oracle proof' \
  || fail "156: the contract doc does not say the orchestrator records the oracle proof"

# A card made by filling every placeholder must still queue. The comment
# examples in the template must not read as the card's own metadata.
repo="$tmp/repo"
mkdir -p "$repo/state" "$tmp/cards"
printf '{"current_stage":null,"stages":[]}\n' >"$repo/state/state.yaml"
filled="$tmp/cards/99-filled.md"
sed -e 's/<<contract-test-path-or-None>>/None/' \
    -e 's/<<sha256-of-frozen-block-or-None>>/None/' \
    -e 's/<<[^>]*>>/x/g' "$tpl" >"$filled"
printf '%s\n' '- **Dispatch:** serial' >>"$filled"
"$repo_source/scripts/add-stage.sh" "$repo" "$filled" >"$tmp/queue.out" 2>&1 \
  || fail "156: a card made from the template is refused: $(tr '\n' ' ' <"$tmp/queue.out")"
grep -Fq '99-filled' "$repo/state/state.yaml" \
  || fail "156: the filled template card is not in the queue"
# AUTOMETTA-CONTRACT-END

printf 'PASS: the template asks for decisions, seats, proof and spend, and a card made from it queues\n'

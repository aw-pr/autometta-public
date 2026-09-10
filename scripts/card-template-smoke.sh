#!/usr/bin/env bash
# Offline proof for stage card 131: a card carries its own oracle.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_source="$(cd "$script_dir/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

write_card() {
  local path="$1" digest_line="$2"
  {
    printf '# Stage card %s: smoke fixture\n\n## Metadata\n\n' "$(basename "$path" .md)"
    printf '%s\n' '- **Orchestrator:** Smoke <smoke@local>'
    printf '%s\n' '- **Worker:** Codex Smoke <codex-smoke@local>'
    printf '%s\n' '- **Verifier:** Claude Verify <claude-verify@local>'
    printf '%s\n' '- **Path claims:** src/a.sh'
    printf '\n## Contract test\n\n'
    printf '%s\n' '- **Test file:** scripts/example-smoke.sh'
    printf '%s\n' "$digest_line"
    printf '\n## Budget\n\n- **Worker wall-clock:** 10 minutes\n'
  } >"$path"
}

repo="$tmp/repo"
mkdir -p "$repo/state" "$tmp/cards"
printf '{"current_stage":null,"stages":[]}\n' >"$repo/state/state.yaml"

# The assertions below are the frozen acceptance spec for stage card 131,
# authored by the orchestrator before any implementation existed
# (docs/dispatch-contract.md:131).
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/131-a-card-carries-its-own-oracle.md
# A card that names a contract test but carries an instruction where its
# digest belongs is asking the worker to author its own oracle. That is the
# shipped template's wording, so it is not a rare mistake: it reached at
# least cards 113, 114 and 124.
write_card "$tmp/cards/90-instruction.md" \
  '- **Assertions digest:** frame the assertions in a block between the begin marker and the end marker, and replace this line with the real digest.'
if "$repo_source/scripts/add-stage.sh" "$repo" "$tmp/cards/90-instruction.md" \
     >"$tmp/instruction.out" 2>&1; then
  fail "131: a card whose Assertions digest line is an instruction was queued"
fi
grep -Fq 'digest' "$tmp/instruction.out" \
  || fail "131: the refusal does not name the missing digest"

write_card "$tmp/cards/91-nodigest.md" '- **Assertions digest:** none yet'
if "$repo_source/scripts/add-stage.sh" "$repo" "$tmp/cards/91-nodigest.md" \
     >"$tmp/nodigest.out" 2>&1; then
  fail "131: a card naming a test file with no sha256 digest was queued"
fi

write_card "$tmp/cards/92-good.md" \
  '- **Assertions digest:** `sha256:0000000000000000000000000000000000000000000000000000000000000000`'
"$repo_source/scripts/add-stage.sh" "$repo" "$tmp/cards/92-good.md" >/dev/null 2>&1 \
  || fail "131: a card carrying a real digest was refused"

# A card with no contract test at all is still allowed; not every stage
# earns one (docs/dispatch-contract.md:172).
{
  printf '# Stage card 93-prose: smoke fixture\n\n## Metadata\n\n'
  printf '%s\n' '- **Orchestrator:** Smoke <smoke@local>'
  printf '%s\n' '- **Worker:** Codex Smoke <codex-smoke@local>'
  printf '%s\n' '- **Verifier:** Claude Verify <claude-verify@local>'
  printf '%s\n' '- **Path claims:** src/b.sh'
  printf '\n## Contract test\n\nNone\n'
  printf '\n## Budget\n\n- **Worker wall-clock:** 10 minutes\n'
} >"$tmp/cards/93-prose.md"
"$repo_source/scripts/add-stage.sh" "$repo" "$tmp/cards/93-prose.md" >/dev/null 2>&1 \
  || fail "131: a card declaring no contract test was refused"

# The template must stop asking the worker to do the authoring.
if grep -Fq 'replace this line' "$repo_source/templates/stage-card.md"; then
  fail "131: the card template still tells the worker to write its own digest"
fi
grep -Eqi 'orchestrator' "$repo_source/templates/stage-card.md" \
  || fail "131: the template does not say who authors the assertions"
# AUTOMETTA-CONTRACT-END

printf 'PASS: a card names a contract test only when it carries the digest, and the template says who writes it\n'

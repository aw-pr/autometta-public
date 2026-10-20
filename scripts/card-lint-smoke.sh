#!/usr/bin/env bash
# Offline proof for stage card 157: a card is linted before it is queued.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_source="$(cd "$script_dir/.." && pwd)"
lint="$repo_source/scripts/card-lint.sh"
gate="$repo_source/scripts/check-contract-test-gate.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Marker text is assembled so that this file carries only its own block.
marker_begin="AUTOMETTA-CONTRACT-""BEGIN"
marker_end="AUTOMETTA-CONTRACT-""END"
marker_none="AUTOMETTA-CONTRACT-""NONE"

repo="$tmp/repo"
mkdir -p "$repo/stage-cards" "$repo/src" "$repo/tests" "$repo/docs"
git -C "$repo" init -q
printf 'echo existing\n' >"$repo/src/existing.sh"
printf '# Agents\n' >"$repo/AGENTS.md"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/157-a-card-is-linted-before-it-is-queued.md
# Most failed attempts traced to the card, and most of those were visible in
# the card text before dispatch. Each fixture below is one of those classes
# and must trip exactly one check, because a lint that cries wolf gets
# waved through.
make_test() {
  local id="$1" extra="${2:-}"
  {
    printf '#!/usr/bin/env bash\n'
    [[ -z "$extra" ]] || printf '%s\n' "$extra"
    printf '# %s card=stage-cards/%s.md\n' "$marker_begin" "$id"
    printf 'test "$(bash src/a.sh)" = hello\n'
    printf '# %s\n' "$marker_end"
  } >"$repo/tests/$id-smoke.sh"
}

digest_of() { "$gate" print "$repo/tests/$1-smoke.sh"; }

good_card() {
  local id="$1" test_file="$2" digest="$3"
  cat >"$repo/stage-cards/$id.md" <<CARD
# Stage card $id: fixture

## Metadata

- **Authored:** 2026-10-12
- **Orchestrator:** Claude Smoke <claude-smoke@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/$id
- **Path claims:** src/a.sh, docs/a.md
- **Pairing rationale:** cross-family fixture.
- **Open decisions:** none

## Surfacing concern

Fixture.

## Objective

Make \`src/a.sh\` print a greeting.

## Inputs (read these in your own context)

- \`src/existing.sh\`
- \`AGENTS.md\`

## Deliverables

1. \`src/a.sh\`: print the greeting.
2. \`docs/a.md\`: one sentence. Exit non-zero if \`data.json\` cannot be read.

## Constraints

- Keep the \`<<placeholder>>\` syntax when quoting the template.

\`\`\`
<<an-example-inside-a-fence>>
\`\`\`

## Acceptance criteria

1. \`bash tests/$id-smoke.sh\` passes.

## Contract test

- **Test file:** $test_file
- **Assertions digest:** $digest

## Budget

- **Worker wall-clock:** 10 minutes
- **Verifier wall-clock:** 10 minutes

## Dispatch envelope

Write \`state/envelopes/$id.json\`.
CARD
}

# variant <id> <line> <replacement> [<line> <replacement>...] writes a good
# card with whole lines swapped; an empty replacement deletes the line and
# a literal \n in a replacement splits it into two lines.
variant() {
  local id="$1"
  shift
  good_card "$id" None None
  python3 -I - "$repo/stage-cards/$id.md" "$@" <<'PY'
import sys
path, pairs = sys.argv[1], sys.argv[2:]
lines = open(path).read().split("\n")
for old, new in zip(pairs[0::2], pairs[1::2]):
    i = lines.index(old)
    if new:
        lines[i] = new.replace("\\n", "\n")
    else:
        del lines[i]
open(path, "w").write("\n".join(lines))
PY
}

expect_only() {
  local id="$1" check="$2" card="$repo/stage-cards/$1.md" out rc
  set +e
  out="$("$lint" --strict "$card" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" == 1 ]] || fail "157: --strict exits $rc on $id, want 1: $out"
  printf '%s\n' "$out" | grep -Eq "^card-lint: ERROR .*/$id\.md: $check: " \
    || fail "157: $id does not report '$check': $out"
  [[ "$(printf '%s\n' "$out" | grep -c '^card-lint: ERROR ')" == 1 ]] \
    || fail "157: $id reports more than the one '$check' finding: $out"
  out="$("$lint" "$card" 2>&1)" || fail "157: default mode exits non-zero on $id"
  printf '%s\n' "$out" | grep -Eq "^card-lint: WARN .*/$id\.md: $check: " \
    || fail "157: default mode does not warn '$check' on $id: $out"
}

make_test 20-good
good_card 20-good tests/20-good-smoke.sh "\`$(digest_of 20-good)\`"
out="$("$lint" --strict "$repo/stage-cards/20-good.md")" \
  || fail "157: a card that passes every check is refused: $out"
printf '%s\n' "$out" | grep -Eq '^card-lint: OK .*/20-good\.md$' \
  || fail "157: a clean card does not print an OK line: $out"
(cd / && "$lint" --strict "$repo/stage-cards/20-good.md" >/dev/null) \
  || fail "157: the lint depends on the directory it is started from"

variant 21-placeholder 'Fixture.' 'Make <<objective>> happen.'
expect_only 21-placeholder placeholder
variant 22-undecided '- **Open decisions:** none' '- **Open decisions:** 1. Which port does the server use?'
expect_only 22-undecided open-decisions
variant 23-nodecisions '- **Open decisions:** none' ''
expect_only 23-nodecisions open-decisions
variant 24-samefamily \
  '- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>' '- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>'
expect_only 24-samefamily pairing
variant 25-samefamily-ok \
  '- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>' '- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>' \
  '- **Pairing rationale:** cross-family fixture.' '- **Pairing rationale:** same-family: a mechanical rename, accepted.'
"$lint" --strict "$repo/stage-cards/25-samefamily-ok.md" >/dev/null \
  || fail "157: a same-family pairing that says so is refused"
# Re-brief 1: metadata values wrap, a Contract test section may say None
# without a Test file line, code spans can use double backticks, and an
# unreadable card is a usage error, not a crash.
variant 35-wrapped-rationale \
  '- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>' '- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>' \
  '- **Pairing rationale:** cross-family fixture.' '- **Pairing rationale:** a mechanical rename, so a\n  same-family pairing is accepted here.'
"$lint" --strict "$repo/stage-cards/35-wrapped-rationale.md" >/dev/null \
  || fail "157: a same-family rationale wrapped onto a second line is not read"
variant 36-no-test-line '- **Test file:** None' 'None' '- **Assertions digest:** None' ''
"$lint" --strict "$repo/stage-cards/36-no-test-line.md" >/dev/null \
  || fail "157: a Contract test section that says None without a Test file line is refused"
variant 37-double-tick 'Fixture.' 'Write ``state/<<stage-id>>.json`` here.'
"$lint" --strict "$repo/stage-cards/37-double-tick.md" >/dev/null \
  || fail "157: a placeholder inside a double-backtick code span is reported"
printf '# Stage card 38\n\377\376\n' >"$repo/stage-cards/38-unreadable.md"
set +e
"$lint" "$repo/stage-cards/38-unreadable.md" >"$tmp/unreadable.out" 2>&1
unreadable_rc=$?
set -e
[[ "$unreadable_rc" == 2 ]] || fail "157: an unreadable card should exit 2, got $unreadable_rc"
if grep -q Traceback "$tmp/unreadable.out"; then
  fail "157: an unreadable card produces a traceback"
fi
variant 26-missing-input '- `AGENTS.md`' '- `AGENTS.md`\n- `scripts/not-there.sh`'
expect_only 26-missing-input inputs
variant 27-unclaimed \
  '2. `docs/a.md`: one sentence. Exit non-zero if `data.json` cannot be read.' \
  '2. `docs/a.md`: one sentence. Exit non-zero if `data.json` cannot be read.\n3. `src/b.sh`: also this.'
expect_only 27-unclaimed claims
variant 32-abs \
  '- Keep the `<<placeholder>>` syntax when quoting the template.' \
  '- Never write /Users/someone/repo here.\n- Keep the `<<placeholder>>` syntax when quoting the template.'
expect_only 32-abs absolute-path
variant 33-budget '- **Verifier wall-clock:** 10 minutes' ''
expect_only 33-budget budget
variant 34-noheading '## Acceptance criteria' ''
expect_only 34-noheading headings

make_test 28-digest
good_card 28-digest tests/28-digest-smoke.sh '`sha256:0000000000000000000000000000000000000000000000000000000000000000`'
expect_only 28-digest contract-test
good_card 29-wrongcard tests/20-good-smoke.sh "\`$(digest_of 20-good)\`"
expect_only 29-wrongcard contract-test
make_test 30-none-marker "# $marker_none reason=fixture"
good_card 30-none-marker tests/30-none-marker-smoke.sh "\`$(digest_of 30-none-marker)\`"
expect_only 30-none-marker contract-test
good_card 31-missing-test tests/absent-smoke.sh '`sha256:1111111111111111111111111111111111111111111111111111111111111111`'
expect_only 31-missing-test contract-test

set +e
both="$("$lint" --strict "$repo/stage-cards/20-good.md" "$repo/stage-cards/21-placeholder.md" 2>&1)"
both_rc=$?
"$lint" >/dev/null 2>&1
usage_rc=$?
"$lint" --strict "$repo/stage-cards/no-such-card.md" >/dev/null 2>&1
missing_rc=$?
set -e
[[ "$both_rc" == 1 ]] || fail "157: one bad card among two does not fail --strict"
printf '%s\n' "$both" | grep -Eq '^card-lint: OK .*/20-good\.md$' \
  || fail "157: the good card is not reported when linted beside a bad one"
[[ "$usage_rc" == 2 ]] || fail "157: no arguments should exit 2, got $usage_rc"
[[ "$missing_rc" == 2 ]] || fail "157: a card that does not exist should exit 2, got $missing_rc"
# AUTOMETTA-CONTRACT-END

variant 39-xhigh '- **Open decisions:** none' '- **Open decisions:** none\n- **Worker effort:** xhigh'
expect_only 39-xhigh effort
variant 40-max-verifier '- **Open decisions:** none' '- **Open decisions:** none\n- **Verifier effort:** max'
expect_only 40-max-verifier effort
variant 41-xhigh-approved '- **Open decisions:** none' \
  '- **Open decisions:** none\n- **Worker effort:** xhigh\n- **Effort approved:** operator, 2026-10-20: "run this one at xhigh"'
"$lint" --strict "$repo/stage-cards/41-xhigh-approved.md" >/dev/null \
  || fail "effort: an xhigh card carrying the operator's approval is refused"
variant 42-high '- **Open decisions:** none' '- **Open decisions:** none\n- **Worker effort:** high'
"$lint" --strict "$repo/stage-cards/42-high.md" >/dev/null \
  || fail "effort: a high-effort card is refused"

printf 'PASS: card-lint finds each card-defect class once, and only when it is there\n'

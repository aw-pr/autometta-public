#!/usr/bin/env bash
# gate-consistency-smoke.sh: the contract-test gate describes the tree it is
# shown. Card 134. No auth, no network, no token spend, and no dependency on
# this repo's own cards: every case runs the shipped gate inside a throwaway
# git repository built here.
#
# Two defects are pinned, both found by verifiers in the 108-133 batch:
#
# 1. The working-tree mode diffs the index against the tree, so a change the
#    worker (or the orchestrator) has already staged is invisible to it. A
#    staged drift that the staged mode rejects is "no relevant changed files"
#    to the worktree mode, and the two modes disagree about one tree.
#
# 2. A test whose card is not in the tree at all is reported as a card that
#    "has no 'Assertions digest' line", above a raw `cat:` error. Stage 133's
#    verifier met this in a run worktree cut before the card landed and had
#    to work out the real cause by hand. The message sends an operator to fix
#    the wrong thing.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd "$script_dir/.." && pwd)"
gate="$source_root/scripts/check-contract-test-gate.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

fail=0
check() {
  local description="$1" result="$2"
  if [[ "$result" == "ok" ]]; then
    printf '  PASS: %s\n' "$description" >&2
  else
    printf '  FAIL: %s (%s)\n' "$description" "$result" >&2
    fail=1
  fi
}
eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }
has() { [[ "$1" == *"$2"* ]] && printf 'ok\n' || printf 'output lacks %q: %s\n' "$2" "$(printf '%s' "$1" | tr '\n' '|')"; }
lacks() { [[ "$1" != *"$2"* ]] && printf 'ok\n' || printf 'output carries %q: %s\n' "$2" "$(printf '%s' "$1" | tr '\n' '|')"; }

# Marker tokens come from the gate's own constants, as cards 106 and 121
# required, so this file carries exactly one begin marker: its own.
mk_begin="$(sed -n "s/^MARKER_BEGIN='\(.*\)'/\1/p" "$gate")"
mk_end="$(sed -n "s/^MARKER_END='\(.*\)'/\1/p" "$gate")"
[[ -n "$mk_begin" && -n "$mk_end" ]] || { echo "FAIL: could not read the marker constants from $gate" >&2; exit 1; }

# --- fixtures --------------------------------------------------------------
# A fixture repo has one seed commit and nothing else. The gate under test is
# the shipped script run from inside the fixture, so its card globs and git
# calls resolve there and never here.
make_gate_repo() {
  local repo="$tmp_root/$1"
  mkdir -p "$repo/stage-cards" "$repo/scripts"
  (
    cd "$repo"
    git init -q -b dev .
    git config user.email smoke@local
    git config user.name smoke
    git config commit.gpgsign false
    git commit -q --allow-empty -m seed
  )
  printf '%s' "$repo"
}

# scripts/*-smoke.sh is a gate candidate by name (card 121), so a fixture test
# needs no card to name it and the missing-card case below is reachable.
write_test() {
  local repo="$1" test_path="$2" card="$3" body="$4"
  printf '#!/usr/bin/env bash\n# %s card=%s\n%s\n# %s\n' \
    "$mk_begin" "$card" "$body" "$mk_end" > "$repo/$test_path"
}

write_card() {
  local repo="$1" card="$2" test_path="$3" digest="$4"
  cat > "$repo/$card" <<CARD
# Stage card fixture

## Contract test

- **Test file:** $test_path
- **Assertions digest:** \`$digest\`
CARD
}

digest_of() { ( cd "$1" && bash "$gate" print "$2" ); }
commit_all() { ( cd "$1" && git add -A && git commit -qm "$2" ); }

# Runs one gate mode inside a fixture and records exit code and combined
# output under a label, so the assertions below read values, not processes.
run_gate() {
  local repo="$1" mode="$2" label="$3" rc=0
  ( cd "$repo" && bash "$gate" "$mode" ) >"$tmp_root/$label.out" 2>&1 || rc=$?
  printf '%s' "$rc"
}
gate_out() { cat "$tmp_root/$1.out"; }

fixture_test=scripts/fixture-smoke.sh
fixture_card=stage-cards/40-fixture.md

# --- a. a staged drift ------------------------------------------------------
# The block and its card land together, then the block drifts and the drift is
# staged. The index and the tree agree about the drift; the two modes must too.
printf '== a. a drifted block that has been staged ==\n' >&2
a_repo="$(make_gate_repo staged-drift)"
write_test "$a_repo" "$fixture_test" "$fixture_card" 'echo original'
write_card "$a_repo" "$fixture_card" "$fixture_test" "$(digest_of "$a_repo" "$fixture_test")"
commit_all "$a_repo" baseline
write_test "$a_repo" "$fixture_test" "$fixture_card" 'echo drifted'
( cd "$a_repo" && git add "$fixture_test" )
a_staged_rc="$(run_gate "$a_repo" --staged a-staged)"
a_worktree_rc="$(run_gate "$a_repo" --worktree a-worktree)"

# --- b. a clean staged pair -------------------------------------------------
# A new test and its card, digest matching, both staged and nothing unstaged.
# This is the tree an orchestrator has just before committing a landing.
printf '== b. a matching test and card, both staged ==\n' >&2
b_repo="$(make_gate_repo staged-clean)"
write_test "$b_repo" "$fixture_test" "$fixture_card" 'echo clean'
write_card "$b_repo" "$fixture_card" "$fixture_test" "$(digest_of "$b_repo" "$fixture_test")"
( cd "$b_repo" && git add -A )
b_staged_rc="$(run_gate "$b_repo" --staged b-staged)"
b_worktree_rc="$(run_gate "$b_repo" --worktree b-worktree)"

# --- c. the one divergence the two modes are allowed -----------------------
# The drift is staged; the card's new digest is written but not staged. The
# commit would be inconsistent and the tree is consistent, and each mode is
# asked about a different one of those. Pinned so the fix does not collapse
# the two modes into one.
printf '== c. a drift staged, its card re-recorded only in the tree ==\n' >&2
c_repo="$(make_gate_repo split)"
write_test "$c_repo" "$fixture_test" "$fixture_card" 'echo original'
write_card "$c_repo" "$fixture_card" "$fixture_test" "$(digest_of "$c_repo" "$fixture_test")"
commit_all "$c_repo" baseline
write_test "$c_repo" "$fixture_test" "$fixture_card" 'echo drifted'
( cd "$c_repo" && git add "$fixture_test" )
write_card "$c_repo" "$fixture_card" "$fixture_test" "$(digest_of "$c_repo" "$fixture_test")"
c_staged_rc="$(run_gate "$c_repo" --staged c-staged)"
c_worktree_rc="$(run_gate "$c_repo" --worktree c-worktree)"

# --- d. a test whose card is not in the tree --------------------------------
# What stage 133's verifier met: the test names a card that does not exist
# here. Still a violation, and it must be reported as the violation it is.
printf '== d. a test naming a card that does not exist ==\n' >&2
absent_card=stage-cards/41-absent.md
d_repo="$(make_gate_repo orphan)"
write_test "$d_repo" scripts/orphan-smoke.sh "$absent_card" 'echo orphan'
d_worktree_rc="$(run_gate "$d_repo" --worktree d-worktree)"
( cd "$d_repo" && git add scripts/orphan-smoke.sh )
d_staged_rc="$(run_gate "$d_repo" --staged d-staged)"

# --- e. nothing changed at all ---------------------------------------------
# Card 129's "nothing to inspect" exit stays distinct from a pass in both
# modes; widening the worktree mode must not turn an empty tree into a pass.
printf '== e. a tree with nothing changed ==\n' >&2
e_repo="$(make_gate_repo untouched)"
write_test "$e_repo" "$fixture_test" "$fixture_card" 'echo settled'
write_card "$e_repo" "$fixture_card" "$fixture_test" "$(digest_of "$e_repo" "$fixture_test")"
commit_all "$e_repo" baseline
e_staged_rc="$(run_gate "$e_repo" --staged e-staged)"
e_worktree_rc="$(run_gate "$e_repo" --worktree e-worktree)"

printf '\n== assertions ==\n' >&2
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/134-the-gate-describes-the-tree-it-is-shown.md
check "the staged mode fails a staged drift" "$(eq 1 "$a_staged_rc")"
check "the worktree mode fails the same staged drift" "$(eq 1 "$a_worktree_rc")"
check "the worktree mode names the drift rather than calling the tree unchanged" "$(has "$(gate_out a-worktree)" 'frozen assertions changed')"
check "the staged mode passes a matching staged pair" "$(eq 0 "$b_staged_rc")"
check "the worktree mode passes the same matching staged pair" "$(eq 0 "$b_worktree_rc")"
check "the worktree mode does not call a staged pair nothing to inspect" "$(lacks "$(gate_out b-worktree)" 'no relevant changed files')"
check "the staged mode judges the commit: a card re-recorded only in the tree is not in it" "$(eq 1 "$c_staged_rc")"
check "the staged mode says which side is missing" "$(has "$(gate_out c-staged)" 'not in this commit')"
check "the worktree mode judges the tree: the same re-recorded card passes there" "$(eq 0 "$c_worktree_rc")"
check "a test naming an absent card fails the worktree mode" "$(eq 1 "$d_worktree_rc")"
check "the worktree mode says the card does not exist" "$(has "$(gate_out d-worktree)" "card $absent_card does not exist")"
check "the worktree mode does not call an absent card a card without a digest line" "$(lacks "$(gate_out d-worktree)" "has no 'Assertions digest' line")"
check "no raw cat error reaches the operator from the worktree mode" "$(lacks "$(gate_out d-worktree)" 'cat: ')"
check "a test naming an absent card fails the staged mode" "$(eq 1 "$d_staged_rc")"
check "the staged mode says the card does not exist" "$(has "$(gate_out d-staged)" "card $absent_card does not exist")"
check "no raw cat error reaches the operator from the staged mode" "$(lacks "$(gate_out d-staged)" 'cat: ')"
check "an untouched tree is still nothing to inspect in the staged mode" "$(eq 2 "$e_staged_rc")"
check "an untouched tree is still nothing to inspect in the worktree mode" "$(eq 2 "$e_worktree_rc")"
# AUTOMETTA-CONTRACT-END

if (( fail )); then
  printf '\ngate-consistency-smoke: FAIL\n' >&2
  exit 1
fi
printf '\ngate-consistency-smoke: the gate describes the tree it is shown\n' >&2

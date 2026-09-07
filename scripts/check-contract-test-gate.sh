#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Contract-test freeze gate for the dispatch contract.
#
# A contract test carries a frozen assertion block between two markers:
#
#   AUTOMETTA-CONTRACT-BEGIN card=<path-to-stage-card>
#   ... assertions ...
#   AUTOMETTA-CONTRACT-END
#
# The matching stage card records the block digest on an "Assertions digest:"
# line. The block and the card cannot move independently: a changed assertion
# changes the digest, and a changed digest must be re-recorded in the card, or
# this gate rejects the change. See docs/dispatch-contract.md (Contract tests).
#
# Usage:
#   check-contract-test-gate.sh print <test-file>
#       Print sha256:<hex> of the test's frozen block, to paste into the
#       card's "Assertions digest" line.
#   check-contract-test-gate.sh
#       Compare the staged index with HEAD and gate that change set.
#       Exit non-zero on the first violation.
#   check-contract-test-gate.sh --worktree
#       Compare the working tree and index with HEAD, plus untracked candidates.

MARKER_BEGIN='AUTOMETTA-CONTRACT-BEGIN'
MARKER_END='AUTOMETTA-CONTRACT-END'

warn() { printf 'contract-gate: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

# Frozen block = lines strictly between the two markers, read from stdin.
# Exit 3 if no BEGIN marker is present, exit 4 if more than one block.
extract_block() {
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    index($0, b) { if (seen++) found_extra=1; inblk=1; next }
    index($0, e) { inblk=0; next }
    inblk        { print }
    END          { if (!seen) exit 3; if (found_extra) exit 4 }
  '
}

# Card path declared on the BEGIN marker line (card=<path>), read from stdin.
card_path_from_marker() {
  awk -v b="$MARKER_BEGIN" '
    index($0, b) {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^card=/) { sub(/^card=/, "", $i); print $i; exit }
    }'
}

# First sha256:... token on an "Assertions digest" line, backticks stripped.
declared_digest() {
  awk '
    /Assertions digest/ {
      for (i = 1; i <= NF; i++) { t = $i; gsub(/`/, "", t); if (t ~ /^sha256:/) { print t; exit } }
    }'
}

# To-be-committed content of a path: the staged index entry if present,
# otherwise the working-tree file.
staged_content() {
  if git show ":$1" >/dev/null 2>&1; then
    git show ":$1"
  else
    cat -- "$1"
  fi
}

working_content() {
  cat -- "$1"
}

# Every path declared as a "Test file:" line in any stage card on disk,
# paired with the card that names it, as "<path>\t<card>". Reads
# to-be-committed content so a card and the test it names can be staged in
# the same commit. Same glob set list-cards.sh uses, so a card is found
# under whichever layout (current or legacy) the repo actually has.
test_file_declarations() {
  local reader="${1:-staged_content}" pattern card
  for pattern in stage-cards/*.md docs/stages/*.md examples/self-host/*.md; do
    for card in $pattern; do
      [ -f "$card" ] || continue
      "$reader" "$card" \
        | awk '
            /^[[:space:]]*-[[:space:]]+\*\*Test file:\*\*/ {
              line = $0
              gsub(/[*`]/, "", line)
              sub(/^.*Test file:[[:space:]]*/, "", line)
              print line
            }' \
        | tr ',' '\n' \
        | while IFS= read -r path; do
            path="$(printf '%s' "$path" \
              | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                    -e 's/[[:space:]]*([^)]*)[[:space:]]*$//')"
            [ -n "$path" ] || continue
            case "$path" in
              None|'<<fill at dispatch>>'|'<<contract-test-path-or-None>>') continue ;;
            esac
            printf '%s\t%s\n' "$path" "$card"
          done
    done
  done
}

# Digest the frozen block arriving on stdin. Uniform across print and gate so
# the two always agree on the same bytes.
digest_block() {
  local block rc=0
  block="$(extract_block)" || rc=$?
  case "$rc" in
    3) die "no $MARKER_BEGIN marker found" ;;
    4) die "more than one frozen block in file; one block per test" ;;
  esac
  printf '%s' "$block" | shasum -a 256 | awk '{print "sha256:" $1}'
}

cmd_print() {
  [ -n "${1:-}" ] || die "usage: check-contract-test-gate.sh print <test-file>"
  [ -f "$1" ]     || die "no such file: $1"
  digest_block < "$1"
}

cmd_gate() {
  local mode="$1" changed untracked f card recomputed declared violations=0 declarations naming_card content

  case "$mode" in
    staged)
      changed="$(git diff --cached --name-only --diff-filter=ACM)"
      content=staged_content
      ;;
    worktree)
      changed="$(git diff HEAD --name-only --diff-filter=ACM)"
      content=working_content
      ;;
    *) die "internal error: unknown gate mode $mode" ;;
  esac

  declarations="$(test_file_declarations "$content")"

  if [ "$mode" = worktree ]; then
    untracked="$(git ls-files --others --exclude-standard)"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      naming_card="$(printf '%s\n' "$declarations" | awk -F'\t' -v f="$f" '$1 == f { print $2; exit }')"
      case "$f" in
        scripts/*-smoke.sh) changed="$(printf '%s\n%s\n' "$changed" "$f" | awk 'NF && !seen[$0]++')" ;;
        *) [ -n "$naming_card" ] && changed="$(printf '%s\n%s\n' "$changed" "$f" | awk 'NF && !seen[$0]++')" ;;
      esac
    done <<EOF
$untracked
EOF
  fi

  if [ -z "$changed" ]; then
    if [ "$mode" = staged ]; then
      warn "no staged files to inspect; use --worktree for unstaged dispatch changes"
    else
      warn "no relevant changed files to inspect in the working tree"
    fi
    exit 2
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue

    naming_card="$(printf '%s\n' "$declarations" | awk -F'\t' -v f="$f" '$1 == f { print $2; exit }')"
    case "$f" in
      scripts/*-smoke.sh) ;;
      *) [ -n "$naming_card" ] || continue ;;
    esac

    if "$content" "$f" | grep -q "$MARKER_BEGIN"; then
      card="$("$content" "$f" | card_path_from_marker)"
      if [ -z "$card" ]; then
        warn "$f: $MARKER_BEGIN marker has no card=<path>"
        violations=$((violations + 1)); continue
      fi

      recomputed="$("$content" "$f" | digest_block)" || { violations=$((violations + 1)); continue; }
      if ! "$content" "$card" >/dev/null 2>&1; then
        warn "$f: card $card does not exist"
        violations=$((violations + 1)); continue
      fi
      declared="$("$content" "$card" | declared_digest || true)"

      if [ -z "$declared" ]; then
        warn "$f: card $card has no 'Assertions digest' line"
        violations=$((violations + 1)); continue
      fi

      if [ "$recomputed" != "$declared" ]; then
        if printf '%s\n' "$changed" | grep -qx -- "$card"; then
          warn "$f: assertions changed but card $card still declares $declared (recomputed $recomputed); update the card's 'Assertions digest' line in this commit"
        else
          warn "$f: frozen assertions changed but their card $card is not in this commit (declared $declared, recomputed $recomputed)"
        fi
        violations=$((violations + 1))
      fi
      continue
    fi

    # No marker in this file. A file no card names as its contract test is
    # genuinely not this gate's business and is skipped, as before. A file a
    # card DOES name as its contract test is supposed to carry a frozen
    # block; its absence is a violation, not a skip -- that gap is the
    # fail-open defect this rewrite closes.
    if [ -n "$naming_card" ]; then
      warn "$f: no $MARKER_BEGIN marker found, but $naming_card names it as this stage's contract test"
    else
      warn "$f: no $MARKER_BEGIN marker found, but scripts/*-smoke.sh files are contract-test candidates"
    fi
    violations=$((violations + 1))
  done <<EOF
$changed
EOF

  [ "$violations" -eq 0 ] || die "$violations contract-test freeze violation(s); see messages above"
}

main() {
  case "${1:-}" in
    print)        shift; cmd_print "$@" ;;
    ""|--staged)  cmd_gate staged ;;
    --worktree)    cmd_gate worktree ;;
    *)             die "unknown argument: $1 (use 'print <file>', --staged, or --worktree)" ;;
  esac
}

main "$@"

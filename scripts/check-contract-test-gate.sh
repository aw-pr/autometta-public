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
#       Gate the staged change set. Exit non-zero on the first violation.
#       Suitable for a verifier acceptance step or a pre-commit chain.

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
  local staged f card recomputed declared violations=0

  staged="$(git diff --cached --name-only --diff-filter=ACM)"
  [ -n "$staged" ] || exit 0

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    staged_content "$f" | grep -q "$MARKER_BEGIN" || continue

    card="$(staged_content "$f" | card_path_from_marker)"
    if [ -z "$card" ]; then
      warn "$f: $MARKER_BEGIN marker has no card=<path>"
      violations=$((violations + 1)); continue
    fi

    recomputed="$(staged_content "$f" | digest_block)" || { violations=$((violations + 1)); continue; }
    declared="$(staged_content "$card" | declared_digest || true)"

    if [ -z "$declared" ]; then
      warn "$f: card $card has no 'Assertions digest' line"
      violations=$((violations + 1)); continue
    fi

    if [ "$recomputed" != "$declared" ]; then
      if printf '%s\n' "$staged" | grep -qx -- "$card"; then
        warn "$f: assertions changed but card $card still declares $declared (recomputed $recomputed); update the card's 'Assertions digest' line in this commit"
      else
        warn "$f: frozen assertions changed but their card $card is not in this commit (declared $declared, recomputed $recomputed)"
      fi
      violations=$((violations + 1))
    fi
  done <<EOF
$staged
EOF

  [ "$violations" -eq 0 ] || die "$violations contract-test freeze violation(s); see messages above"
}

main() {
  case "${1:-}" in
    print)        shift; cmd_print "$@" ;;
    ""|--staged)  cmd_gate ;;
    *)            die "unknown argument: $1 (use 'print <file>' or no args)" ;;
  esac
}

main "$@"

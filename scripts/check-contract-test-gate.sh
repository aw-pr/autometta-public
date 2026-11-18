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
# A regression smoke that no stage card freezes instead declares:
#
#   AUTOMETTA-CONTRACT-NONE reason=<short reason>
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
#   check-contract-test-gate.sh --verify-card <card>
#       Verify the named oracle even when unchanged, then gate worktree changes.

MARKER_BEGIN='AUTOMETTA-CONTRACT-BEGIN'
MARKER_END='AUTOMETTA-CONTRACT-END'
MARKER_NONE='AUTOMETTA-CONTRACT-NONE'

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

cmd_verify_card() {
  [ "$#" -eq 1 ] || die "usage: check-contract-test-gate.sh --verify-card <card>"
  local rc=0 named_rc=0
  python3 - "$1" "$0" <<'PY' || named_rc=$?
from pathlib import Path
import re
import subprocess
import sys

card = Path(sys.argv[1]).resolve()
root = Path.cwd().resolve()

def fail(message):
    print(f"contract-gate: {message}", file=sys.stderr)
    raise SystemExit(1)

if not card.is_file():
    fail(f"stage card does not exist: {card}")
text = card.read_text(encoding="utf-8")
sections = re.findall(r"^## Contract tests?[ \t]*\r?$(.*?)(?=^## |\Z)", text,
                      re.MULTILINE | re.DOTALL | re.IGNORECASE)
if len(sections) > 1:
    fail("more than one Contract test section")
if not sections:
    # Older prose-only cards predate the optional Contract test section.
    print("contract-gate: named oracle NONE (no Contract test section)")
    raise SystemExit(2)
else:
    section = sections[0]
    fields = {}
    for key in ("Test file", "Assertions digest"):
        values = re.findall(r"^\s*-?\s*" + key + r":\s*(.*?)\s*$",
                            section.replace("*", "").replace("`", ""), re.MULTILINE)
        if len(values) > 1:
            fail(f"duplicate {key} declaration")
        fields[key] = values[0] if values else ""
    test = fields["Test file"]
    declared = fields["Assertions digest"]
    none = re.compile(r"None(?:\s*\([^\n]*\)|\s*[:\-].*)?\.?", re.IGNORECASE)
    if none.fullmatch(test or section.strip().replace("`", "")):
        if declared and not none.fullmatch(declared):
            fail("no-oracle card declares an assertions digest")
        print("contract-gate: named oracle NONE (explicit no-oracle card)")
        raise SystemExit(2)
    else:
        if not test or "," in test or "<<" in test:
            fail("missing or malformed Test file declaration")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", declared):
            fail("missing or malformed Assertions digest declaration")
        test = re.sub(r"\s+\([^)]*\)\s*$", "", test)
        path = (root / test).resolve()
        if Path(test).is_absolute() or not path.is_relative_to(root):
            fail(f"test must be relative to the subscriber root: {test}")
        if not path.is_file():
            fail(f"named oracle does not exist: {test}")
        lines = path.read_text(encoding="utf-8").splitlines()
        begins = [i for i, line in enumerate(lines) if "AUTOMETTA-CONTRACT-BEGIN" in line]
        ends = [i for i, line in enumerate(lines) if "AUTOMETTA-CONTRACT-END" in line]
        if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
            fail(f"{test}: expected one complete frozen assertion block")
        if any("AUTOMETTA-CONTRACT-NONE" in line for line in lines):
            fail(f"{test}: named oracle cannot opt out of its frozen block")
        owners = re.findall(r"\bcard=(\S+)", lines[begins[0]])
        if len(owners) != 1:
            fail(f"{test}: marker needs one card=<path>")
        expected = card
        if not card.is_relative_to(root):
            # A dispatch may read its card from the subscriber's main checkout.
            result = subprocess.run(["git", "-C", str(card.parent), "rev-parse", "--show-toplevel"],
                                    text=True, capture_output=True)
            if result.returncode:
                fail("external stage card is not in a subscriber checkout")
            expected = root / card.relative_to(Path(result.stdout.strip()).resolve())
        if (root / owners[0]).resolve() != expected.resolve():
            fail(f"{test}: marker belongs to {owners[0]}, not the supplied card")
        result = subprocess.run(["bash", sys.argv[2], "print", str(path)],
                                text=True, capture_output=True)
        actual = result.stdout.strip()
        print(f"contract-gate: named oracle {test}; declared={declared}; actual={actual}")
        if result.returncode or actual != declared:
            fail(f"{test}: named oracle digest mismatch")
PY
  case "$named_rc" in
    0|2) ;;
    *) return "$named_rc" ;;
  esac
  if [ "$named_rc" -eq 2 ] && {
    [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != true ] ||
      ! git rev-parse --verify HEAD >/dev/null 2>&1
  }; then
    printf 'contract-gate: no oracle and no worktree revision; change gate not applicable\n'
    return 0
  fi
  (cmd_gate worktree) || rc=$?
  case "$rc" in
    0|2) printf 'contract-gate: combined card and worktree check PASS\n' ;;
    *) return "$rc" ;;
  esac
}

cmd_gate() {
  local mode="$1" changed untracked f card recomputed declared violations=0 declarations naming_card naming_cards content

  case "$mode" in
    staged)
      changed="$(git diff --cached --name-only --diff-filter=ACM)" || return $?
      content=staged_content
      ;;
    worktree)
      changed="$(git diff HEAD --name-only --diff-filter=ACM)" || return $?
      content=working_content
      ;;
    *) die "internal error: unknown gate mode $mode" ;;
  esac

  declarations="$(test_file_declarations "$content")" || return $?

  if [ "$mode" = worktree ]; then
    untracked="$(git ls-files --others --exclude-standard)" || return $?
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

    naming_cards="$(printf '%s\n' "$declarations" | awk -F'\t' -v f="$f" '$1 == f { print $2 }')"
    naming_card="$(printf '%s\n' "$naming_cards" | awk 'NF { print; exit }')"
    case "$f" in
      scripts/*-smoke.sh) ;;
      *) [ -n "$naming_card" ] || continue ;;
    esac

    if "$content" "$f" | grep -q "$MARKER_NONE"; then
      if "$content" "$f" | grep -q "$MARKER_BEGIN"; then
        warn "$f: cannot carry both $MARKER_NONE and $MARKER_BEGIN markers"
        violations=$((violations + 1)); continue
      fi

      if ! "$content" "$f" | grep -Eq "^[[:space:]]*#[[:space:]]*$MARKER_NONE[[:space:]]+reason=[^[:space:]]"; then
        warn "$f: $MARKER_NONE marker needs a reason=<text>"
        violations=$((violations + 1)); continue
      fi

      while IFS= read -r card; do
        [ -n "$card" ] || continue
        declared="$("$content" "$card" | declared_digest || true)"
        if [ -n "$declared" ]; then
          warn "$f: $MARKER_NONE contradicts $card, which declares $declared"
          violations=$((violations + 1)); break
        fi
      done <<EOF
$naming_cards
EOF
      continue
    fi

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
    --verify-card) shift; cmd_verify_card "$@" ;;
    *)             die "unknown argument: $1 (use 'print <file>', --staged, --worktree, or --verify-card <card>)" ;;
  esac
}

main "$@"

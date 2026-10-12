#!/usr/bin/env bash
# Offline proof for stage card 158: preserving a failed attempt never reaches
# outside the run worktree.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export PHAT_CONTROLLER_HOME="$fixture/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/log"
# tick.sh resolves its controller paths while it is sourced.
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"
set -euo pipefail
IFS=$'\n\t'

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/158-a-preserve-stays-inside-its-worktree.md
# The tick reads every backticked token with a slash in a card's Deliverables
# as a deliverable. On 2026-10-12 card 157 quoted /var, /private/var and a
# bare slash there, and its verifier FAIL made the tick walk the system disk.
# A preserve may only ever add files that physically live in the worktree.
wt="$fixture/wt"
mkdir -p "$wt/scripts" "$wt/build" "$fixture/outside" "$fixture/shared-state"
printf 'secret\n' >"$fixture/outside/file.txt"
printf '{}\n' >"$fixture/shared-state/state.json"
(
  cd "$wt"
  git init -q -b dev
  git config user.name Smoke
  git config user.email smoke@local
  printf 'build/\nstate\n' >.gitignore
  git add .gitignore
  git commit -q -m init
)
ln -s "$fixture/shared-state" "$wt/state"
printf 'echo real\n' >"$wt/scripts/real.sh"
printf 'out\n' >"$wt/build/out.txt"
wt_phys="$(cd "$wt" && pwd -P)"

card="$fixture/158-card.md"
cat >"$card" <<'CARD'
# Stage card 158-fixture

## Deliverables

1. `scripts/real.sh`: the worker's new file.
2. `build/`: an ignored output directory the card asks for.
3. Never `/`, `/var`, `~/notes.txt`, `../outside/file.txt`, `state/` or
   `state/state.json`: none of these lives in the worktree.

## Constraints

- None.
CARD

paths="$(card_deliverable_paths "$card")"
for bad in / /var '~/notes.txt' ../outside/file.txt; do
  if printf '%s\n' "$paths" | grep -qxF -- "$bad"; then
    fail "158: card_deliverable_paths still offers '$bad' as a deliverable"
  fi
done
printf '%s\n' "$paths" | grep -qxF scripts/real.sh \
  || fail "158: card_deliverable_paths dropped the real deliverable scripts/real.sh"
printf '%s\n' "$paths" | grep -qxF build/ \
  || fail "158: card_deliverable_paths dropped the ignored deliverable build/"

# Record every find the preserve runs, and search only inside the worktree,
# so a regression shows up as a recorded path rather than a disk walk.
: >"$fixture/find-args"
find() {
  printf '%s\n' "$1" >>"$fixture/find-args"
  local target
  target="$(cd "$1" 2>/dev/null && pwd -P || true)"
  case "$target/" in
    "$wt_phys"/*) command find "$@" ;;
    *) return 0 ;;
  esac
}

(cd "$wt" && force_add_card_deliverables "$wt" 158-fixture "verifier FAIL" "$card")
staged="$(git -C "$wt" diff --cached --name-only | sort | tr '\n' ' ')"
[[ "$staged" == "build/out.txt scripts/real.sh " ]] \
  || fail "158: the preserve staged '$staged', want only build/out.txt and scripts/real.sh"
while IFS= read -r searched; do
  [[ -n "$searched" ]] || continue
  resolved="$(cd "$wt" && cd "$searched" 2>/dev/null && pwd -P || printf 'unresolvable:%s' "$searched")"
  case "$resolved/" in
    "$wt_phys"/*) ;;
    *) fail "158: the preserve searched '$searched', which is outside the worktree" ;;
  esac
done <"$fixture/find-args"

git -C "$wt" reset -q
rm -rf "$wt/scripts" "$wt/build"
outside_only="$fixture/158-outside-only.md"
cat >"$outside_only" <<'CARD'
# Stage card 158-outside-only

## Deliverables

1. `/`, `state/` and `../outside/file.txt` only.
CARD
if card_deliverables_exist "$wt" "$outside_only"; then
  fail "158: a clean worktree whose card names only outside paths is treated as holding work"
fi
# AUTOMETTA-CONTRACT-END

printf 'PASS: a preserve adds only what lives in the run worktree\n'

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Autometta vendor freshness check.
#
# Compares the Autometta templates and scripts vendored into this repo against
# the canonical Autometta checkout on this machine, and reports any that have
# drifted. Run it after a `git pull` of the Autometta source, or as a
# pre-flight before an orchestrator session, to confirm the vendored contract
# is still current. It reads the provenance stamp (.autometta-vendor) to learn
# which sha this copy came from, takes the file set from upstream's single
# definition (scripts/vendor-set.sh), then content-hashes each file.
#
# The set comes from upstream rather than from the stamp on purpose. A stamp
# records the set as it stood when the copy was made, so a file added upstream
# since then would never be looked at, and this check would call a repo current
# that was in fact missing part of the contract. A file in the stamp that
# upstream has since retired is reported as RETIRED and is not drift.
#
# Canonical source resolution, first hit wins: $AUTOMETTA_ROOT, then
# ~/repos/autometta.
#
# A template's `<<placeholder>>` slots are meant to be filled downstream, so a
# file differing from upstream only in filled placeholders is reported as
# FILLED rather than DRIFT. `autometta refresh-repo` preserves such a file
# rather than overwriting the fill.
#
# Exit 0 if every vendored file matches upstream (or differs only in filled
# placeholders), 1 if any drifted or went missing, 2 on a setup problem (no
# stamp, no source checkout).

stamp=".autometta-vendor"
warn() { printf 'vendor-check: %s\n' "$*" >&2; }

[ -f "$stamp" ] || { warn "no $stamp in this repo; was Autometta vendored here?"; exit 2; }

src="${AUTOMETTA_ROOT:-$HOME/repos/autometta}"
[ -d "$src" ] || { warn "canonical Autometta checkout not found at $src; set AUTOMETTA_ROOT"; exit 2; }

vendor_set="$src/scripts/vendor-set.sh"
[ -f "$vendor_set" ] || {
  warn "no scripts/vendor-set.sh in $src; that checkout predates the single vendored-set definition, so this check has no list to read. Update the Autometta checkout at $src."
  exit 2
}
# shellcheck source=./vendor-set.sh
. "$vendor_set"

vendored_from="$(autometta_vendor_stamp_field "$stamp" vendored_from)"
upstream_head="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo unknown)"

printf 'Autometta source: %s (HEAD %s)\n' "$src" "$upstream_head"
printf 'Vendored from:    %s\n\n' "${vendored_from:-unknown}"

canonical="$(autometta_vendored_files)"

drift=0 missing=0 ok=0 filled=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ ! -f "$src/$f" ]; then
    printf '  ORPHAN %s (in the upstream set but not in the upstream tree)\n' "$f"; drift=$((drift + 1)); continue
  fi
  if [ ! -f "$f" ]; then
    printf '  GONE   %s (vendored file missing locally)\n' "$f"; missing=$((missing + 1)); continue
  fi
  if [ "$(autometta_file_digest "$f")" = "$(autometta_file_digest "$src/$f")" ]; then
    ok=$((ok + 1))
  elif autometta_only_filled_placeholders "$f" "$src/$f"; then
    printf '  FILLED %s (placeholders completed downstream, not drift)\n' "$f"
    filled=$((filled + 1))
  else
    printf '  DRIFT  %s\n' "$f"; drift=$((drift + 1))
  fi
done <<< "$canonical"

# A file this copy was given that upstream has since dropped from the set. Not
# drift: nothing upstream governs it any more, so it is the operator's to keep
# or delete.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case $'\n'"$canonical"$'\n' in
    *$'\n'"$f"$'\n'*) continue ;;
  esac
  printf '  RETIRED %s (no longer in the upstream vendored set)\n' "$f"
done < <(autometta_vendor_stamp_files "$stamp")

printf '\n%d up to date, %d filled, %d drifted, %d missing locally.\n' "$ok" "$filled" "$drift" "$missing"

if [ "$drift" -gt 0 ] || [ "$missing" -gt 0 ]; then
  printf 'Refresh this repo from %s with: autometta refresh-repo .\n' "$src"
  exit 1
fi
printf 'Vendored Autometta contract is current.\n'

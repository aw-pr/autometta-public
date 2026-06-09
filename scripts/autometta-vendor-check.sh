#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Autometta vendor freshness check.
#
# Compares the Autometta templates and scripts vendored into this repo against
# the canonical Autometta checkout on this machine, and reports any that have
# drifted. Run it after a `git pull` of the Autometta source, or as a
# pre-flight before an orchestrator session, to confirm the vendored contract
# is still current. It reads the provenance stamp (.autometta-vendor) the
# setup step wrote, then content-hashes each listed file against upstream.
#
# Canonical source resolution, first hit wins: $AUTOMETTA_ROOT, then
# ~/repos/autometta.
#
# Exit 0 if every vendored file matches upstream, 1 if any drifted or went
# missing, 2 on a setup problem (no stamp, no source checkout).

stamp=".autometta-vendor"
warn() { printf 'vendor-check: %s\n' "$*" >&2; }

[ -f "$stamp" ] || { warn "no $stamp in this repo; was Autometta vendored here?"; exit 2; }

src="${AUTOMETTA_ROOT:-$HOME/repos/autometta}"
[ -d "$src" ] || { warn "canonical Autometta checkout not found at $src; set AUTOMETTA_ROOT"; exit 2; }

digest() { shasum -a 256 "$1" | awk '{print $1}'; }

vendored_from="$(awk -F': ' '/^vendored_from:/ {print $2; exit}' "$stamp")"
upstream_head="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo unknown)"

printf 'Autometta source: %s (HEAD %s)\n' "$src" "$upstream_head"
printf 'Vendored from:    %s\n\n' "${vendored_from:-unknown}"

drift=0 missing=0 ok=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ ! -f "$f" ]; then
    printf '  GONE   %s (vendored file missing locally)\n' "$f"; missing=$((missing + 1)); continue
  fi
  if [ ! -f "$src/$f" ]; then
    printf '  ORPHAN %s (no longer present upstream)\n' "$f"; drift=$((drift + 1)); continue
  fi
  if [ "$(digest "$f")" = "$(digest "$src/$f")" ]; then
    ok=$((ok + 1))
  else
    printf '  DRIFT  %s\n' "$f"; drift=$((drift + 1))
  fi
done < <(awk -F': ' '/^file:/ {print $2}' "$stamp")

printf '\n%d up to date, %d drifted, %d missing locally.\n' "$ok" "$drift" "$missing"

if [ "$drift" -gt 0 ] || [ "$missing" -gt 0 ]; then
  printf 'Re-vendor the affected files from %s and refresh %s (see the autometta-setup skill).\n' "$src" "$stamp"
  exit 1
fi
printf 'Vendored Autometta contract is current.\n'

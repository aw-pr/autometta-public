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
# Templates carry `<<placeholder>>` slots that a subscriber is meant to fill
# (e.g. <<family-specific-notes-or-none>>). A filled slot is the template
# working as designed, so a plain content hash would report every correctly
# adopted repo as drifted, for ever. Such a file is reported as FILLED rather
# than DRIFT when every line that differs from upstream is one where upstream
# holds a placeholder. Anything else still counts as drift.
#
# Exit 0 if every vendored file matches upstream (or differs only in filled
# placeholders), 1 if any drifted or went missing, 2 on a setup problem (no
# stamp, no source checkout).

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

# True when the only lines differing from upstream are ones where upstream
# holds a << >> placeholder. Uses a unified diff with no context so each hunk
# is exactly the changed run; a hunk whose removed lines are all placeholders
# is a fill, anything else is drift.
only_filled_placeholders() {
  local local_f="$1" up_f="$2" body line added=0 removed=0
  # Drop diff's two file-header lines before reading +/- markers, otherwise
  # the `---`/`+++` header is mistaken for content. Do not filter with a
  # `^-[^-]` style pattern: every markdown bullet begins with a dash, so that
  # discards exactly the lines most likely to hold a placeholder.
  body="$(diff -U0 "$up_f" "$local_f" 2>/dev/null | tail -n +3 || true)"
  [ -n "$body" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      @*) continue ;;
      +*) added=$((added + 1)) ;;
      -*)
        removed=$((removed + 1))
        # An upstream line that is not a placeholder cannot be a fill site.
        case "${line#-}" in
          *'<<'*'>>'*) ;;
          *) return 1 ;;
        esac ;;
    esac
  done <<< "$body"
  # A fill REPLACES a placeholder, so it both removes and adds. Removals with
  # nothing added mean upstream gained placeholder lines this copy never got,
  # which is ordinary staleness and must still read as drift.
  [ "$removed" -gt 0 ] && [ "$added" -gt 0 ]
}

drift=0 missing=0 ok=0 filled=0
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
  elif only_filled_placeholders "$f" "$src/$f"; then
    printf '  FILLED %s (placeholders completed downstream, not drift)\n' "$f"
    filled=$((filled + 1))
  else
    printf '  DRIFT  %s\n' "$f"; drift=$((drift + 1))
  fi
done < <(awk -F': ' '/^file:/ {print $2}' "$stamp")

printf '\n%d up to date, %d filled, %d drifted, %d missing locally.\n' "$ok" "$filled" "$drift" "$missing"

if [ "$drift" -gt 0 ] || [ "$missing" -gt 0 ]; then
  printf 'Re-vendor the affected files from %s and refresh %s (see the autometta-setup skill).\n' "$src" "$stamp"
  exit 1
fi
printf 'Vendored Autometta contract is current.\n'

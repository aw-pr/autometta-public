#!/usr/bin/env bash
# The vendored set: one definition, read by everything that vendors or checks.
#
# Source this file; do not execute it.
#
# A subscriber holds a copy of the dispatch contract -- four templates and two
# scripts -- recorded in its .autometta-vendor stamp. Until this file existed
# the list lived in three places: prose in the autometta-setup skill, a shell
# loop in that skill's copy-paste block, and the `file:` lines of whichever
# stamp a repo happened to have written. Nothing reconciled them, so "what is
# vendored" had no answer that could be checked, only three answers that
# happened to agree. The vendor step and the freshness check now read the same
# list from here, which is the only way they cannot disagree.
#
# Adding a file to the set is a deliberate change to the contract: add it here,
# then push it out with `autometta refresh-all-repos`.

autometta_vendored_files() {
  cat <<'FILES'
templates/worker-prompt.md
templates/verifier-prompt.md
templates/orchestrator-checklist.md
templates/stage-card.md
scripts/check-contract-test-gate.sh
scripts/autometta-vendor-check.sh
FILES
}

# The stamp is written by the vendor step and read by the check, so its shape
# is part of the contract too. `vendored_from` is the short sha of the
# autometta root the copy came from; the `file:` lines record the set as it
# stood at that sha, which is how a later check can tell a file upstream has
# retired from one that has gone missing locally.
autometta_vendor_stamp_name=".autometta-vendor"

autometta_vendor_stamp_files() {
  local stamp_path="$1"
  [ -f "$stamp_path" ] || return 0
  sed -n 's/^file:[[:space:]]*//p' "$stamp_path"
}

autometta_vendor_stamp_field() {
  local stamp_path="$1" key="$2" value
  [ -f "$stamp_path" ] || return 0
  value="$(sed -n "s/^${key}:[[:space:]]*//p" "$stamp_path" | head -n1)"
  value="${value%\"}"; value="${value#\"}"
  printf '%s' "$value"
}

autometta_write_vendor_stamp() {
  local stamp_path="$1" source_sha="$2" f
  {
    printf '# Autometta vendor stamp. Refresh with: autometta refresh-repo .\n'
    printf 'source_repo: autometta\n'
    printf 'vendored_from: %s\n' "$source_sha"
    printf 'vendored_at: %s\n' "$(date +%Y-%m-%d)"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf 'file: %s\n' "$f"
    done < <(autometta_vendored_files)
  } > "$stamp_path"
}

autometta_file_digest() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# True when the only lines differing from upstream are ones where upstream
# holds a << >> placeholder. Uses a unified diff with no context so each hunk
# is exactly the changed run; a hunk whose removed lines are all placeholders
# is a fill, anything else is drift.
#
# Templates carry `<<placeholder>>` slots that a subscriber is meant to fill
# (e.g. <<family-specific-notes-or-none>>). A filled slot is the template
# working as designed, so a plain content hash would report every correctly
# adopted repo as drifted, for ever -- and a refresh that trusted that hash
# would overwrite the fill, which is the one thing a push must never do.
autometta_only_filled_placeholders() {
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

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# refresh-all-repos.sh: push the vendored dispatch contract to the whole fleet.
#
#   scripts/refresh-all-repos.sh [--dry-run]
#
# One release, every subscriber. It walks the registry in weight order and
# hands each repo to the same refresh that `autometta refresh-repo` uses, so a
# fleet push and a single push cannot behave differently.
#
# Everything it does not refresh, it names and says why. A fleet command that
# quietly omitted the retired entries, the repos that never vendored, or the
# one with a worker in flight would read as "covered everything" when it had
# covered five of nine, which is the kind of wrong answer that only surfaces
# weeks later as an unexplained drift.
#
# --dry-run reports exactly what a real run would change and writes nothing.
#
# Exit 0 when every enabled subscriber was refreshed or skipped for a stated
# reason, 1 if any repo failed outright.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./subscribers.sh
. "$script_dir/subscribers.sh"
# shellcheck source=./refresh-repo.sh
. "$script_dir/refresh-repo.sh"

subscribers_dir="$(autometta_subscribers_dir)"

usage() {
  printf 'Usage: %s [--dry-run]\n' "$(basename "$0")" >&2
  exit 1
}

dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    -h|--help) usage ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; usage ;;
  esac
  shift
done

if [[ ! -d "$subscribers_dir" ]]; then
  printf 'FAIL no subscriber registry at %s; run autometta init-host first\n' "$subscribers_dir" >&2
  exit 1
fi

autometta_resolve_root "$(autometta_self_root "$script_dir")"
src="$AUTOMETTA_ROOT_RESOLVED"
autometta_source_vendor_set_from_root "$src"
src_sha="$(autometta_root_sha "$src")"
if [[ "$src_sha" == "unknown" ]]; then
  printf 'FAIL autometta root %s reports no sha (not a checkout, no VERSION file); a stamp written from it would name nothing\n' "$src" >&2
  exit 1
fi

printf 'autometta source: %s (%s, via %s)\n' "$src" "$src_sha" "$AUTOMETTA_ROOT_ORIGIN"
printf 'registry:         %s\n' "$subscribers_dir"
if [[ "$dry_run" == "true" ]]; then
  printf 'mode:             dry run, nothing is written\n'
fi
printf '\n'

refreshed=0 skipped=0 failed=0
skip_lines=()

while IFS= read -r subscriber_file; do
  [[ -n "$subscriber_file" ]] || continue
  enabled="$(read_subscriber_field "$subscriber_file" "enabled")"
  repo_path="$(read_subscriber_field "$subscriber_file" "repo_path")"
  if [[ -z "$repo_path" ]]; then
    skip_lines+=("SKIP $subscriber_file: no repo_path in the subscriber file")
    skipped=$((skipped + 1))
    continue
  fi
  if [[ "$enabled" != "true" ]]; then
    skip_lines+=("SKIP $repo_path: subscriber is disabled (enabled: ${enabled:-unset})")
    skipped=$((skipped + 1))
    continue
  fi
  rc=0
  output="$(autometta_refresh_repo "$repo_path" "$dry_run" false "$src" "$src_sha")" || rc=$?
  case "$rc" in
    0)
      printf '%s\n\n' "$output"
      refreshed=$((refreshed + 1))
      ;;
    3)
      skip_lines+=("$output")
      skipped=$((skipped + 1))
      ;;
    *)
      printf '%s\n\n' "$output" >&2
      failed=$((failed + 1))
      ;;
  esac
done < <(sort_subscribers)

while IFS= read -r disabled_file; do
  [[ -n "$disabled_file" ]] || continue
  disabled_repo="$(read_subscriber_field "$disabled_file" "repo_path")"
  skip_lines+=("SKIP ${disabled_repo:-$disabled_file}: registry entry is retired ($(basename "$disabled_file"))")
  skipped=$((skipped + 1))
done < <(list_disabled_subscribers)

if [[ ${#skip_lines[@]} -gt 0 ]]; then
  printf 'Not refreshed:\n'
  for skip_line in "${skip_lines[@]}"; do
    printf '  %s\n' "$skip_line"
  done
  printf '\n'
fi

if [[ "$dry_run" == "true" ]]; then
  printf 'PASS dry run complete: %d would refresh, %d skipped, %d failed. Nothing was written.\n' \
    "$refreshed" "$skipped" "$failed"
else
  printf 'PASS refresh complete: %d refreshed, %d skipped, %d failed.\n' \
    "$refreshed" "$skipped" "$failed"
fi

[[ "$failed" -eq 0 ]] || exit 1

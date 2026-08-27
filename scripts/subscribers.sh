#!/usr/bin/env bash
# The subscriber registry: one reader, one ordering rule.
#
# Source this file; do not execute it. ~/.autometta/subscribers holds one
# YAML file per subscribed repo, plus a template.yaml that is an example and
# never a subscriber, plus any number of <slug>.yaml.disabled entries for repos
# that have been retired without being forgotten. Anything that walks the fleet
# -- the tick, a fleet-wide refresh -- reads it through these functions so the
# same file means the same thing to all of them.

subscribers_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./resolve-root.sh
source "$subscribers_script_dir/resolve-root.sh"

autometta_subscribers_dir() {
  printf '%s/subscribers' "$(autometta_controller_home)"
}

read_subscriber_field() {
  local file_path="$1"
  local key="$2"
  local raw
  raw="$(sed -n "s/^${key}:[[:space:]]*//p" "$file_path" | head -n1)"
  # Strip surrounding double or single quotes if present. subscribe-repo.sh
  # writes quoted strings; the template uses unquoted form. Accept both.
  raw="${raw%\"}"
  raw="${raw#\"}"
  raw="${raw%\'}"
  raw="${raw#\'}"
  printf '%s' "$raw"
}

# Every registered subscriber, enabled or not, in weight order. Callers filter
# on `enabled` themselves, because "skipped, and here is why" is part of what a
# fleet command owes its operator.
sort_subscribers() {
  local dir="${subscribers_dir:-$(autometta_subscribers_dir)}"
  for file in "$dir"/*.yaml; do
    [[ -e "$file" ]] || continue
    # Skip the example template; only real subscribers are processed.
    [[ "$(basename "$file")" == "template.yaml" ]] && continue
    local weight
    weight="$(read_subscriber_field "$file" "weight")"
    printf '%s\t%s\n' "${weight:-9999}" "$file"
  done | sort -n | cut -f2-
}

# Retired registry entries, one path per line. They are candidates for nothing,
# but a fleet command that silently omitted them would read as "covered
# everything" when it had not.
list_disabled_subscribers() {
  local dir="${subscribers_dir:-$(autometta_subscribers_dir)}"
  local file
  for file in "$dir"/*.yaml.disabled; do
    [[ -e "$file" ]] || continue
    printf '%s\n' "$file"
  done
}

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# list-cards.sh: classify stage cards in a repo as done | in_flight | pending.
#
# Args:
#   <repo_root>
#
# Output (tab-separated):
#   <card_id>\t<status>\t<card_path>
#
# Classification:
#   - done:      card_id appears in PLAN.md as a "done" row, OR in
#                state/recent-agents/ with outcome=completed.
#   - in_flight: card_id appears in state/active-agents/.
#   - pending:   neither.

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <repo_root>\n' "$(basename "$0")" >&2
  exit 1
fi

repo_root="$1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuse manifest_patterns by sourcing tick.sh helpers indirectly: tick.sh
# wraps them inside functions that need controller_home etc. Simpler to
# duplicate the default patterns here (kept small and consistent with
# tick.sh's defaults plus self-host examples).
manifest_path=""
if [[ -f "$repo_root/.autometta.local.yaml" ]]; then
  manifest_path="$repo_root/.autometta.local.yaml"
fi

declare -a patterns=()
if [[ -n "$manifest_path" ]] && command -v yq >/dev/null 2>&1; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && patterns+=("$line")
  done < <(yq -r '.stage_card_globs[]? // empty' "$manifest_path" 2>/dev/null || true)
fi
patterns+=("docs/stages/*.md")
patterns+=("examples/self-host/*.md")

# Build the done set from PLAN.md
plan_path="$repo_root/examples/self-host/PLAN.md"
done_ids=""
if [[ -f "$plan_path" ]]; then
  # Extract card ids from PLAN rows that say "done"
  done_ids="$(grep -E '\| done \|' "$plan_path" 2>/dev/null \
    | sed -nE 's/.*\[`([0-9]{2}[a-z]*-[a-z0-9-]+)\.md`\].*/\1/p' \
    || true)"
fi

# in_flight = card_ids referenced by state/active-agents
in_flight_ids=""
if [[ -d "$repo_root/state/active-agents" ]]; then
  while IFS= read -r f; do
    [[ -e "$f" ]] || continue
    cid="$(python3 -c 'import json,sys,os
try:
  d=json.load(open(sys.argv[1]))
  p=d.get("card_path","")
  print(os.path.splitext(os.path.basename(p))[0])
except Exception:
  pass' "$f")"
    [[ -n "$cid" ]] && in_flight_ids="$in_flight_ids
$cid"
  done < <(compgen -G "$repo_root/state/active-agents/*.json" || true)
fi

is_done() {
  printf '%s\n' "$done_ids" | grep -qxF "$1"
}
is_in_flight() {
  printf '%s\n' "$in_flight_ids" | grep -qxF "$1"
}

seen=""
for pattern in "${patterns[@]}"; do
  if [[ "$pattern" = /* ]]; then
    search_path="$pattern"
  else
    search_path="$repo_root/$pattern"
  fi
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ -f "$candidate" ]] || continue
    card_id="$(basename "$candidate" .md)"
    # Skip non-stage-card files
    if [[ ! "$card_id" =~ ^[0-9]{2}[a-z]*-[a-z0-9-]+$ ]]; then
      continue
    fi
    # Dedupe
    case "$seen" in
      *"|$card_id|"*) continue ;;
    esac
    seen="$seen|$card_id|"

    if is_in_flight "$card_id"; then
      status="in_flight"
    elif is_done "$card_id"; then
      status="done"
    else
      status="pending"
    fi
    printf '%s\t%s\t%s\n' "$card_id" "$status" "$candidate"
  done < <(compgen -G "$search_path" || true)
done | sort -t$'\t' -k1,1

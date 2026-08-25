#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# list-cards.sh: classify stage cards in a repo against the queue the
# controller actually dispatches from.
#
# Args:
#   <repo_root>
#
# Output (tab-separated):
#   <card_id>\t<status>\t<card_path>
#
# Statuses, in the vocabulary state/state.yaml uses plus two of our own:
#   pending          queued and waiting for a worker.
#   in_flight        state.yaml says in_progress, or a live entry in
#                    state/active-agents/ names the card.
#   done             state.yaml says completed; or, for a card state.yaml
#                    has never seen, a done row in PLAN.md or an
#                    outcome=completed record in state/recent-agents/.
#   failed |
#   verifier_failed |
#   stalled          carried through from state.yaml verbatim.
#   unqueued         the card exists on disk but the controller has never
#                    recorded it. A real and useful category, and NOT the
#                    same thing as pending.
#
# state/state.yaml is authoritative for every card it records. PLAN.md and
# state/recent-agents/ are consulted only for cards it has never seen.
#
# The old classification never read state.yaml at all: a card was "done" only
# if it appeared as a done row in examples/self-host/PLAN.md, which is
# autometta's own file and does not exist in any other subscriber. So every
# card in a subscriber's docs/stages/ was reported pending forever. On
# 2026-08-23 the ticker showed emergence-lab with sixteen pending stages while
# state.yaml recorded 31 completed, 3 verifier_failed, 2 stalled and not one
# pending. An empty queue that displays as a full one is why nobody noticed
# the overnight windows were coming up dead.
#
# A stage state.yaml records with no card on disk is listed too, with "-" for
# its path: it is part of the queue, so it belongs in a queue listing.

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <repo_root>\n' "$(basename "$0")" >&2
  exit 1
fi

repo_root="$1"

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
patterns+=("stage-cards/*.md")
# Legacy fallback for subscribers that used the former common layout.
patterns+=("docs/stages/*.md")
# Legacy fallback for Autometta's former self-host layout.
patterns+=("examples/self-host/*.md")

# The controller's queue: "<stage-id> <status>" per line. yq is the normal
# route; the text scan is a fallback so an operator without yq still gets the
# real queue rather than silently dropping back to "everything is pending".
state_path="$repo_root/state/state.yaml"
state_rows=""
if [[ -f "$state_path" ]]; then
  if command -v yq >/dev/null 2>&1; then
    state_rows="$(yq -o=json '.' "$state_path" 2>/dev/null \
      | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for s in (d.get("stages") or []):
    sid = s.get("id")
    if sid:
        print("%s %s" % (sid, s.get("status") or "unknown"))
' || true)"
  fi
  if [[ -z "$state_rows" ]]; then
    state_rows="$(python3 - "$state_path" <<'PY' || true
import sys
sid = None
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = raw.strip()
    if line.startswith("- id:"):
        sid = line.split(":", 1)[1].strip().strip('"').strip("'")
    elif line.startswith("status:") and sid:
        print("%s %s" % (sid, line.split(":", 1)[1].strip().strip('"').strip("'")))
        sid = None
PY
)"
  fi
fi

state_status() {
  local id="$1" row
  row="$(printf '%s\n' "$state_rows" | awk -v id="$id" '$1 == id {print $2; exit}')"
  case "$row" in
    in_progress) printf 'in_flight' ;;
    completed)   printf 'done' ;;
    *)           printf '%s' "$row" ;;
  esac
}

# Fallback done set, for cards state.yaml has never recorded.
plan_path="$repo_root/stage-cards/PLAN.md"
if [[ ! -f "$plan_path" ]]; then
  # Legacy fallback for Autometta's former self-host layout.
  plan_path="$repo_root/examples/self-host/PLAN.md"
fi
done_ids=""
if [[ -f "$plan_path" ]]; then
  done_ids="$(grep -E '\| done \|' "$plan_path" 2>/dev/null \
    | sed -nE 's/.*\[`([0-9]{2}[a-z]*-[a-z0-9-]+)\.md`\].*/\1/p' \
    || true)"
fi
if [[ -d "$repo_root/state/recent-agents" ]]; then
  while IFS= read -r f; do
    [[ -e "$f" ]] || continue
    cid="$(python3 -c 'import json,sys,os
try:
  d=json.load(open(sys.argv[1]))
  if str(d.get("outcome","")).lower() == "completed":
    print(os.path.splitext(os.path.basename(d.get("card_path","")))[0])
except Exception:
  pass' "$f")"
    [[ -n "$cid" ]] && done_ids="$done_ids
$cid"
  done < <(compgen -G "$repo_root/state/recent-agents/*.json" || true)
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

classify() {
  local card_id="$1" status
  status="$(state_status "$card_id")"
  if [[ -n "$status" ]]; then
    printf '%s' "$status"
    return 0
  fi
  # Never queued. A live agent still outranks the disk.
  if is_in_flight "$card_id"; then
    printf 'in_flight'
  elif is_done "$card_id"; then
    printf 'done'
  else
    printf 'unqueued'
  fi
}

{
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
      case "$seen" in
        *"|$card_id|"*) continue ;;
      esac
      seen="$seen|$card_id|"
      printf '%s\t%s\t%s\n' "$card_id" "$(classify "$card_id")" "$candidate"
    done < <(compgen -G "$search_path" || true)
  done

  # Queued stages with no card on disk. They are still queue depth, and a
  # pending stage whose card has gone missing is worth seeing rather than
  # silently dropping.
  while IFS=' ' read -r sid status; do
    [[ -n "$sid" ]] || continue
    case "$seen" in
      *"|$sid|"*) continue ;;
    esac
    seen="$seen|$sid|"
    printf '%s\t%s\t-\n' "$sid" "$(state_status "$sid")"
  done <<< "$state_rows"
} | sort -t$'\t' -k1,1

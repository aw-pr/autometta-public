#!/usr/bin/env bash
# proposals.sh - the harness proposals ledger (memory/proposals.jsonl).
#
# A proposal is a suggested change to the harness itself, raised while a run
# was being worked: by the orchestration chat on acking an escalation, or
# lifted from a verifier's HARNESS: findings. The ledger is append-only and
# committed; every line is one event against a proposal id and the newest
# event is the proposal's status. The weekly review (skills/autometta-weekly-
# review) reads it, the operator decides, and approved items become cards.
# Contract: docs/learning-log.md. Schema: schemas/proposals-ledger.json.
#
# Usage:
#   proposals.sh add --title T --kind K --target PATH[,PATH] --change TEXT \
#                    --evidence REF[,REF] [--repo NAME] [--stage ID] [--run ID]
#   proposals.sh list [--status proposed|approved|rejected|merged|carded|landed|open|all]
#   proposals.sh show <id>
#   proposals.sh approve <id> --note TEXT
#   proposals.sh reject  <id> --note TEXT
#   proposals.sh merge   <id> --into <id> [--note TEXT]
#   proposals.sh card    <id> --stage <stage-id> [--note TEXT]
#   proposals.sh land    <id> --commit <sha> [--note TEXT]
#   proposals.sh lint [FILE]
#
# Every writing verb needs the recording agent's identity, in git author
# form, from --agent or $AUTOMETTA_AGENT. There is no default: a line with an
# invented identity is a permanent wrong line. Claude chats get theirs from
# `agent-whoami --model '<model id>'`; Codex chats from `agent-whoami`.
#
# $PROPOSALS_LEDGER_PATH overrides the ledger path (smokes point it at a
# temp file). Exit 0 on success, 1 when a check fails (bad transition,
# unknown id, lint failure), 2 on a usage error.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
schema_path="$repo_root/schemas/proposals-ledger.json"
ledger_path="${PROPOSALS_LEDGER_PATH:-$repo_root/memory/proposals.jsonl}"

usage() {
  sed -n '12,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() { printf 'proposals: %s\n' "$*" >&2; exit 1; }
usage_error() { printf 'proposals: %s\n' "$*" >&2; usage; }

for tool in python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'proposals: %s not found on PATH\n' "$tool" >&2; exit 2; }
done

# Append one line under a directory lock so two chats cannot interleave a
# write. macOS has no flock; mkdir is atomic everywhere.
append_line() {
  local line="$1" lock="$ledger_path.lock" waited=0
  mkdir -p "$(dirname "$ledger_path")"
  until mkdir "$lock" 2>/dev/null; do
    (( waited < 50 )) || die "ledger locked for over 5s: $lock"
    sleep 0.1; waited=$((waited + 1))
  done
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  printf '%s\n' "$line" >> "$ledger_path"
  rmdir "$lock"
  trap - EXIT
}

# Validate the whole ledger plus one candidate line (when given) against the
# schema and the event-specific rules. Structural checks reuse facts-lint.sh
# with this ledger's schema; event fields and transitions are checked here.
lint_ledger() {
  local candidate="${1:-}" tmp
  tmp="$(mktemp)"
  [[ -f "$ledger_path" ]] && cat "$ledger_path" > "$tmp"
  [[ -z "$candidate" ]] || printf '%s\n' "$candidate" >> "$tmp"
  if ! "$script_dir/facts-lint.sh" --schema "$schema_path" "$tmp" >/dev/null; then
    rm -f "$tmp"; return 1
  fi
  python3 - "$tmp" <<'PY'
import json, sys
from pathlib import Path

NEEDS = {
    "proposed": ["title", "kind", "target", "change", "evidence"],
    "approved": ["note"],
    "rejected": ["note"],
    "merged": ["into"],
    "carded": ["stage_id"],
    "landed": ["commit"],
}
ONLY_ON_PROPOSED = {"title", "kind", "target", "change", "evidence"}
LEGAL = {
    None: {"proposed"},
    "proposed": {"approved", "rejected", "merged"},
    "approved": {"carded", "rejected"},
    "carded": {"landed", "rejected"},
    "rejected": set(),
    "merged": set(),
    "landed": set(),
}

status = {}
bad = None
for lineno, raw in enumerate(Path(sys.argv[1]).read_text(encoding="utf-8").splitlines(), 1):
    if not raw.strip():
        continue
    rec = json.loads(raw)
    pid, event = rec["id"], rec["event"]
    for field in NEEDS[event]:
        if field not in rec:
            bad = f"{lineno}: {event} needs {field!r}"; break
    if bad: break
    if event != "proposed":
        stray = ONLY_ON_PROPOSED & set(rec)
        if stray:
            bad = f"{lineno}: {sorted(stray)[0]!r} belongs on the proposed event only"; break
    for key in ("target", "evidence"):
        if key in rec:
            vals = rec[key]
            if not vals or not all(isinstance(v, str) and v for v in vals):
                bad = f"{lineno}: {key} must be a non-empty list of strings"; break
            if key == "target" and any(v.startswith("/") for v in vals):
                bad = f"{lineno}: target paths must be repo-relative"; break
    if bad: break
    if event == "merged" and rec["into"] == pid:
        bad = f"{lineno}: a proposal cannot merge into itself"; break
    if event == "merged" and rec["into"] not in status:
        bad = f"{lineno}: merge target {rec['into']} is not a known proposal"; break
    current = status.get(pid)
    if event not in LEGAL[current]:
        was = current or "nothing"
        bad = f"{lineno}: {pid} cannot go from {was} to {event}"; break
    status[pid] = event

if bad:
    print(f"FAIL proposals ledger line {bad}", file=sys.stderr)
    sys.exit(1)
print(f"PASS proposals ledger: {len(status)} proposal{'' if len(status) == 1 else 's'}")
PY
  local rc=$?
  rm -f "$tmp"
  return $rc
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

require_agent() {
  agent="${agent:-${AUTOMETTA_AGENT:-}}"
  [[ -n "$agent" ]] || die "no agent identity: pass --agent or set AUTOMETTA_AGENT (from agent-whoami)"
}

mint_id() {
  local day hex
  day="$(date -u +%Y%m%d)"
  hex="$(python3 -c 'import secrets; print(secrets.token_hex(2))')"
  printf 'P-%s-%s\n' "$day" "$hex"
}

csv_to_json_array() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -sc .
}

current_status() {
  local pid="$1"
  [[ -f "$ledger_path" ]] || return 1
  jq -r --arg id "$pid" 'select(.id == $id) | .event' "$ledger_path" | tail -1 | grep . || return 1
}

transition() {
  local event="$1" pid="$2"; shift 2
  local extra="$1"
  require_agent
  current_status "$pid" >/dev/null || die "unknown proposal id: $pid"
  local line
  line="$(jq -nc --arg id "$pid" --arg event "$event" --arg agent "$agent" --arg at "$(now_utc)" \
    --argjson extra "$extra" '{id:$id, event:$event, agent:$agent, recorded_at:$at} + $extra')"
  lint_ledger "$line" >/dev/null || die "$event refused for $pid (lint above)"
  append_line "$line"
  printf '%s %s\n' "$pid" "$event"
}

[[ $# -ge 1 ]] || usage
verb="$1"; shift
agent=""
title="" kind="" target="" change="" evidence="" repo="" stage="" run="" note="" into="" commit=""
status_filter="open"
pid=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent|--title|--kind|--target|--change|--evidence|--repo|--stage|--run|--note|--into|--commit|--status)
      [[ $# -ge 2 ]] || usage_error "$1 needs a value"
      case "$1" in
        --agent) agent="$2" ;;      --title) title="$2" ;;   --kind) kind="$2" ;;
        --target) target="$2" ;;    --change) change="$2" ;; --evidence) evidence="$2" ;;
        --repo) repo="$2" ;;        --stage) stage="$2" ;;   --run) run="$2" ;;
        --note) note="$2" ;;        --into) into="$2" ;;     --commit) commit="$2" ;;
        --status) status_filter="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage ;;
    -*) usage_error "unknown option: $1" ;;
    *)
      [[ -z "$pid" ]] || usage_error "unexpected argument: $1"
      pid="$1"; shift ;;
  esac
done

case "$verb" in
  add)
    require_agent
    [[ -n "$title" && -n "$kind" && -n "$target" && -n "$change" && -n "$evidence" ]] \
      || usage_error "add needs --title, --kind, --target, --change and --evidence"
    new_id="$(mint_id)"
    while [[ -f "$ledger_path" ]] && grep -q "\"id\":\"$new_id\"" "$ledger_path"; do new_id="$(mint_id)"; done
    line="$(jq -nc --arg id "$new_id" --arg agent "$agent" --arg at "$(now_utc)" \
      --arg title "$title" --arg kind "$kind" --arg change "$change" \
      --argjson target "$(csv_to_json_array "$target")" \
      --argjson evidence "$(csv_to_json_array "$evidence")" \
      --arg repo "$repo" --arg stage "$stage" --arg run "$run" '
      {id:$id, event:"proposed", agent:$agent, recorded_at:$at,
       title:$title, kind:$kind, target:$target, change:$change, evidence:$evidence}
      + (if $repo != "" then {repo:$repo} else {} end)
      + (if $stage != "" then {stage_id:$stage} else {} end)
      + (if $run != "" then {run_id:$run} else {} end)')"
    lint_ledger "$line" >/dev/null || die "add refused (lint above)"
    append_line "$line"
    printf '%s\n' "$new_id"
    ;;
  list)
    [[ -z "$pid" ]] || usage_error "list takes no id"
    case "$status_filter" in
      proposed|approved|rejected|merged|carded|landed|open|all) ;;
      *) usage_error "unknown --status: $status_filter" ;;
    esac
    [[ -f "$ledger_path" ]] || exit 0
    jq -rs --arg want "$status_filter" '
      group_by(.id) | map({
        id: .[0].id, title: .[0].title, kind: .[0].kind,
        proposed_at: .[0].recorded_at, status: (.[-1].event),
        stage: ([.[] | .stage_id // empty] | last // "-")
      })
      | sort_by(.proposed_at)
      | map(select(
          $want == "all"
          or ($want == "open" and (.status == "proposed" or .status == "approved" or .status == "carded"))
          or .status == $want))
      | .[] | "\(.id)\t\(.status)\t\(.kind)\t\(.stage)\t\(.title)"' "$ledger_path"
    ;;
  show)
    [[ -n "$pid" ]] || usage_error "show needs an id"
    current_status "$pid" >/dev/null || die "unknown proposal id: $pid"
    jq -c --arg id "$pid" 'select(.id == $id)' "$ledger_path"
    ;;
  approve)
    [[ -n "$pid" && -n "$note" ]] || usage_error "approve needs <id> --note"
    transition approved "$pid" "$(jq -nc --arg n "$note" '{note:$n}')"
    ;;
  reject)
    [[ -n "$pid" && -n "$note" ]] || usage_error "reject needs <id> --note"
    transition rejected "$pid" "$(jq -nc --arg n "$note" '{note:$n}')"
    ;;
  merge)
    [[ -n "$pid" && -n "$into" ]] || usage_error "merge needs <id> --into <id>"
    transition merged "$pid" "$(jq -nc --arg i "$into" --arg n "$note" '{into:$i} + (if $n != "" then {note:$n} else {} end)')"
    ;;
  card)
    [[ -n "$pid" && -n "$stage" ]] || usage_error "card needs <id> --stage <stage-id>"
    transition carded "$pid" "$(jq -nc --arg s "$stage" --arg n "$note" '{stage_id:$s} + (if $n != "" then {note:$n} else {} end)')"
    ;;
  land)
    [[ -n "$pid" && -n "$commit" ]] || usage_error "land needs <id> --commit <sha>"
    transition landed "$pid" "$(jq -nc --arg c "$commit" --arg n "$note" '{commit:$c} + (if $n != "" then {note:$n} else {} end)')"
    ;;
  lint)
    [[ -z "$pid" ]] || ledger_path="$pid"
    if [[ ! -f "$ledger_path" ]]; then
      printf 'PASS %s: no ledger yet (0 proposals)\n' "$ledger_path"
      exit 0
    fi
    lint_ledger
    ;;
  *) usage_error "unknown verb: $verb" ;;
esac

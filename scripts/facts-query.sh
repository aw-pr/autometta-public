#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ledger_path="${FACTS_LEDGER_PATH:-$script_dir/../memory/facts.jsonl}"
subject=""
predicate=""
stage=""
limit=20

usage() {
  printf 'usage: %s [--subject VALUE] [--predicate VALUE] [--stage VALUE] [--limit 1..100]\n' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject|--predicate|--stage|--limit)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      case "$1" in
        --subject) subject="$2" ;;
        --predicate) predicate="$2" ;;
        --stage) stage="$2" ;;
        --limit)
          if [[ ! "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt 1 ]]; then
            usage
            exit 2
          fi
          limit="$2"
          ;;
      esac
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$limit" -gt 100 ]]; then
  printf 'facts-query: --limit %s clamped to 100\n' "$limit" >&2
  limit=100
fi

# The ledger is advisory context. A missing, unreadable, or malformed file
# must behave like an empty ledger rather than interfere with a dispatch.
if [[ ! -r "$ledger_path" ]]; then
  exit 0
fi

python3 - "$ledger_path" "$subject" "$predicate" "$stage" "$limit" <<'PY'
import json
import sys

ledger_path, subject, predicate, stage, limit = sys.argv[1:]
facts = []
try:
    with open(ledger_path, encoding="utf-8") as ledger:
        for index, line in enumerate(ledger):
            try:
                fact = json.loads(line)
            except (json.JSONDecodeError, TypeError):
                continue
            if not isinstance(fact, dict):
                continue
            if subject and fact.get("subject") != subject:
                continue
            if predicate and fact.get("predicate") != predicate:
                continue
            if stage and fact.get("stage_id") != stage:
                continue
            facts.append((str(fact.get("recorded_at", "")), index, fact))
except (OSError, UnicodeError):
    sys.exit(0)

for _, _, fact in sorted(facts, reverse=True)[:int(limit)]:
    fields = (
        fact.get("recorded_at", ""),
        fact.get("subject", ""),
        fact.get("predicate", ""),
        fact.get("object", ""),
        fact.get("source", ""),
    )
    print(" | ".join(str(field).replace("\n", " ") for field in fields))
PY

#!/usr/bin/env bash
# facts-backfill.sh - append mechanically evidenced stage facts from git history.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
ledger_path="$repo_root/memory/facts.jsonl"

command -v git >/dev/null 2>&1 || {
  printf 'facts-backfill: git not found on PATH\n' >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  printf 'facts-backfill: python3 not found on PATH\n' >&2
  exit 2
}

if [[ -n "${FACTS_AGENT:-}" ]]; then
  recorder="$FACTS_AGENT"
elif command -v agent-whoami >/dev/null 2>&1; then
  recorder="$(agent-whoami)"
else
  printf 'facts-backfill: set FACTS_AGENT or install agent-whoami\n' >&2
  exit 2
fi

recorded_at="$(date -u +%F)"
mkdir -p "$(dirname "$ledger_path")"
touch "$ledger_path"

emit_fact() {
  local subject="$1"
  local predicate="$2"
  local object="$3"
  local source="$4"
  local line

  line="$(python3 - "$subject" "$predicate" "$object" "$source" "$recorder" "$recorded_at" <<'PY'
import json
import sys

subject, predicate, object_, source, agent, recorded_at = sys.argv[1:]
print(json.dumps({
    "subject": subject,
    "predicate": predicate,
    "object": object_,
    "source": source,
    "agent": agent,
    "recorded_at": recorded_at,
}, separators=(",", ":")))
PY
)"

  grep -Fqx -- "$line" "$ledger_path" || printf '%s\n' "$line" >>"$ledger_path"
}

while IFS=$'\x1f' read -r sha subject verifier worker orchestrator controller; do
  [[ -n "$sha" ]] || continue
  [[ "$subject" =~ ^([0-9]{2,}[a-z]*-[a-z0-9-]+): ]] || continue
  stage_id="${BASH_REMATCH[1]}"

  if [[ -n "$verifier" ]]; then
    emit_fact "$stage_id" "verified-by" "$verifier" "$sha"
  fi

  if [[ -n "$verifier$worker$orchestrator$controller" ]] && [[ "$subject" =~ [Rr]e-brief|[Ff]ix ]]; then
    emit_fact "$stage_id" "fixed-by" "commit $sha" "$sha"
  fi
done < <(
  git -C "$repo_root" log --format='%H%x1f%s%x1f%(trailers:key=Autometta-Verifier,valueonly,unfold=true)%x1f%(trailers:key=Autometta-Worker,valueonly,unfold=true)%x1f%(trailers:key=Autometta-Orchestrator,valueonly,unfold=true)%x1f%(trailers:key=Autometta-Controller,valueonly,unfold=true)'
)

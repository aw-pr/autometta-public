#!/usr/bin/env bash
set -euo pipefail

# Checks whether the agent-orchestrator skill in the repo matches the
# copy loaded into the Claude Code harness at ~/.claude/skills/agent-orchestrator/.
#
# Locally, that path is a symlink back to the repo, so the comparison is
# degenerate and this script reports a NOTICE rather than a PASS. In a
# hosted context (where the harness has its own copy), real drift is detected.
#
# Exit 0: in sync, or symlink degeneracy (hosted-only meaningful).
# Exit 1: drift detected between repo skill and harness copy.
#
# Usage: ./check-upstream-skills.sh [--repo-root <path>]

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) shift; repo_root="$1" ;;
    *) echo "Usage: $0 [--repo-root <path>]" >&2; exit 1 ;;
  esac
  shift
done

skill_in_repo="$repo_root/skills/agent-orchestrator"
skill_in_harness="${HOME}/.claude/skills/agent-orchestrator"

if [[ ! -d "$skill_in_repo" ]]; then
  echo "ERROR: repo skill dir not found: $skill_in_repo"
  exit 1
fi

if [[ ! -e "$skill_in_harness" ]]; then
  echo "NOTICE: harness skill dir not found at $skill_in_harness — check is hosted-only meaningful"
  exit 0
fi

if [[ -L "$skill_in_harness" ]]; then
  resolved=$(readlink -f "$skill_in_harness" 2>/dev/null || readlink "$skill_in_harness")
  echo "NOTICE: $skill_in_harness is a symlink -> $resolved — comparison is degenerate locally; check is hosted-only meaningful"
  exit 0
fi

drift=0
for f in SKILL.md REFERENCE.md; do
  repo_file="$skill_in_repo/$f"
  harness_file="$skill_in_harness/$f"

  [[ -f "$repo_file" ]] || continue

  if [[ ! -f "$harness_file" ]]; then
    echo "DRIFT: $f present in repo but missing from harness"
    drift=$((drift + 1))
    continue
  fi

  if ! diff -q "$repo_file" "$harness_file" >/dev/null 2>&1; then
    echo "DRIFT: $f differs between repo and harness"
    diff --unified=3 "$harness_file" "$repo_file" | head -40 || true
    drift=$((drift + 1))
  fi
done

if [[ $drift -eq 0 ]]; then
  echo "OK: agent-orchestrator skill is in sync between repo and harness"
  exit 0
fi

echo "ERROR: ${drift} drift(s) detected — harness may be running a stale version of agent-orchestrator"
exit 1

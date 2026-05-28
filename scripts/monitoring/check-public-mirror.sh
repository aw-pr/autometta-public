#!/usr/bin/env bash
set -euo pipefail

# Compares origin/publish HEAD to public/main HEAD.
# Exit 0: mirror in sync or public/main is a clean ancestor (normal lag).
# Exit 1: divergence detected — public/main has commits not reachable from origin/publish.
#
# Usage: ./check-public-mirror.sh [--repo-root <path>] [--no-fetch]
# Fake a divergence for testing:
#   git update-ref refs/remotes/public/main <non-ancestor-sha>
#   ./check-public-mirror.sh --no-fetch
#   git update-ref refs/remotes/public/main <original-sha>

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
no_fetch=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) shift; repo_root="$1" ;;
    --no-fetch)  no_fetch=true ;;
    *) echo "Usage: $0 [--repo-root <path>] [--no-fetch]" >&2; exit 1 ;;
  esac
  shift
done

cd "$repo_root"

if [[ "$no_fetch" == false ]]; then
  git fetch origin publish 2>/dev/null || { echo "ERROR: cannot fetch origin publish"; exit 1; }
  git fetch public main 2>/dev/null || { echo "ERROR: cannot fetch public main"; exit 1; }
fi

publish_sha=$(git rev-parse refs/remotes/origin/publish 2>/dev/null || true)
public_sha=$(git rev-parse refs/remotes/public/main 2>/dev/null || true)

if [[ -z "$publish_sha" ]]; then
  echo "NOTICE: origin/publish does not exist yet — nothing to compare"
  exit 0
fi

if [[ -z "$public_sha" ]]; then
  echo "NOTICE: public/main does not exist yet — nothing to compare"
  exit 0
fi

if [[ "$publish_sha" == "$public_sha" ]]; then
  echo "OK: mirror in sync (${publish_sha:0:8})"
  exit 0
fi

if git merge-base --is-ancestor "$public_sha" "$publish_sha" 2>/dev/null; then
  behind=$(git rev-list --count "${public_sha}..${publish_sha}")
  echo "OK: public/main (${public_sha:0:8}) is ${behind} commits behind origin/publish (${publish_sha:0:8}) — publish pending"
  exit 0
fi

echo "ERROR: divergence detected"
echo "  origin/publish: ${publish_sha}"
echo "  public/main:    ${public_sha}"
echo "  public/main is not an ancestor of origin/publish — the public mirror may contain commits not in private history"
exit 1

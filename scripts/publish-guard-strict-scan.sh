#!/usr/bin/env bash
# Strict publish-guard scanner — blocks if any forbidden phrase appears
# anywhere in the working tree (tracked + untracked, gitignore-aware).
#
# Patterns are read from .publish-guard-strict.local (gitignored), one ERE
# regex per line. Blank lines and #-comments ignored. No path exemptions.
#
# Invoked by:
#   - scripts/git-hooks/pre-commit  (before staged-content scan)
#   - scripts/git-hooks/pre-push    (before pushing to public remote)
#   - scripts/smoke-test.sh         (as a leak check)
#
# Deliberate override: skip a hook with --no-verify, or set
# PUBLISH_GUARD_STRICT_SKIP=1 for a single invocation. Either is a conscious
# act; do not paper over a hit by editing this script.
set -euo pipefail

if [ "${PUBLISH_GUARD_STRICT_SKIP:-0}" = "1" ]; then
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "publish-guard-strict: not inside a git repository." >&2
  exit 1
}

strict_cfg="$repo_root/.publish-guard-strict.local"
if [ ! -f "$strict_cfg" ]; then
  # No strict file → silent no-op. The init/retrofit skills seed it.
  exit 0
fi

patterns="$(grep -vE '^\s*(#|$)' "$strict_cfg" || true)"
[ -z "$patterns" ] && exit 0

# Collect tracked + untracked-not-ignored files. Three exclusions:
#   - the strict config itself (legitimately contains the patterns)
#   - private-tier paths that are already excluded from the publish squash
#     (runs/, archive/, HANDOFF.md, RUNBOOK.md, LICENSE) — keeps audit-trail
#     retros legible without weakening the public-reaching guard
#   - the .git directory (handled by ls-files)
files=$(
  {
    git -C "$repo_root" ls-files
    git -C "$repo_root" ls-files --others --exclude-standard
  } | sort -u | grep -vE '^(\.publish-guard\.local|\.publish-guard-strict\.local)(\.example)?$' \
    | grep -vE '^(runs/|archive/|HANDOFF\.md$|RUNBOOK\.md$|LICENSE$)' || true
)

[ -z "$files" ] && exit 0

fail=0
scan_files=()
while IFS= read -r f; do
  [ -f "$repo_root/$f" ] && scan_files+=("$repo_root/$f")
done <<< "$files"
while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  pattern_status=0
  grep -E -- "$pat" /dev/null >/dev/null 2>&1 || pattern_status=$?
  if [ "$pattern_status" -gt 1 ]; then
    echo "publish-guard-strict: invalid pattern configuration — blocked." >&2
    fail=1
    continue
  fi
  # Bound argv size without spawning a grep process for every file.
  for ((offset=0; offset<${#scan_files[@]}; offset+=100)); do
    grep_status=0
    matches="$(grep -HInE -- "$pat" "${scan_files[@]:offset:100}" 2>/dev/null)" || grep_status=$?
    if [ "$grep_status" -gt 1 ]; then
      echo "publish-guard-strict: a candidate file could not be scanned — blocked." >&2
      fail=1
    elif [ "$grep_status" -eq 0 ]; then
      if [ -n "$matches" ]; then
        echo "publish-guard-strict: forbidden phrase /$pat/:" >&2
        echo "$matches" | sed 's/^/  /' >&2
        fail=1
      fi
    fi
  done
done <<< "$patterns"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "publish-guard-strict: blocked. Remove these phrases from the working" >&2
  echo "tree. Strict list (.publish-guard-strict.local) covers all paths except" >&2
  echo "the private-tier exemption set (runs/, archive/, HANDOFF.md, RUNBOOK.md," >&2
  echo "LICENSE) which is already filtered out of the publish squash." >&2
  echo "Override for a single run: PUBLISH_GUARD_STRICT_SKIP=1 <command>" >&2
  exit 1
fi
exit 0

#!/usr/bin/env bash
# Idempotent: arm publish-guard hooks + local config + gitignore entries.
# Safe to re-run. Run from anywhere inside the target repo:
#   bash /path/to/mechanism/install-guards.sh
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 0755 "$here/pre-commit" "$root/.git/hooks/pre-commit"
install -m 0755 "$here/pre-push"   "$root/.git/hooks/pre-push"

if [ ! -f "$root/.publish-guard.local" ]; then
  cp "$here/publish-guard.local.example" "$root/.publish-guard.local"
  created_cfg=1
fi

gi="$root/.gitignore"
touch "$gi"
for e in '.publish-guard.local' '.env' '.env.*' '!.env.example' '*.local' \
         'op-refs.local.sh' '.claude/settings.local.json' 'logs/' 'runs/*.log'; do
  grep -qxF "$e" "$gi" || printf '%s\n' "$e" >> "$gi"
done

echo "publish-guard: hooks armed in $root/.git/hooks/"
if [ "${created_cfg:-0}" = 1 ]; then
  echo "publish-guard: created .publish-guard.local — EDIT IT with your real"
  echo "               username / vault / public-repo-url before committing."
else
  echo "publish-guard: .publish-guard.local already present (left as-is)."
fi

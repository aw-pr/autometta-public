#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=publish guard regression; no stage card freezes it
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q "$scratch"
cd "$scratch"
printf 'FORBIDDEN_FIXTURE\n' > .publish-guard-strict.local
printf '.publish-guard-strict.local\nignored.txt\n' > .gitignore
printf 'allowed\n' > tracked.txt
git add .gitignore tracked.txt
check() {
  local expected="$1" code=0
  "$script_dir/publish-guard-strict-scan.sh" > "$scratch/result.log" 2>&1 || code=$?
  # The test log is not part of the candidate tree on the next invocation.
  if [[ "$code" != "$expected" ]]; then
    printf 'FAIL strict guard: expected %s, got %s\n' "$expected" "$code" >&2
    exit 1
  fi
}
printf '\nresult.log\n' >> .gitignore
check 0
printf 'FORBIDDEN_FIXTURE\n' > 'untracked with spaces.txt'
check 1
printf 'allowed\n' > 'untracked with spaces.txt'
printf 'FORBIDDEN_FIXTURE\n' > tracked.txt
check 1
printf 'allowed\n' > tracked.txt
mkdir runs archive
for path in ignored.txt HANDOFF.md RUNBOOK.md LICENSE runs/private.md archive/private.md; do
  printf 'FORBIDDEN_FIXTURE\n' > "$path"
done
check 0
printf '\0FORBIDDEN_FIXTURE' > binary.bin
check 0
printf '[broken\n' > .publish-guard-strict.local
check 1
printf 'FORBIDDEN_FIXTURE\n' > .publish-guard-strict.local
for n in {1..205}; do printf 'allowed\n' > "batch-$n.txt"; done
printf 'FORBIDDEN_FIXTURE\n' > batch-205.txt
check 1
printf 'allowed\n' > batch-205.txt
check 0
printf 'publish-guard-strict-smoke: PASS\n'

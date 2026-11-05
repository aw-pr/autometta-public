#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=regression for the operator-authorised recovery policy
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/tick.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
card="$tmp/card.md"
fail() { echo "FAIL: recovery policy: $1" >&2; exit 1; }
printf '%s\n' '- **Recovery attempts:** 3' '- **Recovery attempt:** 2' > "$card"
recovery_attempt_available "$card" || fail 'second attempt may recover'
printf '%s\n' '- **Recovery attempts:** 3' '- **Recovery attempt:** 3' > "$card"
if recovery_attempt_available "$card"; then fail 'third attempt may not trigger a fourth'; fi
printf '%s\n' '- **Recovery attempts:** 1' '- **Recovery attempt:** 1' > "$card"
if recovery_attempt_available "$card"; then fail 'stricter one-attempt limit must hold'; fi
printf '%s\n' '- **Recovery attempts:** invalid' '- **Recovery attempt:** 1' > "$card"
if recovery_attempt_available "$card"; then fail 'malformed explicit limit must hold'; fi
printf '%s\n' '- **Recovery attempts:** 3' '- **Recovery attempt:** 999999999999999999999999' > "$card"
if recovery_attempt_available "$card"; then fail 'overflowing count must hold'; fi
printf '%s\n' '# Legacy card' > "$card"
recovery_attempt_available "$card" || fail 'legacy card retains existing one-death recovery'
echo 'PASS: recovery policy allowance'

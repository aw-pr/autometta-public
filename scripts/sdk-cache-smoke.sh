#!/usr/bin/env bash
# Smoke test for verify-sdk.py prompt caching.
#
# Runs verify-sdk.py twice against stage 14 in quick succession. Asserts
# that the second run has cache_read_input_tokens > 0 (a cache hit). Exits 0
# on success, non-zero with a clear message on miss.
#
# Requires ANTHROPIC_API_KEY in the environment.
# Usage: scripts/sdk-cache-smoke.sh [stage-id] [card-path] [artefact-glob]
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

stage_id="${1:-14-auth-route-toggle}"
card="${2:-$repo_root/examples/self-host/14-auth-route-toggle.md}"
artefact_glob="${3:-scripts/auth-route.sh,scripts/spawn-worker.sh,scripts/spawn-verifier.sh}"

if [[ ! -f "$card" ]]; then
  printf 'sdk-cache-smoke: stage card not found: %s\n' "$card" >&2
  exit 2
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  printf 'sdk-cache-smoke: ANTHROPIC_API_KEY not set\n' >&2
  exit 2
fi

out1="$(mktemp /tmp/sdk-smoke-run1-XXXX.json)"
out2="$(mktemp /tmp/sdk-smoke-run2-XXXX.json)"
trap 'rm -f "$out1" "$out2"' EXIT

_extract_cache_field() {
  local log="$1" field="$2"
  # Parse: cache: write=N read=M input=I output=O
  grep -oE "${field}=[0-9]+" "$log" 2>/dev/null | tail -n1 | cut -d= -f2 || echo 0
}

printf '=== run 1 (cold cache expected) ===\n' >&2
run1_log="$(mktemp /tmp/sdk-smoke-log1-XXXX.txt)"
trap 'rm -f "$out1" "$out2" "$run1_log"' EXIT
python3 "$script_dir/verify-sdk.py" \
  --stage-id "$stage_id" \
  --card "$card" \
  --artefact-glob "$artefact_glob" \
  --out "$out1" 2>"$run1_log" || true
cat "$run1_log" >&2
write1="$(_extract_cache_field "$run1_log" write)"
read1="$(_extract_cache_field "$run1_log" read)"
printf 'run1: write=%s read=%s\n' "$write1" "$read1" >&2

printf '=== run 2 (cache hit expected, within 5 min TTL) ===\n' >&2
run2_log="$(mktemp /tmp/sdk-smoke-log2-XXXX.txt)"
trap 'rm -f "$out1" "$out2" "$run1_log" "$run2_log"' EXIT
python3 "$script_dir/verify-sdk.py" \
  --stage-id "$stage_id" \
  --card "$card" \
  --artefact-glob "$artefact_glob" \
  --out "$out2" 2>"$run2_log" || true
cat "$run2_log" >&2
write2="$(_extract_cache_field "$run2_log" write)"
read2="$(_extract_cache_field "$run2_log" read)"
printf 'run2: write=%s read=%s\n' "$write2" "$read2" >&2

if (( read2 > 0 )); then
  printf 'PASS: cache hit on run 2 (read=%s)\n' "$read2"
  exit 0
else
  printf 'FAIL: no cache hit on run 2 (read=%s); check that both runs used the same static block and ran within 5 minutes\n' "$read2" >&2
  exit 1
fi

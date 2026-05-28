#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autometta_root="$(cd "$script_dir/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  retro-grade.sh [--last N] [--dry-run]

Build and optionally submit an Anthropic Message Batch that re-runs the
current verifier rubric over recent completed stages.
USAGE
}

dry_run=0
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      args+=("$1")
      shift
      ;;
    --last)
      if [[ $# -lt 2 ]]; then
        printf 'retro-grade: --last requires a value\n' >&2
        exit 1
      fi
      args+=("$1" "$2")
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'retro-grade: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "$autometta_root"

if [[ "$dry_run" -eq 1 ]]; then
  exec python3 scripts/retro-grade-batch.py "${args[@]}"
fi

# shellcheck source=../op-refs.sh
source "$autometta_root/op-refs.sh"

if [[ -z "${OP_REF_ANTHROPIC_API_KEY:-}" ]]; then
  printf 'retro-grade: OP_REF_ANTHROPIC_API_KEY is unset\n' >&2
  exit 1
fi
if [[ "$OP_REF_ANTHROPIC_API_KEY" == op://YOUR_VAULT/* ]]; then
  printf 'retro-grade: OP_REF_ANTHROPIC_API_KEY still points at the placeholder ref\n' >&2
  exit 1
fi
if ! command -v op-fetch >/dev/null 2>&1; then
  printf 'retro-grade: op-fetch is required for live batch submission\n' >&2
  exit 1
fi

exec op-fetch "ANTHROPIC_API_KEY=$OP_REF_ANTHROPIC_API_KEY" -- \
  python3 scripts/retro-grade-batch.py "${args[@]}"

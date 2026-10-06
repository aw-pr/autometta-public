#!/usr/bin/env bash
# claude-model-routing-smoke.sh — offline check that a Claude identity runs on
# the weights its slug names, and that tier defaults serve only identities
# without one. Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./models.sh
source "$script_dir/models.sh"

fail=0
check() {  # check <identity> <want>
  local got
  got="$(claude_model_for_identity "$1")"
  if [[ "$got" == "$2" ]]; then
    printf 'PASS  %-45s -> %s\n' "$1" "$got"
  else
    printf 'FAIL  %-45s -> %s (want %s)\n' "$1" "$got" "$2"; fail=1
  fi
}

check 'Claude Opus 5.5 <claude-opus-5-5@local>'  'claude-opus-5-5'
check 'Claude Opus 5 <claude-opus-5@local>'      'claude-opus-5'
check 'Claude Fable 5.1 <claude-fable-5-1@local>' 'claude-fable-5-1'
check 'Claude Sonnet 5.5 <claude-sonnet-5-5@local>' 'claude-sonnet-5-5'
check 'Claude Sonnet 5 <claude-sonnet-5@local>'  'claude-sonnet-5'
check 'Claude Haiku 4.5 <claude-haiku-4-5@local>' 'claude-haiku-4-5'
check 'Claude Opus'                              "$AUTOMETTA_MODEL_OPUS"
check 'Claude Fable'                             "$AUTOMETTA_MODEL_FABLE"
check 'Claude Sonnet'                            "$AUTOMETTA_MODEL_SONNET"
check 'Claude Haiku'                             "$AUTOMETTA_MODEL_HAIKU"
check 'someone'                                  'sonnet'

exit "$fail"

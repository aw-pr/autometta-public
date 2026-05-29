#!/usr/bin/env bash
# models.sh — single source of truth for the Claude model IDs autometta
# dispatches to. This is the ONE place to bump on a model release; every spawn
# script sources this file rather than hard-coding model strings of its own.
#
# Sourced by spawn-worker.sh, spawn-verifier.sh, and spawn-verifier-panel.sh.

AUTOMETTA_MODEL_OPUS="claude-opus-4-8"
AUTOMETTA_MODEL_SONNET="claude-sonnet-4-6"
AUTOMETTA_MODEL_HAIKU="claude-haiku-4-5"

# Map a worker/verifier identity string (e.g. "Claude Opus 4.8 <...>") to the
# model ID it should run on. Falls back to the sonnet alias when no tier matches.
claude_model_for_identity() {
  local identity="$1"
  if [[ "$identity" == *Sonnet* ]]; then
    printf '%s\n' "$AUTOMETTA_MODEL_SONNET"
  elif [[ "$identity" == *Opus* ]]; then
    printf '%s\n' "$AUTOMETTA_MODEL_OPUS"
  elif [[ "$identity" == *Haiku* ]]; then
    printf '%s\n' "$AUTOMETTA_MODEL_HAIKU"
  else
    printf 'sonnet\n'
  fi
}

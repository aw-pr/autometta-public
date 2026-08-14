#!/usr/bin/env bash
# models.sh — single source of truth for the model IDs autometta dispatches to.
# This is the ONE place to bump on a model release; every spawn script sources
# this file rather than hard-coding model strings of its own.
#
# Sourced by spawn-worker.sh, spawn-verifier.sh, and spawn-verifier-panel.sh.

AUTOMETTA_MODEL_OPUS="claude-opus-5"
AUTOMETTA_MODEL_SONNET="claude-sonnet-5"
AUTOMETTA_MODEL_HAIKU="claude-haiku-4-5"
# Frontier tier a step above Opus. Opt-in per card only: no existing identity
# resolves here, so a stage uses it only when its card names a *Fable* role.
AUTOMETTA_MODEL_FABLE="claude-fable-5"
# One codex model serves every codex identity. A card naming Terra, Luna or Sol
# all dispatch here, so the identity string drives git attribution and the cost
# tier, not the model that actually runs. Name the role Sol on new cards or the
# cost-log bills a T1 run at the T2 rate.
AUTOMETTA_MODEL_CODEX="gpt-5.6-sol"

# Both CLIs take the same effort vocabulary, so one card field serves both.
AUTOMETTA_EFFORT_LEVELS="low medium high xhigh max"

# Map a card's declared effort level to the CLI flags for a vendor family.
#
# Prints nothing when the card declares no effort, which leaves each CLI on its
# own default: `claude` on its built-in level, `codex` on model_reasoning_effort
# from ~/.codex/config.toml. That keeps every card written before this field
# existed dispatching exactly as it did.
#
# An unrecognised value also prints nothing rather than failing the dispatch: a
# typo should cost a stage its effort override, not its run, and defaulting down
# never silently promotes a cheap stage to max.
effort_flags_for_family() {
  local family="$1"
  local effort="$2"
  [[ -n "$effort" ]] || return 0
  case " $AUTOMETTA_EFFORT_LEVELS " in
    *" $effort "*) ;;
    *)
      printf 'models.sh: ignoring unknown effort level %s (valid: %s)\n' \
        "$effort" "$AUTOMETTA_EFFORT_LEVELS" >&2
      return 0
      ;;
  esac
  case "$family" in
    claude) printf -- '--effort %s\n' "$effort" ;;
    codex)  printf -- '-c model_reasoning_effort=%s\n' "$effort" ;;
  esac
}

# Map a worker/verifier identity string (e.g. "Claude Opus 4.8 <...>") to the
# model ID it should run on. Falls back to the sonnet alias when no tier matches.
claude_model_for_identity() {
  local identity="$1"
  if [[ "$identity" == *Sonnet* ]]; then
    printf '%s\n' "$AUTOMETTA_MODEL_SONNET"
  elif [[ "$identity" == *Fable* ]]; then
    printf '%s\n' "$AUTOMETTA_MODEL_FABLE"
  elif [[ "$identity" == *Opus* ]]; then
    printf '%s\n' "$AUTOMETTA_MODEL_OPUS"
  elif [[ "$identity" == *Haiku* ]]; then
    printf '%s\n' "$AUTOMETTA_MODEL_HAIKU"
  else
    printf 'sonnet\n'
  fi
}

# Resolve the codex CLI sandbox mode for dispatches into a repo. The default
# (workspace-write) exposes no Metal/GPU device on macOS, so repos whose
# acceptance criteria require GPU work (Metal renderers, CUDA, etc.) can widen
# it. Resolution order (most specific wins):
#   1. AUTOMETTA_CODEX_SANDBOX env var override
#   2. codex.sandbox in <repo>/.autometta.local.yaml
#   3. default: workspace-write
# Prints the mode; invalid values fall back to workspace-write with a warning
# on stderr (fail-closed to the narrower sandbox, never the wider one).
resolve_codex_sandbox() {
  local repo_root="$1"
  local manifest="$repo_root/.autometta.local.yaml"
  local mode=""

  if [[ -n "${AUTOMETTA_CODEX_SANDBOX:-}" ]]; then
    mode="${AUTOMETTA_CODEX_SANDBOX}"
  elif [[ -f "$manifest" ]] && command -v yq >/dev/null 2>&1; then
    mode="$(yq -r '.codex.sandbox // ""' "$manifest" 2>/dev/null || true)"
  fi

  case "$mode" in
    read-only|workspace-write|danger-full-access)
      printf '%s\n' "$mode"
      ;;
    "")
      printf 'workspace-write\n'
      ;;
    *)
      printf 'codex-sandbox: invalid mode %s; using workspace-write\n' "$mode" >&2
      printf 'workspace-write\n'
      ;;
  esac
}

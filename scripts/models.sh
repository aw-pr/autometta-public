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
# The codex `local` auth route (auth.codex.mode: local) runs this Ollama model
# id via `codex exec --oss --local-provider=ollama -m <id>` instead of the API
# model above. One place to bump when a faster or better-pulled local model
# becomes the default; see codex_local_preflight below for the ollama checks
# that gate a dispatch on this id actually being pulled.
AUTOMETTA_MODEL_CODEX_LOCAL="${AUTOMETTA_MODEL_CODEX_LOCAL:-gpt-oss:120b}"

# Worker and verifier both read the id above, which makes the same weights
# judge their own output. That is not an independent gate, and on one machine
# it is also a scheduling problem: two roles on one model id contend for a
# single loaded copy instead of running side by side. A repo that wants a
# genuinely separate local verifier sets the per-role override. Unset roles
# fall back to the shared default, so a repo that never sets one dispatches
# exactly as it did before.
AUTOMETTA_MODEL_CODEX_LOCAL_WORKER="${AUTOMETTA_MODEL_CODEX_LOCAL_WORKER:-}"
AUTOMETTA_MODEL_CODEX_LOCAL_VERIFIER="${AUTOMETTA_MODEL_CODEX_LOCAL_VERIFIER:-}"

# agent_family_for_identity <identity>
# Map an identity string to the dispatch family, which selects WHICH CLI runs:
# codex exec or claude -p. This is the one copy; spawn-worker.sh, spawn-
# verifier.sh and cost-log.sh all delegate here rather than carrying their own,
# which they did until they disagreed about nothing and duplicated a rule that
# has to stay identical to be correct.
#
# Note what this is not: it is not a statement about the weights. Every local
# Ollama model dispatches through codex exec --oss, so Llama weights are family
# codex too. Anything that needs to tell two local models apart wants
# codex_local_model_for_identity below, not this.
agent_family_for_identity() {
  local identity="$1"
  if [[ "$identity" == *Codex* || "$identity" == *GPT* ]]; then
    printf 'codex\n'
  elif [[ "$identity" == *Claude* ]]; then
    printf 'claude\n'
  else
    printf 'unknown\n'
  fi
}

# codex_local_model_for_identity <identity>
# The inverse of agent-whoami for the local route: a card's declared identity
# names the weights that role runs on. This is what lets the head and tail of a
# pipeline pair use different local models, which a per-role manifest key
# cannot express, both stages' workers being the same role. Prints nothing for
# an identity that names no local model, which is every cloud identity.
codex_local_model_for_identity() {
  case "$1" in
    *GPT-OSS\ 120B*|*gpt-oss-120b*)   printf 'gpt-oss:120b' ;;
    *GPT-OSS\ 20B*|*gpt-oss-20b*)     printf 'gpt-oss:20b' ;;
    *Llama\ 3.3\ 70B*|*llama-3-3-70b*) printf 'llama3.3:70b' ;;
    *Llama\ 4\ Scout*|*llama-4-scout*) printf 'llama4:scout' ;;
    *)                                 printf '' ;;
  esac
}

# codex_local_model_for_role <worker|verifier> [repo-root]
# Resolve the Ollama model id a role dispatches to. Resolution order, most
# specific wins, mirroring resolve_codex_sandbox below:
#   1. AUTOMETTA_MODEL_CODEX_LOCAL_WORKER / _VERIFIER env override
#   2. the identity's own weights, via codex_local_model_for_identity
#   3. codex.local_model.<role> in <repo>/.autometta.local.yaml
#   4. AUTOMETTA_MODEL_CODEX_LOCAL (env, else the built-in default above)
# An unrecognised role gets the shared default rather than failing: a typo
# should cost a role its override, not cost the run its dispatch.
codex_local_model_for_role() {
  local role="$1" repo_root="${2:-}" identity="${3:-}"
  local env_override="" manifest="" model=""

  case "$role" in
    worker)   env_override="${AUTOMETTA_MODEL_CODEX_LOCAL_WORKER:-}" ;;
    verifier) env_override="${AUTOMETTA_MODEL_CODEX_LOCAL_VERIFIER:-}" ;;
    *)        printf '%s' "$AUTOMETTA_MODEL_CODEX_LOCAL"; return 0 ;;
  esac

  if [[ -n "$env_override" ]]; then
    printf '%s' "$env_override"
    return 0
  fi

  # A card that names its weights wins over the repo-wide per-role key: two
  # stages paired in a pipeline are both workers, so the role key alone cannot
  # give them different models.
  if [[ -n "$identity" ]]; then
    model="$(codex_local_model_for_identity "$identity")"
    if [[ -n "$model" ]]; then
      printf '%s' "$model"
      return 0
    fi
  fi

  manifest="$repo_root/.autometta.local.yaml"
  if [[ -n "$repo_root" && -f "$manifest" ]] && command -v yq >/dev/null 2>&1; then
    model="$(yq -r ".codex.local_model.${role} // \"\"" "$manifest" 2>/dev/null || true)"
  fi

  printf '%s' "${model:-$AUTOMETTA_MODEL_CODEX_LOCAL}"
}

# Both CLIs take the same effort vocabulary, so one card field serves both.
AUTOMETTA_EFFORT_LEVELS="low medium high xhigh max"

# Map a card's declared effort level to the CLI flags for a vendor family.
#
# Prints ONE argv element per line. A caller must never rely on word splitting
# to turn "--effort high" into two arguments: these scripts set IFS=$'\n\t',
# which has no space in it, so an unquoted expansion of a space-joined string
# stays a single argument and the CLI sees an option whose name contains a
# space. Use effort_argv_for_family below rather than reading this directly.
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
    claude) printf -- '--effort\n%s\n' "$effort" ;;
    codex)  printf -- '-c\nmodel_reasoning_effort=%s\n' "$effort" ;;
  esac
}

# Build the effort argv for one dispatch into the global array
# AUTOMETTA_EFFORT_ARGV, empty when the card declares no usable effort.
#
# A global array is the return channel because a bash function cannot return
# one, and an array is the point: it survives any IFS and cannot silently
# re-collapse into a single argument the way an unquoted string can. Callers
# expand it as ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"} — the
# +alternate guard is needed because bash 3.2 (the system bash on macOS)
# treats "${arr[@]}" on an empty array as unbound under set -u.
effort_argv_for_family() {
  local family="$1"
  local effort="$2"
  local line
  AUTOMETTA_EFFORT_ARGV=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    AUTOMETTA_EFFORT_ARGV+=("$line")
  done < <(effort_flags_for_family "$family" "$effort")
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

# Resolve the codex sandbox for one dispatch, honouring a card's GUI need.
#
# A browser cannot start under seatbelt: Playwright's chromium, firefox and
# WebKit all abort in NSApplication init / _RegisterApplication because the
# sandbox denies WindowServer access. `headless: true` does not avoid it — the
# abort happens before any page loads. Verified 2026-08-14 on stage
# 33-markus-lyapunov-interaction, where all three browsers died in 38 seconds
# under --sandbox workspace-write.
#
# The launchd tick already runs in the gui/<uid> domain, so the GUI session is
# present and the sandbox is the only thing in the way. Claude roles are
# unsandboxed and need nothing; only codex roles have to opt out.
#
# So a card that drives a browser, screenshots, or otherwise needs the window
# server declares `- **Requires GUI:** true` and its codex roles run
# unsandboxed. Declare it only when the acceptance criteria genuinely need a
# browser: it hands that agent full machine access.
# A run worktree gets its state/ as a symlink to the subscriber's real state
# dir (tick.sh ensure_run_worktree), so every role shares one set of envelopes,
# logs and budget rather than a per-worktree copy. That target sits outside the
# worktree, and codex's workspace-write sandbox makes only the -C root writable.
# So a sandboxed codex role can read its card but cannot write the handoff or
# verifier envelope that the loop uses as its sole completion signal.
#
# The failure is silent in the worst way: the role does the work, reports its
# verdict in prose, and exits clean. tick.sh sees no artefact, reads that as a
# failed attempt, and burns a retry. Three of those stall the stage and discard
# the work. Stage 31 passed verification three times this way and lost 8.8M
# tokens of merged-nowhere output before the cause was found.
#
# --add-dir widens the sandbox to the symlink's real target and nothing else.
# Emitting the resolved physical path matters: codex resolves the symlink when
# it checks a write, so naming the worktree-relative path would not help.
codex_state_argv_for_repo() {
  local repo_root="$1"
  local state_dir
  AUTOMETTA_CODEX_STATE_ARGV=()
  state_dir="$(cd "$repo_root/state" 2>/dev/null && pwd -P)" || return 0
  [[ -n "$state_dir" ]] || return 0
  AUTOMETTA_CODEX_STATE_ARGV=(--add-dir "$state_dir")
}

resolve_codex_sandbox_for_card() {
  local repo_root="$1"
  local requires_gui="$2"
  case "$requires_gui" in
    true|True|TRUE|yes|1)
      printf 'danger-full-access\n'
      return 0
      ;;
  esac
  resolve_codex_sandbox "$repo_root"
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

# codex_local_preflight: fail closed, before spawning anything, when the
# codex `local` auth route cannot actually serve the requested Ollama model.
#
# A dispatch that only discovers a missing model or a dead server after codex
# has already negotiated with Ollama burns a worker or verifier attempt on
# infrastructure rather than on the stage, the same cost the sibling-CODEX_HOME
# gate exists to avoid for api mode. No daemon management here: this checks
# and reports, it never runs `ollama serve`.
#
# Prints nothing on success (return 0). On failure, prints one line naming the
# missing piece to stderr and returns 1; the caller must not spawn.
codex_local_preflight() {
  local model="$1"
  if ! command -v ollama >/dev/null 2>&1; then
    printf 'codex-local: ollama not found on PATH; install it or set auth.codex.mode to subscription/api\n' >&2
    return 1
  fi
  local listing
  if ! listing="$(ollama list 2>&1)"; then
    printf 'codex-local: ollama is not serving locally (ollama list failed); start it with '\''ollama serve'\'' before dispatching, not from an autometta spawn script\n' >&2
    return 1
  fi
  if ! printf '%s\n' "$listing" | awk '{print $1}' | grep -qxF "$model"; then
    printf 'codex-local: model %s is not pulled; run '\''ollama pull %s'\'' before dispatching\n' "$model" "$model" >&2
    return 1
  fi
  return 0
}

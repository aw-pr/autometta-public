#!/usr/bin/env bash
# local-route-smoke.sh — offline check for the codex `local` auth route
# (card 45): dispatch against Ollama-served local weights instead of the
# subscription or api routes.
#
# Everything here runs without a live ollama server and without touching the
# real /usr/local/bin/ollama on the operating machine: PATH is rebuilt per
# scenario, either pointing at a stub `ollama` (captured argv, "model not
# pulled") or omitting a real one entirely ("ollama not installed"), always
# excluding the directory the real binary lives in so a positive result here
# can never be a false pass from the live installation. op-fetch is stubbed
# exactly as in effort-flags-smoke.sh, capturing the built argv instead of
# running it. Assertions:
#
#   1. auth-route.sh mode resolution: default, manifest, env-override-beats-
#      manifest, and auth.claude.mode: local refused with a clear message.
#   2. local mode emits no op-fetch pairs, like subscription.
#   3. tier_for_identity/rate_for_tier: the new identity resolves T5 at
#      0.0 0.0 0.0, ahead of the generic Codex/GPT-5 T2 fallback.
#   4. Worker and verifier local dispatch build --oss --local-provider=ollama
#      -m <model> as separate argv elements, with no CODEX_HOME sibling
#      requirement (unset CODEX_HOME reaching op-fetch) and no --model flag.
#   5. A missing ollama binary, or ollama present but the model unpulled,
#      fails closed before spawn: no op-fetch invocation, no worker_pid /
#      verifier_pid written to state.yaml.
#   6. Subscription and api dispatch build exactly the argv they did before
#      this card (regression guard on the case-statement restructuring).
#   7. Amended criterion 4: agent-whoami resolves the local model id to the
#      canonical identity (skipped if the mcp-hub tool is not on PATH), and
#      tick.sh's step-7 trailer construction (_process_verifier_artefact)
#      renders that identity into an "Autometta-Verifier:" trailer against a
#      throwaway fixture repo.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./models.sh
source "$script_dir/models.sh"
# shellcheck source=./rates.sh
source "$script_dir/rates.sh"

fail=0

check() {
  local desc="$1"
  local cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s\n' "$desc" >&2
    fail=1
  fi
}

argv_is() {
  [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'no\n'
}

# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# Self root: a smoke test exercises the tree it ships in, never one an env
# var or the controller config happens to name.
autometta_root="$(autometta_self_root "$script_dir")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Directories that hold the tools every scenario needs (yq, jq, python3, git,
# core utils), deliberately excluding /usr/local/bin so the real ollama
# install can never leak into a "not installed" assertion.
safe_path_tail="/opt/homebrew/bin:/usr/bin:/bin"

stub_dir="$tmp/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/op-fetch" <<'STUB'
#!/usr/bin/env bash
{
  printf 'CODEX_HOME=%s\n' "${CODEX_HOME-<unset>}"
  for a in "$@"; do printf '%s\n' "$a"; done
} >"$AUTOMETTA_SMOKE_CAPTURE"
STUB
chmod +x "$stub_dir/op-fetch"

ollama_stub_with_model() {
  # ollama_stub_with_model <dir> <model...> — writes a stub `ollama` that
  # answers `ollama list` with a NAME column containing each given model.
  local dir="$1"; shift
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [[ "${1:-}" == "list" ]]; then\n'
    printf '  printf "NAME\\tID\\tSIZE\\tMODIFIED\\n"\n'
    for m in "$@"; do
      printf '  printf "%s\\tabc123\\t1 GB\\t1 day ago\\n"\n' "$m"
    done
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'exit 1\n'
  } >"$dir/ollama"
  chmod +x "$dir/ollama"
}

repo="$tmp/repo"
mkdir -p "$repo/state/logs" "$repo/state/verifiers" "$repo/cards"

write_card() {
  local path="$1" worker="$2" verifier="$3"
  {
    printf '# Stage card\n\n## Metadata\n\n'
    printf -- '- **Worker:** %s\n' "$worker"
    printf -- '- **Verifier:** %s\n' "$verifier"
    printf -- '- **Verifier panel:** false\n\n'
    printf '## Deliverables\n\n1. `scripts/example.sh`\n\n'
    printf '## Budget\n\n- **Worker wall-clock:** 1 minutes\n'
    printf -- '- **Verifier wall-clock:** 1 minutes\n'
  } >"$path"
}

write_state() {
  local stage_id="$1"
  printf 'stages:\n  - id: %s\n    status: running\n' "$stage_id" >"$repo/state/state.yaml"
}

worker_pid_written() {
  local stage_id="$1"
  PATH="$safe_path_tail" yq -r "(.stages[] | select(.id == \"$stage_id\")).worker_pid // \"\"" "$repo/state/state.yaml"
}

verifier_pid_written() {
  local stage_id="$1"
  PATH="$safe_path_tail" yq -r "(.stages[] | select(.id == \"$stage_id\")).verifier_pid // \"\"" "$repo/state/state.yaml"
}

codex_id='Codex GPT-OSS 120B <codex-gpt-oss-120b@local>'

# ---------------------------------------------------------------------------
printf '== auth-route.sh mode resolution ==\n' >&2

manifest_repo="$tmp/manifest-repo"
mkdir -p "$manifest_repo"

# Default: no manifest, no env override.
(
  unset AUTOMETTA_CODEX_MODE AUTOMETTA_CLAUDE_MODE
  PATH="$safe_path_tail" REPO_ROOT="$manifest_repo" "$autometta_root/scripts/auth-route.sh" codex --print-mode
) >"$tmp/mode.out" 2>"$tmp/mode.err" || true
check "codex with no manifest/env defaults to subscription" \
  "$(argv_is "subscription" "$(cat "$tmp/mode.out")")"

# Manifest sets local.
cat >"$manifest_repo/.autometta.local.yaml" <<'YAML'
auth:
  codex:
    mode: local
YAML
(
  unset AUTOMETTA_CODEX_MODE AUTOMETTA_CLAUDE_MODE
  PATH="$safe_path_tail" REPO_ROOT="$manifest_repo" "$autometta_root/scripts/auth-route.sh" codex --print-mode
) >"$tmp/mode.out" 2>"$tmp/mode.err" || true
check "manifest auth.codex.mode: local resolves to local" \
  "$(argv_is "local" "$(cat "$tmp/mode.out")")"

# env override beats an api manifest.
cat >"$manifest_repo/.autometta.local.yaml" <<'YAML'
auth:
  codex:
    mode: api
YAML
(
  export AUTOMETTA_CODEX_MODE=local
  PATH="$safe_path_tail" REPO_ROOT="$manifest_repo" "$autometta_root/scripts/auth-route.sh" codex --print-mode
) >"$tmp/mode.out" 2>"$tmp/mode.err" || true
check "AUTOMETTA_CODEX_MODE=local overrides an api manifest" \
  "$(argv_is "local" "$(cat "$tmp/mode.out")")"

# claude family local is refused.
rc=0
(
  unset AUTOMETTA_CLAUDE_MODE
  export AUTOMETTA_CLAUDE_MODE=local
  PATH="$safe_path_tail" REPO_ROOT="$manifest_repo" "$autometta_root/scripts/auth-route.sh" claude --print-mode
) >"$tmp/mode.out" 2>"$tmp/mode.err" || rc=$?
check "auth.claude.mode: local is refused (nonzero exit)" \
  "$([[ $rc -ne 0 ]] && printf 'ok\n' || printf 'no\n')"
check "claude local refusal names the family in its message" \
  "$(grep -q -i 'claude' "$tmp/mode.err" && printf 'ok\n' || printf 'no\n')"

# local mode emits no pairs, like subscription.
(
  export AUTOMETTA_CODEX_MODE=local
  PATH="$safe_path_tail" REPO_ROOT="$manifest_repo" "$autometta_root/scripts/auth-route.sh" codex
) >"$tmp/pairs.out" 2>"$tmp/pairs.err" || true
check "codex local mode emits no op-fetch pairs" \
  "$([[ ! -s "$tmp/pairs.out" ]] && printf 'ok\n' || printf 'no\n')"

# ---------------------------------------------------------------------------
printf '\n== tier / rate resolution (deliverable 5) ==\n' >&2

check "new identity resolves tier T5" \
  "$(argv_is "T5" "$(tier_for_identity "$codex_id")")"
check "T5 rate is explicit zero, not the T2 fallback" \
  "$(argv_is "0.0 0.0 0.0" "$(rate_for_tier T5)")"
check "raw local model id also resolves T5" \
  "$(argv_is "T5" "$(tier_for_identity "$AUTOMETTA_MODEL_CODEX_LOCAL")")"

# ---------------------------------------------------------------------------
printf '\n== local dispatch argv (worker + verifier) ==\n' >&2

ok_ollama_dir="$tmp/ollama-ok"
ollama_stub_with_model "$ok_ollama_dir" "$AUTOMETTA_MODEL_CODEX_LOCAL"

dispatch_local() {
  # dispatch_local <spawn-script> <card> <stage-id> <ollama-bin-dir-or-empty>
  local spawn="$1" card="$2" stage_id="$3" ollama_dir="${4:-}"
  local capture="$tmp/capture.txt"
  rm -f "$capture"
  write_state "$stage_id"
  local dispatch_path
  if [[ -n "$ollama_dir" ]]; then
    dispatch_path="$stub_dir:$ollama_dir:$safe_path_tail"
  else
    dispatch_path="$stub_dir:$safe_path_tail"
  fi
  (
    export PATH="$dispatch_path"
    export AUTOMETTA_SMOKE_CAPTURE="$capture"
    export AUTOMETTA_CODEX_MODE=local
    export AUTOMETTA_CLAUDE_MODE=subscription
    "$autometta_root/scripts/$spawn" "$card" "$repo" >/dev/null 2>>"$tmp/spawn.log"
  ) || true
  # The dispatch backgrounds the actual op-fetch call and returns immediately
  # (disown), so the capture file may not exist yet on return. Poll briefly,
  # as capture_dispatch does in effort-flags-smoke.sh; the fail-closed
  # scenarios never write it at all and correctly time out to empty.
  local waited=0
  while [[ ! -s "$capture" && $waited -lt 30 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  cat "$capture" 2>/dev/null || true
}

card="$repo/cards/50-local-worker.md"
write_card "$card" "$codex_id" "$codex_id"
argv="$(dispatch_local spawn-worker.sh "$card" 50-local-worker "$ok_ollama_dir")"
check "local worker argv carries --oss" \
  "$(printf '%s\n' "$argv" | grep -qxF -- '--oss' && printf 'ok\n' || printf 'no\n')"
check "local worker argv carries --local-provider=ollama" \
  "$(printf '%s\n' "$argv" | grep -qxF -- '--local-provider=ollama' && printf 'ok\n' || printf 'no\n')"
check "local worker argv carries -m and the model as separate elements" \
  "$(printf '%s\n' "$argv" | grep -A1 -x -F -e '-m' | grep -q -x -F -e "$AUTOMETTA_MODEL_CODEX_LOCAL" && printf 'ok\n' || printf 'no\n')"
check "local worker argv carries no --model flag (that is the api/subscription form)" \
  "$(printf '%s\n' "$argv" | grep -qxF -- '--model' && printf 'no\n' || printf 'ok\n')"
check "local worker dispatch does not require the sibling CODEX_HOME" \
  "$(printf '%s\n' "$argv" | grep -qxF -- 'CODEX_HOME=<unset>' && printf 'ok\n' || printf 'no\n')"
check "local worker writes a worker_pid" \
  "$([[ -n "$(worker_pid_written 50-local-worker)" ]] && printf 'ok\n' || printf 'no\n')"

card="$repo/cards/51-local-verifier.md"
write_card "$card" "$codex_id" "$codex_id"
argv="$(dispatch_local spawn-verifier.sh "$card" 51-local-verifier "$ok_ollama_dir")"
check "local verifier argv carries --oss" \
  "$(printf '%s\n' "$argv" | grep -qxF -- '--oss' && printf 'ok\n' || printf 'no\n')"
check "local verifier argv carries -m and the model as separate elements" \
  "$(printf '%s\n' "$argv" | grep -A1 -x -F -e '-m' | grep -q -x -F -e "$AUTOMETTA_MODEL_CODEX_LOCAL" && printf 'ok\n' || printf 'no\n')"
check "local verifier dispatch does not require the sibling CODEX_HOME" \
  "$(printf '%s\n' "$argv" | grep -qxF -- 'CODEX_HOME=<unset>' && printf 'ok\n' || printf 'no\n')"
check "local verifier writes a verifier_pid" \
  "$([[ -n "$(verifier_pid_written 51-local-verifier)" ]] && printf 'ok\n' || printf 'no\n')"

# ---------------------------------------------------------------------------
printf '\n== fail-closed preflight (deliverable 2 / acceptance 3) ==\n' >&2

card="$repo/cards/52-no-ollama.md"
write_card "$card" "$codex_id" "$codex_id"
argv="$(dispatch_local spawn-worker.sh "$card" 52-no-ollama "")"
check "missing ollama binary: no op-fetch dispatch happened" \
  "$([[ -z "$argv" ]] && printf 'ok\n' || printf 'no\n')"
check "missing ollama binary: no worker_pid written" \
  "$([[ -z "$(worker_pid_written 52-no-ollama)" ]] && printf 'ok\n' || printf 'no\n')"
check "missing ollama binary: the failure names ollama" \
  "$(grep -qi 'ollama' "$tmp/spawn.log" && printf 'ok\n' || printf 'no\n')"

unpulled_ollama_dir="$tmp/ollama-unpulled"
ollama_stub_with_model "$unpulled_ollama_dir" "llama3.3:70b"

card="$repo/cards/53-model-unpulled.md"
write_card "$card" "$codex_id" "$codex_id"
argv="$(dispatch_local spawn-verifier.sh "$card" 53-model-unpulled "$unpulled_ollama_dir")"
check "unpulled model: no op-fetch dispatch happened" \
  "$([[ -z "$argv" ]] && printf 'ok\n' || printf 'no\n')"
check "unpulled model: no verifier_pid written" \
  "$([[ -z "$(verifier_pid_written 53-model-unpulled)" ]] && printf 'ok\n' || printf 'no\n')"
check "unpulled model: the failure names the model" \
  "$(grep -qF "$AUTOMETTA_MODEL_CODEX_LOCAL" "$tmp/spawn.log" && printf 'ok\n' || printf 'no\n')"

# ---------------------------------------------------------------------------
printf '\n== subscription / api dispatch unchanged (acceptance 5) ==\n' >&2

dispatch_route() {
  # dispatch_route <spawn-script> <card> <stage-id> <codex-mode> [codex-home]
  local spawn="$1" card="$2" stage_id="$3" mode="$4" codex_home="${5:-}"
  local capture="$tmp/capture.txt"
  rm -f "$capture"
  write_state "$stage_id"
  (
    export PATH="$stub_dir:$safe_path_tail"
    export AUTOMETTA_SMOKE_CAPTURE="$capture"
    export AUTOMETTA_CODEX_MODE="$mode"
    export AUTOMETTA_CLAUDE_MODE=subscription
    if [[ "$mode" == "api" ]]; then
      export OP_REF_OPENAI_API_KEY='op://smoke/item/key'
      export AUTOMETTA_CODEX_HOME="$codex_home"
    fi
    "$autometta_root/scripts/$spawn" "$card" "$repo" >/dev/null 2>>"$tmp/spawn.log"
  )
  cat "$capture" 2>/dev/null || true
}

card="$repo/cards/54-subscription.md"
write_card "$card" "$codex_id" "$codex_id"
argv="$(dispatch_route spawn-worker.sh "$card" 54-subscription subscription)"
check "subscription-mode worker still uses --model, not --oss" \
  "$(printf '%s\n' "$argv" | grep -qxF -- '--model' && ! printf '%s\n' "$argv" | grep -qxF -- '--oss' && printf 'ok\n' || printf 'no\n')"
check "subscription-mode worker CODEX_HOME still unset" \
  "$(printf '%s\n' "$argv" | grep -qxF -- 'CODEX_HOME=<unset>' && printf 'ok\n' || printf 'no\n')"

codex_home_dir="$tmp/codex-api-only"
mkdir -p "$codex_home_dir"
printf '{"auth_mode":"apikey"}\n' >"$codex_home_dir/auth.json"

card="$repo/cards/55-api.md"
write_card "$card" "$codex_id" "$codex_id"
argv="$(dispatch_route spawn-worker.sh "$card" 55-api api "$codex_home_dir")"
check "api-mode worker still uses --model, not --oss" \
  "$(printf '%s\n' "$argv" | grep -qxF -- '--model' && ! printf '%s\n' "$argv" | grep -qxF -- '--oss' && printf 'ok\n' || printf 'no\n')"
check "api-mode worker still passes the sibling CODEX_HOME" \
  "$(printf '%s\n' "$argv" | grep -qxF -- "CODEX_HOME=$codex_home_dir" && printf 'ok\n' || printf 'no\n')"

# ---------------------------------------------------------------------------
printf '\n== attribution (amended criterion 4): agent-whoami and the step-7 trailer ==\n' >&2

# agent-whoami is an mcp-hub tool installed to ~/.local/bin, not part of this
# repo, so it is not on the safe_path_tail every other scenario here uses.
# Call the real one if present; skip cleanly rather than faking a resolver
# this repo does not own.
if command -v agent-whoami >/dev/null 2>&1; then
  whoami_out="$(agent-whoami --model "$AUTOMETTA_MODEL_CODEX_LOCAL" 2>/dev/null || true)"
  check "agent-whoami resolves the local model id to the canonical identity" \
    "$(argv_is "$codex_id" "$whoami_out")"
else
  printf '  SKIP: agent-whoami not on PATH (mcp-hub tool, not part of this repo)\n' >&2
fi

# The step-7 trailer construction lives in tick.sh's _process_verifier_artefact.
# Exercise it directly against a throwaway repo: a card naming an
# orchestrator, a state.yaml recording the local identity as .verifier, and a
# PASS artefact. Assert the resulting commit carries "Autometta-Verifier:
# <local identity>", the actual construction from docs/dispatch-contract.md
# step 7, not just that the string exists somewhere in state.
attribution_home="$tmp/controller-home"
mkdir -p "$attribution_home/subscribers" "$attribution_home/log"
attr_repo="$tmp/attribution-repo"
mkdir -p "$attr_repo/state/handoffs" "$attr_repo/state/verifiers" "$attr_repo/stage-cards"
(
  cd "$attr_repo"
  git init -q -b dev .
  git config user.email smoke@local
  git config user.name smoke
  git config commit.gpgsign false
  printf 'state/**\n!state/handoffs/\n!state/handoffs/.gitkeep\n' >.gitignore
  touch state/handoffs/.gitkeep
  printf 'seed\n' >README.md
  git add -A
  git commit -qm seed
) >/dev/null

cat >"$attr_repo/stage-cards/60-attribution-fixture.md" <<CARD
# Stage card 60-attribution-fixture: prove the trailer renders the local identity

## Metadata

- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** $codex_id
CARD

cat >"$attr_repo/state/state.yaml" <<YAML
version: 1
current_stage: 60-attribution-fixture
stages:
  - id: 60-attribution-fixture
    status: in_progress
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "$codex_id"
    base_branch: dev
    verifier_artefact: state/verifiers/60-attribution-fixture.json
YAML
printf '{"overall":"PASS","headline":"local verifier trailer fixture"}\n' \
  >"$attr_repo/state/verifiers/60-attribution-fixture.json"
cat >"$attr_repo/state/budget.json" <<JSON
{
  "version": 1,
  "token_cap_total": 1000000,
  "tokens_spent": 0,
  "wall_clock_cap_seconds": 86400,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 400,
  "clock_ticks_used": 1,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "window_started_at": "2026-08-24"
}
JSON

(
  export PHAT_CONTROLLER_HOME="$attribution_home"
  # shellcheck source=./tick.sh
  source "$autometta_root/scripts/tick.sh"
  wt="$(ensure_run_worktree "$attr_repo" 60-attribution-fixture dev)"
  printf 'deliverable\n' >"$wt/out.txt"
  _process_verifier_artefact "$attr_repo" "$attr_repo/state/state.yaml" \
    60-attribution-fixture state/verifiers/60-attribution-fixture.json ""
) >"$tmp/attribution.log" 2>&1 || true
# Base (dev) had not moved since dispatch, so _process_verifier_artefact
# fast-forwards dev and reaps the run branch/worktree in the same call (the
# "still" path in state-branch-smoke.sh's equivalent fixture) -- read the
# trailer from dev, not the now-gone run branch.
git -C "$attr_repo" log -1 --format=%B dev \
  >"$tmp/attribution-trailer.txt" 2>/dev/null || true

check "the step-7 trailer construction renders the local identity into Autometta-Verifier" \
  "$(grep -qxF "Autometta-Verifier: $codex_id" "$tmp/attribution-trailer.txt" && printf 'ok\n' || printf 'no\n')"

printf '\n' >&2
if [[ $fail -eq 0 ]]; then
  printf 'local-route-smoke: PASS\n' >&2
  exit 0
fi
printf 'local-route-smoke: FAIL (spawn stderr in %s)\n' "$tmp/spawn.log" >&2
cat "$tmp/spawn.log" >&2 2>/dev/null || true
exit 1

#!/usr/bin/env bash
# state-writable-smoke.sh — offline check that a sandboxed codex role is told
# the shared state dir is writable.
#
# The defect this guards (card 29): a run worktree gets its state/ as a symlink
# to the subscriber's real state dir, which sits outside the worktree. codex's
# workspace-write sandbox makes only the -C root writable, so a sandboxed role
# could read its card but not write the handoff or verifier envelope that the
# loop uses as its sole completion signal:
#
#   Write failed: unable to create `state/verifiers/<stage>.json`.
#
# The failure is silent in the worst way. The role does the work, reports its
# verdict in prose, and exits clean. tick.sh sees no artefact, reads that as a
# failed attempt, and burns a retry; three stall the stage. Stage 31 passed
# verification three times this way and lost 8.8M tokens of output.
#
# Assertions are on the constructed argv, captured from a stub op-fetch on
# PATH, so nothing here needs live auth, network, or a real CLI. It asserts:
#
#   1. codex_state_argv_for_repo emits `--add-dir` and the path as two argv
#      elements, and resolves a symlinked state/ to its physical target — the
#      run-worktree case, and the whole point, since codex resolves the link
#      when it checks a write.
#   2. It degrades to an empty argv rather than failing when state/ is absent.
#   3. A dispatched codex worker and verifier both carry --add-dir <state>.
#   4. Claude roles are unaffected: they are unsandboxed and get no --add-dir.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./models.sh
source "$script_dir/models.sh"

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

eq() {
  [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'no\n'
}

# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# Self root: a smoke test exercises the tree it ships in, never one an env
# var or the controller config happens to name.
autometta_root="$(autometta_self_root "$script_dir")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf '== state argv construction (card 29) ==\n' >&2

if ! declare -f codex_state_argv_for_repo >/dev/null 2>&1; then
  printf '  FAIL: models.sh has no codex_state_argv_for_repo — pre-fix tree, a\n' >&2
  printf '        sandboxed codex role cannot write its envelope\n' >&2
  printf 'state-writable-smoke: FAIL\n' >&2
  exit 1
fi

real_repo="$tmp/real"
mkdir -p "$real_repo/state"
real_state="$(cd "$real_repo/state" && pwd -P)"

codex_state_argv_for_repo "$real_repo"
check "a plain repo builds two argv elements" \
  "$(eq 2 "${#AUTOMETTA_CODEX_STATE_ARGV[@]}")"
check "the first element is --add-dir" \
  "$(eq '--add-dir' "${AUTOMETTA_CODEX_STATE_ARGV[0]}")"
check "the second element is the state dir" \
  "$(eq "$real_state" "${AUTOMETTA_CODEX_STATE_ARGV[1]}")"

# The run-worktree shape: state/ is a symlink out of the tree. The emitted path
# must be the link's target, because that is what codex checks a write against.
link_repo="$tmp/run-worktree"
mkdir -p "$link_repo"
ln -s "../real/state" "$link_repo/state"

codex_state_argv_for_repo "$link_repo"
check "a symlinked state resolves to its physical target" \
  "$(eq "$real_state" "${AUTOMETTA_CODEX_STATE_ARGV[1]}")"
check "the emitted path is not the worktree-relative link" \
  "$(eq 'ok' "$([[ "${AUTOMETTA_CODEX_STATE_ARGV[1]}" != "$link_repo/state" ]] && echo ok || echo no)")"

codex_state_argv_for_repo "$tmp/does-not-exist"
check "a repo with no state dir builds no argv rather than failing" \
  "$(eq 0 "${#AUTOMETTA_CODEX_STATE_ARGV[@]}")"

# ---------------------------------------------------------------------------
# End-to-end: dispatch each spawn script against a throwaway repo with a stub
# op-fetch on PATH, and read back the argv it was handed.
# ---------------------------------------------------------------------------

stub_dir="$tmp/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/op-fetch" <<'STUB'
#!/usr/bin/env bash
# Capture the argv of the dispatch instead of running it. One element per line.
: >"$AUTOMETTA_SMOKE_CAPTURE"
for a in "$@"; do printf '%s\n' "$a" >>"$AUTOMETTA_SMOKE_CAPTURE"; done
STUB
chmod +x "$stub_dir/op-fetch"

repo="$tmp/repo"
mkdir -p "$repo/state/logs" "$repo/state/verifiers" "$repo/cards"
repo_state="$(cd "$repo/state" && pwd -P)"

write_card() {
  # write_card <path> <worker-identity> <verifier-identity>
  local path="$1" worker="$2" verifier="$3"
  {
    printf '# Stage card\n\n## Metadata\n\n'
    printf -- '- **Worker:** %s\n' "$worker"
    printf -- '- **Verifier:** %s\n' "$verifier"
    printf -- '- **Verifier panel:** false\n\n'
    printf '## Budget\n\n- **Worker wall-clock:** 1 minutes\n'
  } >"$path"
}

capture_dispatch() {
  # capture_dispatch <spawn-script> <card> <stage-id> — prints captured argv.
  local spawn="$1" card="$2" stage_id="$3"
  local capture="$tmp/capture.txt"
  rm -f "$capture"
  printf 'stages:\n  - id: %s\n    status: running\n' "$stage_id" >"$repo/state/state.yaml"
  (
    export PATH="$stub_dir:$PATH"
    export AUTOMETTA_SMOKE_CAPTURE="$capture"
    export AUTOMETTA_CODEX_MODE=subscription
    export AUTOMETTA_CLAUDE_MODE=subscription
    export AUTOMETTA_CLAUDE_TRANSPORT=cli
    "$autometta_root/scripts/$spawn" "$card" "$repo" >/dev/null 2>>"$tmp/spawn.log"
  )
  local waited=0
  while [[ ! -s "$capture" && $waited -lt 100 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  cat "$capture" 2>/dev/null || true
}

argv_has_adjacent() {
  # argv_has_adjacent <first> <second> <argv-text> — true when the two appear
  # as consecutive lines, i.e. as two separate arguments.
  local first="$1" second="$2" argv="$3"
  printf '%s' "$argv" | grep -A1 -x -F -e "$first" | grep -q -x -F -e "$second" \
    && printf 'ok\n' || printf 'no\n'
}

argv_lacks() {
  local needle="$1" argv="$2"
  printf '%s' "$argv" | grep -q -F -e "$needle" && printf 'no\n' || printf 'ok\n'
}

printf '\n== dispatched argv (stub op-fetch) ==\n' >&2

claude_id='Claude Opus 5 <claude-opus-5@local>'
codex_id='Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>'

card="$repo/cards/50-codex-state.md"
write_card "$card" "$codex_id" "$codex_id"

argv="$(capture_dispatch spawn-worker.sh "$card" 50-codex-state)"
check "codex worker passes --add-dir and the state dir separately" \
  "$(argv_has_adjacent '--add-dir' "$repo_state" "$argv")"

argv="$(capture_dispatch spawn-verifier.sh "$card" 50-codex-state)"
check "codex verifier passes --add-dir and the state dir separately" \
  "$(argv_has_adjacent '--add-dir' "$repo_state" "$argv")"

card="$repo/cards/51-claude-state.md"
write_card "$card" "$claude_id" "$claude_id"

argv="$(capture_dispatch spawn-worker.sh "$card" 51-claude-state)"
check "claude worker passes no --add-dir (it is not sandboxed)" \
  "$(argv_lacks '--add-dir' "$argv")"

if [[ "$fail" -eq 0 ]]; then
  printf '\nstate-writable-smoke: all assertions passed\n' >&2
  exit 0
fi
printf '\nstate-writable-smoke: FAIL\n' >&2
exit 1

#!/usr/bin/env bash
# effort-flags-smoke.sh — offline check that a card's declared effort reaches
# each verifier transport as separate argv elements.
#
# The defect this guards (card 30): models.sh emitted "--effort high" as one
# space-joined string and both spawn scripts expanded it unquoted, relying on
# word splitting. The spawn scripts set IFS=$'\n\t', which has no space in it,
# so no split happened and `claude` received a single argument whose option
# name contained a space:
#
#   error: unknown option '--effort high'
#
# Assertions are on the constructed argv, captured from a stub op-fetch on
# PATH, so nothing here needs live auth, network, or a real CLI. It asserts:
#
#   1. effort_argv_for_family yields two elements per family, and none for a
#      card with no effort or an unknown level.
#   2. A dispatched claude worker/verifier passes `--effort` and `high` as two
#      arguments, never one.
#   3. The same for a codex role: `-c` and `model_reasoning_effort=high`.
#   4. The SDK and panel verifier routes receive the same separate arguments.
#   5. A card declaring no effort dispatches with no effort argument at all.
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

argv_is() {
  # argv_is <expected-joined> <actual-joined> — compare newline-joined argv.
  [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'no\n'
}

join_argv() {
  local out=""
  local a
  for a in "$@"; do
    out="${out}${a}"$'\n'
  done
  printf '%s' "$out"
}

printf '== effort argv construction (card 30) ==\n' >&2

if ! declare -f effort_argv_for_family >/dev/null 2>&1; then
  printf '  FAIL: models.sh has no effort_argv_for_family — pre-fix tree, effort\n' >&2
  printf '        flags are emitted space-joined and collapse to one argument\n' >&2
  printf 'effort-flags-smoke: FAIL\n' >&2
  exit 1
fi

effort_argv_for_family claude high
check "claude high builds two argv elements" \
  "$(argv_is 2 "${#AUTOMETTA_EFFORT_ARGV[@]}")"
check "claude high builds [--effort] [high]" \
  "$(argv_is "$(join_argv -- --effort high)" "$(join_argv -- ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"})")"

effort_argv_for_family codex high
check "codex high builds two argv elements" \
  "$(argv_is 2 "${#AUTOMETTA_EFFORT_ARGV[@]}")"
check "codex high builds [-c] [model_reasoning_effort=high]" \
  "$(argv_is "$(join_argv -- -c model_reasoning_effort=high)" "$(join_argv -- ${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"})")"

effort_argv_for_family claude ""
check "no declared effort builds no argv" \
  "$(argv_is 0 "${#AUTOMETTA_EFFORT_ARGV[@]}")"

effort_argv_for_family codex nonsense 2>/dev/null
check "unknown effort level builds no argv" \
  "$(argv_is 0 "${#AUTOMETTA_EFFORT_ARGV[@]}")"

# ---------------------------------------------------------------------------
# End-to-end: dispatch each spawn script against a throwaway repo with a stub
# op-fetch on PATH, and read back the argv it was handed.
# ---------------------------------------------------------------------------

# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# Self root: a smoke test exercises the tree it ships in, never one an env
# var or the controller config happens to name.
autometta_root="$(autometta_self_root "$script_dir")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub_dir="$tmp/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/op-fetch" <<'STUB'
#!/usr/bin/env bash
# Capture the argv of the dispatch instead of running it. One element per line.
if [[ -n "${AUTOMETTA_SMOKE_CAPTURE_DIR:-}" ]]; then
  model="" out="" previous=""
  for a in "$@"; do
    [[ "$previous" == "--model" ]] && model="$a"
    [[ "$previous" == "--out" ]] && out="$a"
    previous="$a"
  done
  case "$model" in
    *opus*) label="panel-opus" ;;
    *sonnet*) label="panel-sonnet" ;;
    *) label="panel-codex" ;;
  esac
  capture="$AUTOMETTA_SMOKE_CAPTURE_DIR/${label}.argv"
  : >"$capture"
  for a in "$@"; do printf '%s\n' "$a" >>"$capture"; done

  if [[ -z "$out" ]]; then
    for a in "$@"; do
      case "$a" in
        *'Verifier artefact path:'*)
          out="$(printf '%s\n' "$a" | sed -n 's/.*Verifier artefact path: `\([^`]*\)`.*/\1/p')"
          ;;
      esac
    done
  fi
  if [[ -n "$out" ]]; then
    mkdir -p "$(dirname "$out")"
    printf '{"overall":"PASS","criteria":[],"additional_findings":""}\n' >"$out"
  fi
  exit 0
fi

: >"$AUTOMETTA_SMOKE_CAPTURE"
for a in "$@"; do printf '%s\n' "$a" >>"$AUTOMETTA_SMOKE_CAPTURE"; done
STUB
chmod +x "$stub_dir/op-fetch"

repo="$tmp/repo"
mkdir -p "$repo/state/logs" "$repo/state/verifiers" "$repo/cards"

write_card() {
  # write_card <path> <worker-identity> <verifier-identity> <effort-or-empty> [panel]
  local path="$1" worker="$2" verifier="$3" effort="$4" panel="${5:-false}"
  {
    printf '# Stage card\n\n## Metadata\n\n'
    printf -- '- **Worker:** %s\n' "$worker"
    printf -- '- **Verifier:** %s\n' "$verifier"
    if [[ -n "$effort" ]]; then
      printf -- '- **Worker effort:** %s\n' "$effort"
      printf -- '- **Verifier effort:** %s\n' "$effort"
    fi
    printf -- '- **Verifier panel:** %s\n\n' "$panel"
    printf '## Deliverables\n\n1. `scripts/example.sh`\n\n'
    printf '## Budget\n\n- **Worker wall-clock:** 1 minutes\n'
    printf -- '- **Verifier wall-clock:** 1 minutes\n'
  } >"$path"
}

write_state() {
  local stage_id="$1"
  printf 'stages:\n  - id: %s\n    status: running\n' "$stage_id" >"$repo/state/state.yaml"
}

capture_dispatch() {
  # capture_dispatch <spawn-script> <card> <stage-id> [claude-transport]
  local spawn="$1" card="$2" stage_id="$3" transport="${4:-cli}"
  local capture="$tmp/capture.txt"
  rm -f "$capture"
  write_state "$stage_id"
  (
    export PATH="$stub_dir:$PATH"
    export AUTOMETTA_SMOKE_CAPTURE="$capture"
    # Force subscription so the auth route emits no op:// pairs and the stub
    # needs no 1Password service account.
    export AUTOMETTA_CODEX_MODE=subscription
    if [[ "$transport" == "sdk" ]]; then
      export AUTOMETTA_CLAUDE_MODE=api
      export OP_REF_ANTHROPIC_API_KEY='op://smoke/item/key'
    else
      export AUTOMETTA_CLAUDE_MODE=subscription
    fi
    export AUTOMETTA_CLAUDE_TRANSPORT="$transport"
    "$autometta_root/scripts/$spawn" "$card" "$repo" >/dev/null 2>>"$tmp/spawn.log"
  )
  local waited=0
  while [[ ! -s "$capture" && $waited -lt 100 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  cat "$capture" 2>/dev/null || true
}

capture_panel() {
  # capture_panel <card> — writes one argv file per panellist.
  local card="$1"
  local capture_dir="$tmp/panel-captures"
  rm -rf "$capture_dir"
  mkdir -p "$capture_dir"
  (
    export PATH="$stub_dir:$PATH"
    export AUTOMETTA_SMOKE_CAPTURE_DIR="$capture_dir"
    export AUTOMETTA_CODEX_MODE=subscription
    export AUTOMETTA_CLAUDE_MODE=api
    export OP_REF_ANTHROPIC_API_KEY='op://smoke/item/key'
    "$autometta_root/scripts/spawn-verifier-panel.sh" "$card" "$repo" --read-only \
      >/dev/null 2>>"$tmp/spawn.log"
  )
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

card="$repo/cards/40-claude-effort.md"
write_card "$card" "$claude_id" "$claude_id" high
argv="$(capture_dispatch spawn-worker.sh "$card" 40-claude-effort)"
check "claude worker passes --effort and high as separate arguments" \
  "$(argv_has_adjacent '--effort' 'high' "$argv")"
check "claude worker passes no argument named '--effort high'" \
  "$(argv_lacks '--effort high' "$argv")"

argv="$(capture_dispatch spawn-verifier.sh "$card" 40-claude-effort)"
check "claude verifier passes --effort and high as separate arguments" \
  "$(argv_has_adjacent '--effort' 'high' "$argv")"
check "claude verifier passes no argument named '--effort high'" \
  "$(argv_lacks '--effort high' "$argv")"

argv="$(capture_dispatch spawn-verifier.sh "$card" 40-claude-effort sdk)"
check "SDK verifier passes --effort and high as separate arguments" \
  "$(argv_has_adjacent '--effort' 'high' "$argv")"

panel_card="$repo/cards/44-panel-effort.md"
write_card "$panel_card" "$claude_id" "$claude_id" high true
capture_panel "$panel_card"
for panellist in panel-opus panel-sonnet panel-codex; do
  argv="$(cat "$tmp/panel-captures/${panellist}.argv" 2>/dev/null || true)"
  check "${panellist} passes its effort flag as separate arguments" \
    "$(if [[ "$panellist" == panel-codex ]]; then
         argv_has_adjacent '-c' 'model_reasoning_effort=high' "$argv"
       else
         argv_has_adjacent '--effort' 'high' "$argv"
       fi)"
done

card="$repo/cards/41-codex-effort.md"
write_card "$card" "$codex_id" "$codex_id" high
argv="$(capture_dispatch spawn-worker.sh "$card" 41-codex-effort)"
check "codex worker passes -c and model_reasoning_effort=high separately" \
  "$(argv_has_adjacent '-c' 'model_reasoning_effort=high' "$argv")"
check "codex worker passes no argument named '-c model_reasoning_effort=high'" \
  "$(argv_lacks '-c model_reasoning_effort=high' "$argv")"

argv="$(capture_dispatch spawn-verifier.sh "$card" 41-codex-effort)"
check "codex verifier passes -c and model_reasoning_effort=high separately" \
  "$(argv_has_adjacent '-c' 'model_reasoning_effort=high' "$argv")"

card="$repo/cards/42-no-effort.md"
write_card "$card" "$claude_id" "$claude_id" ""
argv="$(capture_dispatch spawn-worker.sh "$card" 42-no-effort)"
check "claude worker with no effort field still dispatches" \
  "$(argv_lacks '--effort' "$argv")"
check "claude worker with no effort field still reaches the CLI" \
  "$([[ "$argv" == *claude* ]] && printf 'ok\n' || printf 'no\n')"

argv="$(capture_dispatch spawn-verifier.sh "$card" 42-no-effort)"
check "claude CLI verifier with no effort field still dispatches unchanged" \
  "$(argv_lacks '--effort' "$argv")"

argv="$(capture_dispatch spawn-verifier.sh "$card" 42-no-effort sdk)"
check "SDK verifier with no effort field still dispatches unchanged" \
  "$(argv_lacks '--effort' "$argv")"

panel_card="$repo/cards/45-panel-no-effort.md"
write_card "$panel_card" "$claude_id" "$claude_id" "" true
capture_panel "$panel_card"
for panellist in panel-opus panel-sonnet panel-codex; do
  argv="$(cat "$tmp/panel-captures/${panellist}.argv" 2>/dev/null || true)"
  if [[ "$panellist" == panel-codex ]]; then
    check "${panellist} with no effort field dispatches unchanged" \
      "$(argv_lacks 'model_reasoning_effort' "$argv")"
  else
    check "${panellist} with no effort field dispatches unchanged" \
      "$(argv_lacks '--effort' "$argv")"
  fi
done

card="$repo/cards/43-no-effort-codex.md"
write_card "$card" "$codex_id" "$codex_id" ""
argv="$(capture_dispatch spawn-worker.sh "$card" 43-no-effort-codex)"
check "codex worker with no effort field still dispatches" \
  "$(argv_lacks 'model_reasoning_effort' "$argv")"
check "codex worker with no effort field still reaches the CLI" \
  "$([[ "$argv" == *codex* ]] && printf 'ok\n' || printf 'no\n')"

printf '\n' >&2
if [[ $fail -eq 0 ]]; then
  printf 'effort-flags-smoke: PASS\n' >&2
  exit 0
fi
printf 'effort-flags-smoke: FAIL (spawn stderr in %s)\n' "$tmp/spawn.log" >&2
cat "$tmp/spawn.log" >&2 2>/dev/null || true
exit 1

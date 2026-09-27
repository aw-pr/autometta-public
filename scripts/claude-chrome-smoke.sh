#!/usr/bin/env bash
# claude-chrome-smoke.sh — offline check that a Claude dispatch gets --chrome
# only when the card declares Requires GUI AND the repo manifest sets
# dispatch.claude.chrome: true. Headless `claude -p` has no browser tools
# without the flag, so a GUI card's worker and verifier would otherwise be
# blind to the browser the card requires.
#
# Harness mirrors mcp-isolation-smoke.sh: op-fetch is stubbed to capture the
# argv `claude` would receive, so nothing is ever dispatched.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./models.sh
source "$script_dir/models.sh"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"

fail=0

check() {
  local desc="$1"
  local cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2
    fail=1
  fi
}

eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }

autometta_root="$(autometta_self_root "$script_dir")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub_dir="$tmp/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/op-fetch" <<'STUB'
#!/usr/bin/env bash
# Capture the argv the dispatch built instead of running it. One element per
# line, so `claude`'s own flags can be inspected without ever invoking it.
: >"$AUTOMETTA_SMOKE_CAPTURE"
for a in "$@"; do printf '%s\n' "$a" >>"$AUTOMETTA_SMOKE_CAPTURE"; done
STUB
chmod +x "$stub_dir/op-fetch"

# A fake `claude` that fails loudly if ever actually exec'd. The stub above
# intercepts the dispatch at op-fetch, one level before this would run, so
# reaching this binary at all means the smoke fixture is wired up wrong.
cat >"$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude-chrome-smoke: the fake claude was exec'"'"'d directly; the op-fetch stub should have intercepted the dispatch first\n' >&2
exit 1
STUB
chmod +x "$stub_dir/claude"

repo="$tmp/repo"
mkdir -p "$repo/state/logs" "$repo/state/verifiers" "$repo/cards"

claude_id='Claude Opus 5 <claude-opus-5@local>'

write_card() {
  local path="$1" requires_gui="$2"
  {
    printf '# Stage card\n\n## Metadata\n\n'
    printf -- '- **Worker:** %s\n' "$claude_id"
    printf -- '- **Verifier:** %s\n' "$claude_id"
    printf -- '- **Verifier panel:** false\n'
    printf -- '- **Requires GUI:** %s\n\n' "$requires_gui"
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
  # capture_dispatch <spawn-script> <card> <stage-id> <repo-root>
  local spawn="$1" card="$2" stage_id="$3" repo_root="$4"
  local capture="$tmp/capture.txt"
  rm -f "$capture"
  write_state "$stage_id"
  (
    export PATH="$stub_dir:$PATH"
    export AUTOMETTA_SMOKE_CAPTURE="$capture"
    # Force subscription so the auth route emits no op:// pairs and the stub
    # needs no 1Password service account.
    export AUTOMETTA_CODEX_MODE=subscription
    export AUTOMETTA_CLAUDE_MODE=subscription
    export AUTOMETTA_CLAUDE_TRANSPORT=cli
    export AUTOMETTA_CODEX_TRANSPORT=cli
    "$autometta_root/scripts/$spawn" "$card" "$repo_root" >/dev/null 2>>"$tmp/spawn.log"
  )
  local waited=0
  while [[ ! -s "$capture" && $waited -lt 100 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  cat "$capture" 2>/dev/null || true
}

dispatched() { printf '%s\n' "$1" | grep -qxF -- '--strict-mcp-config' && printf 'ok\n' || printf 'no dispatch captured\n'; }
has_chrome() { printf '%s\n' "$1" | grep -qxF -- '--chrome' && printf 'yes\n' || printf 'no\n'; }

set_manifest_chrome() {
  if [[ "$1" == "true" ]]; then
    printf 'dispatch:\n  claude:\n    chrome: true\n' >"$repo/.autometta.local.yaml"
  else
    rm -f "$repo/.autometta.local.yaml"
  fi
}

gui_card="$repo/cards/901-gui.md"
plain_card="$repo/cards/902-plain.md"
write_card "$gui_card" true
write_card "$plain_card" false

for spawn in spawn-worker.sh spawn-verifier.sh; do
  printf '\n== %s ==\n' "$spawn" >&2

  set_manifest_chrome true
  argv="$(capture_dispatch "$spawn" "$gui_card" 901-gui "$repo")"
  check "GUI card + manifest opt-in passes --chrome" "$(eq yes "$(has_chrome "$argv")")"
  check "GUI card + manifest opt-in keeps --strict-mcp-config" "$(dispatched "$argv")"

  argv="$(capture_dispatch "$spawn" "$plain_card" 902-plain "$repo")"
  check "non-GUI card dispatched" "$(dispatched "$argv")"
  check "non-GUI card ignores the manifest opt-in" "$(eq no "$(has_chrome "$argv")")"

  set_manifest_chrome false
  argv="$(capture_dispatch "$spawn" "$gui_card" 901-gui "$repo")"
  check "GUI card without manifest opt-in dispatched" "$(dispatched "$argv")"
  check "GUI card without manifest opt-in stays browserless" "$(eq no "$(has_chrome "$argv")")"
done

printf '\n' >&2
if [[ $fail -eq 0 ]]; then
  printf 'claude-chrome-smoke: PASS\n' >&2
  exit 0
fi
printf 'claude-chrome-smoke: FAIL (spawn stderr in %s)\n' "$tmp/spawn.log" >&2
cat "$tmp/spawn.log" >&2 2>/dev/null || true
exit 1

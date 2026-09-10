#!/usr/bin/env bash
# mcp-isolation-smoke.sh — offline check for stage card 120: a Claude worker
# or verifier must not inherit the operator's MCP servers.
#
# The surfacing incident: a stage 75 worker's only child process was an
# Obsidian vault MCP server, because spawn-worker.sh started `claude` with no
# MCP configuration of its own and it loaded the operator's user-level
# servers. The fix pins `--strict-mcp-config --mcp-config <file>` on every
# claude dispatch, where the file defaults to an empty server list and can be
# overridden per repo via `dispatch.claude.mcp_config` in
# .autometta.local.yaml.
#
# Everything here runs offline: op-fetch is stubbed exactly as in
# effort-flags-smoke.sh and local-route-smoke.sh, capturing the argv `claude`
# would have received instead of running it, so a fake `claude` on PATH is
# never actually exec'd (the stub intercepts the dispatch one level up, at
# op-fetch) but is still present on PATH so nothing in the dispatch path can
# silently fall through to a real installed `claude`.
#
# What it asserts:
#
#   1. A worker dispatch and a verifier dispatch both carry
#      --strict-mcp-config and --mcp-config as separate argv elements.
#   2. The default --mcp-config file exists, is valid JSON, and reads
#      {"mcpServers":{}}.
#   3. A manifest key dispatch.claude.mcp_config names a different file and
#      that path resolves onto the same two dispatch sites.
#   4. Against the pre-change spawn scripts (no mcp argv construction at
#      all), the flag assertion fails — proving this is not a vacuous check.
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

argv_has_adjacent() {
  # argv_has_adjacent <first> <second> <argv-text> — true when the two appear
  # as consecutive lines, i.e. as two separate arguments.
  local first="$1" second="$2" argv="$3"
  printf '%s' "$argv" | grep -A1 -x -F -e "$first" | grep -q -x -F -e "$second" \
    && printf 'ok\n' || printf 'no\n'
}

# Self root: a smoke test exercises the tree it ships in, never one an env
# var or the controller config happens to name.
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
printf 'mcp-isolation-smoke: the fake claude was exec'"'"'d directly; the op-fetch stub should have intercepted the dispatch first\n' >&2
exit 1
STUB
chmod +x "$stub_dir/claude"

repo="$tmp/repo"
mkdir -p "$repo/state/logs" "$repo/state/verifiers" "$repo/cards"

claude_id='Claude Opus 5 <claude-opus-5@local>'

write_card() {
  local path="$1"
  {
    printf '# Stage card\n\n## Metadata\n\n'
    printf -- '- **Worker:** %s\n' "$claude_id"
    printf -- '- **Verifier:** %s\n' "$claude_id"
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

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/120-a-worker-does-not-inherit-the-operators-mcp-servers.md
printf '== default: no manifest, an empty MCP config on every claude dispatch ==\n' >&2

card="$repo/cards/120-worker.md"
write_card "$card"
argv="$(capture_dispatch spawn-worker.sh "$card" 120-worker "$repo")"
check "worker dispatch carries --strict-mcp-config" \
  "$(printf '%s\n' "$argv" | grep -qxF -- '--strict-mcp-config' && printf 'ok\n' || printf 'no\n')"
check "worker dispatch carries --mcp-config and a path as separate arguments" \
  "$(printf '%s\n' "$argv" | grep -A1 -x -F -e '--mcp-config' | grep -q . && printf 'ok\n' || printf 'no\n')"
worker_mcp_config="$(printf '%s\n' "$argv" | grep -A1 -x -F -e '--mcp-config' | tail -n1)"
check "the default file is under the repo's state/ scratch area" \
  "$(eq "$repo/state/mcp-config-empty.json" "$worker_mcp_config")"
check "the default file exists" \
  "$([[ -f "$worker_mcp_config" ]] && printf 'ok\n' || printf 'no\n')"
check "the default file is empty JSON: {\"mcpServers\":{}}" \
  "$(eq '{"mcpServers":{}}' "$(tr -d '[:space:]' <"$worker_mcp_config" 2>/dev/null || true)")"

argv="$(capture_dispatch spawn-verifier.sh "$card" 120-worker "$repo")"
check "verifier dispatch carries --strict-mcp-config" \
  "$(printf '%s\n' "$argv" | grep -qxF -- '--strict-mcp-config' && printf 'ok\n' || printf 'no\n')"
verifier_mcp_config="$(printf '%s\n' "$argv" | grep -A1 -x -F -e '--mcp-config' | tail -n1)"
check "the verifier gets the same default file as the worker" \
  "$(eq "$worker_mcp_config" "$verifier_mcp_config")"

printf '\n== manifest override: dispatch.claude.mcp_config names a different file ==\n' >&2

named_mcp_config="$tmp/named-mcp-config.json"
printf '{"mcpServers":{"fixture":{"command":"true"}}}\n' >"$named_mcp_config"
cat >"$repo/.autometta.local.yaml" <<YAML
dispatch:
  claude:
    mcp_config: $named_mcp_config
YAML

argv="$(capture_dispatch spawn-worker.sh "$card" 120-worker-named "$repo")"
check "a manifest-named config still carries --strict-mcp-config" \
  "$(printf '%s\n' "$argv" | grep -qxF -- '--strict-mcp-config' && printf 'ok\n' || printf 'no\n')"
check "worker dispatch passes the manifest-named file" \
  "$(eq "$named_mcp_config" "$(printf '%s\n' "$argv" | grep -A1 -x -F -e '--mcp-config' | tail -n1)")"

argv="$(capture_dispatch spawn-verifier.sh "$card" 120-worker-named "$repo")"
check "verifier dispatch passes the manifest-named file" \
  "$(eq "$named_mcp_config" "$(printf '%s\n' "$argv" | grep -A1 -x -F -e '--mcp-config' | tail -n1)")"

rm -f "$repo/.autometta.local.yaml"

printf '\n== the flag assertion is not vacuous ==\n' >&2

# A pre-fix spawn-worker.sh has no call to claude_mcp_config_argv_for_repo at
# all, so its claude dispatch line never carries --strict-mcp-config or
# --mcp-config: grep the spawn scripts themselves for the call site, rather
# than only asserting on argv that this fixed tree's own resolver already
# guarantees will be present.
check "spawn-worker.sh calls the mcp-config resolver before dispatching claude" \
  "$(grep -qF 'claude_mcp_config_argv_for_repo' "$autometta_root/scripts/spawn-worker.sh" && printf 'ok\n' || printf 'no\n')"
check "spawn-worker.sh threads AUTOMETTA_CLAUDE_MCP_ARGV into the claude dispatch line" \
  "$(grep -qF 'AUTOMETTA_CLAUDE_MCP_ARGV[@]+' "$autometta_root/scripts/spawn-worker.sh" && printf 'ok\n' || printf 'no\n')"
check "spawn-verifier.sh calls the mcp-config resolver before dispatching claude" \
  "$(grep -qF 'claude_mcp_config_argv_for_repo' "$autometta_root/scripts/spawn-verifier.sh" && printf 'ok\n' || printf 'no\n')"
check "spawn-verifier.sh threads AUTOMETTA_CLAUDE_MCP_ARGV into the claude cli dispatch line" \
  "$(grep -qF 'AUTOMETTA_CLAUDE_MCP_ARGV[@]+' "$autometta_root/scripts/spawn-verifier.sh" && printf 'ok\n' || printf 'no\n')"
# AUTOMETTA-CONTRACT-END

printf '\n' >&2
if [[ $fail -eq 0 ]]; then
  printf 'mcp-isolation-smoke: PASS\n' >&2
  exit 0
fi
printf 'mcp-isolation-smoke: FAIL (spawn stderr in %s)\n' "$tmp/spawn.log" >&2
cat "$tmp/spawn.log" >&2 2>/dev/null || true
exit 1

#!/usr/bin/env bash
# verifier-bake-off-route-smoke.sh — offline check of card 46's route
# isolation: a cloud candidate's dispatch names ONLY its own provider's
# env var, a local candidate never touches op-fetch at all, and every
# cloud candidate fails closed before any network call when its ref is
# unset or still the committed placeholder.
#
# Modelled on local-route-smoke.sh and effort-flags-smoke.sh: a stub
# op-fetch on PATH captures the argv it was called with, so this needs no
# live network, credentials, or Ollama server.
#
# Assertions:
#   1. A cloud candidate (groq, openrouter) with a resolved, non-placeholder
#      ref invokes op-fetch naming ONLY that provider's env var — never
#      OPENAI_API_KEY or ANTHROPIC_API_KEY, even when both are exported in
#      the parent shell (the auth-route-security route-isolation property).
#   2. A local candidate never invokes op-fetch, with or without paid keys
#      exported in the parent shell.
#   3. A cloud candidate whose ref is unconfigured (unset, or still the
#      op-refs.sh placeholder op://YOUR_VAULT/... — indistinguishable once
#      op-refs.sh's own default assignment has run) fails closed: no
#      op-fetch invocation happens at all.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autometta_root="$(cd "$script_dir/.." && pwd)"
harness="$script_dir/verifier-bake-off.sh"

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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub_dir="$tmp/bin"
mkdir -p "$stub_dir"
capture="$tmp/op-fetch.capture"
# Also stub python3 so no real HTTP call, model load, or JSON parse happens
# after op-fetch hands off — this test is only about what op-fetch was (or
# was not) asked to fetch, not about the caller's behaviour past that point.
cat >"$stub_dir/op-fetch" <<STUB
#!/usr/bin/env bash
: >"$capture"
for a in "\$@"; do
  [[ "\$a" == "--" ]] && break
  printf '%s\n' "\$a" >>"$capture"
done
exit 0
STUB
chmod +x "$stub_dir/op-fetch"
cat >"$stub_dir/python3" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_dir/python3"

# Directories that hold the other tools the harness needs (jq, core utils),
# deliberately excluding any path that might carry a real op-fetch.
safe_path_tail="/opt/homebrew/bin:/usr/bin:/bin"
smoke_path="$stub_dir:$safe_path_tail"

printf '== verifier-bake-off route isolation (card 46) ==\n' >&2

# A dedicated, throwaway budget file and near-zero pacing: this test must
# never touch the real state/bake-off-budget.json (a live batch run may be
# using it concurrently) and has no reason to sit through the real 65s/3s
# per-minute pacing sleeps to check argv construction.
export AUTOMETTA_BAKEOFF_BUDGET_PATH="$tmp/budget.json"
export AUTOMETTA_BAKEOFF_GROQ_INTERVAL_SECONDS=0
export AUTOMETTA_BAKEOFF_OPENROUTER_INTERVAL_SECONDS=0

# op-refs.sh's resolution order checks $AUTOMETTA_LOCAL_REFS before the
# machine's real op-refs.local.sh (XDG dir, then script-adjacent) — the
# "explicit operator override" case. Redirecting it at a file this test
# controls is what makes the test deterministic and independent of
# whatever is actually configured in 1Password on the machine it runs on;
# without it, the real local-refs file's unconditional `export` lines
# would override anything this test tries to set first.
fake_refs="$tmp/fake-op-refs.local.sh"
empty_refs="$tmp/empty-op-refs.local.sh"
: >"$empty_refs"

# --- Scenario 1: resolved ref, paid keys present in parent env ---------
cat >"$fake_refs" <<'REFS'
export OP_REF_GROQ_API_KEY="op://dev-stuff/fake-groq-item/credential"
export OP_REF_OPENROUTER_API_KEY="op://dev-stuff/fake-openrouter-item/credential"
REFS
export AUTOMETTA_LOCAL_REFS="$fake_refs"
export OPENAI_API_KEY="sk-should-not-leak"
export ANTHROPIC_API_KEY="sk-ant-should-not-leak"

: >"$capture"
PATH="$smoke_path" "$harness" run --candidate groq-gpt-oss-120b --stage 06-real-dispatch-test >/dev/null 2>&1 || true
check "groq candidate calls op-fetch (resolved ref)" \
  "$([[ -s "$capture" ]] && printf ok || printf no)"
check "groq candidate's op-fetch pairs name only GROQ_API_KEY" \
  "$(grep -q '^GROQ_API_KEY=' "$capture" && ! grep -qE '^(OPENAI_API_KEY|ANTHROPIC_API_KEY)=' "$capture" && printf ok || printf no)"

: >"$capture"
PATH="$smoke_path" "$harness" run --candidate openrouter-nemotron-3-super-120b --stage 06-real-dispatch-test >/dev/null 2>&1 || true
check "openrouter candidate's op-fetch pairs name only OPENROUTER_API_KEY" \
  "$(grep -q '^OPENROUTER_API_KEY=' "$capture" && ! grep -qE '^(OPENAI_API_KEY|ANTHROPIC_API_KEY)=' "$capture" && printf ok || printf no)"

# --- Scenario 2: local candidate never touches op-fetch -----------------
: >"$capture"
PATH="$smoke_path" "$harness" run --candidate local-devstral --stage 06-real-dispatch-test >/dev/null 2>&1 || true
check "local candidate never invokes op-fetch (paid keys still exported)" \
  "$([[ ! -s "$capture" ]] && printf ok || printf no)"

# --- Scenario 3: no configured ref fails closed, no op-fetch call -------
# An empty AUTOMETTA_LOCAL_REFS-pointed file means op-refs.sh's own
# `: "${OP_REF_GROQ_API_KEY:=op://YOUR_VAULT/...}"` default fires, which is
# indistinguishable at the auth-route check from a genuinely unset ref —
# both are the "not configured on this machine" case the fail-closed
# behaviour exists for.
export AUTOMETTA_LOCAL_REFS="$empty_refs"
: >"$capture"
rc=0
PATH="$smoke_path" "$harness" run --candidate groq-gpt-oss-120b --stage 06-real-dispatch-test >/dev/null 2>&1 || rc=$?
check "groq candidate with unconfigured ref exits non-zero" \
  "$([[ "$rc" -ne 0 ]] && printf ok || printf no)"
check "groq candidate with unconfigured ref never calls op-fetch" \
  "$([[ ! -s "$capture" ]] && printf ok || printf no)"

if [[ "$fail" -eq 0 ]]; then
  printf 'verifier-bake-off-route-smoke: PASS\n' >&2
  exit 0
else
  printf 'verifier-bake-off-route-smoke: FAIL\n' >&2
  exit 1
fi

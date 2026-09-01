#!/usr/bin/env bash
# verifier-route-matrix-smoke.sh: a surface and its credential are one route.
# No auth, no network, no token spend.
#
# "SDK" named two different products, and for one day that ambiguity was a
# fleet-wide outage. scripts/verify-sdk.py imports `anthropic` -- the api-sdk
# surface, the raw Messages API -- while the branch dispatching it described
# the Agent SDK and its subscription OAuth token. Both surfaces are valid; the
# crossing is not. Measured 2026-09-01, same model and minute, one request
# each: max_tokens=4 returned 429 rate_limit_error on the OAuth token, 200 on
# ANTHROPIC_API_KEY, and `claude -p` on that same OAuth token answered.
#
# What it asserts:
#
#   1. Every transport spelling maps to exactly one named surface, and the
#      legacy `sdk` still means api-sdk so existing manifests keep working.
#   2. The matrix refuses api-sdk on a subscription token, and only that
#      pairing -- api-sdk on a key, and the cli on either, all stand.
#   3. agent-sdk is refused as unimplemented rather than silently becoming
#      something else, because no verifier entrypoint targets it yet.
#   4. The guard applies to every provenance: an explicit env or manifest
#      transport is a preference, not a licence to mix.
#   5. It leaves the codex family alone.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./models.sh
source "$script_dir/models.sh"
spawn="$script_dir/spawn-verifier.sh"

OAUTH="CLAUDE_CODE_OAUTH_TOKEN=op://vault/item/credential"
KEY="ANTHROPIC_API_KEY=op://vault/item/credential"

fail=0
check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2
    fail=1
  fi
}
eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }

refused() { claude_route_refusal "$1" "$2" >/dev/null && printf 'yes\n' || printf 'no\n'; }

printf '== 1. every spelling names one surface ==\n' >&2
check "sdk is the legacy spelling of api-sdk" "$(eq api-sdk "$(claude_surface_for_transport sdk)")"
check "api-sdk names itself"                  "$(eq api-sdk "$(claude_surface_for_transport api-sdk)")"
check "agent-sdk is a surface of its own"     "$(eq agent-sdk "$(claude_surface_for_transport agent-sdk)")"
check "cli names itself"                      "$(eq cli "$(claude_surface_for_transport cli)")"
check "anything else is unknown, not a guess" "$(eq unknown "$(claude_surface_for_transport nonsense)")"

printf '== 2. only the api-sdk/subscription crossing is refused ==\n' >&2
check "api-sdk on a subscription token is refused" "$(eq yes "$(refused api-sdk "$OAUTH")")"
check "api-sdk on an API key stands"               "$(eq no  "$(refused api-sdk "$KEY")")"
check "cli on a subscription token stands"         "$(eq no  "$(refused cli "$OAUTH")")"
check "cli on an API key stands"                   "$(eq no  "$(refused cli "$KEY")")"

printf '== 3. agent-sdk is refused as unimplemented, not silently swapped ==\n' >&2
check "agent-sdk is refused on a subscription token" "$(eq yes "$(refused agent-sdk "$OAUTH")")"
check "agent-sdk is refused on an API key too"       "$(eq yes "$(refused agent-sdk "$KEY")")"
check "the refusal names the missing entrypoint" \
  "$(claude_route_refusal agent-sdk "$OAUTH" | grep -q 'no verifier entrypoint' && printf 'ok\n' || printf 'reason does not name it\n')"

printf '== 4. the guard applies to every provenance ==\n' >&2
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
printf 'version: 1\nauth:\n  claude:\n    mode: subscription\nverifier:\n  claude:\n    transport: sdk\n' \
  > "$repo/.autometta.local.yaml"
manifest_out="$(bash "$spawn" --print-transport claude "$repo" 2>/dev/null || true)"
case "$manifest_out" in
  "cli (route-guard:"*) check "a manifest sdk plus subscription resolves to cli" ok ;;
  *) check "a manifest sdk plus subscription resolves to cli" "got ${manifest_out:-<empty>}" ;;
esac

env_out="$(AUTOMETTA_CLAUDE_TRANSPORT=sdk bash "$spawn" --print-transport claude "$repo" 2>/dev/null || true)"
case "$env_out" in
  "cli (route-guard:"*) check "an env override cannot bypass the guard" ok ;;
  *) check "an env override cannot bypass the guard" "got ${env_out:-<empty>}" ;;
esac

printf '== 5. the codex family is untouched ==\n' >&2
check "a non-claude family passes through unguarded" \
  "$(claude_route_guard codex sdk default-sdk "$OAUTH" | grep -q '^sdk default-sdk$' && printf 'ok\n' || printf 'codex was rewritten\n')"

if [[ "$fail" -eq 0 ]]; then
  printf 'verifier-route-matrix-smoke: PASS\n' >&2
else
  printf 'verifier-route-matrix-smoke: FAIL\n' >&2
fi
exit "$fail"

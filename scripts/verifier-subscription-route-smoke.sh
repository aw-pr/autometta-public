#!/usr/bin/env bash
# verifier-subscription-route-smoke.sh: the API SDK is never handed a
# subscription OAuth token. No auth, no network, no token spend.
#
# scripts/verify-sdk.py imports `anthropic` -- the API SDK -- and calls the raw
# Messages API. A Claude Code subscription token (CLAUDE_CODE_OAUTH_TOKEN, what
# `claude setup-token` mints) is not a credential for that surface: measured
# 2026-09-01, a max_tokens=4 request returned 429 rate_limit_error on it while
# the identical request on ANTHROPIC_API_KEY returned 200. The Agent SDK
# (claude-agent-sdk, pinned in requirements-sdk.txt) is the surface that does
# accept it, and the branch this guards used to carry a comment saying so --
# describing an intention the code never implemented.
#
# What it asserts:
#
#   1. The subscription branch downgrades the transport to cli rather than
#      dispatching verify-sdk.py.
#   2. It still fails closed when the token is absent, since the CLI route
#      needs the same credential.
#   3. verify-sdk.py prefers ANTHROPIC_API_KEY over the OAuth token, which is
#      why card 89 passed: with a key in the environment the subscription
#      token was never the credential under test.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
spawn="$script_dir/spawn-verifier.sh"
sdk="$script_dir/verify-sdk.py"

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

# The subscription arm of the sdk precondition, up to the next case label.
branch="$(awk '/^          subscription\)/{f=1} f{print} f&&/^            ;;$/{exit}' "$spawn")"

printf '== the subscription route does not reach the API SDK ==\n' >&2

[[ "$branch" == *'claude_transport="cli"'* ]] \
  && check "the subscription branch downgrades to the cli transport" ok \
  || check "the subscription branch downgrades to the cli transport" "no claude_transport=cli assignment in the branch"

[[ "$branch" == *'exit 1'* && "$branch" == *'CLAUDE_CODE_OAUTH_TOKEN'* ]] \
  && check "it still fails closed on an absent OAuth token" ok \
  || check "it still fails closed on an absent OAuth token" "the token precondition is gone"

# Order matters: api_key must be returned before the oauth token is consulted.
api_line="$(grep -n 'return "api_key"' "$sdk" | head -n1 | cut -d: -f1)"
oauth_line="$(grep -n 'return "auth_token"' "$sdk" | head -n1 | cut -d: -f1)"
if [[ -n "$api_line" && -n "$oauth_line" && "$api_line" -lt "$oauth_line" ]]; then
  check "verify-sdk.py prefers ANTHROPIC_API_KEY over the OAuth token" ok
else
  check "verify-sdk.py prefers ANTHROPIC_API_KEY over the OAuth token" "api_key at ${api_line:-<none>}, auth_token at ${oauth_line:-<none>}"
fi

if [[ "$fail" -eq 0 ]]; then
  printf 'verifier-subscription-route-smoke: PASS\n' >&2
else
  printf 'verifier-subscription-route-smoke: FAIL\n' >&2
fi
exit "$fail"

#!/usr/bin/env bash
# preflight-network.sh: is the network worth spending a dispatch on?
#
# Resolves the two provider API hosts through the *system* resolver (no
# @server: the point is to measure what the dispatched agent will get, not
# what a public resolver would answer). Exit 0 when both resolve, non-zero
# with a one-line reason naming the host and the resolver that was tried.
#
# On 2026-09-03 the machine's resolvers (Tailscale MagicDNS, then NordVPN)
# stopped answering at about 22:35. Nothing above noticed: one worker sat
# retrying `Request timed out` for 50 minutes, two later dispatches died at
# launch on `op-fetch: error: failed to resolve CLAUDE_CODE_OAUTH_TOKEN`,
# and the quota reader went stale. One fault, three symptoms, and a dispatch
# spent on each.
#
# Run this from the tick, which is a LaunchAgent and unsandboxed. Run from
# inside a sandboxed agent it will always fail, because that sandbox has no
# network -- which is a true answer to a question the sandbox should not be
# asking.
set -uo pipefail
IFS=$'\n\t'

PREFLIGHT_HOSTS=(api.anthropic.com api.openai.com)

# Per-host wall-clock cap. Both hosts answer in well under a tenth of this on
# a healthy resolver; the cap only binds when a resolver is swallowing
# queries, which is the case worth failing fast on.
PREFLIGHT_TIMEOUT_SECONDS="${AUTOMETTA_PREFLIGHT_TIMEOUT_SECONDS:-2}"

# Run a command with a wall-clock cap, printing its stdout. Exit 124 on
# timeout, mirroring coreutils `timeout`, which macOS does not ship.
run_bounded() {
  local seconds="$1"; shift
  local out; out="$(mktemp)"
  "$@" >"$out" 2>/dev/null &
  # Deadline off the wall clock rather than a count of poll iterations: each
  # iteration costs a fork or two beyond its sleep, which on a 0.1s poll
  # overran a two-second cap by 40%. The start second is truncated, so the
  # real wait lands just under the stated cap and never over it -- the gate
  # runs before every dispatch and must not itself become the delay.
  local pid=$! rc=0
  local deadline=$(( $(date +%s) + seconds ))
  while kill -0 "$pid" 2>/dev/null; do
    if (( $(date +%s) >= deadline )); then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out"
      return 124
    fi
    sleep 0.1
  done
  wait "$pid" || rc=$?
  cat "$out"
  rm -f "$out"
  return "$rc"
}

# Which resolver command is available, in preference order. dig is the one
# the incident was diagnosed with, but it is not a dependency: a machine
# without it falls back and the reason line says which path was taken.
resolver_command() {
  local candidate
  for candidate in dig getent host; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Does this resolver output contain something that looks like an address?
# dig +short answers NXDOMAIN with empty output and exit 0, and every
# resolver will happily print a CNAME chain, so "non-empty" is not enough.
holds_address() {
  grep -Eq '(^|[[:space:]])([0-9]{1,3}\.){3}[0-9]{1,3}([[:space:]]|$)|[0-9a-fA-F]{1,4}:[0-9a-fA-F:]*:[0-9a-fA-F]{0,4}'
}

resolve_host() {
  local resolver="$1" host="$2"
  case "$resolver" in
    dig)    run_bounded "$PREFLIGHT_TIMEOUT_SECONDS" dig +short +time=1 +tries=1 "$host" ;;
    getent) run_bounded "$PREFLIGHT_TIMEOUT_SECONDS" getent hosts "$host" ;;
    host)   run_bounded "$PREFLIGHT_TIMEOUT_SECONDS" host -W 1 "$host" ;;
  esac
}

main() {
  local resolver
  if ! resolver="$(resolver_command)"; then
    printf 'no resolver available: none of dig, getent, host is on PATH\n' >&2
    return 1
  fi

  local host answer rc
  for host in "${PREFLIGHT_HOSTS[@]}"; do
    rc=0
    answer="$(resolve_host "$resolver" "$host")" || rc=$?
    if (( rc == 124 )); then
      printf '%s did not resolve: %s timed out after %ss\n' \
        "$host" "$resolver" "$PREFLIGHT_TIMEOUT_SECONDS" >&2
      return 1
    fi
    if (( rc != 0 )); then
      printf '%s did not resolve: %s exited %s\n' "$host" "$resolver" "$rc" >&2
      return 1
    fi
    if ! printf '%s\n' "$answer" | holds_address; then
      printf '%s did not resolve: %s returned no address\n' "$host" "$resolver" >&2
      return 1
    fi
  done
  return 0
}

main "$@"

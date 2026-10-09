#!/usr/bin/env bash
# Offline proof for stage card 147: the agent-sdk verifier is current.
#
# The machine this runs on is part of the fixture by design: the card's
# deliverable is that the python3 the spawn scripts resolve carries the
# claude-agent-sdk release the requirements file pins. No auth, no network,
# no token spend.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  case "$tmp" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$tmp" ;; esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

requirements="$repo_root/scripts/requirements-sdk.txt"
entrypoint="$repo_root/scripts/verify-sdk-agent.py"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/147-the-agent-sdk-verifier-is-current.md
# 1. The pin names a release on the current line, not the one the brew
#    python lost when it moved to 3.14.
pin_line="$(grep -E '^claude-agent-sdk==' "$requirements" || true)"
[[ "$pin_line" =~ ^claude-agent-sdk==([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] \
  || fail "147: requirements-sdk.txt carries no exact claude-agent-sdk pin"
pinned="${pin_line#*==}"
(( BASH_REMATCH[1] > 0 || BASH_REMATCH[2] > 2 || (BASH_REMATCH[2] == 2 && BASH_REMATCH[3] >= 100) )) \
  || fail "147: pin $pinned predates the 0.2.100 line"
# 2. The entrypoint can say whether this machine matches the pin before any
#    token is spent, and names both versions when it does not.
installed="$(python3 -c 'import importlib.metadata as m; print(m.version("claude-agent-sdk"))' 2>/dev/null || true)"
[[ -n "$installed" ]] \
  || fail "147: python3 cannot import claude-agent-sdk at all"
python3 "$entrypoint" --check-sdk >/dev/null 2>"$tmp/check.err" \
  || fail "147: --check-sdk refused the real pin: $(cat "$tmp/check.err")"
[[ "$installed" == "$pinned" ]] \
  || fail "147: installed $installed differs from pinned $pinned"
printf 'claude-agent-sdk==0.0.1\njsonschema==4.23.0\n' > "$tmp/stale-requirements.txt"
set +e
AUTOMETTA_SDK_REQUIREMENTS="$tmp/stale-requirements.txt" \
  python3 "$entrypoint" --check-sdk >/dev/null 2>"$tmp/stale.err"
rc=$?
set -e
[[ "$rc" == "2" ]] \
  || fail "147: a mismatched pin must exit 2 before any dispatch, got $rc"
grep -q '0\.0\.1' "$tmp/stale.err" \
  || fail "147: the mismatch message does not name the pinned version"
grep -q -F "$installed" "$tmp/stale.err" \
  || fail "147: the mismatch message does not name the installed version"
# 3. The probe the card ran is on record with its usage, so the next person
#    does not have to spend a verification to learn whether the route works.
probe="$repo_root/docs/experiments/agent-sdk-verifier-probe.md"
[[ -f "$probe" ]] \
  || fail "147: docs/experiments/agent-sdk-verifier-probe.md is missing"
grep -q -F "claude-agent-sdk==$pinned" "$probe" \
  || fail "147: the probe record does not name the pinned release it ran on"
grep -Eq '"overall": *"(PASS|FAIL)"' "$probe" \
  || fail "147: the probe record does not carry the artefact's overall verdict"
# AUTOMETTA-CONTRACT-END

printf 'sdk-pin-smoke: PASS\n'

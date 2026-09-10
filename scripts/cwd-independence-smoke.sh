#!/usr/bin/env bash
# cwd-independence-smoke.sh — offline check for stage card 122: retro-grade-batch.py
# and verify-sdk.py must not depend on the directory they were started from.
#
# The surfacing incident: verify-sdk.py died one second after every subscriber
# dispatch until 2026-09-01 because it read schemas/verifier.json relative to
# cwd (HANDOFF.md, the 2026-09-01 section). That path was fixed, but two
# siblings remained: retro-grade-batch.py's module-level STATE, VERIFIER_SCHEMA,
# VERIFIER_TEMPLATE and REPORT_TEMPLATE constants, and verify-sdk.py's
# active-agents registry path.
#
# What it asserts:
#
#   1. `retro-grade-batch.py --dry-run` run from a temporary directory that is
#      not the repo exits 0 and creates nothing in that directory.
#   2. `verify-sdk.py --help` run from the same kind of directory exits 0 and
#      creates nothing there.
#   3. Neither script's source contains a bare cwd-relative literal for the
#      paths this card fixes (schemas/verifier.json, state/state.yaml,
#      templates/verifier-prompt.md, memory/retro-grade-template.md,
#      state/active-agents) — proving the fix is real, not a coincidence of
#      this particular invocation.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Self root: a smoke test exercises the tree it ships in, never one an env
# var or the controller config happens to name.
autometta_root="$(autometta_self_root "$script_dir")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/122-the-verifier-scripts-do-not-depend-on-where-they-were-started.md
printf '== retro-grade-batch.py --dry-run from a directory that is not the repo ==\n' >&2

retro_out="$tmp/retro.out"
retro_exit=0
( cd "$tmp" && python3 "$autometta_root/scripts/retro-grade-batch.py" --dry-run >"$retro_out" 2>&1 ) || retro_exit=$?
check "retro-grade-batch.py --dry-run exits 0 from a foreign cwd" \
  "$([[ $retro_exit -eq 0 ]] && printf 'ok\n' || printf 'exit %s: %s\n' "$retro_exit" "$(cat "$retro_out")")"
check "retro-grade-batch.py --dry-run creates nothing in the foreign cwd" \
  "$([[ -z "$(find "$tmp" -mindepth 1 -not -name "$(basename "$retro_out")")" ]] && printf 'ok\n' || printf 'found: %s\n' "$(find "$tmp" -mindepth 1 -not -name "$(basename "$retro_out")")")"

printf '\n== verify-sdk.py --help from a directory that is not the repo ==\n' >&2

rm -f "$retro_out"
verify_out="$tmp/verify.out"
verify_exit=0
( cd "$tmp" && python3 "$autometta_root/scripts/verify-sdk.py" --help >"$verify_out" 2>&1 ) || verify_exit=$?
check "verify-sdk.py --help exits 0 from a foreign cwd" \
  "$([[ $verify_exit -eq 0 ]] && printf 'ok\n' || printf 'exit %s: %s\n' "$verify_exit" "$(cat "$verify_out")")"
check "verify-sdk.py --help creates nothing in the foreign cwd" \
  "$([[ -z "$(find "$tmp" -mindepth 1 -not -name "$(basename "$verify_out")")" ]] && printf 'ok\n' || printf 'found: %s\n' "$(find "$tmp" -mindepth 1 -not -name "$(basename "$verify_out")")")"

printf '\n== the two scripts anchor their paths, not cwd ==\n' >&2

check "retro-grade-batch.py does not read schemas/verifier.json relative to cwd" \
  "$(grep -qF 'Path("schemas/verifier.json")' "$autometta_root/scripts/retro-grade-batch.py" && printf 'still cwd-relative\n' || printf 'ok\n')"
check "retro-grade-batch.py does not read templates/verifier-prompt.md relative to cwd" \
  "$(grep -qF 'Path("templates/verifier-prompt.md")' "$autometta_root/scripts/retro-grade-batch.py" && printf 'still cwd-relative\n' || printf 'ok\n')"
check "retro-grade-batch.py does not read memory/retro-grade-template.md relative to cwd" \
  "$(grep -qF 'Path("memory/retro-grade-template.md")' "$autometta_root/scripts/retro-grade-batch.py" && printf 'still cwd-relative\n' || printf 'ok\n')"
check "retro-grade-batch.py's state.yaml path is not a bare cwd-relative literal" \
  "$(grep -qF 'STATE = Path("state/state.yaml")' "$autometta_root/scripts/retro-grade-batch.py" && printf 'still cwd-relative\n' || printf 'ok\n')"
check "retro-grade-batch.py exposes a --repo argument for state.yaml" \
  "$(grep -qF '"--repo"' "$autometta_root/scripts/retro-grade-batch.py" && printf 'ok\n' || printf 'no --repo argument\n')"
check "verify-sdk.py does not write its registry to a bare cwd-relative state/active-agents" \
  "$(grep -qF 'Path("state/active-agents")' "$autometta_root/scripts/verify-sdk.py" && printf 'still cwd-relative\n' || printf 'ok\n')"
check "verify-sdk.py creates the active-agents directory if absent" \
  "$(grep -qF 'mkdir(parents=True, exist_ok=True)' "$autometta_root/scripts/verify-sdk.py" && printf 'ok\n' || printf 'no mkdir guard\n')"
# AUTOMETTA-CONTRACT-END

printf '\n' >&2
if [[ $fail -eq 0 ]]; then
  printf 'cwd-independence-smoke: PASS\n' >&2
  exit 0
fi
printf 'cwd-independence-smoke: FAIL\n' >&2
exit 1

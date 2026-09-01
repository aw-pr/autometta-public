#!/usr/bin/env bash
# verify-sdk-schema-path-smoke.sh: the SDK verifier finds its schema from a
# foreign cwd. No auth, no network, no token spend.
#
# spawn-verifier.sh dispatches the SDK route as
# `( cd "$work_dir" && python3 "$sdk_script" ... )`, so cwd is the subscriber's
# run worktree while the script itself lives in the autometta install. The
# schema was read as the cwd-relative Path("schemas/verifier.json"), which
# exists only in autometta's own tree: `schemas/` is not in the vendored set
# (scripts/vendor-set.sh ships four templates and two scripts). Card 90 made
# the SDK the verifier's transport of first resort on 2026-08-31, and from
# that moment every subscriber's Claude verifier died on
# "verify-sdk: verifier schema not found: schemas/verifier.json" one second
# after dispatch. It went unseen because that day's stages all ran in
# autometta itself, where cwd happens to hold the schema.
#
# What it asserts:
#
#   1. SCHEMA resolves to a file that exists when cwd is somewhere else.
#   2. It is the same file the autometta root holds, not a lookalike.
#   3. TEMPLATE stays cwd-relative -- a subscriber vendors its own copy and
#      may fill its placeholders, so this must NOT be pinned to the install.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
foreign="$(mktemp -d)"
trap 'rm -rf "$foreign"' EXIT

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

probe() {
  # Load the module from a cwd that holds neither schemas/ nor templates/,
  # exactly as a dispatched verifier sees the world, and print what the two
  # module-level paths resolve to.
  ( cd "$foreign" && python3 - "$root/scripts/verify-sdk.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("vsdk", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.SCHEMA)
print(module.SCHEMA.is_file())
print(module.TEMPLATE.is_absolute())
PY
  )
}

printf '== the SDK verifier resolves its schema from a run worktree ==\n' >&2
# bash 3.2 ships as /bin/bash on macOS and has no mapfile.
schema_path=""; schema_found=""; template_absolute=""
{
  IFS= read -r schema_path || true
  IFS= read -r schema_found || true
  IFS= read -r template_absolute || true
} <<<"$(probe)"

[[ "$schema_found" == "True" ]] \
  && check "SCHEMA exists when cwd is not the autometta root" ok \
  || check "SCHEMA exists when cwd is not the autometta root" "resolved ${schema_path:-<none>}, is_file=${schema_found:-<none>}"

[[ "$schema_path" == "$root/schemas/verifier.json" ]] \
  && check "SCHEMA is the autometta root's own schema" ok \
  || check "SCHEMA is the autometta root's own schema" "expected $root/schemas/verifier.json, got ${schema_path:-<none>}"

[[ "$template_absolute" == "False" ]] \
  && check "TEMPLATE stays cwd-relative, so a vendored fill still wins" ok \
  || check "TEMPLATE stays cwd-relative, so a vendored fill still wins" "is_absolute=${template_absolute:-<none>}"

if [[ "$fail" -eq 0 ]]; then
  printf 'verify-sdk-schema-path-smoke: PASS\n' >&2
else
  printf 'verify-sdk-schema-path-smoke: FAIL\n' >&2
fi
exit "$fail"

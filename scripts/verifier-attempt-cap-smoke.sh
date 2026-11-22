#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=regression suite; no stage card freezes it
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/tick.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
state_file="$test_dir/state.yaml"
printf '%s\n' '{"stages":[{"id":"ordinary","verifier_attempts":3},{"id":"approved","verifier_attempts":3,"verifier_attempt_cap":4,"verifier_attempt_cap_reason":"owner approved one additional dispatch"}]}' > "$state_file"
before="$(shasum -a 256 "$state_file")"
[[ "$(verifier_attempt_cap_for_stage "$state_file" ordinary)" == 3 ]]
[[ "$(verifier_attempt_cap_for_stage "$state_file" approved)" == 4 ]]
[[ "$(shasum -a 256 "$state_file")" == "$before" ]]
# Existing counters decide admission; the exception grants exactly one dispatch.
(( 3 >= $(verifier_attempt_cap_for_stage "$state_file" ordinary) ))
(( 3 < $(verifier_attempt_cap_for_stage "$state_file" approved) ))
(( 4 >= $(verifier_attempt_cap_for_stage "$state_file" approved) ))
for value in null false 0 -1 3.5 1001 '"4"'; do
  jq --argjson cap "$value" '.stages[1].verifier_attempt_cap=$cap' "$state_file" > "$test_dir/bad.yaml"
  if verifier_attempt_cap_for_stage "$test_dir/bad.yaml" approved >/dev/null 2>&1; then
    printf 'FAIL accepted invalid cap %s\n' "$value"; exit 1
  fi
done
for reason in null '""' '"   "' 42; do
  jq --argjson reason "$reason" '.stages[1].verifier_attempt_cap_reason=$reason' "$state_file" > "$test_dir/bad.yaml"
  if verifier_attempt_cap_for_stage "$test_dir/bad.yaml" approved >/dev/null 2>&1; then
    printf 'FAIL accepted missing approval reason\n'; exit 1
  fi
done
if verifier_attempt_cap_for_stage "$state_file" missing >/dev/null 2>&1; then exit 1; fi
jq '.stages += [.stages[1]]' "$state_file" > "$test_dir/bad.yaml"
if verifier_attempt_cap_for_stage "$test_dir/bad.yaml" approved >/dev/null 2>&1; then exit 1; fi
printf 'PASS verifier attempt defaults, scoped exception, preserved counters and fail-closed input\n'

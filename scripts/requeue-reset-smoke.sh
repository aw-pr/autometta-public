#!/usr/bin/env bash
# requeue-reset-smoke.sh: offline proof that a re-queued stage carries no
# counter from its prior attempt. No auth, no network, no token spend.
#
# The defect this pins: requeue-stage.sh zeroed worker_tokens and tokens but
# left verifier_tokens standing, so a stage re-queued after a verifier FAIL
# reported its previous verifier's spend against an attempt that had not run.
# The dashboard rendered it faithfully as "worker 0, verifier 1,357,637" on a
# stage whose verifier had never been dispatched.
#
# What it asserts:
#
#   1. Every per-attempt counter reads zero after a re-queue.
#   2. Every per-attempt pid, timestamp and marker is null, and the status is
#      pending with zero verifier attempts.
#   3. The preserved fields survive: the card's pairing, the base branch, the
#      path claims, the gate, and the wip pointer to the prior attempt.
#   4. A sibling stage in the same ledger is untouched.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

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

repo="$tmp_root/subscriber"
mkdir -p "$repo/state"
git -C "$repo" init -q
git -C "$repo" config user.email smoke@local
git -C "$repo" config user.name smoke
printf 'seed\n' > "$repo/seed.txt"
git -C "$repo" add seed.txt
git -C "$repo" commit -qm seed

# A ledger in exactly the shape a verifier FAIL leaves behind: every
# per-attempt counter populated, including the one the defect missed.
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: 42-the-stage-under-test
stages:
  - id: 42-the-stage-under-test
    status: verifier_failed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    started_at: "2026-08-31T22:05:50Z"
    worker_pid: 4242
    verifier_pid: 4243
    verifier_artefact: state/verifiers/42-the-stage-under-test.json
    verifier_attempts: 1
    completed_at: null
    gate:
      type: stage_completed
      stage_id: 41-the-prerequisite
    path_claims:
      - scripts/thing.sh
    base_branch: dev
    worker_tokens: 2177636
    verifier_tokens: 1357637
    tokens: 3535273
    worker_envelope: partial
    verifier_started_at: "2026-08-31T22:25:12Z"
    stall_marker: "stalled after 4487s"
    wip_commit: 94570284f7f8dedb74a58916062deec4a2554b26
    wip_branch: wip/42-the-stage-under-test-attempt-1
  - id: 43-the-untouched-sibling
    status: completed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
    verifier_attempts: 1
    worker_tokens: 111
    verifier_tokens: 222
    tokens: 333
YAML

mkdir -p "$repo/state/handoffs" "$repo/state/verifiers"
printf '{"status":"pass"}\n' > "$repo/state/handoffs/42-the-stage-under-test.json"
printf '{"verdict":"FAIL"}\n' > "$repo/state/verifiers/42-the-stage-under-test.json"

bash "$script_dir/requeue-stage.sh" "$repo" 42-the-stage-under-test >/dev/null 2>&1

field() {
  yq -r ".stages[] | select(.id == \"$1\") | .$2" "$repo/state/state.yaml"
}

printf '== 1. no counter survives the re-queue ==\n' >&2
for counter in worker_tokens verifier_tokens tokens; do
  check "$counter reads 0" "$(eq 0 "$(field 42-the-stage-under-test "$counter")")"
done

printf '== 2. the stage is a clean pending ==\n' >&2
check "status is pending" "$(eq pending "$(field 42-the-stage-under-test status)")"
check "verifier_attempts is 0" "$(eq 0 "$(field 42-the-stage-under-test verifier_attempts)")"
for nulled in worker_pid verifier_pid started_at completed_at verifier_started_at stall_marker worker_envelope; do
  check "$nulled is null" "$(eq null "$(field 42-the-stage-under-test "$nulled")")"
done
check "current_stage no longer points here" \
  "$(eq null "$(yq -r '.current_stage' "$repo/state/state.yaml")")"

printf '== 3. the card metadata is preserved, not reset ==\n' >&2
check "worker seat preserved" \
  "$(eq 'Worker <worker@local>' "$(field 42-the-stage-under-test worker)")"
check "base_branch preserved" "$(eq dev "$(field 42-the-stage-under-test base_branch)")"
check "gate preserved" \
  "$(eq 41-the-prerequisite "$(field 42-the-stage-under-test 'gate.stage_id')")"
check "path claim preserved" \
  "$(eq scripts/thing.sh "$(field 42-the-stage-under-test 'path_claims[0]')")"
check "wip_commit survives the reset" \
  "$(eq 94570284f7f8dedb74a58916062deec4a2554b26 "$(field 42-the-stage-under-test wip_commit)")"
check "wip_branch survives the reset" \
  "$(eq wip/42-the-stage-under-test-attempt-1 "$(field 42-the-stage-under-test wip_branch)")"

printf '== 4. the sibling stage is untouched ==\n' >&2
check "sibling status" "$(eq completed "$(field 43-the-untouched-sibling status)")"
check "sibling verifier_tokens" "$(eq 222 "$(field 43-the-untouched-sibling verifier_tokens)")"

if [[ "$fail" -eq 0 ]]; then
  printf 'requeue-reset-smoke: PASS\n' >&2
else
  printf 'requeue-reset-smoke: FAIL\n' >&2
fi
exit "$fail"

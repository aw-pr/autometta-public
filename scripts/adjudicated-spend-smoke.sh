#!/usr/bin/env bash
# adjudicated-spend-smoke.sh: a stage the ledger landed is not reported as
# lost work. No auth, no network, no token spend.
#
# The defect this pins: history cards and every "lost" figure were built from
# the cost log alone, so a stage's verdict was whatever its last dispatch said.
# An orchestrator adjudication writes the ledger, not the cost log, so a stage
# landed after a verifier FAIL went on reporting FAIL with its entire spend
# counted as wasted. On 2026-09-01 stages 23, 79 and 98 were each landed on dev
# and together showed 30.3M tokens as lost work.
#
# What it asserts, against a fixture whose ledger and cost log disagree:
#
#   1. A stage the ledger calls completed reports no lost tokens, however its
#      dispatches ended.
#   2. Its card reads LANDED: not FAIL, which contradicts the ledger, and not
#      PASS, which would hide that a verifier refused it.
#   3. Its individual dispatch verdicts survive, so the FAIL is still visible.
#   4. A stage the ledger does NOT call completed still counts as lost. This is
#      the half that matters: the fix must not launder every failure.
#   5. A clean pass is untouched and still reads PASS.
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
  if [[ "$cond" == "ok" ]]; then printf '  PASS: %s\n' "$desc" >&2
  else printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2; fail=1; fi
}
eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }

# The aggregator reads registered subscribers, so the fixture is registered in
# a throwaway controller home rather than the operator's.
export PHAT_CONTROLLER_HOME="$tmp_root/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/subscribers" "$PHAT_CONTROLLER_HOME/log"

repo="$tmp_root/repo"
mkdir -p "$repo/state"
cat > "$PHAT_CONTROLLER_HOME/subscribers/repo.yaml" <<YAML
repo_path: "$repo"
manifest_path: "$repo/.autometta.local.yaml"
weight: 100
enabled: true
YAML
printf 'version: 1\n' > "$repo/.autometta.local.yaml"

# Three stages whose ledger status and last dispatch deliberately disagree.
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages:
  - id: 10-landed-after-a-fail
    status: completed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 11-genuinely-failed
    status: verifier_failed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 12-clean-pass
    status: completed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
YAML

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cost_log="$repo/state/cost-log.jsonl"
row() {
  # output_tokens 0 so input+cached+output equals total_tokens. The repo-level
  # lost figure sums the three components while a history card reads
  # total_tokens, and a fixture where those disagree tests the difference
  # between them rather than the thing this smoke is about.
  printf '{"ts":"%s","repo":"repo","stage_id":"%s","role":"%s","identity":"Worker <worker@local>","tier":"T2","input_tokens":%s,"cached_input_tokens":0,"output_tokens":0,"total_tokens":%s,"cost_usd_est":1.0,"total_cost_usd_est":1.0,"result":"%s"}\n' \
    "$now" "$1" "$2" "$3" "$3" "$4" >> "$cost_log"
}
row 10-landed-after-a-fail worker   1000 partial
row 10-landed-after-a-fail verifier 2000 fail
row 11-genuinely-failed    worker   4000 partial
row 11-genuinely-failed    verifier 8000 fail
row 12-clean-pass          worker   500  pass
row 12-clean-pass          verifier 500  pass

payload="$("$script_dir/aggregate-dashboard.sh" --repo "$repo" 2>/dev/null)"
[[ -n "$payload" ]] || { echo "FAIL: aggregator produced nothing" >&2; exit 1; }

field() { printf '%s' "$payload" | jq -r "$1"; }
card()  { printf '.history.cards[] | select(.id == "%s")' "$1"; }

printf '== 1. a landed stage reports no lost spend ==\n' >&2
check "landed stage lost_tokens is 0" \
  "$(eq 0 "$(field "$(card 10-landed-after-a-fail) | .lost_tokens")")"
check "its total spend is still counted" \
  "$(eq 3000 "$(field "$(card 10-landed-after-a-fail) | .tokens")")"

printf '== 2. and reads LANDED, not FAIL and not PASS ==\n' >&2
check "landed stage result is LANDED" \
  "$(eq LANDED "$(field "$(card 10-landed-after-a-fail) | .result")")"

printf '== 3. the failed dispatch is still visible underneath ==\n' >&2
check "its verifier dispatch still reads FAIL" \
  "$(eq FAIL "$(field "$(card 10-landed-after-a-fail) | .dispatches[] | select(.role == \"verifier\") | .result")")"

printf '== 4. a stage the ledger did not land still counts as lost ==\n' >&2
# The fix must not launder every failure into success. This is the assertion
# that would catch that.
check "unlanded stage keeps its lost tokens" \
  "$(eq 12000 "$(field "$(card 11-genuinely-failed) | .lost_tokens")")"
check "unlanded stage still reads FAIL" \
  "$(eq FAIL "$(field "$(card 11-genuinely-failed) | .result")")"
check "repo-level lost counts only the unlanded stage" \
  "$(eq 12000 "$(field '.spend.lost.tokens')")"

printf '== 5. a clean pass is untouched ==\n' >&2
check "clean stage still reads PASS" \
  "$(eq PASS "$(field "$(card 12-clean-pass) | .result")")"
check "clean stage has no lost tokens" \
  "$(eq 0 "$(field "$(card 12-clean-pass) | .lost_tokens")")"

if [[ "$fail" -eq 0 ]]; then printf 'adjudicated-spend-smoke: PASS\n' >&2
else printf 'adjudicated-spend-smoke: FAIL\n' >&2; fi
exit "$fail"

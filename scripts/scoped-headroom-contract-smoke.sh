#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/181-scoped-headroom.md
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export AUTOMETTA_HOME="$tmp/host" PHAT_CONTROLLER_HOME="$tmp/host"
mkdir -p "$tmp/repo/state" "$tmp/other/state" "$AUTOMETTA_HOME"
ln -s repo "$tmp/alias"
for dir in repo other; do printf '{"token_cap_total":300,"tokens_spent":120}\n' > "$tmp/$dir/state/budget.json"; done
drain="$AUTOMETTA_HOME/drain.json"
jq -n --arg repo "$tmp/repo" --argjson expiry "$(( $(date +%s) + 600 ))" '{repos:[$repo],expires_at:$expiry,token_cap_total:1000}' > "$drain"
cd "$tmp"
before="$(cksum "$drain" */state/budget.json)"
report() { "$root/scripts/readiness-headroom.sh" "$1" 400 700 250; }
for path in "$tmp/repo" ./repo other/../repo ./alias; do
  report "$path" | jq -e '. == {cap:1000,spent:120,headroom:880,card_shortfall:0,batch_shortfall:0,with_retry_shortfall:70}' >/dev/null || { echo "FAIL: cap or shortfall for $path" >&2; exit 1; }
done
report ./other | jq -e '.cap == 300 and .spent == 120 and .headroom == 180 and .with_retry_shortfall == 770' >/dev/null
[[ "$(cksum "$drain" */state/budget.json)" == "$before" ]]
if report ./absent >/dev/null 2>&1; then echo 'FAIL: missing repo reported ready' >&2; exit 1; fi
[[ ! -e ./absent ]]
# AUTOMETTA-CONTRACT-END
echo 'PASS: scoped headroom by repo path'

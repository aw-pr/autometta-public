#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/178-readiness-headroom.md
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export AUTOMETTA_HOME="$tmp/host" PHAT_CONTROLLER_HOME="$tmp/host"
repo="$tmp/repo"
mkdir -p "$repo/state" "$AUTOMETTA_HOME"
budget="$repo/state/budget.json"
printf '{"token_cap_total":650000,"tokens_spent":100000}\n' > "$budget"
helper="$root/scripts/readiness-headroom.sh"
[[ -x "$helper" ]] || { echo 'FAIL: readiness headroom report is unavailable' >&2; exit 1; }
report() { "$helper" "$repo" 700000 900000 400000; }
unchanged="$(cksum < "$budget")"
report | jq -e '.cap == 650000 and .spent == 100000 and .headroom == 550000 and
  .card_shortfall == 150000 and .batch_shortfall == 350000 and .with_retry_shortfall == 750000'
drain="$AUTOMETTA_HOME/drain.json"
jq -n --arg repo "$repo" --argjson expires "$(( $(date +%s) + 900 ))" \
  '{repos:[$repo],expires_at:$expires,token_cap_total:1600000}' > "$drain"
report | jq -e '.cap == 1600000 and .headroom == 1500000 and
  [.card_shortfall,.batch_shortfall,.with_retry_shortfall] == [0,0,0]'
jq '.expires_at = 1' "$drain" > "$tmp/expired"
cp "$tmp/expired" "$drain"
report | jq -e '.cap == 650000 and .with_retry_shortfall == 750000'
cmp "$tmp/expired" "$drain"
[[ "$(cksum < "$budget")" == "$unchanged" ]]
jq -n --argjson expires "$(( $(date +%s) + 900 ))" '{repos:["/other"],expires_at:$expires,token_cap_total:2000000}' > "$drain"
report | jq -e '.cap == 650000'
rm "$drain"
"$helper" "$repo" 0 400000 150000 | jq -e '.with_retry_shortfall == 0 and .headroom == 550000'
if "$helper" "$repo" 900000 700000 0; then echo 'FAIL: batch smaller than card' >&2; exit 1; fi
if "$helper" "$repo" invalid 700000 0; then echo 'FAIL: malformed estimate' >&2; exit 1; fi
printf 'token_cap_total: 1100000\n' > "$AUTOMETTA_HOME/config.yaml"
printf '{"tokens_spent":200000}\n' > "$budget"
report | jq -e '.cap == 1100000 and .with_retry_shortfall == 400000'
printf '{"tokens_spent":1200000}\n' > "$budget"
report | jq -e '.cap == 1100000 and .headroom == 0'
printf '{"token_cap_total":650000}\n' > "$budget"
if report >/dev/null; then echo 'FAIL: missing usage reported as known' >&2; exit 1; fi
for guide in autometta-card-review autometta-run-design; do
  grep -F 'readiness-headroom.sh' "$root/skills/$guide/SKILL.md" >/dev/null
done
# AUTOMETTA-CONTRACT-END

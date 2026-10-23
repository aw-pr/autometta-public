#!/usr/bin/env bash
# spend-authority-dropped-smoke.sh: the mandate's spend_authority field is gone
# from every live surface (card 162a).
#
# Card 162 removed the controller pass, which was the only reader of
# spend_authority, but the docs, template and setup skill went on saying the
# tick enforced it. The operator chose to drop the field rather than enforce
# it: each repo's budget.json caps and drains are the hard stops.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"

fail() {
  printf 'FAIL: 162a-spend-authority-dropped: %s\n' "$1" >&2
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/162a-spend-authority-dropped.md
tpl="$root/templates/phat-controller-mandate.yaml.tpl"
yq -e '.' "$tpl" >/dev/null 2>&1 || fail "the mandate template does not parse"
[[ "$(yq -r 'has("spend_authority")' "$tpl")" == "false" ]] \
  || fail "the mandate template still carries spend_authority"
for key in window_reserve escalation repos; do
  [[ "$(yq -r "has(\"$key\")" "$tpl")" == "true" ]] \
    || fail "the mandate template lost $key"
done

for rel in templates/phat-controller-mandate.yaml.tpl docs/tick-loop.md \
           skills/autometta-setup/SKILL.md scripts/phat-controller.sh; do
  if grep -n -i -E 'spend[ _-]authority' "$root/$rel" >/dev/null; then
    fail "$rel still mentions the spend authority"
  fi
done
if grep -n -i 'hard token ceiling' "$root/skills/autometta-setup/SKILL.md" >/dev/null; then
  fail "the setup skill still asks the operator for a token ceiling"
fi

proposal="$root/docs/proposals/controller-retired.md"
if grep -n 'Unchanged for the tick: `spend_authority`' "$proposal" >/dev/null; then
  fail "the proposal still says the tick reads spend_authority"
fi
consequences="$(awk '/^## Consequences/ { on = 1 } on' "$proposal")"
grep -q 'spend_authority' <<<"$consequences" \
  || fail "the proposal's Consequences do not record that spend_authority was dropped"

readers="$(cd "$root" && grep -l 'spend_authority' scripts/* bin/* 2>/dev/null \
  | grep -v -E -- '-smoke\.sh$' || true)"
[[ -z "$readers" ]] || fail "a script reads spend_authority: $readers"
# AUTOMETTA-CONTRACT-END

printf 'spend-authority-dropped-smoke: PASS\n'

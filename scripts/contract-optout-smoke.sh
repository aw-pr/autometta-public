#!/usr/bin/env bash
# Offline proof for stage card 152: a smoke can say it freezes nothing.
#
# Each case builds a throwaway git repo holding a copy of the gate under test,
# stages one change and runs the gate in its default (staged) mode. The marker
# strings are assembled at run time so this file carries only its own frozen
# block. No auth, no network, no token spend.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
gate_src="$script_dir/check-contract-test-gate.sh"
tmp="$(mktemp -d)"
cleanup() {
  case "$tmp" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$tmp" ;; esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

prefix="AUTOMETTA-CONTRACT-"
begin="${prefix}BEGIN"
end="${prefix}END"
none="${prefix}NONE"
case_no=0

fresh_repo() {
  case_no=$((case_no + 1))
  local dir="$tmp/case-$case_no"
  mkdir -p "$dir/scripts" "$dir/stage-cards"
  cp "$gate_src" "$dir/scripts/check-contract-test-gate.sh"
  printf '#!/usr/bin/env bash\necho plain v1\n' > "$dir/scripts/plain-smoke.sh"
  git -C "$dir" init -q
  git -C "$dir" -c user.name=smoke -c user.email=smoke@local add -A
  git -C "$dir" -c user.name=smoke -c user.email=smoke@local commit -q -m baseline
  printf '%s' "$dir"
}

gate_in() { # dir -> exit status of the staged gate, stderr kept in $dir/gate.err
  local dir="$1" rc=0
  git -C "$dir" add -A
  (cd "$dir" && scripts/check-contract-test-gate.sh) 2> "$dir/gate.err" >/dev/null || rc=$?
  printf '%s' "$rc"
}

card_naming() { # dir test-file digest
  printf '# Stage card 90: fixture\n\n## Contract test\n\n- **Test file:** %s\n- **Assertions digest:** %s\n' \
    "$2" "$3" > "$1/stage-cards/90-fixture.md"
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/152-a-smoke-can-say-it-freezes-nothing.md
# 1. Fail-closed stays: an edited smoke carrying no marker at all is refused.
d="$(fresh_repo)"
printf '#!/usr/bin/env bash\necho plain v2\n' > "$d/scripts/plain-smoke.sh"
[[ "$(gate_in "$d")" != 0 ]] || fail "152: an unmarked smoke edit must still be refused"
# 2. A smoke that declares it freezes nothing, with a reason, may change.
d="$(fresh_repo)"
printf '#!/usr/bin/env bash\n# %s reason=regression suite, not a stage contract\necho plain v2\n' "$none" > "$d/scripts/plain-smoke.sh"
[[ "$(gate_in "$d")" == 0 ]] || fail "152: an opted-out smoke edit was refused: $(cat "$d/gate.err")"
# 3. The opt-out needs a reason.
d="$(fresh_repo)"
printf '#!/usr/bin/env bash\n# %s\necho plain v2\n' "$none" > "$d/scripts/plain-smoke.sh"
[[ "$(gate_in "$d")" != 0 ]] || fail "152: an opt-out without reason= must be refused"
# 4. A card that records a real digest for an opted-out file contradicts it.
d="$(fresh_repo)"
printf '#!/usr/bin/env bash\n# %s reason=regression suite\necho plain v2\n' "$none" > "$d/scripts/plain-smoke.sh"
card_naming "$d" scripts/plain-smoke.sh '`sha256:0000000000000000000000000000000000000000000000000000000000000000`'
[[ "$(gate_in "$d")" != 0 ]] || fail "152: a card with a sha256 digest naming an opted-out smoke must be refused"
grep -q 'plain-smoke.sh' "$d/gate.err" || fail "152: the refusal should name the file"
# 5. A card that names an opted-out file with digest None agrees with it.
d="$(fresh_repo)"
printf '#!/usr/bin/env bash\n# %s reason=regression suite\necho plain v2\n' "$none" > "$d/scripts/plain-smoke.sh"
card_naming "$d" scripts/plain-smoke.sh None
[[ "$(gate_in "$d")" == 0 ]] || fail "152: a None-digest card naming an opted-out smoke was refused: $(cat "$d/gate.err")"
# 6. A file cannot both freeze a block and opt out.
d="$(fresh_repo)"
printf '#!/usr/bin/env bash\n# %s reason=both\n# %s card=stage-cards/90-fixture.md\necho v2\n# %s\n' \
  "$none" "$begin" "$end" > "$d/scripts/plain-smoke.sh"
card_naming "$d" scripts/plain-smoke.sh None
[[ "$(gate_in "$d")" != 0 ]] || fail "152: a smoke carrying both a frozen block and an opt-out must be refused"
# 7. A frozen block with a matching card still passes, and a changed one
#    still fails.
d="$(fresh_repo)"
printf '#!/usr/bin/env bash\n# %s card=stage-cards/90-fixture.md\necho frozen v1\n# %s\n' "$begin" "$end" > "$d/scripts/plain-smoke.sh"
card_naming "$d" scripts/plain-smoke.sh "\`$(cd "$d" && scripts/check-contract-test-gate.sh print scripts/plain-smoke.sh)\`"
[[ "$(gate_in "$d")" == 0 ]] || fail "152: a frozen smoke with its matching digest was refused: $(cat "$d/gate.err")"
git -C "$d" -c user.name=smoke -c user.email=smoke@local commit -q -m frozen
sed -i.bak 's/frozen v1/frozen v2/' "$d/scripts/plain-smoke.sh" && rm -f "$d/scripts/plain-smoke.sh.bak"
[[ "$(gate_in "$d")" != 0 ]] || fail "152: a changed frozen block must still be refused"
# 8. Every smoke in this repo declares one or the other, and the TUI smoke
#    card 80 names with digest None is an opt-out.
missing=()
for f in "$repo_root"/scripts/*-smoke.sh; do
  if ! grep -q "$begin" "$f" && ! grep -Eq "$none reason=[^[:space:]]" "$f"; then
    missing+=("$(basename "$f")")
  fi
done
(( ${#missing[@]} == 0 )) || fail "152: smokes declaring neither a frozen block nor an opt-out: ${missing[*]}"
grep -Eq "$none reason=[^[:space:]]" "$repo_root/scripts/tui-smoke.sh" \
  || fail "152: scripts/tui-smoke.sh should carry an opt-out with a reason"
# AUTOMETTA-CONTRACT-END

printf 'contract-optout-smoke: PASS\n'

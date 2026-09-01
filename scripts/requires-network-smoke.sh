#!/usr/bin/env bash
# requires-network-smoke.sh: offline proof of the card-level network grant.
# No auth, no network, no token spend.
#
# Codex's workspace-write sandbox denies network to every model-generated
# shell command, which is the right default. A stage whose deliverable is
# itself an agent session cannot run under it: card 23's SDK experiment died
# on "API Error: Unable to connect to API (FailedToOpenSocket)" before its
# Bash tool ever executed. `- **Requires network:** true` lifts exactly that,
# and nothing else.
#
# What it asserts:
#
#   1. The resolver emits the codex config flag only for a card that asks.
#   2. It stays out of the way under danger-full-access, which already has
#      network, and under read-only, which must not gain it.
#   3. It is a distinct grant from Requires GUI: a network card keeps
#      workspace-write, so filesystem confinement survives.
#   4. Both spawners extract the field from a real card body.
#   5. Every codex dispatch site in both spawners threads the argv, so the
#      grant cannot be honoured on one route and silently dropped on another.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./models.sh
source "$script_dir/models.sh"

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

argv_of() {
  # argv_of <requires-network> <sandbox>
  # Joined on a space deliberately: this file sets IFS to newline/tab, and
  # "${arr[*]}" would otherwise join on a newline and compare unequal to a
  # flag that is correct.
  codex_network_argv_for_card "$1" "$2"
  ( IFS=' '; printf '%s' "${AUTOMETTA_CODEX_NETWORK_ARGV[*]-}" )
}

argc_of() {
  codex_network_argv_for_card "$1" "$2"
  printf '%s' "${#AUTOMETTA_CODEX_NETWORK_ARGV[@]}"
}

granted='-c sandbox_workspace_write.network_access=true'

printf '== 1. the flag appears only for a card that asks ==\n' >&2
for yes in true True TRUE yes 1; do
  check "requires-network '$yes' grants the socket" \
    "$(eq "$granted" "$(argv_of "$yes" workspace-write)")"
done
# codex takes -c and its assignment as two argv elements. One joined string
# would be parsed as a single unknown flag, so the split is the contract.
check "the grant is two argv elements, not one joined string" \
  "$(eq 2 "$(argc_of true workspace-write)")"

for no in false False no 0 "" "maybe" "true-ish"; do
  check "requires-network '${no:-<empty>}' grants nothing" \
    "$(eq "" "$(argv_of "$no" workspace-write)")"
done

printf '== 2. it is silent where it would be meaningless or wrong ==\n' >&2
check "danger-full-access already has network, so no flag is added" \
  "$(eq "" "$(argv_of true danger-full-access)")"
check "read-only does not gain a network grant" \
  "$(eq "" "$(argv_of true read-only)")"

printf '== 3. it is a narrower grant than Requires GUI ==\n' >&2
# Requires GUI drops the sandbox entirely and hands over the machine. A
# network card must not: workspace-write's filesystem confinement is the
# thing worth keeping, and the socket is the only thing being opened.
check "a GUI card resolves to danger-full-access" \
  "$(eq danger-full-access "$(resolve_codex_sandbox_for_card "$tmp_root" true)")"
check "a network card leaves the sandbox at workspace-write" \
  "$(eq workspace-write "$(resolve_codex_sandbox_for_card "$tmp_root" false)")"

printf '== 4. both spawners read the field off a real card ==\n' >&2
card="$tmp_root/91-a-card.md"
cat > "$card" <<'CARD'
# Stage card 91: a card

## Metadata

- **Worker effort:** high
- **Requires GUI:** false
- **Requires network:** true
- **Verifier panel:** false
CARD
for spawn in spawn-worker spawn-verifier; do
  extracted="$(
    # shellcheck disable=SC1090
    sed -n '/^extract_requires_network() {$/,/^}$/p' "$script_dir/$spawn.sh" > "$tmp_root/fn.sh"
    source "$tmp_root/fn.sh"
    extract_requires_network "$card"
  )"
  check "$spawn extracts Requires network from the card" "$(eq true "$extracted")"
done

printf '== 5. every codex dispatch site threads the argv ==\n' >&2
# The grant is worthless if one of the three routes drops it, and that is
# invisible until a stage on that route fails the way card 23 did.
for spawn in spawn-worker spawn-verifier; do
  sandbox_sites="$(grep -c -- '--sandbox "$codex_sandbox"' "$script_dir/$spawn.sh" || true)"
  network_sites="$(grep -c -- 'AUTOMETTA_CODEX_NETWORK_ARGV\[@\]+' "$script_dir/$spawn.sh" || true)"
  check "$spawn threads the network argv at all $sandbox_sites sandbox sites" \
    "$(eq "$sandbox_sites" "$network_sites")"
done

if [[ "$fail" -eq 0 ]]; then
  printf 'requires-network-smoke: PASS\n' >&2
else
  printf 'requires-network-smoke: FAIL\n' >&2
fi
exit "$fail"

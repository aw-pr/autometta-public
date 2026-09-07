#!/usr/bin/env bash
# Card 114: run one tick fire with AUTOMETTA_TICK_PROFILE=1 and print a cost
# table sorted by phase cost. This is the tool the next person reaches for
# when a fire feels slow, rather than re-deriving profile parsing by hand.
#
# Honours the same AUTOMETTA_ROOT / PHAT_CONTROLLER_HOME overrides tick.sh
# itself does (scripts/resolve-root.sh), so it can be pointed at a fixture
# fleet exactly as scripts/tick-profile-smoke.sh does.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

AUTOMETTA_TICK_PROFILE=1 "$script_dir/tick.sh" >"$log_file" 2>&1 || {
  cat "$log_file" >&2
  printf 'tick-profile: the fire exited non-zero; see output above\n' >&2
  exit 1
}

if ! grep -Eq 'profile repo=[^ ]+ phase=[^ ]+ ms=[0-9]+' "$log_file"; then
  cat "$log_file" >&2
  printf 'tick-profile: no profile lines were emitted; is AUTOMETTA_TICK_PROFILE wired up?\n' >&2
  exit 1
fi

printf '%-24s %-16s %10s\n' "repo" "phase" "ms"
printf '%-24s %-16s %10s\n' "----" "-----" "--"
grep -Eo 'profile repo=[^ ]+ phase=[^ ]+ ms=[0-9]+' "$log_file" \
  | sed -E 's/^profile repo=([^ ]+) phase=([^ ]+) ms=([0-9]+)$/\3\t\1\t\2/' \
  | sort -t"$(printf '\t')" -k1,1nr \
  | awk -F'\t' '{ printf "%-24s %-16s %8s ms\n", $2, $3, $1 }'

total_ms="$(grep -Eo 'phase=[^ ]+ ms=[0-9]+' "$log_file" \
  | awk -F'ms=' '{ s += $2 } END { printf "%d\n", s+0 }')"
printf '%-24s %-16s %10s\n' "----" "-----" "--"
printf '%-24s %-16s %8s ms\n' "TOTAL" "" "$total_ms"

fire_line="$(grep -E 'profile fire total_ms=[0-9]+' "$log_file" | tail -n1 || true)"
[[ -n "$fire_line" ]] && printf '\n%s\n' "$fire_line"

#!/usr/bin/env bash
# vendor-staleness-smoke.sh: vendor freshness is judged on the files, not on
# the stamp. Card 136. Offline, no token spend; the fixture subscriber is
# built from this checkout's own vendored set.
#
# The defect it pins: warn_if_vendor_stale (scripts/tick.sh) and the fleet
# ticker's vendor_stale flag (scripts/aggregate-dashboard.sh) compare the
# stamp's vendored_from sha against the autometta checkout's HEAD and never
# look at a file. Every upstream commit therefore flags every subscriber as
# stale, byte-identical files or not, and the line it logs ("stale vendor:
# ... run: autometta refresh-repo") does not say that dispatch continues.
# On 2026-09-07 an operator reading that line above an empty dispatch log
# spent twenty minutes restamping emergence-lab before finding the real
# stop (card 135). The check that does read files,
# scripts/autometta-vendor-check.sh, is the one nothing in the tick calls.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd "$script_dir/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected $1, got $2"
}
assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: missing $2"
}
assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "$3: unexpectedly found $2"
}

export AUTOMETTA_HOME="$fixture/controller"
mkdir -p "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_HOME/log"

# shellcheck source=./vendor-set.sh
source "$script_dir/vendor-set.sh"

# A subscriber holding every vendored file byte-for-byte from this checkout,
# stamped from a sha that is not this checkout's HEAD. That is exactly
# emergence-lab on 2026-09-07: files current, marker behind.
repo="$fixture/subscriber"
mkdir -p "$repo/state"
git -C "$fixture" init -q -b dev subscriber
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  mkdir -p "$repo/$(dirname "$f")"
  cp "$source_root/$f" "$repo/$f"
done < <(autometta_vendored_files)
autometta_write_vendor_stamp "$repo/$autometta_vendor_stamp_name" 0000000
vendored_count="$(autometta_vendored_files | grep -c .)"
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages: []
YAML
cat > "$repo/state/budget.json" <<'JSON'
{"paused_until":null,"paused_reason":null}
JSON
cat > "$AUTOMETTA_HOME/subscribers/subscriber.yaml" <<YAML
enabled: true
repo_path: "$repo"
manifest_path: "$repo/.autometta.local.yaml"
YAML

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

tick_log_path="$AUTOMETTA_HOME/log/tick-$(date +%F).log"
reset_warning_guard() { vendor_staleness_warned=""; : > "$tick_log_path"; }

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/136-vendor-freshness-is-judged-on-the-files-not-the-stamp.md

# --- Acceptance 1: files current, stamp behind. The tick says the contract
# is current, says dispatch continues, and does not call it stale.
reset_warning_guard
warn_if_vendor_stale "$repo"
current_log="$(cat "$tick_log_path")"
assert_not_contains "$current_log" "stale vendor:" "current files are not reported stale"
assert_contains "$current_log" "vendor stamp behind" "the stamp lag is named for what it is"
assert_contains "$current_log" "${vendored_count} vendored files current" "the file count is stated"
assert_contains "$current_log" "dispatch continues" "the line says dispatch is unaffected"
printf 'PASS acceptance 1: a behind stamp over current files is a note, not a staleness warning\n'

# --- Acceptance 2: one file genuinely drifted. Now it is stale, the drifted
# file is named, and the line still says dispatch continues.
printf '\n# local drift\n' >> "$repo/scripts/check-contract-test-gate.sh"
reset_warning_guard
warn_if_vendor_stale "$repo"
drift_log="$(cat "$tick_log_path")"
assert_contains "$drift_log" "stale vendor:" "a drifted file is reported stale"
assert_contains "$drift_log" "scripts/check-contract-test-gate.sh" "the drifted file is named"
assert_contains "$drift_log" "dispatch continues" "staleness never claims to stop dispatch"
assert_contains "$drift_log" "autometta refresh-repo" "the remedy is still one command"
printf 'PASS acceptance 2: real drift is stale, named, and still non-blocking\n'

# --- Acceptance 3: the fleet ticker's flag follows the files too. Restore
# the file: vendor_stale must read false with the stamp still behind.
cp "$source_root/scripts/check-contract-test-gate.sh" "$repo/scripts/check-contract-test-gate.sh"
"$script_dir/aggregate-dashboard.sh" >/dev/null
assert_eq false "$(jq -r '.repos[0].vendor_stale' "$AUTOMETTA_HOME/dashboard/data.json")" "dashboard: current files are not stale"
assert_eq 0000000 "$(jq -r '.repos[0].vendor_from' "$AUTOMETTA_HOME/dashboard/data.json")" "dashboard still reports the stamp sha"
printf '\n# local drift\n' >> "$repo/templates/stage-card.md"
"$script_dir/aggregate-dashboard.sh" >/dev/null
assert_eq true "$(jq -r '.repos[0].vendor_stale' "$AUTOMETTA_HOME/dashboard/data.json")" "dashboard: a drifted file is stale"
printf 'PASS acceptance 3: the fleet flag is file-based\n'

# --- Acceptance 4: a filled placeholder is not drift, in the tick as in the
# check. Replace the drifted template with one whose only change is a
# completed <<placeholder>> slot.
cp "$source_root/templates/stage-card.md" "$repo/templates/stage-card.md"
python3 - "$repo/templates/stage-card.md" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"<<[^>]*>>", "filled downstream", s, count=1)
open(p, "w").write(s)
PY
reset_warning_guard
warn_if_vendor_stale "$repo"
filled_log="$(cat "$tick_log_path")"
assert_not_contains "$filled_log" "stale vendor:" "a filled placeholder is not drift"
printf 'PASS acceptance 4: filled placeholders read as current, matching autometta-vendor-check.sh\n'

# AUTOMETTA-CONTRACT-END

printf 'PASS vendor-staleness-smoke: freshness is judged on the files, not the stamp\n'

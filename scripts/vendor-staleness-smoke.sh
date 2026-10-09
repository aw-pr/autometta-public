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

# Exercise the checker from a subscriber, including its own vendored copy.
cp "$source_root/templates/stage-card.md" "$repo/templates/stage-card.md"
checker_output="$(cd "$repo" && AUTOMETTA_ROOT="$source_root" bash scripts/autometta-vendor-check.sh)"
assert_contains "$checker_output" "vendor stamp behind" "checker notes stamp lag"
assert_contains "$checker_output" "6 vendored files current" "checker counts current files"
assert_contains "$checker_output" "dispatch continues" "checker note is non-blocking"
assert_contains "$checker_output" "autometta refresh-repo ." "checker names the remedy"

# Filled files count as current, while retaining the checker's FILLED line.
python3 - "$repo/templates/stage-card.md" <<'PY'
import re, sys
p = sys.argv[1]
with open(p) as f:
    s = f.read()
with open(p, "w") as f:
    f.write(re.sub(r"<<[^>]*>>", "filled downstream", s, count=1))
PY
checker_output="$(cd "$repo" && AUTOMETTA_ROOT="$source_root" bash scripts/autometta-vendor-check.sh)"
assert_contains "$checker_output" "FILLED templates/stage-card.md" "checker preserves filled reporting"
assert_contains "$checker_output" "6 vendored files current" "checker includes filled files in current count"
cp "$source_root/templates/stage-card.md" "$repo/templates/stage-card.md"

reset_warning_guard
warn_if_vendor_stale "$repo"
warn_if_vendor_stale "$repo"
assert_eq 1 "$(wc -l < "$tick_log_path" | tr -d '[:space:]')" "stamp note occurs once per pass"

# A matching stamp cannot hide real drift or a missing file.
autometta_write_vendor_stamp "$repo/$autometta_vendor_stamp_name" "$autometta_sha_this_pass"
reset_warning_guard
warn_if_vendor_stale "$repo"
assert_eq "" "$(cat "$tick_log_path")" "matching stamp and files are silent"
"$script_dir/aggregate-dashboard.sh" >/dev/null
cp "$AUTOMETTA_HOME/dashboard/data.json" "$fixture/current-dashboard.json"
assert_eq "$vendored_count" "$(jq -r '.repos[0].vendor_files_current' "$fixture/current-dashboard.json")" "dashboard counts current files"
assert_eq '[]' "$(jq -c '.repos[0].vendor_drifted' "$fixture/current-dashboard.json")" "dashboard has no drifted paths"

printf '\n# local drift\n' >> "$repo/scripts/check-contract-test-gate.sh"
checker_rc=0
checker_output="$(cd "$repo" && AUTOMETTA_ROOT="$source_root" bash scripts/autometta-vendor-check.sh)" || checker_rc=$?
assert_eq 1 "$checker_rc" "checker exits 1 for content drift"
assert_contains "$checker_output" "DRIFT  scripts/check-contract-test-gate.sh" "checker names content drift"
rm "$repo/templates/worker-prompt.md"
printf 'file: templates/retired.md\n' >> "$repo/$autometta_vendor_stamp_name"
checker_rc=0
checker_output="$(cd "$repo" && AUTOMETTA_ROOT="$source_root" bash scripts/autometta-vendor-check.sh)" || checker_rc=$?
assert_eq 1 "$checker_rc" "checker exits 1 for missing files"
assert_contains "$checker_output" "GONE   templates/worker-prompt.md" "checker preserves missing reporting"
assert_contains "$checker_output" "RETIRED templates/retired.md" "checker preserves retired reporting"

subscriber_snapshot() {
  python3 - "$repo" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
for p in sorted(root.rglob("*")):
    if p.is_file() and ".git" not in p.relative_to(root).parts:
        print(p.relative_to(root), hashlib.sha256(p.read_bytes()).hexdigest())
PY
}
snapshot_before="$(subscriber_snapshot)"
reset_warning_guard
warn_if_vendor_stale "$repo"
warn_if_vendor_stale "$repo"
assert_eq 1 "$(wc -l < "$tick_log_path" | tr -d '[:space:]')" "drift warning occurs once per pass"
assert_contains "$(cat "$tick_log_path")" "templates/worker-prompt.md" "tick names missing file despite matching stamp"
assert_contains "$(cat "$tick_log_path")" "scripts/check-contract-test-gate.sh" "tick names every drifted file"
"$script_dir/aggregate-dashboard.sh" >/dev/null
assert_eq "$snapshot_before" "$(subscriber_snapshot)" "tick and dashboard leave subscriber files unchanged"
assert_eq 4 "$(jq -r '.repos[0].vendor_files_current' "$AUTOMETTA_HOME/dashboard/data.json")" "dashboard excludes missing and drifted files"
assert_eq '["templates/worker-prompt.md","scripts/check-contract-test-gate.sh"]' \
  "$(jq -c '.repos[0].vendor_drifted' "$AUTOMETTA_HOME/dashboard/data.json")" "dashboard names missing and drifted paths"

python3 - "$script_dir/lib/fleet-ticker-render.py" "$fixture/current-dashboard.json" "$AUTOMETTA_HOME/dashboard/data.json" <<'PY'
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("fleet_renderer", sys.argv[1])
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
with open(sys.argv[2]) as f:
    current = json.load(f)
with open(sys.argv[3]) as f:
    drifted = json.load(f)
assert not any(r["result"] == "vendor-stale" for r in renderer.collect_escalation_rows(current["repos"], time.time()))
rows = [r for r in renderer.collect_escalation_rows(drifted["repos"], time.time()) if r["result"] == "vendor-stale"]
assert len(rows) == 1
for path in drifted["repos"][0]["vendor_drifted"]:
    assert path in rows[0]["detail"]
assert "dispatch continues" in rows[0]["detail"]
assert "autometta refresh-repo" in rows[0]["detail"]
PY
printf 'PASS supplementary checks: checker exits, counts, fleet paths, matching stamps, once-per-pass guard and read-only consumers\n'

printf 'PASS vendor-staleness-smoke: freshness is judged on the files, not the stamp\n'

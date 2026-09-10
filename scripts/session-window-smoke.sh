#!/usr/bin/env bash
# Offline contract proof for the schedule-aware window_reserve: the resolved
# reserve varies by wall-clock time, an in-flight stage still lands past the
# window's end, and a --ignore-reserve drain cannot outlive the window that
# permits it. Every schedule-resolution case drives an injected clock
# (AUTOMETTA_SCHEDULE_CLOCK) rather than the hour it happens to run in. The
# one exception is the live-drain case in acceptance 5, which cannot: a
# drain's expiry is read against the real clock by budget.sh, outside this
# card's path claims. That case builds a window positioned relative to the
# real now instead, so it too reads the same at any hour.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected $1, got $2"
}
assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: missing $2"
}

export AUTOMETTA_HOME="$fixture/controller"
mkdir -p "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_HOME/log"

# Plain mandate: no overnight block declared at all. Deliverable 2 must not
# change this mandate's resolution in any way.
plain_mandate="$fixture/plain-mandate.yaml"
cat > "$plain_mandate" <<'YAML'
window_reserve:
  percent: 12
  action: hold
YAML

# Scheduled mandate: the shape deliverable 1 adds. Daytime holds at 20%;
# 22:00-01:00 (crossing midnight) drains freely; the schedule is read in
# local wall-clock time (timezone: local), never UTC.
sched_mandate="$fixture/sched-mandate.yaml"
cat > "$sched_mandate" <<'YAML'
window_reserve:
  percent: 20
  action: hold
  overnight:
    start: "22:00"
    end: "01:00"
    percent: 0
  timezone: local
YAML

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/124-a-daytime-run-leaves-the-operator-a-session.md

# --- Acceptance 1: an unconfigured mandate resolves exactly as it did before
# this card, byte for byte -- two tab-separated fields, no window column.
plain_out="$(quota_reserve_settings "$plain_mandate")"
assert_eq "$(printf '12\thold')" "$plain_out" "unconfigured mandate output unchanged"
assert_eq 2 "$(awk -F'\t' '{print NF}' <<<"$plain_out")" "unconfigured mandate stays two fields"
printf 'PASS acceptance 1: no overnight declared resolves byte-for-byte as today\n'

# --- Acceptance 2: the schedule resolves per the current moment, and the
# midnight crossing is one interval, not two comparisons. The naive
# start<=now<end test is wrong for a wrapping window and never binds at
# all, which is exactly the case this pins: 23:00 and 00:30 both cross
# midnight relative to a 22:00-01:00 window.
check_resolved() {
  local clock="$1" want_percent="$2" want_window="$3"
  local out percent action window
  out="$(AUTOMETTA_SCHEDULE_CLOCK="$clock" quota_reserve_settings "$sched_mandate")"
  IFS=$'\t' read -r percent action window <<<"$out"
  assert_eq "$want_percent" "$percent" "resolved percent at ${clock}"
  assert_eq "hold" "$action" "resolved action at ${clock}"
  assert_eq "$want_window" "$window" "resolved window at ${clock}"
}
check_resolved 14:00 20 daytime
check_resolved 23:00 0 overnight
check_resolved 00:30 0 overnight
check_resolved 01:30 20 daytime
# A pre-change quota_reserve_settings reads only the top-level percent/action
# and has never heard of AUTOMETTA_SCHEDULE_CLOCK or an overnight block,
# so it would resolve every clock above to "20 hold" with no third field --
# these four checks are new failures against it, satisfying acceptance 6.
printf 'PASS acceptance 2: schedule resolves per the clock; midnight crossing is one interval\n'

# --- Repo fixture for acceptance 3 and 4: gate + dispatch decisions, not
# just the resolver. One stage already in flight when the overnight window
# ends (its worker was dispatched under the suspended reserve and carries
# reserve_exempt), one stage still pending.
repo="$fixture/repo"
mkdir -p "$repo/state"
git -C "$fixture" init -q -b dev repo
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: flight-stage
stages:
  - id: flight-stage
    status: in_progress
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    reserve_exempt: true
  - id: fresh-stage
    status: pending
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "GPT-5.6 Sol <gpt-5-6-sol@local>"
YAML
cat > "$repo/state/budget.json" <<'JSON'
{"paused_until":null,"paused_reason":null}
JSON
cp "$sched_mandate" "$AUTOMETTA_HOME/phat-controller-mandate.yaml"

reading_85() {
  jq -nc --arg reset "$1" '
    {read_at:null, families:{
      claude:{family:"claude", status:"known", reason:null, source:"fixture", fetched_at:null,
              windows:[{key:"five_hour", label:"5-hour", utilization:85, resets_at:$reset}]},
      codex:{family:"codex", status:"unknown", reason:"no rollout files", source:null, fetched_at:null, windows:[]}
    }}'
}
# A window that reset in the night and is barely touched. The reserve has
# nothing to bind on here, which is the whole point: this is what an
# overnight run looks like at nine the next morning.
reading_healthy() {
  jq -nc '
    {read_at:null, families:{
      claude:{family:"claude", status:"known", reason:null, source:"fixture", fetched_at:null,
              windows:[{key:"five_hour", label:"5-hour", utilization:10, resets_at:"2033-05-18T03:38:20Z"}]},
      codex:{family:"codex", status:"unknown", reason:"no rollout files", source:null, fetched_at:null, windows:[]}
    }}'
}
AUTOMETTA_QUOTA_TICK_JSON="$(reading_85 "2033-05-18T03:38:20Z")"

# --- Acceptance 3: at 01:30, past the overnight window's end, a fresh
# worker dispatch is refused (the daytime reserve has resumed and a
# near-exhausted Claude window sits inside it); the stage already in
# flight at 01:00 still reaps and lands -- its verifier is exempt because
# its worker was dispatched while the reserve was suspended, and finishing
# already-claimed work is never what the schedule stop refuses.
fresh_rc=0
AUTOMETTA_SCHEDULE_CLOCK=01:30 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  fresh-stage worker || fresh_rc=$?
assert_eq 1 "$fresh_rc" "fresh stage worker held at 01:30 (daytime reserve resumed)"

# The stop must not be the reserve wearing a hat. Every case below drives a
# reading the reserve cannot act on -- healthy, then unknown -- so a refusal
# can only have come from the clock. Without this, the assertion above passes
# against a tree that has no stop in it at all, because the 85%% reading is
# inside the daytime reserve and the reserve alone accounts for the 1.
AUTOMETTA_QUOTA_TICK_JSON="$(reading_healthy)"
healthy_rc=0
AUTOMETTA_SCHEDULE_CLOCK=01:30 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  fresh-stage worker || healthy_rc=$?
assert_eq 1 "$healthy_rc" "stop refuses a fresh worker at 01:30 on a healthy reading"
assert_eq null "$(jq -r '.paused_until' "$repo/state/budget.json")" "the stop refuses the dispatch without pausing the repo"

morning_rc=0
AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  fresh-stage worker || morning_rc=$?
assert_eq 1 "$morning_rc" "stop refuses a fresh worker at 09:00 on a healthy reading"

AUTOMETTA_QUOTA_TICK_JSON="$(jq -nc '{read_at:null, families:{
  claude:{family:"claude", status:"unknown", reason:"snapshot absent", source:null, fetched_at:null, windows:[]},
  codex:{family:"codex", status:"unknown", reason:"no rollout files", source:null, fetched_at:null, windows:[]}
}}')"
unknown_stop_rc=0
AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  fresh-stage worker || unknown_stop_rc=$?
assert_eq 1 "$unknown_stop_rc" "stop refuses a fresh worker at 09:00 on an unknown reading"

# Inside the window the stop is silent and the dispatch proceeds on the same
# healthy reading, so the refusals above are the clock and not a blanket no.
AUTOMETTA_QUOTA_TICK_JSON="$(reading_healthy)"
inside_rc=0
AUTOMETTA_SCHEDULE_CLOCK=23:30 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  fresh-stage worker || inside_rc=$?
assert_eq 0 "$inside_rc" "stop permits a fresh worker inside the window"

# The reason the tick logs, asserted directly rather than scraped from a log.
stop_reason_rc=0
AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_schedule_permits_dispatch \
  "$AUTOMETTA_HOME/phat-controller-mandate.yaml" "$repo" || stop_reason_rc=$?
assert_eq 1 "$stop_reason_rc" "quota_schedule_permits_dispatch refuses outside the window"
assert_contains "$QUOTA_SCHEDULE_STOP_REASON" "22:00-01:00" "the refusal names the window"
assert_contains "$QUOTA_SCHEDULE_STOP_REASON" "09:00" "the refusal names the clock it read"

# An unconfigured mandate must never be stopped: no schedule, no stop.
plain_stop_rc=0
AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_schedule_permits_dispatch "$plain_mandate" "$repo" || plain_stop_rc=$?
assert_eq 0 "$plain_stop_rc" "no schedule declared means no stop"

AUTOMETTA_QUOTA_TICK_JSON="$(reading_85 "2033-05-18T03:38:20Z")"

jq '.paused_until=null | .paused_reason=null' "$repo/state/budget.json" > "$repo/state/budget.next"
mv "$repo/state/budget.next" "$repo/state/budget.json"

flight_rc=0
AUTOMETTA_SCHEDULE_CLOCK=01:30 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  flight-stage verifier || flight_rc=$?
assert_eq 0 "$flight_rc" "in-flight stage verifier still proceeds past the window's end"
printf 'PASS acceptance 3: schedule stop refuses new dispatch only; an in-flight stage still lands\n'

# --- Acceptance 4: the 20%% daytime reserve holds an 85%%-utilised window
# (15%% remaining <= 20%%) and pauses to the published reset; the same
# reading at 23:00 (reserve suspended for the night) dispatches; an unknown
# reading fails open at both times, exactly as it does today.
# Criterion 4 is a statement about the reserve, so it is exercised against
# the reserve gate directly. Since the stop landed above it, a daytime
# quota_gate_role_dispatch refuses on the clock before the reserve is ever
# consulted, and asserting criterion 4 through the role gate would only
# re-prove the stop. See the PROPOSED-AMENDMENT on the card.
day_rc=0
AUTOMETTA_SCHEDULE_CLOCK=14:00 quota_gate_family_dispatch "$repo" claude "daytime reserve" || day_rc=$?
assert_eq 1 "$day_rc" "85%% utilisation held under the 20%% daytime reserve"
assert_eq 2000000300 "$(jq -r '.paused_until' "$repo/state/budget.json")" "pause carries the snapshot reset"

jq '.paused_until=null | .paused_reason=null' "$repo/state/budget.json" > "$repo/state/budget.next"
mv "$repo/state/budget.next" "$repo/state/budget.json"

night_rc=0
AUTOMETTA_SCHEDULE_CLOCK=23:00 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  fresh-stage worker || night_rc=$?
assert_eq 0 "$night_rc" "same 85%% reading dispatches at 23:00 (reserve off)"
assert_eq null "$(jq -r '.paused_until' "$repo/state/budget.json")" "overnight dispatch leaves pause untouched"

AUTOMETTA_QUOTA_TICK_JSON="$(jq -nc '{read_at:null, families:{
  claude:{family:"claude", status:"unknown", reason:"snapshot absent", source:null, fetched_at:null, windows:[]},
  codex:{family:"codex", status:"unknown", reason:"no rollout files", source:null, fetched_at:null, windows:[]}
}}')"
unknown_day_rc=0
AUTOMETTA_SCHEDULE_CLOCK=14:00 quota_gate_family_dispatch "$repo" claude "daytime unknown" || unknown_day_rc=$?
unknown_night_rc=0
AUTOMETTA_SCHEDULE_CLOCK=23:00 quota_gate_family_dispatch "$repo" claude "overnight unknown" || unknown_night_rc=$?
assert_eq 0 "$unknown_day_rc" "unknown reading fails open in daytime"
assert_eq 0 "$unknown_night_rc" "unknown reading fails open overnight"
printf 'PASS acceptance 4: 85%% held in daytime, dispatches overnight; unknown always fails open\n'

# --- Acceptance 5: --ignore-reserve suspends the daytime reserve for the
# life of the drain and no longer, and a --hours that would still be
# running past the overnight window's end is refused at start. drain.sh
# reads the real clock by default; AUTOMETTA_DRAIN_NOW_EPOCH pins it here to
# 14:00 local so the refusal is reachable regardless of the hour this test
# happens to run in.
# A live drain is the one thing here that cannot run on an injected clock.
# budget_drain_active compares the drain's expires_at against the real clock
# (budget.sh is outside this card's path claims and is deliberately not
# touched), so back-dating the drain's start to a fixed 14:00 made it
# already-expired for any run after 16:00 local -- the case was red for
# roughly two thirds of the day. Both clocks are therefore made real here:
# the drain is opened from the actual now, and the schedule is driven by a
# window positioned relative to that same now, so this case reads the same
# at any hour. The fixed-clock fixture returns for the refusal below, which
# is a start-time check and never consults budget_drain_active.
rel_mandate="$fixture/relative-mandate.yaml"
python3 - "$rel_mandate" <<'PY'
import datetime as dt, sys
now = dt.datetime.now()
start = (now + dt.timedelta(hours=3)).strftime("%H:%M")
end = (now + dt.timedelta(hours=5)).strftime("%H:%M")
open(sys.argv[1], "w").write(
    "window_reserve:\n"
    "  percent: 20\n"
    "  action: hold\n"
    "  overnight:\n"
    f'    start: "{start}"\n'
    f'    end: "{end}"\n'
    "    percent: 0\n"
    "  timezone: local\n"
)
PY
cp "$rel_mandate" "$AUTOMETTA_HOME/phat-controller-mandate.yaml"

"$script_dir/drain.sh" start --cap 999999999 --hours 2 --ignore-reserve >/dev/null
AUTOMETTA_QUOTA_TICK_JSON="$(reading_85 "2033-05-18T03:38:20Z")"
ignore_rc=0
quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" fresh-stage worker || ignore_rc=$?
assert_eq 0 "$ignore_rc" "--ignore-reserve suspends the daytime reserve for its duration"
"$script_dir/drain.sh" end >/dev/null

expired_rc=0
quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" fresh-stage worker || expired_rc=$?
assert_eq 1 "$expired_rc" "dispatch is refused again once the drain has ended"
reserve_back_rc=0
quota_gate_family_dispatch "$repo" claude "post-drain reserve" || reserve_back_rc=$?
assert_eq 1 "$reserve_back_rc" "reserve is not suspended once the drain has ended"

jq '.paused_until=null | .paused_reason=null' "$repo/state/budget.json" > "$repo/state/budget.next"
mv "$repo/state/budget.next" "$repo/state/budget.json"
cp "$sched_mandate" "$AUTOMETTA_HOME/phat-controller-mandate.yaml"

# A start-time refusal only: this path never consults budget_drain_active,
# so it can keep the fixed clock the fixed-window fixture is written against.
now_14=$(python3 -c 'import datetime; print(int(datetime.datetime.now().replace(hour=14, minute=0, second=0, microsecond=0).timestamp()))')
overrun_rc=0
AUTOMETTA_DRAIN_NOW_EPOCH="$now_14" "$script_dir/drain.sh" start --cap 999999999 --hours 12 --ignore-reserve \
  >"$fixture/overrun.log" 2>&1 || overrun_rc=$?
assert_eq 1 "$overrun_rc" "a drain that would outlive the overnight window is refused at start"
assert_contains "$(cat "$fixture/overrun.log")" "overnight window" "refusal names the window"
printf 'PASS acceptance 5: --ignore-reserve suspends the reserve for its own life only, never past the window\n'

# AUTOMETTA-CONTRACT-END

for file in quota-window.sh budget.sh tick.sh drain.sh; do
  bash -n "$script_dir/$file"
done
printf 'PASS syntax: touched shell files parse\n'

# Both smokes build their own AUTOMETTA_HOME/PHAT_CONTROLLER_HOME fixture;
# this file's own exported AUTOMETTA_HOME must not leak into either, or
# autometta_controller_home()'s precedence picks this fixture over theirs.
env -u AUTOMETTA_HOME "$script_dir/quota-window-smoke.sh" >/dev/null
printf 'PASS quota-window-smoke.sh still passes\n'
env -u AUTOMETTA_HOME "$script_dir/budget-cap-smoke.sh" >/dev/null
printf 'PASS budget-cap-smoke.sh still passes\n'

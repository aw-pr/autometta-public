#!/usr/bin/env bash
# reserve-schedule-smoke.sh: an overnight reserve schedule is a percentage,
# not a curfew. Card 135. Offline, injected clock, no token spend.
#
# The defect it pins: card 124 made one block, window_reserve.overnight, do
# two unrelated jobs. quota_reserve_settings reads its start/end to pick the
# reserve percentage for the current moment, and quota_schedule_permits_dispatch
# reads the same start/end as a hard window outside which no new worker is
# dispatched at all. An operator who declares the block to say "no reserve
# after 01:00" has, without any key saying so, also declared "no dispatch
# before 01:00". That stopped emergence-lab's 82-86 run dead at 21:01 on
# 2026-09-07 (docs/runs/2026-09-07-stages-82-86-watch.md in that repo).
#
# After this card the curfew is its own opt-in key, overnight.stop_outside.
# Without it the block only moves the percentage; with it, today's stop.
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
assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "$3: unexpectedly found $2"
}

export AUTOMETTA_HOME="$fixture/controller"
mkdir -p "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_HOME/log"

# The operator's actual 2026-09-07 intent: hold a 20% reserve by day, spend
# freely between 22:00 and 01:00. Nothing here asks for a curfew.
reserve_only="$fixture/reserve-only.yaml"
cat > "$reserve_only" <<'YAML'
window_reserve:
  percent: 20
  action: hold
  overnight:
    start: "22:00"
    end: "01:00"
    percent: 0
  timezone: local
YAML

# The same schedule with the stop asked for explicitly: card 124's behaviour,
# now opt-in.
curfew="$fixture/curfew.yaml"
cat > "$curfew" <<'YAML'
window_reserve:
  percent: 20
  action: hold
  overnight:
    start: "22:00"
    end: "01:00"
    percent: 0
    stop_outside: true
  timezone: local
YAML

repo="$fixture/repo"
mkdir -p "$repo/state"
git -C "$fixture" init -q -b dev repo
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages:
  - id: pending-stage
    status: pending
    worker: "GPT-6 Astra <gpt-6-astra@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
YAML
cat > "$repo/state/budget.json" <<'JSON'
{"paused_until":null,"paused_reason":null}
JSON

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

unknown_reading() {
  jq -nc '{read_at:null,families:{claude:{family:"claude",status:"unknown",reason:"snapshot absent",source:null,fetched_at:null,windows:[]},codex:{family:"codex",status:"unknown",reason:"no rollout files",source:null,fetched_at:null,windows:[]}}}'
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/135-an-overnight-reserve-is-a-percentage-not-a-curfew.md

# --- Acceptance 1: the percentage half is untouched. The reserve-only
# mandate resolves exactly as card 124 specified, at every clock.
check_resolved() {
  local clock="$1" want_percent="$2" want_window="$3" out
  out="$(AUTOMETTA_SCHEDULE_CLOCK="$clock" quota_reserve_settings "$reserve_only")"
  assert_eq "$want_percent" "$(cut -f1 <<<"$out")" "reserve at $clock"
  assert_eq "$want_window" "$(cut -f3 <<<"$out")" "window at $clock"
}
check_resolved 14:00 20 daytime
check_resolved 23:00 0 overnight
check_resolved 00:30 0 overnight
check_resolved 01:30 20 daytime
printf 'PASS acceptance 1: the schedule still moves the percentage per the clock\n'

# --- Acceptance 2: an overnight block without stop_outside never refuses a
# dispatch. 09:00 is the hour the old code refused; 23:00 is inside the
# window and must be permitted either way.
for clock in 09:00 14:00 23:00 00:30 01:30; do
  rc=0
  AUTOMETTA_SCHEDULE_CLOCK="$clock" quota_schedule_permits_dispatch "$reserve_only" "$repo" || rc=$?
  assert_eq 0 "$rc" "reserve-only schedule permits dispatch at $clock"
done
assert_contains "$QUOTA_SCHEDULE_STOP_REASON" "no curfew declared" "the permit reason says why: no curfew"
printf 'PASS acceptance 2: a reserve schedule alone never stops new dispatch\n'

# --- Acceptance 3: the curfew is still available, and only when asked for.
curfew_rc=0
AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_schedule_permits_dispatch "$curfew" "$repo" || curfew_rc=$?
assert_eq 1 "$curfew_rc" "stop_outside: true refuses outside the window"
assert_contains "$QUOTA_SCHEDULE_STOP_REASON" "22:00-01:00" "the refusal names the window"
assert_contains "$QUOTA_SCHEDULE_STOP_REASON" "stop_outside" "the refusal names the key that armed it"
inside_rc=0
AUTOMETTA_SCHEDULE_CLOCK=23:00 quota_schedule_permits_dispatch "$curfew" "$repo" || inside_rc=$?
assert_eq 0 "$inside_rc" "stop_outside: true permits inside the window"
printf 'PASS acceptance 3: the curfew exists only as an explicit opt-in\n'

# --- Acceptance 4: through the role gate, with the reserve-only mandate in
# the controller home, a worker dispatches at 09:00 on an unknown reading
# and the tick log says which rule resolved and that no curfew is armed.
cp "$reserve_only" "$AUTOMETTA_HOME/phat-controller-mandate.yaml"
AUTOMETTA_QUOTA_TICK_JSON="$(unknown_reading)"
export AUTOMETTA_QUOTA_TICK_JSON
gate_rc=0
AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  pending-stage worker || gate_rc=$?
assert_eq 0 "$gate_rc" "role gate dispatches a worker at 09:00 under a reserve-only schedule"
assert_eq null "$(jq -r '.paused_until' "$repo/state/budget.json")" "no pause recorded"
tick_log="$(cat "$AUTOMETTA_HOME/log/tick-$(date +%F).log")"
assert_not_contains "$tick_log" "schedule stop worker pending-stage" "no schedule stop was logged"
assert_contains "$tick_log" "curfew off" "the log names the curfew state"
assert_contains "$tick_log" "daytime" "the log names the resolved rule"
printf 'PASS acceptance 4: the role gate dispatches by day and the log says why\n'

# --- Acceptance 5: an unconfigured mandate is byte-for-byte as before, and
# the curfew key is not read from anywhere but the overnight block.
plain="$fixture/plain.yaml"
printf 'window_reserve:\n  percent: 12\n  action: hold\n  stop_outside: true\n' > "$plain"
plain_out="$(quota_reserve_settings "$plain")"
assert_eq "$(printf '12\thold')" "$plain_out" "no overnight block resolves as today"
plain_rc=0
AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_schedule_permits_dispatch "$plain" "$repo" || plain_rc=$?
assert_eq 0 "$plain_rc" "a top-level stop_outside with no window is inert"
printf 'PASS acceptance 5: no window declared means no curfew, whatever else the mandate says\n'

# AUTOMETTA-CONTRACT-END

# Cover malformed opt-ins and a misplaced key even when a window exists.
variant="$fixture/variant.yaml"
for value in false null 1 '"true"' '"yes"' '[]' '{}'; do
  yq ".window_reserve.overnight.stop_outside = $value" "$reserve_only" > "$variant"
  rc=0
  AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_schedule_permits_dispatch "$variant" "$repo" || rc=$?
  assert_eq 0 "$rc" "non-boolean opt-in $value permits dispatch"
  assert_contains "$QUOTA_SCHEDULE_STOP_REASON" "no curfew declared" "non-boolean opt-in reason"
done
yq '.window_reserve.stop_outside = true | .stop_outside = true' "$reserve_only" > "$variant"
AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_schedule_permits_dispatch "$variant" "$repo" \
  || fail 'misplaced stop_outside with a valid window must be ignored'
for field in start end; do
  for value in '"24:00"' '"29:00"' '"22:60"' '"9:00"' null; do
    yq ".window_reserve.overnight.$field = $value" "$curfew" > "$variant"
    AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_schedule_permits_dispatch "$variant" "$repo" \
      || fail "invalid $field $value must not arm a curfew"
    assert_contains "$QUOTA_SCHEDULE_STOP_REASON" "no curfew declared" "invalid boundary reason"
  done
done
quota_schedule_permits_dispatch "$fixture/missing.yaml" "$repo" \
  || fail 'missing mandate must permit dispatch'
assert_contains "$QUOTA_SCHEDULE_STOP_REASON" "no curfew declared" "missing mandate reason"
printf 'PASS opt-in validation: only boolean true with valid nested boundaries arms a curfew\n'

# Exercise the actual drain command on both sides of the same window end.
now_14="$(python3 -c 'import datetime as dt; print(int(dt.datetime.now().replace(hour=14, minute=0, second=0, microsecond=0).timestamp()))')"
AUTOMETTA_DRAIN_NOW_EPOCH="$now_14" "$script_dir/drain.sh" start \
  --cap 999999999 --hours 12 --ignore-reserve > "$fixture/drain.log" 2>&1 \
  || fail "reserve-only drain may outlive the window: $(cat "$fixture/drain.log")"
assert_eq true "$(jq -r '.ignore_reserve' "$AUTOMETTA_HOME/drain.json")" "drain persists reserve override"
"$script_dir/drain.sh" end >/dev/null
cp "$curfew" "$AUTOMETTA_HOME/phat-controller-mandate.yaml"
rc=0
AUTOMETTA_DRAIN_NOW_EPOCH="$now_14" "$script_dir/drain.sh" start \
  --cap 999999999 --hours 12 --ignore-reserve > "$fixture/drain.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "curfew drain must not outlive the window"
assert_contains "$(cat "$fixture/drain.log")" "stop_outside" "drain refusal names the opt-in"
printf 'PASS drain window: only an armed curfew limits the reserve override to the window end\n'

rc=0
AUTOMETTA_SCHEDULE_CLOCK=09:00 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  pending-stage worker || rc=$?
assert_eq 1 "$rc" "armed curfew stops worker before the unknown reading"
tick_log="$(tail -n 1 "$AUTOMETTA_HOME/log/tick-$(date +%F).log")"
assert_contains "$tick_log" "daytime" "stopped dispatch logs resolved rule"
assert_contains "$tick_log" "curfew on 22:00-01:00" "stopped dispatch logs armed curfew"
AUTOMETTA_SCHEDULE_CLOCK=23:00 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  pending-stage worker || fail 'worker inside curfew must dispatch with reserve zero'
printf 'PASS curfew logging: stopped and permitted workers resolve the rule and curfew\n'

printf 'PASS reserve-schedule-smoke: an overnight reserve is a percentage, not a curfew\n'

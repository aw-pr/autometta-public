#!/usr/bin/env bash
# Shared quota-window read and dispatch gate. The reader owns no credential and
# makes no network request. Claude is a sanitised file contract; Codex is local
# rollout evidence. Call quota_refresh_tick once, then pass its result onward.

quota_window_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# budget.sh is optional here: quota_reserve_settings only consults it (via
# quota_drain_ignore_reserve_active, guarded by `command -v budget_drain_
# active`) to honour an active --ignore-reserve drain. Sourcing it directly,
# rather than requiring every caller to source budget.sh first, keeps this
# file usable standalone.
# shellcheck source=./budget.sh
source "$quota_window_script_dir/budget.sh"

# quota_drain_ignore_reserve_active <repo-root>: succeed (0) when the drain
# in force for this repo (if any) was opened with --ignore-reserve and has
# not expired. Reuses budget_drain_active's expiry-and-scope handling
# (unmodified, out of this card's path claims) rather than re-deriving it;
# this only reads the one extra field drain.sh now writes alongside it.
quota_drain_ignore_reserve_active() {
  local repo_root="${1:-}"
  command -v budget_drain_active >/dev/null 2>&1 || return 1
  budget_drain_active "$repo_root" >/dev/null 2>&1 || return 1
  local drain_path
  drain_path="$(budget_drain_file)"
  [[ -f "$drain_path" ]] || return 1
  [[ "$(jq -r '.ignore_reserve // false' "$drain_path" 2>/dev/null)" == "true" ]]
}

# The legacy reserve is on unless the operator switches it off. Twenty
# percent unspent stops new work at 80% used, leaving room for active work.
# Codex defaults to card admission below 100% instead. An operator turns it off with an
# explicit window_reserve.percent: 0 or action: off in the mandate; an
# unanswered or invalid value is not an answer and takes the default.
# The default needs a mandate file to be unanswered in: init-host installs
# the template, so an initialised host is on. A host with no mandate at all
# (a fixture controller home in a smoke, a tick run before init-host) is off,
# and the tick log names the missing file at every dispatch.
QUOTA_RESERVE_DEFAULT_PERCENT=20
QUOTA_RESERVE_DEFAULT_ACTION=hold

AUTOMETTA_QUOTA_TICK_JSON=""
QUOTA_GATE_WINDOW=""
QUOTA_GATE_RESET=""
QUOTA_GATE_REASON=""
# QUOTA_RESERVE_WINDOW: which rule quota_reserve_settings resolved under --
# default (no schedule declared), daytime, overnight, or drain-ignore-reserve.
# Set as a side channel (same convention as QUOTA_GATE_WINDOW above) so the
# 2-column percent/action stdout stays byte-for-byte identical to before this
# card for an unconfigured mandate, while the caller can still log the rule.
QUOTA_RESERVE_WINDOW=""

quota_refresh_tick() {
  local script_dir_q
  script_dir_q="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  AUTOMETTA_QUOTA_TICK_JSON="$(python3 "$script_dir_q/quota-window.py" all 2>/dev/null || true)"
  if ! printf '%s' "$AUTOMETTA_QUOTA_TICK_JSON" | jq -e '
    .families.claude.status and .families.codex.status
  ' >/dev/null 2>&1; then
    AUTOMETTA_QUOTA_TICK_JSON='{"read_at":null,"families":{"claude":{"family":"claude","status":"unknown","reason":"reader failed","source":null,"fetched_at":null,"windows":[]},"codex":{"family":"codex","status":"unknown","reason":"reader failed","source":null,"fetched_at":null,"windows":[]}}}'
    return 1
  fi
  return 0
}

quota_write_repo_state() {
  local repo_root="$1" tmp_path="$1/state/quota-window.json.tmp.$$"
  [[ -n "$AUTOMETTA_QUOTA_TICK_JSON" ]] || quota_refresh_tick || true
  mkdir -p "$repo_root/state"
  printf '%s\n' "$AUTOMETTA_QUOTA_TICK_JSON" > "$tmp_path"
  mv "$tmp_path" "$repo_root/state/quota-window.json"
}


# quota_schedule_now_hm: local wall-clock "HH:MM", the clock the overnight
# schedule is read against. Local, not UTC: the window describes when a
# person is asleep, and a person's sleep does not move with UTC. Across a
# DST change the wall-clock boundaries ("22:00", "01:00") do not shift, but
# the window's real duration does -- one nominal 3-hour overnight window is
# 2 or 4 hours on the two transition nights a year. Accepted: see
# docs/tick-loop.md.
#
# AUTOMETTA_SCHEDULE_CLOCK overrides the read for tests ("HH:MM"); this is
# the injectable clock scripts/session-window-smoke.sh drives.
quota_schedule_now_hm() {
  if [[ -n "${AUTOMETTA_SCHEDULE_CLOCK:-}" ]]; then
    printf '%s\n' "$AUTOMETTA_SCHEDULE_CLOCK"
    return 0
  fi
  date +%H:%M
}

_quota_hm_to_minutes() {
  local hm="$1" h m
  IFS=: read -r h m <<<"$hm"
  h=$((10#$h)); m=$((10#$m))
  printf '%s\n' "$((h * 60 + m))"
}

# quota_time_in_window <now-hm> <start-hm> <end-hm>: true (0) when now falls
# in [start, end). A window whose end is less than its start crosses
# midnight and is handled as one interval (now >= start OR now < end), not
# as two separate comparisons -- the obvious start<=now<end test is silently
# wrong for a window that wraps, since it never matches at all.
quota_time_in_window() {
  local now start end
  now="$(_quota_hm_to_minutes "$1")"
  start="$(_quota_hm_to_minutes "$2")"
  end="$(_quota_hm_to_minutes "$3")"
  if (( start <= end )); then
    (( now >= start && now < end ))
  else
    (( now >= start || now < end ))
  fi
}

# quota_schedule_next_overnight_end_epoch <mandate-path> [now-epoch]: the
# epoch second of the next occurrence of window_reserve.overnight.end in
# local time, or nothing (rc 1) when no schedule is declared. Used by
# drain.sh to refuse a --ignore-reserve drain that would outlive the window
# that permits it.
quota_schedule_next_overnight_end_epoch() {
  local mandate_path="$1"
  local now_epoch="${2:-$(date +%s)}"
  [[ -f "$mandate_path" ]] && command -v yq >/dev/null 2>&1 || return 1
  local ov_end
  ov_end="$(yq -r '.window_reserve.overnight.end // ""' "$mandate_path" 2>/dev/null || true)"
  [[ "$ov_end" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || return 1
  python3 - "$ov_end" "$now_epoch" <<'PY'
import datetime as dt
import sys

end_hm, now_epoch = sys.argv[1], sys.argv[2]
now = dt.datetime.fromtimestamp(int(now_epoch))
eh, em = (int(x) for x in end_hm.split(":"))
end_today = now.replace(hour=eh, minute=em, second=0, microsecond=0)
end = end_today if now < end_today else end_today + dt.timedelta(days=1)
print(int(end.timestamp()))
PY
}

# quota_reserve_settings <mandate-path> [repo-root]
#
# Resolves window_reserve for the current moment rather than returning one
# static pair. Precedence, first hit wins:
#
#   1. an active --ignore-reserve drain (repo-root scoped, budget.sh's
#      concern; consulted only if budget.sh is on hand) -- reserve off for
#      the life of that drain and no longer.
#   2. window_reserve.overnight, when declared, resolved against the local
#      clock (quota_schedule_now_hm) -- overnight.percent inside the window,
#      the top-level percent/action outside it.
#   3. the top-level percent/action, unconditionally -- today's only mode.
#
# stdout is "percent\taction\n" for an unconfigured mandate (no overnight
# block, no active drain) -- byte-for-byte what it printed before this card
# -- and "percent\taction\twindow\n" the moment either is in play, naming
# the rule that resolved it (daytime|overnight|drain-ignore-reserve) so the
# caller can log it. The window name travels on stdout rather than in the
# QUOTA_RESERVE_WINDOW global below: every caller reads this function's
# result through a $(...) command substitution, which runs in a subshell,
# and a global set only inside that subshell never reaches the caller.
# QUOTA_RESERVE_WINDOW is set anyway for a same-process caller that invokes
# this directly (no substitution), but stdout is the contract. repo-root is
# optional; omitting it just skips the drain check (rule 1).
quota_reserve_settings() {
  local mandate_path="$1"
  local repo_root="${2:-}"
  QUOTA_RESERVE_WINDOW="default"

  if [[ -n "$repo_root" ]] && quota_drain_ignore_reserve_active "$repo_root"; then
    QUOTA_RESERVE_WINDOW="drain-ignore-reserve"
    printf '0\toff\t%s\n' "$QUOTA_RESERVE_WINDOW"
    return 0
  fi

  if [[ ! -f "$mandate_path" ]] || ! command -v yq >/dev/null 2>&1; then
    printf '0\toff\n'
    return 0
  fi
  local percent action
  percent="$(yq -r '.window_reserve.percent // ""' "$mandate_path" 2>/dev/null || true)"
  action="$(yq -r '.window_reserve.action // ""' "$mandate_path" 2>/dev/null || true)"
  # Only an explicit, valid zero (or action: off) switches the reserve off.
  # Empty is the template's unanswered state and anything unparseable is a
  # typo; neither is a decision to spend the window down, so both take the
  # default rather than silently disarming the guard.
  if [[ -z "$percent" ]] || ! [[ "$percent" =~ ^[0-9]+([.][0-9]+)?$ ]] \
     || ! awk -v value="$percent" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
    percent="$QUOTA_RESERVE_DEFAULT_PERCENT"
  fi
  case "$action" in hold|observe|off) ;; *) action="$QUOTA_RESERVE_DEFAULT_ACTION" ;; esac

  local ov_start ov_end
  ov_start="$(yq -r '.window_reserve.overnight.start // ""' "$mandate_path" 2>/dev/null || true)"
  ov_end="$(yq -r '.window_reserve.overnight.end // ""' "$mandate_path" 2>/dev/null || true)"
  if [[ -z "$ov_start" || -z "$ov_end" \
        || ! "$ov_start" =~ ^[0-2][0-9]:[0-5][0-9]$ || ! "$ov_end" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
    printf '%s\t%s\n' "$percent" "$action"
    return 0
  fi

  local ov_percent now_hm
  ov_percent="$(yq -r '.window_reserve.overnight.percent // 0' "$mandate_path" 2>/dev/null || printf 0)"
  if ! [[ "$ov_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] \
     || ! awk -v value="$ov_percent" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
    ov_percent=0
  fi
  now_hm="$(quota_schedule_now_hm)"
  if quota_time_in_window "$now_hm" "$ov_start" "$ov_end"; then
    percent="$ov_percent"
    QUOTA_RESERVE_WINDOW="overnight"
  else
    QUOTA_RESERVE_WINDOW="daytime"
  fi
  printf '%s\t%s\t%s\n' "$percent" "$action" "$QUOTA_RESERVE_WINDOW"
}

# The legacy reserve remains available for an explicitly chosen policy.
quota_codex_card_policy() {
  [[ "${AUTOMETTA_CODEX_QUOTA_POLICY:-card}" != "reserve" ]]
}

quota_codex_role_uses_subscription() {
  local repo_root="$1" identity="$2" role="$3" mode
  [[ "$identity" == *Codex* || "$identity" == *GPT* ]] || return 1
  mode="$(REPO_ROOT="$repo_root" "$quota_window_script_dir/auth-route.sh" codex --print-mode --role "$role" 2>/dev/null)" || return 0
  [[ "$mode" == subscription ]]
}

# quota_codex_admit_percent: window_reserve.codex_admit_percent from the
# controller mandate, the used percentage at which no new Codex card starts.
# Empty when unset, so the reader keeps its 100% default.
quota_codex_admit_percent() {
  local mandate_path
  mandate_path="${AUTOMETTA_CONTROLLER_MANDATE:-$(autometta_controller_home)/phat-controller-mandate.yaml}"
  [[ -f "$mandate_path" ]] || return 0
  yq -r '.window_reserve.codex_admit_percent // ""' "$mandate_path" 2>/dev/null || true
}

quota_gate_codex_reading() {
  local result
  QUOTA_GATE_WINDOW=""; QUOTA_GATE_RESET=""; QUOTA_GATE_REASON=""
  result="$(printf '%s' "$1" | AUTOMETTA_CODEX_ADMIT_PERCENT="$(quota_codex_admit_percent)" python3 "$quota_window_script_dir/quota-window.py" codex-admission)" || {
    QUOTA_GATE_REASON="Codex quota admission reader failed"
    return 1
  }
  QUOTA_GATE_REASON="$(printf '%s' "$result" | jq -r '.reason')"
  QUOTA_GATE_WINDOW="$(printf '%s' "$result" | jq -r '.window')"
  QUOTA_GATE_RESET="$(printf '%s' "$result" | jq -r '.reset // empty')"
  [[ "$(printf '%s' "$result" | jq -r '.allowed')" == true ]]
}

# quota_spawn_permits <repo-root> claude|codex [card-path]
#
# The reserve check for a spawn that did not come through the tick: an
# orchestrator at a prompt running scripts/spawn-worker.sh by hand. Same
# reading and same rule as the tick's quota_gate_family_dispatch, but pure:
# it pauses nothing and writes nothing, because the caller is a person who
# will read the refusal, not a loop that must remember to resume. Returns 1
# with QUOTA_GATE_REASON when a known window of this family is inside a hold
# reserve, 0 otherwise, including every unknown reading (fail-open, as the
# tick). Two escapes, both explicit and both named in the log line:
#   AUTOMETTA_IGNORE_RESERVE=1  the operator means to spend the window.
#   AUTOMETTA_RESERVE_GATED=1   set by tick.sh on its own spawn calls, which
#                               have already passed the gate this tick and
#                               would otherwise halt the repo with a
#                               dispatch-configuration-fault on a refusal.
quota_spawn_permits() {
  local repo_root="$1" family="$2" card_path="${3:-}"
  QUOTA_GATE_REASON=""
  if [[ "${AUTOMETTA_RESERVE_GATED:-}" == "1" ]]; then
    QUOTA_GATE_REASON="reserve already applied by the tick"
    return 0
  fi
  if quota_codex_card_policy; then
    local worker_id verifier_id uses_codex=false
    if [[ -n "$card_path" ]]; then
      worker_id="$(sed -n 's/^- \*\*Worker:\*\* //p' "$card_path" | head -n1)"
      verifier_id="$(sed -n 's/^- \*\*Verifier:\*\* //p' "$card_path" | head -n1)"
      if quota_codex_role_uses_subscription "$repo_root" "$worker_id" worker || quota_codex_role_uses_subscription "$repo_root" "$verifier_id" verifier; then
        uses_codex=true
      fi
    elif [[ "$family" == codex ]]; then
      uses_codex=true
    fi
    if [[ "$uses_codex" == true ]]; then
      [[ -n "$AUTOMETTA_QUOTA_TICK_JSON" ]] || quota_refresh_tick || true
      local codex_reading
      codex_reading="$(printf '%s' "$AUTOMETTA_QUOTA_TICK_JSON" | jq -c '.families.codex')"
      quota_gate_codex_reading "$codex_reading" || return 1
    fi
    [[ "$family" != codex ]] || return 0
  fi
  if [[ "${AUTOMETTA_IGNORE_RESERVE:-}" == "1" ]]; then
    QUOTA_GATE_REASON="AUTOMETTA_IGNORE_RESERVE=1"
    return 0
  fi
  case "$family" in claude|codex) ;; *)
    QUOTA_GATE_REASON="family unknown"
    return 0
  esac
  local mandate_path settings reserve action window reading
  mandate_path="${AUTOMETTA_CONTROLLER_MANDATE:-$(autometta_controller_home)/phat-controller-mandate.yaml}"
  settings="$(quota_reserve_settings "$mandate_path" "$repo_root")"
  IFS=$'\t' read -r reserve action window <<<"$settings"
  [[ -n "$AUTOMETTA_QUOTA_TICK_JSON" ]] || quota_refresh_tick || true
  reading="$(printf '%s' "$AUTOMETTA_QUOTA_TICK_JSON" | jq -c --arg family "$family" '.families[$family]' 2>/dev/null || printf '{}')"
  if quota_gate_reading "$reading" "$reserve" "$action"; then
    return 0
  fi
  QUOTA_GATE_REASON="${QUOTA_GATE_REASON} (${window:-default} schedule); resets $(date -u -r "$QUOTA_GATE_RESET" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$QUOTA_GATE_RESET")"
  return 1
}

QUOTA_SCHEDULE_STOP_REASON=""

# quota_schedule_curfew_window <mandate-path>: print start-end only for an
# explicitly armed curfew with valid local wall-clock boundaries.
quota_schedule_curfew_window() {
  local mandate_path="$1" ov_start ov_end
  [[ -f "$mandate_path" ]] && command -v yq >/dev/null 2>&1 || return 1
  [[ "$(yq -r '.window_reserve.overnight.stop_outside | tag' "$mandate_path" 2>/dev/null)" == "!!bool" ]] || return 1
  [[ "$(yq -r '.window_reserve.overnight.stop_outside' "$mandate_path" 2>/dev/null)" == "true" ]] || return 1
  ov_start="$(yq -r '.window_reserve.overnight.start // ""' "$mandate_path" 2>/dev/null || true)"
  ov_end="$(yq -r '.window_reserve.overnight.end // ""' "$mandate_path" 2>/dev/null || true)"
  [[ "$ov_start" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && "$ov_end" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
  printf '%s-%s\n' "$ov_start" "$ov_end"
}

# quota_schedule_permits_dispatch <mandate-path> [repo-root]
#
# Returns 0 when a *new* worker dispatch is permitted at this moment,
# 1 when an explicit overnight.stop_outside curfew refuses it, with
# QUOTA_SCHEDULE_STOP_REASON carrying the reason the caller logs.
#
# This deliberately does not read the quota. The reserve below is a
# reading-driven hold: it binds only when a known window is near exhaustion,
# and every unknown reading fails open. That is right for a guard against
# spending the last of a window and useless as a stop, because the case the
# stop exists for -- an overnight run that must not still be dispatching at
# nine the next morning -- is exactly the case where the reading is healthy
# (the window reset in the night) or unknown (no snapshot). A stop built on
# the reading fails open precisely when it is needed, which leaves the
# operator no session and no alarm saying why.
#
# Precedence, first hit wins:
#   1. no valid curfew declared -- permitted; the schedule only selects a
#      reserve percentage unless overnight.stop_outside is boolean true.
#   2. an active --ignore-reserve drain -- permitted. Burning the daytime
#      session is opt-in and self-expiring (deliverable 4).
#   3. inside the declared window -- permitted.
#   4. otherwise -- refused.
#
# Only new worker dispatch reaches this. An in-flight stage is never killed
# by the stop: its verifier runs under the reserve_exempt path in tick.sh, so
# work already claimed still reaps and lands after the window closes.
quota_schedule_permits_dispatch() {
  local mandate_path="$1" repo_root="${2:-}"
  QUOTA_SCHEDULE_STOP_REASON="no curfew declared"

  local curfew ov_start ov_end
  curfew="$(quota_schedule_curfew_window "$mandate_path")" || return 0
  ov_start="${curfew%-*}"
  ov_end="${curfew#*-}"

  if [[ -n "$repo_root" ]] && quota_drain_ignore_reserve_active "$repo_root"; then
    QUOTA_SCHEDULE_STOP_REASON="--ignore-reserve drain in force"
    return 0
  fi

  local now_hm
  now_hm="$(quota_schedule_now_hm)"
  if quota_time_in_window "$now_hm" "$ov_start" "$ov_end"; then
    QUOTA_SCHEDULE_STOP_REASON="clock ${now_hm} is inside the ${ov_start}-${ov_end} dispatch window"
    return 0
  fi
  QUOTA_SCHEDULE_STOP_REASON="clock ${now_hm} is outside the ${ov_start}-${ov_end} dispatch window (overnight.stop_outside: true); it next opens at ${ov_start}"
  return 1
}

# quota_gate_reading <reading-json> <reserve-percent> <action>
# Returns 1 only when a known window is inside a non-zero hold reserve and has
# a future reset. Unknown, zero and observe all fail open with an explicit
# QUOTA_GATE_REASON. The caller owns budget_pause_until and logging.
quota_gate_reading() {
  local reading="$1" reserve="$2" action="$3" now
  QUOTA_GATE_WINDOW=""; QUOTA_GATE_RESET=""; QUOTA_GATE_REASON=""
  if awk -v r="$reserve" 'BEGIN { exit !(r <= 0) }'; then
    QUOTA_GATE_REASON="reserve off"
    return 0
  fi
  local status reason
  status="$(printf '%s' "$reading" | jq -r '.status // "unknown"' 2>/dev/null || printf unknown)"
  if [[ "$status" != "known" ]]; then
    reason="$(printf '%s' "$reading" | jq -r '.reason // "reading unknown"' 2>/dev/null || printf 'reading unknown')"
    QUOTA_GATE_REASON="reading unknown: $reason"
    return 0
  fi
  local binding
  binding="$(printf '%s' "$reading" | jq -c --argjson reserve "$reserve" '
    [.windows[]? | select((.utilization | type) == "number")
      | . + {remaining:(100 - .utilization)}
      | select(.remaining <= $reserve)]
    | sort_by(-.utilization) | .[0] // empty
  ' 2>/dev/null || true)"
  if [[ -z "$binding" ]]; then
    QUOTA_GATE_REASON="outside reserve"
    return 0
  fi
  QUOTA_GATE_WINDOW="$(printf '%s' "$binding" | jq -r '.label')"
  QUOTA_GATE_RESET="$(printf '%s' "$binding" | jq -r '.resets_at // empty')"
  if [[ "$action" != "hold" ]]; then
    QUOTA_GATE_REASON="${QUOTA_GATE_WINDOW} inside reserve; action ${action} does not hold"
    return 0
  fi
  if [[ -z "$QUOTA_GATE_RESET" ]]; then
    QUOTA_GATE_REASON="${QUOTA_GATE_WINDOW} inside reserve but reset is unknown"
    return 0
  fi
  now="$(date -u +%s)"
  local reset_epoch
  reset_epoch="$(python3 - "$QUOTA_GATE_RESET" <<'PY'
from datetime import datetime
import sys
try:
    print(int(datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))
except ValueError:
    pass
PY
)"
  if [[ ! "$reset_epoch" =~ ^[0-9]+$ || "$reset_epoch" -le "$now" ]]; then
    QUOTA_GATE_REASON="${QUOTA_GATE_WINDOW} inside reserve but reset is not in the future"
    return 0
  fi
  QUOTA_GATE_RESET="$reset_epoch"
  # Read by tick.sh after this function returns.
  # shellcheck disable=SC2034
  QUOTA_GATE_REASON="${QUOTA_GATE_WINDOW} inside ${reserve}% reserve"
  return 1
}

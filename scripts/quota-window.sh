#!/usr/bin/env bash
# Shared quota-window read and dispatch gate. The reader owns no credential and
# makes no network request. Claude is a sanitised file contract; Codex is local
# rollout evidence. Call quota_refresh_tick once, then pass its result onward.

AUTOMETTA_QUOTA_TICK_JSON=""
QUOTA_GATE_WINDOW=""
QUOTA_GATE_RESET=""
QUOTA_GATE_REASON=""

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

quota_reserve_settings() {
  local mandate_path="$1"
  if [[ ! -f "$mandate_path" ]] || ! command -v yq >/dev/null 2>&1; then
    printf '0\toff\n'
    return 0
  fi
  local percent action
  percent="$(yq -r '.window_reserve.percent // 0' "$mandate_path" 2>/dev/null || printf 0)"
  action="$(yq -r '.window_reserve.action // "off"' "$mandate_path" 2>/dev/null || printf off)"
  if ! [[ "$percent" =~ ^[0-9]+([.][0-9]+)?$ ]] \
     || ! awk -v value="$percent" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
    percent=0
    action=off
  fi
  case "$action" in hold|observe|off) ;; *) action=off ;; esac
  printf '%s\t%s\n' "$percent" "$action"
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

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Drain mode: the deliberate overnight run, as opposed to the daily cap.
#
# The daily token cap exists to catch a runaway. An overnight drain is the
# opposite intent -- spend the provider window down on purpose and stop when
# the *provider* stops, around 01:00 -- and on 2026-08-23 the two were the
# same number. emergence-lab spent 104,942,068 against its 100,000,000 cap,
# the gate refused a verifier dispatch at 00:01 with a finished worker
# sitting on a passing envelope, and the run only resumed when the midnight
# window reset zeroed the counter an hour later. The cap was right; it was
# describing the wrong intent.
#
# A drain is host-level, per run, and self-expiring. It never edits any
# repo's budget.json, so there is nothing to remember to put back.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"
# shellcheck source=./quota-window.sh
# Sourced only for quota_schedule_next_overnight_end_epoch, the one read
# --ignore-reserve needs to refuse a --hours that would outlive the
# overnight window. Token-cap logic stays exactly what it was; this drain
# learns nothing new about caps.
source "$script_dir/quota-window.sh"

usage() {
  cat <<'USAGE' >&2
Usage:
  drain.sh start [--cap N | --lift] [--hours H] [--repo PATH]... [--reason TEXT] [--ignore-reserve]
  drain.sh status
  drain.sh end

  start   open a drain. Default 8 hours, maximum 12 (AUTOMETTA_DRAIN_MAX_SECONDS).
          --cap N            raise the token cap to N for the duration
          --lift              raise it to the lift ceiling (AUTOMETTA_DRAIN_LIFT_CAP)
          --repo              limit the drain to one repo; repeatable. Default: all.
          --ignore-reserve    suspend the window_reserve hold for the life of this
                              drain and no longer. When a schedule (window_reserve.
                              overnight) is declared, a --hours that would still be
                              running past the window's end is refused at start.
  status  print the drain in force, if any, and when it expires.
  end     close the drain now rather than waiting for it to expire.
USAGE
  exit 1
}

drain_path="$(budget_drain_file)"

fmt_epoch() {
  date -r "$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || printf '%s' "$1"
}

cmd_status() {
  if [[ ! -f "$drain_path" ]]; then
    printf 'drain: none in force (resting caps apply)\n'
    if [[ -f "${drain_path%.json}.expired.json" ]]; then
      printf 'drain: last drain expired at %s\n' \
        "$(fmt_epoch "$(jq -r '.expires_at // 0' "${drain_path%.json}.expired.json")")"
    fi
    return 0
  fi
  local expires now cap reason repos
  expires="$(jq -r '.expires_at // 0' "$drain_path")"
  now="$(date -u +%s)"
  cap="$(jq -r '.token_cap_total // 0' "$drain_path")"
  reason="$(jq -r '.reason // "unstated"' "$drain_path")"
  repos="$(jq -r 'if ((.repos // []) | length) == 0 then "all subscribers" else (.repos | join(", ")) end' "$drain_path")"
  if (( now >= expires )); then
    printf 'drain: expired at %s, next read will retire it\n' "$(fmt_epoch "$expires")"
    return 0
  fi
  printf 'drain: ACTIVE cap %s until %s (%s minutes left)\n' \
    "$cap" "$(fmt_epoch "$expires")" "$(( (expires - now) / 60 ))"
  printf 'drain: scope %s\n' "$repos"
  printf 'drain: reason %s\n' "$reason"
  if [[ "$(jq -r '.ignore_reserve // false' "$drain_path")" == "true" ]]; then
    printf 'drain: ignore-reserve ACTIVE, window_reserve hold suspended until this drain ends\n'
  fi
}

cmd_end() {
  if [[ ! -f "$drain_path" ]]; then
    printf 'drain: none in force, nothing to end\n'
    return 0
  fi
  mv "$drain_path" "${drain_path%.json}.expired.json"
  printf 'PASS drain ended, resting caps apply\n'
}

cmd_start() {
  local cap="" hours=8 reason="operator drain" repos=() ignore_reserve=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cap) cap="${2:-}"; shift 2 ;;
      --lift) cap="$AUTOMETTA_DRAIN_LIFT_CAP"; shift ;;
      --hours) hours="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      --repo) repos+=("${2:-}"); shift 2 ;;
      --ignore-reserve) ignore_reserve=true; shift ;;
      *) usage ;;
    esac
  done

  if [[ -z "$cap" ]]; then
    printf 'drain: --cap N or --lift is required. A drain with no stated cap is not a decision.\n' >&2
    exit 1
  fi
  if ! [[ "$cap" =~ ^[0-9]+$ ]] || (( cap <= 0 )); then
    printf 'drain: --cap must be a positive integer, got %q\n' "$cap" >&2
    exit 1
  fi
  if ! [[ "$hours" =~ ^[0-9]+$ ]] || (( hours <= 0 )); then
    printf 'drain: --hours must be a positive integer, got %q\n' "$hours" >&2
    exit 1
  fi

  local seconds=$(( hours * 3600 ))
  if (( seconds > AUTOMETTA_DRAIN_MAX_SECONDS )); then
    printf 'drain: %s hours exceeds the maximum of %s hours; a drain that outlives its night is an unlimited cap with extra steps\n' \
      "$hours" "$(( AUTOMETTA_DRAIN_MAX_SECONDS / 3600 ))" >&2
    exit 1
  fi

  local now expires resolved=()
  # AUTOMETTA_DRAIN_NOW_EPOCH: test-only clock override, so the --hours vs.
  # overnight-window-end refusal below is reachable without waiting for a
  # particular hour to run the test in.
  now="${AUTOMETTA_DRAIN_NOW_EPOCH:-$(date -u +%s)}"
  expires=$(( now + seconds ))

  if [[ "$ignore_reserve" == "true" ]]; then
    local mandate_path window_end_epoch
    mandate_path="${AUTOMETTA_CONTROLLER_MANDATE:-$(budget_controller_home)/phat-controller-mandate.yaml}"
    if window_end_epoch="$(quota_schedule_next_overnight_end_epoch "$mandate_path" "$now")" \
       && [[ "$window_end_epoch" =~ ^[0-9]+$ ]] && (( expires > window_end_epoch )); then
      printf 'drain: --ignore-reserve for %s hours would still be running past the overnight window ending %s; refusing. A drain must not outlive the window that permits it.\n' \
        "$hours" "$(fmt_epoch "$window_end_epoch")" >&2
      exit 1
    fi
  fi

  local r
  for r in ${repos+"${repos[@]}"}; do
    if command -v realpath >/dev/null 2>&1; then
      resolved+=("$(realpath "$r")")
    else
      resolved+=("$r")
    fi
  done

  mkdir -p "$(budget_controller_home)"
  local tmp_path repos_json
  tmp_path="${drain_path}.tmp.$$"
  if (( ${#resolved[@]} == 0 )); then
    repos_json='[]'
  else
    repos_json="$(printf '%s\n' "${resolved[@]}" | jq -R . | jq -s .)"
  fi
  jq -n \
    --argjson cap "$cap" \
    --argjson expires "$expires" \
    --argjson repos "$repos_json" \
    --arg started "$(date -u -r "$now" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg reason "$reason" \
    --argjson ignore_reserve "$ignore_reserve" \
    '{version: 1, token_cap_total: $cap, expires_at: $expires, started_at: $started, repos: $repos, reason: $reason, ignore_reserve: $ignore_reserve}' \
    > "$tmp_path"
  json_check "$tmp_path"
  mv "$tmp_path" "$drain_path"
  rm -f "${drain_path%.json}.expired.json"

  printf 'PASS drain started cap %s until %s (%s hours)\n' "$cap" "$(fmt_epoch "$expires")" "$hours"
  printf 'PASS drain scope %s\n' \
    "$(jq -r 'if ((.repos // []) | length) == 0 then "all subscribers" else (.repos | join(", ")) end' "$drain_path")"
  printf 'PASS drain expires by itself; no repo budget.json was modified\n'
  if [[ "$ignore_reserve" == "true" ]]; then
    printf 'PASS drain ignore-reserve: window_reserve hold suspended for the life of this drain and no longer\n'
  fi
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  status) shift || true; cmd_status ;;
  end) shift || true; cmd_end ;;
  *) usage ;;
esac

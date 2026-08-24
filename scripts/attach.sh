#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
controller_home="$(autometta_controller_home)"
subscribers_dir="$controller_home/subscribers"
build_checked_at=0
build_sha="unknown"
installed_sha="unknown"
build_warning=""

refresh_build_status() {
  local now version
  now="$(date +%s)"
  (( now - build_checked_at < 60 )) && return 0
  build_checked_at="$now"
  build_sha="$(git -C "$script_dir/.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
  version="$(autometta --version 2>/dev/null || true)"
  installed_sha="$(printf '%s' "$version" | grep -Eo '[0-9a-f]{7,40}' | head -n1 || true)"
  [[ -n "$installed_sha" ]] || installed_sha=unknown
  [[ "$installed_sha" == unknown ]] || installed_sha="${installed_sha:0:7}"
  build_warning=""
  if [[ "$build_sha" != unknown && "$installed_sha" != unknown && "$build_sha" != "$installed_sha" ]]; then
    build_warning="BUILD DRIFT: installed ${installed_sha}, checkout ${build_sha} (fallback comparison)"
  fi
}

usage() {
  printf 'Usage: %s [repo-path] [--dry-run] [--ensure]\n' "$(basename "$0")" >&2
  printf '       %s --detach [repo-path] | --detach-all | --fleet-ticker | --fleet-refresh\n' "$(basename "$0")" >&2
  exit 1
}

shell_quote() { printf '%q' "$1"; }

resolve_path() {
  local input_path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$input_path"
  else
    python3 - "$input_path" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
  fi
}

read_field() {
  local file_path="$1" key="$2" raw
  raw="$(sed -n "s/^${key}:[[:space:]]*//p" "$file_path" 2>/dev/null | head -n1)"
  raw="${raw%\"}"; raw="${raw#\"}"
  raw="${raw%\'}"; raw="${raw#\'}"
  printf '%s' "$raw"
}

# shellcheck source=./session-slug.sh
source "$script_dir/session-slug.sh"
# shellcheck source=./alert-statuses.sh
source "$script_dir/alert-statuses.sh"
# shellcheck source=./repo-light.sh
source "$script_dir/repo-light.sh"

fleet_columns() {
  # Deprecated for one release: PHAT_CONTROLLER_FLEET_COLUMNS.
  local columns="${AUTOMETTA_FLEET_COLUMNS:-${PHAT_CONTROLLER_FLEET_COLUMNS:-}}"
  if [[ -z "$columns" ]]; then
    columns="$(tput cols 2>/dev/null || printf 80)"
  fi
  [[ "$columns" =~ ^[0-9]+$ ]] || columns=80
  (( columns >= 40 )) || columns=40
  printf '%s' "$columns"
}

fleet_style_init() {
  FLEET_COLUMNS="$(fleet_columns)"
  FLEET_COLOUR=false
  # Deprecated for one release: PHAT_CONTROLLER_FLEET_STYLE.
  local fleet_style="${AUTOMETTA_FLEET_STYLE:-${PHAT_CONTROLLER_FLEET_STYLE:-auto}}"
  if [[ -z "${NO_COLOR:-}" && -z "${NO_COLOUR:-}" && "$fleet_style" != plain ]] \
    && [[ "$fleet_style" == colour || "$(tput colors 2>/dev/null || printf 0)" -ge 8 ]] \
    && [[ "$(locale charmap 2>/dev/null || true)" == *UTF-8* ]]; then
    FLEET_COLOUR=true
  fi
  if "$FLEET_COLOUR"; then
    FLEET_H='─'; FLEET_V='│'; FLEET_TL='┌'; FLEET_TM='┬'; FLEET_TR='┐'
    FLEET_ML='├'; FLEET_MM='┼'; FLEET_MR='┤'; FLEET_BL='└'; FLEET_BM='┴'; FLEET_BR='┘'
    FLEET_ELLIPSIS='…'
    FLEET_RED="$(tput setaf 1)"; FLEET_GREEN="$(tput setaf 2)"; FLEET_YELLOW="$(tput setaf 3)"
    FLEET_BOLD="$(tput bold)"; FLEET_DIM="$(tput dim)"; FLEET_RESET="$(tput sgr0)"
  else
    FLEET_H='-'; FLEET_V='|'; FLEET_TL='+'; FLEET_TM='+'; FLEET_TR='+'
    FLEET_ML='+'; FLEET_MM='+'; FLEET_MR='+'; FLEET_BL='+'; FLEET_BM='+'; FLEET_BR='+'
    FLEET_ELLIPSIS='...'
    FLEET_RED=''; FLEET_GREEN=''; FLEET_YELLOW=''; FLEET_BOLD=''; FLEET_DIM=''; FLEET_RESET=''
  fi
}

repeat_char() {
  local char="$1" count="$2" out=''
  while (( count > 0 )); do out+="$char"; count=$(( count - 1 )); done
  printf '%s' "$out"
}

fit_cell() {
  local value="$1" width="$2" alignment="${3:-left}" ellipsis="$FLEET_ELLIPSIS"
  value="${value//$'\n'/ }"; value="${value//$'\r'/ }"; value="${value//$'\t'/ }"
  if (( ${#value} > width )); then
    if [[ "$ellipsis" == '...' && "$width" -ge 4 ]]; then
      value="${value:0:$(( width - 3 ))}..."
    elif (( width >= 2 )); then
      value="${value:0:$(( width - 1 ))}${ellipsis:0:1}"
    else
      value="${value:0:$width}"
    fi
  fi
  if [[ "$alignment" == right ]]; then
    printf '%*s' "$width" "$value"
  else
    printf '%-*s' "$width" "$value"
  fi
}

table_rule() {
  local left="$1" middle="$2" right="$3" i out
  out="$left"
  for (( i=0; i<${#TABLE_WIDTHS[@]}; i++ )); do
    out+="$(repeat_char "$FLEET_H" "$(( TABLE_WIDTHS[i] + 2 ))")"
    if (( i + 1 < ${#TABLE_WIDTHS[@]} )); then out+="$middle"; else out+="$right"; fi
  done
  printf '%s\n' "$out"
}

row_style_prefix() {
  case "$1" in
    failure|action|red) printf '%s%s' "$FLEET_BOLD" "$FLEET_RED" ;;
    stall|limit|drift|amber) printf '%s%s' "$FLEET_BOLD" "$FLEET_YELLOW" ;;
    running|pass|green) printf '%s' "$FLEET_GREEN" ;;
    quiet) printf '%s' "$FLEET_DIM" ;;
  esac
}

# render_table <title> <tab-separated headers> <tab-separated alignments>
#              <rows: style TAB cell...>
# This is the sole table renderer for the fleet pane.
render_table() {
  local title="$1" header_line="$2" alignment_line="$3" rows="$4"
  local -a headers alignments cells
  local row style line i total natural max_index prefix
  rows="${rows//\\t/$'\t'}"
  IFS=$'\t' read -r -a headers <<< "$header_line"
  IFS=$'\t' read -r -a alignments <<< "$alignment_line"
  TABLE_WIDTHS=()
  for (( i=0; i<${#headers[@]}; i++ )); do TABLE_WIDTHS[i]="${#headers[i]}"; done
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -r -a cells <<< "$row"
    for (( i=1; i<${#cells[@]} && i<=${#headers[@]}; i++ )); do
      natural="${#cells[i]}"
      (( natural > TABLE_WIDTHS[i-1] )) && TABLE_WIDTHS[i-1]="$natural"
    done
  done <<< "$rows"
  total=$(( ${#headers[@]} + 1 + 2 * ${#headers[@]} ))
  for (( i=0; i<${#TABLE_WIDTHS[@]}; i++ )); do total=$(( total + TABLE_WIDTHS[i] )); done
  while (( total > FLEET_COLUMNS )); do
    max_index=-1
    for (( i=${#TABLE_WIDTHS[@]}-1; i>=0; i-- )); do
      natural="${#headers[i]}"; (( natural < 3 )) && natural=3
      [[ "${headers[i]}" == age && "$natural" -lt 7 ]] && natural=7
      if (( TABLE_WIDTHS[i] > natural )); then max_index="$i"; break; fi
    done
    (( max_index >= 0 )) || break
    TABLE_WIDTHS[max_index]=$(( TABLE_WIDTHS[max_index] - 1 )); total=$(( total - 1 ))
  done
  # At very narrow widths the headers themselves may not fit. Truncate those
  # too rather than ever handing wrapping back to the terminal.
  while (( total > FLEET_COLUMNS )); do
    max_index=-1
    for (( i=${#TABLE_WIDTHS[@]}-1; i>=0; i-- )); do
      if (( TABLE_WIDTHS[i] > 1 )); then max_index="$i"; break; fi
    done
    (( max_index >= 0 )) || break
    TABLE_WIDTHS[max_index]=$(( TABLE_WIDTHS[max_index] - 1)); total=$(( total - 1 ))
  done
  printf '%s%s%s\n' "$FLEET_BOLD" "$title" "$FLEET_RESET"
  table_rule "$FLEET_TL" "$FLEET_TM" "$FLEET_TR"
  line="$FLEET_V"
  for (( i=0; i<${#headers[@]}; i++ )); do
    line+=" $(fit_cell "${headers[i]}" "${TABLE_WIDTHS[i]}" "${alignments[i]:-left}") $FLEET_V"
  done
  printf '%s%s%s\n' "$FLEET_BOLD" "$line" "$FLEET_RESET"
  table_rule "$FLEET_ML" "$FLEET_MM" "$FLEET_MR"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -r -a cells <<< "$row"
    style="${cells[0]}"; line="$FLEET_V"
    for (( i=0; i<${#headers[@]}; i++ )); do
      line+=" $(fit_cell "${cells[i+1]:-}" "${TABLE_WIDTHS[i]}" "${alignments[i]:-left}") $FLEET_V"
    done
    prefix="$(row_style_prefix "$style")"
    printf '%s%s%s\n' "$prefix" "$line" "$FLEET_RESET"
  done <<< "$rows"
  table_rule "$FLEET_BL" "$FLEET_BM" "$FLEET_BR"
}

relative_age() {
  local stamp="${1:-}" now="$2"
  [[ -n "$stamp" && "$stamp" != null ]] || { printf 'never'; return; }
  python3 - "$stamp" "$now" <<'PY'
import datetime as dt
import sys

try:
    stamp = dt.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    age = max(0, int(sys.argv[2]) - int(stamp.timestamp()))
except (ValueError, TypeError):
    print("never")
    raise SystemExit
if age < 120:
    print(f"{age}s ago")
elif age < 3600:
    print(f"{age // 60}m")
elif age < 86400:
    print(f"{age // 3600}h")
else:
    print(f"{age // 86400}d")
PY
}

display_time() {
  local stamp="${1:-}" now="$2" age
  age="$(relative_age "$stamp" "$now")"
  # Deprecated for one release: PHAT_CONTROLLER_FLEET_ABSOLUTE_TIME.
  if [[ "${AUTOMETTA_FLEET_ABSOLUTE_TIME:-${PHAT_CONTROLLER_FLEET_ABSOLUTE_TIME:-false}}" == true && -n "$stamp" && "$stamp" != null ]]; then
    printf '%s (%s)' "$age" "$stamp"
  else
    printf '%s' "$age"
  fi
}

short_duration() {
  local seconds="${1:-0}"
  [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
  if (( seconds < 60 )); then printf '%ss' "$seconds"
  elif (( seconds < 3600 )); then printf '%sm%02ss' "$(( seconds / 60 ))" "$(( seconds % 60 ))"
  else printf '%sh%02sm' "$(( seconds / 3600 ))" "$(( (seconds % 3600) / 60 ))"; fi
}

short_tokens() {
  awk -v n="${1:-0}" 'BEGIN {
    if (n >= 1000000000) { v=n/1000000000; printf (v==int(v) ? "%dB" : "%.1fB"),v }
    else if (n >= 1000000) { v=n/1000000; printf (v==int(v) ? "%dM" : "%.1fM"),v }
    else if (n >= 1000) { v=n/1000; printf (v==int(v) ? "%dK" : "%.1fK"),v }
    else printf "%d", n
  }'
}

fleet_light_mark() {
  local light="$1"
  if "$FLEET_COLOUR"; then
    case "$light" in green) printf '●' ;; amber) printf '◐' ;; *) printf '○' ;; esac
  else
    case "$light" in green) printf 'ok' ;; amber) printf 'WARN' ;; *) printf 'FAIL' ;; esac
  fi
}

render_fleet_once() {
  local data_path="$controller_home/dashboard/data.json"
  local stale_seconds="${AUTOMETTA_FLEET_STALE_SECONDS:-${PHAT_CONTROLLER_FLEET_STALE_SECONDS:-600}}"
  local now generated_epoch age generated_at totals
  local total_enabled total_today_tokens total_today_cost total_window_spent total_window_cap
  local rows='' repo_json repo light reason state queue window today last style
  local input output progress stage status stamp detail
  fleet_style_init
  now="$(date -u +%s)"

  printf '%sautometta %s fleet%s\n' "$FLEET_BOLD" "$build_sha" "$FLEET_RESET"
  if [[ ! -s "$data_path" ]] || ! jq -e '.generated_at and (.repos | type == "array")' "$data_path" >/dev/null 2>&1; then
    printf '\nFLEET DATA MISSING\n  Run `autometta dashboard`; an empty fleet is not assumed healthy.\n'
    return 0
  fi

  generated_epoch="$(jq -r 'try (.generated_at | fromdateiso8601) catch 0' "$data_path")"
  generated_at="$(jq -r '.generated_at' "$data_path")"
  age=$(( now - generated_epoch ))
  printf 'Data generated: %s\n' "$(display_time "$generated_at" "$now")"
  if (( generated_epoch == 0 || age > stale_seconds )); then
    printf '%sFLEET DATA STALE: generated %s (limit %ss)%s\n' "$FLEET_RED$FLEET_BOLD" \
      "$(relative_age "$generated_at" "$now")" "$stale_seconds" "$FLEET_RESET"
  fi
  if jq -e '.drain.active == true' "$data_path" >/dev/null 2>&1; then
    printf '%sDRAIN cap %s, expires %s%s\n' "$FLEET_YELLOW$FLEET_BOLD" \
      "$(jq -r '.drain.cap' "$data_path")" "$(jq -r '.drain.expires_at' "$data_path")" "$FLEET_RESET"
  fi
  printf '\n'

  totals="$(jq -r '[(.fleet_totals.enabled_repos // 0),
    (.spend.tokens_total // .fleet_totals.today_tokens // 0),
    (.spend.cost_usd_est // .fleet_totals.today_cost_usd_est // 0),
    (.fleet_totals.window_tokens_spent // 0),(.fleet_totals.window_token_cap_total // 0)] | @tsv' "$data_path")"
  IFS=$'\t' read -r total_enabled total_today_tokens total_today_cost total_window_spent total_window_cap <<<"$totals"
  printf '%sTOTALS%s\n' "$FLEET_BOLD" "$FLEET_RESET"
  printf '  enabled: %s  today: %s tokens / $%.2f est  window: %s / %s tokens\n\n' \
    "$total_enabled" "$total_today_tokens" "$total_today_cost" "$total_window_spent" "$total_window_cap"

  while IFS= read -r repo_json; do
    [[ -n "$repo_json" ]] || continue
    repo="$(printf '%s' "$repo_json" | jq -r '.name')"
    IFS=$'\t' read -r light reason <<<"$(repo_light "$repo_json" "$now")"
    state="$(printf '%s' "$repo_json" | jq -r '
      if .state_error != null then "state unreadable"
      elif .halted then "HALTED: " + (.halt_reason // "budget")
      elif (.agents | length) > 0 then "run " + (.agents[0].stage_id // "unknown")
      elif (.queue | length) > 0 then "queued " + (.queue[0].stage_id // "unknown")
      else "idle" end')"
    queue="$(printf '%s' "$repo_json" | jq -r '.queue | length')"
    input="$(printf '%s' "$repo_json" | jq -r '.tokens_spent // 0')"
    output="$(printf '%s' "$repo_json" | jq -r 'if .drain_active then .drain_cap else .token_cap_total end // 0')"
    window="$(short_tokens "$input")/$(short_tokens "$output")"
    today="$(short_tokens "$(printf '%s' "$repo_json" | jq -r '.spend.tokens_total // 0')")"
    last="$(printf '%s' "$repo_json" | jq -r '.spend.last_dispatch_at // empty')"
    [[ -n "$last" ]] && last="$(relative_age "$last" "$now")" || last=never
    rows+="$light\t$(fleet_light_mark "$light")\t$repo\t$state\t$queue\t$window\t$today\t$last\t$reason"$'\n'
  done < <(jq -c '.repos[] | select(.enabled)' "$data_path")
  [[ -n "$rows" ]] || rows=$'quiet\t-\t(none)\tidle\t0\t0/0\t0\tnever\tno enabled repos\n'
  render_table 'REPOS' $'st\trepo\tstate\tq\twindow\ttoday\tlast\trule' \
    $'left\tleft\tleft\tright\tright\tright\tright\tleft' "$rows"

  # Compatibility anchor for consumers that select the alert-bearing tail.
  # The former union is gone; the rows below are classified by lifetime.
  printf '\nALERTS (classified: ATTENTION and HISTORY)\n\n'; rows=''
  while IFS=$'\t' read -r stage status; do
    [[ -n "$stage" ]] || continue
    printf '  %s\n' "$(fit_cell "$stage: $status" "$(( FLEET_COLUMNS - 2 ))")"
  done < <(jq -r --argjson statuses "$(alert_stage_statuses_json)" '.repos[] | select(.enabled) |
    .stages[]? | select(.status as $s | $statuses | index($s)) | [.id,.status] | @tsv' "$data_path")
  while IFS= read -r detail; do
    [[ -n "$detail" ]] || continue
    case "$detail" in
      *[Ss]ession\ limit*) detail='session limit' ;;
      *[Uu]sage\ limit*) detail='usage limit' ;;
      *429*) detail='HTTP 429' ;;
      *) detail='provider limit' ;;
    esac
    printf '  %s\n' "$(fit_cell "$detail" "$(( FLEET_COLUMNS - 2 ))")"
  done < <(jq -r '.repos[] | select(.enabled) | .alerts[]? | .line // empty' "$data_path")
  printf '\n'
  if (( generated_epoch == 0 || age > stale_seconds )); then
    rows+="red\tfleet\tdata stale\t$(relative_age "$generated_at" "$now")"$'\n'
  fi
  if [[ -n "$build_warning" ]]; then rows+="amber\tautometta\tbuild drift\t$build_warning"$'\n'; fi
  while IFS= read -r repo_json; do
    [[ -n "$repo_json" ]] || continue
    repo="$(printf '%s' "$repo_json" | jq -r '.name')"
    IFS=$'\t' read -r light reason <<<"$(repo_light "$repo_json" "$now")"
    [[ "$light" != green ]] || continue
    case "$reason" in 'historic terminal failure'|'drain active') continue ;; esac
    rows+="$light\t$repo\t$light\t$reason"$'\n'
  done < <(jq -c '.repos[] | select(.enabled)' "$data_path")
  while IFS=$'\t' read -r repo stage detail; do
    [[ -n "$repo" ]] || continue
    rows+="amber\t$repo\tamber\tprovider limit $stage: $detail"$'\n'
  done < <(jq -r --argjson now "$now" '
    def epoch: try (. | fromdateiso8601) catch 0;
    .repos[] | select(.enabled) as $r | $r.alerts[]? |
    select((.occurred_at | epoch) > 0 and ($now - (.occurred_at | epoch)) < 86400) |
    [$r.name,(.log // "provider" | split("/")[-1]),(.line // "provider limit")] | @tsv' "$data_path")
  [[ -n "$rows" ]] || rows=$'quiet\t(none)\t-\tno live conditions\n'
  render_table 'ATTENTION (live, clears when resolved)' $'repo\tlight\treason' $'left\tleft\tleft' "$rows"

  printf '\n'; rows=''
  local alert_statuses history_cutoff fresh_cutoff
  alert_statuses="$(alert_stage_statuses_json)"
  history_cutoff=$(( now - 604800 ))
  fresh_cutoff=$(( now - ${FLEET_FRESH_FAILURE_HOURS:-24} * 3600 ))
  while IFS=$'\t' read -r repo stage status stamp detail; do
    [[ -n "$repo" ]] || continue
    style=quiet; [[ "$status" == pass ]] || style=amber
    rows+="$style\t$repo\t$stage\t$status\t$(relative_age "$stamp" "$now")\t$detail"$'\n'
  done < <(jq -r --argjson statuses "$alert_statuses" --argjson history "$history_cutoff" \
    --argjson fresh "$fresh_cutoff" '
    def epoch: try (. | fromdateiso8601) catch 0;
    [ .repos[] | select(.enabled) as $r |
      ($r.stages[]? |
        (.event_at | epoch) as $at |
        select($at >= $history or $at == 0) |
        if (.status as $s | $statuses | index($s)) and ($at < $fresh or $at == 0) then
          {repo:$r.name,stage:.id,status:.status,at:(.event_at // "-"),detail:(.verifier_overall // "terminal stage")}
        elif .status == "completed" then
          {repo:$r.name,stage:.id,status:"pass",at:.event_at,detail:"completed"}
        else empty end),
      ($r.alerts[]? | (.occurred_at | epoch) as $at |
        select($at >= $history and $at < $fresh) |
        {repo:$r.name,stage:(.log // "provider" | split("/")[-1]),status:"limit",at:.occurred_at,detail:(.line // "provider limit")})
    ] | sort_by(.at) | reverse | .[:8][] |
    [.repo,.stage,.status,.at,.detail] | @tsv' "$data_path")
  [[ -n "$rows" ]] || rows=$'quiet\t(none)\t-\t-\t-\tno history in seven days\n'
  render_table 'HISTORY (7d, newest first, max 8)' $'repo\tstage\tevent\tage\tdetail' \
    $'left\tleft\tleft\tright\tleft' "$rows"

  printf '\nAGENTS\nRUNNING\n'; rows=''
  local kind role family identity verifier elapsed budget flags log_bytes agent_light
  while IFS=$'\t' read -r repo kind stage role family identity verifier elapsed budget flags log_bytes; do
    [[ -n "$repo" ]] || continue
    if [[ "$kind" == live ]]; then
      style=running; agent_light=green
      if [[ "$flags" == *over-budget* ]]; then style=failure; agent_light=red; fi
      progress="$(short_duration "$elapsed")"
      (( budget > 0 )) && progress+="/$(short_duration "$budget")"
      progress+=" log:${log_bytes}B"
      rows+="$style\t$(fleet_light_mark "$agent_light")\t$repo\tlive\t$stage\t$role\t$family $identity\t-\t$progress"$'\n'
    elif [[ "$kind" == queued ]]; then
      rows+="quiet\t-\t$repo\tnext\t$stage\tqueued\t$identity\t$verifier\t-"$'\n'
    else
      rows+="quiet\t-\t$repo\tempty\tempty\tidle\t-\t-\t-"$'\n'
    fi
  done < <(jq -r '.repos[] | select(.enabled) as $r |
    ($r.agents[]? | [$r.name,"live",(.stage_id // "unknown"),(.role // "unknown"),
      (.family // "unknown"),((.identity // "unknown") | split("<")[0] | rtrimstr(" ")),"-",(.elapsed_seconds // 0),(.budget_seconds // 0),
      ((.flags // []) | join(",")),(.log_bytes // 0)]),
    ($r.queue[]? | [$r.name,"queued",(.stage_id // "unknown"),"queued","-",
      ((.worker // "unknown") | split("<")[0] | rtrimstr(" ")),
      ((.verifier // "unknown") | split("<")[0] | rtrimstr(" ")),0,0,"",0]),
    ($r | select((.agents|length)==0 and (.queue|length)==0) |
      [$r.name,"empty","empty","idle","-","-","-",0,0,"",0]) | @tsv' "$data_path")
  [[ -n "$rows" ]] || rows=$'quiet\t-\t(none)\t-\t-\t-\t-\t-\t-\n'
  render_table 'LIVE AGENTS / QUEUED TARGETS' $'st\trepo\tkind\tstage\trole\tagent / worker\tverifier\telapsed/budget' \
    $'left\tleft\tleft\tleft\tleft\tleft\tleft\tright' "$rows"

  printf '\nQUEUE\n'; rows=''
  while IFS=$'\t' read -r repo queue stage; do
    [[ -n "$repo" ]] || continue
    [[ "$queue" -gt 0 ]] || stage=empty
    rows+="quiet\t$repo\t$queue\t$stage"$'\n'
  done < <(jq -r '.repos[] | select(.enabled) |
    [.name,(.queue|length),(.queue[0].stage_id // "empty")] | @tsv' "$data_path")
  render_table 'PENDING STAGES' $'repo\tdepth\tnext stage' $'left\tright\tleft' "$rows"

  printf '\nREQUIRED ACTIONS\n'; rows=''
  while IFS=$'\t' read -r repo status detail; do
    [[ -n "$repo" ]] || continue
    rows+="action\t$repo\t$status\t$detail"$'\n'
  done < <(jq -r '.repos[] | select(.enabled) |
    (if .halted then [.name,"halted",(.halt_reason // "operator action required")] else empty end),
    (if ((.consecutive_failure_cap // 0)>0 and (.consecutive_failures // 0)>=.consecutive_failure_cap)
      then [.name,"attempt cap",((.consecutive_failures|tostring)+"/"+(.consecutive_failure_cap|tostring))] else empty end) |
    @tsv' "$data_path")
  [[ -n "$rows" ]] || rows=$'quiet\t(none)\tclear\tno operator action required\n'
  render_table 'OPERATOR DECISIONS' $'repo\tstate\tdetail' $'left\tleft\tleft' "$rows"

  printf '\nFAILURES\n'; rows=''
  while IFS=$'\t' read -r repo stage status stamp; do
    [[ -n "$repo" ]] || continue
    rows+="amber\t$repo\t$stage\tstage\t$status\t-\t$(relative_age "$stamp" "$now")"$'\n'
  done < <(jq -r --argjson statuses "$alert_statuses" '.repos[] | select(.enabled) as $r |
    $r.stages[]? | select(.status as $s | $statuses | index($s)) |
    [$r.name,.id,.status,(.event_at // "-")] | @tsv' "$data_path")
  while IFS=$'\t' read -r repo stage role status stamp progress; do
    [[ -n "$repo" ]] || continue
    rows+="failure\t$repo\t$stage\t$role\t$status\t$progress\t$(relative_age "$stamp" "$now")"$'\n'
  done < <(jq -r '.spend.failures[]? |
    [.repo,.stage_id,.role,.result,.ts,(.tokens_lost|tostring)] | @tsv' "$data_path")
  local lost_sum
  lost_sum="$(jq -r '[.spend.failures[]?.tokens_lost] | add // 0' "$data_path")"
  [[ -n "$rows" ]] || rows=$'quiet\t(none)\t-\t-\t-\t0\t-\n'
  rows+="action\tTOTAL LOST\t-\t-\tnon-pass\t$lost_sum\t7d"$'\n'
  render_table 'STAGES AND NON-PASS DISPATCHES' $'repo\tstage\trole\tresult\ttokens lost\tage' \
    $'left\tleft\tleft\tleft\tright\tright' "$rows"

  printf '\nLIMITS\n'; rows=''
  while IFS=$'\t' read -r repo stage stamp detail; do
    [[ -n "$repo" ]] || continue
    rows+="amber\t$repo\t$stage\t$(relative_age "$stamp" "$now")\t$detail"$'\n'
  done < <(jq -r '.repos[] | select(.enabled) as $r | $r.alerts[]? |
    [$r.name,(.log // "provider" | split("/")[-1]),(.occurred_at // "-"),(.line // "provider limit")] | @tsv' "$data_path")
  [[ -n "$rows" ]] || rows=$'quiet\t(none)\t-\t-\tno provider limits\n'
  render_table 'PROVIDER LIMITS' $'repo\tlog\tage\tdetail' $'left\tleft\tright\tleft' "$rows"

  printf '\n'; rows=''
  local cached productive lost cost
  while IFS=$'\t' read -r repo role input cached output productive lost cost; do
    [[ -n "$repo" ]] || continue
    rows+="quiet\t$repo\t$role\t$input\t$cached\t$output\t$productive\t$lost\t\$$cost"$'\n'
  done < <(jq -r '.spend.by_repo_role[]? |
    [.repo,.role,.input_tokens,.cached_input_tokens,.output_tokens,
     .productive_tokens,.lost_tokens,((.cost_usd_est * 100 | round) / 100)] | @tsv' "$data_path")
  [[ -n "$rows" ]] || rows=$'quiet\t(none)\t-\t0\t0\t0\t0\t0\t$0\n'
  render_table 'SPEND (today UTC)' $'repo\trole\tin\tcached\tout\tpass\tlost\tcost' \
    $'left\tleft\tright\tright\tright\tright\tright\tright' "$rows"

  local overlap
  overlap="$(jq -r '[.repos[] | select(.enabled and (.name | startswith("emergence-lab"))) | .name] |
    if length > 1 then join(", ") else empty end' "$data_path")"
  [[ -z "$overlap" ]] || printf '\nOVERLAP\n  emergence-lab subscribers enabled together: %s\n' "$overlap"
}

fleet_refresher() {
  # Deprecated for one release: PHAT_CONTROLLER_FLEET_REFRESH_INTERVAL and PHAT_CONTROLLER_FLEET_SESSION.
  local interval="${AUTOMETTA_FLEET_REFRESH_INTERVAL:-${PHAT_CONTROLLER_FLEET_REFRESH_INTERVAL:-120}}"
  local session="${AUTOMETTA_FLEET_SESSION:-${PHAT_CONTROLLER_FLEET_SESSION:-}}"
  trap 'exit 0' INT TERM
  while true; do
    if [[ -n "$session" ]] && ! tmux has-session -t "$session" 2>/dev/null; then
      return 0
    fi
    "$script_dir/aggregate-dashboard.sh" >/dev/null 2>&1 || true
    sleep "$interval"
  done
}

fleet_ticker() {
  # Deprecated for one release: PHAT_CONTROLLER_STATUS_TICKER_INTERVAL and PHAT_CONTROLLER_FLEET_ONCE.
  local interval="${AUTOMETTA_STATUS_TICKER_INTERVAL:-${PHAT_CONTROLLER_STATUS_TICKER_INTERVAL:-5}}"
  if [[ "${AUTOMETTA_FLEET_ONCE:-${PHAT_CONTROLLER_FLEET_ONCE:-false}}" == true ]]; then
    refresh_build_status
    render_fleet_once
    return 0
  fi
  trap 'exit 0' INT TERM
  while true; do
    refresh_build_status
    printf '\033[H'
    # Erase each line's tail as it is overwritten: home-and-repaint leaves
    # the old frame's longer lines showing through otherwise (REPOS over
    # agentic-rag-kimble rendered as REPOSntic-rag-kimble, 2026-08-24).
    render_fleet_once | sed -e $'s/$/\033[K/'
    printf '\nRefresh: %ss\033[K\033[J\n' "$interval"
    sleep "$interval"
  done
}

# viewer_sessions: the tmux sessions this tool owns, one per subscriber in the
# registry, enabled or disabled. A disabled subscriber's viewer is still ours
# to report and remove; a session that merely starts with "autometta-" is not.
#
# The prefix glob this replaces was a real hazard rather than a tidiness point.
# An operator's own shell or agent session can share the prefix -- on
# 2026-08-23 report_orphans flagged autometta-cl, an attached Claude Code
# session, as an orphaned viewer, and detach --all would have killed it on the
# strength of the same match. Killing a session because its name collides is
# unrecoverable, so ownership is established from the registry, never guessed
# from the name.
viewer_sessions() {
  local f base repo slug
  for f in "$subscribers_dir"/*.yaml "$subscribers_dir"/*.yaml.disabled; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in template.yaml|template.yaml.disabled) continue ;; esac
    repo="$(read_field "$f" repo_path)"
    [[ -n "$repo" ]] || continue
    slug="$(session_slug "$repo")"
    [[ -n "$slug" ]] || continue
    printf 'autometta-%s\n' "$slug"
  done
}

report_orphans() {
  command -v tmux >/dev/null 2>&1 || return 0
  local expected='' f enabled repo slug session
  for f in "$subscribers_dir"/*.yaml; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == template.yaml ]] && continue
    enabled="$(read_field "$f" enabled)"
    [[ "$enabled" == true ]] || continue
    repo="$(read_field "$f" repo_path)"
    [[ -n "$repo" ]] || continue
    slug="$(session_slug "$repo")"
    expected="${expected}autometta-${slug}"$'\n'
  done
  local owned
  owned="$(viewer_sessions)"
  while IFS= read -r session; do
    printf '%s' "$owned" | grep -Fqx "$session" || continue
    if ! printf '%s' "$expected" | grep -Fqx "$session"; then
      printf 'ORPHAN tmux viewer %s (subscriber disabled or gone; use `autometta detach --all` or `tmux kill-session -t %s`)\n' "$session" "$session" >&2
    fi
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)
}

reconcile_enabled_viewers() {
  local f enabled repo
  for f in "$subscribers_dir"/*.yaml; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == template.yaml ]] && continue
    enabled="$(read_field "$f" enabled)"
    [[ "$enabled" == true ]] || continue
    repo="$(read_field "$f" repo_path)"
    [[ -d "$repo" ]] || continue
    "$script_dir/attach.sh" --ensure "$repo" || true
  done
}

dry_run=false
ensure_only=false
mode=attach
repo_path="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --ensure) ensure_only=true ;;
    --fleet-ticker) mode=fleet ;;
    --detach) mode=detach ;;
    --detach-all) mode=detach_all ;;
    --fleet-refresh) mode=fleet_refresh ;;
    -*) usage ;;
    *)
      [[ "$repo_path" == "." ]] || usage
      repo_path="$1"
      ;;
  esac
  shift
done

if [[ "$mode" == fleet ]]; then
  fleet_ticker
  exit 0
fi
if [[ "$mode" == fleet_refresh ]]; then
  fleet_refresher
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  if "$ensure_only"; then printf 'WARN tmux optional attach viewer unavailable\n' >&2; exit 0; fi
  printf 'MISSING tmux optional attach viewer requires tmux\n' >&2
  exit 1
fi

if [[ "$mode" == detach_all ]]; then
  removed=0
  owned="$(viewer_sessions)"
  while IFS= read -r session; do
    printf '%s' "$owned" | grep -Fqx "$session" || continue
    tmux kill-session -t "$session"
    printf 'PASS tmux viewer removed %s\n' "$session"
    removed=$(( removed + 1 ))
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)
  (( removed > 0 )) || printf 'NOOP no autometta viewers\n'
  exit 0
fi

repo_path="$(resolve_path "$repo_path")"
repo_slug="$(session_slug "$repo_path")"
[[ -n "$repo_slug" ]] || repo_slug=repo
# Deprecated for one release: PHAT_CONTROLLER_TMUX_SESSION.
session_name="${AUTOMETTA_TMUX_SESSION:-${PHAT_CONTROLLER_TMUX_SESSION:-autometta-$repo_slug}}"

if [[ "$mode" == detach ]]; then
  if tmux has-session -t "$session_name" 2>/dev/null; then
    tmux kill-session -t "$session_name"
    printf 'PASS tmux viewer removed %s\n' "$session_name"
  else
    printf 'NOOP tmux viewer absent %s\n' "$session_name"
  fi
  exit 0
fi

# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# Resolved root, not the self root: the viewer's panes run autometta scripts,
# and a viewer reporting on a different tree than the tick executes is the
# split card 42 closed.
autometta_resolve_root "$(autometta_self_root "$script_dir")"
autometta_root="$AUTOMETTA_ROOT_RESOLVED"
autometta_root_q="$(shell_quote "$autometta_root")"
controller_log_q="$(shell_quote "$controller_home/log")"
repo_path_q="$(shell_quote "$repo_path")"
status_cmd="cd $autometta_root_q && scripts/status-ticker.sh --repo $repo_path_q"
log_cmd="mkdir -p $controller_log_q; latest=''; for candidate in $controller_log_q/tick-*.log; do [ -e \"\$candidate\" ] || continue; latest=\"\$candidate\"; done; printf 'Project: $repo_slug\nRepo: $repo_path\n\n'; if [ -n \"\$latest\" ]; then printf '(showing only lines mentioning this repo; waiting for the first one)\\n'; tail -f \"\$latest\" | grep --line-buffered -F $repo_path_q; else printf 'No tick log yet in $controller_home/log\n'; exec \"\${SHELL:-/bin/sh}\"; fi"
ticker_cmd="cd $autometta_root_q && scripts/agent-ticker.sh $repo_path_q"
fleet_cmd="cd $autometta_root_q && scripts/attach.sh --fleet-ticker"
session_name_q="$(shell_quote "$session_name")"
fleet_refresh_cmd="cd $autometta_root_q && AUTOMETTA_FLEET_SESSION=$session_name_q scripts/attach.sh --fleet-refresh"

report_orphans

if "$dry_run"; then
  printf 'tmux session: %s\nrepo: %s\n' "$session_name" "$repo_path"
  if [[ "$repo_slug" == autometta ]]; then printf 'default window: fleet (%s)\nsecond window: repo\n' "$fleet_cmd"; fi
  printf 'status pane: %s\nlog pane: %s\nticker pane: %s\n' "$status_cmd" "$log_cmd" "$ticker_cmd"
  exit 0
fi

if ! "$ensure_only"; then
  reconcile_enabled_viewers
fi

# An interactive re-attach replaces the viewer so long-running ticker loops
# pick up the installed scripts. --ensure remains non-disruptive for ticks.
if tmux has-session -t "$session_name" 2>/dev/null && ! "$ensure_only"; then
  tmux kill-session -t "$session_name"
  printf 'PASS tmux viewer refreshed %s\n' "$session_name"
fi

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  if [[ "$repo_slug" == autometta ]]; then
    "$script_dir/aggregate-dashboard.sh" >/dev/null 2>&1 || true
    tmux new-session -d -s "$session_name" -n fleet "$fleet_cmd"
    tmux run-shell -b -t "$session_name" "$fleet_refresh_cmd"
    tmux new-window -d -t "$session_name" -n repo "$status_cmd"
    tmux split-window -h -t "$session_name":repo "$log_cmd"
    tmux split-window -v -t "$session_name":repo.1 "$ticker_cmd"
    tmux select-window -t "$session_name":fleet
  else
    tmux new-session -d -s "$session_name" "$status_cmd"
    tmux split-window -h -t "$session_name" "$log_cmd"
    tmux split-window -v -t "$session_name":0.1 "$ticker_cmd"
    tmux select-pane -t "$session_name":0.0
  fi
  printf 'PASS tmux viewer created %s\n' "$session_name"
elif "$ensure_only"; then
  printf 'PASS tmux viewer exists %s\n' "$session_name"
fi

"$ensure_only" && exit 0
tmux attach-session -t "$session_name"

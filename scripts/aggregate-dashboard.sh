#!/usr/bin/env bash
# aggregate-dashboard.sh: the sole subscriber walker for fleet displays.
#
# Usage: aggregate-dashboard.sh [--repo <repo-path>]
#
# Without --repo: walks every subscriber and writes the fleet-wide
# dashboard/data.json and data.js, as before.
#
# With --repo: walks only that one subscriber, prints its repo object (the
# same shape as one element of the fleet's .repos[]) to stdout, and writes
# nothing. This is the sole data source for scripts/repo-ticker.sh -- one
# walker, so a per-repo renderer never re-derives a figure the walker already
# computed. It also enriches the matched repo's live agents with an
# incrementally-read transcript token total (ported from agent-ticker.sh's
# ACTIVE panel), which the fleet-wide pass skips as too expensive to run
# every 120s across five repos.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# shellcheck source=budget.sh
. "$script_dir/budget.sh"
# shellcheck source=repo-light.sh
. "$script_dir/repo-light.sh"
# shellcheck source=alert-statuses.sh
. "$script_dir/alert-statuses.sh"
alert_statuses_json="$(alert_stage_statuses_json)"
# shellcheck source=vendor-set.sh
. "$script_dir/vendor-set.sh"
autometta_current_sha="$(git -C "$script_dir/.." rev-parse --short HEAD 2>/dev/null || printf unknown)"

repo_filter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { printf 'usage: %s [--repo <repo-path>]\n' "$(basename "$0")" >&2; exit 1; }
      repo_filter="$2"
      shift 2
      ;;
    *)
      printf 'usage: %s [--repo <repo-path>]\n' "$(basename "$0")" >&2
      exit 1
      ;;
  esac
done
repo_filter_resolved=""
if [[ -n "$repo_filter" ]]; then
  repo_filter_resolved="$(cd "$repo_filter" 2>/dev/null && pwd -P || printf '%s' "$repo_filter")"
fi

controller_home="$(autometta_controller_home)"
subscribers_dir="$controller_home/subscribers"
dashboard_dir="$controller_home/dashboard"
data_json="$dashboard_dir/data.json"
data_js="$dashboard_dir/data.js"
now_epoch="$(date -u +%s)"
today_epoch=$(( now_epoch - (now_epoch % 86400) ))

build_check_max_age="${AUTOMETTA_BUILD_CHECK_MAX_AGE:-600}"
[[ "$build_check_max_age" =~ ^[0-9]+$ ]] || build_check_max_age=600

# --repo prints one row and writes nothing, so the dashboard directory and the
# scratch space belong to the fleet pass alone. Both were unconditional, which
# cost a mkdir and two mktemps on every ticker refresh for files nothing read.
aggregate_tmp=""
cleanup() {
  case "$aggregate_tmp" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$aggregate_tmp" ;; esac
}
trap cleanup EXIT
new_tmp() {
  [[ -n "$aggregate_tmp" ]] || aggregate_tmp="$(mktemp -d)"
  mktemp "$aggregate_tmp/item.XXXXXX"
}
if [[ -z "$repo_filter" ]]; then
  mkdir -p "$dashboard_dir"
fi

# One pass over a subscriber file for the three fields that matter, in the
# shell rather than a sed per key. --repo has to read every subscriber before
# it knows which one it wants, so three forks per key became twenty-seven
# forks to answer a question about one repo. Same rule as the sed it replaces:
# the key at column zero, first occurrence wins, one layer of quoting off.
subscriber_enabled=""; subscriber_repo_path=""; subscriber_manifest_path=""
read_subscriber_fields() {
  local file_path="$1" line key raw
  local seen_enabled=false seen_repo_path=false seen_manifest_path=false
  subscriber_enabled=""; subscriber_repo_path=""; subscriber_manifest_path=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    key="${line%%:*}"
    case "$key" in
      enabled|repo_path|manifest_path) ;;
      *) continue ;;
    esac
    [[ "$line" != "$key" ]] || continue
    raw="${line#"$key":}"
    while [[ "$raw" == [[:space:]]* ]]; do raw="${raw#?}"; done
    raw="${raw%\"}"; raw="${raw#\"}"
    raw="${raw%\'}"; raw="${raw#\'}"
    case "$key" in
      enabled) [[ "$seen_enabled" == true ]] || { subscriber_enabled="$raw"; seen_enabled=true; } ;;
      repo_path) [[ "$seen_repo_path" == true ]] || { subscriber_repo_path="$raw"; seen_repo_path=true; } ;;
      manifest_path) [[ "$seen_manifest_path" == true ]] || { subscriber_manifest_path="$raw"; seen_manifest_path=true; } ;;
    esac
  done < "$file_path"
}

state_yaml_to_json() { yq -o=json '.' "$1"; }

epoch_iso() {
  local epoch="${1:-0}"
  [[ "$epoch" =~ ^[0-9]+$ && "$epoch" -gt 0 ]] || return 0
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || true
}

repos_array_file=""
if [[ -z "$repo_filter" ]]; then
  repos_array_file="$(new_tmp)"
  printf '[]\n' > "$repos_array_file"
fi

for subscriber_file in "$subscribers_dir"/*.yaml; do
  [[ -e "$subscriber_file" ]] || continue
  name="${subscriber_file##*/}"; name="${name%.yaml}"
  [[ "$name" == template ]] && continue

  read_subscriber_fields "$subscriber_file"
  enabled="$subscriber_enabled"
  repo_path="$subscriber_repo_path"
  manifest_path="$subscriber_manifest_path"
  [[ -n "$repo_path" ]] || continue

  if [[ -n "$repo_filter" ]]; then
    # The literal comparison first, so the common case never forks a subshell
    # to resolve a path it was about to skip anyway.
    if [[ "$repo_path" != "$repo_filter" ]]; then
      repo_path_resolved="$(cd "$repo_path" 2>/dev/null && pwd -P || printf '%s' "$repo_path")"
      [[ "$repo_path_resolved" == "$repo_filter_resolved" ]] || continue
    fi
  fi

  card_globs=()
  if [[ -n "$manifest_path" && -f "$manifest_path" ]]; then
    while IFS= read -r g; do [[ -n "$g" ]] && card_globs+=("$g"); done \
      < <(yq -r '.stage_card_globs[]? // empty' "$manifest_path" 2>/dev/null || true)
  fi
  card_globs+=("stage-cards/*.md")
  # Legacy fallbacks for subscribers that have not migrated their cards yet.
  card_globs+=("docs/stages/*.md" "examples/self-host/*.md")

  # One index over every candidate card, built once per subscriber. The shape
  # this replaces answered "which card is stage X?" by re-expanding the globs
  # and forking basename per candidate, once for the card path and again for
  # the orchestrator line: a fifty-stage repo with eighty cards paid several
  # thousand forks for a question the glob already knew, and that was two
  # thirds of the walk's wall clock. Suffix stripping is parameter expansion
  # and the orchestrator lines come out of a single awk pass over the same
  # file list. Earlier globs still win, and within a glob the earlier
  # candidate wins, so the index answers exactly what the lookup did.
  card_paths=()
  card_index_lines=""
  for card_glob in "${card_globs[@]}"; do
    if [[ "$card_glob" = /* ]]; then card_search="$card_glob"; else card_search="$repo_path/$card_glob"; fi
    for card_cand in $card_search; do
      [[ -f "$card_cand" ]] || continue
      card_sid="${card_cand##*/}"; card_sid="${card_sid%.md}"
      card_index_lines+="$card_sid"$'\t'"$card_cand"$'\n'
      card_paths+=("$card_cand")
    done
  done

  cards_json='{}'
  if [[ ${#card_paths[@]} -gt 0 ]]; then
    cards_json="$(awk '
      FNR == 1 { matched = 0 }
      !matched && /^- \*\*Orchestrator:\*\*/ {
        value = $0
        sub(/^- \*\*Orchestrator:\*\*[[:space:]]*/, "", value)
        printf "%s\t%s\n", FILENAME, value
        matched = 1
      }' "${card_paths[@]}" 2>/dev/null | jq -R -s -c \
      --arg index_lines "$card_index_lines" '
      ([splits("\n") | select(length > 0) | split("\t")] |
        reduce .[] as $row ({}; . + {($row[0]): ($row[1] // "")})) as $orchestrators |
      ($index_lines | split("\n") | map(select(length > 0) | split("\t"))) |
      reduce .[] as $row ({};
        if has($row[0]) then .
        else . + {($row[0]): {path: $row[1],
          orchestrator: (($orchestrators[$row[1]] // "") |
            if . == "" then null else . end)}} end)' \
      || printf '{}')"
  fi

  state_yaml="$repo_path/state/state.yaml"
  budget_path="$repo_path/state/budget.json"
  cost_log_path="$repo_path/state/cost-log.jsonl"
  quota_path="$repo_path/state/quota-window.json"
  active_agents_dir="$repo_path/state/active-agents"
  heartbeat_path="$repo_path/state/heartbeat.json"

  tokens_spent=0; token_cap_total=0; halted=false; halt_reason=null
  consecutive_failures=0; consecutive_failure_cap=0
  paused_until=null; paused_reason=null
  # Eight fields off one file used to be eight jq invocations over a string
  # the shell had already read. One pass emits them a line each instead; the
  # nullable ones come through tojson, which never emits a bare newline, so a
  # line is a safe frame for them.
  if [[ -f "$budget_path" ]] && budget_fields="$(jq -r '
    [(.tokens_spent // 0), (.token_cap_total // 0), (.halted // false),
     ((.halt_reason // null) | tojson), (.consecutive_failures // 0),
     (.consecutive_failure_cap // 0), ((.paused_until // null) | tojson),
     ((.paused_reason // null) | tojson)] | .[]' "$budget_path" 2>/dev/null)"; then
    {
      IFS= read -r tokens_spent; IFS= read -r token_cap_total
      IFS= read -r halted; IFS= read -r halt_reason
      IFS= read -r consecutive_failures; IFS= read -r consecutive_failure_cap
      IFS= read -r paused_until; IFS= read -r paused_reason
    } <<<"$budget_fields"
  fi
  # Resolved cap (drain > repo cap > host default > floor) and which rule
  # won, so the ticker's CAP row never shows a resting number while a drain
  # or host default is actually what binds.
  effective_token_cap="$(budget_effective_token_cap "$repo_path" 2>/dev/null || printf '%s' "$token_cap_total")"
  cap_source="$(budget_cap_source "$repo_path" 2>/dev/null || printf 'host-default')"

  drain_active=false; drain_cap=null; drain_expires_at=null
  if active_cap="$(budget_drain_active "$repo_path" 2>/dev/null)" && [[ -n "$active_cap" ]]; then
    drain_active=true
    drain_cap="$active_cap"
    drain_epoch="$(jq -r '.expires_at // 0' "$(budget_drain_file)" 2>/dev/null || printf 0)"
    drain_iso="$(epoch_iso "$drain_epoch")"
    [[ -n "$drain_iso" ]] && drain_expires_at="$(jq -nc --arg value "$drain_iso" '$value')"
  fi

  heartbeat_json='{}'
  if [[ -f "$heartbeat_path" ]]; then
    heartbeat_json="$(jq -c '.' "$heartbeat_path" 2>/dev/null || printf '{}')"
  fi
  # Heartbeat owns the expensive tree walk. Missing or over-age evidence is
  # unreadable, so a stopped cadence cannot leave an old "current" verdict on
  # screen indefinitely.
  build_check="$(printf '%s' "$heartbeat_json" | jq -c \
    --argjson now "$now_epoch" --argjson max_age "$build_check_max_age" '
    (.build_check // {status:"unreadable",stale:false,installed_sha:null,
      checkout_sha:null,checked_at:null}) |
    . as $check |
    (try ($check.checked_at | fromdateiso8601) catch 0) as $checked_epoch |
    if $checked_epoch == 0 or ($now - $checked_epoch) > $max_age
    then $check + {status:"unreadable",stale:false}
    else $check end')"
  # The alive-pid list rides along so the agent pass below can test membership
  # in the shell rather than ask jq once per dead-looking pid. It sits before
  # the outlier policy because it is the one field that can come out empty,
  # and a trailing empty line would not survive the command substitution.
  {
    IFS= read -r heartbeat_checked_at; IFS= read -r heartbeat_baselines
    IFS= read -r heartbeat_alive_pids; IFS= read -r heartbeat_outlier_policy
  } <<<"$(printf '%s' "$heartbeat_json" | jq -r '
    [((.checked_at // null) | tojson), ((.baselines // {}) | tojson),
     ([.entries[]? | select(.alive == true) | .pid | tostring] | join(",")),
     ((.outlier_policy // {}) | tojson)] | .[]')"

  # Vendor staleness (card 66): the same comparison scripts/tick.sh's
  # warn_if_vendor_stale makes each pass, offered here as data rather than a
  # log line so the fleet page can show which subscribers are dispatching
  # against a copy of the contract older than this autometta checkout.
  vendor_stale=false; vendor_from=null
  vendor_stamp="$repo_path/$autometta_vendor_stamp_name"
  if [[ -f "$vendor_stamp" && "$autometta_current_sha" != unknown ]]; then
    vendored_from_raw="$(autometta_vendor_stamp_field "$vendor_stamp" vendored_from | tr -d '[:space:]')"
    if [[ -n "$vendored_from_raw" ]]; then
      vendor_from="$(jq -nc --arg value "$vendored_from_raw" '$value')"
      [[ "$vendored_from_raw" == "$autometta_current_sha" ]] || vendor_stale=true
    fi
  fi

  stages_json='[]'; state_error=null; last_tick_at=null; tick_count=0; current_stage=null; run_started_at=null
  current_run_id=null; current_run_started_at=null; current_run_stages='[]'
  if [[ ! -r "$state_yaml" ]]; then
    state_error='"state.yaml unreadable"'
  elif state_doc="$(state_yaml_to_json "$state_yaml" 2>/dev/null)" \
    && state_fields="$(printf '%s' "$state_doc" | jq -r '
      [.stages[]? | {
        id, run_id:(.run_id // null), status:(.status // "pending"),
        worker:(.worker // null), verifier:(.verifier // null),
        started_at:(.started_at // null), completed_at:(.completed_at // null), tokens:(.tokens // 0),
        worker_tokens:(.worker_tokens // null), verifier_tokens:(.verifier_tokens // null),
        commit:(.commit // null), verifier_artefact:(.verifier_artefact // null),
        integration:(.integration // null), required_action:(.required_action // null),
        verifier_attempts:(.verifier_attempts // 0), wip_branch:(.wip_branch // null),
        wip_commit:(.wip_commit // null), stall_marker:(.stall_marker // null)
      }] as $stages |
      [($stages | tojson), ((.last_tick_at // null) | tojson), (.tick_count // 0),
       ((.current_stage // null) | tojson),
       ([$stages[] | select((.verifier_artefact // "") != "") | .verifier_artefact] | join("\t")),
       (([$stages[] | .started_at // empty] | min // null) | tojson)] | .[]')"; then
    {
      IFS= read -r stages_json; IFS= read -r last_tick_at; IFS= read -r tick_count
      IFS= read -r current_stage; IFS= read -r artefact_rel_line; IFS= read -r run_started_at
    } <<<"$state_fields"

    # Verifier artefacts, read as a set. Per stage this was a jq for .overall,
    # a stat and a date for the mtime; one jq and one stat over the whole list
    # answer the same thing, and jq's strftime formats the epochs it already
    # holds rather than forking date per row. The paths ride out of the state
    # pass above rather than costing a jq of their own to re-read.
    artefact_keys=(); artefact_paths=()
    if [[ -n "$artefact_rel_line" ]]; then
      IFS=$'\t' read -ra artefact_rels <<<"$artefact_rel_line"
      for artefact_rel in "${artefact_rels[@]}"; do
        [[ -n "$artefact_rel" && -f "$repo_path/$artefact_rel" ]] || continue
        artefact_keys+=("$artefact_rel"); artefact_paths+=("$repo_path/$artefact_rel")
      done
    fi

    artefact_key_lines=""; artefact_overall_lines=""; mtime_lines=""
    if [[ ${#artefact_paths[@]} -gt 0 ]]; then
      overall_values=()
      if batch_overalls="$(jq -c '.overall // null' "${artefact_paths[@]}" 2>/dev/null)"; then
        while IFS= read -r overall_line; do overall_values+=("$overall_line"); done <<<"$batch_overalls"
      fi
      if [[ ${#overall_values[@]} -ne ${#artefact_paths[@]} ]]; then
        # One artefact jq cannot read aborts the batch, so an unreadable file
        # costs a slow walk rather than values read against the wrong stage.
        overall_values=()
        for artefact_path in "${artefact_paths[@]}"; do
          overall_values+=("$(jq -c '.overall // null' "$artefact_path" 2>/dev/null || printf null)")
        done
      fi
      mtime_values=()
      if batch_mtimes="$(stat -f '%m' "${artefact_paths[@]}" 2>/dev/null \
        || stat -c '%Y' "${artefact_paths[@]}" 2>/dev/null)"; then
        while IFS= read -r mtime_line; do mtime_values+=("$mtime_line"); done <<<"$batch_mtimes"
      fi
      if [[ ${#mtime_values[@]} -eq ${#artefact_paths[@]} ]]; then
        mtime_lines="$(printf '%s\n' "${mtime_values[@]}")"
      fi
      artefact_key_lines="$(printf '%s\n' "${artefact_keys[@]}")"
      artefact_overall_lines="$(printf '%s\n' "${overall_values[@]}")"
    fi

    # One pass builds the enriched stage list and everything derived from it.
    # Joining the cards, joining the artefacts and scoping the current run were
    # three walks of the same array through three jq processes, each one
    # re-serialising a list the previous had just written.
    {
      IFS= read -r stages_json; IFS= read -r current_run_id
      IFS= read -r current_run_stages; IFS= read -r current_run_started_at
    } <<<"$(printf '%s' "$stages_json" | jq -r \
      --arg repo_path "$repo_path" --argjson cards "$cards_json" \
      --arg artefact_keys "$artefact_key_lines" --arg artefact_overalls "$artefact_overall_lines" \
      --arg artefact_mtimes "$mtime_lines" '
      ($artefact_keys | split("\n") | map(select(length > 0))) as $keys |
      ($artefact_overalls | split("\n") | map(select(length > 0) | fromjson)) as $overalls |
      ($artefact_mtimes | split("\n") | map(select(length > 0)) |
        map(if test("^[0-9]+$") then tonumber else 0 end)) as $mtimes |
      (reduce range(0; $keys | length) as $i ({};
        . + {($keys[$i]): {
          overall: $overalls[$i],
          at: (($mtimes[$i] // 0) as $epoch |
            if $epoch > 0 then ($epoch | strftime("%Y-%m-%dT%H:%M:%SZ")) else null end)}})) as $artefacts |
      map(
        ($cards[.id] // null) as $card |
        (if (.verifier_artefact | type) == "string" then ($artefacts[.verifier_artefact] // null)
         else null end) as $artefact |
        . + {
          verifier_overall: (if $artefact == null then null else $artefact.overall end),
          orchestrator: (if $card == null then null else $card.orchestrator end),
          card: (if $card == null then null
            elif ($card.path | startswith($repo_path + "/")) then $card.path[($repo_path | length) + 1:]
            else $card.path end),
          event_at: (.completed_at // .started_at //
            (if $artefact == null then null else $artefact.at end))
        }) as $enriched |
      ([$enriched[] | select((.status == "pending" or .status == "in_progress") and .run_id != null) |
        .run_id] | last // null) as $run_id |
      [($enriched | tojson),
       ($run_id | tojson),
       (if $run_id == null then "[]"
        else ([$enriched[] | select(.run_id == $run_id)] | tojson) end),
       (if $run_id == null then "null"
        else ("\($run_id[4:8])-\($run_id[8:10])-\($run_id[10:12])T\($run_id[13:15]):\($run_id[15:17]):\($run_id[17:19])Z" | tojson)
        end)] | .[]')"
  else
    stages_json='[]'; state_error='"state.yaml unparseable"'
  fi

  alerts_json='[]'
  if [[ -x "$script_dir/scan-usage-limits.sh" ]]; then
    alerts_json="$("$script_dir/scan-usage-limits.sh" "$repo_path" 2>/dev/null \
      | jq -R -s -c 'split("\n") | map(select(length > 0)) |
        map(split("\t") | {log:.[0], line:(.[1] // ""), occurred_at:(.[2] // null)})' \
      || printf '[]')"
  fi

  # Registry pass: one jq per agent file for the three things the shell needs
  # to decide liveness, then one jq for the whole enriched array. The shape
  # this replaces spent seven jq invocations per agent and rewrote the growing
  # array on every row, which is the same accumulate-by-rewrite the stage list
  # was paying for.
  agent_rows=""
  if [[ -d "$active_agents_dir" ]]; then
    for agent_file in "$active_agents_dir"/*.json; do
      [[ -f "$agent_file" ]] || continue
      agent_pid=""; agent_log=""; registration=""
      {
        IFS= read -r agent_pid || agent_pid=""
        IFS= read -r agent_log || agent_log=""
        IFS= read -r registration || registration=""
      } <<<"$(jq -r '(.pid // 0), (.log_path // ""), tojson' "$agent_file" 2>/dev/null || true)"
      [[ -n "$registration" ]] || continue
      [[ "$agent_pid" =~ ^[0-9]+$ ]] || continue
      if ! kill -0 "$agent_pid" 2>/dev/null; then
        case ",$heartbeat_alive_pids," in *",$agent_pid,"*) ;; *) continue ;; esac
      fi
      agent_log_bytes=0
      if [[ -n "$agent_log" && -f "$agent_log" ]]; then
        agent_log_bytes="$(stat -f %z "$agent_log" 2>/dev/null \
          || stat -c %s "$agent_log" 2>/dev/null \
          || wc -c < "$agent_log" | tr -d ' ')"
      fi
      agent_rows+="$registration"$'\t'"${agent_log_bytes:-0}"$'\n'
    done
  fi
  agents_json='[]'
  if [[ -n "$agent_rows" ]]; then
    agents_json="$(printf '%s' "$agent_rows" | jq -R -s -c \
      --argjson hb "$heartbeat_json" --argjson now "$now_epoch" '
      def epoch: try (. | fromdateiso8601) catch $now;
      [splits("\n") | select(length > 0) | split("\t") |
        (.[0] | fromjson) as $reg | (.[1] | tonumber) as $log_bytes |
        ($hb.entries // [] | map(select(.pid == $reg.pid))[0] // {}) as $live |
        ($reg + {
          stage_id: ($reg.stage_id // ($reg.card_path // "unknown" | split("/")[-1] | sub("\\.md$"; ""))),
          elapsed_seconds: ($live.elapsed_seconds // ($now - (($reg.started_at // "") | epoch))),
          flags: ($live.flags // []),
          live_total_tokens: ($live.live_total_tokens // null),
          baseline_median_tokens: ($live.baseline_median_tokens // null),
          baseline_sample_size: ($live.baseline_sample_size // null),
          token_outlier: ($live.token_outlier // null),
          log_bytes:$log_bytes, alive:true
        }) | . + {elapsed:.elapsed_seconds}]')"
  fi

  # Live transcript token totals, --repo mode only: reading the harness
  # transcript for every live agent across five repos every 5s is the cost
  # the fleet-wide pass cannot afford (see docs/lessons.md gotcha 14 for why
  # the read has to be incremental at all), but a single-repo ticker refresh
  # can. Offsets are cached in the same active-agents registry file
  # scripts/agent-ticker.sh already used for this, so the two never disagree
  # about how much of a transcript has been consumed.
  if [[ -n "$repo_filter" && "$agents_json" != "[]" ]]; then
    agents_json="$(python3 "$script_dir/lib/transcript-tokens.py" "$active_agents_dir" \
      "${AUTOMETTA_CLAUDE_PROJECTS:-$HOME/.claude/projects}" \
      "${AUTOMETTA_CODEX_SESSIONS:-$HOME/.codex/sessions}" <<<"$agents_json" 2>/dev/null || printf '%s' "$agents_json")"
  fi

  # The queue and, below it, the stages done/outstanding/escalated counts for
  # the repo ticker's NEXT line: both aggregates over the full stages list, so
  # they belong here and not in the renderer (scripts/lib/repo-ticker-render.py:9,
  # card 63 criterion 9), and one pass answers both.
  {
    IFS= read -r queue_json; IFS= read -r queue_counts_json
  } <<<"$(printf '%s' "$stages_json" | jq -r \
    --argjson alert "$alert_statuses_json" --argjson live "$agents_json" '
    ([.[] | select(.status != "completed" and .status != "superseded") | .id] | unique) as $outstanding |
    (([.[] | select(.status as $s | $alert | index($s) != null) | .id] +
      [$live[] | select((.flags // []) | index("token-outlier")) | .stage_id]) | unique) as $escalated |
    [([.[] | select(.status == "pending") |
       {stage_id:.id, worker:(.worker // null), verifier:(.verifier // null)}] | tojson),
     ({done: ([.[] | select(.status == "completed")] | length),
       outstanding: ($outstanding | length),
       escalated: ([$escalated[] | select(. as $id | $outstanding | index($id))] | length)} | tojson)
    ] | .[]')"

  quota='{"read_at":null,"families":{"claude":{"family":"claude","status":"unknown","reason":"no tick reading","source":null,"fetched_at":null,"windows":[]},"codex":{"family":"codex","status":"unknown","reason":"no tick reading","source":null,"fetched_at":null,"windows":[]}}}'
  if [[ -f "$quota_path" ]]; then
    quota="$(jq -c '
      {read_at:(.read_at // null), families:{
        claude:(.families.claude // {family:"claude",status:"unknown",reason:"missing from tick reading",source:null,fetched_at:null,windows:[]}),
        codex:(.families.codex // {family:"codex",status:"unknown",reason:"missing from tick reading",source:null,fetched_at:null,windows:[]})}}
    ' "$quota_path" 2>/dev/null || printf '%s' "$quota")"
  fi

  spend='{"scope":"today_utc","input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"tokens_total":0,"cost_usd_est":0,"productive":{"tokens":0,"cost_usd_est":0},"lost":{"tokens":0,"cost_usd_est":0},"lost_seven_day":{"tokens":0,"cost_usd_est":0},"openai_zero_output_caveat":false,"by_role":[],"by_stage":[],"failures":[],"last_dispatch_at":null,"seven_day_cost_usd_est":0,"last_hour_tokens":0,"history":{"summary":{"card_count":0,"lost_seven_day_tokens":0,"lost_seven_day_marked":false,"seven_day_cost_usd_est":0,"seven_day_cost_marked":false},"cards":[],"fortnight":{"by_day":[],"by_model":[]}}}'
  if [[ -f "$cost_log_path" ]]; then
    spend="$(jq -s -c --argjson now "$now_epoch" --argjson today "$today_epoch" '
      # epoch, token sum and the zero-output test are asked of every row by
      # thirty-odd separate comprehensions below, and the fortnight chart asks
      # fourteen more times again. Answering them once per row on the way in
      # turns a date parse and a regex per row per pass into a field read: on
      # a five-thousand-row log that is most of the query. The three carrier
      # fields never reach the payload, which builds its objects by name.
      def parse_epoch: try (.ts | fromdateiso8601) catch 0;
      def sum_tokens: ((.input_tokens // 0) + (.cached_input_tokens // 0) + (.output_tokens // 0));
      def read_zero_output:
        (((.identity // "") | test("gpt|codex"; "i")) and
         ((.usage_status // "recorded") == "recorded") and
         (((.input_tokens // 0) + (.cached_input_tokens // 0)) > 0) and
         ((.output_tokens // 0) == 0));
      def epoch: .row_epoch;
      def tok: .row_tokens;
      def zero_output_read: .row_zero_output;
      def dispatch_tokens: (.total_tokens // .row_tokens);
      def dispatch_cost: (.total_cost_usd_est // .cost_usd_est // 0);
      def totals($rows): {
        input_tokens: ([$rows[] | .input_tokens // 0] | add // 0),
        cached_input_tokens: ([$rows[] | .cached_input_tokens // 0] | add // 0),
        output_tokens: ([$rows[] | .output_tokens // 0] | add // 0),
        tokens: ([$rows[] | tok] | add // 0),
        cost_usd_est: ([$rows[] | .cost_usd_est // 0] | add // 0)
      };
      [.[] | select(type == "object") | . + {
        row_epoch: parse_epoch, row_tokens: sum_tokens, row_zero_output: read_zero_output}] as $all |
      [$all[] | select(epoch >= $today)] as $rows |
      [$rows[] | select((.result // "") == "pass")] as $pass |
      [$rows[] | select((.result // "") != "pass")] as $lost |
      [$all[] | select(epoch >= ($today - 518400))] as $week_rows |
      [$week_rows[] | select((.result // "") != "pass")] as $lost_week |
      [$all[] | select((.role // "") != "phat-controller")] as $dispatches |
      [$dispatches[] | select(epoch >= ($today - 1123200))] as $fortnight_rows |
      ([$fortnight_rows[] | dispatch_cost] | add // 0) as $fortnight_cost |
      # The fortnight chart used to re-scan the fortnight twice per day drawn,
      # twenty-eight passes over the log for fourteen numbers. One reduce
      # buckets by UTC midnight instead, in the same row order, so each day
      # sums the same values in the same sequence it did before.
      (reduce $fortnight_rows[] as $row ({};
        (($row.row_epoch - ($row.row_epoch % 86400)) | tostring) as $day |
        .[$day] = {
          cost_usd_est: ((.[$day].cost_usd_est // 0) + ($row | dispatch_cost)),
          marked: ((.[$day].marked // false) or $row.row_zero_output)})) as $fortnight_by_day |
      (totals($rows)) as $t |
      {scope:"today_utc", input_tokens:$t.input_tokens,
       cached_input_tokens:$t.cached_input_tokens, output_tokens:$t.output_tokens,
       tokens_total:$t.tokens, cost_usd_est:$t.cost_usd_est,
       productive:(totals($pass) | {tokens, cost_usd_est}),
       lost:(totals($lost) | {tokens, cost_usd_est}),
       lost_seven_day:(totals($lost_week) | {tokens, cost_usd_est}),
       openai_zero_output_caveat: (any($week_rows[]?; zero_output_read)),
       by_role: ([$rows | group_by(.role)[] | . as $role_rows |
         (totals($role_rows)) + {role:($role_rows[0].role // "unknown"),
           productive_tokens:([$role_rows[] | select((.result // "") == "pass") | tok] | add // 0),
           lost_tokens:([$role_rows[] | select((.result // "") != "pass") | tok] | add // 0)}]),
       by_stage: ([$all | group_by(.stage_id)[] | . as $stage_rows |
         (totals($stage_rows)) + {stage_id:($stage_rows[0].stage_id // "unknown")}]),
       failures: ([$all[] | select((.result // "") != "pass" and epoch >= ($today - 518400)) |
         {ts, stage_id, role, result, input_tokens:(.input_tokens // 0),
          cached_input_tokens:(.cached_input_tokens // 0), output_tokens:(.output_tokens // 0),
          tokens_lost:tok, cost_usd_est:(.cost_usd_est // 0)}] | sort_by(.ts) | reverse),
       last_dispatch_at: ([$all[] | select(epoch > 0) | .ts] | max // null),
       seven_day_cost_usd_est: ([$all[] | select(epoch >= ($today - 518400)) | .cost_usd_est // 0] | add // 0),
       last_hour_tokens: ([$all[] | select(epoch >= ($now - 3600)) | tok] | add // 0),
       history: {
         summary: {
           card_count: ([$dispatches[].stage_id] | unique | length),
           lost_seven_day_tokens: ([$dispatches[] |
             select(epoch >= ($today - 518400) and (.result // "") != "pass") |
             dispatch_tokens] | add // 0),
           lost_seven_day_marked: (any($dispatches[]?;
             epoch >= ($today - 518400) and (.result // "") != "pass" and zero_output_read)),
           seven_day_cost_usd_est: ([$dispatches[] |
             select(epoch >= ($today - 518400)) | dispatch_cost] | add // 0),
           seven_day_cost_marked: (any($dispatches[]?;
             epoch >= ($today - 518400) and zero_output_read))
         },
         cards: ([$dispatches | group_by(.stage_id)[] | sort_by(.ts) as $stage_rows |
           {
             id: ($stage_rows[0].stage_id // "unknown"),
             result: (($stage_rows[-1].result // "unknown") | ascii_upcase),
             attempts: ([$stage_rows | group_by(.role)[] | length] | max // 0),
             tokens: ([$stage_rows[] | dispatch_tokens] | add // 0),
             tokens_marked: (any($stage_rows[]?; zero_output_read)),
             lost_tokens: ([$stage_rows[] | select((.result // "") != "pass") |
               dispatch_tokens] | add // 0),
             lost_marked: (any($stage_rows[]?;
               (.result // "") != "pass" and zero_output_read)),
             cost_usd_est: ([$stage_rows[] | dispatch_cost] | add // 0),
             cost_marked: (any($stage_rows[]?; zero_output_read)),
             worker: ([$stage_rows[] | select(.role == "worker") | .identity] | last // null),
             verifier: ([$stage_rows[] | select(.role == "verifier") | .identity] | last // null),
             last_dispatch_at: ([$stage_rows[].ts] | max // null),
             dispatches: ([$stage_rows[] | {
               role: (.role // "unknown"), result: ((.result // "unknown") | ascii_upcase),
               tokens: dispatch_tokens, tokens_marked: zero_output_read,
               cost_usd_est: dispatch_cost, cost_marked: zero_output_read,
               when: (.ts // null), identity: (.identity // null)
             }] | sort_by(.when) | reverse)
           }] | sort_by(.last_dispatch_at) | reverse),
         fortnight: {
           by_day: ([range(0; 14) as $offset |
             ($today - ((13 - $offset) * 86400)) as $day |
             ($fortnight_by_day[$day | tostring] // {}) as $bucket |
             {day: ($day | strftime("%Y-%m-%d")),
              cost_usd_est: ($bucket.cost_usd_est // 0),
              marked: ($bucket.marked // false)}]),
           by_model: ([$fortnight_rows | group_by(.identity)[] | . as $model_rows |
             ([$model_rows[] | dispatch_cost] | add // 0) as $model_cost |
             {identity: ($model_rows[0].identity // "unknown"),
              cost_usd_est: $model_cost,
              share_percent: (if $fortnight_cost > 0
                then (($model_cost * 100 / $fortnight_cost) | round) else 0 end),
              marked: (any($model_rows[]?; zero_output_read))}] |
             sort_by(.cost_usd_est) | reverse)
         }
       }}
    ' "$cost_log_path" 2>/dev/null || printf '%s' "$spend")"
  fi

  # The spend block arrives on stdin, not in argv. It carries a dispatch object
  # per cost-log row, so a subscriber with a few thousand rows pushes it past
  # ARG_MAX and jq dies with "Argument list too long" -- taking the whole row
  # with it, at exactly the scale where the figures matter most. Same reason
  # scripts/repo-light.sh reads its row in. The current run is built here too
  # rather than in a jq of its own: it needs the same spend block, and asking
  # for it twice meant parsing it twice.
  repo_row="$(printf '%s' "$spend" | jq -nc \
    --argjson current_run_id "$current_run_id" \
    --argjson current_run_started_at "$current_run_started_at" \
    --argjson current_run_stages "$current_run_stages" \
    --arg name "$name" --arg repo_path "$repo_path" \
    --argjson enabled "$([[ "$enabled" == true ]] && printf true || printf false)" \
    --argjson tokens_spent "${tokens_spent:-0}" --argjson token_cap_total "${token_cap_total:-0}" \
    --argjson effective_token_cap "${effective_token_cap:-0}" --arg cap_source "${cap_source:-host-default}" \
    --argjson halted "$([[ "$halted" == true ]] && printf true || printf false)" \
    --argjson halt_reason "$halt_reason" --argjson consecutive_failures "${consecutive_failures:-0}" \
    --argjson consecutive_failure_cap "${consecutive_failure_cap:-0}" \
    --argjson paused_until "$paused_until" --argjson paused_reason "$paused_reason" \
    --argjson last_tick_at "$last_tick_at" --argjson tick_count "${tick_count:-0}" \
    --argjson current_stage "$current_stage" --argjson run_started_at "$run_started_at" \
    --argjson verifier_attempt_cap 3 \
    --argjson stages "$stages_json" --argjson alerts "$alerts_json" --argjson agents "$agents_json" \
    --argjson queue "$queue_json" --argjson queue_counts "$queue_counts_json" \
    --argjson quota "$quota" --argjson state_error "$state_error" \
    --argjson heartbeat_checked_at "$heartbeat_checked_at" --argjson drain_active "$drain_active" \
    --argjson heartbeat_baselines "$heartbeat_baselines" \
    --argjson heartbeat_outlier_policy "$heartbeat_outlier_policy" \
    --argjson drain_cap "$drain_cap" --argjson drain_expires_at "$drain_expires_at" \
    --argjson vendor_stale "$([[ "$vendor_stale" == true ]] && printf true || printf false)" \
    --argjson vendor_from "$vendor_from" --arg vendor_current "$autometta_current_sha" \
    --argjson build_check "$build_check" '
    input as $spend |
    (if $current_run_id == null then null else {
      id:$current_run_id,
      started_at:$current_run_started_at,
      stages:$current_run_stages,
      tokens_total: ([$current_run_stages[] as $stage |
        ([$spend.by_stage[]? | select(.stage_id == $stage.id)][0].tokens // $stage.tokens // 0)] |
        add // 0),
      cost_usd_est: ([$current_run_stages[] as $stage |
        ([$spend.by_stage[]? | select(.stage_id == $stage.id)][0].cost_usd_est // 0)] |
        add // 0)
    } end) as $current_run |
    {name:$name, repo_path:$repo_path, enabled:$enabled, tokens_spent:$tokens_spent,
     token_cap_total:$token_cap_total, effective_token_cap:$effective_token_cap, cap_source:$cap_source,
     halted:$halted, halt_reason:$halt_reason,
     consecutive_failures:$consecutive_failures, consecutive_failure_cap:$consecutive_failure_cap,
     paused_until:$paused_until, paused_reason:$paused_reason,
     last_tick_at:$last_tick_at, tick_count:$tick_count, current_stage:$current_stage,
     run_started_at:$run_started_at, verifier_attempt_cap:$verifier_attempt_cap,
     current_run:$current_run,
     state_error:$state_error, heartbeat_checked_at:$heartbeat_checked_at,
     heartbeat_baselines:$heartbeat_baselines, heartbeat_outlier_policy:$heartbeat_outlier_policy,
     drain_active:$drain_active, drain_cap:$drain_cap, drain_expires_at:$drain_expires_at,
     vendor_stale:$vendor_stale, vendor_from:$vendor_from, vendor_current:$vendor_current,
     build_check:$build_check,
     queue_depth:($queue|length), in_flight:([$stages[] | select(.status == "in_progress")] | length),
     alerts:$alerts, agents:$agents, active_agents:$agents, queue:$queue, queue_counts:$queue_counts,
     stages:$stages, spend:$spend, history:$spend.history, quota:$quota,
     today_tokens:$spend.tokens_total, today_cost_usd_est:$spend.cost_usd_est,
     seven_day_cost_usd_est:$spend.seven_day_cost_usd_est,
     last_hour_tokens:$spend.last_hour_tokens, last_dispatch_at:$spend.last_dispatch_at}')"
  IFS=$'\t' read -r light reason <<<"$(repo_light "$repo_row" "$now_epoch")"
  repo_row="$(printf '%s' "$repo_row" | jq -c --arg light "$light" --arg reason "$reason" \
    '. + {light:$light, light_reason:$reason}')"
  # --repo prints this row and leaves; appending it to a fleet array nothing
  # downstream reads was a whole jq and a file rewrite spent on the way out.
  if [[ -n "$repo_filter" ]]; then
    printf '%s\n' "$repo_row"
    exit 0
  fi

  printf '%s' "$repo_row" | jq -n --slurpfile rows "$repos_array_file" \
    'input as $row | $rows[0] + [$row]' > "${repos_array_file}.next"
  mv "${repos_array_file}.next" "$repos_array_file"
done

if [[ -n "$repo_filter" ]]; then
  printf 'aggregate-dashboard.sh: no enabled subscriber matches --repo %s\n' "$repo_filter" >&2
  exit 1
fi

repos_json="$(jq -c '.' "$repos_array_file")"
by_model_json="$(printf '%s' "$repos_json" | jq -c '[.[].stages[]? |
  [(if .worker != null then {identity:.worker,tokens:(.worker_tokens // 0)} else empty end),
   (if .verifier != null then {identity:.verifier,tokens:(.verifier_tokens // 0)} else empty end),
   (if .orchestrator != null then {identity:.orchestrator,tokens:0} else empty end)] | .[]] |
  group_by(.identity) | map({identity:.[0].identity,tokens:(map(.tokens)|add)}) | sort_by(-.tokens,.identity)')"
by_day_json="$(printf '%s' "$repos_json" | jq -c '[.[].stages[]? |
  select(.completed_at != null and (.tokens // 0) > 0) |
  {date:.completed_at[0:10],tokens:(.tokens // 0)}] | group_by(.date) |
  map({date:.[0].date,tokens:(map(.tokens)|add)}) | sort_by(.date)')"
fleet_totals_json="$(printf '%s' "$repos_json" | jq -c '{
  enabled_repos:([.[]|select(.enabled)]|length),
  today_tokens:([.[]|select(.enabled)|.spend.tokens_total]|add // 0),
  today_cost_usd_est:([.[]|select(.enabled)|.spend.cost_usd_est]|add // 0),
  window_tokens_spent:([.[]|select(.enabled)|.tokens_spent]|add // 0),
  window_token_cap_total:([.[]|select(.enabled)|.token_cap_total]|add // 0)}')"
spend_json="$(printf '%s' "$repos_json" | jq -c '
  [.[] | select(.enabled)] as $repos |
  {scope:"today_utc", input_tokens:([$repos[].spend.input_tokens]|add // 0),
   cached_input_tokens:([$repos[].spend.cached_input_tokens]|add // 0),
   output_tokens:([$repos[].spend.output_tokens]|add // 0),
   tokens_total:([$repos[].spend.tokens_total]|add // 0),
   cost_usd_est:([$repos[].spend.cost_usd_est]|add // 0),
   productive:{tokens:([$repos[].spend.productive.tokens]|add // 0),cost_usd_est:([$repos[].spend.productive.cost_usd_est]|add // 0)},
   lost:{tokens:([$repos[].spend.lost.tokens]|add // 0),cost_usd_est:([$repos[].spend.lost.cost_usd_est]|add // 0)},
   by_repo_role:([$repos[] as $repo | $repo.spend.by_role[]? | . + {repo:$repo.name}] | sort_by(.repo,.role)),
   failures:([$repos[] as $repo | $repo.spend.failures[]? | . + {repo:$repo.name}] | sort_by(.ts) | reverse)}')"
drain_json="$(printf '%s' "$repos_json" | jq -c '
  [.[] | select(.enabled and .drain_active)] as $active |
  {active:($active|length > 0), cap:($active[0].drain_cap // null),
   expires_at:($active[0].drain_expires_at // null), repos:[$active[].name]}')"

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
data_tmp="$(new_tmp)"
jq -n --arg generated_at "$generated_at" --slurpfile repos_file "$repos_array_file" \
  --argjson by_model "$by_model_json" --argjson by_day "$by_day_json" \
  --argjson fleet_totals "$fleet_totals_json" --argjson spend "$spend_json" \
  --argjson drain "$drain_json" \
  '$repos_file[0] as $repos |
   {generated_at:$generated_at,repos:$repos,by_model:$by_model,by_day:$by_day,
    fleet_totals:$fleet_totals,spend:$spend,drain:$drain,
    drain_active:$drain.active,drain_cap:$drain.cap,drain_expires_at:$drain.expires_at}' > "$data_tmp"
mv "$data_tmp" "$data_json"

js_tmp="$(new_tmp)"
{ printf 'window.AUTOMETTA_DATA = '; jq -c '.' "$data_json"; printf ';\n'; } > "$js_tmp"
mv "$js_tmp" "$data_js"

printf 'wrote %s and %s\n' "$data_json" "$data_js"

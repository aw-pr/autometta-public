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

mkdir -p "$dashboard_dir"
aggregate_tmp="$(mktemp -d)"
new_tmp() { mktemp "$aggregate_tmp/item.XXXXXX"; }
cleanup() {
  case "$aggregate_tmp" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$aggregate_tmp" ;; esac
}
trap cleanup EXIT

read_field() {
  local file_path="$1" key="$2" raw
  raw="$(sed -n "s/^${key}:[[:space:]]*//p" "$file_path" 2>/dev/null | head -n1)"
  raw="${raw%\"}"; raw="${raw#\"}"
  raw="${raw%\'}"; raw="${raw#\'}"
  printf '%s' "$raw"
}

state_yaml_to_json() { yq -o=json '.' "$1"; }

epoch_iso() {
  local epoch="${1:-0}"
  [[ "$epoch" =~ ^[0-9]+$ && "$epoch" -gt 0 ]] || return 0
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || true
}

file_mtime_iso() {
  local path="$1" epoch
  epoch="$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || true)"
  epoch_iso "$epoch"
}

repos_array_file="$(new_tmp)"
printf '[]\n' > "$repos_array_file"

for subscriber_file in "$subscribers_dir"/*.yaml; do
  [[ -e "$subscriber_file" ]] || continue
  [[ "$(basename "$subscriber_file")" == template.yaml ]] && continue

  enabled="$(read_field "$subscriber_file" enabled)"
  repo_path="$(read_field "$subscriber_file" repo_path)"
  manifest_path="$(read_field "$subscriber_file" manifest_path)"
  name="$(basename "$subscriber_file" .yaml)"
  [[ -n "$repo_path" ]] || continue

  if [[ -n "$repo_filter" ]]; then
    repo_path_resolved="$(cd "$repo_path" 2>/dev/null && pwd -P || printf '%s' "$repo_path")"
    [[ "$repo_path_resolved" == "$repo_filter_resolved" || "$repo_path" == "$repo_filter" ]] || continue
  fi

  card_globs=()
  if [[ -n "$manifest_path" && -f "$manifest_path" ]]; then
    while IFS= read -r g; do [[ -n "$g" ]] && card_globs+=("$g"); done \
      < <(yq -r '.stage_card_globs[]? // empty' "$manifest_path" 2>/dev/null || true)
  fi
  card_globs+=("stage-cards/*.md")
  # Legacy fallbacks for subscribers that have not migrated their cards yet.
  card_globs+=("docs/stages/*.md" "examples/self-host/*.md")

  find_card_for_stage() {
    local sid="$1" g cand search
    for g in "${card_globs[@]}"; do
      if [[ "$g" = /* ]]; then search="$g"; else search="$repo_path/$g"; fi
      for cand in $search; do
        [[ -f "$cand" ]] || continue
        if [[ "$(basename "$cand" .md)" == "$sid" ]]; then printf '%s\n' "$cand"; return 0; fi
      done
    done
    return 1
  }

  card_orchestrator_for_stage() {
    local card
    card="$(find_card_for_stage "$1")" || return 0
    grep -E '^- \*\*Orchestrator:\*\*' "$card" 2>/dev/null | head -n1 \
      | sed -E 's/^- \*\*Orchestrator:\*\*[[:space:]]*//'
  }

  state_yaml="$repo_path/state/state.yaml"
  budget_path="$repo_path/state/budget.json"
  cost_log_path="$repo_path/state/cost-log.jsonl"
  quota_path="$repo_path/state/quota-window.json"
  active_agents_dir="$repo_path/state/active-agents"
  heartbeat_path="$repo_path/state/heartbeat.json"

  tokens_spent=0; token_cap_total=0; halted=false; halt_reason=null
  consecutive_failures=0; consecutive_failure_cap=0
  paused_until=null; paused_reason=null
  if [[ -f "$budget_path" ]] && budget_json="$(jq -c '.' "$budget_path" 2>/dev/null)"; then
    tokens_spent="$(printf '%s' "$budget_json" | jq -r '.tokens_spent // 0')"
    token_cap_total="$(printf '%s' "$budget_json" | jq -r '.token_cap_total // 0')"
    halted="$(printf '%s' "$budget_json" | jq -r '.halted // false')"
    halt_reason="$(printf '%s' "$budget_json" | jq -c '.halt_reason // null')"
    consecutive_failures="$(printf '%s' "$budget_json" | jq -r '.consecutive_failures // 0')"
    consecutive_failure_cap="$(printf '%s' "$budget_json" | jq -r '.consecutive_failure_cap // 0')"
    paused_until="$(printf '%s' "$budget_json" | jq -c '.paused_until // null')"
    paused_reason="$(printf '%s' "$budget_json" | jq -c '.paused_reason // null')"
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
  heartbeat_checked_at="$(printf '%s' "$heartbeat_json" | jq -c '.checked_at // null')"
  heartbeat_baselines="$(printf '%s' "$heartbeat_json" | jq -c '.baselines // {}')"
  heartbeat_outlier_policy="$(printf '%s' "$heartbeat_json" | jq -c '.outlier_policy // {}')"

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
  current_run_id=null; current_run_started_at=null; current_run_stages='[]'; current_run=null
  if [[ ! -r "$state_yaml" ]]; then
    state_error='"state.yaml unreadable"'
  elif state_doc="$(state_yaml_to_json "$state_yaml" 2>/dev/null)" \
    && stages_json="$(printf '%s' "$state_doc" | jq -c '[.stages[]? | {
      id, run_id:(.run_id // null), status:(.status // "pending"),
      worker:(.worker // null), verifier:(.verifier // null),
      started_at:(.started_at // null), completed_at:(.completed_at // null), tokens:(.tokens // 0),
      worker_tokens:(.worker_tokens // null), verifier_tokens:(.verifier_tokens // null),
      commit:(.commit // null), verifier_artefact:(.verifier_artefact // null),
      integration:(.integration // null), required_action:(.required_action // null),
      verifier_attempts:(.verifier_attempts // 0), wip_branch:(.wip_branch // null),
      wip_commit:(.wip_commit // null), stall_marker:(.stall_marker // null)
    }]')"; then
    last_tick_at="$(printf '%s' "$state_doc" | jq -c '.last_tick_at // null')"
    tick_count="$(printf '%s' "$state_doc" | jq -r '.tick_count // 0')"
    current_stage="$(printf '%s' "$state_doc" | jq -c '.current_stage // null')"
    run_started_at="$(printf '%s' "$stages_json" | jq -c '[.[] | .started_at // empty] | min // null')"
    merged_file="$(new_tmp)"; printf '[]\n' > "$merged_file"
    while IFS= read -r stage_entry; do
      [[ -n "$stage_entry" ]] || continue
      sid="$(printf '%s' "$stage_entry" | jq -r '.id')"
      artefact_rel="$(printf '%s' "$stage_entry" | jq -r '.verifier_artefact // empty')"
      verifier_overall=null; artefact_at=null
      if [[ -n "$artefact_rel" && -f "$repo_path/$artefact_rel" ]]; then
        verifier_overall="$(jq -c '.overall // null' "$repo_path/$artefact_rel" 2>/dev/null || printf null)"
        artefact_stamp="$(file_mtime_iso "$repo_path/$artefact_rel")"
        [[ -n "$artefact_stamp" ]] && artefact_at="$(jq -nc --arg value "$artefact_stamp" '$value')"
      fi
      orchestrator="$(card_orchestrator_for_stage "$sid" || true)"
      orchestrator_json=null
      [[ -z "$orchestrator" ]] || orchestrator_json="$(jq -nc --arg value "$orchestrator" '$value')"
      card_path="$(find_card_for_stage "$sid" || true)"
      card_rel="${card_path#"$repo_path"/}"
      card_json=null
      [[ -z "$card_path" ]] || card_json="$(jq -nc --arg value "$card_rel" '$value')"
      enriched="$(printf '%s' "$stage_entry" | jq -c \
        --argjson overall "$verifier_overall" --argjson orchestrator "$orchestrator_json" \
        --argjson artefact_at "$artefact_at" --argjson card "$card_json" \
        '. + {verifier_overall:$overall, orchestrator:$orchestrator,
          card:$card, event_at:(.completed_at // .started_at // $artefact_at)}')"
      jq --argjson row "$enriched" '. + [$row]' "$merged_file" > "${merged_file}.next"
      mv "${merged_file}.next" "$merged_file"
    done < <(printf '%s' "$stages_json" | jq -c '.[]')
    stages_json="$(jq -c '.' "$merged_file")"
    current_run_id="$(printf '%s' "$stages_json" | jq -c '
      [.[] | select((.status == "pending" or .status == "in_progress") and .run_id != null) |
        .run_id] | last // null')"
    if [[ "$current_run_id" != "null" ]]; then
      current_run_stages="$(printf '%s' "$stages_json" | jq -c --argjson run_id "$current_run_id" \
        '[.[] | select(.run_id == $run_id)]')"
      current_run_started_at="$(jq -nc --argjson run_id "$current_run_id" '
        $run_id as $id |
        "\($id[4:8])-\($id[8:10])-\($id[10:12])T\($id[13:15]):\($id[15:17]):\($id[17:19])Z"')"
    fi
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

  agents_file="$(new_tmp)"; printf '[]\n' > "$agents_file"
  if [[ -d "$active_agents_dir" ]]; then
    for agent_file in "$active_agents_dir"/*.json; do
      [[ -f "$agent_file" ]] || continue
      registration="$(jq -c '.' "$agent_file" 2>/dev/null || true)"
      [[ -n "$registration" ]] || continue
      agent_pid="$(printf '%s' "$registration" | jq -r '.pid // 0')"
      [[ "$agent_pid" =~ ^[0-9]+$ ]] || continue
      if ! kill -0 "$agent_pid" 2>/dev/null; then
        heartbeat_alive="$(printf '%s' "$heartbeat_json" | jq -r --argjson pid "$agent_pid" \
          'any(.entries[]?; .pid == $pid and .alive == true)')"
        [[ "$heartbeat_alive" == "true" ]] || continue
      fi
      agent_log="$(printf '%s' "$registration" | jq -r '.log_path // empty')"
      agent_log_bytes=0
      if [[ -n "$agent_log" && -f "$agent_log" ]]; then
        agent_log_bytes="$(wc -c < "$agent_log" | tr -d ' ')"
      fi
      agent="$(jq -nc --argjson reg "$registration" --argjson hb "$heartbeat_json" \
        --argjson now "$now_epoch" --argjson log_bytes "${agent_log_bytes:-0}" '
        def epoch: try (. | fromdateiso8601) catch $now;
        ($hb.entries // [] | map(select(.pid == $reg.pid))[0] // {}) as $live |
        $reg + {
          stage_id: ($reg.stage_id // ($reg.card_path // "unknown" | split("/")[-1] | sub("\\.md$"; ""))),
          elapsed_seconds: ($live.elapsed_seconds // ($now - (($reg.started_at // "") | epoch))),
          flags: ($live.flags // []),
          live_total_tokens: ($live.live_total_tokens // null),
          baseline_median_tokens: ($live.baseline_median_tokens // null),
          baseline_sample_size: ($live.baseline_sample_size // null),
          token_outlier: ($live.token_outlier // null),
          log_bytes:$log_bytes, alive:true
        }')"
      agent="$(printf '%s' "$agent" | jq -c '. + {elapsed:.elapsed_seconds}')"
      jq --argjson row "$agent" '. + [$row]' "$agents_file" > "${agents_file}.next"
      mv "${agents_file}.next" "$agents_file"
    done
  fi
  agents_json="$(jq -c '.' "$agents_file")"

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

  queue_json="$(printf '%s' "$stages_json" | jq -c '[.[] | select(.status == "pending") |
    {stage_id:.id, worker:(.worker // null), verifier:(.verifier // null)}]')"

  # Stages done/outstanding/escalated for the repo ticker's NEXT counts line:
  # an aggregate over the full stages list, so it belongs here and not in the
  # renderer (scripts/lib/repo-ticker-render.py:9, card 63 criterion 9).
  queue_counts_json="$(printf '%s' "$stages_json" | jq -c \
    --argjson alert "$alert_statuses_json" --argjson live "$agents_json" '
    ([.[] | select(.status != "completed" and .status != "superseded") | .id] | unique) as $outstanding |
    (([.[] | select(.status as $s | $alert | index($s) != null) | .id] +
      [$live[] | select((.flags // []) | index("token-outlier")) | .stage_id]) | unique) as $escalated |
    {done: ([.[] | select(.status == "completed")] | length),
     outstanding: ($outstanding | length),
     escalated: ([$escalated[] | select(. as $id | $outstanding | index($id))] | length)}
  ')"

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
      def epoch: try (.ts | fromdateiso8601) catch 0;
      def tok: ((.input_tokens // 0) + (.cached_input_tokens // 0) + (.output_tokens // 0));
      def dispatch_tokens: (.total_tokens // tok);
      def dispatch_cost: (.total_cost_usd_est // .cost_usd_est // 0);
      def zero_output_read:
        (((.identity // "") | test("gpt|codex"; "i")) and
         ((.usage_status // "recorded") == "recorded") and
         (((.input_tokens // 0) + (.cached_input_tokens // 0)) > 0) and
         ((.output_tokens // 0) == 0));
      def totals($rows): {
        input_tokens: ([$rows[] | .input_tokens // 0] | add // 0),
        cached_input_tokens: ([$rows[] | .cached_input_tokens // 0] | add // 0),
        output_tokens: ([$rows[] | .output_tokens // 0] | add // 0),
        tokens: ([$rows[] | tok] | add // 0),
        cost_usd_est: ([$rows[] | .cost_usd_est // 0] | add // 0)
      };
      [.[] | select(type == "object")] as $all |
      [$all[] | select(epoch >= $today)] as $rows |
      [$rows[] | select((.result // "") == "pass")] as $pass |
      [$rows[] | select((.result // "") != "pass")] as $lost |
      [$all[] | select(epoch >= ($today - 518400))] as $week_rows |
      [$week_rows[] | select((.result // "") != "pass")] as $lost_week |
      [$all[] | select((.role // "") != "phat-controller")] as $dispatches |
      [$dispatches[] | select(epoch >= ($today - 1123200))] as $fortnight_rows |
      ([$fortnight_rows[] | dispatch_cost] | add // 0) as $fortnight_cost |
      (totals($rows)) as $t |
      {scope:"today_utc", input_tokens:$t.input_tokens,
       cached_input_tokens:$t.cached_input_tokens, output_tokens:$t.output_tokens,
       tokens_total:$t.tokens, cost_usd_est:$t.cost_usd_est,
       productive:(totals($pass) | {tokens, cost_usd_est}),
       lost:(totals($lost) | {tokens, cost_usd_est}),
       lost_seven_day:(totals($lost_week) | {tokens, cost_usd_est}),
       openai_zero_output_caveat: (any($week_rows[]?;
         ((.identity // "") | test("gpt|codex"; "i")) and
         ((.usage_status // "recorded") == "recorded") and
         (((.input_tokens // 0) + (.cached_input_tokens // 0)) > 0) and
         ((.output_tokens // 0) == 0))),
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
             {day: ($day | strftime("%Y-%m-%d")),
              cost_usd_est: ([$fortnight_rows[] |
                select(epoch >= $day and epoch < ($day + 86400)) | dispatch_cost] | add // 0),
              marked: (any($fortnight_rows[]?;
                epoch >= $day and epoch < ($day + 86400) and zero_output_read))}]),
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

  if [[ "$current_run_id" != "null" ]]; then
    current_run="$(jq -nc \
      --argjson id "$current_run_id" --argjson started_at "$current_run_started_at" \
      --argjson stages "$current_run_stages" --argjson spend "$spend" '
      {
        id:$id,
        started_at:$started_at,
        stages:$stages,
        tokens_total: ([$stages[] as $stage |
          ([$spend.by_stage[]? | select(.stage_id == $stage.id)][0].tokens // $stage.tokens // 0)] |
          add // 0),
        cost_usd_est: ([$stages[] as $stage |
          ([$spend.by_stage[]? | select(.stage_id == $stage.id)][0].cost_usd_est // 0)] |
          add // 0)
      }')"
  fi

  repo_row="$(jq -nc \
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
    --argjson current_run "$current_run" \
    --argjson verifier_attempt_cap 3 \
    --argjson stages "$stages_json" --argjson alerts "$alerts_json" --argjson agents "$agents_json" \
    --argjson queue "$queue_json" --argjson queue_counts "$queue_counts_json" \
    --argjson spend "$spend" --argjson quota "$quota" --argjson state_error "$state_error" \
    --argjson heartbeat_checked_at "$heartbeat_checked_at" --argjson drain_active "$drain_active" \
    --argjson heartbeat_baselines "$heartbeat_baselines" \
    --argjson heartbeat_outlier_policy "$heartbeat_outlier_policy" \
    --argjson drain_cap "$drain_cap" --argjson drain_expires_at "$drain_expires_at" \
    --argjson vendor_stale "$([[ "$vendor_stale" == true ]] && printf true || printf false)" \
    --argjson vendor_from "$vendor_from" --arg vendor_current "$autometta_current_sha" '
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
     queue_depth:($queue|length), in_flight:([$stages[] | select(.status == "in_progress")] | length),
     alerts:$alerts, agents:$agents, active_agents:$agents, queue:$queue, queue_counts:$queue_counts,
     stages:$stages, spend:$spend, history:$spend.history, quota:$quota,
     today_tokens:$spend.tokens_total, today_cost_usd_est:$spend.cost_usd_est,
     seven_day_cost_usd_est:$spend.seven_day_cost_usd_est,
     last_hour_tokens:$spend.last_hour_tokens, last_dispatch_at:$spend.last_dispatch_at}')"
  IFS=$'\t' read -r light reason <<<"$(repo_light "$repo_row" "$now_epoch")"
  repo_row="$(printf '%s' "$repo_row" | jq -c --arg light "$light" --arg reason "$reason" \
    '. + {light:$light, light_reason:$reason}')"
  jq --argjson row "$repo_row" '. + [$row]' "$repos_array_file" > "${repos_array_file}.next"
  mv "${repos_array_file}.next" "$repos_array_file"

  if [[ -n "$repo_filter" ]]; then
    printf '%s\n' "$repo_row"
    exit 0
  fi
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
jq -n --arg generated_at "$generated_at" --argjson repos "$repos_json" \
  --argjson by_model "$by_model_json" --argjson by_day "$by_day_json" \
  --argjson fleet_totals "$fleet_totals_json" --argjson spend "$spend_json" \
  --argjson drain "$drain_json" \
  '{generated_at:$generated_at,repos:$repos,by_model:$by_model,by_day:$by_day,
    fleet_totals:$fleet_totals,spend:$spend,drain:$drain,
    drain_active:$drain.active,drain_cap:$drain.cap,drain_expires_at:$drain.expires_at}' > "$data_tmp"
mv "$data_tmp" "$data_json"

js_tmp="$(new_tmp)"
{ printf 'window.AUTOMETTA_DATA = '; jq -c '.' "$data_json"; printf ';\n'; } > "$js_tmp"
mv "$js_tmp" "$data_js"

printf 'wrote %s and %s\n' "$data_json" "$data_js"

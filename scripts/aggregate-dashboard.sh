#!/usr/bin/env bash
# aggregate-dashboard.sh — walk subscribers, read each repo's state, emit
# ~/.phat-controller/dashboard/data.json with the schema defined in the
# stage-11 card. Read-only on adopter repos. bash 3.2 compatible.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
subscribers_dir="$controller_home/subscribers"
dashboard_dir="$controller_home/dashboard"
data_json="$dashboard_dir/data.json"

mkdir -p "$dashboard_dir"

# read_field <file> <key>: minimal yaml line reader (mirrors tick.sh).
# Returns first matching value, stripping surrounding quotes.
read_field() {
  local file_path="$1"
  local key="$2"
  local raw
  raw="$(sed -n "s/^${key}:[[:space:]]*//p" "$file_path" 2>/dev/null | head -n1)"
  raw="${raw%\"}"; raw="${raw#\"}"
  raw="${raw%\'}"; raw="${raw#\'}"
  printf '%s' "$raw"
}

state_yaml_to_json() {
  yq -o=json '.' "$1"
}

repos_array_file="$(mktemp)"
printf '[]\n' > "$repos_array_file"

for subscriber_file in "$subscribers_dir"/*.yaml; do
  [[ -e "$subscriber_file" ]] || continue
  [[ "$(basename "$subscriber_file")" == "template.yaml" ]] && continue

  enabled="$(read_field "$subscriber_file" "enabled")"
  repo_path="$(read_field "$subscriber_file" "repo_path")"
  manifest_path="$(read_field "$subscriber_file" "manifest_path")"
  name="$(basename "$subscriber_file" .yaml)"
  [[ -n "$repo_path" ]] || continue

  # Resolve stage-card glob patterns for this repo so we can pull
  # orchestrator identity from the card metadata. Mirrors tick.sh.
  card_globs=()
  if [[ -n "$manifest_path" && -f "$manifest_path" ]]; then
    while IFS= read -r g; do
      [[ -n "$g" ]] && card_globs+=("$g")
    done < <(yq -r '.stage_card_globs[]? // empty' "$manifest_path" 2>/dev/null || true)
  fi
  card_globs+=("docs/stages/*.md" "examples/self-host/*.md")

  find_card_for_stage() {
    local sid="$1" g cand
    for g in "${card_globs[@]}"; do
      local search
      if [[ "$g" = /* ]]; then search="$g"; else search="$repo_path/$g"; fi
      for cand in $search; do
        [[ -f "$cand" ]] || continue
        if [[ "$(basename "$cand" .md)" == "$sid" ]]; then
          printf '%s\n' "$cand"
          return 0
        fi
      done
    done
    return 1
  }

  card_orchestrator_for_stage() {
    local card
    card="$(find_card_for_stage "$1")" || return 0
    [[ -n "$card" && -f "$card" ]] || return 0
    grep -E '^- \*\*Orchestrator:\*\*' "$card" 2>/dev/null \
      | head -n1 \
      | sed -E 's/^- \*\*Orchestrator:\*\*[[:space:]]*//'
  }

  state_yaml="$repo_path/state/state.yaml"
  budget_path="$repo_path/state/budget.json"
  cost_log_path="$repo_path/state/cost-log.jsonl"
  active_agents_dir="$repo_path/state/active-agents"

  tokens_spent=0
  token_cap_total=0
  halted=false
  halt_reason=null
  consecutive_failures=0
  consecutive_failure_cap=0
  if [[ -f "$budget_path" ]]; then
    tokens_spent="$(jq -r '.tokens_spent // 0' "$budget_path")"
    token_cap_total="$(jq -r '.token_cap_total // 0' "$budget_path")"
    halted="$(jq -r '.halted // false' "$budget_path")"
    halt_reason="$(jq -c '.halt_reason // null' "$budget_path")"
    consecutive_failures="$(jq -r '.consecutive_failures // 0' "$budget_path")"
    consecutive_failure_cap="$(jq -r '.consecutive_failure_cap // 0' "$budget_path")"
  fi

  # The aggregator is the single fleet walker. Do the ledger roll-up here so
  # tmux renderers only read data.json and never walk subscriber repos.
  cost_rollup='{"today_tokens":0,"today_cost_usd_est":0,"seven_day_cost_usd_est":0,"last_hour_tokens":0,"last_dispatch_at":null}'
  if [[ -f "$cost_log_path" ]]; then
    now_epoch="$(date -u +%s)"
    cost_rollup="$(jq -s -c --argjson now "$now_epoch" '
      def tokens: ((.input_tokens // 0) + (.cached_input_tokens // 0) + (.output_tokens // 0));
      def epoch: try (.ts | fromdateiso8601) catch 0;
      ($now - ($now % 86400)) as $today |
      [ .[] | select(type == "object") ] as $rows |
      {
        today_tokens: ([$rows[] | select(epoch >= $today) | tokens] | add // 0),
        today_cost_usd_est: ([$rows[] | select(epoch >= $today) | (.cost_usd_est // 0)] | add // 0),
        seven_day_cost_usd_est: ([$rows[] | select(epoch >= ($today - 518400)) | (.cost_usd_est // 0)] | add // 0),
        last_hour_tokens: ([$rows[] | select(epoch >= ($now - 3600)) | tokens] | add // 0),
        last_dispatch_at: ([$rows[] | select(epoch > 0) | .ts] | max // null)
      }
    ' "$cost_log_path" 2>/dev/null || printf '%s' "$cost_rollup")"
  fi

  stages_json='[]'
  if [[ -f "$state_yaml" ]]; then
    # Build a stages array from state.yaml, defaulting absent token fields
    # to 0 / null so older entries still parse. Per stage 11 schema.
    stages_json="$(state_yaml_to_json "$state_yaml" | jq -c '
      [ .stages[]? | {
          id: .id,
          status: (.status // "pending"),
          worker: (.worker // null),
          verifier: (.verifier // null),
          started_at: (.started_at // null),
          completed_at: (.completed_at // null),
          tokens: (.tokens // 0),
          worker_tokens: (.worker_tokens // null),
          verifier_tokens: (.verifier_tokens // null),
          commit: (.commit // null),
          verifier_artefact: (.verifier_artefact // null),
          integration: (.integration // null),
          required_action: (.required_action // null)
        } ]')"

    # Read each verifier artefact for the .overall field and merge into
    # the matching stage entry. The artefact path is relative to repo_root.
    stages_with_artefact='[]'
    artefact_paths_file="$(mktemp)"
    printf '%s\n' "$stages_json" | jq -c '.[]' > "$artefact_paths_file"
    merged_file="$(mktemp)"
    printf '[]\n' > "$merged_file"
    while IFS= read -r stage_entry; do
      [[ -n "$stage_entry" ]] || continue
      sid="$(printf '%s' "$stage_entry" | jq -r '.id')"
      artefact_rel="$(printf '%s' "$stage_entry" | jq -r '.verifier_artefact // empty')"
      verifier_overall=null
      if [[ -n "$artefact_rel" && -f "$repo_path/$artefact_rel" ]]; then
        verifier_overall="$(jq -c '.overall // null' "$repo_path/$artefact_rel" 2>/dev/null || printf 'null')"
      fi
      orchestrator_str="$(card_orchestrator_for_stage "$sid" || true)"
      if [[ -n "$orchestrator_str" ]]; then
        orchestrator_json="$(jq -nc --arg s "$orchestrator_str" '$s')"
      else
        orchestrator_json='null'
      fi
      jq --argjson new "$(printf '%s' "$stage_entry" \
        | jq --argjson v "$verifier_overall" --argjson o "$orchestrator_json" \
          '. + {verifier_overall: $v, orchestrator: $o}')" \
        '. + [$new]' "$merged_file" > "${merged_file}.tmp"
      mv "${merged_file}.tmp" "$merged_file"
    done < "$artefact_paths_file"
    stages_json="$(cat "$merged_file")"
    rm -f "$artefact_paths_file" "$merged_file"
  fi

  # Provider limit alerts (usage/rate limit, overload, exhausted credit)
  # from recent agent logs. Report-only; a scan failure never breaks the
  # dashboard build.
  alerts_json='[]'
  if [[ -x "$script_dir/scan-usage-limits.sh" ]]; then
    alerts_json="$("$script_dir/scan-usage-limits.sh" "$repo_path" 2>/dev/null \
      | jq -R -s -c 'split("\n") | map(select(length > 0))
          | map(split("\t") | {log: .[0], line: (.[1] // ""), occurred_at: (.[2] // null)})' \
      || printf '[]')"
  fi

  # Live-agent rows are collected by the existing subscriber walk. The fleet
  # renderer reads only data.json and never reaches back into adopter repos.
  active_agents_json='[]'
  if [[ -d "$active_agents_dir" ]]; then
    active_agents_file="$(mktemp)"
    printf '[]\n' > "$active_agents_file"
    for agent_file in "$active_agents_dir"/*.json; do
      [[ -f "$agent_file" ]] || continue
      agent_pid="$(jq -r '.pid // 0' "$agent_file" 2>/dev/null || printf 0)"
      [[ "$agent_pid" =~ ^[0-9]+$ ]] || continue
      kill -0 "$agent_pid" 2>/dev/null || continue
      agent_log="$(jq -r '.log_path // empty' "$agent_file" 2>/dev/null || true)"
      agent_log_bytes=0
      if [[ -n "$agent_log" && -f "$agent_log" ]]; then
        agent_log_bytes="$(wc -c < "$agent_log" | tr -d ' ')"
      fi
      agent_stage="$(jq -r '.stage_id // empty' "$agent_file" 2>/dev/null || true)"
      if [[ -z "$agent_stage" ]]; then
        agent_card="$(jq -r '.card_path // empty' "$agent_file" 2>/dev/null || true)"
        agent_stage="$(basename "${agent_card:-unknown}" .md)"
      fi
      agent_entry="$(jq -c \
        --arg stage "$agent_stage" \
        --argjson log_bytes "${agent_log_bytes:-0}" \
        '. + {stage: $stage, log_bytes: $log_bytes}' "$agent_file" 2>/dev/null || true)"
      [[ -n "$agent_entry" ]] || continue
      jq --argjson row "$agent_entry" '. + [$row]' "$active_agents_file" \
        > "${active_agents_file}.tmp"
      mv "${active_agents_file}.tmp" "$active_agents_file"
    done
    active_agents_json="$(cat "$active_agents_file")"
    rm -f "$active_agents_file"
  fi

  # Append this repo to the repos array.
  jq \
    --arg name "$name" \
    --arg repo_path "$repo_path" \
    --argjson enabled "$([[ "$enabled" == "true" ]] && printf 'true' || printf 'false')" \
    --argjson tokens_spent "${tokens_spent:-0}" \
    --argjson token_cap_total "${token_cap_total:-0}" \
    --argjson halted "$([[ "$halted" == "true" ]] && printf 'true' || printf 'false')" \
    --argjson halt_reason "$halt_reason" \
    --argjson consecutive_failures "${consecutive_failures:-0}" \
    --argjson consecutive_failure_cap "${consecutive_failure_cap:-0}" \
    --argjson stages "$stages_json" \
    --argjson alerts "$alerts_json" \
    --argjson active_agents "$active_agents_json" \
    --argjson cost_rollup "$cost_rollup" \
    '. + [{
       name: $name,
       repo_path: $repo_path,
       enabled: $enabled,
       tokens_spent: $tokens_spent,
       token_cap_total: $token_cap_total,
       halted: $halted,
       halt_reason: $halt_reason,
       consecutive_failures: $consecutive_failures,
       consecutive_failure_cap: $consecutive_failure_cap,
       queue_depth: ([$stages[] | select(.status == "pending")] | length),
       in_flight: ([$stages[] | select(.status == "in_progress")] | length),
       alerts: $alerts,
       active_agents: $active_agents,
       stages: $stages
     } + $cost_rollup]' "$repos_array_file" > "${repos_array_file}.tmp"
  mv "${repos_array_file}.tmp" "$repos_array_file"
done

# by_model and by_day rollups, computed from the assembled repos array.
by_model_json="$(jq -c '
  [ .[].stages[]?
    | [
        (if (.worker // null) != null
            then {identity: .worker, tokens: (.worker_tokens // 0)} else empty end),
        (if (.verifier // null) != null
            then {identity: .verifier, tokens: (.verifier_tokens // 0)} else empty end),
        (if (.orchestrator // null) != null
            then {identity: .orchestrator, tokens: 0} else empty end)
      ]
    | .[]
  ]
  | group_by(.identity)
  | map({identity: .[0].identity, tokens: (map(.tokens) | add)})
  | sort_by(-.tokens, .identity)
' "$repos_array_file")"

by_day_json="$(jq -c '
  [ .[].stages[]?
    | select((.completed_at // null) != null and (.tokens // 0) > 0)
    | {date: (.completed_at[0:10]), tokens: (.tokens // 0)}
  ]
  | group_by(.date)
  | map({date: .[0].date, tokens: (map(.tokens) | add)})
  | sort_by(.date)
' "$repos_array_file")"

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

fleet_totals_json="$(jq -c '
  {
    enabled_repos: ([.[] | select(.enabled)] | length),
    today_tokens: ([.[] | select(.enabled) | (.today_tokens // 0)] | add // 0),
    today_cost_usd_est: ([.[] | select(.enabled) | (.today_cost_usd_est // 0)] | add // 0),
    window_tokens_spent: ([.[] | select(.enabled) | (.tokens_spent // 0)] | add // 0),
    window_token_cap_total: ([.[] | select(.enabled) | (.token_cap_total // 0)] | add // 0)
  }
' "$repos_array_file")"

jq -n \
  --arg generated_at "$generated_at" \
  --argjson repos "$(cat "$repos_array_file")" \
  --argjson by_model "$by_model_json" \
  --argjson by_day "$by_day_json" \
  --argjson fleet_totals "$fleet_totals_json" \
  '{generated_at: $generated_at, repos: $repos, by_model: $by_model, by_day: $by_day, fleet_totals: $fleet_totals}' \
  > "$data_json"

rm -f "$repos_array_file"

printf 'wrote %s\n' "$data_json"

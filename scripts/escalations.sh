#!/usr/bin/env bash

escalations_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./resolve-root.sh
source "$escalations_script_dir/resolve-root.sh"
# shellcheck source=./alert-statuses.sh
source "$escalations_script_dir/alert-statuses.sh"

escalations_dir() {
  printf '%s\n' "${AUTOMETTA_ESCALATIONS:-$(autometta_controller_home)/escalations}"
}

escalation_write() (
  local repo="$1" stage="$2" kind="$3" summary="$4" detail="${5:-}"
  local dir stamp created base path tmp envelope verifier suffix=1
  dir="$(escalations_dir)" || return 1
  mkdir -p "$dir/pending" "$dir/processed" || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  base="$stamp-$(basename "$repo")-${stage:-run}-$kind"
  tmp="$(mktemp "$dir/pending/.write.XXXXXX")" || return 1
  trap 'rm -f "$tmp"' EXIT

  {
    printf '%s\n' '---'
    jq -nr --arg repo "$repo" --arg stage "$stage" --arg kind "$kind" --arg created "$created" \
      '{repo:$repo, stage:$stage, kind:$kind, created:$created}
       | to_entries[] | "\(.key): \(.value | tojson)"' || return 1
    printf '%s\n\n%s\n' '---' "$summary"
    if [[ -n "$detail" ]]; then
      printf '\n'
      cat "$detail" || return 1
    fi
    if [[ -n "$stage" ]]; then
      envelope="$repo/state/envelopes/$stage.json"
      if [[ ! -f "$envelope" && -f "$repo/state/handoffs/$stage.json" ]]; then
        envelope="$repo/state/handoffs/$stage.json"
      fi
      if [[ -f "$envelope" ]]; then
        printf '\nWorker envelope: %s\n' "$envelope"
        jq -r '"status: \(.status // "unknown")\nnotes: \(.notes // "")"' "$envelope" 2>/dev/null \
          || printf 'Worker envelope could not be read as JSON.\n'
      fi
      verifier="state/verifiers/$stage.json"
      if [[ -f "$repo/state/state.yaml" ]]; then
        local recorded
        recorded="$(yq -o=json '.' "$repo/state/state.yaml" 2>/dev/null \
          | jq -r --arg id "$stage" '.stages[]? | select(.id == $id) | .verifier_artefact // empty')" || recorded=""
        [[ -z "$recorded" ]] || verifier="$recorded"
      fi
      [[ "$verifier" == /* ]] || verifier="$repo/$verifier"
      if [[ -f "$verifier" ]]; then
        printf '\nVerifier artefact: %s\n' "$verifier"
      fi
      for path in "$repo/state/uat/$stage/" "$repo/state/logs/$stage-worker.log" \
        "$repo/state/logs/$stage-verifier.log"; do
        if [[ -e "$path" ]]; then
          printf '\nEvidence: %s\n' "$path"
        fi
      done
    fi
  } > "$tmp" || return 1

  # A hard link publishes a complete file and refuses collisions atomically.
  path="$dir/pending/$base.md"
  while :; do
    if [[ ! -e "$dir/processed/${path##*/}" ]] && ln "$tmp" "$path" 2>/dev/null; then
      break
    fi
    if [[ ! -e "$path" && ! -e "$dir/processed/${path##*/}" ]]; then
      return 1
    fi
    suffix=$((suffix + 1))
    path="$dir/pending/$base-$suffix.md"
  done
  if [[ "${AUTOMETTA_NOTIFY:-1}" != 0 ]]; then
    osascript -e 'on run argv
      display notification (item 1 of argv) with title "Autometta escalation"
    end run' "$summary" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$path"
)

escalations_scan() (
  local repo="$1" ledger="$1/state/escalated-episodes.json"
  local stages='[]' halt='[]' episodes episode key stage kind summary tmp result=0
  [[ -d "$repo/state" ]] || return 0
  if [[ -f "$repo/state/state.yaml" ]]; then
    stages="$(yq -o=json '.' "$repo/state/state.yaml" | jq -c \
      --argjson alerts "$(alert_stage_statuses_json)" '
      [.stages[]? | select(.status as $status | $alerts | index($status))
       | {stage:.id, kind:.status, summary:("Stage " + .id + " entered " + .status),
          episode:[.id, .status, .started_at, .verifier_attempts, .stall_marker]}]')" \
      || { stages='[]'; result=1; }
  fi
  if [[ -f "$repo/state/budget.json" ]]; then
    halt="$(jq -c '[select(.halted == true)
      | {stage:"", kind:"halted", summary:("Repo halted: " + (.halt_reason // "unknown")),
         episode:[.halt_reason, .halted_at]}]' "$repo/state/budget.json")" \
      || { halt='[]'; result=1; }
  fi
  episodes="$(jq -nc --argjson stages "$stages" --argjson halt "$halt" '$stages + $halt')" || return 1
  [[ "$episodes" != '[]' ]] || return "$result"
  tmp="$(mktemp "$repo/state/.escalated-episodes.XXXXXX")" || return 1
  trap 'rm -f "$tmp"' EXIT
  if [[ ! -f "$ledger" ]]; then
    printf '[]\n' > "$tmp" && mv "$tmp" "$ledger" || return 1
  fi
  jq -e 'type == "array"' "$ledger" >/dev/null || return 1
  while IFS= read -r episode; do
    key="$(printf '%s\n' "$episode" | jq -c '.episode')" || return 1
    if jq -e --argjson key "$key" 'any(.[]; . == $key)' "$ledger" >/dev/null; then
      continue
    fi
    stage="$(printf '%s\n' "$episode" | jq -r '.stage')" || return 1
    kind="$(printf '%s\n' "$episode" | jq -r '.kind')" || return 1
    summary="$(printf '%s\n' "$episode" | jq -r '.summary')" || return 1
    escalation_write "$repo" "$stage" "$kind" "$summary" >/dev/null || return 1
    jq --argjson key "$key" '. + [$key]' "$ledger" > "$tmp" \
      && mv "$tmp" "$ledger" || return 1
  done < <(printf '%s\n' "$episodes" | jq -c '.[]')
  return "$result"
)

escalations_main() {
  local command="${1:-}" id="${2:-}" note="${3:-}" dir path
  dir="$(escalations_dir)" || return 1
  case "$command" in
    list)
      [[ -d "$dir/pending" ]] || return 0
      local files=() file
      for file in "$dir/pending"/*.md; do
        [[ ! -f "$file" ]] || files+=("$file")
      done
      [[ ${#files[@]} -gt 0 ]] || return 0
      while IFS= read -r path; do
        file="${path##*/}"
        printf '%s\n' "${file%.md}"
      done < <(ls -1tr "${files[@]}")
      ;;
    show|ack)
      [[ -n "$id" && "$id" != */* && -f "$dir/pending/$id.md" ]] || return 1
      path="$dir/pending/$id.md"
      if [[ "$command" == show ]]; then
        cat "$path"
      else
        mkdir -p "$dir/processed" || return 1
        [[ ! -e "$dir/processed/$id.md" ]] || return 1
        printf '\nacked: %s\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$note" >> "$path" || return 1
        mv "$path" "$dir/processed/$id.md"
      fi
      ;;
    *)
      printf 'Usage: escalations.sh list | show <id> | ack <id> [note]\n' >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  escalations_main "$@"
fi

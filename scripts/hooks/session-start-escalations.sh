#!/usr/bin/env bash
# Snapshot reader, or change-only lifecycle delivery with --live <family>.
#
# Prints nothing when there are none. Never fails the session: every error
# path exits 0 silently. Snapshot mode ignores stdin; live mode consumes the
# harness's session JSON in the shared Python adapter.
if [[ "${1:-}" == --live ]]; then
  exec python3 "$(dirname "${BASH_SOURCE[0]}")/escalation-context.py" "${2:-claude}" 2>/dev/null
fi
exec 2>/dev/null </dev/null

hook_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=../subscribers.sh
source "$hook_script_dir/../subscribers.sh" || exit 0
# shellcheck source=../escalations.sh
source "$hook_script_dir/../escalations.sh" || exit 0

hook_max_lines=10
hook_summary_width=100

physical_dir() {
  (cd "$1" && pwd -P)
}

# The enabled subscriber whose repo_path contains the working directory,
# deepest match first; prints the raw and the physical path on two lines.
current_subscriber_repo() {
  local work file repo physical best_raw="" best_physical=""
  work="$(physical_dir "${CLAUDE_PROJECT_DIR:-$PWD}")" || return 1
  while IFS= read -r file; do
    [[ "$(read_subscriber_field "$file" enabled)" == true ]] || continue
    repo="$(read_subscriber_field "$file" repo_path)"
    [[ -n "$repo" ]] || continue
    physical="$(physical_dir "$repo")" || continue
    if [[ "$work" == "$physical" || "$work" == "$physical"/* ]] \
      && [[ ${#physical} -gt ${#best_physical} ]]; then
      best_raw="$repo"
      best_physical="$physical"
    fi
  done < <(sort_subscribers)
  [[ -n "$best_physical" ]] || return 1
  printf '%s\n%s\n' "$best_raw" "$best_physical"
}

unquote() {
  local value="${1# }"
  value="${value#\"}"
  printf '%s' "${value%\"}"
}

# Sets parsed_repo, parsed_stage, parsed_kind and parsed_summary from one file.
parse_escalation() {
  local line state=0
  parsed_repo="" parsed_stage="" parsed_kind="" parsed_summary=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $state -eq 0 ]]; then
      if [[ "$line" == --- ]]; then
        state=1
        continue
      fi
      state=2
    fi
    if [[ $state -eq 1 ]]; then
      case "$line" in
        ---) state=2 ;;
        repo:*) parsed_repo="$(unquote "${line#repo:}")" ;;
        stage:*) parsed_stage="$(unquote "${line#stage:}")" ;;
        kind:*) parsed_kind="$(unquote "${line#kind:}")" ;;
      esac
      continue
    fi
    if [[ -n "${line//[[:space:]]/}" ]]; then
      parsed_summary="$line"
      break
    fi
  done < "$1"
}

main() {
  local dir file base repo_raw="" repo_physical="" scope="" subscriber
  local lines=() total=0
  dir="$(escalations_dir)" || return 0
  [[ -d "$dir/pending" ]] || return 0

  if subscriber="$(current_subscriber_repo)"; then
    repo_raw="${subscriber%%$'\n'*}"
    repo_physical="${subscriber#*$'\n'}"
    scope=" for $(basename "$repo_physical")"
  fi

  for file in "$dir/pending"/*.md; do
    [[ -f "$file" ]] || continue
    parse_escalation "$file"
    if [[ -n "$repo_raw" && "$parsed_repo" != "$repo_raw" && "$parsed_repo" != "$repo_physical" ]]; then
      continue
    fi
    if [[ "${1:-}" == --records ]]; then
      [[ -n "$parsed_repo" && -n "$parsed_kind" && -n "$parsed_summary" ]] || continue
      jq -nc --arg path "$file" --arg repo "$parsed_repo" --arg stage "$parsed_stage" \
        --arg kind "$parsed_kind" --arg summary "${parsed_summary:0:$hook_summary_width}" \
        '{path:$path,repo:$repo,stage:$stage,kind:$kind,summary:$summary}'
      continue
    fi
    total=$((total + 1))
    [[ ${#lines[@]} -lt $hook_max_lines ]] || continue
    base="${file##*/}"
    lines+=("$(printf '%s %s %s %s %s %s' "${base%%-*}" "$(basename "${parsed_repo:-unknown}")" \
      "${parsed_stage:-run}" "${parsed_kind:--}" "${parsed_summary:0:$hook_summary_width}" "$file")")
  done

  [[ $total -gt 0 ]] || return 0
  printf 'Autometta: %d pending escalation(s)%s, oldest first\n' "$total" "$scope"
  printf '%s\n' "${lines[@]}"
  if [[ $total -gt $hook_max_lines ]]; then
    printf '+%d more\n' $((total - hook_max_lines))
  fi
  printf 'Run scripts/escalations.sh list, or work them with the autometta-escalations skill.\n'
}

main "$@" || true
exit 0

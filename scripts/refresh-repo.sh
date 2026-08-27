#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# refresh-repo.sh: push the vendored dispatch contract into one subscriber.
#
#   scripts/refresh-repo.sh <repo-path> [--dry-run] [--adopt]
#
# Work happens here, in autometta. A subscriber holds a copy of the contract
# and a .autometta-vendor stamp naming the sha it came from. Before this script
# there was no way to push an update: the copy was made once by hand from the
# autometta-setup skill and thereafter only drifted.
#
# What it refuses to do is the point of it. It never overwrites a template a
# subscriber has legitimately filled in, it will not write into a repo with
# uncommitted changes on a vendored path, and it will not touch a repo with a
# stage in flight. It leaves its changes unstaged in the subscriber: autometta
# pushes files, an operator decides what is committed in somebody else's repo.
#
# Exit 0 refreshed or already current, 3 skipped or refused with a stated
# reason, 1 a problem with this autometta tree.

refresh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./resolve-root.sh
. "$refresh_script_dir/resolve-root.sh"
# shellcheck source=./vendor-set.sh
. "$refresh_script_dir/vendor-set.sh"

# The list of vendored files must come from the same tree as the files it
# names. Self and the resolved root are usually one tree; when they are not --
# an installed build resolving to a checkout -- the checkout is the tree a
# dispatch actually runs, so its list is the one that binds. Reading the list
# from one tree and the files from another is how a file added to the set
# quietly fails to reach anybody.
autometta_source_vendor_set_from_root() {
  local root="$1"
  if [[ -f "$root/scripts/vendor-set.sh" ]]; then
    # shellcheck source=./vendor-set.sh
    . "$root/scripts/vendor-set.sh"
  fi
}

autometta_refresh_abspath() {
  local input_path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$input_path" 2>/dev/null || printf '%s' "$input_path"
  else
    python3 - "$input_path" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
  fi
}

# The shared .git directory behind a checkout and all of its linked worktrees.
# Empty when the path is not a git repository at all.
autometta_refresh_git_common_dir() {
  local dir
  dir="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  autometta_refresh_abspath "$dir"
}

# Prints a human reason and returns 0 when the repo has work in flight.
# Refreshing under a running worker replaces the very templates it is reading,
# and the prompt it is working from was rendered against the old ones.
autometta_repo_stage_in_flight() {
  local repo_root="$1"
  local lock_pid agent_file pid role stage_ids state_yaml

  local lock_dir="$repo_root/state/.tick.lock"
  if [[ -d "$lock_dir" ]]; then
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      printf 'a tick is running in it (pid %s holds state/.tick.lock)' "$lock_pid"
      return 0
    fi
  fi

  for agent_file in "$repo_root"/state/active-agents/*.json; do
    [[ -f "$agent_file" ]] || continue
    pid="$(jq -r '.pid // 0' "$agent_file" 2>/dev/null || echo 0)"
    role="$(jq -r '.role // "agent"' "$agent_file" 2>/dev/null || echo agent)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]] && kill -0 "$pid" 2>/dev/null; then
      printf 'a %s is live in it (pid %s)' "$role" "$pid"
      return 0
    fi
  done

  state_yaml="$repo_root/state/state.yaml"
  if [[ -s "$state_yaml" ]] && command -v yq >/dev/null 2>&1; then
    stage_ids="$(yq -r '[.stages[]? | select(.status == "in_progress") | .id] | join(", ")' "$state_yaml" 2>/dev/null || true)"
    if [[ -n "$stage_ids" && "$stage_ids" != "null" ]]; then
      printf 'stage in flight: %s' "$stage_ids"
      return 0
    fi
  fi

  return 1
}

# The first vendored path carrying uncommitted state -- staged, unstaged or
# untracked. A push must not be mixed into somebody's working set: once the two
# are in one diff the operator has no way to tell their edit from ours.
autometta_dirty_vendored_path() {
  local repo_root="$1" f status_out
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    status_out="$(git -C "$repo_root" status --porcelain --untracked-files=normal -- "$f" 2>/dev/null || true)"
    if [[ -n "$status_out" ]]; then
      printf '%s\n' "$f"
      break
    fi
  done < <(autometta_vendored_files; printf '%s\n' "$autometta_vendor_stamp_name")
}

# autometta_refresh_repo <repo-path> <dry-run:true|false> <adopt:true|false> <src-root> <src-sha>
autometta_refresh_repo() {
  local repo_path="$1" dry_run="$2" adopt="$3" src="$4" src_sha="$5"
  local stamp f label prefix=""
  local updated=0 created=0 preserved=0 unchanged=0
  local -a actions=()

  [[ "$dry_run" == "true" ]] && prefix="[dry-run] "

  repo_path="$(autometta_refresh_abspath "$repo_path")"
  stamp="$repo_path/$autometta_vendor_stamp_name"

  if [[ ! -d "$repo_path" ]]; then
    printf 'SKIP %s: repo_path is not on disk\n' "$repo_path"
    return 3
  fi
  # -e, not -d: a linked git worktree has a .git *file* pointing at the parent.
  if [[ ! -e "$repo_path/.git" ]]; then
    printf 'SKIP %s: not a git repo\n' "$repo_path"
    return 3
  fi
  # Same path, or the same repository seen through another worktree. A run
  # worktree resolving as the root would otherwise let autometta vendor the
  # contract into its own checkout, which is where the contract comes from.
  local repo_git_dir src_git_dir
  repo_git_dir="$(autometta_refresh_git_common_dir "$repo_path")"
  src_git_dir="$(autometta_refresh_git_common_dir "$src")"
  if [[ "$repo_path" == "$(autometta_refresh_abspath "$src")" ]] \
     || [[ -n "$repo_git_dir" && "$repo_git_dir" == "$src_git_dir" ]]; then
    printf 'SKIP %s: this is the autometta source repository, which is where the set is defined\n' "$repo_path"
    return 3
  fi
  if [[ ! -f "$stamp" && "$adopt" != "true" ]]; then
    printf 'SKIP %s: no %s stamp, so this repo has never vendored the contract; pass --adopt to vendor it for the first time\n' \
      "$repo_path" "$autometta_vendor_stamp_name"
    return 3
  fi

  local in_flight_reason
  if in_flight_reason="$(autometta_repo_stage_in_flight "$repo_path")"; then
    printf 'SKIP %s: %s\n' "$repo_path" "$in_flight_reason"
    return 3
  fi

  local dirty
  dirty="$(autometta_dirty_vendored_path "$repo_path")"
  if [[ -n "$dirty" ]]; then
    printf 'REFUSE %s: uncommitted changes on vendored path %s; commit or set them aside first, a refresh must not be mixed into your working set\n' \
      "$repo_path" "$dirty"
    return 3
  fi

  # Classify every file before writing any of them, so a set with a hole in it
  # is reported rather than half applied.
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -f "$src/$f" ]]; then
      printf 'FAIL %s: %s is in the vendored set but missing from %s\n' "$repo_path" "$f" "$src"
      return 1
    fi
    if [[ ! -f "$repo_path/$f" ]]; then
      actions+=("NEW"$'\t'"$f"); created=$((created + 1))
    elif [[ "$(autometta_file_digest "$repo_path/$f")" == "$(autometta_file_digest "$src/$f")" ]]; then
      actions+=("SAME"$'\t'"$f"); unchanged=$((unchanged + 1))
    elif autometta_only_filled_placeholders "$repo_path/$f" "$src/$f"; then
      actions+=("FILLED"$'\t'"$f"); preserved=$((preserved + 1))
    else
      actions+=("UPDATE"$'\t'"$f"); updated=$((updated + 1))
    fi
  done < <(autometta_vendored_files)

  # bash 3.2 is the macOS system shell and expanding an empty array under
  # `set -u` is an error there, so an empty set has to be caught, not iterated.
  if [[ ${#actions[@]} -eq 0 ]]; then
    printf 'FAIL %s: the vendored set defined in %s/scripts/vendor-set.sh is empty\n' "$repo_path" "$src"
    return 1
  fi

  local stamp_from
  stamp_from="$(autometta_vendor_stamp_field "$stamp" vendored_from)"
  printf '%srefresh %s\n' "$prefix" "$repo_path"

  local action verb path
  for action in "${actions[@]}"; do
    verb="${action%%$'\t'*}"
    path="${action#*$'\t'}"
    case "$verb" in
      NEW)    label="vendored for the first time" ;;
      UPDATE) label="replaced from ${src_sha}" ;;
      FILLED) label="placeholders completed downstream, preserved" ;;
      SAME)   label="already current" ;;
      *)      label="" ;;
    esac
    printf '%s  %-6s %s (%s)\n' "$prefix" "$verb" "$path" "$label"
  done

  if [[ "$dry_run" == "true" ]]; then
    printf '%s  stamp  %s -> %s\n' "$prefix" "${stamp_from:-none}" "$src_sha"
    printf '%sPASS would refresh %s (%d new, %d updated, %d filled preserved, %d unchanged); nothing written\n' \
      "$prefix" "$repo_path" "$created" "$updated" "$preserved" "$unchanged"
    return 0
  fi

  for action in "${actions[@]}"; do
    verb="${action%%$'\t'*}"
    path="${action#*$'\t'}"
    case "$verb" in
      NEW|UPDATE)
        mkdir -p "$repo_path/$(dirname "$path")"
        cp "$src/$path" "$repo_path/$path"
        case "$path" in
          *.sh) chmod +x "$repo_path/$path" ;;
        esac
        ;;
    esac
  done

  autometta_write_vendor_stamp "$stamp" "$src_sha"
  printf '  stamp  %s -> %s\n' "${stamp_from:-none}" "$src_sha"
  printf 'PASS refreshed %s (%d new, %d updated, %d filled preserved, %d unchanged)\n' \
    "$repo_path" "$created" "$updated" "$preserved" "$unchanged"
  printf '  changes are unstaged in that repo; review and commit them there\n'
  return 0
}

autometta_refresh_usage() {
  printf 'Usage: %s <repo-path> [--dry-run] [--adopt]\n' "$(basename "$0")" >&2
  exit 1
}

autometta_refresh_main() {
  local repo_path="" dry_run=false adopt=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --adopt) adopt=true ;;
      -h|--help) autometta_refresh_usage ;;
      -*) printf 'unknown flag: %s\n' "$1" >&2; autometta_refresh_usage ;;
      *)
        [[ -z "$repo_path" ]] || autometta_refresh_usage
        repo_path="$1"
        ;;
    esac
    shift
  done
  [[ -n "$repo_path" ]] || autometta_refresh_usage

  autometta_resolve_root "$(autometta_self_root "$refresh_script_dir")"
  local src="$AUTOMETTA_ROOT_RESOLVED"
  autometta_source_vendor_set_from_root "$src"
  local src_sha
  src_sha="$(autometta_root_sha "$src")"
  if [[ "$src_sha" == "unknown" ]]; then
    printf 'FAIL autometta root %s reports no sha (not a checkout, no VERSION file); a stamp written from it would name nothing\n' "$src" >&2
    exit 1
  fi
  printf 'autometta source: %s (%s, via %s)\n' "$src" "$src_sha" "$AUTOMETTA_ROOT_ORIGIN"

  local rc=0
  autometta_refresh_repo "$repo_path" "$dry_run" "$adopt" "$src" "$src_sha" || rc=$?
  exit "$rc"
}

# Only auto-run when executed directly; refresh-all-repos.sh sources this file
# for autometta_refresh_repo rather than shelling out per subscriber.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  autometta_refresh_main "$@"
fi

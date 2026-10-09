#!/usr/bin/env bash
# Operator view of the stage dependency graph: `autometta graph`.
#
#   graph.sh [--repo <path>] [--json]
#
# Resolves the base branch exactly as the tick does, then runs the read-only
# inspector (scripts/dependency-graph.sh). --json prints the inspector report
# byte for byte; the default prints the same report for a person. Either way
# the exit code is the inspector's: 0 valid, 2 invalid graph, 1 no inspection.
# The dependency rules live in the inspector only; this file formats.
#
# Contract: docs/dependency-graph.md.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf 'usage: autometta graph [--repo <path>] [--json]\n' >&2
  exit 1
}

die() {
  printf 'graph: %s\n' "$*" >&2
  exit 1
}

repo_arg="."
want_json=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 && -n "$2" ]] || usage
      repo_arg="$2"
      shift 2
      ;;
    --json)
      want_json=true
      shift
      ;;
    -h|--help)
      printf 'usage: autometta graph [--repo <path>] [--json]\n'
      exit 0
      ;;
    *)
      usage
      ;;
  esac
done

for tool in git yq python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

[[ -d "$repo_arg" ]] || die "repo ${repo_arg} is not a directory"
repo_root="$(cd "$repo_arg" && pwd)"
git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 \
  || die "${repo_root} is not a Git repository"
state_yaml="$repo_root/state/state.yaml"
[[ -f "$state_yaml" && -r "$state_yaml" ]] \
  || die "${state_yaml} is missing or unreadable; is this repo subscribed?"

export GIT_OPTIONAL_LOCKS=0

# The registry entry for this repo names the manifest the tick reads, and so
# the base branch the tick would cut a dependent card from. Resolution itself
# is the tick's own resolve_base_branch, never a copy of it.
read -r manifest_path base_branch < <(
  bash -c '
    source "$1/tick.sh"
    want="$(cd "$2" && pwd -P)"
    manifest=""
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      path="$(read_subscriber_field "$file" repo_path)"
      [[ -n "$path" && -d "$path" ]] || continue
      if [[ "$(cd "$path" && pwd -P)" == "$want" ]]; then
        manifest="$(read_subscriber_field "$file" manifest_path)"
        break
      fi
    done < <(sort_subscribers)
    printf "%s\t%s\n" "${manifest:--}" "$(resolve_base_branch "$2" "$manifest")"
  ' graph-base "$script_dir" "$repo_root"
) || true
[[ "${manifest_path:-}" == "-" ]] && manifest_path=""
if [[ -z "${base_branch:-}" || "$base_branch" == "HEAD" ]]; then
  die "could not resolve a base branch for ${repo_root}: set base_branch in its manifest or .autometta.local.yaml, or check out the base branch"
fi

report_rc=0
report="$("$script_dir/dependency-graph.sh" "$repo_root" "$state_yaml" "$base_branch")" || report_rc=$?
if (( report_rc != 0 && report_rc != 2 )); then
  printf 'graph: inspection failed for %s against base %s; nothing is dependency ready\n' \
    "$repo_root" "$base_branch" >&2
  exit "$report_rc"
fi

if [[ "$want_json" == true ]]; then
  printf '%s\n' "$report"
  exit "$report_rc"
fi

state_json="$(yq -o=json '.' "$state_yaml")" || die "state file ${state_yaml} could not be parsed"

GRAPH_REPORT="$report" GRAPH_STATE="$state_json" python3 - \
  "$repo_root" "$base_branch" "${manifest_path:-}" <<'PY'
import json
import os
import sys

repo_root, base_branch, manifest_path = sys.argv[1:4]
report = json.loads(os.environ["GRAPH_REPORT"])
state = json.loads(os.environ["GRAPH_STATE"])
records = {}
for stage in state.get("stages") or []:
    if isinstance(stage, dict) and isinstance(stage.get("id"), str):
        records.setdefault(stage["id"], stage)

print(f"repo:  {repo_root}")
base_source = "tick base-branch policy, " + (
    f"registry manifest {manifest_path}" if manifest_path else "no registry manifest")
print(f"base:  {base_branch} ({base_source})")
if report["valid"]:
    print("graph: valid")
else:
    print("graph: INVALID - graph members cannot be judged and will not dispatch")
    for error in report["errors"]:
        print(f"  error: {error}")
print()
print("Readiness below is dependency readiness only, not permission to dispatch.")
print("Quota, budget, network, pauses and each stage's own status are still")
print("checked by the tick at dispatch time.")
print()

width = max([len(str(n["id"])) for n in report["stages"]] + [5])
for node in report["stages"]:
    stage_id = node["id"]
    record = records.get(stage_id, {})
    status = record.get("status", "?")
    if not node["graph_member"]:
        readiness = "not in graph"
    elif node["dependency_ready"]:
        readiness = "dependencies landed" if "depends_on" in record else "graph root"
    elif any(b["reason"] == "invalid-graph" for b in node["blocked_by"]):
        readiness = "INVALID GRAPH"
    else:
        readiness = "waiting on dependencies"
    print(f"{str(stage_id):<{width}}  {status:<16} {readiness}")
    declared = record.get("depends_on")
    if isinstance(declared, list) and all(isinstance(p, str) for p in declared):
        print(f"{'':<{width}}    depends on: {', '.join(declared)}")
    elif declared is not None:
        print(f"{'':<{width}}    depends on (malformed): {json.dumps(declared)}")
    gate = record.get("gate")
    if isinstance(gate, dict) and gate.get("type") == "stage_completed":
        print(f"{'':<{width}}    legacy gate: stage-completed {gate.get('stage_id')} (status only)")
    elif isinstance(gate, dict) and gate.get("type") == "queue_empty":
        print(f"{'':<{width}}    legacy gate: queue-empty (status only)")
    for blocker in node["blocked_by"]:
        label = "invalid" if blocker["reason"] == "invalid-graph" else "waiting"
        print(f"{'':<{width}}    {label}: {blocker['id']} {blocker['reason']}")
PY
exit "$report_rc"

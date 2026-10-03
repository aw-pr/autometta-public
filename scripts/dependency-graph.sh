#!/usr/bin/env bash
# Read-only dependency inspector: reports, for every queued stage, whether the
# stages it declares in `depends_on` have landed on the given base branch.
#
#   dependency-graph.sh <repo-root> <state-file> <base-branch>
#
# Exit 0: the graph is structurally valid (stages may still be blocked).
# Exit 2: the graph is invalid; the report carries valid:false and errors.
# Exit 1: inspection was impossible (bad arguments, unreadable state, missing
#         base branch, unreadable Git evidence). Nothing is printed on stdout,
#         so no caller can read readiness out of a failed inspection.
#
# Contract: docs/dependency-graph.md.
set -euo pipefail
IFS=$'\n\t'

die() {
  printf 'dependency-graph: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  printf 'usage: %s <repo-root> <state-file> <base-branch>\n' "$0" >&2
  exit 1
fi

repo_arg="$1"
state_arg="$2"
base_branch="$3"

for tool in git yq python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

[[ -d "$repo_arg" ]] || die "repo root ${repo_arg} is not a directory"
repo_root="$(cd "$repo_arg" && pwd)"
[[ -f "$state_arg" && -r "$state_arg" ]] || die "state file ${state_arg} is missing or unreadable"

# Inspection must never take a lock or refresh the index on the caller's behalf.
export GIT_OPTIONAL_LOCKS=0

git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 \
  || die "${repo_root} is not a Git repository"

[[ -n "$base_branch" && "$base_branch" != -* ]] || die "base branch '${base_branch}' is not a branch name"
base_ref=""
for candidate in "refs/heads/${base_branch}" "refs/remotes/${base_branch}"; do
  if git -C "$repo_root" show-ref --verify --quiet "$candidate"; then
    base_ref="$candidate"
    break
  fi
done
[[ -n "$base_ref" ]] || die "base branch ${base_branch} does not exist in ${repo_root}"
base_tip="$(git -C "$repo_root" rev-parse --verify --quiet "${base_ref}^{commit}")" \
  || die "base branch ${base_branch} does not resolve to a commit"

state_json="$(yq -o=json '.' "$state_arg")" || die "state file ${state_arg} could not be parsed"

printf '%s' "$state_json" | python3 -c '
import json
import re
import subprocess
import sys

repo_root, base_branch, base_tip = sys.argv[1:4]

STAGE_ID = re.compile(r"^[0-9]{2,}[a-z]*-[a-z0-9-]+$")
OBJECT_NAME = re.compile(r"^[0-9a-f]{7,64}$")
INSPECTION_FAILED = 1
INVALID_GRAPH = 2


def fail(message):
    print(f"dependency-graph: {message}", file=sys.stderr)
    raise SystemExit(INSPECTION_FAILED)


def warn(message):
    print(f"dependency-graph: {message}", file=sys.stderr)


def git(*args):
    return subprocess.run(["git", "-C", repo_root, *args], text=True,
                          capture_output=True, check=False)


try:
    state = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    fail(f"state could not be decoded: {exc}")
if not isinstance(state, dict) or not isinstance(state.get("stages"), list):
    fail("state has no stages list")
stages = state["stages"]

errors = []
ids = []
for position, stage in enumerate(stages):
    stage_id = stage.get("id") if isinstance(stage, dict) else None
    if not isinstance(stage_id, str) or not stage_id:
        errors.append(f"stage at queue position {position} has no string id")
        stage_id = None
    ids.append(stage_id)

known = {stage_id for stage_id in ids if stage_id is not None}
duplicates = []
for stage_id in ids:
    if stage_id is not None and ids.count(stage_id) > 1 and stage_id not in duplicates:
        duplicates.append(stage_id)
for stage_id in duplicates:
    errors.append(f"stage id {stage_id} appears {ids.count(stage_id)} times in the queue")

# Declared edges, owner -> prerequisite, in queue and declaration order.
declares = [False] * len(stages)
declared = [[] for _ in stages]
members = set()
dependency_edges = []
for position, stage in enumerate(stages):
    owner = ids[position]
    if not isinstance(stage, dict) or "depends_on" not in stage:
        continue
    declares[position] = True
    if owner is not None:
        members.add(owner)
    label = owner if owner is not None else f"stage at queue position {position}"
    value = stage["depends_on"]
    if not isinstance(value, list):
        errors.append(f"{label}: depends_on must be a list of stage ids, got {json.dumps(value)}")
        continue
    if not value:
        errors.append(f"{label}: depends_on is empty; omit it or name at least one stage")
        continue
    seen = []
    for prerequisite in value:
        if not isinstance(prerequisite, str) or not STAGE_ID.match(prerequisite):
            errors.append(f"{label}: depends_on entry {json.dumps(prerequisite)} is not a full stage id")
            continue
        declared[position].append(prerequisite)
        members.add(prerequisite)
        if prerequisite in seen:
            errors.append(f"{label}: depends_on names {prerequisite} more than once")
            continue
        seen.append(prerequisite)
        if prerequisite == owner:
            errors.append(f"{label}: depends_on names the stage itself")
        elif prerequisite not in known:
            errors.append(f"{label}: depends_on names {prerequisite}, which is not in the queue")
        elif owner is not None:
            dependency_edges.append((owner, prerequisite))

# Cycles count only when they run through at least one depends_on edge; a
# legacy stage_completed gate keeps its historical status-only meaning, and
# one naming an absent stage simply stays pending.
gate_edges = []
for position, stage in enumerate(stages):
    owner = ids[position]
    gate = stage.get("gate") if isinstance(stage, dict) else None
    if owner is None or not isinstance(gate, dict) or gate.get("type") != "stage_completed":
        continue
    target = gate.get("stage_id")
    if isinstance(target, str) and target in known and target != owner:
        gate_edges.append((owner, target))

order = list(dict.fromkeys(stage_id for stage_id in ids if stage_id is not None))
successors = {stage_id: [] for stage_id in order}
for owner, target in dependency_edges + gate_edges:
    if target not in successors[owner]:
        successors[owner].append(target)


def strongly_connected(nodes, successors):
    index, low, on_stack, stack, found = {}, {}, set(), [], []
    counter = 0
    for root in nodes:
        if root in index:
            continue
        work = [(root, 0)]
        while work:
            node, child = work.pop()
            if child == 0:
                index[node] = low[node] = counter
                counter += 1
                stack.append(node)
                on_stack.add(node)
            if child < len(successors[node]):
                work.append((node, child + 1))
                nxt = successors[node][child]
                if nxt not in index:
                    work.append((nxt, 0))
                elif nxt in on_stack:
                    low[node] = min(low[node], index[nxt])
                continue
            if low[node] == index[node]:
                component = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    component.append(member)
                    if member == node:
                        break
                found.append(component)
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])
    return found


cycle_members = set()
for component in strongly_connected(order, successors):
    if len(component) < 2:
        continue
    inside = set(component)
    if not any(owner in inside and target in inside for owner, target in dependency_edges):
        continue
    cycle_members |= inside
    ranked = sorted(component, key=order.index)
    edges = [f"{owner} -> {target} ({kind})"
             for kind, edge_list in (("depends_on", dependency_edges), ("stage_completed gate", gate_edges))
             for owner, target in edge_list if owner in inside and target in inside]
    errors.append("dependency cycle among " + ", ".join(ranked) + ": " + "; ".join(edges))

valid = not errors
affected = members | set(duplicates) | cycle_members

by_id = {}
for position, stage_id in enumerate(ids):
    if stage_id is not None:
        by_id.setdefault(stage_id, stages[position])


def landed_tip(record):
    integration = record.get("integration")
    integration = integration if isinstance(integration, dict) else {}
    for source, value in (("integration.rebased_tip", integration.get("rebased_tip")),
                          ("commit", record.get("commit")),
                          ("integration.head", integration.get("head"))):
        if value is None or value == "":
            continue
        return source, value
    return None, None


def evidence_blocker(prerequisite):
    record = by_id[prerequisite]
    if record.get("status") != "completed":
        return "not-completed"
    integration = record.get("integration")
    if isinstance(integration, dict) and integration.get("state") == "awaiting":
        return "awaiting-integration"
    source, tip = landed_tip(record)
    if tip is None:
        return "missing-commit"
    if not isinstance(tip, str) or not OBJECT_NAME.match(tip):
        warn(f"{prerequisite}: {source} {json.dumps(tip)} is not a commit id")
        return "missing-commit"
    resolved = git("rev-parse", "--verify", "--quiet", f"{tip}^{{commit}}")
    full = resolved.stdout.strip()
    if resolved.returncode != 0 or not full.startswith(tip):
        warn(f"{prerequisite}: {source} {tip} is not a commit in {repo_root}")
        return "missing-commit"
    ancestry = git("merge-base", "--is-ancestor", full, base_tip)
    if ancestry.returncode == 0:
        return None
    if ancestry.returncode == 1:
        return "commit-not-on-base"
    fail(f"{prerequisite}: could not test whether {full} is on {base_branch}: "
         + (ancestry.stderr.strip() or f"git exited {ancestry.returncode}"))


report_stages = []
for position, stage_id in enumerate(ids):
    graph_member = declares[position] or (stage_id in members)
    blocked_by = []
    if not valid and (graph_member or stage_id is None or stage_id in affected):
        culprits = list(dict.fromkeys(declared[position])) or [stage_id]
        blocked_by = [{"id": culprit, "reason": "invalid-graph"} for culprit in culprits]
    elif declares[position]:
        for prerequisite in dict.fromkeys(declared[position]):
            reason = evidence_blocker(prerequisite)
            if reason is not None:
                blocked_by.append({"id": prerequisite, "reason": reason})
    report_stages.append({"id": stage_id, "graph_member": graph_member,
                          "dependency_ready": not blocked_by, "blocked_by": blocked_by})

print(json.dumps({"valid": valid, "errors": errors, "stages": report_stages},
                 separators=(",", ":")))
raise SystemExit(0 if valid else INVALID_GRAPH)
' "$repo_root" "$base_branch" "$base_tip"

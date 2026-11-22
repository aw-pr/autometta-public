#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/179-serial-claims.md
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export AUTOMETTA_HOME="$tmp/host" PHAT_CONTROLLER_HOME="$tmp/host"
source "$root/scripts/tick.sh"
quota_gate_role_dispatch() { return 0; }
budget_gate_dispatch() { return 0; }
network_preflight_ok() { return 0; }
ensure_run_worktree() { printf '%s\n' "$1"; }
spawn_worker_for_stage() { touch "$repo/spawned"; }
for scenario in eligible head tail legacy-head legacy-tail; do
  repo="$tmp/$scenario"
  state="$repo/state/state.yaml"
  mkdir -p "$repo/docs/stages" "$repo/state"
  git -C "$repo" init -qb dev
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@local commit -qm fixture --allow-empty
  printf '{"stages":[],"current_stage":null}\n' > "$state"
  printf '{"total_tokens":100}\n' > "$repo/state/cost-log.jsonl"
  printf '{"token_cap_total":4000,"tokens_spent":0}\n' > "$repo/state/budget.json"
  for id in 01-head 02-tail; do
    card="$repo/docs/stages/$id.md"
    if [[ "$id" == 01-head ]]; then worker=Codex; verifier=Claude; else worker=Claude; verifier=Codex; fi
    printf '# Fixture\n\n- **Worker:** %s Fixture\n- **Verifier:** %s Fixture\n- **Path claims:** %s.txt\n' "$worker" "$verifier" "$id" > "$card"
    if [[ "$scenario" == "${id#*-}" ]]; then printf '%s\n' '- **Dispatch:** serial' >> "$card"; fi
    "$root/scripts/add-stage.sh" "$repo" "$card" >/dev/null
    if [[ "$scenario" == "legacy-${id#*-}" ]]; then printf '%s\n' '- **Dispatch:** serial' >> "$card"; fi
  done
  git -C "$repo" add docs
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@local commit -qm cards
  yq -i '.current_stage="01-head" | .stages[0].status="in_progress"' "$state"
  state_json "$state" | jq -e '[.stages[].path_claims] == [["01-head.txt"],["02-tail.txt"]]' >/dev/null
  if pipeline_try_dispatch_tail "$repo" "$state" 01-head ""; then paired=yes; else paired=no; fi
  if [[ "$scenario" == eligible ]]; then
    [[ "$paired" == yes && -f "$repo/spawned" ]] || { echo 'FAIL: eligible pair never dispatched' >&2; exit 1; }
  else
    [[ "$paired" == no && ! -e "$repo/spawned" ]] || { echo "FAIL: $scenario serial declaration overlapped" >&2; exit 1; }
    state_json "$state" | jq -e '.pipeline_pair == null and .stages[1].status == "pending"' >/dev/null
  fi
done
# AUTOMETTA-CONTRACT-END
echo 'PASS: serial declarations with path claims'

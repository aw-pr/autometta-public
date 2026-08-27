#!/usr/bin/env bash
# aggregate-perf-smoke.sh: the shape guard on scripts/aggregate-dashboard.sh.
#
# Two claims, both offline and both about shape rather than about this machine.
#
#   1. A five-thousand-row cost log and sixty stage cards aggregate inside a
#      bound only a whole-file reader can meet. The shape this guards against
#      forked jq, basename or date once per row; on any plausible hardware that
#      costs tens of seconds, while reading each file once costs well under a
#      second. Ten seconds sits in the gap, so the guard never fails for being
#      run on a slow or busy machine, only for the shape coming back.
#
#   2. The payload the walker prints still carries what its consumers read:
#      the card and orchestrator join, verifier artefacts, live agents, a halt,
#      marked zero-output rows and the run scoping card 72 added. Consumers are
#      the reason the shape may not change silently.
#
# Usage: aggregate-perf-smoke.sh [--fixture DIR] [--dump DIR]
#
#   --fixture DIR  build (or reuse) the fixture tree at DIR rather than a
#                  temporary one, so two runs can be compared against the same
#                  pinned inputs.
#   --dump DIR     write each repo's normalised payload to DIR/<name>.json.
#
# AUTOMETTA_AGGREGATE_SCRIPT names the walker under test. Pointing it at an
# older copy of aggregate-dashboard.sh is how the before-and-after diff for
# card 74 was taken: same fixture, two walkers, one diff.
set -euo pipefail
IFS=$'\n\t'

# Pinned so a locale's thousands separator, a terminal's width or a local
# timezone can never be the reason a payload differs between two runs.
export LC_ALL=C LANG=C TZ=UTC
export TERM="${TERM:-dumb}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
aggregate="${AUTOMETTA_AGGREGATE_SCRIPT:-$script_dir/aggregate-dashboard.sh}"
perf_bound="${AUTOMETTA_AGGREGATE_PERF_BOUND:-10}"
perf_rows="${AUTOMETTA_AGGREGATE_PERF_ROWS:-5000}"

fixture=""
dump_dir=""
keep_fixture=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture) [[ $# -ge 2 ]] || { printf 'usage: %s [--fixture DIR] [--dump DIR]\n' "${0##*/}" >&2; exit 3; }
      fixture="$2"; keep_fixture=true; shift 2 ;;
    --dump) [[ $# -ge 2 ]] || { printf 'usage: %s [--fixture DIR] [--dump DIR]\n' "${0##*/}" >&2; exit 3; }
      dump_dir="$2"; shift 2 ;;
    *) printf 'usage: %s [--fixture DIR] [--dump DIR]\n' "${0##*/}" >&2; exit 3 ;;
  esac
done

# Every helper this smoke leans on is named here rather than discovered
# halfway through, so a missing one is an environment error with a name on it
# and not a mysterious empty payload two hundred lines later.
need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'ENV %s: required command not found (%s)\n' "${0##*/}" "$1" >&2
    exit 3
  }
}
for dependency in jq yq awk stat date python3; do need "$dependency"; done
[[ -x "$aggregate" ]] || {
  printf 'ENV %s: walker not executable: %s\n' "${0##*/}" "$aggregate" >&2
  exit 3
}

fail=0
check() {
  local name="$1" verdict="$2"
  if [[ "$verdict" == ok ]]; then
    printf '  PASS: %s\n' "$name"
  else
    printf '  FAIL: %s (%s)\n' "$name" "$verdict" >&2
    fail=$(( fail + 1 ))
  fi
}
eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %s, got %s\n' "$1" "$2"; }

if [[ -z "$fixture" ]]; then
  fixture="$(mktemp -d)"
fi
cleanup() {
  [[ "$keep_fixture" == true ]] && return 0
  case "$fixture" in /tmp/*|/private/tmp/*|/private/var/*|/var/folders/*) rm -rf -- "$fixture" ;; esac
}
trap cleanup EXIT

mkdir -p "$fixture"
controller="$fixture/controller"
now_file="$fixture/now"
[[ -f "$now_file" ]] || date -u +%s > "$now_file"
now="$(cat "$now_file")"
iso_at() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# Fixture. Built once and reused when --fixture names a tree that already has
# it, so the same bytes go into both walkers of a before-and-after comparison.
# ---------------------------------------------------------------------------
if [[ ! -f "$fixture/.built" ]]; then
  mkdir -p "$controller/subscribers" "$controller/dashboard"

  make_repo() {
    local name="$1"
    local path="$fixture/$name"
    mkdir -p "$path/state/active-agents" "$path/state/verifiers" "$path/state/logs" "$path/stage-cards"
    printf 'enabled: true\nrepo_path: %s\nmanifest_path: \n' "$path" \
      > "$controller/subscribers/$name.yaml"
  }
  make_card() {
    local repo="$1" stage="$2" orchestrator="$3"
    printf '# Stage card %s\n\n## Metadata\n\n- **Orchestrator:** %s\n- **Worker:** worker <worker@local>\n' \
      "$stage" "$orchestrator" > "$fixture/$repo/stage-cards/$stage.md"
  }

  # --- live: agents running, a card join, a verifier artefact, run scoping ---
  make_repo live
  make_card live stage-alpha 'Claude Fable 5 <claude-fable-5@local>'
  make_card live stage-beta 'phat-controller <phat-controller@local>'
  make_card live stage-gamma 'Claude Fable 5 <claude-fable-5@local>'
  printf '{"tokens_spent":1200,"token_cap_total":1000000,"halted":false,"halt_reason":null,"consecutive_failures":0,"consecutive_failure_cap":3}\n' \
    > "$fixture/live/state/budget.json"
  printf '{"overall":"PASS","criteria":[]}\n' > "$fixture/live/state/verifiers/stage-alpha.json"
  cat > "$fixture/live/state/state.yaml" <<YAML
last_tick_at: "$(iso_at "$(( now - 120 ))")"
tick_count: 42
current_stage: stage-beta
stages:
  - id: stage-alpha
    run_id: "run-20260826T090000Z"
    status: completed
    worker: "Codex GPT-5.3 <codex-gpt-5-3@local>"
    verifier: "Claude Fable 5 <claude-fable-5@local>"
    started_at: "$(iso_at "$(( now - 7200 ))")"
    completed_at: "$(iso_at "$(( now - 5400 ))")"
    tokens: 120000
    worker_tokens: 90000
    verifier_tokens: 30000
    verifier_artefact: state/verifiers/stage-alpha.json
  - id: stage-beta
    run_id: "run-20260826T090000Z"
    status: in_progress
    worker: "Claude Opus 5 <claude-opus-5@local>"
    verifier: "Claude Fable 5 <claude-fable-5@local>"
    started_at: "$(iso_at "$(( now - 600 ))")"
  - id: stage-gamma
    run_id: "run-20260826T090000Z"
    status: pending
    worker: "GPT-5.6 Sol <gpt-5-6-sol@local>"
    verifier: "Claude Fable 5 <claude-fable-5@local>"
  - id: stage-delta
    status: verifier_failed
    worker: "Claude Haiku 4.5 <claude-haiku-4-5@local>"
    completed_at: "$(iso_at "$(( now - 86400 ))")"
YAML
  printf 'a live worker log\n' > "$fixture/live/state/logs/stage-beta-worker.log"
  # A pid above the kernel's ceiling, held alive by the heartbeat instead. The
  # walker's own pid would make the fixture different on every run and so
  # unusable for a before-and-after diff, and a dead pid with a live heartbeat
  # is the harder of the two liveness paths anyway.
  agent_pid=999999
  printf '{"pid":%s,"role":"worker","family":"claude","identity":"Claude Opus 5 <claude-opus-5@local>","stage_id":"stage-beta","card_path":"stage-cards/stage-beta.md","log_path":"%s","budget_seconds":5400,"started_at":"%s"}\n' \
    "$agent_pid" "$fixture/live/state/logs/stage-beta-worker.log" "$(iso_at "$(( now - 600 ))")" \
    > "$fixture/live/state/active-agents/$agent_pid.json"
  printf '{"checked_at":"%s","entries":[{"pid":%s,"alive":true,"elapsed_seconds":600,"flags":["token-outlier"],"live_total_tokens":900000,"baseline_median_tokens":300000,"baseline_sample_size":8,"token_outlier":true}],"baselines":{"worker":300000},"outlier_policy":{"multiple":3}}\n' \
    "$(iso_at "$(( now - 60 ))")" "$agent_pid" > "$fixture/live/state/heartbeat.json"
  # A codex row that reports input but no output is the marked case: the
  # payload has to raise the caveat rather than quietly report zero spend.
  {
    printf '{"ts":"%s","repo":"live","stage_id":"stage-alpha","role":"worker","identity":"Codex GPT-5.3 <codex-gpt-5-3@local>","input_tokens":80000,"cached_input_tokens":10000,"output_tokens":0,"cost_usd_est":0.5,"total_cost_usd_est":0.55,"result":"pass"}\n' "$(iso_at "$(( now - 5400 ))")"
    printf '{"ts":"%s","repo":"live","stage_id":"stage-alpha","role":"verifier","identity":"Claude Fable 5 <claude-fable-5@local>","input_tokens":20000,"cached_input_tokens":5000,"output_tokens":5000,"cost_usd_est":0.25,"total_cost_usd_est":0.25,"result":"pass"}\n' "$(iso_at "$(( now - 5000 ))")"
    # Deliberately not on the hour boundary: last_hour_tokens counts from the
    # moment of the walk, so a row at now-3600 falls out of the window between
    # two walks of the same fixture and reads as a payload difference that is
    # really just the clock.
    printf '{"ts":"%s","repo":"live","stage_id":"stage-delta","role":"verifier","identity":"Claude Haiku 4.5 <claude-haiku-4-5@local>","input_tokens":1000,"cached_input_tokens":0,"output_tokens":100,"cost_usd_est":0.02,"total_cost_usd_est":0.02,"result":"fail"}\n' "$(iso_at "$(( now - 1800 ))")"
    printf '{"ts":"%s","repo":"live","stage_id":"stage-beta","role":"phat-controller","identity":"phat-controller <phat-controller@local>","input_tokens":10,"cached_input_tokens":0,"output_tokens":10,"cost_usd_est":0.001,"result":"pass"}\n' "$(iso_at "$(( now - 300 ))")"
  } > "$fixture/live/state/cost-log.jsonl"
  printf '{"read_at":"%s","families":{"claude":{"family":"claude","status":"ok","reason":"read","source":"cli","fetched_at":"%s","windows":[]}}}\n' \
    "$(iso_at "$(( now - 200 ))")" "$(iso_at "$(( now - 200 ))")" > "$fixture/live/state/quota-window.json"

  # --- halted: the budget stop, which every display reads before anything else
  make_repo halted
  printf '{"tokens_spent":990000,"token_cap_total":1000000,"halted":true,"halt_reason":"operator stop","consecutive_failures":2,"consecutive_failure_cap":3,"paused_until":null,"paused_reason":null}\n' \
    > "$fixture/halted/state/budget.json"
  printf '{"stages":[]}\n' > "$fixture/halted/state/state.yaml"

  # --- bulk: the shape target. Sixty cards and a long cost log ---------------
  make_repo bulk
  bulk_index=0
  while (( bulk_index < 60 )); do
    make_card bulk "$(printf 'bulk-%02d' "$bulk_index")" 'Claude Fable 5 <claude-fable-5@local>'
    bulk_index=$(( bulk_index + 1 ))
  done
  printf '{"tokens_spent":50,"token_cap_total":1000000,"halted":false,"halt_reason":null,"consecutive_failures":0,"consecutive_failure_cap":3}\n' \
    > "$fixture/bulk/state/budget.json"
  python3 - "$fixture/bulk" "$now" "$perf_rows" <<'PY'
import json
import os
import sys
import time

repo, now, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
identities = ["Codex GPT-5.3 <codex-gpt-5-3@local>", "Claude Opus 5 <claude-opus-5@local>"]
roles = ["worker", "verifier", "phat-controller"]


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


stages = []
for index in range(60):
    stages.append(
        "  - id: bulk-%02d\n    status: %s\n    completed_at: \"%s\"\n    tokens: %d\n"
        % (index, "completed" if index % 4 else "pending", iso(now - 3600 - index * 60), index * 1000)
    )
with open(os.path.join(repo, "state", "state.yaml"), "w") as handle:
    handle.write("last_tick_at: \"%s\"\ntick_count: 900\nstages:\n%s" % (iso(now - 60), "".join(stages)))

with open(os.path.join(repo, "state", "cost-log.jsonl"), "w") as handle:
    for index in range(rows):
        handle.write(json.dumps({
            "ts": iso(now - index * 120),
            "repo": "bulk",
            "stage_id": "bulk-%02d" % (index % 60),
            "role": roles[index % 3],
            "identity": identities[index % 2],
            "input_tokens": 1000 + index,
            "cached_input_tokens": 500,
            "output_tokens": 0 if index % 23 == 0 else 250,
            "cost_usd_est": 0.01,
            "total_cost_usd_est": 0.012,
            "result": "pass" if index % 7 else "fail",
        }) + "\n")
PY

  touch "$fixture/.built"
fi

walk() {
  AUTOMETTA_HOME="$controller" "$aggregate" --repo "$fixture/$1"
}

# Volatile by construction: the seconds an agent has been running move between
# two walks of the same fixture, and nothing else in the payload does.
normalise() {
  jq -S --arg fixture "$fixture" '
    walk(if type == "string" then sub("^" + $fixture; "<FIXTURE>") else . end) |
    if has("agents") then
      .agents = (.agents | map(.elapsed_seconds = "<ELAPSED>" | .elapsed = "<ELAPSED>")) |
      .active_agents = .agents
    else . end'
}

# ---------------------------------------------------------------------------
printf 'aggregate-perf-smoke: walker %s\n' "$aggregate"

live_payload="$(walk live)"
halted_payload="$(walk halted)"

if [[ -n "$dump_dir" ]]; then
  mkdir -p "$dump_dir"
  printf '%s' "$live_payload" | normalise > "$dump_dir/live.json"
  printf '%s' "$halted_payload" | normalise > "$dump_dir/halted.json"
  walk bulk | normalise > "$dump_dir/bulk.json"
fi

jq_live() { printf '%s' "$live_payload" | jq -r "$1"; }
jq_halted() { printf '%s' "$halted_payload" | jq -r "$1"; }

printf 'payload: the card and orchestrator join\n'
check "the card path is relative to the repo" \
  "$(eq 'stage-cards/stage-alpha.md' "$(jq_live '.stages[] | select(.id == "stage-alpha") | .card')")"
check "the orchestrator comes off the card" \
  "$(eq 'Claude Fable 5 <claude-fable-5@local>' "$(jq_live '.stages[] | select(.id == "stage-alpha") | .orchestrator')")"
check "each stage gets its own card's orchestrator" \
  "$(eq 'phat-controller <phat-controller@local>' "$(jq_live '.stages[] | select(.id == "stage-beta") | .orchestrator')")"
check "a stage with no card carries neither" \
  "$(eq 'null null' "$(jq_live '.stages[] | select(.id == "stage-delta") | "\(.card) \(.orchestrator)"')")"

printf 'payload: verifier artefacts\n'
check "the artefact verdict is joined onto the stage" \
  "$(eq 'PASS' "$(jq_live '.stages[] | select(.id == "stage-alpha") | .verifier_overall')")"
check "a stage with no artefact reads null" \
  "$(eq 'null' "$(jq_live '.stages[] | select(.id == "stage-beta") | .verifier_overall')")"
check "event_at prefers the completion stamp" \
  "$(eq "$(iso_at "$(( now - 5400 ))")" "$(jq_live '.stages[] | select(.id == "stage-alpha") | .event_at')")"
check "event_at falls back to the start stamp" \
  "$(eq "$(iso_at "$(( now - 600 ))")" "$(jq_live '.stages[] | select(.id == "stage-beta") | .event_at')")"

printf 'payload: live agents\n'
check "the live agent survives the liveness test" \
  "$(eq '1' "$(jq_live '.agents | length')")"
check "the agent carries its stage and heartbeat flags" \
  "$(eq 'stage-beta token-outlier' "$(jq_live '.agents[0] | "\(.stage_id) \(.flags[0])"')")"
check "elapsed mirrors elapsed_seconds" \
  "$(eq 'true' "$(jq_live '.agents[0].elapsed == .agents[0].elapsed_seconds')")"
check "the agent log size is read" \
  "$(eq 'true' "$(jq_live '.agents[0].log_bytes > 0')")"
check "active_agents is the same list" \
  "$(eq 'true' "$(jq_live '.agents == .active_agents')")"
# stage-beta escalates on the live agent's token-outlier flag and stage-delta
# on its verifier_failed status: the count joins both sources, and both stages
# are still outstanding.
check "the outlier flag and the failed status both escalate" \
  "$(eq '2' "$(jq_live '.queue_counts.escalated')")"
check "the outstanding count skips completed stages" \
  "$(eq '3' "$(jq_live '.queue_counts.outstanding')")"

printf 'payload: run scoping (card 72)\n'
check "the current run is the newest unfinished run" \
  "$(eq 'run-20260826T090000Z' "$(jq_live '.current_run.id')")"
check "the run start is derived from the run id" \
  "$(eq '2026-08-26T09:00:00Z' "$(jq_live '.current_run.started_at')")"
check "the run holds only its own stages" \
  "$(eq '3' "$(jq_live '.current_run.stages | length')")"
check "the run totals its stages' spend" \
  "$(eq 'true' "$(jq_live '.current_run.tokens_total > 0')")"

printf 'payload: marked zero-output rows\n'
check "a codex row with no output raises the caveat" \
  "$(eq 'true' "$(jq_live '.spend.openai_zero_output_caveat')")"
check "the marked row marks its card" \
  "$(eq 'true' "$(jq_live '.history.cards[] | select(.id == "stage-alpha") | .tokens_marked')")"
check "the seven-day cost is marked" \
  "$(eq 'true' "$(jq_live '.history.summary.seven_day_cost_marked')")"
check "phat-controller rows stay out of the card history" \
  "$(eq '0' "$(jq_live '[.history.cards[] | select(.id == "stage-beta")] | length')")"
check "the fortnight chart still draws fourteen days" \
  "$(eq '14' "$(jq_live '.spend.history.fortnight.by_day | length')")"
check "today's bar carries the day's cost" \
  "$(eq 'true' "$(jq_live '.spend.history.fortnight.by_day[-1].cost_usd_est > 0')")"

printf 'payload: a halted repo\n'
check "the halt is reported" \
  "$(eq 'true' "$(jq_halted '.halted')")"
check "the halt reason survives" \
  "$(eq 'operator stop' "$(jq_halted '.halt_reason')")"
check "the halt sets the red light" \
  "$(eq 'red budget halted' "$(jq_halted '"\(.light) \(.light_reason)"')")"

# ---------------------------------------------------------------------------
# The guard. A walker that forks per row cannot come near this bound; one that
# reads each file once is not close to it either, from the other side.
# ---------------------------------------------------------------------------
printf 'guard: %s cost-log rows and 60 cards within %ss\n' "$perf_rows" "$perf_bound"
[[ "$(wc -l < "$fixture/bulk/state/cost-log.jsonl" | tr -d ' ')" -ge "$perf_rows" ]] \
  || { printf 'ENV %s: bulk fixture is short of %s rows\n' "${0##*/}" "$perf_rows" >&2; exit 3; }

hires_now() { python3 -c 'import time; print(repr(time.time()))'; }
started="$(hires_now)"
walk bulk > "$fixture/bulk-payload.json"
elapsed="$(python3 -c "import sys; print('%.3f' % (float(sys.argv[1]) - float(sys.argv[2])))" \
  "$(hires_now)" "$started")"

check "the bulk walk stayed inside the bound (took ${elapsed}s)" \
  "$(python3 -c "import sys; print('ok' if float(sys.argv[1]) < float(sys.argv[2]) else 'took %ss, bound is %ss' % (sys.argv[1], sys.argv[2]))" \
    "$elapsed" "$perf_bound")"
check "the bulk walk still produced every stage" \
  "$(eq '60' "$(jq -r '.stages | length' "$fixture/bulk-payload.json")")"
check "the bulk walk still joined every card" \
  "$(eq '60' "$(jq -r '[.stages[] | select(.card != null)] | length' "$fixture/bulk-payload.json")")"
check "the bulk walk still totalled the log" \
  "$(eq 'true' "$(jq -r '.spend.history.summary.seven_day_cost_usd_est > 0' "$fixture/bulk-payload.json")")"

# ---------------------------------------------------------------------------
if (( fail == 0 )); then
  printf 'PASS aggregate perf: card join, artefacts, agents, run scoping, marked rows, halt, %s-row guard in %ss\n' \
    "$perf_rows" "$elapsed"
else
  printf 'FAIL aggregate perf smoke\n' >&2
  exit 1
fi

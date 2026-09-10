#!/usr/bin/env bash
# Offline proof for stage card 114: a fire costs what it measures.
#
# Everything here runs against a throwaway fleet under a fake
# PHAT_CONTROLLER_HOME, so no assertion depends on the operator's live
# LaunchAgent, on their real subscribers, or on machine speed beyond the
# ratio checks it makes explicitly. The card originally asked for three live
# fires with the fleet job unloaded; it does not need them, and unloading a
# running fleet to measure it is not a thing a smoke may do.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

copy_harness() {
  local destination="$1"
  mkdir -p "$destination"
  cp -R "$repo_root/scripts" "$repo_root/templates" "$repo_root/bin" "$destination/"
  cat > "$destination/scripts/check-installed-build.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '{"status":"current","stale":false,"installed_sha":"fixture","checkout_sha":"fixture","checked_at":"2026-09-01T00:00:00Z"}\n'
STUB
  chmod +x "$destination/scripts/check-installed-build.sh"
}

make_fleet() {
  local name="$1" controller="$fixture_root/$1-controller" repos="$fixture_root/$1-repos"
  mkdir -p "$controller/subscribers" "$controller/log" "$repos"
  local n repo
  for n in 1 2 3 4; do
    repo="$repos/repo-$n"
    mkdir -p "$repo/state/active-agents" "$repo/state/recent-agents" "$repo/state/logs"
    cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: null
last_tick_at: "2000-01-01T00:00:00Z"
tick_count: 0
clock_tick_budget_remaining: 400
stages: []
YAML
    cat > "$repo/state/budget.json" <<'JSON'
{"version":1,"token_cap_total":1000000,"tokens_spent":0,"wall_clock_cap_seconds":86400,"wall_clock_elapsed_seconds":0,"clock_tick_cap":400,"clock_ticks_used":0,"consecutive_failure_cap":3,"consecutive_failures":0,"halted":false,"window_started_at":"2026-09-01"}
JSON
    (
      cd "$repo"
      git init -q -b dev
      git config user.email smoke@local
      git config user.name smoke
      git config commit.gpgsign false
      printf 'state/**\n' > .gitignore
      printf 'fixture\n' > README.md
      git add .gitignore README.md
      git commit -qm seed
    )
    printf 'repo_path: "%s"\nweight: 100\nenabled: true\n' "$repo" \
      > "$controller/subscribers/repo-$n.yaml"
  done
  printf '%s\n' "$controller"
}

fire() {
  local harness="$1" controller="$2" label="$3"
  shift 3
  local timing="$fixture_root/$label.time"
  env "$@" AUTOMETTA_ROOT="$harness" PHAT_CONTROLLER_HOME="$controller" \
    /usr/bin/time -p "$harness/scripts/tick.sh" \
      >"$fixture_root/$label.out" 2>"$timing" || true
  cat "$fixture_root/$label.out" "$timing" > "$fixture_root/$label.all"
  awk '/^real / { print $2; exit }' "$timing"
}

state_branch_commits() {
  git -C "$1" rev-list --count autometta/state 2>/dev/null || printf '0\n'
}

harness="$fixture_root/harness"
copy_harness "$harness"
controller="$(make_fleet main)"
repo_one="$fixture_root/main-repos/repo-1"

# The assertions below are the frozen acceptance spec for stage card 114,
# authored by the orchestrator before any implementation existed
# (docs/dispatch-contract.md:131). A worker satisfies them by changing the
# implementation, never by editing them; fixtures and scaffolding may be
# added outside the markers.
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/114-a-fire-costs-what-it-measures.md
# Deliverable 1 / acceptance 1. The instrumentation exists, is off by
# default, and accounts for the fire it claims to measure.
profiled_elapsed="$(fire "$harness" "$controller" profiled AUTOMETTA_TICK_PROFILE=1)"
grep -Eq 'profile repo=[^ ]+ phase=[^ ]+ ms=[0-9]+' "$fixture_root/profiled.all" \
  || fail "114: AUTOMETTA_TICK_PROFILE=1 emitted no per-phase profile line"
grep -Eq 'profile .*(fire|total)' "$fixture_root/profiled.all" \
  || fail "114: the profiled fire emitted no summary line"

phase_ms_sum="$(grep -Eo 'phase=[^ ]+ ms=[0-9]+' "$fixture_root/profiled.all" \
  | awk -F'ms=' '{ s += $2 } END { printf "%d\n", s }')"
[[ "${phase_ms_sum:-0}" -gt 0 ]] || fail "114: the per-phase lines summed to zero"
awk -v sum_ms="$phase_ms_sum" -v real_s="$profiled_elapsed" 'BEGIN {
  real_ms = real_s * 1000
  if (real_ms <= 0) { exit 1 }
  ratio = sum_ms / real_ms
  exit !(ratio >= 0.90 && ratio <= 1.10)
}' || fail "114: the per-phase lines do not sum to within 10% of the fire wall clock"

plain_elapsed="$(fire "$harness" "$controller" plain AUTOMETTA_TICK_PROFILE=)"
: "${plain_elapsed:?}"
if grep -Eq 'profile repo=' "$fixture_root/plain.all"; then
  fail "114: profile lines were emitted with the flag unset"
fi

# Deliverable 2. The tool is the deliverable, not a one-off command in an
# envelope: the next person to ask this question must not have to re-derive it.
[[ -x "$harness/scripts/tick-profile.sh" ]] \
  || fail "114: scripts/tick-profile.sh is missing or not executable"
AUTOMETTA_ROOT="$harness" PHAT_CONTROLLER_HOME="$controller" \
  "$harness/scripts/tick-profile.sh" >"$fixture_root/tool.out" 2>&1 \
  || fail "114: scripts/tick-profile.sh exited non-zero"
grep -Eqi 'phase' "$fixture_root/tool.out" \
  || fail "114: tick-profile.sh printed no phase column"
tool_rows="$(grep -Eo '[0-9]+(\.[0-9]+)?[[:space:]]*ms|ms=[0-9]+' "$fixture_root/tool.out" | wc -l | tr -d ' ')"
[[ "${tool_rows:-0}" -ge 2 ]] || fail "114: tick-profile.sh printed no cost table"

# Deliverable 3. The measured fix. An idle fire changes only tick_count and
# last_tick_at, so the state-snapshot short-circuit must fire and no commit
# may be written. Pre-change the bookkeeping bump defeats the tree
# comparison and every tick commits, which is the cost this card exists to
# remove.
before_commits="$(state_branch_commits "$repo_one")"
fire "$harness" "$controller" idle1 AUTOMETTA_TICK_PROFILE= >/dev/null
after_first="$(state_branch_commits "$repo_one")"
fire "$harness" "$controller" idle2 AUTOMETTA_TICK_PROFILE= >/dev/null
after_second="$(state_branch_commits "$repo_one")"
[[ "$after_second" -eq "$after_first" ]] \
  || fail "114: a second idle fire committed to the state branch (${after_first} -> ${after_second}); the short-circuit did not fire"
[[ $(( after_first - before_commits )) -le 1 ]] \
  || fail "114: a single idle fire wrote more than one state-branch commit"

# The fix must not change what the tick decides. An idle fire still counts
# itself, or the clock-tick budget stops meaning anything.
tick_count_now="$(yq -r '.tick_count' "$repo_one/state/state.yaml")"
[[ "${tick_count_now:-0}" -ge 3 ]] \
  || fail "114: idle fires stopped incrementing tick_count (got ${tick_count_now})"
# AUTOMETTA-CONTRACT-END

printf 'PASS: tick profile instrumentation, the profile tool, and the idle-fire state-branch short-circuit\n'

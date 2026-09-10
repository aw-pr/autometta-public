#!/usr/bin/env bash
# Offline fleet-cost regression check. The fixture has six drained repos, so
# no dispatches occur. A one-second build-check stub makes the pre-change
# six-per-repo cost observable without depending on machine speed.
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

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3 (got $1, expected $2)"
}

copy_harness() {
  local destination="$1" version="$2"
  mkdir -p "$destination"
  cp -R "$repo_root/scripts" "$repo_root/templates" "$repo_root/bin" "$destination/"
  if [[ "$version" == "pre-change" ]]; then
    write_legacy_tick_fixture "$destination/scripts/tick.sh"
  fi
  cat > "$destination/scripts/check-installed-build.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf x >> "$AUTOMETTA_TICK_COST_BUILD_CHECK_COUNT"
sleep "${AUTOMETTA_TICK_COST_BUILD_CHECK_SLEEP:-1}"
printf '{"status":"current","stale":false,"installed_sha":"fixture","checkout_sha":"fixture","checked_at":"2026-09-01T00:00:00Z"}\n'
STUB
  chmod +x "$destination/scripts/check-installed-build.sh"
}

write_legacy_tick_fixture() {
  local destination="$1"
  cat > "$destination" <<'FIXTURE'
#!/usr/bin/env bash
# Frozen offline model of the pre-cache fleet tick. It deliberately performs
# the controller-wide build check through every subscriber heartbeat.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller="${PHAT_CONTROLLER_HOME:?PHAT_CONTROLLER_HOME is required}"

for subscriber in "$controller"/subscribers/*.yaml; do
  repo_root="$(yq -r '.repo_path' "$subscriber")"
  "$script_dir/heartbeat.sh" "$repo_root" >/dev/null
  yq -i '.tick_count += 1' "$repo_root/state/state.yaml"
  jq '.idle_ticks_used = ((.idle_ticks_used // 0) + 1)' "$repo_root/state/budget.json" \
    > "$repo_root/state/budget.json.next"
  mv "$repo_root/state/budget.json.next" "$repo_root/state/budget.json"
done
FIXTURE
  chmod +x "$destination"
}

make_fleet() {
  local name="$1" controller="$fixture_root/$1-controller" repos="$fixture_root/$1-repos"
  mkdir -p "$controller/subscribers" "$controller/log" "$repos"
  local n repo
  for n in 1 2 3 4 5 6; do
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

timed_tick() {
  local harness="$1" controller="$2" label="$3"
  local timing="$fixture_root/$label.time"
  AUTOMETTA_ROOT="$harness" PHAT_CONTROLLER_HOME="$controller" \
    AUTOMETTA_TICK_COST_BUILD_CHECK_COUNT="$fixture_root/$label.count" \
    AUTOMETTA_TICK_COST_BUILD_CHECK_SLEEP=1 \
    /usr/bin/time -lp "$harness/scripts/tick.sh" \
      >"$fixture_root/$label.out" 2>"$timing"
  awk '/^real / { print $2; exit }' "$timing"
}

within_budget() {
  awk -v elapsed="$1" -v cap="$2" 'BEGIN { exit !(elapsed <= cap) }'
}

budget_seconds="${AUTOMETTA_TICK_COST_MAX_SECONDS:-6.0}"
legacy_root="$fixture_root/legacy-autometta"
candidate_root="$fixture_root/candidate-autometta"
copy_harness "$legacy_root" pre-change
copy_harness "$candidate_root" candidate

legacy_controller="$(make_fleet legacy)"
candidate_controller="$(make_fleet candidate)"

legacy_elapsed="$(timed_tick "$legacy_root" "$legacy_controller" legacy)"
candidate_elapsed="$(timed_tick "$candidate_root" "$candidate_controller" candidate)"
legacy_checks="$(wc -c < "$fixture_root/legacy.count" | tr -d '[:space:]')"
candidate_checks="$(wc -c < "$fixture_root/candidate.count" | tr -d '[:space:]')"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/105-the-cost-smoke-survives-its-own-commit.md
assert_eq "$legacy_checks" 6 "pre-change tick did not compute one build check per repo"
assert_eq "$candidate_checks" 1 "candidate tick did not share the build check across the fleet"
if within_budget "$legacy_elapsed" "$budget_seconds"; then
  fail "pre-change tick unexpectedly met the ${budget_seconds}s budget (${legacy_elapsed}s)"
fi
within_budget "$candidate_elapsed" "$budget_seconds" \
  || fail "candidate tick exceeded the ${budget_seconds}s budget (${candidate_elapsed}s)"
# AUTOMETTA-CONTRACT-END

for n in 1 2 3 4 5 6; do
  repo="$candidate_controller/../candidate-repos/repo-$n"
  assert_eq "$(yq -r '.current_stage' "$repo/state/state.yaml")" null "repo-$n changed current_stage"
  assert_eq "$(yq -r '.tick_count' "$repo/state/state.yaml")" 1 "repo-$n did not record one tick"
  assert_eq "$(jq -r '.clock_ticks_used' "$repo/state/budget.json")" 0 "repo-$n charged idle work"
  assert_eq "$(jq -r '.idle_ticks_used' "$repo/state/budget.json")" 1 "repo-$n did not record its idle tick"
done

printf 'PASS tick cost: pre-change %ss (%s build checks), candidate %ss (%s build check), budget %ss\n' \
  "$legacy_elapsed" "$legacy_checks" "$candidate_elapsed" "$candidate_checks" "$budget_seconds"
